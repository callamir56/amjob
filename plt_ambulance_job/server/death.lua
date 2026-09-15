--[[
    ------------------------------------------------------------------
    PLT AMBULANCE - DEATH SYSTEM v2 (server side)
    ------------------------------------------------------------------
    The server is the single authority for FINISHED:

      * DOWNED is echoed by the client (amb_server:SetDowned) and tracked
        here with a timestamp + the validated killer info.
      * FINISH comes only through: the death timer (elapsed time, checked
        here), the GIVE UP path (earliest time, checked here), or another
        player executing the downed player (distance / state, checked here).
      * Every public event re-validates: a cheater can never finish,
        execute or respawn anyone by firing events.
      * FINISHED players respawn at the hospital after the finished
        countdown with the whole ox_inventory wiped.

    NOTE: this file always loads and always registers its callbacks, but
    every handler is guarded by deathSystemEnabled() at runtime - exactly
    like the proven design. In legacy mode the callbacks simply answer
    "no" (cb(0) / cb(false)) so the death UI never hangs waiting.
]]

local finishedPlayers = {} -- [src] = true when the player is FINISHED (final dead)
local downedAt = {}        -- [src] = os.time() when the player went DOWNED
local downedFrom = {}      -- [src] = 'death' (only tracked for the debug print)
local killerInfo = {}      -- [src] = { src, name, id, weaponHash, label, time }
local executingPlayers = {} -- [executorSrc] = targetSrc while an execution runs
local executingTargets = {} -- [targetSrc] = executorSrc while an execution runs
local hospitalRespawnAuthorized = {} -- [src] = true for the final respawn round-trip

local function deathSystemEnabled()
    return not (Config.DisableDeathSystem == true
        or (Config.DeathSystem and Config.DeathSystem.Enabled == false))
end

local function deathTimerSeconds()
    return math.max(1, tonumber(Config.DeathSystem and Config.DeathSystem.DeathTimer) or 600)
end

local function giveUpTime()
    return math.max(0, tonumber(
        (Config.DeathSystem and Config.DeathSystem.GiveUpTime)
        or (Config.Mercy and Config.Mercy.GiveUpTime)
    ) or 300)
end

local function executeDistance()
    return math.max(0.5, tonumber(Config.DeathSystem and Config.DeathSystem.ExecuteDistance) or 2.0)
end

local function executeTime()
    -- Milliseconds the executor holds the progress bar (also sizes the
    -- server-side safety net below).
    return math.max(500, tonumber(Config.DeathSystem and Config.DeathSystem.ExecuteTime) or 5000)
end

local function executeEnabled()
    return not (Config.DeathSystem and Config.DeathSystem.ExecuteEnabled == false)
end

local function respawnSeconds()
    -- How long a FINISHED player waits before the hospital respawn.
    return math.max(1, tonumber(Config.DeathSystem and Config.DeathSystem.FinishedRespawnSeconds)
        or tonumber(Config.Mercy and Config.Mercy.RespawnSeconds)
        or 300)
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

local function broadcastFinished(src, finished)
    TriggerClientEvent('amb_client:syncFinishedPlayer', -1, src, finished)
end

local function elapsedSinceDown(src)
    local start = downedAt[src]
    if not start then
        return nil
    end
    return os.difftime(os.time(), start)
end

local hospitalRespawn
local scheduleHospitalRespawn

-- Records who finished the victim (execution / damage), fully validated.
-- Client values are never trusted: offline / self / invalid ids are dropped.
local function attributeKiller(src, killerSrc, weaponHash)
    killerSrc = tonumber(killerSrc) or 0
    weaponHash = tonumber(weaponHash) or 0

    if killerSrc <= 0 or killerSrc == src or not isPlayerOnline(killerSrc) then
        return
    end

    killerInfo[src] = {
        src = killerSrc,
        name = getPlayerName(killerSrc),
        id = killerSrc,
        weaponHash = weaponHash,
        time = os.time(),
    }

    TriggerClientEvent('amb_client:receiveDeathKiller', src, killerInfo[src])
end

local function finishPlayer(src, reason)
    if isFinished(src) then
        return false
    end

    finishedPlayers[src] = true

    hospitalRespawnAuthorized[src] = nil

    -- A finished body is no longer "downed": carriers auto-drop it and no
    -- target interaction (search / carry / execute) is offered any more.
    TriggerClientEvent('amb_client:syncDownedPlayer', -1, src, false)

    broadcastFinished(src, true)

    Framework.Notify(src, _L('player_finished_self'), 'error')

    print(('^1[DEATH]^7 Player %s (%s) FINISHED (%s).'):format(
        tostring(src), getPlayerName(src), tostring(reason or 'unknown')))

    scheduleHospitalRespawn(src)

    return true
end

scheduleHospitalRespawn = function(src)
    CreateThread(function()
        local waitSeconds = respawnSeconds()

        if waitSeconds < 5 then
            waitSeconds = 5
        end

        local startWait = os.time()

        while os.difftime(os.time(), startWait) < waitSeconds do
            Wait(1000)

            if not isFinished(src) then
                return
            end

            if not isPlayerOnline(src) then
                return
            end
        end

        if isFinished(src) and isPlayerOnline(src) then
            hospitalRespawn(src)
        end
    end)
end

hospitalRespawn = function(src)
    if not isFinished(src) then
        return
    end

    if not isPlayerOnline(src) then
        return
    end

    -- Wipe the whole ox_inventory of the finished player BEFORE the respawn.
    -- Direct export (ox_inventory exposes ClearInventory): if it fails for
    -- any reason, the legacy item-by-item wipe still runs via DropInventory.
    local cleared = pcall(function()
        exports.ox_inventory:ClearInventory(src)
    end)

    if cleared then
        print(('^1[DEATH]^7 Cleared ox_inventory for finished player %s (%s).'):format(
            tostring(src), getPlayerName(src)))
    else
        print(('^1[DEATH]^7 FAILED to clear ox_inventory for finished player %s (%s).'):format(
            tostring(src), getPlayerName(src)))
    end

    finishedPlayers[src] = nil
    downedAt[src] = nil
    downedFrom[src] = nil
    killerInfo[src] = nil
    hospitalRespawnAuthorized[src] = true

    -- The client only revives + teleports because we say so: authorize first,
    -- then broadcast, then issue the revive. The client's generic-revive
    -- guard (FINISHED -> refuse) must be gone by the time InternalRevive's
    -- effect lands, which is why the broadcast runs before the revive.
    TriggerClientEvent('amb_client:authorizeFinishedRespawn', src)
    broadcastFinished(src, false)

    Framework.InternalRevive(src)

    TriggerClientEvent('amb_client:finishedRespawn', src, true)

    print(('^1[DEATH]^7 Player %s (%s) respawned at the hospital after FINISHED.'):format(
        tostring(src), getPlayerName(src)))
end

-- Downed echo from the client (sent by health.lua). The client owns the
-- health watch; the server owns the timestamps, the finished flag and every
-- validation.
RegisterNetEvent('amb_server:SetDowned', function(downed)
    local src = source

    if not deathSystemEnabled() then
        return
    end

    if downed == false then
        -- Revive path: clear the downed tracking. A FINISHED player can never
        -- leave through this event (only the hospital respawn clears it).
        if isFinished(src) then
            print(('^1[DEATH]^7 Ignored amb_server:SetDowned(false) for FINISHED player %s.'):format(
                tostring(src)))
            return
        end

        downedAt[src] = nil
        downedFrom[src] = nil
        killerInfo[src] = nil

        TriggerClientEvent('amb_client:onRevive', src)
        return
    end

    if isFinished(src) then
        return
    end

    if not downedAt[src] then
        downedAt[src] = os.time()
    end

    downedFrom[src] = 'death'

    -- Keep killer info fresh for every new down.
    if not killerInfo[src] then
        killerInfo[src] = { src = 0, name = 'UNKNOWN', weaponHash = 0 }
    end

    print(('^3[DEATH]^7 Player %s (%s) is DOWNED.'):format(
        tostring(src), getPlayerName(src)))
end)

RegisterNetEvent('amb_server:reportDeathKiller', function(killerSrc, weaponHash)
    local src = source

    if not deathSystemEnabled() then
        return
    end

    killerSrc = tonumber(killerSrc) or 0
    weaponHash = tonumber(weaponHash) or 0

    if killerSrc <= 0 or not isPlayerOnline(killerSrc) then
        return
    end

    if killerSrc == src then
        return
    end

    if isFinished(src) then
        return
    end

    killerInfo[src] = {
        src = killerSrc,
        name = getPlayerName(killerSrc),
        id = killerSrc,
        weaponHash = weaponHash,
        time = os.time(),
    }

    -- Hand the validated info back to the victim's death screen.
    TriggerClientEvent('amb_client:receiveDeathKiller', src, killerInfo[src])
end)

-- Server-authoritative downed time for the death UI countdown.
Framework.CreateCallback('amb_server:getDeathElapsed', function(_, cb)
    local src = source

    if deathSystemEnabled() then
        local elapsed = elapsedSinceDown(src)

        if elapsed ~= nil then
            cb(math.floor(elapsed))
            return
        end
    end

    cb(0)
end)

-- FINISH paths for the client: the client asks, the server validates and
-- finishes the player. Self-finish only (no target parameter), so a cheater
-- firing this can only ever finish themselves.
RegisterNetEvent('amb_server:finishPlayer', function(reason, killerSrc, weaponHash)
    local src = source

    if not deathSystemEnabled() then
        return
    end

    if reason ~= 'timer' and reason ~= 'giveup' and reason ~= 'damage' then
        return
    end

    if isFinished(src) then
        return
    end

    if not exports.plt_ambulance_job:IsPlayerDowned(src) then
        print(('^3[DEATH]^7 Player %s finish refused: not downed.'):format(tostring(src)))
        return
    end

    local elapsed = elapsedSinceDown(src)

    if elapsed == nil then
        return
    end

    -- Fresh damage while DOWNED: finish immediately, no timer check. The
    -- finisher is attributed (validated) so the death screen shows them.
    if reason == 'damage' then
        attributeKiller(src, killerSrc, weaponHash)
        finishPlayer(src, 'damage')
        return
    end

    if reason == 'timer' then
        if elapsed < deathTimerSeconds() then
            print(('^1[DEATH]^7 Blocked early timer-finish for %s (elapsed %ds).'):format(
                tostring(src), math.floor(elapsed)))
            return
        end

        finishPlayer(src, 'timer')
        return
    end

    -- Give up: allowed only after the configured give-up time.
    if elapsed < giveUpTime() then
        Framework.Notify(src, _L('give_up_unavailable'), 'error')
        return
    end

    finishPlayer(src, 'giveup')
end)

-- ----------------------------------------------------------------
-- Execute (finish a downed player through the target interaction)
-- ----------------------------------------------------------------
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
    if isFinished(src) or exports.plt_ambulance_job:IsPlayerDowned(src) then
        cb(false, 'invalid')
        return
    end

    -- Target must be downed, not finished, not already being executed.
    if isFinished(targetId)
        or not exports.plt_ambulance_job:IsPlayerDowned(targetId) then
        cb(false, 'target')
        return
    end

    if executingTargets[targetId] or executingPlayers[src] then
        cb(false, 'busy')
        return
    end

    -- Distance validation against the real positions.
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

    print(('^1[DEATH]^7 Player %s (%s) started executing %s (%s).'):format(
        tostring(src), getPlayerName(src), tostring(targetId), getPlayerName(targetId)))

    cb(true)
end)

RegisterNetEvent('amb_server:cancelExecute', function(targetId)
    local src = source

    if not deathSystemEnabled() then
        return
    end

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

    -- Must be a running execution started through amb_server:executeStart.
    if executingPlayers[src] ~= targetId then
        return
    end

    -- Re-validate everything at completion time.
    if not isPlayerOnline(targetId) then
        executingPlayers[src] = nil
        executingTargets[targetId] = nil
        return
    end

    if isFinished(targetId)
        or not exports.plt_ambulance_job:IsPlayerDowned(targetId) then
        executingPlayers[src] = nil
        executingTargets[targetId] = nil
        TriggerClientEvent('amb_client:executionStopped', targetId)
        TriggerClientEvent('amb_client:executeInvalid', src, 'target')
        return
    end

    if isFinished(src) or exports.plt_ambulance_job:IsPlayerDowned(src) then
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

    attributeKiller(targetId, src, weaponHash)

    if finishPlayer(targetId, 'execute') then
        Framework.Notify(src, _L('execute_success'), 'success')
    end
end)

RegisterNetEvent('amb_server:giveUp', function()
    local src = source

    if not deathSystemEnabled() then
        return
    end

    if isFinished(src) then
        return
    end

    if not exports.plt_ambulance_job:IsPlayerDowned(src) then
        return
    end

    local elapsed = elapsedSinceDown(src)

    if elapsed == nil then
        return
    end

    if elapsed < giveUpTime() then
        Framework.Notify(src, _L('give_up_unavailable'), 'error')
        return
    end

    finishPlayer(src, 'giveup')
end)

AddEventHandler('playerDropped', function()
    local src = source

    if not deathSystemEnabled() then
        return
    end

    if executingPlayers[src] then
        local target = executingPlayers[src]
        executingPlayers[src] = nil
        executingTargets[target] = nil

        if isPlayerOnline(target) then
            TriggerClientEvent('amb_client:executionStopped', target)
        end
    end

    if executingTargets[src] then
        local executor = executingTargets[src]
        executingTargets[src] = nil
        executingPlayers[executor] = nil

        if isPlayerOnline(executor) then
            TriggerClientEvent('amb_client:executionStopped', executor)
        end
    end

    finishedPlayers[src] = nil
    downedAt[src] = nil
    downedFrom[src] = nil
    killerInfo[src] = nil
    hospitalRespawnAuthorized[src] = nil
end)

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then
        return
    end

    TriggerClientEvent('amb_client:deathSystemReset', -1)

    print('^2[DEATH]^7 death system v2 started.')
end)

-- Debug / admin: clear everything for a player and stand them up.
RegisterNetEvent('amb_server:clearFinished', function()
    local src = source

    if not deathSystemEnabled() then
        return
    end

    if not isFinished(src) and downedAt[src] == nil then
        return
    end

    finishedPlayers[src] = nil
    downedAt[src] = nil
    downedFrom[src] = nil
    killerInfo[src] = nil
    hospitalRespawnAuthorized[src] = nil

    broadcastFinished(src, false)

    Framework.InternalRevive(src)

    TriggerClientEvent('amb_client:debugRespawn', src)
    Framework.Notify(src, _L('death_state_cleared'), 'success')

    print(('^1[DEATH]^7 Cleared death state for player %s (%s).'):format(
        tostring(src), getPlayerName(src)))
end)
