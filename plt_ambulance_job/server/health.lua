local savedHealth = {}
local bodyBagStates = {}
local deathTickets = {}
local lastSyncedStates = {}
local downedFallback = {}

local MEDICATION_EVENTS = {
    plt_bandage = 'amb_client:selfBandage',
    plt_painkillers = 'amb_client:useMedication',
    plt_painkillers_adv = 'amb_client:useMedication',
    plt_antibiotics = 'amb_client:useMedication',
    plt_medkit = 'amb_client:useMedication',
    iak_wheelchair = 'amb_client:useWheelchair',
    plt_walking_stick = 'amb_client:toggleWalkingAid',
    plt_cane = 'amb_client:toggleWalkingAid',
    plt_crutches = 'amb_client:toggleWalkingAid'
}

local REUSABLE_ITEMS = {
    plt_walking_stick = true,
    plt_cane = true,
    plt_crutches = true
}

local XRAY_CLIPBOARD_ITEMS = {
    as_xray_clipboard_01 = true,
    as_xray_clipboard_02 = true,
    as_xray_clipboard_03 = true,
    as_xray_clipboard_04 = true
}

local function isPlayerOnline(src)
    src = tonumber(src)

    if not src then
        return false
    end

    return GetPlayerName(src) ~= nil
end

local function notifyClientRevive(src)
    TriggerClientEvent('amb_client:SetDeathStatus', src, false)
    TriggerClientEvent('amb_client:RevivePlayer', src)
    TriggerClientEvent('amb_client:onPlayerRevive', src)
end

local function isPlayerDowned(src)
    if Framework.HasAuthoritativeMedicalState() then
        return Framework.GetMedicalState(src) == Framework.MedicalState.LASTSTAND
    end

    if downedFallback[src] == true then
        return true
    end

    local isDead = Framework.GetMetaData(src, 'isdead')
    local inLaststand = Framework.GetMetaData(src, 'inlaststand')
    local isDeadAlt = Framework.GetMetaData(src, 'is_dead')

    if isDead == true or inLaststand == true or isDeadAlt == true then
        return true
    end

    local ped = GetPlayerPed(src)

    if ped and ped > 0 then
        local health = GetEntityHealth(ped)

        if health and health <= 110 then
            return true
        end
    end

    return false
end

local function getElapsedSeconds(timestamp)
    timestamp = tonumber(timestamp) or 0

    if timestamp <= 0 then
        return 0
    end

    return math.max(0, os.time() - timestamp)
end

local setMedicalState

local function syncMedicalStateToClient(src)
    if not Framework.HasAuthoritativeMedicalState() or not isPlayerOnline(src) then
        return
    end

    local state, startedAt = Framework.GetMedicalState(src)

    if not state then
        return
    end

    TriggerClientEvent('amb_client:syncMedicalState', src, state, getElapsedSeconds(startedAt))
end

local function scheduleBleedOut(src, startedAt)
    src = tonumber(src)

    if not src then
        return
    end

    deathTickets[src] = (deathTickets[src] or 0) + 1

    local ticket = deathTickets[src]
    local deathTimer = math.max(0, tonumber(Config.Health and Config.Health.DeathTimer) or 300)
    local remaining = math.max(0, deathTimer - getElapsedSeconds(startedAt))

    SetTimeout(math.floor(remaining * 1000), function()
        if deathTickets[src] ~= ticket or not isPlayerOnline(src) then
            return
        end

        local state, stateStartedAt = Framework.GetMedicalState(src)

        if state ~= Framework.MedicalState.LASTSTAND or stateStartedAt ~= startedAt then
            return
        end

        setMedicalState(src, Framework.MedicalState.DEAD, startedAt)
    end)
end

setMedicalState = function(src, state, startedAt)
    src = tonumber(src)

    if not Framework.HasAuthoritativeMedicalState() or not src or not isPlayerOnline(src) then
        return false
    end

    state, startedAt = Framework.SetMedicalState(src, state, startedAt)

    if not state then
        return false
    end

    lastSyncedStates[src] = {
        state = state,
        startedAt = startedAt
    }

    deathTickets[src] = (deathTickets[src] or 0) + 1

    if state == Framework.MedicalState.LASTSTAND then
        scheduleBleedOut(src, startedAt)
    end

    syncMedicalStateToClient(src)

    return true
end

exports('SetMedicalState', setMedicalState)

exports('GetMedicalState', function(src)
    if not Framework.HasAuthoritativeMedicalState() then
        return nil, 0
    end

    return Framework.GetMedicalState(tonumber(src))
end)

local function setBodyBagState(src, bagged)
    src = tonumber(src)

    if not src or src <= 0 then
        return
    end

    if bagged == true then
        bodyBagStates[src] = true
    else
        bodyBagStates[src] = nil
    end

    TriggerClientEvent('amb_client:setBodyBagState', -1, src, bagged == true)
end

local function clampHealth(value)
    local health = tonumber(value)

    if not health then
        return nil
    end

    health = math.floor(health)

    if health < 100 then
        health = 100
    end

    if health > 200 then
        health = 200
    end

    return health
end

local function resetVitals(src)
    pcall(function()
        Framework.SetMetaData(src, 'hunger', 100)
    end)

    pcall(function()
        Framework.SetMetaData(src, 'thirst', 100)
    end)

    pcall(function()
        Framework.SetMetaData(src, 'stress', 0)
    end)
end

local function saveHealth(src, health)
    if not Framework.GetPlayer(src) then
        return
    end

    local value = clampHealth(health) or clampHealth(savedHealth[src])

    if not value then
        local ped = GetPlayerPed(src)

        if ped and ped > 0 then
            value = clampHealth(GetEntityHealth(ped))
        end
    end

    if value then
        Framework.SetMetaData(src, 'amb_saved_health', value)
    end
end

-- Lets every client know who is downed so target options (search / carry) can
-- gate on it without each client guessing.
local function broadcastDowned(src, downed)
    TriggerClientEvent('amb_client:syncDownedPlayer', -1, src, downed == true)
end

local searchCooldown = {}

RegisterNetEvent('amb_server:SetDowned', function(downed)
    local src = source

    if Framework.HasAuthoritativeMedicalState() then
        local state = Framework.GetMedicalState(src)

        if downed == true then
            if state == Framework.MedicalState.DEAD then
                syncMedicalStateToClient(src)
            end
        else
            setMedicalState(src, Framework.MedicalState.ALIVE)
        end
    else
        downedFallback[src] = downed == true
        Framework.SetDeathStatus(src, downed)
    end

    broadcastDowned(src, downed == true)

    if downed ~= true then
        setBodyBagState(src, false)
    end
end)

-- Searching a downed / dead player opens their ox_inventory, rate-limited by a
-- per-searcher cooldown so it cannot be spammed.
RegisterNetEvent('amb_server:searchDowned', function(targetId)
    local src = source

    targetId = tonumber(targetId)

    if not targetId or targetId <= 0 or targetId == src then
        return
    end

    local cooldown = tonumber(Config.Search and Config.Search.Cooldown) or 15000
    local now = GetGameTimer()

    if searchCooldown[src] and (now - searchCooldown[src]) < cooldown then
        local left = math.ceil((cooldown - (now - searchCooldown[src])) / 1000)

        Framework.Notify(src, _L('search_cooldown', { seconds = left }), 'error')

        return
    end

    if exports.plt_ambulance_job:IsPlayerFinished(targetId) then
        Framework.Notify(src, _L('player_finished_other'), 'error')

        return
    end

    if not isPlayerDowned(targetId) then
        Framework.Notify(src, _L('target_not_downed'), 'error')

        return
    end

    searchCooldown[src] = now

    if GetResourceState('ox_inventory') == 'started' then
        -- openInventory('player', id) is a *client* export. On the server the
        -- supported way to show one player another player's inventory is
        -- forceOpenInventory(searcher, 'player', target). The old OpenInventory
        -- call here raised an error every time.
        local ok = pcall(function()
            exports.ox_inventory:forceOpenInventory(src, 'player', targetId)
        end)

        if not ok then
            Framework.Notify(src, _L('search_unsupported'), 'error')
        end
    else
        Framework.Notify(src, _L('search_unsupported'), 'error')
    end
end)

-- While a player is being carried, their OWN client must stop enforcing the
-- downed pose (it otherwise pins velocity and replays the lying anim every
-- tick, which is exactly what made the carrier/patient freeze). These relay
-- the carried state to the patient's client.
RegisterNetEvent('amb_server:carryDowned', function(targetId)
    local src = source

    targetId = tonumber(targetId)

    if not targetId or targetId <= 0 or targetId == src then
        return
    end

    if exports.plt_ambulance_job:IsPlayerFinished(targetId) then
        Framework.Notify(src, _L('player_finished_other'), 'error')
        return
    end

    if not isPlayerDowned(targetId) then
        return
    end

    -- tell the patient who is carrying so it can attach itself to the carrier.
    TriggerClientEvent('amb_client:setCarried', targetId, true, src)
end)

RegisterNetEvent('amb_server:dropCarried', function(targetId)
    targetId = tonumber(targetId)

    if not targetId or targetId <= 0 then
        return
    end

    TriggerClientEvent('amb_client:setCarried', targetId, false)
end)

RegisterNetEvent('amb_server:SetMedicalState', function(requestedState)
    if not Framework.HasAuthoritativeMedicalState() then
        return
    end

    local src = source
    local newState = Framework.NormalizeMedicalState(requestedState)
    local currentState, startedAt = Framework.GetMedicalState(src)

    if newState == Framework.MedicalState.LASTSTAND and currentState == Framework.MedicalState.DEAD then
        syncMedicalStateToClient(src)
        return
    end

    if newState == Framework.MedicalState.DEAD then
        local deathTimer = math.max(0, tonumber(Config.Health and Config.Health.DeathTimer) or 300)

        if currentState ~= Framework.MedicalState.LASTSTAND or deathTimer > getElapsedSeconds(startedAt) then
            syncMedicalStateToClient(src)
            return
        end
    end

    setMedicalState(src, newState)
end)

RegisterNetEvent('hospital:server:SetDeathStatus', function(isDead)
    if Framework.Type ~= 'qb' then
        return
    end

    local src = source
    local dead = isDead == true

    if not dead then
        setBodyBagState(src, false)
    end

    setMedicalState(src, dead and Framework.MedicalState.DEAD or Framework.MedicalState.ALIVE)
end)

RegisterNetEvent('hospital:server:SetLaststandStatus', function(inLaststand)
    if Framework.Type ~= 'qb' then
        return
    end

    local src = source
    local laststand = inLaststand == true
    local currentState = Framework.GetMedicalState(src)

    if laststand then
        if currentState == Framework.MedicalState.DEAD then
            syncMedicalStateToClient(src)
        else
            setMedicalState(src, Framework.MedicalState.LASTSTAND)
        end
    else
        if currentState == Framework.MedicalState.LASTSTAND then
            setMedicalState(src, Framework.MedicalState.ALIVE)
        else
            syncMedicalStateToClient(src)
        end
    end

    if not laststand and currentState ~= Framework.MedicalState.DEAD then
        setBodyBagState(src, false)
    end
end)

Framework.CreateCallback('amb_server:getBodyBagStates', function(_, cb)
    cb(bodyBagStates)
end)

RegisterNetEvent('amb_server:pronounceWithBodyBag', function(targetId)
    local src = source

    targetId = tonumber(targetId)

    if Config.Medical and Config.Medical.EnablePronounceBodyBag ~= true then
        return
    end

    if not targetId or not isPlayerOnline(targetId) then
        return
    end

    if not exports.plt_ambulance_job:IsEMS(src) then
        return
    end

    local medicPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)

    if medicPed and medicPed > 0 and targetPed and targetPed > 0 then
        local distance = #(GetEntityCoords(medicPed) - GetEntityCoords(targetPed))

        if distance > 4.0 then
            return
        end
    end

    if bodyBagStates[targetId] then
        Framework.Notify(src, _L('target_already_bodybagged'), 'error')
        return
    end

    if not isPlayerDowned(targetId) then
        Framework.Notify(src, _L('target_not_downed'), 'error')
        return
    end

    setBodyBagState(targetId, true)

    Framework.Notify(src, _L('bodybag_applied'), 'success')
end)

RegisterNetEvent('amb_server:cacheHealth', function(health)
    local src = source
    local value = clampHealth(health)

    if not value then
        return
    end

    savedHealth[src] = value

    Framework.SetMetaData(src, 'amb_saved_health', value)
end)

Framework.CreateCallback('amb_server:getSavedHealth', function(src, cb)
    cb(clampHealth(Framework.GetMetaData(src, 'amb_saved_health')))
end)

Framework.CreateCallback('amb_server:isPlayerDowned', function(_, cb, targetId)
    targetId = tonumber(targetId)

    if Framework.HasAuthoritativeMedicalState() and targetId then
        cb(Framework.GetMedicalState(targetId) == Framework.MedicalState.LASTSTAND)
        return
    end

    cb(isPlayerDowned(targetId))
end)

Framework.CreateCallback('amb_server:getMedicalState', function(src, cb)
    if not Framework.HasAuthoritativeMedicalState() then
        cb(nil, 0)
        return
    end

    local state, startedAt = Framework.GetMedicalState(src)

    cb(state, getElapsedSeconds(startedAt))
end)

local function resyncMedicalState(src)
    src = tonumber(src)

    if not Framework.HasAuthoritativeMedicalState() or not src or not isPlayerOnline(src) then
        return
    end

    local state, startedAt = Framework.GetMedicalState(src)

    if state then
        setMedicalState(src, state, startedAt)
    end
end

if Framework.PlayerDataEvent then
    AddEventHandler(Framework.PlayerDataEvent, function(playerId, dataType)
        if dataType ~= 'metadata' and dataType ~= 'all' then
            return
        end

        playerId = tonumber(playerId)

        if not playerId then
            return
        end

        SetTimeout(50, function()
            if not isPlayerOnline(playerId) then
                return
            end

            local state, startedAt = Framework.GetMedicalState(playerId)
            local cached = lastSyncedStates[playerId]

            if cached and cached.state == state and cached.startedAt == startedAt then
                return
            end

            setMedicalState(playerId, state, startedAt)
        end)
    end)
end

if Framework.PlayerLoadedEvent then
    RegisterNetEvent(Framework.PlayerLoadedEvent, function(payload)
        local src = source

        if type(payload) == 'table' then
            if payload.PlayerData and payload.PlayerData.source then
                src = payload.PlayerData.source
            end
        elseif tonumber(payload) then
            src = tonumber(payload)
        end

        SetTimeout(750, function()
            resyncMedicalState(src)
        end)
    end)
end

CreateThread(function()
    Wait(2000)

    if not Framework.HasAuthoritativeMedicalState() then
        return
    end

    for _, playerId in ipairs(GetPlayers()) do
        resyncMedicalState(tonumber(playerId))
    end
end)

local function internalRevive(src)
    if not isPlayerOnline(src) then
        return false
    end

    -- A finished player cannot be revived; hospital respawn handles them.
    if exports.plt_ambulance_job:IsPlayerFinished(src) then
        return false
    end

    setBodyBagState(src, false)

    if Framework.HasAuthoritativeMedicalState() then
        setMedicalState(src, Framework.MedicalState.ALIVE)
    else
        downedFallback[src] = false

        pcall(function()
            Framework.SetLaststandStatus(src, false)
        end)

        pcall(function()
            Framework.SetDeathStatus(src, false)
        end)

        notifyClientRevive(src)
    end

    resetVitals(src)

    if not Framework.HasAuthoritativeMedicalState() then
        SetTimeout(500, function()
            if isPlayerOnline(src) then
                notifyClientRevive(src)
            end
        end)

        SetTimeout(1500, function()
            if isPlayerOnline(src) then
                notifyClientRevive(src)
            end
        end)
    end

    return true
end

exports('InternalRevive', internalRevive)
exports('IsPlayerDowned', isPlayerDowned)

local function killPlayer(src)
    if not src or not isPlayerOnline(src) then
        return false
    end

    if not Framework.HasAuthoritativeMedicalState() then
        downedFallback[src] = true
    end

    savedHealth[src] = 100

    saveHealth(src, 100)

    TriggerClientEvent('amb_client:KillPlayer', src)

    return true
end

RegisterNetEvent('amb_server:RevivePlayer', function(targetId)
    local src = source

    targetId = tonumber(targetId) or src

    local isEMS = exports.plt_ambulance_job:IsEMS(src)
    local hasPermission = Framework.HasPermission(src, Config.Permission)

    if hasPermission or isEMS then
        if exports.plt_ambulance_job:IsPlayerFinished(targetId) then
            Framework.Notify(src, _L('player_finished_other'), 'error')
            return
        end

        internalRevive(targetId)
    end
end)

RegisterNetEvent('hospital:server:RevivePlayer', function(targetId)
    if Framework.Type ~= 'qb' then
        return
    end

    local src = source
    local resolvedTarget = tonumber(targetId) or src

    local isEMS = exports.plt_ambulance_job:IsEMS(src)
    local hasPermission = Framework.HasPermission(src, Config.Permission)

    if hasPermission or isEMS then
        if exports.plt_ambulance_job:IsPlayerFinished(resolvedTarget) then
            Framework.Notify(src, _L('player_finished_other'), 'error')
            return
        end

        internalRevive(resolvedTarget)
    end
end)

local function resolveCommandTarget(src, args, commandName)
    if src ~= 0 and not Framework.HasPermission(src, Config.Permission) then
        Framework.Notify(src, _L('no_command_permission'), 'error')
        return nil
    end

    local targetId = (args[1] and tonumber(args[1])) or src

    if src == 0 and (not targetId or targetId == 0) then
        print(('^1[plt_ambulance] Usage from console: /%s [id]^7'):format(commandName))
        return nil
    end

    if not targetId or not isPlayerOnline(targetId) then
        if src ~= 0 then
            Framework.Notify(src, _L('player_not_found'), 'error')
        else
            print(('[plt_ambulance] /%s failed: invalid player id %s'):format(commandName, tostring(args[1])))
        end

        return nil
    end

    return targetId
end

RegisterCommand('revive', function(src, args)
    local targetId = resolveCommandTarget(src, args, 'revive')

    if not targetId then
        return
    end

    if exports.plt_ambulance_job:IsPlayerFinished(targetId) then
        if src ~= 0 then
            Framework.Notify(src, _L('player_finished_other'), 'error')
        end

        return
    end

    if not internalRevive(targetId) then
        if src ~= 0 then
            Framework.Notify(src, _L('player_not_found'), 'error')
        else
            print(('[plt_ambulance] /revive failed: player %s is not online'):format(tostring(targetId)))
        end
    end
end, false)

local function healPlayer(src)
    if not src or not isPlayerOnline(src) then
        return false
    end

    setBodyBagState(src, false)

    savedHealth[src] = 200

    if Framework.HasAuthoritativeMedicalState() then
        setMedicalState(src, Framework.MedicalState.ALIVE)
    else
        downedFallback[src] = false

        pcall(function()
            Framework.SetLaststandStatus(src, false)
        end)

        pcall(function()
            Framework.SetDeathStatus(src, false)
        end)
    end

    resetVitals(src)
    saveHealth(src, 200)

    TriggerClientEvent('amb_client:HealInjuries', src)

    return true
end

RegisterCommand('heal', function(src, args)
    local targetId = resolveCommandTarget(src, args, 'heal')

    if not targetId then
        return
    end

    healPlayer(targetId)
end, false)

RegisterCommand('kill', function(src, args)
    local targetId = resolveCommandTarget(src, args, 'kill')

    if not targetId then
        return
    end

    if killPlayer(targetId) then
        if src ~= 0 then
            Framework.Notify(src, ('Player %s killed.'):format(targetId), 'success')
        else
            print(('[plt_ambulance] Player %s killed.'):format(targetId))
        end
    end
end, false)

AddEventHandler('txAdmin:events:healedPlayer', function(payload)
    if GetInvokingResource() ~= 'monitor' or type(payload) ~= 'table' then
        return
    end

    local targetId = tonumber(payload.id)

    if not targetId then
        return
    end

    if targetId == -1 then
        for _, playerId in ipairs(GetPlayers()) do
            healPlayer(tonumber(playerId))
        end

        return
    end

    healPlayer(targetId)
end)

AddEventHandler('txAdmin:events:revivedPlayer', function(payload)
    if GetInvokingResource() ~= 'monitor' or type(payload) ~= 'table' then
        return
    end

    local targetId = tonumber(payload.id)

    if not targetId then
        return
    end

    if targetId == -1 then
        for _, playerId in ipairs(GetPlayers()) do
            internalRevive(tonumber(playerId))
        end

        return
    end

    internalRevive(targetId)
end)

RegisterNetEvent('amb_server:HealPlayer', function(targetId, bodyPart, level)
    local src = source
    local requiredItem = level >= 2 and 'plt_surgical_kit' or 'plt_medkit'

    if Inventory.RemoveItem(src, requiredItem, 1) then
        TriggerClientEvent('amb_client:HealPart', targetId, bodyPart, level)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source

    saveHealth(src)
    setBodyBagState(src, false)

    savedHealth[src] = nil
    deathTickets[src] = nil
    lastSyncedStates[src] = nil
    downedFallback[src] = nil
end)

Framework.CreateUseableItem('plt_bandage', function(src)
    if not Framework.GetPlayer(src) then
        return
    end

    if isPlayerDowned(src) then
        Framework.Notify(src, _L('cannot_use_incapacitated'), 'error')
        return false
    end

    if Inventory.RemoveItem(src, 'plt_bandage', 1) then
        TriggerClientEvent('amb_client:selfBandage', src)
        return true
    end

    return false
end)

for itemName, eventName in pairs(MEDICATION_EVENTS) do
    if itemName ~= 'plt_bandage' then
        Framework.CreateUseableItem(itemName, function(src, item)
            if not Framework.GetPlayer(src) then
                return
            end

            if isPlayerDowned(src) and itemName ~= 'iak_wheelchair' then
                Framework.Notify(src, _L('cannot_use_incapacitated'), 'error')
                return false
            end

            local metadata = item and (item.info or item.metadata)
            local removed = true

            if not REUSABLE_ITEMS[itemName] then
                removed = Inventory.RemoveItem(src, itemName, 1)
            end

            if not removed then
                return false
            end

            if eventName == 'amb_client:useWheelchair' then
                TriggerClientEvent(eventName, src, metadata and metadata.duration or nil)
            else
                TriggerClientEvent(eventName, src, itemName, metadata)
            end

            return true
        end)
    end
end

for itemName in pairs(XRAY_CLIPBOARD_ITEMS) do
    Framework.CreateUseableItem(itemName, function(src)
        if not Framework.GetPlayer(src) then
            return
        end

        if isPlayerDowned(src) then
            Framework.Notify(src, _L('cannot_use_incapacitated'), 'error')
            return false
        end

        TriggerClientEvent('amb_client:useXrayClipboard', src, itemName)

        return true
    end)
end

RegisterNetEvent('amb_server:consumeMedication', function(itemName, slot, isOxUse, metadata)
    local src = source

    if not Framework.GetPlayer(src) then
        return
    end

    local eventName = MEDICATION_EVENTS[itemName]

    if not eventName then
        return
    end

    if isPlayerDowned(src) and itemName ~= 'iak_wheelchair' then
        Framework.Notify(src, _L('cannot_use_incapacitated'), 'error')
        return
    end

    local requiresRemoval = not REUSABLE_ITEMS[itemName]
    local removed = true

    if requiresRemoval then
        removed = Inventory.RemoveItem(src, itemName, 1, slot)
    end

    if requiresRemoval and not removed and isOxUse == true and Bridge.Inventory == 'ox' then
        removed = true
    end

    if not removed then
        Framework.Notify(src, 'Failed to use item. Try again.', 'error')
        return
    end

    if eventName == 'amb_client:useMedication' or eventName == 'amb_client:toggleWalkingAid' then
        TriggerClientEvent(eventName, src, itemName, nil)
    elseif eventName == 'amb_client:useWheelchair' then
        if isOxUse == true then
            return
        end

        local duration = (type(metadata) == 'table' and metadata.duration) or nil

        TriggerClientEvent(eventName, src, duration)
    else
        TriggerClientEvent(eventName, src)
    end
end)

RegisterNetEvent('amb_server:giveXrayClipboardItem', function(targetId, itemName)
    targetId = tonumber(targetId)

    if not targetId then
        return
    end

    if type(itemName) ~= 'string' or not XRAY_CLIPBOARD_ITEMS[itemName] then
        return
    end

    Inventory.AddItem(targetId, itemName, 1)
end)

