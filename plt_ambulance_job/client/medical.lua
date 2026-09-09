local INTERIOR_SPAWN = vector4(688.21, 1492.13, 207.82, 11.54)
local INTERIOR_CENTER = vector3(687.44, 1494.29, 208.02)
local INTERIOR_RADIUS = 2.0
local VEHICLE_REAR_OFFSET = vector3(0.0, -5.2, 0.2)
local REAR_INTERACT_DISTANCE = 2.4
local EXIT_PROMPT_DISTANCE = 2.0
local INTERIOR_SPAWN_Z_OFFSET = 1.0
local INTERIOR_BUCKET_BASE = 700000
local MAX_BUCKET = 2147483646

local isPerformingCPR = false
local isDraggingBed = false
local draggedBed = nil
local lyingOnBed = nil
local stretcherCollisionCache = {}
local inAmbulanceInterior = false
local interiorVehicleNetId = nil
local interiorBucket = 0
local interiorExitData = nil
local pendingExitRequests = {}

local disableStretcherCollisions

local function isLyingOnBed()
    if lyingOnBed and not DoesEntityExist(lyingOnBed) then
        lyingOnBed = nil
    end

    return lyingOnBed ~= nil
end

local function requestAmbulanceExitData(netId, timeout)
    local vehicleNetId = tonumber(netId)

    if not vehicleNetId or vehicleNetId <= 0 then
        return nil
    end

    local requestKey = ('%s:%s:%s'):format(
        tostring(vehicleNetId),
        tostring(GetPlayerServerId(PlayerId())),
        tostring(GetGameTimer()))

    local request = promise.new()

    pendingExitRequests[requestKey] = request

    TriggerServerEvent('amb_server:requestAmbulanceExitData', requestKey, vehicleNetId)

    CreateThread(function()
        Wait(timeout or 2500)

        local pending = pendingExitRequests[requestKey]

        if pending then
            pendingExitRequests[requestKey] = nil
            pending:resolve(nil)
        end
    end)

    return Citizen.Await(request)
end

local function spawnStretcher(coords, heading)
    local modelName = Config.FernocotModel or 'fernocot'
    local model = GetHashKey(modelName)

    if not IsModelValid(model) then
        return nil
    end

    RequestModel(model)

    local attempts = 0

    while not HasModelLoaded(model) and attempts < 200 do
        Wait(10)
        attempts = attempts + 1
    end

    if not HasModelLoaded(model) then
        return nil
    end

    local spawnZ = coords.z
    local foundGround, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 5.0, false)

    if foundGround then
        spawnZ = groundZ
    end

    local stretcher = CreateObject(model, coords.x, coords.y, spawnZ, true, true, true)

    if not DoesEntityExist(stretcher) then
        return nil
    end

    SetEntityHeading(stretcher, heading)
    PlaceObjectOnGroundProperly(stretcher)
    FreezeEntityPosition(stretcher, true)

    if disableStretcherCollisions then
        disableStretcherCollisions(stretcher, 8.0)
    end

    SetModelAsNoLongerNeeded(model)

    return stretcher
end

local function normalizeModelName(value)
    if type(value) ~= 'string' then
        return nil
    end

    local name = value:lower():gsub('^%s+', ''):gsub('%s+$', '')

    if name == '' then
        return nil
    end

    return name
end

local function getServerIdFromPed(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return nil
    end

    local playerIndex = NetworkGetPlayerIndexFromPed(ped)

    if not playerIndex or playerIndex < 0 then
        return nil
    end

    local serverId = GetPlayerServerId(playerIndex)

    if not serverId or serverId <= 0 then
        return nil
    end

    return serverId
end

local function isPedDowned(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false
    end

    return IsPedDeadOrDying(ped, true)
        or IsPedRagdoll(ped)
        or GetEntityHealth(ped) <= 120
        or IsEntityPlayingAnim(ped, 'dead', 'dead_a', 3)
        or IsEntityPlayingAnim(ped, 'veh@low@front_ps@idle_duck', 'sit', 3)
end

local function isPatientDowned(ped, serverId)
    if isPedDowned(ped) then
        return true
    end

    local state = serverId and Player(serverId) and Player(serverId).state

    if not state then
        return false
    end

    return state.medicalState == 'laststand'
end

local function isPatientInInteriorBed(ped, serverId)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false
    end

    if not serverId or serverId <= 0 then
        return false
    end

    if #(GetEntityCoords(ped) - INTERIOR_CENTER) > INTERIOR_RADIUS then
        return false
    end

    local state = Player(serverId) and Player(serverId).state

    if state and state.isLyingOnBed == true then
        return true
    end

    if IsEntityPlayingAnim(ped, 'anim@heists@fleeca_bank@ig_7_jetski_owner', 'owner_idle', 3) then
        return true
    end

    if IsEntityPlayingAnim(ped, 'anim@gangops@morgue@table@', 'ko_front', 3) then
        return true
    end

    return false
end

local function findNearbyStretcher(entity, radius)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return nil
    end

    local model = GetHashKey(Config.FernocotModel or 'fernocot')
    local coords = GetEntityCoords(entity)
    local stretcher = GetClosestObjectOfType(coords.x, coords.y, coords.z, radius or 6.0, model, false, false, false)

    if stretcher and stretcher ~= 0 and DoesEntityExist(stretcher) then
        return stretcher
    end

    return nil
end

local function getAmbulanceModels()
    local models = {}

    if type(DepartmentData) == 'table' and type(DepartmentData.nodes) == 'table' then
        for _, node in ipairs(DepartmentData.nodes) do
            if type(node) == 'table' and node.type == 'vehicle' and type(node.vehicles) == 'table' then
                for _, vehicle in ipairs(node.vehicles) do
                    local modelName = (type(vehicle) == 'table' and vehicle.model) or vehicle
                    local normalized = normalizeModelName(modelName)

                    if normalized then
                        models[GetHashKey(normalized)] = true
                    end
                end
            end
        end
    end

    if next(models) == nil then
        for _, modelName in ipairs(Config.FernocotVehicleModels or {}) do
            local normalized = normalizeModelName(modelName)

            if normalized then
                models[GetHashKey(normalized)] = true
            end
        end
    end

    return models
end

local function isAmbulanceVehicle(entity, models)
    if type(entity) ~= 'number' or entity <= 0 or not DoesEntityExist(entity) then
        return false
    end

    if GetEntityType(entity) ~= 2 then
        return false
    end

    local ok, model = pcall(GetEntityModel, entity)

    if not ok or not model or model == 0 then
        return false
    end

    models = models or getAmbulanceModels()

    return models[model] == true
end

disableStretcherCollisions = function(stretcher, radius)
    if not stretcher or stretcher == 0 or not DoesEntityExist(stretcher) then
        return false
    end

    if Config.FernocotDisableVehicleCollision == false then
        return false
    end

    local coords = GetEntityCoords(stretcher)
    local maxDistance = tonumber(radius) or 8.0
    local disabledAny = false
    local models = getAmbulanceModels()

    stretcherCollisionCache[stretcher] = stretcherCollisionCache[stretcher] or {}

    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if isAmbulanceVehicle(vehicle, models) then
            local distance = #(coords - GetEntityCoords(vehicle))

            if distance <= maxDistance then
                if not stretcherCollisionCache[stretcher][vehicle] then
                    SetEntityNoCollisionEntity(stretcher, vehicle, false)
                    SetEntityNoCollisionEntity(vehicle, stretcher, false)
                    stretcherCollisionCache[stretcher][vehicle] = true
                end

                disabledAny = true
            end
        end
    end

    return disabledAny
end

CreateThread(function()
    local stretcherModel = GetHashKey(Config.FernocotModel or 'fernocot')

    while true do
        local sleep = 2000

        if Config.FernocotDisableVehicleCollision ~= false then
            local ped = PlayerPedId()
            local vehicle = IsPedInAnyVehicle(ped, false) and GetVehiclePedIsIn(ped, false) or 0

            if isAmbulanceVehicle(vehicle) then
                sleep = 750

                for _, object in ipairs(GetGamePool('CObject')) do
                    if DoesEntityExist(object) and GetEntityModel(object) == stretcherModel then
                        disableStretcherCollisions(object, 8.0)
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

local function isNearVehicleRear(vehicle, maxDistance)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return false
    end

    local ped = PlayerPedId()
    local pedCoords = GetEntityCoords(ped)
    local rearCoords = GetOffsetFromEntityInWorldCoords(vehicle,
        VEHICLE_REAR_OFFSET.x, VEHICLE_REAR_OFFSET.y, VEHICLE_REAR_OFFSET.z)

    if #(pedCoords - rearCoords) > (maxDistance or REAR_INTERACT_DISTANCE) then
        return false
    end

    local relative = GetOffsetFromEntityGivenWorldCoords(vehicle, pedCoords.x, pedCoords.y, pedCoords.z)

    return relative.y <= -0.8
end

local function getInteriorBucket(netId)
    local bucket = INTERIOR_BUCKET_BASE + (tonumber(netId) or 0)

    if bucket > MAX_BUCKET then
        bucket = MAX_BUCKET
    end

    if bucket < 1 then
        bucket = 1
    end

    return bucket
end

local function snapToGround(coords)
    if not coords then
        return nil
    end

    local foundGround, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 5.0, false)

    if foundGround and groundZ then
        return vector3(coords.x, coords.y, groundZ + 0.05)
    end

    return coords
end

local function findPatientOnStretcher(stretcher)
    if not stretcher or stretcher == 0 or not DoesEntityExist(stretcher) then
        return nil
    end

    local stretcherNetId = ObjToNet(stretcher)

    if not stretcherNetId or stretcherNetId <= 0 then
        stretcherNetId = nil
    end

    local localPlayer = PlayerId()

    for _, playerIndex in ipairs(GetActivePlayers()) do
        if playerIndex ~= localPlayer then
            local ped = GetPlayerPed(playerIndex)

            if ped and ped ~= 0 and DoesEntityExist(ped) and IsEntityAttachedToEntity(ped, stretcher) then
                local serverId = GetPlayerServerId(playerIndex)

                if serverId and serverId > 0 then
                    return {
                        src = serverId,
                        stretcherNetId = stretcherNetId
                    }
                end
            end
        end
    end

    return nil
end

local function findPatientNearVehicleRear(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return nil
    end

    local localPlayer = PlayerId()
    local rearCoords = GetOffsetFromEntityInWorldCoords(vehicle,
        VEHICLE_REAR_OFFSET.x, VEHICLE_REAR_OFFSET.y, VEHICLE_REAR_OFFSET.z)
    local stretcherModel = GetHashKey(Config.FernocotModel or 'fernocot')

    for _, playerIndex in ipairs(GetActivePlayers()) do
        if playerIndex ~= localPlayer then
            local ped = GetPlayerPed(playerIndex)

            if ped and ped ~= 0 and DoesEntityExist(ped) and IsEntityAttached(ped) then
                local attachedTo = GetEntityAttachedTo(ped)

                if attachedTo and attachedTo ~= 0 and DoesEntityExist(attachedTo)
                    and GetEntityModel(attachedTo) == stretcherModel then
                    if #(GetEntityCoords(attachedTo) - rearCoords) <= 7.5 then
                        local serverId = GetPlayerServerId(playerIndex)

                        if serverId and serverId > 0 then
                            local stretcherNetId = ObjToNet(attachedTo)

                            if not stretcherNetId or stretcherNetId <= 0 then
                                stretcherNetId = nil
                            end

                            return {
                                src = serverId,
                                stretcherNetId = stretcherNetId
                            }
                        end
                    end
                end
            end
        end
    end

    return nil
end

local function teleportToInterior(ped)
    if not ped or ped == 0 then
        return
    end

    FreezeEntityPosition(ped, true)
    DoScreenFadeOut(250)

    while not IsScreenFadedOut() do
        Wait(0)
    end

    SetEntityCoordsNoOffset(ped, INTERIOR_SPAWN.x, INTERIOR_SPAWN.y,
        INTERIOR_SPAWN.z + INTERIOR_SPAWN_Z_OFFSET, false, false, false)
    SetEntityHeading(ped, INTERIOR_SPAWN.w)

    Wait(450)

    SetEntityCoordsNoOffset(ped, INTERIOR_SPAWN.x, INTERIOR_SPAWN.y, INTERIOR_SPAWN.z, false, false, false)

    Wait(1000)

    FreezeEntityPosition(ped, false)

    Wait(100)

    DoScreenFadeIn(250)
end

local function enterAmbulanceInterior(vehicle)
    if inAmbulanceInterior then
        return
    end

    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return
    end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)

    if not netId or netId <= 0 then
        Framework.Notify('Unable to resolve vehicle instance ID.', 'error')
        return
    end

    local rearCoords = GetOffsetFromEntityInWorldCoords(vehicle,
        VEHICLE_REAR_OFFSET.x, VEHICLE_REAR_OFFSET.y, VEHICLE_REAR_OFFSET.z)

    interiorExitData = {
        coords = vector3(rearCoords.x, rearCoords.y, rearCoords.z),
        heading = GetEntityHeading(vehicle)
    }

    interiorVehicleNetId = netId
    interiorBucket = getInteriorBucket(netId)

    local patient = nil

    if isDraggingBed and draggedBed and DoesEntityExist(draggedBed) then
        patient = findPatientOnStretcher(draggedBed)
    end

    if not patient then
        patient = findPatientNearVehicleRear(vehicle)
    end

    if patient and patient.src then
        TriggerServerEvent('amb_server:enterAmbulanceInteriorWithPatient', patient.src, interiorBucket, interiorVehicleNetId, {
            x = rearCoords.x,
            y = rearCoords.y,
            z = rearCoords.z,
            heading = GetEntityHeading(vehicle)
        }, patient.stretcherNetId)

        if patient.stretcherNetId and isDraggingBed and draggedBed and DoesEntityExist(draggedBed) then
            local draggedNetId = ObjToNet(draggedBed)

            if draggedNetId and draggedNetId == patient.stretcherNetId then
                isDraggingBed = false
                draggedBed = nil
                ClearPedTasksImmediately(PlayerPedId())
            end
        end
    else
        TriggerServerEvent('amb_server:setPlayerRoutingBucket', interiorBucket)
    end

    teleportToInterior(PlayerPedId())

    inAmbulanceInterior = true
end

RegisterNetEvent('amb_client:enterAmbulanceInteriorAsPatient', function(payload)
    if inAmbulanceInterior then
        return
    end

    local ped = PlayerPedId()

    if IsEntityAttached(ped) then
        DetachEntity(ped, true, true)
        ClearPedTasksImmediately(ped)
    end

    local data = (type(payload) == 'table' and payload) or {}

    interiorVehicleNetId = tonumber(data.vehicleNetId)
    interiorBucket = tonumber(data.bucket) or 0

    local exitData = data.exitData

    if type(exitData) == 'table' and exitData.x and exitData.y and exitData.z then
        interiorExitData = {
            coords = vector3(exitData.x + 0.0, exitData.y + 0.0, exitData.z + 0.0),
            heading = tonumber(exitData.heading) or 0.0
        }
    else
        interiorExitData = nil
    end

    teleportToInterior(ped)

    inAmbulanceInterior = true
end)

local function getInteriorExitPoint()
    local heading = (interiorExitData and interiorExitData.heading) or 0.0

    if interiorVehicleNetId and interiorVehicleNetId > 0 then
        local vehicle = NetToVeh(interiorVehicleNetId)

        if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
            local rearCoords = GetOffsetFromEntityInWorldCoords(vehicle,
                VEHICLE_REAR_OFFSET.x, VEHICLE_REAR_OFFSET.y, VEHICLE_REAR_OFFSET.z)

            return vector3(rearCoords.x, rearCoords.y, rearCoords.z), GetEntityHeading(vehicle)
        end
    end

    if interiorExitData and interiorExitData.coords then
        return interiorExitData.coords, heading
    end

    return vector3(INTERIOR_SPAWN.x, INTERIOR_SPAWN.y, INTERIOR_SPAWN.z), heading
end

local function exitAmbulanceInterior()
    if not inAmbulanceInterior then
        return
    end

    local exitCoords, exitHeading = getInteriorExitPoint()

    if interiorVehicleNetId and interiorVehicleNetId > 0 then
        local exitData = nil

        for _ = 1, 3 do
            exitData = requestAmbulanceExitData(interiorVehicleNetId, 2000)

            if type(exitData) == 'table' and exitData.x and exitData.y and exitData.z then
                break
            end

            Wait(150)
        end

        if type(exitData) == 'table' and exitData.x and exitData.y and exitData.z then
            exitCoords = vector3(exitData.x + 0.0, exitData.y + 0.0, exitData.z + 0.0)
            exitHeading = tonumber(exitData.heading) or exitHeading or 0.0

            interiorExitData = {
                coords = exitCoords,
                heading = exitHeading
            }
        else
            Framework.Notify('Unable to locate this ambulance yet. Please try exiting again.', 'error')
            return
        end
    end

    TriggerServerEvent('amb_server:setPlayerRoutingBucket', 0)

    Wait(100)

    local targetCoords = snapToGround(exitCoords) or exitCoords
    local ped = PlayerPedId()

    DoScreenFadeOut(250)

    while not IsScreenFadedOut() do
        Wait(0)
    end

    SetEntityCoordsNoOffset(ped, targetCoords.x, targetCoords.y, targetCoords.z, false, false, false)
    SetEntityHeading(ped, exitHeading or 0.0)

    Wait(100)

    DoScreenFadeIn(250)

    inAmbulanceInterior = false
    interiorVehicleNetId = nil
    interiorBucket = 0
    interiorExitData = nil
end

RegisterNetEvent('amb_client:receiveAmbulanceExitData', function(requestKey, exitData)
    if not requestKey then
        return
    end

    local request = pendingExitRequests[requestKey]

    if not request then
        return
    end

    pendingExitRequests[requestKey] = nil

    request:resolve(exitData)
end)

RegisterNetEvent('amb_client:probeAmbulanceExitData', function(requestKey, netId, requesterId)
    local key = tostring(requestKey or '')
    local vehicleNetId = tonumber(netId)
    local requester = tonumber(requesterId)

    if key == '' or not vehicleNetId or vehicleNetId <= 0 or not requester or requester <= 0 then
        return
    end

    local vehicle = NetToVeh(vehicleNetId)

    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        return
    end

    local rearCoords = GetOffsetFromEntityInWorldCoords(vehicle,
        VEHICLE_REAR_OFFSET.x, VEHICLE_REAR_OFFSET.y, VEHICLE_REAR_OFFSET.z)

    TriggerServerEvent('amb_server:submitAmbulanceExitDataProbe', key, requester, {
        x = rearCoords.x,
        y = rearCoords.y,
        z = rearCoords.z,
        heading = GetEntityHeading(vehicle)
    })
end)

local function levelStretcher(stretcher)
    if not stretcher or stretcher == 0 or not DoesEntityExist(stretcher) then
        return
    end

    local rotation = GetEntityRotation(stretcher, 2)

    if math.abs(rotation.x) > 0.01 or math.abs(rotation.y) > 0.01 then
        SetEntityRotation(stretcher, 0.0, 0.0, rotation.z, 2, true)
    end
end

function ReleaseBed()
    if not isDraggingBed or not draggedBed then
        return
    end

    local stretcher = draggedBed
    local ped = PlayerPedId()

    DetachEntity(stretcher, true, true)
    ClearPedTasks(ped)
    SetEntityCollision(stretcher, true, true)
    FreezeEntityPosition(stretcher, false)
    PlaceObjectOnGroundProperly(stretcher)
    levelStretcher(stretcher)

    Wait(500)

    if DoesEntityExist(stretcher) then
        FreezeEntityPosition(stretcher, true)
        SetEntityCollision(stretcher, true, true)

        if disableStretcherCollisions then
            disableStretcherCollisions(stretcher, 8.0)
        end
    end

    isDraggingBed = false
    stretcherCollisionCache[stretcher] = nil
    draggedBed = nil

    Framework.Notify(_L('bed_released'), 'success')
end

local function dragBed(stretcher)
    if isDraggingBed or isLyingOnBed() then
        return
    end

    local ped = PlayerPedId()
    local dragOffset = Config.FernocotDragOffset or { x = 0.0, y = 1.3, z = -0.35 }
    local dragRotation = Config.FernocotDragRotation or { x = 0.0, y = 0.0, z = 180.0 }

    SetEntityAsMissionEntity(stretcher, true, true)
    NetworkRequestControlOfEntity(stretcher)

    local attempts = 0

    while not NetworkHasControlOfEntity(stretcher) and attempts < 100 do
        NetworkRequestControlOfEntity(stretcher)
        Wait(50)
        attempts = attempts + 1
    end

    SetEntityCollision(stretcher, false, false)
    SetEntityNoCollisionEntity(stretcher, ped, true)
    FreezeEntityPosition(stretcher, true)
    SetEntityInvincible(stretcher, true)

    Framework.RequestAnimDict('anim@heists@box_carry@')
    TaskPlayAnim(ped, 'anim@heists@box_carry@', 'idle', 8.0, -8.0, -1, 49, 0, false, false, false)

    isDraggingBed = true
    draggedBed = stretcher

    Framework.Notify(_L('release_bed_prompt'), 'info')

    CreateThread(function()
        local lastGroundZ = 0.0
        local nextCollisionRefresh = 0

        while isDraggingBed and DoesEntityExist(draggedBed) do
            Wait(0)

            local playerPed = PlayerPedId()

            if not NetworkHasControlOfEntity(draggedBed) then
                NetworkRequestControlOfEntity(draggedBed)
            end

            SetEntityNoCollisionEntity(draggedBed, playerPed, true)

            if disableStretcherCollisions and nextCollisionRefresh <= GetGameTimer() then
                disableStretcherCollisions(draggedBed, 8.0)
                nextCollisionRefresh = GetGameTimer() + 500
            end

            DisableControlAction(0, 37, true)
            DisableControlAction(0, 22, true)
            DisableControlAction(0, 44, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)

            local pedCoords = GetEntityCoords(playerPed)
            local targetCoords = GetOffsetFromEntityInWorldCoords(playerPed, dragOffset.x, dragOffset.y, 0.0)

            local rayHandle = StartShapeTestRay(
                targetCoords.x, targetCoords.y, pedCoords.z + 2.0,
                targetCoords.x, targetCoords.y, pedCoords.z - 2.0,
                1, draggedBed, 0)

            local _, hit, hitCoords = GetShapeTestResult(rayHandle)
            local targetZ = pedCoords.z + (dragOffset.z or -0.95)

            if hit == 1 then
                targetZ = hitCoords.z
                lastGroundZ = targetZ
            elseif lastGroundZ ~= 0.0 then
                targetZ = lastGroundZ
            end

            SetEntityCoordsNoOffset(draggedBed, targetCoords.x, targetCoords.y, targetZ + 0.02, false, false, false)

            local heading = GetEntityHeading(playerPed) + (dragRotation.z or 180.0)

            SetEntityHeading(draggedBed, heading)
            SetEntityRotation(draggedBed, 0.0, 0.0, heading, 2, true)

            if not IsEntityPlayingAnim(playerPed, 'anim@heists@box_carry@', 'idle', 3) then
                TaskPlayAnim(playerPed, 'anim@heists@box_carry@', 'idle', 8.0, -8.0, -1, 49, 0, false, false, false)
            end

            if IsPedDeadOrDying(playerPed) or IsPedRagdoll(playerPed) then
                ReleaseBed()
                break
            end

            if IsControlJustPressed(0, 38) then
                ReleaseBed()
                break
            end
        end
    end)
end

CreateThread(function()
    local stretcherModel = Config.FernocotModel or 'fernocot'

    local stretcherOptions = {
        {
            name = 'ems_lie_bed',
            icon = 'fas fa-bed',
            label = _L('bed_lie'),
            onSelect = function(data)
                local ped = PlayerPedId()
                local stretcher = data.entity

                if lyingOnBed then
                    return
                end

                local lieOffset = Config.FernocotLieOffset or { x = 0.0, y = 0.0, z = 1.2 }
                local lieHeading = Config.FernocotLieHeading or 0.0
                local lieAnim = Config.FernocotLieAnim or {
                    dict = 'amb@world_human_sunbathe@male@back@base',
                    name = 'base'
                }

                Framework.RequestAnimDict(lieAnim.dict)

                AttachEntityToEntity(ped, stretcher, 0,
                    lieOffset.x, lieOffset.y, lieOffset.z,
                    0.0, 0.0, 180.0 + lieHeading,
                    false, false, false, false, 0, true)

                TaskPlayAnim(ped, lieAnim.dict, lieAnim.name, 8.0, -8.0, -1, 1, 0, false, false, false)

                lyingOnBed = stretcher

                CreateThread(function()
                    while lyingOnBed and DoesEntityExist(lyingOnBed) do
                        Wait(500)

                        if lyingOnBed and DoesEntityExist(lyingOnBed)
                            and not IsEntityPlayingAnim(ped, lieAnim.dict, lieAnim.name, 3) then
                            TaskPlayAnim(ped, lieAnim.dict, lieAnim.name, 8.0, -8.0, -1, 1, 0, false, false, false)
                        end
                    end

                    if lyingOnBed and not DoesEntityExist(lyingOnBed) then
                        DetachEntity(ped, true, true)
                        ClearPedTasks(ped)
                        lyingOnBed = nil
                    end
                end)
            end
        },
        {
            name = 'ems_get_off_bed',
            icon = 'fas fa-person-walking',
            label = _L('bed_get_off'),
            onSelect = function(data)
                local ped = PlayerPedId()

                if lyingOnBed ~= data.entity then
                    return
                end

                DetachEntity(ped, true, true)
                ClearPedTasks(ped)

                lyingOnBed = nil

                Framework.Notify(_L('got_off_bed'), 'success')
            end,
            canInteract = function(entity)
                return lyingOnBed == entity
            end
        },
        {
            name = 'ems_drag_bed',
            icon = 'fas fa-hand-holding',
            label = _L('bed_drag'),
            onSelect = function(data)
                dragBed(data.entity)
            end,
            canInteract = function()
                return not isDraggingBed and not isLyingOnBed()
            end
        },
        {
            name = 'ems_delete_bed',
            icon = 'fas fa-trash',
            label = _L('bed_remove'),
            onSelect = function(data)
                SetEntityAsMissionEntity(data.entity, true, true)
                DeleteEntity(data.entity)
                Framework.Notify(_L('bed_removed'), 'success')
            end,
            canInteract = function()
                return exports.plt_ambulance_job:IsEMS() and not isDraggingBed
            end
        }
    }

    if Target then
        Target.AddModel(stretcherModel, stretcherOptions, 2.5)
    end

    local playerOptions = {
        {
            name = 'ems_diagnose',
            icon = 'fas fa-stethoscope',
            label = _L('diagnose_injuries'),
            onSelect = function(data)
                StartDiagnosis(data.entity)
            end,
            canInteract = function(entity)
                if isPerformingCPR or not exports.plt_ambulance_job:IsEMS() then
                    return false
                end

                local serverId = getServerIdFromPed(entity)

                if not serverId then
                    return false
                end

                return not exports.plt_ambulance_job:IsPlayerBodyBagged(serverId)
            end
        },
        {
            name = 'ems_bodybag_put_stretcher_player',
            icon = 'fas fa-bed',
            label = _L('bodybag_put_on_stretcher'),
            onSelect = function(data)
                local serverId = getServerIdFromPed(data.entity)

                if not serverId then
                    return
                end

                local stretcher = findNearbyStretcher(data.entity, 6.0)

                if not stretcher then
                    Framework.Notify(_L('no_stretcher_nearby'), 'error')
                    return
                end

                TriggerServerEvent('amb_server:compat:loadOnStretcher', serverId, ObjToNet(stretcher))
                Framework.Notify(_L('bodybag_loaded_on_stretcher'), 'success')
            end,
            canInteract = function(entity)
                if not exports.plt_ambulance_job:IsEMS() then
                    return false
                end

                local serverId = getServerIdFromPed(entity)

                if not serverId then
                    return false
                end

                if not exports.plt_ambulance_job:IsPlayerBodyBagged(serverId) then
                    return false
                end

                return findNearbyStretcher(entity, 6.0) ~= nil
            end
        },
        {
            name = 'ems_put_dead_player_stretcher',
            icon = 'fas fa-bed-pulse',
            label = _L('put_in_stretcher'),
            onSelect = function(data)
                local serverId = getServerIdFromPed(data.entity)

                if not serverId then
                    return
                end

                local stretcher = findNearbyStretcher(data.entity, 6.0)

                if not stretcher then
                    Framework.Notify(_L('no_stretcher_nearby'), 'error')
                    return
                end

                TriggerServerEvent('amb_server:compat:loadOnStretcher', serverId, ObjToNet(stretcher))
                Framework.Notify(_L('patient_loaded_on_stretcher'), 'success')
            end,
            canInteract = function(entity)
                if not exports.plt_ambulance_job:IsEMS() then
                    return false
                end

                local serverId = getServerIdFromPed(entity)

                if not serverId then
                    return false
                end

                if exports.plt_ambulance_job:IsPlayerBodyBagged(serverId) then
                    return false
                end

                local attachedTo = GetEntityAttachedTo(entity)

                if attachedTo and attachedTo ~= 0 and DoesEntityExist(attachedTo) then
                    if GetEntityModel(attachedTo) == GetHashKey(Config.FernocotModel or 'fernocot') then
                        return false
                    end
                end

                return isPatientDowned(entity, serverId) and findNearbyStretcher(entity, 6.0) ~= nil
            end
        },
        {
            name = 'ems_force_interior_mask_last_slot',
            icon = 'fas fa-mask-face',
            label = 'Force Interior Mask',
            onSelect = function(data)
                local serverId = getServerIdFromPed(data.entity)

                if not serverId then
                    return
                end

                TriggerServerEvent('amb_server:forcePatientInteriorMaskLastSlot', serverId)
            end,
            canInteract = function(entity)
                if not exports.plt_ambulance_job:IsEMS() then
                    return false
                end

                local serverId = getServerIdFromPed(entity)

                if not serverId then
                    return false
                end

                if exports.plt_ambulance_job:IsPlayerBodyBagged(serverId) then
                    return false
                end

                return isPatientInInteriorBed(entity, serverId)
            end
        },
        {
            name = 'ems_pronounce_dead_bodybag',
            icon = 'fas fa-sheet-plastic',
            label = _L('pronounce_dead_bodybag'),
            onSelect = function(data)
                local serverId = getServerIdFromPed(data.entity)

                if not serverId then
                    return
                end

                TriggerServerEvent('amb_server:pronounceWithBodyBag', serverId)
            end,
            canInteract = function(entity)
                if Config.Medical and Config.Medical.EnablePronounceBodyBag ~= true then
                    return false
                end

                if not exports.plt_ambulance_job:IsEMS() then
                    return false
                end

                local serverId = getServerIdFromPed(entity)

                if not serverId then
                    return false
                end

                if exports.plt_ambulance_job:IsPlayerBodyBagged(serverId) then
                    return false
                end

                return isPedDowned(entity)
            end
        }
    }

    if Target then
        Target.AddGlobalPlayer(playerOptions, 2.0)
    end

    local function isAmbulanceTarget(entity)
        return isAmbulanceVehicle(entity)
    end

    local vehicleOptions = {
        {
            name = 'ems_enter_ambulance_interior',
            icon = 'fas fa-door-open',
            label = 'Enter Ambulance Interior',
            distance = 4.0,
            onSelect = function(data)
                if not isAmbulanceTarget(data.entity) then
                    return
                end

                enterAmbulanceInterior(data.entity)
            end,
            canInteract = function(entity)
                return isAmbulanceTarget(entity)
                    and exports.plt_ambulance_job:IsEMS()
                    and not inAmbulanceInterior
                    and isNearVehicleRear(entity, REAR_INTERACT_DISTANCE)
            end
        },
        {
            name = 'ems_take_bed',
            icon = 'fas fa-bed',
            label = _L('bed_take_out'),
            distance = 4.0,
            onSelect = function(data)
                local vehicle = data.entity

                if not DoesEntityExist(vehicle) then
                    return
                end

                SetEntityAsMissionEntity(vehicle, true, true)
                SetVehicleHasBeenOwnedByPlayer(vehicle, true)

                local spawnCoords = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, -4.0, 0.0)
                local spawnHeading = GetEntityHeading(vehicle)

                CreateThread(function()
                    Wait(150)

                    local stretcher = spawnStretcher(spawnCoords, spawnHeading)

                    if not stretcher then
                        Framework.Notify(_L('bed_takeout_failed'), 'error')
                        return
                    end

                    dragBed(stretcher)
                end)
            end,
            canInteract = function(entity)
                return isAmbulanceTarget(entity)
                    and exports.plt_ambulance_job:IsEMS()
                    and not isDraggingBed
                    and isNearVehicleRear(entity, REAR_INTERACT_DISTANCE)
            end
        },
        {
            name = 'ems_put_bed',
            icon = 'fas fa-box',
            label = _L('bed_put_back_in'),
            distance = 4.0,
            onSelect = function()
                local ped = PlayerPedId()
                local coords = GetEntityCoords(ped)
                local model = GetHashKey(Config.FernocotModel or 'fernocot')
                local stretcher = nil

                if isDraggingBed and draggedBed then
                    stretcher = draggedBed
                    isDraggingBed = false
                    draggedBed = nil
                    DetachEntity(stretcher, true, true)
                else
                    stretcher = GetClosestObjectOfType(coords.x, coords.y, coords.z, 4.0, model, false, false, false)
                end

                if not stretcher or not DoesEntityExist(stretcher) then
                    Framework.Notify(_L('no_bed_nearby'), 'error')
                    return
                end

                SetEntityAsMissionEntity(stretcher, true, true)
                DeleteEntity(stretcher)
                ClearPedTasksImmediately(ped)

                Framework.Notify(_L('bed_put_back'), 'success')

                CreateThread(function()
                    Wait(100)
                    ClearPedTasksImmediately(PlayerPedId())
                end)
            end,
            canInteract = function(entity)
                if not isAmbulanceTarget(entity) or not exports.plt_ambulance_job:IsEMS() then
                    return false
                end

                if not isNearVehicleRear(entity, REAR_INTERACT_DISTANCE) then
                    return false
                end

                if isDraggingBed then
                    return true
                end

                local coords = GetEntityCoords(PlayerPedId())
                local model = GetHashKey(Config.FernocotModel or 'fernocot')

                return GetClosestObjectOfType(coords.x, coords.y, coords.z, 4.0, model, false, false, false) ~= 0
            end
        }
    }

    if Target then
        Target.AddGlobalVehicle(vehicleOptions, 4.0)
    end
end)

RegisterNetEvent('amb_client:forceMaskLastSlot', function()
    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    local component = 1
    local drawableCount = GetNumberOfPedDrawableVariations(ped, component)

    if not drawableCount or drawableCount <= 0 then
        return
    end

    local drawable = drawableCount - 1
    local textureCount = GetNumberOfPedTextureVariations(ped, component, drawable)
    local texture = (textureCount and textureCount > 0) and (textureCount - 1) or 0

    SetPedComponentVariation(ped, component, drawable, texture, 0)
end)

CreateThread(function()
    local promptVisible = false

    while true do
        local sleep = 1000

        if inAmbulanceInterior then
            sleep = 0

            local coords = GetEntityCoords(PlayerPedId())
            local distance = #(coords - vector3(INTERIOR_SPAWN.x, INTERIOR_SPAWN.y, INTERIOR_SPAWN.z))

            if distance <= EXIT_PROMPT_DISTANCE then
                if not promptVisible then
                    Framework.ShowTextUI('[E] Exit Ambulance Interior')
                    promptVisible = true
                end

                if IsControlJustPressed(0, 38) then
                    exitAmbulanceInterior()
                end
            elseif promptVisible then
                Framework.HideTextUI()
                promptVisible = false
            end
        elseif promptVisible then
            Framework.HideTextUI()
            promptVisible = false
        end

        Wait(sleep)
    end
end)

function DiagnosePlayer(ped)
    GetPlayerServerId(NetworkGetPlayerIndexFromPed(ped))

    Framework.Notify(_L('checking_vitals'), 'info')

    TaskStartScenarioInPlace(PlayerPedId(), 'CODE_HUMAN_MEDIC_TEND_TO_KNOT', 0, true)

    Wait(3000)

    ClearPedTasks(PlayerPedId())

    Framework.Notify(_L('patient_vitals_result'), 'warning')
end

function RevivePlayerAction(ped)
    local serverId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(ped))

    isPerformingCPR = true

    Framework.Notify(_L('performing_cpr'), 'info')

    TaskStartScenarioInPlace(PlayerPedId(), 'CODE_HUMAN_MEDIC_TEND_TO_KNOT', 0, true)

    if Framework.ProgressBar(_L('progress_revive_player'), 10000) then
        ClearPedTasks(PlayerPedId())
        TriggerServerEvent('amb_server:RevivePlayer', serverId)
        Framework.Notify(_L('player_revived'), 'success')
    else
        ClearPedTasks(PlayerPedId())
    end

    isPerformingCPR = false
end

RegisterNetEvent('amb_client:useWheelchair', function(duration)
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local spawnCoords = coords + (GetEntityForwardVector(ped) * 1.5)
    local heading = GetEntityHeading(ped)
    local model = -1963629913

    Framework.RequestModel(model)

    local wheelchair = CreateVehicle(model, spawnCoords.x, spawnCoords.y, spawnCoords.z, heading, true, true)

    if not DoesEntityExist(wheelchair) then
        Framework.Notify('Failed to deploy wheelchair.', 'error')
        return
    end

    SetEntityAsMissionEntity(wheelchair, true, true)
    SetVehicleHasBeenOwnedByPlayer(wheelchair, true)
    SetModelAsNoLongerNeeded(model)

    Keys.Give(wheelchair)

    Framework.Notify('Wheelchair deployed.', 'success')

    if exports.plt_ambulance_job:GetInjuryType() == 'fatal' then
        TaskWarpPedIntoVehicle(ped, wheelchair, -1)
    end

    local minutes = tonumber(duration) or tonumber(Config.WheelchairDuration) or 10
    local expiry = math.floor(minutes * 60000)

    if Config.Debug then
        print(('[WHEELCHAIR] Deployed with duration: %d minutes (%d ms)'):format(minutes, expiry))
    end

    SetTimeout(expiry, function()
        if not DoesEntityExist(wheelchair) then
            return
        end

        local driver = GetPedInVehicleSeat(wheelchair, -1)

        if driver ~= 0 then
            TaskLeaveVehicle(driver, wheelchair, 0)
            Wait(2000)
        end

        SetEntityAsMissionEntity(wheelchair, true, true)
        DeleteVehicle(wheelchair)

        Framework.Notify('Your rented wheelchair has expired and was returned.', 'info')
    end)
end)

