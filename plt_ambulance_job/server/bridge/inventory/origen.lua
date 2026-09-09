if Bridge.Inventory ~= 'origen' then return end

Inventory = Inventory or {}

local RESOURCE = 'origen_inventory'
local Core = exports['qb-core']:GetCoreObject()

local function GetPlayer(src)
    return Core.Functions.GetPlayer(src)
end

local function GetSharedItems()
    return Core.Shared and Core.Shared.Items or {}
end

local function inv()
    return exports[RESOURCE]
end

function Inventory.AddItem(owner, item, amount, metadata, slot)
    if type(metadata) == 'number' and slot == nil then
        slot = metadata
        metadata = nil
    end

    return inv():addItem(owner, item, amount or 1, slot, metadata)
end

function Inventory.RemoveItem(owner, item, amount)
    return inv():removeItem(owner, item, amount or 1)
end

function Inventory.HasItem(src, item, count)
    count = count or 1

    if count <= 1 then
        return inv():HasItem(src, item) == true
    end

    return (Inventory.GetItemCount(src, item) or 0) >= count
end

function Inventory.GetItem(src, item)
    return inv():getItem(src, item)
end

function Inventory.GetItemCount(src, item)
    return inv():getItemCount(src, item) or 0
end

function Inventory.GetItems(owner)
    if type(owner) == 'number' then
        local inventory = inv():GetPlayerInventory(owner)

        if inventory then
            return inventory.items or inventory
        end

        local player = GetPlayer(owner)

        return player and player.PlayerData.items or {}
    end

    return inv():getItems(owner) or {}
end

function Inventory.GetInventoryInfo(owner)
    if type(owner) == 'number' then
        return { items = Inventory.GetItems(owner) }
    end

    local inventory = inv():getInventory(owner)

    if not inventory then
        return nil
    end

    return {
        items = inventory.items or {},
        maxWeight = inventory.maxweight or inventory.maxWeight,
        slots = inventory.slots
    }
end

function Inventory.Clear(src)
    if not GetPlayer(src) then
        return false
    end

    inv():clearInventory(src)

    return true
end

function Inventory.CanCarryItem(owner, item, amount)
    return inv():canCarryItem(owner, item, amount or 1) == true
end

local knownStashes = {}

function Inventory.RegisterStash(stashId, label, slots, maxWeight)
    if not knownStashes[stashId] then
        inv():RegisterStash(stashId, {
            label = label or stashId,
            slots = slots or 80,
            weight = maxWeight or 400000
        })

        knownStashes[stashId] = true
    end

    return true
end

function Inventory.OpenStashFor(src, stashId)
    inv():OpenInventory(src, 'stash', stashId)

    return true
end

RegisterNetEvent('plt_amb_origen:openStash', function(stashId, label, slots, maxWeight)
    local src = source

    stashId = tostring(stashId or '')

    if stashId:sub(1, 8) ~= 'plt_amb_' then
        return
    end

    Inventory.RegisterStash(stashId, label, tonumber(slots), tonumber(maxWeight))
    Inventory.OpenStashFor(src, stashId)
end)

function Inventory.GetItemLabel(itemName)
    local item = GetSharedItems()[itemName]

    return item and item.label or itemName
end

function Inventory.GetSystem()
    return RESOURCE
end

function Inventory.GetItemData(itemName)
    local item = GetSharedItems()[itemName]

    if not item then
        return { name = itemName, label = itemName, image = itemName }
    end

    return {
        name = itemName,
        label = item.label or itemName,
        image = item.image or itemName
    }
end

