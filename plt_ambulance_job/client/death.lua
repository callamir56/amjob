--[[
    ------------------------------------------------------------------
    PLT AMBULANCE - DEATH SYSTEM (rebuilt from scratch, client side)
    ------------------------------------------------------------------
    Fully self-contained. It does NOT listen to FiveM damage events
    (CEventNetworkEntityDamage is unreliable, and no event fires at all
    while a ped is invincible). Instead it watches the player's own health
    every frame - exactly what the GTA engine itself does:

        ALIVE    ->  bullet to the head        ->  FINISHED instantly
                 ->  fatal body hit            ->  DOWNED (unconscious, 1% HP)
        DOWNED   ->  ANY further health loss   ->  FINISHED for good
        FINISHED ->  lifeless body, NO animation, no controls, no EMS
                     request, no revive. The server runs the 10 minute
                     hospital timer and wipes the entire ox_inventory.

    The same UI as before is used: the built-in death screen (ECG monitor,
    status headline, timer) via the existing amb_client:onPlayerDeath and
    amb_client:finishedStateChanged events.
]]

if Config.DisableDeathSystem == true then
    return
end

if Config.DeathSystem and Config.DeathSystem.Enabled == false then
    return
end

local State = {
    ALIVE = 1,
    DOWNED = 2,
    FINISHED = 3,
}

local state = State.ALIVE
local lastHealth = 0
local lastDamageWeapon = 0
local spawnGraceUntil = 0
local isCarried = false
local isTreated = false

local HEAD_BONES = {
    [31086] = true,    -- SKEL_Head
    [39317] = true,
    [12844] = true,
    [65068] = true,
}

-- Weapon-type groups that count as bullets (same as the old system).
local BULLET_WEAPON_GROUPS = {
    [416676503] = true,     -- pistols
    [-95745345] = true,     -- smg
    [860033945] = true,     -- shotgun
    [970310034] = true,     -- rifle / mg / sniper
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
    return tonumber(Config.DeathSystem and Config.DeathSystem.MinAliveHeadshotDamage) or 40
end

local function spawnGrace()
    return tonumber(Config.DeathSystem and Config.DeathSystem.SpawnGraceMs) or 10000
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
        local coords = GetEntityCoords(ped)

        SetEntityCoords(ped, coords.x, coords.y, coords.z + 1.0, false, false, false, false)
    end
end

-- Lifeless body: tasks cleared, ragdoll on the ground, NO animation at all.
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
local function markDowned()
    TriggerEvent('hospital:client:SetDeathStatus', true)

    TriggerEvent('amb_client:onPlayerDeath', 'dead', 0, Framework.MedicalState.LASTSTAND)
end

local function enterDowned(reason)
    if state ~= State.ALIVE then
        return
    end

    state = State.DOWNED

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

    markDowned()

    print(('^3[DEATH]^7 downed (%s), hp pinned to %s'):format(tostring(reason), tostring(downedHealth())))
end

local function enterFinished(reason)
    if state == State.FINISHED then
        return
    end

    state = State.FINISHED

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

    markDowned()

    print(('^1[DEATH]^7 FINISHED (%s)'):format(tostring(reason)))

    -- The server requires the player to be downed before it accepts the
    -- finish; give the downed state a moment to arrive first.
    SetTimeout(100, function()
        TriggerServerEvent('amb_server:finishPlayer')
    end)
end

-- Opportunistic weapon hint for the ALIVE detection (used only to tell
-- bullets apart from melee / vehicles when the hit did not kill).
AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkEntityDamage' and args[1] == PlayerPedId() then
        lastDamageWeapon = tonumber(args[7]) or 0
    end
end)

-- ---------------------------------------------------------------
-- ONE loop: health watch + pose enforcement (no races, no fights)
-- ---------------------------------------------------------------
CreateThread(function()
    spawnGraceUntil = GetGameTimer() + spawnGrace()

    Wait(2000)

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        lastHealth = GetEntityHealth(ped)
    end

    while true do
        Wait(0)

        local now = GetGameTimer()
        ped = PlayerPedId()

        if not ped or ped == 0 or not DoesEntityExist(ped) then
            Wait(500)
            lastHealth = 0
        elseif state == State.ALIVE then
            local health = GetEntityHealth(ped)

            if now < spawnGraceUntil then
                lastHealth = health
            elseif not isCarried and not isTreated and health < lastHealth then
                local damage = lastHealth - health
                local died = IsPedDeadOrDying(ped, true) or health <= 0
                local bone = getLastDamageBone(ped)
                local headHit = bone ~= 0 and HEAD_BONES[bone] == true
                local weapon = lastDamageWeapon
                lastDamageWeapon = 0
                local inVehicle = IsPedInAnyVehicle(ped, false)

                if died then
                    -- The engine killed us. A bullet to the head finishes;
                    -- everything else (body shots, melee, vehicle, fall,
                    -- explosion) is the first death = unconscious.
                    local cause = GetPedCauseOfDeath(ped)
                    local isBullet = cause ~= 0
                        and BULLET_WEAPON_GROUPS[GetWeapontypeGroup(cause)] == true

                    if headHit and isBullet then
                        enterFinished('headshot kill')
                    else
                        enterDowned('fatal damage')
                    end
                elseif health <= downedThreshold() then
                    -- Survived but dropped below the downed threshold.
                    local isBulletWeapon = BULLET_WEAPON_GROUPS[GetWeapontypeGroup(weapon)] == true

                    if headHit and not inVehicle
                        and (isBulletWeapon or (weapon == 0 and damage >= minHeadshotDamage())) then
                        enterFinished('headshot')
                    else
                        enterDowned('severe damage')
                    end
                else
                    lastHealth = health
                end

                lastHealth = GetEntityHealth(PlayerPedId())
            else
                lastHealth = health
            end
        elseif state == State.DOWNED then
            if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
                -- Killed while downed: finished for good.
                enterFinished('killed while downed')
            else
                local health = GetEntityHealth(ped)

                if isCarried or isTreated then
                    lastHealth = health
                elseif health < lastHealth then
                    -- The 1% HP was taken: finished for good.
                    enterFinished('damage while downed')
                    lastHealth = GetEntityHealth(PlayerPedId())
                else
                    if health > downedHealth() then
                        SetEntityHealth(ped, downedHealth())
                    end

                    lastHealth = downedHealth()
                end

                -- Keep the body down without playing any animation.
                if state ~= State.FINISHED and not IsPedInAnyVehicle(ped, false)
                    and not IsPedRagdoll(ped) then
                    if IsPedGettingUp(ped) or GetEntitySpeed(ped) > 0.5 then
                        SetPedToRagdoll(ped, 5000, 5000, 1, false, false, false)
                    end
                end
            end
        elseif state == State.FINISHED then
            -- Lifeless body: resurrect if the engine killed it, pin the 1%
            -- health, lock every control, keep it ragdolled on the ground.
            if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
                ped = resurrectLocalPlayer(ped)
            end

            local health = GetEntityHealth(ped)

            if health ~= downedHealth() then
                SetEntityHealth(ped, downedHealth())
            end

            lastHealth = downedHealth()

            DisableAllControlActions(0)
            DisablePlayerFiring(PlayerId(), true)
            SetPedCanPlayAmbientAnims(ped, false)
            SetPedCanPlayAmbientBaseAnims(ped, false)
            SetBlockingOfNonTemporaryEvents(ped, true)

            if not IsPedInAnyVehicle(ped, false) and not IsPedRagdoll(ped) then
                if IsPedGettingUp(ped) or IsPedWalking(ped) or IsPedRunning(ped)
                    or GetEntitySpeed(ped) > 0.5 then
                    SetPedToRagdoll(ped, 99999999, 99999999, 1, false, false, false)
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
        end
    end
end)

-- The server refused the finish (e.g. it did not see the player downed yet):
-- step back to the downed state and retry shortly - the downed state has
-- reached the server by then.
RegisterNetEvent('amb_client:finishRefused', function()
    if state ~= State.FINISHED then
        return
    end

    state = State.DOWNED

    local ped = PlayerPedId()

    dropLifeless(ped, false)

    print('^3[DEATH]^7 finish refused by server, retrying...')

    SetTimeout(1500, function()
        if state == State.DOWNED then
            enterFinished('retry after refusal')
        end
    end)
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
    isCarried = false
    isTreated = false

    DisablePlayerFiring(PlayerId(), false)

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        lastHealth = GetEntityHealth(ped)
    end

    print('^2[DEATH]^7 hospital respawn done, state reset to ALIVE.')
end)

-- ---------------------------------------------------------------
-- Debug helpers
-- ---------------------------------------------------------------
-- /mercytest  - runs the whole finish pipeline right away
-- /mercydown  - forces the downed state (tests the unconscious phase)
-- /mercyreset - clears the finished state and stands the player up
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
