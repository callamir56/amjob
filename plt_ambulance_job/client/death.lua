--[[
    ------------------------------------------------------------------
    PLT AMBULANCE - DEATH SYSTEM (rebuilt, client side)
    ------------------------------------------------------------------
    Fully self-contained. It does NOT listen to FiveM damage events
    (CEventNetworkEntityDamage is unreliable, and damage does not fire at
    all while the ped is invincible). Instead it watches the player's own
    health every frame - exactly what the GTA engine itself does:

        ALIVE   ->  head shot / fatal head damage  ->  FINISHED instantly
                ->  fatal body hit / low health    ->  DOWNED (1% HP)
        DOWNED  ->  ANY further health loss         ->  FINISHED for good
        FINISHED->  lifeless body, no animation, no controls, no medic,
                    server runs the 10 minute hospital timer.

    The server (server/death.lua) stays authoritative: it marks the
    finished state, blocks every revive, wipes the ox_inventory and
    respawns the player at the hospital.
]]

if Config.DeathSystem and Config.DeathSystem.Enabled == false then
    return
end

local State = {
    ALIVE = 1,
    DOWNED = 2,
    FINISHED = 3,
}

local state = State.ALIVE
local myId = 0
local lastHealth = 0
local downedAt = 0
local finishedLocal = false
local isCarried = false
local isTreated = false
local spawnGraceUntil = 0

local HEAD_BONES = {
    [31086] = true,    -- SKEL_Head
    [39317] = true,
    [12844] = true,
    [65068] = true,
}

local BULLET_WEAPON_GROUPS = {
    [416676503] = true,     -- pistols
    [-95745345] = true,     -- smg
    [860033945] = true,     -- shotgun
    [970310034] = true,     -- rifle / mg / sniper
}

local VEHICLE_DAMAGE_HASHES = {
    [-1553120962] = true,
    [133987706] = true,
    [341774354] = true,
    [-868994466] = true,
    [148160082] = true,
}

local function downedHealth()
    return tonumber((Config.DeathSystem and Config.DeathSystem.DownedHealth)
        or (Config.Health and Config.Health.DownedHealth)) or 110
end

local function downedThreshold()
    return tonumber((Config.DeathSystem and Config.DeathSystem.DownedThreshold)
        or (Config.Health and Config.Health.DownedThreshold)) or 125
end

local function minHeadshotDamage()
    return tonumber((Config.DeathSystem and Config.DeathSystem.MinAliveHeadshotDamage)) or 40
end

local function spawnGrace()
    return tonumber((Config.DeathSystem and Config.DeathSystem.SpawnGraceMs)) or 10000
end

-- The last-damage bone can lag a few frames behind the actual hit.
local function getLastDamageBone(ped)
    for _ = 1, 15 do
        local found, bone = GetPedLastDamageBone(ped)

        if found and bone and bone ~= 0 then
            return bone
        end

        Wait(0)
    end

    return 0
end

local function resurrectLocalPlayer(ped)
    if not IsPedDeadOrDying(ped, true) and GetEntityHealth(ped) > 0 then
        return ped
    end

    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z + 0.5, heading, true, false)

    Wait(0)

    ped = PlayerPedId()

    SetEntityVisible(ped, true, false)
    ResetEntityAlpha(ped)
    ClearPedBloodDamage(ped)

    return ped
end

local function leaveVehicle(ped)
    if not IsPedInAnyVehicle(ped, false) then
        return
    end

    local vehicle = GetVehiclePedIsIn(ped, false)

    ClearPedTasksImmediately(ped)

    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
        TaskLeaveVehicle(ped, vehicle, 4160)
    else
        TaskLeaveAnyVehicle(ped, 1, 0)
    end

    Wait(100)

    if IsPedInAnyVehicle(ped, false) then
        SetEntityCoords(ped, GetEntityCoords(ped).x, GetEntityCoords(ped).y, GetEntityCoords(ped).z + 1.0, false, false, false, false)
    end
end

local function dropLifeless(ped, longRagdoll)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    ClearPedTasksImmediately(ped)

    SetPedCanRagdoll(ped, true)
    SetPedCanRagdollFromPlayerImpact(ped, true)
    SetPedCanPlayAmbientAnims(ped, false)
    SetPedCanPlayAmbientBaseAnims(ped, false)
    SetBlockingOfNonTemporaryEvents(ped, true)

    SetPedToRagdoll(ped,
        longRagdoll and 99999999 or 5000,
        longRagdoll and 99999999 or 5000,
        1, false, false, false)
end

-- Keeps health.lua / the server / the deathscreen in sync through the
-- existing (proven) bookkeeping path.
local function markDowned(downed)
    TriggerEvent('hospital:client:SetDeathStatus', downed == true)

    if downed == true then
        TriggerEvent('amb_client:onPlayerDeath', 'dead', 0, Framework.MedicalState.LASTSTAND)
    else
        TriggerEvent('amb_client:onPlayerRevive')
    end
end

local function enterDowned(reason)
    if state ~= State.ALIVE then
        return
    end

    state = State.DOWNED
    downedAt = GetGameTimer()

    local ped = PlayerPedId()

    leaveVehicle(ped)
    ped = resurrectLocalPlayer(ped)

    SetEntityMaxHealth(ped, 200)
    SetEntityHealth(ped, downedHealth())
    lastHealth = downedHealth()

    -- NO invincibility: damage must keep registering so the health watch can
    -- detect the finishing hit.
    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)

    dropLifeless(ped, false)

    markDowned(true)

    print(('^3[DEATH]^7 downed (%s), hp pinned to %s'):format(tostring(reason), tostring(downedHealth())))
end

local function enterFinished(reason)
    if state == State.FINISHED then
        return
    end

    state = State.FINISHED
    finishedLocal = true
    downedAt = 0

    local ped = PlayerPedId()

    leaveVehicle(ped)
    ped = resurrectLocalPlayer(ped)

    SetEntityMaxHealth(ped, 200)
    SetEntityHealth(ped, downedHealth())
    lastHealth = downedHealth()

    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)

    -- Lifeless, NO animation at all.
    dropLifeless(ped, true)

    markDowned(true)

    print(('^1[DEATH]^7 FINISHED (%s)'):format(tostring(reason)))

    -- The server requires the player to be downed before it accepts the
    -- finish; give the downed state a moment to arrive first.
    SetTimeout(100, function()
        TriggerServerEvent('amb_server:finishPlayer')
    end)
end

-- ---------------------------------------------------------------
-- Health watch (the only damage detection)
-- ---------------------------------------------------------------
CreateThread(function()
    myId = GetPlayerServerId(PlayerId())
    spawnGraceUntil = GetGameTimer() + spawnGrace()

    Wait(2000)

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        lastHealth = GetEntityHealth(ped)
    end

    while true do
        Wait(0)

        local now = GetGameTimer()
        myId = GetPlayerServerId(PlayerId())
        ped = PlayerPedId()

        if not ped or ped == 0 or not DoesEntityExist(ped) then
            Wait(500)
            lastHealth = 0
        else
            local health = GetEntityHealth(ped)

            if state == State.ALIVE then
                if now < spawnGraceUntil then
                    lastHealth = health
                elseif not isCarried and not isTreated and health < lastHealth then
                    local died = IsPedDeadOrDying(ped, true) or health <= 0
                    local bone = getLastDamageBone(ped)
                    local headHit = bone ~= 0 and HEAD_BONES[bone] == true
                    local damageDealt = lastHealth - health

                    if died or health <= downedThreshold() then
                        if headHit then
                            local cause = died and GetPedCauseOfDeath(ped) or 0
                            local isVehicle = cause ~= 0
                                and (VEHICLE_DAMAGE_HASHES[cause] == true
                                    or cause == -1438083414)  -- WEAPON_FALL
                            local isBulletCause = cause == 0
                                or BULLET_WEAPON_GROUPS[GetWeapontypeGroup(cause)] == true

                            if isVehicle then
                                enterDowned('vehicle / fall')
                            elseif died and not isBulletCause then
                                enterDowned('fatal melee hit')
                            elseif died or damageDealt >= minHeadshotDamage() then
                                enterFinished('head shot')
                            else
                                enterDowned('head damage')
                            end
                        else
                            enterDowned('fatal damage')
                        end

                        -- a new downed/finished state starts with the pinned
                        -- health; avoid re-processing the same hit
                        lastHealth = GetEntityHealth(PlayerPedId())
                    else
                        lastHealth = health
                    end
                else
                    lastHealth = health
                end
            elseif state == State.DOWNED then
                if isCarried or isTreated then
                    lastHealth = health
                elseif health < lastHealth then
                    -- The 1% HP was taken: finished for good.
                    enterFinished('damage while downed')
                else
                    lastHealth = health
                end
            end

            -- FINISHED: everything is handled by the enforcement thread.
        end
    end
end)

-- ---------------------------------------------------------------
-- Pose / control enforcement
-- ---------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(0)

        local ped = PlayerPedId()

        if not ped or ped == 0 or not DoesEntityExist(ped) then
            Wait(500)
        elseif state == State.FINISHED then
            if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
                ped = resurrectLocalPlayer(ped)
            end

            local health = GetEntityHealth(ped)

            if health < downedHealth() - 1 or health > downedHealth() + 1 then
                SetEntityHealth(ped, downedHealth())
            end

            DisableAllControlActions(0)
            DisablePlayerFiring(PlayerId(), true)
            SetPedCanPlayAmbientAnims(ped, false)
            SetPedCanPlayAmbientBaseAnims(ped, false)

            if not IsPedInAnyVehicle(ped, false) and not IsPedRagdoll(ped) then
                if IsPedGettingUp(ped) or IsPedWalking(ped) or IsPedRunning(ped)
                    or GetEntitySpeed(ped) > 0.5 then
                    SetPedToRagdoll(ped, 99999999, 99999999, 1, false, false, false)
                end
            end
        elseif state == State.DOWNED then
            if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
                -- Killed while downed before the watch caught it: finished.
                enterFinished('killed while downed')
            else
                local health = GetEntityHealth(ped)

                -- Only clamp DOWN, never heal: a real drop means a hit and the
                -- watch loop finishes the player.
                if health > downedHealth() then
                    SetEntityHealth(ped, downedHealth())
                    lastHealth = downedHealth()
                end

                if not IsPedInAnyVehicle(ped, false) and not IsPedRagdoll(ped) then
                    if IsPedGettingUp(ped) or GetEntitySpeed(ped) > 0.5 then
                        SetPedToRagdoll(ped, 5000, 5000, 1, false, false, false)
                    end
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------
-- State sync with the rest of the resource
-- ---------------------------------------------------------------
RegisterNetEvent('amb_client:syncFinishedPlayer', function(src, finished)
    src = tonumber(src)

    if not src or src ~= GetPlayerServerId(PlayerId()) then
        return
    end

    if finished == true then
        if state ~= State.FINISHED then
            enterFinished('server confirmed')
        else
            finishedLocal = true
        end
    else
        finishedLocal = false
    end
end)

-- The server refused the finish (e.g. it did not see the player downed yet):
-- step back to the downed state instead of lying finished forever.
RegisterNetEvent('amb_client:finishRefused', function()
    if state ~= State.FINISHED then
        return
    end

    state = State.DOWNED
    finishedLocal = false
    downedAt = GetGameTimer()

    local ped = PlayerPedId()

    dropLifeless(ped, false)

    print('^3[DEATH]^7 finish refused by server, back to downed state.')
end)

RegisterNetEvent('amb_client:setCarried', function(carried)
    isCarried = carried == true
end)

RegisterNetEvent('amb_client:syncCPRAnimation', function()
    isTreated = true
end)

RegisterNetEvent('amb_client:stopCPRAnimation', function()
    isTreated = false
end)

AddEventHandler('amb_client:onPlayerRevive', function()
    state = State.ALIVE
    finishedLocal = false
    downedAt = 0
    isCarried = false
    isTreated = false

    DisablePlayerFiring(PlayerId(), false)

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        lastHealth = GetEntityHealth(ped)

        SetPedCanPlayAmbientAnims(ped, true)
        SetPedCanPlayAmbientBaseAnims(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, false)
    end

    print('^2[DEATH]^7 revived, state reset to ALIVE.')
end)

RegisterNetEvent('amb_client:finishedRespawn', function()
    state = State.ALIVE
    finishedLocal = false
    downedAt = 0

    print('^2[DEATH]^7 hospital respawn done, state reset to ALIVE.')
end)

-- ---------------------------------------------------------------
-- Debug helpers
-- ---------------------------------------------------------------
-- /mercytest  - runs the whole finish pipeline right away
-- /mercyreset - clears the finished state and stands the player up
-- /mercydown  - forces the downed state (tests the unconscious phase)
RegisterCommand('mercytest', function()
    print('^1[DEATH]^7 /mercytest: forcing FINISHED pipeline...')
    enterFinished('mercytest command')
end, false)

RegisterCommand('mercydown', function()
    print('^1[DEATH]^7 /mercydown: forcing DOWNED state...')
    enterDowned('mercydown command')
end, false)

RegisterCommand('mercyreset', function()
    print('^1[DEATH]^7 /mercyreset: clearing finished state...')
    TriggerServerEvent('amb_server:clearFinished')
end, false)
