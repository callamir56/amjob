local bodyBagStates = {}
local bodyBagProps = {}

local function getBodyBagModel()
    return (Config.Medical and Config.Medical.BodyBagModel) or 'xm_prop_body_bag'
end

local function getBodyBagOffset()
    local offset = (Config.Medical and Config.Medical.BodyBagOffset) or {}

    return offset.x or 0.0, offset.y or 0.0, offset.z or -0.95
end

local function getBodyBagRotation()
    local rotation = (Config.Medical and Config.Medical.BodyBagRotation) or {}

    return rotation.x or 0.0, rotation.y or 0.0, rotation.z or 0.0
end

local function getPedFromServerId(serverId)
    local playerIndex = GetPlayerFromServerId(tonumber(serverId) or -1)

    if playerIndex == -1 then
        return nil
    end

    local ped = GetPlayerPed(playerIndex)

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return nil
    end

    return ped
end

local function restorePedVisibility(serverId)
    local ped = getPedFromServerId(serverId)

    if not ped then
        return
    end

    SetEntityVisible(ped, true, false)
    ResetEntityAlpha(ped)
end

local function removeBodyBag(serverId)
    local prop = bodyBagProps[serverId]

    if prop and DoesEntityExist(prop) then
        SetEntityAsMissionEntity(prop, true, true)
        DeleteEntity(prop)
    end

    bodyBagProps[serverId] = nil

    restorePedVisibility(serverId)
end

local function getServerIdFromBagProp(entity)
    if not entity or entity == 0 then
        return nil
    end

    for serverId, prop in pairs(bodyBagProps) do
        if prop == entity and DoesEntityExist(prop) then
            return serverId
        end
    end

    return nil
end

local function findNearbyStretcher(entity, radius)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return nil
    end

    local stretcherModel = GetHashKey(Config.FernocotModel or 'fernocot')
    local coords = GetEntityCoords(entity)
    local stretcher = GetClosestObjectOfType(coords.x, coords.y, coords.z, radius or 6.0, stretcherModel, false, false, false)

    if stretcher and stretcher ~= 0 and DoesEntityExist(stretcher) then
        return stretcher
    end

    return nil
end

local function updateBodyBag(serverId)
    local ped = getPedFromServerId(serverId)

    if not ped then
        removeBodyBag(serverId)
        return
    end

    local prop = bodyBagProps[serverId]

    if not prop or not DoesEntityExist(prop) then
        local modelName = tostring(getBodyBagModel() or 'xm_prop_body_bag')
        local modelHash = GetHashKey(modelName)

        if not IsModelInCdimage(modelHash) or not IsModelValid(modelHash) then
            modelName = 'prop_body_bag_01'
            modelHash = GetHashKey(modelName)
        end

        if not IsModelInCdimage(modelHash) or not IsModelValid(modelHash) then
            return
        end

        Framework.RequestModel(modelHash)

        if not HasModelLoaded(modelHash) then
            return
        end

        local pedCoords = GetEntityCoords(ped)

        prop = CreateObjectNoOffset(modelHash, pedCoords.x, pedCoords.y, pedCoords.z, false, false, false)

        if not prop or prop == 0 or not DoesEntityExist(prop) then
            return
        end

        SetEntityAsMissionEntity(prop, true, true)
        SetEntityCollision(prop, false, false)
        SetEntityInvincible(prop, true)
        SetEntityVisible(prop, true, false)
        ResetEntityAlpha(prop)
        SetModelAsNoLongerNeeded(modelHash)

        bodyBagProps[serverId] = prop
    end

    local offsetX, offsetY, offsetZ = getBodyBagOffset()
    local rotationX, rotationY, rotationZ = getBodyBagRotation()

    local targetCoords = GetOffsetFromEntityInWorldCoords(ped, offsetX, offsetY, offsetZ)
    local targetZ = targetCoords.z

    local attachedTo = GetEntityAttachedTo(ped)
    local onStretcher = false

    if attachedTo and attachedTo ~= 0 and DoesEntityExist(attachedTo) then
        onStretcher = GetEntityModel(attachedTo) == GetHashKey(Config.FernocotModel or 'fernocot')
    end

    if not onStretcher then
        local pedCoords = GetEntityCoords(ped)
        local foundGround, groundZ = GetGroundZFor_3dCoord(pedCoords.x, pedCoords.y, pedCoords.z + 1.5, false)

        if foundGround and groundZ then
            targetZ = groundZ + offsetZ
        end
    end

    SetEntityCoordsNoOffset(prop, targetCoords.x, targetCoords.y, targetZ, false, false, false)
    SetEntityRotation(prop, rotationX, rotationY, GetEntityHeading(ped) + rotationZ, 2, true)
    SetEntityAlpha(ped, 0, false)
end

local function setBodyBagState(serverId, state)
    serverId = tonumber(serverId)

    if not serverId or serverId <= 0 then
        return
    end

    bodyBagStates[serverId] = state == true

    if not bodyBagStates[serverId] then
        removeBodyBag(serverId)
    end
end

RegisterNetEvent('amb_client:setBodyBagState', function(serverId, state)
    setBodyBagState(serverId, state)
end)

RegisterNetEvent('amb_client:syncBodyBagStates', function(states)
    if type(states) ~= 'table' then
        return
    end

    local received = {}

    for serverId, state in pairs(states) do
        local id = tonumber(serverId)

        if id and id > 0 then
            received[id] = true
            setBodyBagState(id, state == true)
        end
    end

    for serverId in pairs(bodyBagStates) do
        if not received[serverId] then
            setBodyBagState(serverId, false)
        end
    end
end)

CreateThread(function()
    Wait(500)

    Framework.TriggerCallback('amb_server:getBodyBagStates', function(states)
        if type(states) ~= 'table' then
            return
        end

        TriggerEvent('amb_client:syncBodyBagStates', states)
    end)
end)

CreateThread(function()
    while true do
        Wait(250)

        for serverId, bagged in pairs(bodyBagStates) do
            if bagged then
                updateBodyBag(serverId)
            else
                removeBodyBag(serverId)
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    for serverId in pairs(bodyBagStates) do
        removeBodyBag(serverId)
    end
end)

CreateThread(function()
    Wait(500)

    local models = { getBodyBagModel(), 'prop_body_bag_01' }

    local options = {
        {
            name = 'ems_bodybag_put_on_stretcher',
            icon = 'fas fa-bed',
            label = _L('bodybag_put_on_stretcher'),
            onSelect = function(data)
                if not exports.plt_ambulance_job:IsEMS() then
                    return
                end

                local serverId = getServerIdFromBagProp(data.entity)

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

                if not getServerIdFromBagProp(entity) then
                    return false
                end

                return findNearbyStretcher(entity, 6.0) ~= nil
            end
        }
    }

    if Target then
        Target.AddModel(models, options, 2.5)
    end
end)

exports('IsPlayerBodyBagged', function(serverId)
    serverId = tonumber(serverId)

    if not serverId then
        return false
    end

    return bodyBagStates[serverId] == true
end)

