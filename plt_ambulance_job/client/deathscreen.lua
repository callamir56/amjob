local deathScreenActive = false
local deathTimer = 0
local emsCalled = false
local deathMode = 'dead'
local deathStartTime = 0
-- ONE fixed end timestamp for the whole death (set once when the death
-- screen opens, adjusted once from the server clock). Both the unconscious
-- countdown and the finished display derive from it, so the timer can never
-- reset - not every frame, not on FINISH. Never recreated in any loop.
local deathEndTime = 0
local transportDelay = 120
local mercyFinished = false
local bleedOutSent = false
local useBuiltInDeathscreen = not Config.Deathscreen or Config.Deathscreen.UseBuiltIn ~= false
local nextVehicleLockTime = 0

local DISABLED_CONTROLS = { 73, 177, 322, 30, 31, 32, 33, 34, 35, 21, 22, 24, 25 }
local ENABLED_CONTROLS = { 1, 2, 245, 246, 47, 199, 200 }

-- True while the rebuilt death system (client/death.lua) is active.
local function deathSystemActive()
    return Config.DisableDeathSystem ~= true
        and not (Config.DeathSystem and Config.DeathSystem.Enabled == false)
end

local function deathTimerSeconds()
    return math.max(1, tonumber((Config.DeathSystem and Config.DeathSystem.DeathTimer)
        or (Config.Health and Config.Health.DeathTimer)) or 600)
end

local function giveUpSeconds()
    return math.max(0, tonumber(Config.DeathSystem and Config.DeathSystem.GiveUpTime) or 60)
end

local function weaponLabelOf(hash)
    local label = nil

    pcall(function()
        label = exports.plt_ambulance_job:GetWeaponLabel(hash)
    end)

    return label or _L('ui_weapon_unknown')
end

-- Normalises killer info (client captured or server validated) into a
-- display-ready table: { src, name, weapon } - never nil / false in the UI.
local function displayKillerInfo(info)
    if type(info) ~= 'table' then
        info = {}
    end

    local src = tonumber(info.src) or 0
    local name = info.name

    if not name or tostring(name) == '' then
        name = 'UNKNOWN'
    end

    return {
        src = src,
        name = name,
        weapon = weaponLabelOf(info.weaponHash)
    }
end

local function isPlayerDowned()
    local downed = false

    pcall(function()
        downed = exports.plt_ambulance_job:IsPlayerDowned() == true
    end)

    return downed
end

local function isPedDowned(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false
    end

    if deathScreenActive and isPlayerDowned() then
        return true
    end

    if IsPedDeadOrDying(ped, true) then
        return true
    end

    if GetEntityHealth(ped) <= 100 then
        return true
    end

    if IsPedRagdoll(ped) then
        return true
    end

    return false
end

exports('IsDeathScreenActive', function()
    return deathScreenActive == true
end)

-- Hospital transport is NOT part of the current death-system phase: it is
-- only available when Config.DeathSystem.AllowHospitalTransport = true.
local function hospitalTransportAllowed()
    if Config.DeathSystem then
        return Config.DeathSystem.AllowHospitalTransport == true
    end

    return true
end

local function applyDeathControls()
    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    -- UNCONSCIOUS: block combat / vehicle / action controls ONLY. Everything
    -- else - look, move, and in particular the LB Phone key - keeps working.
    -- (The body is a physics ragdoll, so movement inputs cannot move it
    -- anyway.) DisableAllControlActions must NOT be used here: it would
    -- prevent LB Phone from opening.
    -- [G] (47) CALL EMS stays disabled only until EMS is called, so the
    -- IsDisabledControlPressed detection below keeps working; afterwards the
    -- key is freed for the phone or anything else. [H] (74) give-up and
    -- [Y] (246) transport stay disabled for the same detection.
    if deathMode == 'unconscious' and not mercyFinished then
        for _, control in ipairs({ 21, 22, 23, 24, 25, 36, 37, 44, 45, 71, 72,
            73, 74, 75, 140, 141, 142, 143, 246, 257, 263, 264 }) do
            DisableControlAction(0, control, true)
        end

        DisableControlAction(0, 47, not emsCalled)

        return
    end

    DisableAllControlActions(0)

    for _, control in ipairs(DISABLED_CONTROLS) do
        DisableControlAction(0, control, true)
    end

    -- A finished player gets NO enabled controls at all: they cannot call EMS
    -- and cannot transport themselves to the hospital.
    if not mercyFinished then
        for _, control in ipairs(ENABLED_CONTROLS) do
            EnableControlAction(0, control, true)
        end
    end

    local now = GetGameTimer()

    if now < nextVehicleLockTime then
        return
    end

    if not IsPedInAnyVehicle(ped, false) then
        return
    end

    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
        SetVehicleUndriveable(vehicle, true)
        SetVehicleEngineOn(vehicle, false, true, true)
        SetVehicleForwardSpeed(vehicle, 0.0)
        SetEntityVelocity(vehicle, 0.0, 0.0, 0.0)
    end

    nextVehicleLockTime = now + 400
end

local function toggleDeathScreen(show, time, mode)
    if not useBuiltInDeathscreen then
        return
    end

    SendNUIMessage({
        action = 'amb_toggleDeathScreen',
        show = show,
        time = time or 0,
        mode = mode or deathMode,
        transportDelay = transportDelay
    })

    SendNUIMessage({
        action = 'amb_transportAllowed',
        show = hospitalTransportAllowed()
    })

    SetNuiFocus(false, false)
end

local function getClosestCheckInBed()
    if not (DepartmentData and DepartmentData.nodes) then
        return nil
    end

    local coords = GetEntityCoords(PlayerPedId())
    local closestBed = nil
    local closestDistance = 999999.0

    for _, node in ipairs(DepartmentData.nodes) do
        if node.type == 'check_in' and node.coordsList and node.coordsList.bed and node.coordsList.bed.x then
            local bed = node.coordsList.bed
            local distance = #(coords - vector3(bed.x, bed.y, bed.z))

            if distance < closestDistance then
                closestDistance = distance
                closestBed = bed
            end
        end
    end

    return closestBed
end

local function transportToHospital(bed)
    local ped = PlayerPedId()

    SetEntityCoords(ped, bed.x, bed.y, bed.z, false, false, false, false)
    SetEntityHeading(ped, bed.h or 0.0)

    TriggerServerEvent('amb_server:clearInventoryOnHospitalRespawn')

    exports.plt_ambulance_job:RevivePlayer()

    CreateThread(function()
        Wait(200)
        TriggerEvent('amb_client:playWakeUpAnimation')
    end)

    Framework.Notify(_L('transported_to_hospital'), 'success')
end

local function callEMS()
    -- Finished players cannot request a medic. Nobody is coming for them.
    if mercyFinished then
        return
    end

    emsCalled = true

    if SendDeathDispatch then
        SendDeathDispatch()
    end

    Framework.Notify(_L('ems_notified'), 'success')

    SendNUIMessage({ action = 'amb_emsCalled' })
end

RegisterNetEvent('amb_client:onPlayerDeath', function(_, elapsedSeconds, medicalState, killerInfo)
    if not useBuiltInDeathscreen or deathScreenActive then
        return
    end

    deathScreenActive = true

    TriggerServerEvent('plt_mdt_ems:server:onPlayerDeath', true)

    deathMode = medicalState == Framework.MedicalState.LASTSTAND and 'unconscious' or 'dead'
    emsCalled = false

    SendNUIMessage({
        action = 'amb_killerInfo',
        info = displayKillerInfo(killerInfo)
    })

    local elapsed = math.max(0, tonumber(elapsedSeconds) or 0)

    bleedOutSent = medicalState == Framework.MedicalState.DEAD
    deathTimer = math.max(0, (deathSystemActive() and deathTimerSeconds()
        or (tonumber(Config.Health.DeathTimer) or 300)) - math.floor(elapsed))
    deathStartTime = GetGameTimer() - math.floor(elapsed * 1000)
    deathEndTime = 0
    transportDelay = tonumber(Config.Health.HospitalTransportDelay) or 120

    toggleDeathScreen(true, deathTimer, deathMode)

    -- Accurate, CONTINUOUS countdown: the remaining time is recomputed from
    -- ONE fixed end timestamp every tick (GetGameTimer is engine time, so
    -- lag / freezes cannot drift it), and the start point is the
    -- server-authoritative downed time. The timestamp is set once here and
    -- adjusted once from the server - never recreated, never reset, and the
    -- countdown keeps ticking through FINISH (finished mode shows the same
    -- clock running out, it does not restart it).
    CreateThread(function()
        local durationSeconds = deathSystemActive()
            and deathTimerSeconds()
            or (tonumber(Config.Health.DeathTimer) or 300)

        deathEndTime = GetGameTimer() + durationSeconds * 1000

        -- Ask the server how long we have been downed already.
        if deathSystemActive() then
            Framework.TriggerCallback('amb_server:getDeathElapsed', function(serverElapsed)
                if not deathScreenActive then
                    return
                end

                local elapsed = math.max(0, tonumber(serverElapsed) or 0)

                deathEndTime = GetGameTimer() + math.max(0, (durationSeconds - elapsed)) * 1000
            end)
        end

        local lastSent = -1

        while deathScreenActive do
            Wait(250)

            local remaining = math.ceil((deathEndTime - GetGameTimer()) / 1000)

            if remaining < 0 then
                remaining = 0
            end

            if remaining ~= lastSent then
                lastSent = remaining

                SendNUIMessage({
                    action = 'amb_updateDeathTimer',
                    time = remaining
                })
            end

            -- Bleed out only applies while still downed: a finished player
            -- already has their outcome, the server handles the respawn.
            if remaining <= 0 and not bleedOutSent and not mercyFinished then
                bleedOutSent = true

                if deathSystemActive() then
                    -- Bleed out: the server verifies the elapsed time.
                    TriggerServerEvent('amb_server:finishPlayer', 'timer')
                else
                    TriggerServerEvent('amb_server:bleedOut')

                    if deathMode ~= 'dead' then
                        deathMode = 'dead'

                        toggleDeathScreen(true, 0, deathMode)

                        if emsCalled then
                            SendNUIMessage({ action = 'amb_emsCalled' })
                        end
                    end
                end
            end
        end
    end)

    CreateThread(function()
        local callEMSTimer = Config.Health.CallEMSTimer or 60
        local callKeyHeld = false
        local transportKeyHeld = false
        local giveUpKeyHeld = false

        while deathScreenActive do
            Wait(0)

            applyDeathControls()

            pcall(function()
                exports.plt_ambulance_job:EnforceDownedState()
            end)

            local callPressed = IsDisabledControlPressed(0, 47)

            if callPressed and not callKeyHeld then
                callKeyHeld = true

                -- Finished players cannot request a medic or transport
                -- themselves; they just lie there until the timer runs out.
                if not emsCalled and not mercyFinished then
                    local elapsed = (GetGameTimer() - deathStartTime) / 1000

                    if elapsed >= callEMSTimer then
                        callEMS()
                    else
                        Framework.Notify(_L('wait_before_calling', {
                            seconds = math.ceil(callEMSTimer - elapsed)
                        }), 'error')
                    end
                end
            elseif not callPressed then
                callKeyHeld = false
            end

            local transportPressed = IsDisabledControlPressed(0, 246)

            if transportPressed and not transportKeyHeld then
                transportKeyHeld = true

                if not mercyFinished and hospitalTransportAllowed() then
                    local elapsed = (GetGameTimer() - deathStartTime) / 1000

                    if elapsed >= transportDelay then
                        local bed = getClosestCheckInBed()

                        if bed then
                            transportToHospital(bed)
                        else
                            Framework.Notify(_L('no_checkin_bed'), 'error')
                        end
                    else
                        Framework.Notify(_L('transport_available_in', {
                            seconds = math.ceil(transportDelay - elapsed)
                        }), 'error')
                    end
                end
            elseif not transportPressed then
                transportKeyHeld = false
            end

            -- GIVE UP on [H] (74): same gates as the NUI button. The NUI
            -- button only works while the cursor is active, so the key is
            -- the reliable way to trigger it. The server re-validates the
            -- elapsed time before accepting the give-up.
            local giveUpPressed = IsDisabledControlPressed(0, 74)

            if giveUpPressed and not giveUpKeyHeld then
                giveUpKeyHeld = true

                if not mercyFinished and deathSystemActive() then
                    local elapsed = (GetGameTimer() - deathStartTime) / 1000
                    local needed = giveUpSeconds()

                    if elapsed >= needed then
                        TriggerServerEvent('amb_server:giveUp')
                    else
                        Framework.Notify(_L('give_up_unavailable'), 'error')
                    end
                end
            elseif not giveUpPressed then
                giveUpKeyHeld = false
            end
        end
    end)
end)

RegisterNetEvent('amb_client:onPlayerRevive', function()
    if not useBuiltInDeathscreen then
        return
    end

    deathScreenActive = false

    TriggerServerEvent('plt_mdt_ems:server:onPlayerDeath', false)

    emsCalled = false
    bleedOutSent = false
    mercyFinished = false
    deathMode = 'dead'
    deathEndTime = 0

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) and IsPedInAnyVehicle(ped, false) then
        local vehicle = GetVehiclePedIsIn(ped, false)

        if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
            SetVehicleUndriveable(vehicle, false)
        end
    end

    toggleDeathScreen(false)
end)

-- Fired by the crawl phase once the player passes out, so the EMS request goes
-- out automatically instead of waiting for the manual call key.
AddEventHandler('amb_client:markEmsCalled', function()
    if not emsCalled then
        callEMS()
    end
end)

RegisterNUICallback('amb_callEMS', function(_, cb)
    if not useBuiltInDeathscreen or not deathScreenActive or emsCalled or mercyFinished then
        cb('ok')
        return
    end

    local callEMSTimer = Config.Health.CallEMSTimer or 60
    local elapsed = (GetGameTimer() - deathStartTime) / 1000

    if elapsed < callEMSTimer then
        Framework.Notify(_L('wait_before_calling', {
            seconds = math.ceil(callEMSTimer - elapsed)
        }), 'error')

        cb('ok')
        return
    end

    callEMS()
    cb('ok')
end)

RegisterNUICallback('amb_goHospital', function(_, cb)
    if not useBuiltInDeathscreen or not deathScreenActive or mercyFinished
        or not hospitalTransportAllowed() then
        cb('ok')
        return
    end

    local elapsed = (GetGameTimer() - deathStartTime) / 1000
    local remaining = math.ceil(math.max(0, transportDelay - elapsed))

    if remaining > 0 then
        SendNUIMessage({
            action = 'amb_transportState',
            available = false,
            remaining = remaining
        })

        Framework.Notify(_L('transport_available_in', { seconds = remaining }), 'error')

        cb('ok')
        return
    end

    local bed = getClosestCheckInBed()

    if not bed then
        Framework.Notify(_L('no_checkin_bed'), 'error')
        cb('ok')
        return
    end

    transportToHospital(bed)
    cb('ok')
end)

RegisterNUICallback('amb_giveUp', function(_, cb)
    if not useBuiltInDeathscreen or not deathScreenActive or mercyFinished then
        cb('ok')
        return
    end

    if not deathSystemActive() then
        cb('ok')
        return
    end

    local elapsed = (GetGameTimer() - deathStartTime) / 1000
    local needed = giveUpSeconds()

    if elapsed < needed then
        Framework.Notify(_L('give_up_unavailable'), 'error')

        cb('ok')
        return
    end

    -- The server re-checks the elapsed time again.
    TriggerServerEvent('amb_server:giveUp')

    cb('ok')
end)

-- Killer info resolved / validated by the server.
RegisterNetEvent('amb_client:deathKillerInfo', function(info)
    if not deathScreenActive then
        return
    end

    SendNUIMessage({
        action = 'amb_killerInfo',
        info = displayKillerInfo(info)
    })
end)

-- GIVE UP button state: locked until GiveUpTime has passed.
CreateThread(function()
    while true do
        Wait(500)

        if useBuiltInDeathscreen and deathScreenActive and not mercyFinished then
            local elapsed = (GetGameTimer() - deathStartTime) / 1000
            local needed = giveUpSeconds()
            local remaining = math.ceil(math.max(0, needed - elapsed))

            SendNUIMessage({
                action = 'amb_giveUpState',
                available = deathSystemActive() and remaining <= 0,
                remaining = remaining
            })
        else
            Wait(500)
        end
    end
end)

CreateThread(function()
    while true do
        Wait(1000)

        if useBuiltInDeathscreen and deathScreenActive then
            local elapsed = (GetGameTimer() - deathStartTime) / 1000
            local remaining = math.ceil(math.max(0, transportDelay - elapsed))

            SendNUIMessage({
                action = 'amb_transportState',
                available = hospitalTransportAllowed() and remaining <= 0,
                remaining = remaining
            })
        end
    end
end)

AddEventHandler('amb_client:SetDownedState', function(downed)
    if not useBuiltInDeathscreen or Framework.HasAuthoritativeMedicalState() then
        return
    end

    if downed then
        TriggerEvent('amb_client:onPlayerDeath', 'dead', 0, Framework.MedicalState.LASTSTAND)
    else
        TriggerEvent('amb_client:onPlayerRevive')
    end
end)

-- ---------------------------------------------------------------
-- Mercy / finished: 10 minute hospital timer
-- ---------------------------------------------------------------
AddEventHandler('amb_client:finishedStateChanged', function(src, finished)
    if src ~= GetPlayerServerId(PlayerId()) then
        return
    end

    mercyFinished = finished == true

    if not mercyFinished then
        return
    end

    if not deathScreenActive then
        TriggerEvent('amb_client:onPlayerDeath', 'dead', 0, Framework.MedicalState.DEAD)
    end

    deathMode = 'dead'

    -- FINISH must NOT reset the clock: keep showing the same countdown that
    -- was already running (the thread above keeps ticking it down to zero).
    -- Only when no clock exists yet (finish without a prior death screen)
    -- fall back to the full duration; the thread corrects it within a tick.
    if deathEndTime > 0 then
        deathTimer = math.max(0, math.ceil((deathEndTime - GetGameTimer()) / 1000))
    else
        deathTimer = math.max(60, tonumber((Config.DeathSystem and Config.DeathSystem.RespawnSeconds)
            or (Config.Mercy and Config.Mercy.RespawnSeconds)) or 600)
    end

    toggleDeathScreen(true, deathTimer, 'dead')

    SendNUIMessage({
        action = 'amb_updateDeathTimer',
        time = deathTimer
    })

    -- Finished mode: no Call EMS / Go To Hospital / Give Up.
    SendNUIMessage({
        action = 'amb_finishedState',
        show = true
    })

    SendNUIMessage({
        action = 'amb_giveUpState',
        available = false,
        remaining = 0
    })
end)

-- The mercy timer ran out: the server already wiped the inventory and
-- revived us; all that is left is walking out of the hospital.
RegisterNetEvent('amb_client:finishedRespawn', function()
    mercyFinished = false

    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    local spot = getClosestCheckInBed()
        or (Config.Mercy and Config.Mercy.HospitalCoords)
        or { x = 307.7, y = -590.8, z = 43.3, h = 0.0 }

    SetEntityCoords(ped, spot.x, spot.y, spot.z, false, false, false, false)
    SetEntityHeading(ped, spot.h or 0.0)

    CreateThread(function()
        Wait(200)
        TriggerEvent('amb_client:playWakeUpAnimation')
    end)

    Framework.Notify(_L('transported_to_hospital'), 'success')
end)
