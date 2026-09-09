if Bridge.Inventory ~= 'origen' then return end

Inventory = Inventory or {}

local hasItemCache = {}
local hasItemCacheTime = 0

local function clearCache()
    hasItemCache = {}
    hasItemCacheTime = 0
end

local function getItems()
    local playerData = exports['qb-core']:GetCoreObject().Functions.GetPlayerData()

    return playerData and playerData.items or {}
end

local function getCount(item)
    local count = 0

    for _, entry in pairs(getItems()) do
        if entry and entry.name == item then
            count = count + (tonumber(entry.amount or entry.count or entry.quantity or 0) or 0)
        end
    end

    return count
end

function Inventory.GetItemCount(item)
    return getCount(item)
end

function Inventory.HasItem(item)
    local now = GetGameTimer()

    if hasItemCacheTime > 0 and (now - hasItemCacheTime) < 1000 and hasItemCache[item] ~= nil then
        return hasItemCache[item]
    end

    local has = getCount(item) > 0

    hasItemCache[item] = has
    hasItemCacheTime = now

    return has
end

function Inventory.OpenStash(stashId, label, maxWeight, slots)
    TriggerServerEvent('plt_amb_origen:openStash', stashId, label, slots, maxWeight)

    return true
end

function Inventory.Close()
    TriggerEvent('origen_inventory:closeInventory')
end

RegisterNetEvent('origen_inventory:updateInventory', clearCache)
RegisterNetEvent('QBCore:Player:SetPlayerData', clearCache)
RegisterNetEvent('QBCore:Player:UpdatePlayerData', clearCache)

