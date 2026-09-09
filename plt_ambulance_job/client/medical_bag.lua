local BAG_MODEL = -1187210516
local BAG_BONE = 57005

local holdingBag = false
local bagProp = nil
local pendingBagData = nil
local editMode = false

local bagOffset = vector3(0.1, 0.0, 0.0)
local bagRotation = vector3(-90.0, 0.0, 0.0)

local OFFSET_CONTROLS = {
    [172] = vector3(1.0, 0.0, 0.0),
    [173] = vector3(-1.0, 0.0, 0.0),
    [174] = vector3(0.0, 1.0, 0.0),
    [175] = vector3(0.0, -1.0, 0.0),
    [44] = vector3(0.0, 0.0, 1.0),
    [20] = vector3(0.0, 0.0, -1.0)
}

local ROTATION_CONTROLS = {
    [117] = vector3(1.0, 0.0, 0.0),
    [118] = vector3(-1.0, 0.0, 0.0),
    [124] = vector3(0.0, 1.0, 0.0),
    [125] = vector3(0.0, -1.0, 0.0),
    [126] = vector3(0.0, 0.0, 1.0),
    [127] = vector3(0.0, 0.0, -1.0)
}

local function attachBag(ped)
    AttachEntityToEntity(bagProp, ped, GetPedBoneIndex(ped, BAG_BONE),
        bagOffset.x, bagOffset.y, bagOffset.z,
        bagRotation.x, bagRotation.y, bagRotation.z,
        true, true, false, true, 1, true)
end

RegisterNetEvent('amb_client:useMedicalBag', function(bagData)
    if holdingBag then
        Framework.Notify(_L('already_holding_bag'), 'error')
        return
    end

    pendingBagData = bagData

    local ped = PlayerPedId()

    Framework.RequestModel(BAG_MODEL)

    bagProp = CreateObject(BAG_MODEL, 0, 0, 0, true, true, true)

    AttachEntityToEntity(bagProp, ped, GetPedBoneIndex(ped, BAG_BONE),
        0.43, -0.065, -0.005, -90.0, -2.5, 78.0,
        true, true, false, true, 1, true)

    holdingBag = true

    Framework.Notify(_L('drop_bag_prompt'), 'info')

    CreateThread(function()
        while holdingBag do
            Wait(0)

            if not editMode and IsControlJustPressed(0, 38) then
                DropBag()
            end
        end
    end)
end)

exports('plt_medical_bag', function(item, slot)
    TriggerEvent('amb_client:useMedicalBag', {
        slot = slot,
        metadata = item and item.metadata or nil
    })
end)

RegisterCommand('bagedit', function()
    if not holdingBag then
        Framework.Notify(_L('must_hold_bag_edit'), 'error')
        return
    end

    editMode = true

    Framework.Notify(_L('bag_edit_mode'), 'info')

    CreateThread(function()
        local ped = PlayerPedId()

        while editMode do
            Wait(0)

            local fastMode = IsControlPressed(0, 21)
            local moveStep = fastMode and 0.05 or 0.005
            local rotationStep = fastMode and 5.0 or 0.5
            local changed = false

            for control, direction in pairs(OFFSET_CONTROLS) do
                if IsControlPressed(0, control) then
                    bagOffset = bagOffset + (direction * moveStep)
                    changed = true
                end
            end

            for control, direction in pairs(ROTATION_CONTROLS) do
                if IsControlPressed(0, control) then
                    bagRotation = bagRotation + (direction * rotationStep)
                    changed = true
                end
            end

            if changed then
                DetachEntity(bagProp, true, true)
                attachBag(ped)
            end

            local info = ('OFF: %.3f, %.3f, %.3f | ROT: %.1f, %.1f, %.1f'):format(
                bagOffset.x, bagOffset.y, bagOffset.z,
                bagRotation.x, bagRotation.y, bagRotation.z)

            SetTextFont(0)
            SetTextProportional(1)
            SetTextScale(0.0, 0.35)
            SetTextColour(255, 255, 255, 255)
            SetTextDropshadow(0, 0, 0, 0, 255)
            SetTextEdge(1, 0, 0, 0, 255)
            SetTextDropShadow()
            SetTextOutline()
            SetTextEntry('STRING')
            AddTextComponentString(_L('bag_edit_instructions', { info = info }))
            DrawText(0.4, 0.8)

            if IsControlJustPressed(0, 18) then
                editMode = false

                local finalCode = ('AttachEntityToEntity(bagProp, ped, GetPedBoneIndex(ped, 57005), %.3f, %.3f, %.3f, %.1f, %.1f, %.1f, true, true, false, true, 1, true)'):format(
                    bagOffset.x, bagOffset.y, bagOffset.z,
                    bagRotation.x, bagRotation.y, bagRotation.z)

                if Config.Debug then
                    print('^2[BAG_EDIT] FINAL CODE:^7')
                    print(finalCode)
                end

                TriggerEvent('chat:addMessage', {
                    color = { 0, 255, 0 },
                    multiline = true,
                    args = { 'SYSTEM', _L('bag_position_saved') }
                })
            end
        end
    end)
end)

function DropBag()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local dropCoords = coords + (GetEntityForwardVector(ped) * 0.5)

    local foundGround, groundZ = GetGroundZFor_3dCoord(dropCoords.x, dropCoords.y, dropCoords.z, false)

    if not foundGround then
        foundGround, groundZ = GetGroundZFor_3dCoord(dropCoords.x, dropCoords.y, dropCoords.z + 5.0, false)
    end

    if foundGround then
        dropCoords = vector3(dropCoords.x, dropCoords.y, groundZ)
    end

    DetachEntity(bagProp, true, true)
    DeleteEntity(bagProp)

    bagProp = nil
    holdingBag = false

    local bagId, slot

    if pendingBagData then
        slot = pendingBagData.slot

        if pendingBagData.metadata then
            if pendingBagData.metadata.bagId then
                bagId = pendingBagData.metadata.bagId
            end
        elseif pendingBagData.info and pendingBagData.info.bagId then
            bagId = pendingBagData.info.bagId
        end
    end

    pendingBagData = nil

    TriggerServerEvent('amb_server:dropMedicalBag', dropCoords, heading, bagId, slot)
end

RegisterNetEvent('amb_client:openBagUI', function(data)
    if Config.Debug then
        print('^2[PLT_BAG] Opening UI. Received ' .. #data.playerItems .. ' player items.^7')
    end

    SetNuiFocus(true, true)

    SendNUIMessage({
        action = 'amb_openBagUI',
        bagId = data.bagId,
        netId = data.netId,
        items = data.items,
        weight = data.weight,
        maxWeight = data.maxWeight,
        maxSlots = data.maxSlots,
        playerItems = data.playerItems,
        playerWeight = data.playerWeight,
        playerMaxWeight = data.playerMaxWeight,
        playerMaxSlots = data.playerMaxSlots,
        imagePath = Bridge.InventoryImages
    })
end)

RegisterNUICallback('amb_closeBag', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('amb_takeBagItem', function(data, cb)
    TriggerServerEvent('amb_server:takeBagItem', data)
    cb('ok')
end)

RegisterNUICallback('amb_storeInBag', function(data, cb)
    TriggerServerEvent('amb_server:storeInBag', data)
    cb('ok')
end)

CreateThread(function()
    if not Target then
        return
    end

    Target.AddModel(BAG_MODEL, {
        {
            name = 'open_medical_bag',
            icon = 'fas fa-briefcase_medical',
            label = _L('open_medical_bag'),
            onSelect = function(data)
                local netId = NetworkGetNetworkIdFromEntity(data.entity)

                if netId == 0 then
                    Framework.Notify(_L('bag_netid_missing'), 'error')
                    return
                end

                TriggerServerEvent('amb_server:openBagInventory', netId)
            end
        },
        {
            name = 'pickup_medical_bag',
            icon = 'fas fa-hand-holding',
            label = _L('pickup_medical_bag'),
            onSelect = function(data)
                TriggerServerEvent('amb_server:pickupMedicalBag', NetworkGetNetworkIdFromEntity(data.entity))
            end
        }
    }, 2.0)
end)

RegisterNetEvent('amb_client:openBagTarget', function(data)
    TriggerServerEvent('amb_server:openBagInventory', NetworkGetNetworkIdFromEntity(data.entity))
end)

RegisterNetEvent('amb_client:pickupBagTarget', function(data)
    TriggerServerEvent('amb_server:pickupMedicalBag', NetworkGetNetworkIdFromEntity(data.entity))
end)

