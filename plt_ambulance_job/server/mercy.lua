--[[
    ------------------------------------------------------------
    Mercy / "finished" system (server side)
    ------------------------------------------------------------
    A downed player who is shot in the head, kicked / melee-hit, run over by a
    vehicle or hit by ANY other damage is "finished". While finished:

    * medics CANNOT revive them - every revive attempt is refused with an error
      notification; the only thing EMS can do is body-bag the body;
    * their dispatch calls are closed so no medic is navigated to a corpse;
    * a timer (Config.Mercy.RespawnSeconds, 10 minutes by default) runs; when it
      ends, everything in the player's ox_inventory is wiped (or dropped at the
      body if Config.Mercy.DropInventory = true) and the player is revived and
      respawned at the hospital.

    The damage detection happens on the patient's own client (it knows what hit
    it); the server stays authoritative about the state change.
]]

local finishedPlayers = {}

local function mercyEnabled()
    return not (Config.Mercy and Config.Mercy.Enabled == false)
end

local function respawnSeconds()
    return math.max(30, tonumber(Config.Mercy and Config.Mercy.RespawnSeconds) or 600)
end

local function isFinished(src)
    return finishedPlayers[tonumber(src) or 0] == true
end

exports('IsPlayerFinished', isFinished)

local function broadcastFinished(src, state)
    for _, playerId in ipairs(Framework.GetPlayers()) do
        local id = tonumber(playerId)

        if id then
            TriggerClientEvent('amb_client:syncFinishedPlayer', id, src, state)
        end
    end
end

local function isPlayerOnline(src)
    for _, playerId in ipairs(Framework.GetPlayers()) do
        if tonumber(playerId) == src then
            return true
        end
    end

    return false
end

local function hospitalRespawn(src)
    if not finishedPlayers[src] then
        return
    end

    if not isPlayerOnline(src) then
        finishedPlayers[src] = nil
        return
    end

    -- Wipe the player's entire ox_inventory before they leave. Everything they
    -- were carrying is gone. Set Config.Mercy.DropInventory = true to keep the
    -- old behaviour of dropping the items at the body instead (or
    -- Config.Mercy.ClearInventory = false to keep the items).
    if GetResourceState('ox_inventory') == 'started' then
        if Config.Mercy and Config.Mercy.DropInventory == true then
            pcall(function()
                exports.ox_inventory:CreateDropFromPlayer(src)
            end)
        elseif not Config.Mercy or Config.Mercy.ClearInventory ~= false then
            pcall(function()
                if Inventory and Inventory.Clear then
                    Inventory.Clear(src)
                end
            end)
        end
    end

    finishedPlayers[src] = nil

    broadcastFinished(src, false)

    -- Revive first (clears downed/medical state), then let the client move the
    -- player to the hospital and play the wake-up animation.
    pcall(function()
        exports.plt_ambulance_job:InternalRevive(src)
    end)

    TriggerClientEvent('amb_client:finishedRespawn', src)
end

RegisterNetEvent('amb_server:finishPlayer', function()
    local src = source

    if not mercyEnabled() then
        return
    end

    if finishedPlayers[src] then
        return
    end

    if not exports.plt_ambulance_job:IsPlayerDowned(src) then
        return
    end

    finishedPlayers[src] = true

    broadcastFinished(src, true)

    -- Nobody is coming any more: close every dispatch call filed for them.
    pcall(function()
        exports.plt_ambulance_job:ClosePatientCalls(src)
    end)

    Framework.Notify(src, _L('player_finished_self', {
        minutes = math.floor(respawnSeconds() / 60)
    }), 'error')

    print(('^2[Mercy]^7 Player %s was FINISHED. Hospital respawn in %ss.'):format(
        tostring(src), respawnSeconds()))

    SetTimeout(respawnSeconds() * 1000, function()
        hospitalRespawn(src)
    end)
end)
