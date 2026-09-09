-- ESX built-in inventory bridge (server side).
--
-- This file did not exist before, which is why every pharmacy / medical-bag /
-- boss-menu code path that touches `Inventory.*` blew up with
-- "attempt to index a nil value (global 'Inventory')" on an ESX server that
-- has no ox_inventory / qb-inventory installed. Money was checked, then the
-- handler errored out before it could deduct it - so nothing was taken and
-- nothing was given.
--
-- ESX's built-in inventory has no metadata and no slot ids, so anything that
-- relies on those (prescription slots, stashes) degrades to a safe no-op
-- instead of crashing the event handler.

if Bridge.Inventory ~= 'esx' then return end
if GetResourceState('es_extended') ~= 'started' then return end

Inventory = Inventory or {}

local Core = exports['es_extended']:getSharedObject()

-- NOTE: es_extended builds each xPlayer inside a factory, so its methods close
-- over the player and are called with `player.method(args)` - NOT
-- `player:method(args)`. Passing the player as the first argument shifts every
-- parameter by one and silently corrupts the call.

local function GetPlayer(src)
    src = tonumber(src)

    if not src then
        return nil
    end

    return Core.GetPlayerFromId(src)
end

local function GetSharedItems()
    local ok, items = pcall(Core.GetItems)

    if ok and type(items) == 'table' then
        return items
    end

    return {}
end

local function getItemCount(item)
    if type(item) ~= 'table' then
        return 0
    end

    return tonumber(item.count or item.amount or item.quantity or 0) or 0
end

local function debugWarn(message)
    if Config.Debug then
        print(('^3[plt_ambulance_job][esx-inventory]^7 %s'):format(message))
    end
end

-- Normalises the flat ESX inventory list into the { name, slot, count, info }
-- shape the rest of the script expects. `slot` is just the list position, which
-- keeps the `item.slot or index` fallbacks in the callers working.
local function normalizeItems(player)
    local raw = player.getInventory()
    local out = {}

    if type(raw) ~= 'table' then
        return out
    end

    local index = 0

    for _, item in pairs(raw) do
        if type(item) == 'table' and item.name then
            index = index + 1

            out[index] = {
                name = item.name,
                label = item.label or item.name,
                count = getItemCount(item),
                amount = getItemCount(item),
                slot = tonumber(item.slot) or index,
                weight = tonumber(item.weight) or 0,
                metadata = item.metadata,
                info = item.info
            }
        end
    end

    return out
end

function Inventory.GetSystem()
    return 'es_extended'
end

function Inventory.GetItems(owner)
    local player = GetPlayer(owner)

    if not player then
        return {}
    end

    return normalizeItems(player)
end

function Inventory.GetInventoryInfo(owner)
    local player = GetPlayer(owner)

    if not player then
        return nil
    end

    local info = { items = normalizeItems(player) }

    local ok, maxWeight = pcall(player.getMaxWeight)

    if ok and maxWeight then
        info.maxWeight = tonumber(maxWeight)
    end

    return info
end

function Inventory.AddItem(owner, item, amount, metadata, slot)
    local player = GetPlayer(owner)

    if not player then
        return false
    end

    amount = math.max(1, math.floor(tonumber(amount) or 1))

    if metadata ~= nil and next(type(metadata) == 'table' and metadata or {}) ~= nil then
        debugWarn(('Dropping metadata for %s - ESX built-in inventory has no metadata support.'):format(tostring(item)))
    end

    if slot ~= nil then
        debugWarn(('Ignoring slot %s for %s - ESX built-in inventory has no slots.'):format(tostring(slot), tostring(item)))
    end

    local ok = pcall(player.addInventoryItem, item, amount)

    return ok
end

function Inventory.RemoveItem(owner, item, amount, slot)
    local player = GetPlayer(owner)

    if not player then
        return false
    end

    amount = math.max(1, math.floor(tonumber(amount) or 1))

    if Inventory.GetItemCount(owner, item) < amount then
        return false
    end

    if slot ~= nil then
        debugWarn(('Ignoring slot %s for %s - ESX built-in inventory has no slots.'):format(tostring(slot), tostring(item)))
    end

    local ok = pcall(player.removeInventoryItem, item, amount)

    return ok
end

function Inventory.HasItem(owner, item, count)
    return Inventory.GetItemCount(owner, item) >= (tonumber(count) or 1)
end

function Inventory.GetItemCount(owner, item)
    local player = GetPlayer(owner)

    if not player then
        return 0
    end

    local total = 0

    for _, entry in pairs(normalizeItems(player)) do
        if entry.name == item then
            total = total + entry.count
        end
    end

    return total
end

function Inventory.GetItem(owner, item)
    for _, entry in pairs(Inventory.GetItems(owner)) do
        if entry.name == item then
            return entry
        end
    end

    return nil
end

function Inventory.CanCarryItem(owner, item, amount)
    local player = GetPlayer(owner)

    if not player then
        return false
    end

    amount = math.max(1, math.floor(tonumber(amount) or 1))

    -- ESX Legacy exposes canCarryItem; older builds do not.
    if type(player.canCarryItem) == 'function' then
        local ok, result = pcall(player.canCarryItem, item, amount)

        if ok then
            return result == true
        end
    end

    return true
end

function Inventory.Clear(src)
    local player = GetPlayer(src)

    if not player then
        return false
    end

    for _, entry in pairs(normalizeItems(player)) do
        if entry.count > 0 then
            pcall(player.removeInventoryItem, entry.name, entry.count)
        end
    end

    return true
end

-- ESX's built-in inventory has no concept of a stash. Everything below keeps
-- the callers (medical bag, department safe) from erroring out and makes them
-- report "unable to open" instead. Install ox_inventory for real stash support.
function Inventory.RegisterStash()
    debugWarn('Stash support requires ox_inventory - install it or the medical bag / department safe will stay disabled.')

    return false
end

function Inventory.OpenStashFor()
    return false
end

function Inventory.GetItemLabel(itemName)
    local item = GetSharedItems()[itemName]

    return item and item.label or itemName
end

function Inventory.GetItemData(itemName)
    local item = GetSharedItems()[itemName]

    if not item then
        return { name = itemName, label = itemName, image = itemName }
    end

    return {
        name = itemName,
        label = item.label or itemName,
        image = itemName
    }
end
