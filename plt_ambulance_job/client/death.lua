--[[
    ------------------------------------------------------------------
    PLT AMBULANCE - DEATH SYSTEM (client side)
    ------------------------------------------------------------------
    Full spec implementation:

      * ANY fatal damage -> DOWNED / CRITICAL: the body falls to the ground
        as a completely limp ragdoll (unconscious), no weapons, no normal
        respawn. Death UI + timer + one-time CALL EMS.
      * KILLER info (name / id / weapon) captured at the moment of death,
        validated by the server.
      * While downed, other players can EXECUTE via the target interaction
        (progress bar, server validated).
      * Death timer: server-authoritative elapsed time; when it ends the
        player bleeds out and is FINISHED.
      * GIVE UP after the configured time -> FINISHED.
      * FINISHED: completely dead, no revive, no EMS, nothing.

    Detection does not rely on FiveM damage events: one loop watches the
    player's health every frame, the same way the GTA engine itself
    detects death.
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
local downedAt = 0
local spawnGraceUntil = 0
local finishRetries = 0
local isCarried = false
local isTreated = false
local isBeingExecuted = false
local finishedPoseFrozen = false -- freeze applied only AFTER the body is on the ground

local lastAttackerEntity = 0
local lastDamageWeapon = 0

-- Common weapon hashes -> display labels (UI shows UNKNOWN for the rest).
local WEAPON_LABELS = {
    [-1569615261] = 'Unarmed',
    [453432689] = 'Pistol',
    [-1716589765] = 'Pistol Mk II',
    [1593441988] = 'Combat Pistol',
    [584646201] = 'AP Pistol',
    [-1076751822] = 'SN Pistol',
    [-771403250] = 'Heavy Pistol',
    [137902532] = 'Vintage Pistol',
    [-598887786] = 'Marksman Pistol',
    [324215364] = 'Micro SMG',
    [736523883] = 'SMG',
    [-270015777] = 'Assault SMG',
    [171789620] = 'Combat PDW',
    [-619010992] = 'Machine Pistol',
    [2024373456] = 'Mini SMG',
    [-1121678507] = 'SMG Mk II',
    [487013001] = 'Pump Shotgun',
    [2017895192] = 'Sawed-Off Shotgun',
    [-494615257] = 'Assault Shotgun',
    [-1654528753] = 'Bullpup Shotgun',
    [984333226] = 'Heavy Shotgun',
    [-1466123874] = 'Musket',
    [1432025498] = 'Pump Shotgun Mk II',
    [-275439685] = 'Double Barrel Shotgun',
    [-1746263880] = 'Double Action Revolver',
    [-879347409] = 'Heavy Revolver Mk II',
    [324978376] = 'Heavy Revolver',
    [-1045183535] = 'Revolver',
    [-1312131151] = 'Marksman Revolver',
    [-2084633992] = 'Carbine Rifle',
    [-86904375] = 'Carbine Rifle Mk II',
    [2132975508] = 'Bullpup Rifle',
    [-1074790547] = 'Assault Rifle',
    [961495388] = 'Assault Rifle Mk II',
    [-1357824103] = 'Advanced Rifle',
    [1649403952] = 'Compact Rifle',
    [-1063057011] = 'Special Carbine',
    [3231910885] = 'Special Carbine Mk II',
    [2634544996] = 'MG',
    [2144741730] = 'Combat MG',
    [1627465347] = 'Gusenberg',
    [-1660422300] = 'MG Mk II',
    [-2052457935] = 'Heavy Sniper Mk II',
    [205991906] = 'Heavy Sniper',
    [100416529] = 'Sniper Rifle',
    [3342087343] = 'Marksman Rifle',
    [125959754] = 'Compact Grenade Launcher',
    [1119849093] = 'Minigun',
    [741814745] = 'Sticky Bomb',
    [-1813897027] = 'Grenade',
    [615608432] = 'Molotov',
    [126349499] = 'Snowball',
    [-1568386805] = 'Grenade Launcher',
    [1305664598] = 'Grenade Launcher Smoke',
    [600439132] = 'Ball',
    [-2067956739] = 'Crowbar',
    [1141786504] = 'Golf Club',
    [2227010557] = 'Crowbar',
    [1317494643] = 'Hammer',
    [2508868239] = 'Bat',
    [-1810795771] = 'Pool Cue',
    [419712736] = 'Wrench',
    [-102323637] = 'Bottle',
    [-1786099057] = 'Knuckle Duster',
    [1737195953] = 'Nightstick',
    [-1833087301] = 'Knife',
    [-538741184] = 'Switchblade',
    [-656458692] = 'Broken Bottle',
    [940833800] = 'Stone Hatchet',
    [4192643659] = 'Battle Axe',
    [-1951375401] = 'Flashlight',
    [911657153] = 'Stun Gun',
    [-1438083414] = 'Fall',
    [1116286168] = 'Car',
    [133987706] = 'Vehicle',
}

local function weaponLabel(hash)
    local h = tonumber(hash) or 0

    return WEAPON_LABELS[h] or _L('ui_weapon_unknown')
end

exports('GetWeaponLabel', weaponLabel)

local function downedHealth()
    return tonumber((Config.DeathSystem and Config.DeathSystem.DownedHealth)
        or (Config.Health and Config.Health.DownedHealth)) or 110
end

local function downedThreshold()
    return tonumber((Config.DeathSystem and Config.DeathSystem.DownedThreshold)
        or (Config.Health and Config.Health.DownedThreshold)) or 125
end

local function spawnGrace()
    return tonumber(Config.DeathSystem and Config.DeathSystem.SpawnGraceMs) or 10000
end

--[[
    NOTE: crawl support was removed from the death system. A DOWNED player is
    a completely limp, unconscious body (full ragdoll) on the ground until
    REVIVE or EXECUTE - no crawl, no standing, no walking, and never frozen
    while merely downed.
]]

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

-- DOWNED physical state: a completely limp, unconscious body on the ground.
--
-- The player falls and stays down as a full GTA V ragdoll (physics, like an
-- unconscious person) until REVIVE or EXECUTE. No crawl, no custom
-- animation, no standing - and NEVER frozen while merely downed.
--
-- State-based controller: the body is ragdolled once; every frame only
-- checks whether the ragdoll is still active. If another task cleared it
-- (or the ped somehow stood up), the body is dropped back down again - a
-- conditional correction, never a per-frame restart, never a teleport.
local function applyDownedLimp(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    if IsPedInAnyVehicle(ped, false) then
        return
    end

    -- DOWNED is never frozen: the body must stay a soft, physical ragdoll.
    FreezeEntityPosition(ped, false)

    SetPedCanRagdoll(ped, true)
    SetPedCanRagdollFromPlayerImpact(ped, true)
    SetPedCanPlayAmbientAnims(ped, false)
    SetPedCanPlayAmbientBaseAnims(ped, false)
    SetBlockingOfNonTemporaryEvents(ped, true)

    if not IsPedRagdoll(ped) or IsPedGettingUp(ped) then
        -- The limp state was lost (task cleared / ped stood up): remove
        -- whatever took over and drop the body again. Only THIS branch ever
        -- clears tasks - a conditional correction, not a blind per-frame
        -- clear, and it never teleports the ped.
        ClearPedTasksImmediately(ped)

        -- Full GTA V physics ragdoll, type 0 (CTaskNMRelax - the networked
        -- type). Duration -1 keeps the body limp until the state ends.
        SetPedToRagdoll(ped, -1, -1, 0, false, false, false)
    end
end

-- Fully releases the limp body: ragdoll ended, movement clipsets restored,
-- freeze lifted - the ped can stand and walk normally again. Safe to call
-- from revive / carry / CPR / execution / reset paths.
local function releaseDownedLimp(ped)
    FreezeEntityPosition(ped, false)

    if IsPedRagdoll(ped) then
        ClearPedTasksImmediately(ped)
    end

    ResetPedMovementClipset(ped, 0.5)
    ResetPedStrafeClipset(ped)
    ResetPedWeaponMovementClipset(ped)
end

-- Ends any lingering lifeless state (infinite ragdoll from dropLifeless) and
-- returns the body to a controllable state so the limp controller can take
-- over again.
local function releaseFromRagdoll(ped)
    FreezeEntityPosition(ped, false)
    ClearPedTasksImmediately(ped)
end

-- Lifeless body: tasks cleared, ragdoll on the ground, NO animation at all.
local function dropLifeless(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    ClearPedTasksImmediately(ped)

    SetPedCanRagdoll(ped, true)
    SetPedCanRagdollFromPlayerImpact(ped, true)
    SetPedCanPlayAmbientAnims(ped, false)
    SetPedCanPlayAmbientBaseAnims(ped, false)
    SetBlockingOfNonTemporaryEvents(ped, true)

    -- Type 0 (CTaskNMRelax): the only ragdoll type that works for networked
    -- players in FiveM (type 1 / CTaskNMScriptControl is hardcoded off in
    -- networked environments).
    SetPedToRagdoll(ped, -1, -1, 0, false, false, false)
end

-- Keeps health.lua / the server / the deathscreen in sync through the
-- existing (proven) bookkeeping path.
local function markDowned(killerInfo)
    TriggerEvent('hospital:client:SetDeathStatus', true)

    TriggerEvent('amb_client:onPlayerDeath', 'dead', 0, Framework.MedicalState.LASTSTAND, killerInfo)
end

-- Killer capture at the moment of death. The server validates the killer id
-- and resolves the name (client values are never trusted blindly).
local function captureKiller(ped, died)
    local killerSrc = 0
    local weaponHash = lastDamageWeapon
    lastDamageWeapon = 0

    if died then
        local causeOfDeath = GetPedCauseOfDeath(ped)

        if causeOfDeath and causeOfDeath ~= 0 then
            weaponHash = causeOfDeath
        end

        local sourcePed = GetPedSourceOfDeath(ped)

        if not (sourcePed and sourcePed ~= 0) then
            sourcePed = lastAttackerEntity
        end

        if sourcePed and sourcePed ~= 0 and DoesEntityExist(sourcePed) then
            local playerIndex = NetworkGetPlayerIndexFromPed(sourcePed)

            if playerIndex ~= -1 and NetworkIsPlayerActive(playerIndex) then
                killerSrc = GetPlayerServerId(playerIndex)
            end
        end
    else
        local attacker = lastAttackerEntity

        if attacker and attacker ~= 0 and DoesEntityExist(attacker) then
            local playerIndex = NetworkGetPlayerIndexFromPed(attacker)

            if playerIndex ~= -1 and NetworkIsPlayerActive(playerIndex) then
                killerSrc = GetPlayerServerId(playerIndex)
            end
        end
    end

    lastAttackerEntity = 0

    -- Best effort client-side name (the server re-validates and resolves the
    -- authoritative name right after).
    local killerName = nil

    if killerSrc and killerSrc > 0 then
        local killerIndex = GetPlayerFromServerId(killerSrc)

        if killerIndex ~= -1 and NetworkIsPlayerActive(killerIndex) then
            killerName = GetPlayerName(killerIndex)

            if killerName == '**Invalid**' then
                killerName = nil
            end
        end
    end

    local info = {
        src = tonumber(killerSrc) or 0,
        name = killerName,
        weaponHash = tonumber(weaponHash) or 0,
        weapon = weaponLabel(weaponHash)
    }

    return info
end

-- Sends the captured killer to the server (validation + authoritative name).
-- Must run AFTER the downed state reached the server, so it is called from
-- enterDowned once markDowned() has pushed the state.
local function reportKillerToServer(info)
    if type(info) ~= 'table' then
        return
    end

    TriggerServerEvent('amb_server:reportDeathKiller',
        tonumber(info.src) or 0, tonumber(info.weaponHash) or 0)
end

local function enterDowned(reason)
    if state ~= State.ALIVE then
        return
    end

    state = State.DOWNED
    downedAt = GetGameTimer()

    local ped = PlayerPedId()

    local died = IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0

    local killerInfo = captureKiller(ped, died)

    leaveVehicle(ped)
    ped = resurrectLocalPlayer(ped)

    SetEntityMaxHealth(ped, 200)
    SetEntityHealth(ped, downedHealth())
    lastHealth = downedHealth()

    -- IMPORTANT: the ped must NOT be made invincible here. An invincible
    -- ped ignores SetPedToRagdoll - the body would stay standing and
    -- motionless (the reported "standing frozen" bug). Damage immunity comes
    -- from entity proofs instead, which do NOT affect scripted ragdolls.
    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, true, true, true, true, true, true, true, true)

    DisablePlayerFiring(PlayerId(), true)

    -- Downed means no weapons at all: holster whatever is drawn.
    pcall(function()
        if GetSelectedPedWeapon(ped) ~= GetHashKey('WEAPON_UNARMED') then
            SetCurrentPedWeapon(ped, GetHashKey('WEAPON_UNARMED'), true)
        end
    end)

    -- DOWNED is NEVER frozen: the body must stay a soft, physical ragdoll.
    -- (Full freeze belongs to FINISHED, and a short freeze is allowed only
    -- while being executed.)
    FreezeEntityPosition(ped, false)

    -- Limp, unconscious body: fall to the ground and stay there until
    -- REVIVE or EXECUTE. No crawl, no standing.
    applyDownedLimp(ped)

    markDowned(killerInfo)

    reportKillerToServer(killerInfo)

    Framework.Notify(_L('crawl_wounded', {
        seconds = math.floor((Config.DeathSystem.DeathTimer or 600))
    }), 'warning')

    print(('^3[DEATH]^7 downed (%s)'):format(tostring(reason)))
end

local function enterFinished(reason)
    if state == State.FINISHED then
        return
    end

    state = State.FINISHED
    downedAt = 0

    local ped = PlayerPedId()

    leaveVehicle(ped)
    ped = resurrectLocalPlayer(ped)

    SetEntityMaxHealth(ped, 200)
    SetEntityHealth(ped, downedHealth())
    lastHealth = downedHealth()

    -- Same rule as DOWNED: no invincibility (it blocks SetPedToRagdoll and
    -- the corpse would stand upright). Entity proofs keep stray bullets out
    -- without affecting the scripted ragdoll.
    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, true, true, true, true, true, true, true, true)

    DisablePlayerFiring(PlayerId(), true)

    -- FINAL DEAD = FULLY IMMOBILE: no animation, ragdoll on the ground.
    -- IMPORTANT: do NOT freeze here - the ped was just resurrected and is
    -- standing; freezing in the same tick as the ragdoll start blocks the
    -- ragdoll transition and leaves the ped STANDING and frozen (the
    -- reported bug). The FINISHED loop below freezes only once the body is
    -- confirmed on the ground.
    finishedPoseFrozen = false
    dropLifeless(ped)

    markDowned()

    print(('^1[DEATH]^7 FINISHED (%s)'):format(tostring(reason)))

    -- The server requires the player to be downed before it accepts the
    -- finish; give the downed state a moment to arrive first.
    SetTimeout(100, function()
        TriggerServerEvent('amb_server:finishPlayer', reason or 'damage')
    end)
end

-- Opportunistic capture of the attacker / weapon for killer detection.
AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkEntityDamage' and args[1] == PlayerPedId() then
        lastDamageWeapon = tonumber(args[7]) or 0

        local attacker = args[2]

        if attacker and attacker ~= 0 and DoesEntityExist(attacker) then
            lastAttackerEntity = attacker
        end
    end
end)

-- Control blocking for the DOWNED state. The body is a limp ragdoll, but
-- every action that could stand it up or let it fight stays blocked as a
-- second line of defense. DisableControlAction is per-frame only, so this
-- runs every frame while downed - nothing here is sticky and nothing here
-- freezes the ped.
local function enforceDownedControls()
    DisableControlAction(0, 21, true)  -- sprint
    DisableControlAction(0, 22, true)  -- jump
    DisableControlAction(0, 23, true)  -- enter vehicle
    DisableControlAction(0, 24, true)  -- attack / shoot / melee
    DisableControlAction(0, 25, true)  -- aim
    DisableControlAction(0, 36, true)  -- duck / stealth
    DisableControlAction(0, 37, true)  -- weapon wheel / select
    DisableControlAction(0, 44, true)  -- cover
    DisableControlAction(0, 45, true)  -- reload
    DisableControlAction(0, 71, true)  -- vehicle accelerate
    DisableControlAction(0, 72, true)  -- vehicle brake
    DisableControlAction(0, 73, true)  -- vehicle duck
    DisableControlAction(0, 74, true)  -- vehicle attack
    DisableControlAction(0, 75, true)  -- vehicle exit / attack 2
    DisableControlAction(0, 140, true) -- melee attack light
    DisableControlAction(0, 141, true) -- melee attack heavy
    DisableControlAction(0, 142, true) -- melee attack alternate
    DisableControlAction(0, 143, true) -- block
    DisableControlAction(0, 257, true) -- attack 2
    DisableControlAction(0, 263, true) -- melee attack 1
    DisableControlAction(0, 264, true) -- melee attack 2

    DisablePlayerFiring(PlayerId(), true)
end

-- ---------------------------------------------------------------
-- ONE loop: health watch + downed/finished enforcement
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
            elseif health < lastHealth then
                local died = IsPedDeadOrDying(ped, true) or health <= 0

                if died or health <= downedThreshold() then
                    -- First death: downed.
                    enterDowned('first death')
                end

                lastHealth = GetEntityHealth(PlayerPedId())
            else
                lastHealth = health
            end
        elseif state == State.DOWNED then
            -- DOWNED = limp, unconscious body on the ground (full ragdoll).
            -- Everything that could stand the ped up or let it fight is
            -- blocked. The ped is NEVER frozen here (freeze belongs to
            -- FINISHED) - it simply lies on the ground until REVIVE or
            -- EXECUTE.
            --
            -- IMPORTANT: damage does NOT finish a downed player. The state
            -- machine only moves DOWNED -> FINISHED through EXECUTE, the
            -- server-validated timer or GIVE UP. Bullets just keep him down.
            --
            -- DOWNED is NEVER frozen: this clears any leftover freeze (e.g.
            -- a cancelled execution) before the limp body takes over.
            FreezeEntityPosition(ped, false)

            enforceDownedControls()

            if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
                -- Safety net (engine death residue): bring the ped right back
                -- and keep it DOWNED on the ground - no FINISHED transition.
                ped = resurrectLocalPlayer(ped)

                SetEntityMaxHealth(ped, 200)
                SetEntityHealth(ped, downedHealth())
                SetEntityInvincible(ped, false)
                SetEntityProofs(ped, true, true, true, true, true, true, true, true)
                lastHealth = downedHealth()

                applyDownedLimp(ped)
            elseif isCarried or isTreated or isBeingExecuted then
                lastHealth = GetEntityHealth(ped)
            else
                local health = GetEntityHealth(ped)

                -- Keep the 1 HP pinned while lying limp.
                if health > downedHealth() then
                    SetEntityHealth(ped, downedHealth())
                end

                lastHealth = downedHealth()

                -- Limp body controller: keeps the ped on the ground as a
                -- full, soft ragdoll until REVIVE or EXECUTE.
                applyDownedLimp(ped)
            end
        elseif state == State.FINISHED then
            -- FINAL DEAD = fully immobile: resurrect behind the scenes if the
            -- engine killed the ped, pin the 1% health, lock every control,
            -- keep the body ragdolled on the ground and FROZEN.
            if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
                ped = resurrectLocalPlayer(ped)

                -- A resurrected ped stands up: put the body back on the ground
                -- and re-evaluate the freeze (the old latch is invalid now).
                dropLifeless(ped)
                finishedPoseFrozen = false
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

            -- FINAL DEAD = FULLY IMMOBILE: the ONLY state allowed to freeze.
            -- But the freeze is applied ONLY after the body is confirmed on
            -- the ground (ragdoll engaged or inside a vehicle). Freezing in
            -- the same tick as the ragdoll start blocks the ragdoll and
            -- leaves the ped standing frozen - and a merely DOWNED player
            -- must never be frozen at all.
            if IsPedInAnyVehicle(ped, false) then
                FreezeEntityPosition(ped, true)
                finishedPoseFrozen = true
            elseif IsPedRagdoll(ped) then
                -- Body ragdolled on the ground: freeze the pose in place.
                FreezeEntityPosition(ped, true)
                finishedPoseFrozen = true
            elseif finishedPoseFrozen then
                -- Ragdoll physics stop reporting while frozen: keep the
                -- freeze instead of cycling it every frame.
                FreezeEntityPosition(ped, true)
            else
                -- Standing, falling or lying without ragdoll physics:
                -- release any freeze and force the fall again. The freeze
                -- engages on the next frame once the ragdoll starts.
                FreezeEntityPosition(ped, false)
                SetPedToRagdoll(ped, -1, -1, 0, false, false, false)
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
    downedAt = GetGameTimer()

    finishedPoseFrozen = false
    finishRetries = finishRetries + 1

    print(('^3[DEATH]^7 finish refused by server (attempt %s), retrying...'):format(tostring(finishRetries)))

    if finishRetries >= 5 then
        -- Give up: stay downed. Only EXECUTE, the timer or GIVE UP can still
        -- finish the player - damage never does.
        print('^1[DEATH]^7 finish retry limit reached, staying downed.')

        local ped = PlayerPedId()

        if ped and ped ~= 0 and DoesEntityExist(ped) then
            -- Unfreeze / end the finished ragdoll; the DOWNED controller
            -- re-asserts the limp body on the next frame.
            releaseFromRagdoll(ped)
        end

        return
    end

    SetTimeout(1500, function()
        if state == State.DOWNED then
            enterFinished('retry after refusal')
        end
    end)
end)

-- Someone started executing us: pose the limp body for the execution.
RegisterNetEvent('amb_client:executionStarted', function(executorSrc, executorName)
    isBeingExecuted = true

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        dropLifeless(ped)

        -- During the execution the body may be frozen so the executor's
        -- animation lines up cleanly.
        FreezeEntityPosition(ped, true)
    end

    Framework.Notify(_L('being_executed', {
        name = tostring(executorName or ('Player ' .. tostring(executorSrc or '?')))
    }), 'error')
end)

-- Execution was cancelled: back to the limp DOWNED body.
RegisterNetEvent('amb_client:executionStopped', function()
    isBeingExecuted = false

    if state ~= State.DOWNED then
        return
    end

    -- Cancelled execution: back to the DOWNED state exactly as before -
    -- limp ragdoll on the ground, NO freeze, NO stuck pose.
    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        applyDownedLimp(ped)
    end
end)

RegisterNetEvent('amb_client:setCarried', function(carried)
    isCarried = carried == true

    -- The limp ragdoll must not fight the carry; the controller re-asserts
    -- the body once the player is put down again.
    if isCarried then
        local ped = PlayerPedId()

        if ped and ped ~= 0 and DoesEntityExist(ped) then
            releaseDownedLimp(ped)
        end
    end
end)

RegisterNetEvent('amb_client:syncCPRAnimation', function()
    isTreated = true

    -- End the limp ragdoll while CPR is running; it comes back once it ends.
    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        releaseDownedLimp(ped)
    end
end)

RegisterNetEvent('amb_client:stopCPRAnimation', function()
    isTreated = false

    -- The legacy health handler re-applies its own downed pose on this event;
    -- clear it and drop the body back into the limp ragdoll right away.
    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) and state == State.DOWNED then
        ClearPedTasksImmediately(ped)
        applyDownedLimp(ped)
    end
end)

AddEventHandler('amb_client:onPlayerRevive', function()
    state = State.ALIVE
    downedAt = 0
    isCarried = false
    isTreated = false
    isBeingExecuted = false
    finishRetries = 0

    DisablePlayerFiring(PlayerId(), false)

    finishedPoseFrozen = false

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        -- Revived = everything released: ragdoll ended, no freeze, no
        -- invincibility, no damage proofs, normal movement.
        releaseDownedLimp(ped)

        SetEntityInvincible(ped, false)
        SetEntityProofs(ped, false, false, false, false, false, false, false, false)
        lastHealth = GetEntityHealth(ped)

        SetPedCanPlayAmbientAnims(ped, true)
        SetPedCanPlayAmbientBaseAnims(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, false)
    end

    print('^2[DEATH]^7 revived, state reset to ALIVE.')
end)

RegisterNetEvent('amb_client:finishedRespawn', function()
    state = State.ALIVE
    downedAt = 0
    isCarried = false
    isTreated = false
    isBeingExecuted = false

    DisablePlayerFiring(PlayerId(), false)

    finishedPoseFrozen = false

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        -- The body was frozen and ragdolled while FINISHED: release it all so
        -- the hospital respawn can stand the player up.
        ClearPedTasksImmediately(ped)
        SetEntityInvincible(ped, false)
        SetEntityProofs(ped, false, false, false, false, false, false, false, false)
        FreezeEntityPosition(ped, false)
        SetPedCanRagdoll(ped, true)
        SetPedCanPlayAmbientAnims(ped, true)
        SetPedCanPlayAmbientBaseAnims(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, false)
        lastHealth = GetEntityHealth(ped)
    end

    print('^2[DEATH]^7 hospital respawn done, state reset to ALIVE.')
end)

-- Resource (re)start: never leave a player stuck dead / downed / frozen.
RegisterNetEvent('amb_client:deathSystemReset', function()
    state = State.ALIVE
    downedAt = 0
    isCarried = false
    isTreated = false
    isBeingExecuted = false
    finishRetries = 0

    DisablePlayerFiring(PlayerId(), false)

    finishedPoseFrozen = false

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        ClearPedTasksImmediately(ped)
        SetEntityInvincible(ped, false)
        SetEntityProofs(ped, false, false, false, false, false, false, false, false)
        FreezeEntityPosition(ped, false)
        SetPedCanRagdoll(ped, true)
        SetPedCanPlayAmbientAnims(ped, true)
        SetPedCanPlayAmbientBaseAnims(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, false)
        lastHealth = GetEntityHealth(ped)
    end

    EnableAllControlActions(0)

    SendNUIMessage({ action = 'amb_toggleDeathScreen', show = false })
end)

-- On script start: make sure the death UI starts hidden.
CreateThread(function()
    Wait(1000)

    if state == State.ALIVE then
        SendNUIMessage({ action = 'amb_toggleDeathScreen', show = false })
    end
end)

-- ---------------------------------------------------------------
-- Debug helpers
-- ---------------------------------------------------------------
-- /mercydown  - forces the downed state
-- /mercytest  - forces the FINISHED state right away
-- /mercyreset - clears the finished state and stands the player up
RegisterCommand('mercydown', function()
    print('^1[DEATH]^7 /mercydown: forcing DOWNED state...')
    enterDowned('mercydown command')
end, false)

RegisterCommand('mercytest', function()
    print('^1[DEATH]^7 /mercytest: forcing FINISHED state...')
    enterFinished('mercytest command')
end, false)

RegisterCommand('mercyreset', function()
    print('^1[DEATH]^7 /mercyreset: clearing finished state...')
    TriggerServerEvent('amb_server:clearFinished')
end, false)
