--[[
    Downed-player interactions.

    While a player is unconscious / dead, other players can (ALT on ox_target,
    or the qb-target key) Search them (opens their ox_inventory via the server,
    rate-limited by a cooldown) or Carry them. The downed state of every player
    is synced from the server via amb_client:syncDownedPlayer.

    CARRY ARCHITECTURE: the carrier only plays its own carry anim and tells the
    server, which relays amb_client:setCarried to the PATIENT. The patient then
    attaches ITS OWN ped to the carrier on its own client. Because each client
    owns its own ped, the self-attach is authoritative and syncs cleanly - the
    old carrier-side attach of a remote ped is what froze both players.
]]

local DownedPlayers = {}

RegisterNetEvent('amb_client:syncDownedPlayer', function(src, downed)
    src = tonumber(src)

    if not src then
        return
    end

    if downed then
        DownedPlayers[src] = true
    else
        DownedPlayers[src] = nil
    end
end)

local function getPedServerId(ped)
    local playerIndex = NetworkGetPlayerIndexFromPed(ped)

    if playerIndex == -1 or not NetworkIsPlayerActive(playerIndex) then
        return 0
    end

    return GetPlayerServerId(playerIndex)
end

local function isDownedPed(ped)
    local id = getPedServerId(ped)

    return id > 0 and DownedPlayers[id] == true
end

-- ---------------------------------------------------------------
-- Carry
-- ---------------------------------------------------------------
local CARRY_CARRIER_DICT = 'missfinale_c2mcs_1'
local CARRY_CARRIER_ANIM = 'fin_c2_mcs_1_camman'

local carryingSrc = 0
local carryHintShown = false

-- Bottom-of-screen guide: "G | Put Down Player" while carrying.
local function setCarryHint(show)
    show = show == true

    if carryHintShown == show then
        return
    end

    carryHintShown = show

    SendNUIMessage({
        action = 'amb_carryHint',
        show = show
    })
end

local function loadDict(dict)
    RequestAnimDict(dict)

    local waited = 0
    while not HasAnimDictLoaded(dict) and waited < 1500 do
        Wait(50)
        waited = waited + 50
    end
end

local function dropCarry()
    if carryingSrc == 0 then
        return
    end

    ClearPedTasks(PlayerPedId())

    -- the patient detaches itself when it receives setCarried(false).
    TriggerServerEvent('amb_server:dropCarried', carryingSrc)

    carryingSrc = 0
    setCarryHint(false)

    Framework.Notify(_L('carry_dropped'), 'success')
end

local function startCarry(ped)
    if carryingSrc ~= 0 then
        Framework.Notify(_L('carry_already'), 'error')
        return
    end

    if not isDownedPed(ped) then
        Framework.Notify(_L('target_not_downed'), 'error')
        return
    end

    local carrier = PlayerPedId()

    loadDict(CARRY_CARRIER_DICT)

    TaskPlayAnim(carrier, CARRY_CARRIER_DICT, CARRY_CARRIER_ANIM, 8.0, -8.0, -1, 49, 0, false, false, false)

    carryingSrc = getPedServerId(ped)

    TriggerServerEvent('amb_server:carryDowned', carryingSrc)

    setCarryHint(true)

    Framework.Notify(_L('carry_started'), 'success')
end

exports('DropCarry', dropCarry)

-- Auto-drop if the carried player stands back up or disappears.
CreateThread(function()
    while true do
        Wait(1000)

        if carryingSrc ~= 0 and not DownedPlayers[carryingSrc] then
            dropCarry()
        end
    end
end)

-- [G] drop the carried player. While carrying, G puts the patient down and
-- the on-screen guide (amb_carryHint) tells the player so.
CreateThread(function()
    while true do
        if carryingSrc ~= 0 and IsControlJustPressed(0, 47) then
            dropCarry()
        end

        Wait(0)
    end
end)

-- ---------------------------------------------------------------
-- Target options
-- ---------------------------------------------------------------
-- Searching a downed player is NOT instant: a progress bar runs for
-- Config.Search.Duration (15s by default), then a "Wait 1 second..."
-- notification is shown and only after Config.Search.OpenDelay the server
-- is asked to open the target's inventory.
local function searchAction(ped)
    local id = getPedServerId(ped)

    if not (id > 0) then
        return
    end

    local duration = tonumber(Config.Search and Config.Search.Duration) or 15000
    local openDelay = tonumber(Config.Search and Config.Search.OpenDelay) or 1000

    local completed = Framework.ProgressBar(_L('searching_player'), duration, {
        dict = 'amb@medic@standing@kneel@base',
        anim = 'base'
    })

    if not completed then
        Framework.Notify(_L('search_cancelled'), 'error')

        return
    end

    -- The target may have been revived / finished while we were searching.
    if not DownedPlayers[id] then
        Framework.Notify(_L('target_not_downed'), 'error')

        return
    end

    Framework.Notify(_L('search_wait_one_second'), 'success')

    Wait(openDelay)

    TriggerServerEvent('amb_server:searchDowned', id)
end

local function registerTargets()
    if Config.Search.Enabled == false and Config.Carry.Enabled == false then
        return
    end

    local function canInteractDowned(entity)
        local id = getPedServerId(entity)

        return entity ~= PlayerPedId() and isDownedPed(entity) and carryingSrc == 0
            and not exports.plt_ambulance_job:IsPlayerFinished(id)
    end

    if GetResourceState('ox_target') == 'started' then
        local options = {}

        if Config.Search.Enabled ~= false then
            options[#options + 1] = {
                name = 'amb_search_downed',
                label = _L('target_search_downed'),
                icon = 'fa-solid fa-magnifying-glass',
                distance = 2.0,
                canInteract = canInteractDowned,
                onSelect = function(data) searchAction(data.entity) end
            }
        end

        if Config.Carry.Enabled ~= false then
            options[#options + 1] = {
                name = 'amb_carry_downed',
                label = _L('target_carry_downed'),
                icon = 'fa-solid fa-person',
                distance = 2.0,
                canInteract = canInteractDowned,
                onSelect = function(data) startCarry(data.entity) end
            }
        end

        exports.ox_target:addGlobalPlayer(options)

        return
    end

    if GetResourceState('qb-target') == 'started' then
        local options = {}

        if Config.Search.Enabled ~= false then
            options[#options + 1] = {
                name = 'amb_search_downed',
                label = _L('target_search_downed'),
                icon = 'fa-solid fa-magnifying-glass',
                canInteract = canInteractDowned,
                action = function(entity) searchAction(entity) end
            }
        end

        if Config.Carry.Enabled ~= false then
            options[#options + 1] = {
                name = 'amb_carry_downed',
                label = _L('target_carry_downed'),
                icon = 'fa-solid fa-person',
                canInteract = canInteractDowned,
                action = function(entity) startCarry(entity) end
            }
        end

        exports['qb-target']:AddGlobalPlayer({ options = options, distance = 2.0 })
    end
end

-- Registered at load; the GetResourceState guards above make it safe to call
-- even when no target resource is present.
registerTargets()
