local knockoutDisabled = false
local knockoutLoopRunning = false
local pendingDiagnosis = nil
local radioMutedByDeath = false

local INJURY_BODY_PARTS = {
    shot = 'chest',
    stabbed = 'left_arm',
    beat = 'right_arm',
    burned = 'chest'
}

local function getClosestPlayer(radius)
    local players = GetActivePlayers()
    local coords = GetEntityCoords(PlayerPedId())
    local closestPed = nil
    local closestServerId = nil
    local closestDistance = radius or 3.0

    for _, playerIndex in ipairs(players) do
        if playerIndex ~= PlayerId() then
            local ped = GetPlayerPed(playerIndex)

            if DoesEntityExist(ped) then
                local distance = #(GetEntityCoords(ped) - coords)

                if distance <= closestDistance then
                    closestDistance = distance
                    closestPed = ped
                    closestServerId = GetPlayerServerId(playerIndex)
                end
            end
        end
    end

    return closestPed, closestServerId, closestDistance
end

local function awaitCallback(name, ...)
    local request = promise.new()

    Framework.TriggerCallback(name, function(result)
        request:resolve(result)
    end, ...)

    return Citizen.Await(request)
end

local function requestDiagnosis(targetSrc, timeout)
    targetSrc = tonumber(targetSrc)

    if not targetSrc then
        return nil
    end

    if pendingDiagnosis then
        return nil
    end

    local request = promise.new()

    pendingDiagnosis = {
        targetSrc = targetSrc,
        promise = request
    }

    TriggerServerEvent('amb_server:requestInjuries', targetSrc)

    CreateThread(function()
        Wait(timeout or 2500)

        if pendingDiagnosis and pendingDiagnosis.promise == request then
            pendingDiagnosis = nil
            request:resolve(nil)
        end
    end)

    local result = Citizen.Await(request)

    TriggerServerEvent('amb_server:stopDiagnosisSync', targetSrc)

    return result
end

local function getClosestVehicle(radius)
    local coords = GetEntityCoords(PlayerPedId())

    return GetClosestVehicle(coords.x, coords.y, coords.z, radius or 6.0, 0, 71)
end

local function getFreeSeat(vehicle)
    if not DoesEntityExist(vehicle) then
        return nil
    end

    local seats = GetVehicleModelNumberOfSeats(GetEntityModel(vehicle))

    for seat = 0, seats - 2 do
        if IsVehicleSeatFree(vehicle, seat) then
            return seat
        end
    end

    return nil
end

local function isLocalPlayerDead()
    local medicalState = LocalPlayer and LocalPlayer.state and LocalPlayer.state.medicalState

    if medicalState == 'laststand' or medicalState == 'dead' then
        return true
    end

    local ped = PlayerPedId()

    return IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 120
end

RegisterNetEvent('amb_client:receiveDiagnosisData', function(data)
    if not pendingDiagnosis then
        return
    end

    local request = pendingDiagnosis

    pendingDiagnosis = nil

    request.promise:resolve(data)
end)

RegisterNetEvent('amb_client:compat:setKnockoutDisabled', function(disabled)
    knockoutDisabled = disabled == true
end)

RegisterNetEvent('amb_client:compat:manualKnockout', function(knockedOut)
    if knockedOut then
        TriggerEvent('amb_client:SetDeathStatus', true)
    else
        exports.plt_ambulance_job:RevivePlayer()
    end
end)

RegisterNetEvent('amb_client:compat:applySedative', function()
    local ped = PlayerPedId()

    if IsPedInAnyVehicle(ped, false) then
        return
    end

    SetPedToRagdoll(ped, 12000, 12000, 0, false, false, false)
end)

RegisterNetEvent('amb_client:compat:warpIntoVehicle', function(netId, seat)
    local vehicle = NetToVeh(netId)

    if DoesEntityExist(vehicle) and seat then
        TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, seat)
    end
end)

RegisterNetEvent('amb_client:compat:loadOnStretcher', function(netId)
    local stretcher = NetToObj(netId)

    if not DoesEntityExist(stretcher) then
        return
    end

    local offset = Config.FernocotLieOffset or { x = 0.0, y = 0.0, z = 1.2 }
    local heading = Config.FernocotLieHeading or 0.0
    local anim = Config.FernocotLieAnim or {
        dict = 'amb@world_human_sunbathe@male@back@base',
        name = 'base'
    }

    Framework.RequestAnimDict(anim.dict)

    AttachEntityToEntity(PlayerPedId(), stretcher, 0,
        offset.x, offset.y, offset.z,
        0.0, 0.0, 180.0 + heading,
        false, false, false, false, 0, true)

    TaskPlayAnim(PlayerPedId(), anim.dict, anim.name, 8.0, -8.0, -1, 1, 0, false, false, false)
end)

exports('isPlayerDead', function(targetId)
    if not targetId then
        return isLocalPlayerDead()
    end

    local serverId = tonumber(targetId)

    if not serverId then
        return false
    end

    if serverId == GetPlayerServerId(PlayerId()) then
        return isLocalPlayerDead()
    end

    return awaitCallback('amb_server:isPlayerDowned', serverId) == true
end)

exports('diagnosePlayer', function(target)
    if target == nil then
        local ped = getClosestPlayer(3.0)

        if not ped then
            return nil
        end

        if StartDiagnosis then
            StartDiagnosis(ped)
            return true
        end

        return nil
    end

    if target == true then
        return requestDiagnosis(GetPlayerServerId(PlayerId()))
    end

    local serverId = tonumber(target)

    if not serverId then
        return nil
    end

    return requestDiagnosis(serverId)
end)

exports('treatPatient', function(injuryType)
    if not exports.plt_ambulance_job:IsEMS() then
        return false
    end

    local ped, serverId = getClosestPlayer(3.0)

    if not ped or not serverId then
        return false
    end

    local bodyPart = INJURY_BODY_PARTS[tostring(injuryType or ''):lower()] or 'chest'

    TaskStartScenarioInPlace(PlayerPedId(), 'CODE_HUMAN_MEDIC_TEND_TO_KNOT', 0, true)

    local completed = Framework.ProgressBar(_L('progress_apply_treatment'), 5000)

    ClearPedTasks(PlayerPedId())

    if not completed then
        return false
    end

    TriggerServerEvent('amb_server:HealPlayer', serverId, bodyPart, 1)

    return true
end)

exports('reviveTarget', function()
    if not exports.plt_ambulance_job:IsEMS() then
        return false
    end

    local ped = getClosestPlayer(3.0)

    if not ped then
        return false
    end

    if not RevivePlayerAction then
        return false
    end

    RevivePlayerAction(ped)

    return true
end)

exports('healTarget', function()
    local ped = nil

    if exports.plt_ambulance_job:IsEMS() then
        ped = getClosestPlayer(3.0)
    end

    if ped and OpenTreatmentMenu then
        OpenTreatmentMenu(ped)
        return true
    end

    TriggerEvent('amb_client:useMedication', 'plt_medkit')

    return true
end)

exports('useSedative', function()
    local _, serverId = getClosestPlayer(3.0)

    if not serverId then
        return false
    end

    TriggerServerEvent('amb_server:compat:sedateTarget', serverId)

    return true
end)

exports('placeInVehicle', function()
    local _, serverId = getClosestPlayer(4.0)

    if not serverId then
        return false
    end

    local vehicle = getClosestVehicle(6.0)

    if not DoesEntityExist(vehicle) then
        return false
    end

    local seat = getFreeSeat(vehicle)

    if seat == nil then
        return false
    end

    TriggerServerEvent('amb_server:compat:placeInVehicle', serverId, VehToNet(vehicle), seat)

    return true
end)

exports('loadStretcher', function()
    local _, serverId = getClosestPlayer(3.0)

    if not serverId then
        return false
    end

    local stretcherModel = GetHashKey(Config.FernocotModel or 'fernocot')
    local coords = GetEntityCoords(PlayerPedId())
    local stretcher = GetClosestObjectOfType(coords.x, coords.y, coords.z, 5.0, stretcherModel, false, false, false)

    if not stretcher or stretcher == 0 then
        return false
    end

    TriggerServerEvent('amb_server:compat:loadOnStretcher', serverId, ObjToNet(stretcher))

    return true
end)

exports('openOutfits', function()
    if GetResourceState('qb-clothing') == 'started' then
        TriggerEvent('qb-clothing:client:openOutfitMenu')
        return true
    end

    if GetResourceState('illenium-appearance') == 'started' then
        TriggerEvent('illenium-appearance:client:openOutfitMenu')
        return true
    end

    if GetResourceState('esx_skin') == 'started' then
        TriggerEvent('esx_skin:openSaveableMenu')
        return true
    end

    if GetResourceState('origen_clothing') == 'started' then
        TriggerEvent('origen_clothing:client:openOutfitMenu')
        TriggerEvent('origen_clothing:openOutfits')
        return true
    end

    if GetResourceState('rclothing') == 'started' then
        TriggerEvent('rclothing:client:openOutfitMenu')
        TriggerEvent('rclothing:openOutfits')
        return true
    end

    return false
end)

exports('deleteStretcherFromVehicle', function(targetVehicle)
    local vehicle = (targetVehicle and DoesEntityExist(targetVehicle) and targetVehicle) or getClosestVehicle(6.0)

    if not vehicle or not DoesEntityExist(vehicle) then
        return false
    end

    local coords = GetEntityCoords(vehicle)
    local stretcherModel = GetHashKey(Config.FernocotModel or 'fernocot')
    local stretcher = GetClosestObjectOfType(coords.x, coords.y, coords.z, 7.0, stretcherModel, false, false, false)

    if not stretcher or stretcher == 0 then
        return false
    end

    DeleteEntity(stretcher)

    return true
end)

exports('isPlayerUsingStretcher', function(targetId)
    local playerIndex = tonumber(targetId)

    if playerIndex == nil then
        playerIndex = PlayerId()
    end

    local ped = GetPlayerPed(playerIndex)

    if not DoesEntityExist(ped) or not IsEntityAttached(ped) then
        return false
    end

    local attachedTo = GetEntityAttachedTo(ped)

    if not DoesEntityExist(attachedTo) then
        return false
    end

    return GetEntityModel(attachedTo) == GetHashKey(Config.FernocotModel or 'fernocot')
end)

exports('clearPlayerInjury', function(resetVitals)
    exports.plt_ambulance_job:RevivePlayer()

    if resetVitals then
        TriggerServerEvent('amb_server:compat:resetVitals')
    end

    return true
end)

exports('disableKnockoutLoop', function(disabled)
    knockoutDisabled = disabled == true

    if knockoutLoopRunning then
        return knockoutDisabled
    end

    knockoutLoopRunning = true

    CreateThread(function()
        while true do
            if knockoutDisabled then
                local ped = PlayerPedId()

                if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 110 then
                    exports.plt_ambulance_job:RevivePlayer()
                    Wait(1500)
                end

                Wait(300)
            else
                Wait(1200)
            end
        end
    end)

    return knockoutDisabled
end)

exports('manuallyKnockout', function(knockedOut)
    if knockedOut then
        TriggerEvent('amb_client:SetDeathStatus', true)
        return true
    end

    exports.plt_ambulance_job:RevivePlayer()

    return true
end)

local function isPlayerDownedForRadio()
    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false
    end

    local state = LocalPlayer and LocalPlayer.state

    if state then
        if state.isDead == true or state.isdead == true or state.inlaststand == true
            or state.inLaststand == true or state.dead == true then
            return true
        end
    end

    local downed = false

    pcall(function()
        downed = exports.plt_ambulance_job:IsPlayerDowned() == true
    end)

    if downed then
        return true
    end

    return IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 120
end

local function restoreRadio()
    local state = LocalPlayer and LocalPlayer.state

    if state then
        state:set('radioMutedByDeath', false, true)
    end

    pcall(function()
        MumbleSetPlayerMuted(PlayerId(), false)
    end)

    if GetResourceState('pma-voice') == 'started' then
        pcall(function()
            exports['pma-voice']:setVoiceProperty('radioEnabled', true)
        end)
    end

    radioMutedByDeath = false
end

local function muteRadioIfDead()
    if not isPlayerDownedForRadio() then
        if radioMutedByDeath then
            restoreRadio()
        end

        return false
    end

    local state = LocalPlayer and LocalPlayer.state

    if state then
        state:set('radioMutedByDeath', true, true)
    end

    pcall(function()
        MumbleSetPlayerMuted(PlayerId(), true)
    end)

    if GetResourceState('pma-voice') == 'started' then
        pcall(function()
            exports['pma-voice']:setRadioChannel(0)
        end)

        pcall(function()
            exports['pma-voice']:setVoiceProperty('radioEnabled', false)
        end)
    end

    TriggerEvent('qb-radio:client:LeaveChannel')
    TriggerEvent('qb-radio:client:disconnect')
    TriggerEvent('qbx_radio:client:leaveChannel')
    TriggerEvent('esx_radio:leaveRadio')
    TriggerEvent('gcphone:removeRadio')
    TriggerEvent('tgiann-radio:client:CloseRadio')

    radioMutedByDeath = true

    return true
end

exports('ShouldForceRadioMute', function()
    return isPlayerDownedForRadio()
end)

exports('ForceMuteRadioIfDead', function()
    return muteRadioIfDead()
end)

RegisterNetEvent('amb_client:restoreRadioAfterDeath', restoreRadio)

RegisterNetEvent('amb_client:onPlayerRevive', function()
    restoreRadio()
end)

AddEventHandler('amb_client:SetDownedState', function(downed)
    if downed == false then
        restoreRadio()
    end
end)

CreateThread(function()
    while true do
        if muteRadioIfDead() then
            Wait(1000)
        else
            Wait(2000)
        end
    end
end)

