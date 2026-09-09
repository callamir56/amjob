if Bridge.Framework ~= 'es_extended' then return end

local Core = exports['es_extended']:getSharedObject()
Framework.Core = Core
Framework.Resource = 'es_extended'
Framework.PlayerLoadedEvent = 'esx:playerLoaded'
Framework.JobUpdateEvent = 'esx:setJob'

local function GetRawPlayer(src)
    return Core.GetPlayerFromId(src)
end

--[[
    Cash resolution.

    On a plain ESX server cash lives in the `money` account (xPlayer.getMoney).
    With ox_inventory (and on qb-style setups) cash is an ITEM in the player's
    inventory instead, and the money account reads 0 - which is why the pharmacy
    said "you don't have enough cash" while the player could see money right
    there in their inventory.

    Config.MoneySource:
      "auto"    -> use the inventory item when the player carries any, else the account
      "item"    -> always the inventory item
      "account" -> always the ESX money account

    `Inventory` is looked up at call time on purpose: the inventory bridge is
    loaded after this file in fxmanifest.lua.
]]
local function moneyItemNames()
    local names = Config.MoneyItems

    if type(names) ~= 'table' then
        names = { 'money', 'cash' }
    end

    return names
end

-- Returns itemName, count for the first money item the player is carrying.
local function findCashItem(player)
    if not Inventory or type(Inventory.GetItemCount) ~= 'function' then
        return nil, 0
    end

    for _, itemName in ipairs(moneyItemNames()) do
        local ok, count = pcall(Inventory.GetItemCount, player.source, itemName)

        if ok and (tonumber(count) or 0) > 0 then
            return itemName, math.floor(tonumber(count))
        end
    end

    return nil, 0
end

local function useCashItem()
    local source = tostring(Config.MoneySource or 'auto'):lower()

    return source == 'item' or source == 'auto'
end

local function getAccountMoney(player, account)
    local ok, data = pcall(player.getAccount, account)

    if ok and type(data) == 'table' then
        return math.floor(tonumber(data.money) or 0)
    end

    -- Older / custom ESX builds expose accounts as a list instead.
    local listOk, accounts = pcall(player.getAccounts)

    if listOk and type(accounts) == 'table' then
        for _, entry in pairs(accounts) do
            if type(entry) == 'table' and entry.name == account then
                return math.floor(tonumber(entry.money) or 0)
            end
        end
    end

    return 0
end

local function GetAccount(player, account)
    if account == 'cash' or account == 'money' then
        if useCashItem() then
            local itemName, count = findCashItem(player)

            if itemName then
                return count
            end

            if tostring(Config.MoneySource or 'auto'):lower() == 'item' then
                return 0
            end
        end

        if type(player.getMoney) == 'function' then
            return math.floor(tonumber(player.getMoney()) or 0)
        end

        return getAccountMoney(player, 'money')
    end

    return getAccountMoney(player, account)
end

local function giveMoney(player, account, amount, reason)
    amount = math.max(0, math.floor(tonumber(amount) or 0))

    if amount == 0 then
        return true
    end

    if account == 'cash' or account == 'money' then
        if useCashItem() then
            local itemName = (findCashItem(player))

            -- In "auto" mode only use the item when the player already has it,
            -- so we never create a second wallet on an account-based server.
            if itemName or tostring(Config.MoneySource or 'auto'):lower() == 'item' then
                itemName = itemName or moneyItemNames()[1]

                if Inventory and type(Inventory.AddItem) == 'function' then
                    return Inventory.AddItem(player.source, itemName, amount) ~= false
                end
            end
        end

        player.addMoney(amount, reason)

        return true
    end

    player.addAccountMoney(account, amount, reason)

    return true
end

local function takeMoney(player, account, amount, reason)
    amount = math.max(0, math.floor(tonumber(amount) or 0))

    if amount == 0 then
        return true
    end

    if GetAccount(player, account) < amount then
        return false
    end

    if account == 'cash' or account == 'money' then
        if useCashItem() then
            local itemName = (findCashItem(player))

            if itemName then
                if not Inventory or type(Inventory.RemoveItem) ~= 'function' then
                    return false
                end

                return Inventory.RemoveItem(player.source, itemName, amount) ~= false
            end

            if tostring(Config.MoneySource or 'auto'):lower() == 'item' then
                return false
            end
        end

        player.removeMoney(amount, reason)

        return true
    end

    player.removeAccountMoney(account, amount, reason)

    return true
end

function Framework.GetPlayers()
    return Core.GetPlayers()
end

function Framework.GetPlayer(src)
    local player = GetRawPlayer(src)
    if not player then return nil end
    local firstName = player.get('firstName') or ''
    local lastName = player.get('lastName') or ''
    local jobName, onDuty = Framework.NormalizeEsxDutyJob(player.job.name)
    return {
        source = src,
        citizenid = player.identifier,
        identifier = player.identifier,
        name = firstName ~= '' and lastName ~= '' and (firstName .. ' ' .. lastName) or player.getName(),
        charinfo = { firstname = firstName, lastname = lastName },
        job = {
            name = jobName,
            rawName = player.job.name,
            label = player.job.label,
            grade = player.job.grade,
            gradeLabel = player.job.grade_label,
            onduty = onDuty
        },
        functions = {
            AddMoney = function(account, amount, reason)
                return giveMoney(player, account, amount, reason)
            end,
            RemoveMoney = function(account, amount, reason)
                return takeMoney(player, account, amount, reason)
            end,
            GetMoney = function(account) return GetAccount(player, account) end,
            AddItem = function(item, amount)
                if Inventory and type(Inventory.AddItem) == 'function' then
                    return Inventory.AddItem(src, item, amount) ~= false
                end
                player.addInventoryItem(item, amount)
                return true
            end,
            RemoveItem = function(item, amount)
                if Inventory and type(Inventory.RemoveItem) == 'function' then
                    return Inventory.RemoveItem(src, item, amount) ~= false
                end
                player.removeInventoryItem(item, amount)
                return true
            end
        }
    }
end

function Framework.GetPlayerByCitizenId(identifier)
    local player = Core.GetPlayerFromIdentifier(identifier)
    return player and Framework.GetPlayer(player.source) or nil
end

function Framework.CreateCallback(name, cb)
    Core.RegisterServerCallback(name, cb)
end

function Framework.SetMetaData(src, key, value)
    local player = GetRawPlayer(src)
    if player then player.set(key, value) end
end

function Framework.GetMetaData(src, key)
    local player = GetRawPlayer(src)
    return player and player.get(key) or nil
end

function Framework.SetJob(src, job, grade)
    local player = GetRawPlayer(src)
    if player then player.setJob(job, tonumber(grade) or 0) end
end

local function GetMedicalMetadata(player)
    if type(player.getMeta) == 'function' then
        local ok, value = pcall(player.getMeta, 'plt_medical')
        if ok and type(value) == 'table' then return value end
    end
    if type(player.get) == 'function' then
        local value = player.get('plt_medical')
        if type(value) == 'table' then return value end
    end
end

local function SetMedicalMetadata(player, value)
    if type(player.setMeta) == 'function' then
        local ok = pcall(player.setMeta, 'plt_medical', value)
        if ok then return end
    end
    if type(player.set) == 'function' then
        player.set('plt_medical', value)
    end
end

function Framework.GetMedicalState(src)
    local player = GetRawPlayer(src)
    if not player then return nil, 0 end

    local metadata = GetMedicalMetadata(player)
    if metadata then
        return Framework.NormalizeMedicalState(metadata.state), tonumber(metadata.startedAt) or 0
    end

    local isDead = player.get('is_dead') == true or player.get('isDead') == true or player.get('dead') == true
    local inLaststand = player.get('inlaststand') == true
    if isDead then return Framework.MedicalState.DEAD, 0 end
    if inLaststand then return Framework.MedicalState.LASTSTAND, 0 end
    return Framework.MedicalState.ALIVE, 0
end

function Framework.SetMedicalState(src, state, startedAt)
    local player = GetRawPlayer(src)
    if not player then return nil, 0 end

    state = Framework.NormalizeMedicalState(state)
    local currentState, currentStartedAt = Framework.GetMedicalState(src)
    local requestedStartedAt = tonumber(startedAt)
    if state == Framework.MedicalState.ALIVE then
        startedAt = 0
    elseif requestedStartedAt and requestedStartedAt > 0 then
        startedAt = math.floor(requestedStartedAt)
    elseif currentState ~= Framework.MedicalState.ALIVE and currentStartedAt > 0 then
        startedAt = currentStartedAt
    else
        startedAt = os.time()
    end

    SetMedicalMetadata(player, { state = state, startedAt = startedAt })

    local isDead = state == Framework.MedicalState.DEAD
    local inLaststand = state == Framework.MedicalState.LASTSTAND
    player.set('dead', isDead)
    player.set('is_dead', isDead)
    player.set('inlaststand', inLaststand)

    local playerState = Player(src) and Player(src).state
    if playerState then
        playerState:set('medicalState', state, true)
        playerState:set('medicalStateStartedAt', startedAt, true)
        playerState:set('isDead', isDead, true)
        playerState:set('isdead', isDead, true)
        playerState:set('inlaststand', inLaststand, true)
    end

    return state, startedAt
end

function Framework.HasPermission(src, permission)
    local player = GetRawPlayer(src)
    if not player then return false end
    local group = type(player.getGroup) == 'function' and player.getGroup() or 'user'
    if group == permission or group == 'admin' or group == 'superadmin' or group == 'owner' then return true end
    return IsPlayerAceAllowed(src, 'admin') or IsPlayerAceAllowed(src, 'command')
end

function Framework.SetDeathStatus(src, status)
    local player = GetRawPlayer(src)
    if not player then return end
    Framework.SetMedicalState(src, status and Framework.MedicalState.DEAD or Framework.MedicalState.ALIVE)
    if not status then
        TriggerClientEvent('esx_status:set', src, 'hunger', 1000000)
        TriggerClientEvent('esx_status:set', src, 'thirst', 1000000)
        TriggerClientEvent('esx_status:set', src, 'stress', 0)
    end
end

function Framework.SetLaststandStatus(src, status)
    if status then
        Framework.SetMedicalState(src, Framework.MedicalState.LASTSTAND)
    elseif Framework.GetMedicalState(src) == Framework.MedicalState.LASTSTAND then
        Framework.SetMedicalState(src, Framework.MedicalState.ALIVE)
    end
end

function Framework.CreateUseableItem(name, cb)
    Core.RegisterUsableItem(name, cb)
end

function Framework.RemoveMoney(src, account, amount, reason)
    if amount <= 0 then return true end

    local player = GetRawPlayer(src)

    if not player then return false end

    return takeMoney(player, account, amount, reason)
end

function Framework.AddMoney(src, account, amount, reason)
    local player = GetRawPlayer(src)

    if not player then return false end

    return giveMoney(player, account, amount, reason)
end

function Framework.GetPlayerMoney(src, account)
    local player = GetRawPlayer(src)
    return player and GetAccount(player, account) or 0
end

function Framework.GetPlayerIdentifier(src)
    local player = GetRawPlayer(src)
    return player and player.identifier or nil
end

