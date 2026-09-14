--[[
    ------------------------------------------------------------------
    PLT AMBULANCE - DEATH SYSTEM (server side)
    ------------------------------------------------------------------
    The server stays authoritative about every death state:

      * downed time stamps (server clock) -> accurate, non-cheatable
        death timer and GIVE UP unlock;
      * killer info (id / weapon) validated and name resolved;
      * FINISH state: only the server marks a player finished;
      * EXECUTE: every condition is re-validated server side (target
        downed, distance, states, double-execute guard);
      * GIVE UP: only after the configured time;
      * bleed out: only after the death timer actually elapsed;
      * disconnect / resource restart cleanup.

    Events / exports (same names as the rest of the resource):
      client -> 'amb_server:finishPlayer', 'amb_server:executeStart',
                'amb_server:cancelExecute', 'amb_server:executePlayer',
                'amb_server:giveUp', 'amb_server:reportDeathKiller'
      export    IsPlayerFinished(src)
      broadcast 'amb_client:syncFinishedPlayer'
]]

local finishedPlayers = {}
local downedAt = {}
local killerInfo = {}
local executingPlayers = {}
local executingTargets = {}

local function deathSystemEnabled()
    return not (Config.DisableDeathSystem == true
        or (Config.DeathSystem and Config.DeathSystem.Enabled == false))
end

local function deathTimerSeconds()
    return math.max(1, tonumber(Config.DeathSystem and Config.DeathSystem.DeathTimer) or 600)
end

local function giveUpTime()
    return math.max(0, tonumber(Config.DeathSystem and Config.DeathSystem.GiveUpTime) or 60)
end

local function executeDistance()
    return math.max(0.5, tonumber(Config.DeathSystem and Config.DeathSystem.ExecuteDistance) or 2.0)
end

local function executeTime()
    return math.max(500, tonumber(Config.DeathSystem and Config.DeathSystem.ExecuteTime) or 5000)
end

local function executeEnabled()
    return not (Config.DeathSystem and Config.DeathSystem.ExecuteEnabled == false)
end

local function respawnEnabled()
    return not (Config.DeathSystem and Config.DeathSystem.RespawnEnabled == false)
end

local function respawnSeconds()
    return math.max(30, tonumber(Config.DeathSystem and Config.DeathSystem.RespawnSeconds) or 600)
end

local function isFinished(src)
    return finishedPlayers[tonumber(src) or 0] == true
end

exports('IsPlayerFinished', isFinished)

local function isPlayerOnline(src)
    for _, playerId in ipairs(Framework.GetPlayers()) do
        if tonumber(playerId) == src then
            return true
        end
    end

    return false
end

local function getPlayerName(src)
    local player = Framework.GetPlayer(src)

    if player and player.name and tostring(player.name) ~= '' then
        return tostring(player.name)
    end

    local raw = GetPlayerName(src)

    if raw and tostring(raw) ~= '' then
        return tostring(raw)
    end

    return 'UNKNOWN'
end

local function broadcastFinished(src, state)
    for _, playerId in ipairs(Framework.GetPlayers()) do
        local id = tonumber(playerId)

        if id then
            TriggerClientEvent('amb_client:syncFinishedPlayer', id, src, state)
        end
    end
end

local function elapsedSinceDown(src)
    local at = downedAt[src]

    if not at then
        return 0
    end

    return math.max(0, os.time() - at)
end

-- The shared finish routine. Only the server flips the finished state.
local hospitalRespawn
local scheduleHospitalRespawn

-- ---------------------------------------------------------------
-- Reconnect persistence (server-side, identifier-keyed)
-- ---------------------------------------------------------------
-- The death state survives reconnects: every down / finish is saved under
-- the player's stable identifier (ESX identifier / QB citizenid), in memory
-- for the running session AND in the existing plt_ambulance_job_data table
-- through oxmysql when it is available (so it also survives restarts).
-- Stored: 'downed' vs 'finished', the save time, and the killer info for
-- the UI. ONLY a real revive clears it (EMS revive echo, hospital respawn,
-- debug clear) - loading into the server never does.
local persistedDeathStates = {}
local DEATHSTATE_KEY_PREFIX = 'deathstate:'

local function getIdentifier(src)
    if Framework and Framework.GetPlayerIdentifier then
        local ok, identifier = pcall(Framework.GetPlayerIdentifier, src)

        if ok and identifier and tostring(identifier) ~= '' then
            return tostring(identifier)
        end
    end

    local identifiers = GetPlayerIdentifiers(src) or {}

    for _, id in ipairs(identifiers) do
        if type(id) == 'string' and id:sub(1, 8) == 'license:' then
            return id
        end
    end

    return identifiers[1]
end

local function deathStateKey(identifier)
    return DEATHSTATE_KEY_PREFIX .. tostring(identifier)
end

local function dbFetchRow(identifier)
    if MySQL_Sync == nil or MySQL_Sync.fetchAll == nil then
        return nil
    end

    local ok, rows = pcall(MySQL.Sync.fetchAll,
        'SELECT `value` FROM `plt_ambulance_job_data` WHERE `key` = ? LIMIT 1',
        { deathStateKey(identifier) })

    if not ok or type(rows) ~= 'table' or #rows == 0 then
        return nil
    end

    local value = rows[1] and rows[1].value

    if type(value) ~= 'string' or value == '' then
        return nil
    end

    local decodedOk, row = pcall(json.decode, value)

    if not decodedOk or type(row) ~= 'table' then
        return nil
    end

    return row
end

local function dbWriteRow(identifier, row)
    if MySQL == nil or MySQL.Async == nil or MySQL.Async.execute == nil then
        return
    end

    pcall(MySQL.Async.execute,
        'INSERT INTO `plt_ambulance_job_data` (`key`, `value`) VALUES (?, ?)' ..
        ' ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)',
        { deathStateKey(identifier), json.encode(row) })
end

local function dbDeleteRow(identifier)
    if MySQL == nil or MySQL.Async == nil or MySQL.Async.execute == nil then
        return
    end

    pcall(MySQL.Async.execute,
        'DELETE FROM `plt_ambulance_job_data` WHERE `key` = ?',
        { deathStateKey(identifier) })
end

local function getPersistedDeathState(identifier)
    if not identifier then
        return nil
    end

    local row = persistedDeathStates[identifier]

    if type(row) == 'table' then
        return row
    end

    -- Not in memory (e.g. after a restart): fall back to the database.
    row = dbFetchRow(identifier)

    if type(row) == 'table' then
        persistedDeathStates[identifier] = row
    end

    return row
end

local function persistDeathState(src, state)
    if not deathSystemEnabled() then
        return
    end

    local identifier = getIdentifier(src)

    if not identifier then
        return
    end

    local killer = killerInfo[src]

    if type(killer) ~= 'table' then
        killer = { src = 0, name = 'UNKNOWN', weaponHash = 0 }
    end

    local row = {
        state = state,
        at = os.time(),
        killer = {
            src = tonumber(killer.src) or 0,
            name = tostring(killer.name or 'UNKNOWN'),
            weaponHash = tonumber(killer.weaponHash) or 0,
        },
    }

    persistedDeathStates[identifier] = row
    dbWriteRow(identifier, row)
end

local function clearPersistedDeathState(src)
    local identifier = src and getIdentifier(src) or nil

    if not identifier then
        return
    end

    persistedDeathStates[identifier] = nil
    dbDeleteRow(identifier)
end

-- Pulled by the client once after (re)spawning. Rehydrates the server-side
-- tables and hands the persisted state back so the client re-enters it.
-- Fresh timestamps: the bleed-out / hospital clocks restart on reconnect -
-- the STATE is what persists, nobody bleeds out while offline.
Framework.CreateCallback('amb_server:getPersistedDeathState', function(_, cb)
    local src = source

    if not deathSystemEnabled() then
        cb(nil)
        return
    end

    local identifier = getIdentifier(src)
    local row = getPersistedDeathState(identifier)

    if type(row) ~= 'table' or (row.state ~= 'downed' and row.state ~= 'finished') then
        cb(nil)
        return
    end

    downedAt[src] = os.time()

    if type(row.killer) == 'table' then
        killerInfo[src] = {
            src = tonumber(row.killer.src) or 0,
            name = tostring(row.killer.name or 'UNKNOWN'),
            weaponHash = tonumber(row.killer.weaponHash) or 0,
        }

        TriggerClientEvent('amb_client:deathKillerInfo', src, killerInfo[src])
    end

    if row.state == 'finished' then
        finishedPlayers[src] = true

        broadcastFinished(src, true)

        -- Fresh hospital clock for the restored corpse (downedAt was reset
        -- above, so this schedules a full fresh duration), matching the
        -- fresh mercy timer the client shows.
        scheduleHospitalRespawn(src)
    end

    -- Restored DOWNED needs nothing else here: the client's enterDowned echo
    -- (amb_server:SetDowned) completes the server-side bookkeeping.

    print(('^2[DEATH]^7 Player %s reconnected, restored persisted state: %s.'):format(
        tostring(src), tostring(row.state)))

    cb({ state = row.state })
end)

local function finishPlayer(src, reason, killerSrc, killerWeapon)
    if finishedPlayers[src] then
        return false
    end

    if not exports.plt_ambulance_job:IsPlayerDowned(src) then
        return false
    end

    finishedPlayers[src] = true

    broadcastFinished(src, true)

    -- Nobody is coming any more: close every dispatch call filed for them.
    pcall(function()
        exports.plt_ambulance_job:ClosePatientCalls(src)
    end)

    -- Killer info for the UI (validated / resolved by the server).
    local killer = killerInfo[src] or {}

    if killerSrc and killerSrc ~= src then
        killer = {
            src = killerSrc,
            name = getPlayerName(killerSrc),
            weaponHash = killerWeapon or 0
        }

        killerInfo[src] = killer
    end

    TriggerClientEvent('amb_client:deathKillerInfo', src, killer)

    -- Persisted for reconnects (only a real revive clears it again). Saved
    -- AFTER the killer resolution above so an execute persists the executor.
    persistDeathState(src, 'finished')

    Framework.Notify(src, _L('player_finished_self'), 'error')

    print(('^2[DEATH]^7 Player %s was FINISHED (reason: %s, killer: %s).'):format(
        tostring(src), tostring(reason), tostring(killer.src or 'UNKNOWN')))

    scheduleHospitalRespawn(src)

    return true
end

-- Hospital respawn is scheduled against the CONTINUOUS death clock (downed
-- moment + RespawnSeconds), so it lands exactly when the client's
-- never-resetting display reaches 00:00 - FINISH does not restart the
-- timer. A small grace keeps an already-expired clock from respawning in
-- the same instant as the finish.
scheduleHospitalRespawn = function(src)
    if not respawnEnabled() then
        return
    end

    local remaining = respawnSeconds() - elapsedSinceDown(src)

    if remaining < 5 then
        remaining = 5
    end

    SetTimeout(math.floor(remaining * 1000), function()
        hospitalRespawn(src)
    end)
end

hospitalRespawn = function(src)
    if not finishedPlayers[src] then
        return
    end

    if not isPlayerOnline(src) then
        finishedPlayers[src] = nil
        return
    end

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

    -- Hospital respawn revives for real: the persisted state is cleared.
    clearPersistedDeathState(src)

    broadcastFinished(src, false)

    pcall(function()
        exports.plt_ambulance_job:InternalRevive(src)
    end)

    TriggerClientEvent('amb_client:finishedRespawn', src)

    print(('^2[DEATH]^7 Player %s hospital respawn: inventory wiped, revived and teleported.'):format(
        tostring(src)))
end

-- ---------------------------------------------------------------
-- Downed bookkeeping (server clock stamps)
-- ---------------------------------------------------------------
-- The main SetDowned handler lives in server/health.lua; this second handler
-- only records the downed time for the death timer / give-up checks.
RegisterNetEvent('amb_server:SetDowned', function(downed)
    local src = source

    if not deathSystemEnabled() then
        return
    end

    if downed == true then
        if not downedAt[src] then
            downedAt[src] = os.time()
        end

        -- Keep killer info fresh for every new down.
        if not killerInfo[src] then
            killerInfo[src] = { src = 0, name = 'UNKNOWN', weaponHash = 0 }
        end

        -- Eager save: the state must already be stored if the player drops
        -- right after going down. A finished player stays 'finished'.
        persistDeathState(src, finishedPlayers[src] and 'finished' or 'downed')
    else
        -- A real revive reached the server: the persisted state is cleared,
        -- the player truly lives again.
        clearPersistedDeathState(src)

        downedAt[src] = nil
        killerInfo[src] = nil
        executingPlayers[src] = nil
        executingTargets[src] = nil
    end
end)

-- Killer info captured by the victim's client at the moment of death. The
-- server only keeps it when the killer id is a real online player.
RegisterNetEvent('amb_server:reportDeathKiller', function(killerSrc, weaponHash)
    local src = source

    if not deathSystemEnabled() then
        return
    end

    if not exports.plt_ambulance_job:IsPlayerDowned(src) then
        return
    end

    local id = tonumber(killerSrc) or 0
    local hash = tonumber(weaponHash) or 0

    if id > 0 and id ~= src and isPlayerOnline(id) then
        killerInfo[src] = {
            src = id,
            name = getPlayerName(id),
            weaponHash = hash
        }

        TriggerClientEvent('amb_client:deathKillerInfo', src, killerInfo[src])

        print(('^2[DEATH]^7 Player %s downed. Killer: %s (id %s, weapon %s).'):format(
            tostring(src), getPlayerName(id), tostring(id), tostring(hash)))
    else
        killerInfo[src] = { src = 0, name = 'UNKNOWN', weaponHash = hash or 0 }
    end

    -- The killer report lands after the down-save: persist again so a
    -- reconnect still shows the right KILLED BY block.
    persistDeathState(src, finishedPlayers[src] and 'finished' or 'downed')
end)

-- Server-authoritative elapsed downed time (used by the client for the
-- accurate countdown and the give-up state).
Framework.CreateCallback('amb_server:getDeathElapsed', function(_, cb)
    local src = source

    if deathSystemEnabled() and downedAt[src] then
        cb(os.time() - downedAt[src])
    else
        cb(0)
    end
end)

-- ---------------------------------------------------------------
-- Finish (damage while downed / bleed out / give up)
-- ---------------------------------------------------------------
RegisterNetEvent('amb_server:finishPlayer', function(reason)
    local src = source

    if not deathSystemEnabled() then
        return
    end

    if finishedPlayers[src] then
        return
    end

    if not exports.plt_ambulance_job:IsPlayerDowned(src) then
        TriggerClientEvent('amb_client:finishRefused', src)

        print(('^3[DEATH]^7 Player %s finish refused: not downed.'):format(tostring(src)))

        return
    end

    reason = tostring(reason or 'damage')

    -- DAMAGE/DEATH logic is strictly separated from FINISH/EXECUTE logic:
    -- this event ONLY accepts the real, server-checked completion reasons.
    -- Arbitrary or damage-flavoured reasons (e.g. 'damage', or any
    -- hit-bone based auto-finish from other callers) can NEVER finish a
    -- player - a headshot or any other lethal damage always lands in
    -- UNCONSCIOUS first; FINISHED is only reachable through execute (which
    -- never passes through this event), the checked timer, or give up.
    local elapsed = elapsedSinceDown(src)

    if reason == 'timer' then
        -- Server-side time check: the client cannot bleed out early.
        if elapsed < (deathTimerSeconds() - 5) then
            print(('^3[DEATH]^7 Player %s timer finish refused: only %ss elapsed.'):format(
                tostring(src), tostring(elapsed)))

            return
        end
    elseif reason == 'giveup' then
        -- Server-side time check: the client cannot give up early.
        if elapsed < (giveUpTime() - 2) then
            Framework.Notify(src, _L('give_up_unavailable'), 'error')

            return
        end
    else
        print(('^3[DEATH]^7 Player %s finish ignored: invalid reason "%s".'):format(
            tostring(src), tostring(reason)))

        return
    end

    finishPlayer(src, reason)
end)

-- ---------------------------------------------------------------
-- Execute (finish the downed player with a progress bar)
-- ---------------------------------------------------------------
Framework.CreateCallback('amb_server:executeStart', function(_, cb, targetId)
    local src = source

    if not deathSystemEnabled() or not executeEnabled() then
        cb(false, 'invalid')
        return
    end

    targetId = tonumber(targetId)

    if not targetId or targetId == src or not isPlayerOnline(targetId) then
        cb(false, 'invalid')
        return
    end

    -- Executor must be alive and free.
    if finishedPlayers[src] or exports.plt_ambulance_job:IsPlayerDowned(src) then
        cb(false, 'invalid')
        return
    end

    -- Target must be downed, not finished, not already being executed.
    if finishedPlayers[targetId]
        or not exports.plt_ambulance_job:IsPlayerDowned(targetId) then
        cb(false, 'target')
        return
    end

    if executingTargets[targetId] or executingPlayers[src] then
        cb(false, 'busy')
        return
    end

    -- Distance validation.
    local executorPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)

    if executorPed and executorPed > 0 and targetPed and targetPed > 0 then
        local distance = #(GetEntityCoords(executorPed) - GetEntityCoords(targetPed))

        if distance > executeDistance() + 0.5 then
            cb(false, 'distance')
            return
        end
    end

    executingPlayers[src] = targetId
    executingTargets[targetId] = src

    TriggerClientEvent('amb_client:executionStarted', targetId, src, getPlayerName(src))

    -- Safety net: if the client never confirms/cancels, clear the guard.
    SetTimeout(executeTime() + 10000, function()
        if executingPlayers[src] == targetId then
            executingPlayers[src] = nil
            executingTargets[targetId] = nil
            TriggerClientEvent('amb_client:executionStopped', targetId)
        end
    end)

    print(('^2[DEATH]^7 Player %s started executing player %s.'):format(
        tostring(src), tostring(targetId)))

    cb(true)
end)

RegisterNetEvent('amb_server:cancelExecute', function(targetId)
    local src = source

    targetId = tonumber(targetId)

    if executingPlayers[src] == targetId then
        executingPlayers[src] = nil
        executingTargets[targetId] = nil

        TriggerClientEvent('amb_client:executionStopped', targetId)
    end
end)

RegisterNetEvent('amb_server:executePlayer', function(targetId)
    local src = source

    if not deathSystemEnabled() or not executeEnabled() then
        return
    end

    targetId = tonumber(targetId)

    if not targetId or targetId == src then
        return
    end

    if executingPlayers[src] ~= targetId then
        return
    end

    -- Re-validate everything at completion time.
    if not isPlayerOnline(targetId) then
        executingPlayers[src] = nil
        executingTargets[targetId] = nil
        return
    end

    if finishedPlayers[targetId]
        or not exports.plt_ambulance_job:IsPlayerDowned(targetId) then
        executingPlayers[src] = nil
        executingTargets[targetId] = nil
        TriggerClientEvent('amb_client:executionStopped', targetId)
        TriggerClientEvent('amb_client:executeInvalid', src, 'target')
        return
    end

    if finishedPlayers[src] or exports.plt_ambulance_job:IsPlayerDowned(src) then
        executingPlayers[src] = nil
        executingTargets[targetId] = nil
        TriggerClientEvent('amb_client:executionStopped', targetId)
        TriggerClientEvent('amb_client:executeInvalid', src, 'self')
        return
    end

    local executorPed = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetId)

    if executorPed and executorPed > 0 and targetPed and targetPed > 0 then
        local distance = #(GetEntityCoords(executorPed) - GetEntityCoords(targetPed))

        if distance > executeDistance() + 0.5 then
            executingPlayers[src] = nil
            executingTargets[targetId] = nil
            TriggerClientEvent('amb_client:executionStopped', targetId)
            TriggerClientEvent('amb_client:executeInvalid', src, 'distance')
            return
        end
    end

    executingPlayers[src] = nil
    executingTargets[targetId] = nil

    -- The executor's weapon at completion time.
    local weaponHash = 0

    if executorPed and executorPed > 0 then
        local _, currentWeapon = GetCurrentPedWeapon(executorPed, true)

        weaponHash = tonumber(currentWeapon) or 0
    end

    if finishPlayer(targetId, 'execute', src, weaponHash) then
        Framework.Notify(src, _L('execute_success'), 'success')
    end
end)

-- ---------------------------------------------------------------
-- Give up
-- ---------------------------------------------------------------
RegisterNetEvent('amb_server:giveUp', function()
    local src = source

    if not deathSystemEnabled() then
        return
    end

    if finishedPlayers[src] then
        return
    end

    if not exports.plt_ambulance_job:IsPlayerDowned(src) then
        return
    end

    local elapsed = elapsedSinceDown(src)

    if elapsed < giveUpTime() then
        Framework.Notify(src, _L('give_up_unavailable'), 'error')
        return
    end

    finishPlayer(src, 'giveup')
end)

-- ---------------------------------------------------------------
-- Cleanup: disconnect + resource restart
-- ---------------------------------------------------------------
AddEventHandler('playerDropped', function(reason)
    local src = source

    if not deathSystemEnabled() then
        return
    end

    -- The player who dropped was possibly executing someone or being
    -- executed: clear both sides.
    local myTarget = executingPlayers[src]

    if myTarget then
        executingPlayers[src] = nil
        executingTargets[myTarget] = nil
        TriggerClientEvent('amb_client:executionStopped', myTarget)
    end

    local myExecutor = executingTargets[src]

    if myExecutor then
        executingTargets[src] = nil
        executingPlayers[myExecutor] = nil
        TriggerClientEvent('amb_client:executionStopped', src)
    end

    -- NOTE: the persisted death-state row is deliberately NOT deleted here.
    -- It was saved eagerly when the player went down / was finished, and the
    -- reconnect restore reads it back. Only a real revive clears it. The
    -- in-memory tables below are still wiped to avoid leaking stale src keys.
    finishedPlayers[src] = nil
    downedAt[src] = nil
    killerInfo[src] = nil

    pcall(function()
        exports.plt_ambulance_job:ClosePatientCalls(src)
    end)

    print(('^2[DEATH]^7 Player %s dropped, death states cleaned (persisted row kept for reconnect).'):format(tostring(src)))
end)

-- Resource (re)start: never leave players stuck dead / downed / executing.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    -- Make sure the existing key/value table is there (same schema as
    -- docs/esx-install.sql; a no-op when it already exists).
    if MySQL == nil or MySQL.Async == nil or MySQL.Async.execute == nil then
        print('^3[DEATH]^7 oxmysql not available, death-state persistence is memory-only.')
    else
        pcall(MySQL.Async.execute, [[
            CREATE TABLE IF NOT EXISTS `plt_ambulance_job_data` (
                `key`   VARCHAR(64) NOT NULL,
                `value` LONGTEXT NULL,
                PRIMARY KEY (`key`)
            ) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4
        ]], {})

        -- Every client is reset to ALIVE below, so every persisted death
        -- row must go too - otherwise the next reconnect would restore a
        -- state that no longer exists.
        pcall(MySQL.Async.execute,
            'DELETE FROM `plt_ambulance_job_data` WHERE `key` LIKE ?', { 'deathstate:%' })
    end

    for identifier, _ in pairs(persistedDeathStates) do
        persistedDeathStates[identifier] = nil
    end

    TriggerClientEvent('amb_client:deathSystemReset', -1)

    print('^2[DEATH]^7 Resource started, death states reset for everyone.')
end)

-- ---------------------------------------------------------------
-- Debug helpers
-- ---------------------------------------------------------------
-- /mercyreset (client) clears the finished state and stands the player up.
RegisterNetEvent('amb_server:clearFinished', function()
    local src = source

    finishedPlayers[src] = nil
    clearPersistedDeathState(src)
    downedAt[src] = nil
    killerInfo[src] = nil
    executingPlayers[src] = nil
    executingTargets[src] = nil

    broadcastFinished(src, false)

    pcall(function()
        exports.plt_ambulance_job:InternalRevive(src)
    end)

    Framework.Notify(src, 'Death state cleared (debug).', 'success')

    print(('^2[DEATH]^7 Player %s death state cleared (debug).'):format(tostring(src)))
end)
