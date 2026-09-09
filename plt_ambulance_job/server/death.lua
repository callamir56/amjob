--[[
    ------------------------------------------------------------------
    PLT AMBULANCE - DEATH SYSTEM (rebuilt from scratch, server side)
    ------------------------------------------------------------------
    The server stays authoritative about the finished state:

      * marks the player finished (medics can only body-bag, every revive
        is refused);
      * closes the player's dispatch calls;
      * runs the hospital timer (Config.DeathSystem.RespawnSeconds, 10
        minutes by default);
      * when the timer ends: wipes the player's ENTIRE ox_inventory,
        revives them and respawns them at the hospital.

    Events / exports (same names as before so nothing else breaks):
      client -> 'amb_server:finishPlayer'
      export    IsPlayerFinished(src)
      broadcast 'amb_client:syncFinishedPlayer'
]]

local finishedPlayers = {}

local function deathSystemEnabled()
    return not (Config.DisableDeathSystem == true
        or (Config.DeathSystem and Config.DeathSystem.Enabled == false))
end

local function respawnSeconds()
    local seconds = (Config.DeathSystem and Config.DeathSystem.RespawnSeconds)
        or (Config.Mercy and Config.Mercy.RespawnSeconds)

    return math.max(30, tonumber(seconds) or 600)
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

    -- Wipe the player's ENTIRE ox_inventory. Everything they were carrying is
    -- gone. Config.Mercy.DropInventory = true keeps the old behaviour of
    -- dropping the items at the body instead.
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

    -- Revive first (clears the downed / medical state), then the client moves
    -- the player to the hospital and plays the wake-up animation.
    pcall(function()
        exports.plt_ambulance_job:InternalRevive(src)
    end)

    TriggerClientEvent('amb_client:finishedRespawn', src)

    print(('^2[DEATH]^7 Player %s hospital respawn: inventory wiped, revived and teleported.'):format(
        tostring(src)))
end

RegisterNetEvent('amb_server:finishPlayer', function()
    local src = source

    if not deathSystemEnabled() then
        return
    end

    if finishedPlayers[src] then
        return
    end

    if not exports.plt_ambulance_job:IsPlayerDowned(src) then
        -- The client sends the downed state and the finish event back to back;
        -- if they arrive out of order the client steps back to downed and
        -- retries automatically.
        TriggerClientEvent('amb_client:finishRefused', src)

        print(('^3[DEATH]^7 Player %s finish refused: not downed.'):format(tostring(src)))

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

    print(('^2[DEATH]^7 Player %s was FINISHED. Hospital respawn in %ss.'):format(
        tostring(src), respawnSeconds()))

    SetTimeout(respawnSeconds() * 1000, function()
        hospitalRespawn(src)
    end)
end)

-- Debug helper: clears the finished state of the calling player and stands
-- them back up (used with the client /mercyreset command while testing).
RegisterNetEvent('amb_server:clearFinished', function()
    local src = source

    finishedPlayers[src] = nil

    broadcastFinished(src, false)

    pcall(function()
        exports.plt_ambulance_job:InternalRevive(src)
    end)

    Framework.Notify(src, 'Death state cleared (debug).', 'success')

    print(('^2[DEATH]^7 Player %s finished state cleared (debug).'):format(tostring(src)))
end)
