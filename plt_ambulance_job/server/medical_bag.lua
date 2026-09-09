local BAG_MODEL = -1187210516
local DEFAULT_BAG_MAX_WEIGHT = 50000
local DEFAULT_BAG_MAX_SLOTS = 20

local droppedBags = {}
local localStashes = {}
local pendingBagIds = {}

local function generateBagId(seed)
    return ('plt_medical_bag_%s_%s'):format(tostring(os.time()), tostring(seed or math.random(1000, 9999)))
end

local function findBagIdInInventory(src, slot)
    local targetSlot = tonumber(slot)

    for _, item in pairs(Inventory.GetItems(src)) do
        if item and item.name == 'plt_medical_bag' then
            local itemSlot = tonumber(item.slot)

            if not targetSlot or itemSlot == targetSlot then
                local metadata = item.metadata or item.info

                if metadata and metadata.bagId and tostring(metadata.bagId) ~= '' then
                    return tostring(metadata.bagId)
                end

                if targetSlot then
                    break
                end
            end
        end
    end

    return nil
end

local function isQuasarInventory()
    return Bridge.Inventory == 'quasar'
end

local function getLocalStash(bagId)
    if not bagId then
        return nil
    end

    localStashes[bagId] = localStashes[bagId] or {
        items = {},
        maxWeight = DEFAULT_BAG_MAX_WEIGHT,
        maxSlots = DEFAULT_BAG_MAX_SLOTS
    }

    return localStashes[bagId]
end

local function getItemCount(item)
    return tonumber(item and (item.amount or item.count or item.quantity)) or 0
end

local function getItemWeight(item)
    return tonumber(item and item.weight) or 0
end

local function getPlayerItems(src)
    local items = {}

    for _, item in pairs(Inventory.GetItems(src)) do
        if item then
            local count = getItemCount(item)

            if count > 0 then
                items[#items + 1] = {
                    name = item.name,
                    label = item.label or item.name,
                    count = count,
                    slot = tonumber(item.slot),
                    weight = getItemWeight(item)
                }
            end
        end
    end

    return items
end

local function getPlayerItemBySlot(src, slot)
    local targetSlot = tonumber(slot)

    if not targetSlot then
        return nil
    end

    for _, item in ipairs(getPlayerItems(src)) do
        if tonumber(item.slot) == targetSlot then
            return item
        end
    end

    return nil
end

local function removeBagFromPlayer(src, slot)
    local removed = false

    if slot then
        removed = Inventory.RemoveItem(src, 'plt_medical_bag', 1, slot)

        if not removed then
            removed = Inventory.RemoveItem(src, 'plt_medical_bag', 1)
        end
    else
        removed = Inventory.RemoveItem(src, 'plt_medical_bag', 1)
    end

    return removed == true
end

local function giveBagToPlayer(src, metadata)
    if Inventory.AddItem(src, 'plt_medical_bag', 1, metadata) then
        return true, true
    end

    if Inventory.AddItem(src, 'plt_medical_bag', 1) then
        return true, false
    end

    return false, false
end

local function getStashWeight(stash)
    local weight = 0

    for _, item in ipairs(stash.items or {}) do
        weight = weight + (tonumber(item.weight) or 0) * (tonumber(item.count) or 0)
    end

    return weight
end

local function findStashItemBySlot(stash, slot)
    local targetSlot = tonumber(slot)

    if not targetSlot then
        return nil, nil
    end

    for index, item in ipairs(stash.items or {}) do
        if tonumber(item.slot) == targetSlot then
            return item, index
        end
    end

    return nil, nil
end

local function getFreeStashSlot(stash)
    local usedSlots = {}

    for _, item in ipairs(stash.items or {}) do
        if item.slot then
            usedSlots[tonumber(item.slot)] = true
        end
    end

    local maxSlots = tonumber(stash.maxSlots) or DEFAULT_BAG_MAX_SLOTS

    for slot = 1, maxSlots do
        if not usedSlots[slot] then
            return slot
        end
    end

    return nil
end

CreateThread(function()
    Wait(1000)

    Framework.CreateUseableItem('plt_medical_bag', function(src, item)
        TriggerClientEvent('amb_client:useMedicalBag', src, item)
    end)
end)

local function buildBagPayload(src, netId)
    local entity = NetworkGetEntityFromNetworkId(netId)

    if not DoesEntityExist(entity) then
        return nil
    end

    local bagId = (droppedBags[netId] and droppedBags[netId].id) or Entity(entity).state.bagId

    if not bagId then
        return nil
    end

    local bagItems = {}
    local bagWeight = 0
    local bagMaxWeight = DEFAULT_BAG_MAX_WEIGHT
    local bagMaxSlots = DEFAULT_BAG_MAX_SLOTS

    if Config.Debug then
        print('^3[PLT_BAG] Fetching inventory for Player: ' .. src .. ' and Bag: ' .. bagId .. '^7')
    end

    if Bridge.Inventory == 'ox' then
        Inventory.RegisterStash(bagId, 'Medical Bag', bagMaxSlots, bagMaxWeight)

        local stash = Inventory.GetInventoryInfo(bagId)

        if stash and stash.items then
            for _, item in pairs(stash.items) do
                local count = getItemCount(item)
                local weight = getItemWeight(item)

                table.insert(bagItems, {
                    name = item.name,
                    label = item.label,
                    count = count,
                    slot = tonumber(item.slot),
                    weight = weight
                })

                bagWeight = bagWeight + (weight * count)
            end
        end
    elseif isQuasarInventory() then
        local stash = getLocalStash(bagId)

        bagMaxWeight = tonumber(stash.maxWeight) or bagMaxWeight
        bagMaxSlots = tonumber(stash.maxSlots) or bagMaxSlots

        for _, item in ipairs(stash.items or {}) do
            local count = getItemCount(item)
            local weight = getItemWeight(item)

            table.insert(bagItems, {
                name = item.name,
                label = item.label or item.name,
                count = count,
                slot = tonumber(item.slot),
                weight = weight
            })

            bagWeight = bagWeight + (weight * count)
        end
    elseif Bridge.Inventory == 'qb' or Bridge.Inventory == 'tgiann' then
        local stash = Inventory.GetInventoryInfo(bagId)

        if stash and stash.items then
            for _, item in pairs(stash.items) do
                local count = getItemCount(item)
                local weight = getItemWeight(item)

                table.insert(bagItems, {
                    name = item.name,
                    label = item.label,
                    count = count,
                    slot = tonumber(item.slot),
                    weight = weight
                })

                bagWeight = bagWeight + (weight * count)
            end
        end
    end

    local playerItems = {}
    local playerWeight = 0
    local playerMaxWeight = 30000
    local playerMaxSlots = 30

    if Bridge.Inventory == 'ox' then
        local inventory = Inventory.GetInventoryInfo(src)

        if inventory and inventory.items then
            if Config.Debug then
                print('^2[PLT_BAG] Ox Inventory detected. Found ' .. #inventory.items .. ' item slots occupied.^7')
            end

            playerMaxWeight = inventory.maxWeight
            playerMaxSlots = inventory.slots

            for _, item in pairs(inventory.items) do
                local count = getItemCount(item)
                local weight = getItemWeight(item)

                table.insert(playerItems, {
                    name = item.name,
                    label = item.label,
                    count = count,
                    slot = tonumber(item.slot),
                    weight = weight
                })

                playerWeight = playerWeight + (weight * count)
            end
        end
    elseif Bridge.Inventory == 'qb' or Bridge.Inventory == 'tgiann'
        or Bridge.Inventory == 'quasar' or Bridge.Inventory == 'origin' then
        local items = getPlayerItems(src)

        if #items > 0 then
            if Config.Debug then
                print('^2[PLT_BAG] QB Inventory detected.^7')
            end

            for _, item in ipairs(items) do
                table.insert(playerItems, item)
                playerWeight = playerWeight + (tonumber(item.weight) or 0) * (tonumber(item.count) or 0)
            end

            playerMaxSlots = 40
            playerMaxWeight = 120000
        end
    end

    if Config.Debug then
        print('^2[PLT_BAG] Total player items formatted: ' .. #playerItems .. '^7')
    end

    return {
        bagId = bagId,
        netId = netId,
        items = bagItems,
        weight = bagWeight,
        maxWeight = bagMaxWeight,
        maxSlots = bagMaxSlots,
        playerItems = playerItems,
        playerWeight = playerWeight,
        playerMaxWeight = playerMaxWeight,
        playerMaxSlots = playerMaxSlots
    }
end

local function isValidBagId(bagId)
    return bagId and tostring(bagId) ~= ''
end

RegisterNetEvent('amb_server:dropMedicalBag', function(coords, heading, bagId, slot)
    local src = source
    local slotNumber = tonumber(slot)
    local resolvedBagId = bagId

    if not isValidBagId(resolvedBagId) then
        resolvedBagId = findBagIdInInventory(src, slotNumber)
    end

    if not isValidBagId(resolvedBagId) then
        resolvedBagId = pendingBagIds[src]
    end

    if not isValidBagId(resolvedBagId) then
        resolvedBagId = generateBagId(slotNumber or src)
    end

    if not removeBagFromPlayer(src, slotNumber) then
        pendingBagIds[src] = resolvedBagId
        TriggerClientEvent('amb_client:Notify', src, 'Failed to drop bag from inventory.', 'error')
        return
    end

    local object = CreateObject(BAG_MODEL, coords.x, coords.y, coords.z - 0.4, true, true, true)

    while not DoesEntityExist(object) do
        Wait(10)
    end

    SetEntityHeading(object, heading)
    FreezeEntityPosition(object, true)

    local netId = NetworkGetNetworkIdFromEntity(object)

    Entity(object).state:set('bagId', resolvedBagId, true)

    droppedBags[netId] = {
        id = resolvedBagId,
        entity = object
    }

    pendingBagIds[src] = nil

    TriggerClientEvent('amb_client:Notify', src, 'Bag dropped.', 'success')
end)

RegisterNetEvent('amb_server:openBagInventory', function(netId)
    local src = source
    local payload = buildBagPayload(src, netId)

    if payload then
        TriggerClientEvent('amb_client:openBagUI', src, payload)
    end
end)

RegisterNetEvent('amb_server:takeBagItem', function(data)
    local src = source
    local bagId = data.bagId
    local slot = data.slot
    local amount = tonumber(data.amount) or 1

    if isQuasarInventory() then
        local stash = getLocalStash(bagId)
        local item, index = findStashItemBySlot(stash, slot)

        if not item then
            return
        end

        local available = tonumber(item.count) or 0

        if available <= 0 then
            return
        end

        local transfer = amount == 0 and available or math.min(amount, available)

        if transfer <= 0 then
            return
        end

        if not Inventory.CanCarryItem(src, item.name, transfer) then
            Framework.Notify(src, _L('cannot_carry_this_much'), 'error')
            return
        end

        if not Inventory.AddItem(src, item.name, transfer) then
            Framework.Notify(src, _L('cannot_carry_this_much'), 'error')
            return
        end

        item.count = available - transfer

        if (tonumber(item.count) or 0) <= 0 then
            table.remove(stash.items, index)
        end

        local payload = buildBagPayload(src, data.netId)

        if payload then
            TriggerClientEvent('amb_client:openBagUI', src, payload)
        end

        return
    end

    if Bridge.Inventory ~= 'ox' then
        Framework.Notify(src, 'Medical bag transfer currently supports ox/quasar inventory modes.', 'error')
        return
    end

    local stash = Inventory.GetInventoryInfo(bagId)
    local stashItems = (stash and stash.items) or {}
    local item = nil

    for _, stashItem in pairs(stashItems) do
        if stashItem.slot == slot then
            item = stashItem
            break
        end
    end

    if not item then
        return
    end

    local transfer = amount == 0 and item.count or math.min(amount, item.count)

    if not Inventory.CanCarryItem(src, item.name, transfer) then
        Framework.Notify(src, _L('cannot_carry_this_much'), 'error')
        return
    end

    Inventory.RemoveItem(bagId, item.name, transfer, slot)
    Inventory.AddItem(src, item.name, transfer)

    Wait(100)

    local payload = buildBagPayload(src, data.netId)

    if payload then
        TriggerClientEvent('amb_client:openBagUI', src, payload)
    end
end)

RegisterNetEvent('amb_server:storeInBag', function(data)
    local src = source
    local bagId = data.bagId
    local slot = data.slot
    local amount = tonumber(data.amount) or 1

    if isQuasarInventory() then
        local item = getPlayerItemBySlot(src, slot)

        if not item or item.name == 'plt_medical_bag' then
            return
        end

        local available = tonumber(item.count) or 0

        if available <= 0 then
            return
        end

        local transfer = amount == 0 and available or math.min(amount, available)

        if transfer <= 0 then
            return
        end

        local stash = getLocalStash(bagId)
        local itemWeight = tonumber(item.weight) or 0
        local newWeight = getStashWeight(stash) + (itemWeight * transfer)

        if newWeight > (tonumber(stash.maxWeight) or DEFAULT_BAG_MAX_WEIGHT) then
            Framework.Notify(src, _L('bag_is_full'), 'error')
            return
        end

        local existing = nil

        for _, stashItem in ipairs(stash.items) do
            if tostring(stashItem.name) == tostring(item.name) then
                existing = stashItem
                break
            end
        end

        if not existing and #stash.items >= (tonumber(stash.maxSlots) or DEFAULT_BAG_MAX_SLOTS) then
            Framework.Notify(src, _L('bag_is_full'), 'error')
            return
        end

        local removed = Inventory.RemoveItem(src, item.name, transfer, item.slot)

        if not removed then
            removed = Inventory.RemoveItem(src, item.name, transfer)
        end

        if not removed then
            Framework.Notify(src, _L('cannot_carry_this_much'), 'error')
            return
        end

        if existing then
            existing.count = (tonumber(existing.count) or 0) + transfer
            existing.weight = itemWeight
            existing.label = existing.label or item.label or item.name
        else
            local freeSlot = getFreeStashSlot(stash)

            if not freeSlot then
                Inventory.AddItem(src, item.name, transfer)
                Framework.Notify(src, _L('bag_is_full'), 'error')
                return
            end

            stash.items[#stash.items + 1] = {
                name = item.name,
                label = item.label or item.name,
                count = transfer,
                slot = freeSlot,
                weight = itemWeight
            }
        end

        local payload = buildBagPayload(src, data.netId)

        if payload then
            TriggerClientEvent('amb_client:openBagUI', src, payload)
        end

        return
    end

    if Bridge.Inventory ~= 'ox' then
        Framework.Notify(src, 'Medical bag transfer currently supports ox/quasar inventory modes.', 'error')
        return
    end

    local inventory = Inventory.GetInventoryInfo(src)
    local playerItems = (inventory and inventory.items) or {}
    local item = nil

    for _, playerItem in pairs(playerItems) do
        if playerItem.slot == slot then
            item = playerItem
            break
        end
    end

    if not item then
        return
    end

    local transfer = amount == 0 and item.count or math.min(amount, item.count)

    if not Inventory.AddItem(bagId, item.name, transfer) then
        Framework.Notify(src, _L('bag_is_full'), 'error')
        return
    end

    Inventory.RemoveItem(src, item.name, transfer, slot)

    Wait(100)

    local payload = buildBagPayload(src, data.netId)

    if payload then
        TriggerClientEvent('amb_client:openBagUI', src, payload)
    end
end)

RegisterNetEvent('amb_server:pickupMedicalBag', function(netId)
    local src = source
    local entity = NetworkGetEntityFromNetworkId(netId)

    if not DoesEntityExist(entity) then
        return
    end

    local bagId = (droppedBags[netId] and droppedBags[netId].id) or Entity(entity).state.bagId
    local coords = GetEntityCoords(entity)
    local heading = GetEntityHeading(entity)

    DeleteEntity(entity)

    droppedBags[netId] = nil

    local metadata = nil

    if bagId then
        metadata = { bagId = bagId }
    end

    local given, withMetadata = giveBagToPlayer(src, metadata)

    if not given then
        local object = CreateObject(BAG_MODEL, coords.x, coords.y, coords.z, true, true, true)

        if DoesEntityExist(object) then
            SetEntityHeading(object, heading)
            FreezeEntityPosition(object, true)

            local newNetId = NetworkGetNetworkIdFromEntity(object)

            Entity(object).state:set('bagId', bagId, true)

            droppedBags[newNetId] = {
                id = bagId,
                entity = object
            }
        end

        Framework.Notify(src, _L('cannot_carry_more_item'), 'error')
        return
    end

    if bagId then
        pendingBagIds[src] = bagId
    end

    if isQuasarInventory() and withMetadata ~= true then
        Framework.Notify(src, 'Bag picked up (metadata fallback active for qs/quasar).', 'info')
    end

    TriggerClientEvent('amb_client:Notify', src, 'Bag picked up.', 'success')
end)

AddEventHandler('playerDropped', function()
    pendingBagIds[source] = nil
end)

