if Config.Debug then
    print('^2[Dispatch]^7 Dispatch system loaded.')
end

--[[
    ------------------------------------------------------------
    EMS dispatch menu (F6)
    ------------------------------------------------------------
    Pressing F6 (or /dispatch) opens the on-screen request list and focuses the
    mouse so a medic can click a request. An open request shows an Accept
    button; once somebody accepts it the row turns GREEN for every medic and
    nobody else can accept or cancel it. Only the medic who accepted gets a
    Cancel button next to the Accept label, and pressing it hands the call
    back (the row is removed from their screen). The list scrolls when many
    requests come in.

    While a medic holds a claim nothing is drawn at the top of the screen -
    the patient is simply marked on the map with a blip + GPS route until the
    patient is revived or the claim is cancelled.
]]

local menuOpen = false
local knownCalls = {}       -- newest first
local dismissedCalls = {}   -- ids this medic cancelled; hidden from their list

local myClaimedCall = nil
local patientBlip = nil
local patientBlipSrc = 0

local function myServerId()
    return GetPlayerServerId(PlayerId())
end

local function findLocalCall(callId)
    if callId == nil then
        return nil
    end

    local wanted = tostring(callId)

    for _, call in ipairs(knownCalls) do
        if tostring(call.id) == wanted then
            return call
        end
    end

    return nil
end

local function callerNameOf(call)
    local src = tonumber(call and call.source) or 0

    if src > 0 then
        local index = GetPlayerFromServerId(src)

        if index and index ~= -1 and NetworkIsPlayerActive(index) then
            local name = GetPlayerName(index)

            if name and tostring(name) ~= '' then
                return tostring(name)
            end
        end

        return 'Player #' .. tostring(src)
    end

    return 'Player'
end

-- ---------------------------------------------------------------
-- Patient blip (kept until revive or cancel)
-- ---------------------------------------------------------------
local function removePatientBlip()
    if patientBlip and DoesBlipExist(patientBlip) then
        RemoveBlip(patientBlip)
    end

    patientBlip = nil
    patientBlipSrc = 0
end

local function createPatientBlip(call)
    removePatientBlip()

    local coords = call and call.coords or {}
    local x = tonumber(coords.x)
    local y = tonumber(coords.y)
    local z = tonumber(coords.z) or 0.0

    if not (x and y) then
        return
    end

    patientBlipSrc = tonumber(call.source) or 0
    patientBlip = AddBlipForCoord(x, y, z)

    SetBlipSprite(patientBlip, 61)
    SetBlipColour(patientBlip, 1)
    SetBlipScale(patientBlip, 0.9)
    SetBlipAsShortRange(patientBlip, false)
    SetBlipRoute(patientBlip, true)
    SetBlipRouteColour(patientBlip, 1)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(_L('dispatch_blip_patient'))
    EndTextCommandSetBlipName(patientBlip)

    if Config.Debug then
        print('^2[Dispatch]^7 Patient blip created for call ' .. tostring(call.id))
    end
end

-- Keep the blip glued to the patient while we can actually see them.
CreateThread(function()
    while true do
        Wait(1000)

        if patientBlip and DoesBlipExist(patientBlip) and patientBlipSrc > 0 then
            local target = GetPlayerFromServerId(patientBlipSrc)

            if target and target ~= -1 and NetworkIsPlayerActive(target) then
                local ped = GetPlayerPed(target)

                if ped and ped ~= 0 and DoesEntityExist(ped) then
                    local coords = GetEntityCoords(ped)

                    SetBlipCoords(patientBlip, coords.x, coords.y, coords.z)
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------
-- The F6 menu
-- ---------------------------------------------------------------
local function buildMenuPayload()
    local rows = {}

    for _, call in ipairs(knownCalls) do
        local id = call.id

        if not dismissedCalls[tostring(id)] and call.status ~= 'completed' then
            rows[#rows + 1] = {
                id = id,
                caller = callerNameOf(call),
                title = call.title or 'Medical Request',
                location = call.location or '',
                claimed = call.claimedBy ~= nil,
                mine = myClaimedCall ~= nil and tostring(myClaimedCall.id) == tostring(id),
                claimedName = call.claimedName or ''
            }
        end
    end

    return rows
end

local function refreshDispatchMenu()
    if not menuOpen then
        return
    end

    SendNUIMessage({
        action = 'amb_dispatchMenu',
        open = true,
        calls = buildMenuPayload()
    })
end

local function openDispatchMenu()
    menuOpen = true

    SendNUIMessage({
        action = 'amb_dispatchMenu',
        open = true,
        calls = buildMenuPayload()
    })

    SetNuiFocus(true, true)
end

local function closeDispatchMenu()
    menuOpen = false

    SendNUIMessage({
        action = 'amb_dispatchMenu',
        open = false
    })

    SetNuiFocus(false, false)
end

local function toggleDispatchMenu()
    if menuOpen then
        closeDispatchMenu()
    else
        openDispatchMenu()
    end
end

local function tryOpenDispatchMenu()
    -- Non-EMS players pressing the key get nothing at all: no menu, and no
    -- "you are not a medic" notification either.
    if exports.plt_ambulance_job:IsEMS() then
        toggleDispatchMenu()
    end
end

-- F6 opens the dispatch request list for medics.
RegisterKeyMapping('amb_dispatch_menu', 'Open EMS dispatch menu', 'keyboard', 'F6')

RegisterCommand('amb_dispatch_menu', function()
    tryOpenDispatchMenu()
end, false)

RegisterCommand('dispatch', function()
    tryOpenDispatchMenu()
end, false)

RegisterNUICallback('amb_menuClose', function(_, cb)
    closeDispatchMenu()
    cb('ok')
end)

-- ---------------------------------------------------------------
-- Accepting / cancelling from the menu
-- ---------------------------------------------------------------
local function requestClaim(callId)
    if Config.Debug then
        print('^2[Dispatch]^7 Requesting claim on call ' .. tostring(callId))
    end

    TriggerServerEvent('amb_server:claimDispatchCall', callId)
end

RegisterNUICallback('amb_menuAccept', function(data, cb)
    local callId = data and data.id or nil

    if callId then
        requestClaim(callId)
    end

    cb('ok')
end)

RegisterNUICallback('amb_menuCancel', function(data, cb)
    local callId = data and data.id or (myClaimedCall and myClaimedCall.id)

    -- The server only honours a release from the current owner, so a cancel
    -- from anybody else is simply ignored there.
    if callId then
        TriggerServerEvent('amb_server:releaseDispatchCall', callId)
    end

    cb('ok')
end)

RegisterNetEvent('amb_client:dispatchClaimResult', function(ok, reason, callId, extra, extra2)
    if ok then
        local call = (type(extra2) == 'table' and extra2) or findLocalCall(callId)

        if type(call) == 'table' and call.id then
            local stored = findLocalCall(call.id)

            if not stored then
                table.insert(knownCalls, 1, call)
                stored = call
            else
                stored.claimedBy = call.claimedBy or myServerId()
                stored.claimedName = call.claimedName
                stored.status = 'claimed'
                stored.coords = call.coords or stored.coords
                stored.source = call.source or stored.source
            end

            myClaimedCall = stored
            createPatientBlip(stored)

            local coords = stored.coords or {}

            SetNewWaypoint(tonumber(coords.x) or 0.0, tonumber(coords.y) or 0.0)
        end

        Framework.Notify(_L('dispatch_call_accepted', {
            id = tostring(call and call.id or callId)
        }), 'success')

        refreshDispatchMenu()

        return
    end

    if reason == 'taken' then
        -- `extra` carries the current owner's name on a refused claim.
        Framework.Notify(_L('dispatch_call_taken', {
            name = tostring(extra or _L('dispatch_unknown_medic'))
        }), 'error')
    elseif reason == 'notfound' then
        Framework.Notify(_L('dispatch_call_gone'), 'error')
    elseif reason == 'unauthorized' then
        Framework.Notify(_L('authorized_only'), 'error')
    else
        Framework.Notify(_L('dispatch_claim_failed'), 'error')
    end
end)

-- Somebody else took it: the row goes green for us and any blip we had drops.
RegisterNetEvent('amb_client:dispatchCallClaimed', function(callId, bySrc, byName, call)
    if bySrc ~= myServerId() then
        local stored = findLocalCall(callId)

        if stored then
            stored.claimedBy = bySrc
            stored.claimedName = byName
            stored.status = 'claimed'
        end

        if myClaimedCall and tostring(myClaimedCall.id) == tostring(callId) then
            myClaimedCall = nil
        end

        if patientBlipSrc > 0 and call and tonumber(call.source) == patientBlipSrc then
            removePatientBlip()
        end

        Framework.Notify(_L('dispatch_call_taken', {
            name = tostring(byName or _L('dispatch_unknown_medic'))
        }), 'primary')
    end

    refreshDispatchMenu()
end)

RegisterNetEvent('amb_client:dispatchCallReleased', function(callId)
    local stored = findLocalCall(callId)

    if stored then
        stored.claimedBy = nil
        stored.claimedName = nil
        stored.status = 'open'
    end

    if myClaimedCall and tostring(myClaimedCall.id) == tostring(callId) then
        myClaimedCall = nil
        removePatientBlip()

        -- I cancelled my own claim: the row leaves my screen entirely.
        dismissedCalls[tostring(callId)] = true
    end

    refreshDispatchMenu()
end)

RegisterNetEvent('amb_client:dispatchCallCompleted', function(callId)
    for index = #knownCalls, 1, -1 do
        if tostring(knownCalls[index].id) == tostring(callId) then
            table.remove(knownCalls, index)
        end
    end

    dismissedCalls[tostring(callId)] = nil

    if myClaimedCall and tostring(myClaimedCall.id) == tostring(callId) then
        myClaimedCall = nil
    end

    removePatientBlip()
    refreshDispatchMenu()
end)

-- /donecall - the patient is treated, close the call out
RegisterCommand('donecall', function(_, args)
    local callId = tonumber(args and args[1]) or (myClaimedCall and tonumber(myClaimedCall.id))

    if not callId then
        Framework.Notify(_L('dispatch_no_active_call'), 'error')
        return
    end

    TriggerServerEvent('amb_server:completeDispatchCall', callId)
    myClaimedCall = nil
    removePatientBlip()
end, false)

exports('GetClaimedCall', function()
    return myClaimedCall
end)

exports('ClearPatientBlip', removePatientBlip)

-- ---------------------------------------------------------------
-- Filing a call (death screen / exports)
-- ---------------------------------------------------------------
local function getStreetLabel(coords)
    local streetHash, crossingHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local label = GetStreetNameFromHashKey(streetHash)

    if crossingHash ~= 0 then
        label = label .. ' / ' .. GetStreetNameFromHashKey(crossingHash)
    end

    return label
end

function SendDeathDispatch()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local locationName = getStreetLabel(coords)

    if Config.Debug then
        print('^2[Dispatch]^7 Sending death dispatch for location: ' .. locationName)
    end

    TriggerServerEvent('amb_server:sendDispatchCall', {
        title = _L('patient_downed'),
        coords = { x = coords.x, y = coords.y },
        locationName = locationName
    })
end

exports('SendDeathDispatch', function(payload)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local locationName = getStreetLabel(coords)

    local call = (type(payload) == 'table' and payload) or {}

    call.title = call.title or _L('patient_downed')
    call.coords = call.coords or { x = coords.x, y = coords.y }
    call.locationName = call.locationName or locationName

    TriggerServerEvent('amb_server:sendDispatchCall', call)
end)

RegisterNetEvent('amb_client:onPlayerRevive', function()
    -- I am back up, so any call filed against me is finished. The server closes
    -- it and broadcasts amb_client:dispatchCallCompleted, which is what removes
    -- the responding medic's blip - doing it here instead would wipe a medic's
    -- own blip every time *they* got revived.
    TriggerServerEvent('amb_server:dispatchPatientRecovered')
end)

RegisterNetEvent('amb_client:addDispatchCall', function(call)
    if type(call) == 'table' and call.id then
        table.insert(knownCalls, 1, call)

        if #knownCalls > 50 then
            table.remove(knownCalls)
        end
    end

    refreshDispatchMenu()

    -- Audible cue so on-duty EMS notice a new call even with the menu closed.
    PlaySoundFrontend(-1, 'Event_Start_Text', 'GTAO_FM_Events_Soundset', true)
end)
