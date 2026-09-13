--[[
    ------------------------------------------------------------------
    PLT AMBULANCE - DEATH SYSTEM (client side)
    ------------------------------------------------------------------
    Full spec implementation:

      * ANY fatal damage -> DOWNED / CRITICAL: on the ground, crawl only,
        no weapons, no normal respawn. Death UI + timer + one-time CALL EMS.
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
local downedPoseState = nil -- nil | 'still' | 'fwd' | 'bwd' (crawl pose)

local lastAttackerEntity = 0
local lastDamageWeapon = 0

-- The wounded crawl: 'move_crawl' keeps the ped flat on its front. The
-- moving variant (flag 47) moves the ped through the world while the
-- animation plays; the still variant (flag 46) loops in place. WASD input
-- drives it, so the ped CRAWLS on the ground instead of standing up.
local CRAWL_DICT = 'move_crawl'
local CRAWL_ANIM_FWD = 'onfront_fwd'
local CRAWL_ANIM_BWD = 'onfront_bwd'
local CRAWL_FLAG_STILL = 46
local CRAWL_FLAG_MOVE = 47

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

local function crawlEnabled()
    return not (Config.DeathSystem and Config.DeathSystem.CrawlEnabled == false)
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

-- DOWNED pose / crawl state controller.
--
-- RULES (this is a state controller, NOT a per-frame animation trigger):
--  * The ped is NEVER frozen while downed - FreezeEntityPosition belongs to
--    FINISHED only (a short freeze while being executed is allowed).
--  * WASD = crawl: W/S move forward/backward on the ground, A/D turn.
--    Standing, walking, running, jumping, weapons and vehicles stay blocked
--    (see enforceDownedControls below).
--  * The animation is re-applied ONLY when the task was really lost (engine
--    interruption, ragdoll ended, or the ped somehow stood up) - it is never
--    restarted frame after frame while it is playing.
local function applyCrawlPose(ped)
    if not crawlEnabled() or IsPedInAnyVehicle(ped, false) or isCarried or isBeingExecuted then
        return
    end

    -- DOWNED is never frozen: crawl must stay possible.
    FreezeEntityPosition(ped, false)

    if IsPedRagdoll(ped) then
        -- Let the ragdoll settle; the pose is re-applied once it ends.
        return
    end

    if not HasAnimDictLoaded(CRAWL_DICT) then
        RequestAnimDict(CRAWL_DICT)

        local waited = 0

        while not HasAnimDictLoaded(CRAWL_DICT) and waited < 1000 do
            Wait(50)
            waited = waited + 50
        end
    end

    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)

    local moveAxis = GetControlNormal(0, 31)
    local wantFwd = IsControlPressed(0, 32) or moveAxis > 0.5
    local wantBwd = IsControlPressed(0, 33) or moveAxis < -0.5

    -- Apply the animation on input transitions only.
    if downedPoseState ~= 'fwd' and wantFwd and not wantBwd then
        TaskPlayAnimAdvanced(ped, CRAWL_DICT, CRAWL_ANIM_FWD, coords, 1.0, 0.0, heading,
            1.0, 1.0, 1.0, CRAWL_FLAG_MOVE, 1.0, 0, 0)
        downedPoseState = 'fwd'
    elseif downedPoseState ~= 'bwd' and wantBwd and not wantFwd then
        TaskPlayAnimAdvanced(ped, CRAWL_DICT, CRAWL_ANIM_BWD, coords, 1.0, 0.0, heading,
            1.0, 1.0, 1.0, CRAWL_FLAG_MOVE, 1.0, 0, 0)
        downedPoseState = 'bwd'
    elseif downedPoseState ~= 'still' and not wantFwd and not wantBwd then
        TaskPlayAnimAdvanced(ped, CRAWL_DICT, CRAWL_ANIM_FWD, coords, 1.0, 0.0, heading,
            1.0, 1.0, 1.0, CRAWL_FLAG_STILL, 1.0, 0, 0)
        downedPoseState = 'still'
    end

    -- Turn with A/D while crawling.
    if downedPoseState == 'fwd' or downedPoseState == 'bwd' then
        if IsControlPressed(0, 34) then
            SetEntityHeading(ped, heading + 2.0)
        elseif IsControlPressed(0, 35) then
            SetEntityHeading(ped, heading - 2.0)
        end
    end

    -- Guard: only re-apply when the task is really gone (engine cleared it,
    -- ragdoll ended, or the ped stood up). Never restarts while the ped is
    -- actually playing or crawling.
    local currentAnim = (downedPoseState == 'bwd') and CRAWL_ANIM_BWD or CRAWL_ANIM_FWD
    local playing = IsEntityPlayingAnim(ped, CRAWL_DICT, currentAnim, 3)
    local stoodUp = GetEntityHeightAboveGround(ped) > 0.6
    local moving = GetEntitySpeed(ped) > 0.3

    if stoodUp or (not playing and (downedPoseState == 'still' or not moving)) then
        local flag = (downedPoseState == 'fwd' or downedPoseState == 'bwd')
            and CRAWL_FLAG_MOVE or CRAWL_FLAG_STILL

        TaskPlayAnimAdvanced(ped, CRAWL_DICT, currentAnim, GetEntityCoords(ped), 1.0, 0.0,
            GetEntityHeading(ped), 1.0, 1.0, 1.0, flag, 1.0, 0, 0)
    end
end

-- Fully releases the crawl state: animation stopped, freeze lifted. Safe to
-- call from revive / carry / CPR / execution / reset paths.
local function stopCrawlPose(ped)
    downedPoseState = nil

    if IsEntityPlayingAnim(ped, CRAWL_DICT, CRAWL_ANIM_FWD, 3) then
        StopAnimTask(ped, CRAWL_DICT, CRAWL_ANIM_FWD, 1.0)
    end

    if IsEntityPlayingAnim(ped, CRAWL_DICT, CRAWL_ANIM_BWD, 3) then
        StopAnimTask(ped, CRAWL_DICT, CRAWL_ANIM_BWD, 1.0)
    end

    FreezeEntityPosition(ped, false)
end

-- Ends any lingering lifeless state (infinite ragdoll from dropLifeless) and
-- returns the body to a controllable state so the crawl can take over again.
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

    SetPedToRagdoll(ped, 99999999, 99999999, 1, false, false, false)
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

    -- NO invincibility: damage must keep registering so the health watch can
    -- detect the finishing hit (1 HP -> 0).
    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)

    DisablePlayerFiring(PlayerId(), true)

    -- Downed means no weapons at all: holster whatever is drawn.
    pcall(function()
        if GetSelectedPedWeapon(ped) ~= GetHashKey('WEAPON_UNARMED') then
            SetCurrentPedWeapon(ped, GetHashKey('WEAPON_UNARMED'), true)
        end
    end)

    -- DOWNED is NEVER frozen: crawl stays possible. (Full freeze belongs to
    -- FINISHED, and a short freeze is allowed only while being executed.)
    FreezeEntityPosition(ped, false)

    if crawlEnabled() then
        applyCrawlPose(ped)
    else
        dropLifeless(ped)
    end

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

    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)

    DisablePlayerFiring(PlayerId(), true)

    -- FINAL DEAD = FULLY IMMOBILE: no animation, ragdoll on the ground and
    -- the entity frozen. Freeze is allowed ONLY here (and briefly while
    -- being executed), never while merely downed.
    stopCrawlPose(ped)
    dropLifeless(ped)
    FreezeEntityPosition(ped, true)

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

-- Control blocking for the DOWNED state. Crawl input (WASD + look) stays
-- free; everything that could stand the ped up or let it fight is blocked.
-- DisableControlAction is per-frame only, so this runs every frame while
-- downed - nothing here is sticky and nothing here freezes the ped.
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
-- ONE loop: health watch + crawl/finished enforcement
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
            -- DOWNED = crawl only. Everything that could stand the ped up or
            -- let it fight is blocked; WASD stays free for the crawl. The
            -- ped itself is NEVER frozen here (freeze belongs to FINISHED).
            enforceDownedControls()

            if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
                -- The 1 HP dropped to 0: killed while downed = finished.
                enterFinished('killed while downed')
            else
                local health = GetEntityHealth(ped)

                if isCarried or isTreated then
                    lastHealth = health
                elseif health < lastHealth then
                    -- Any further damage (bullet, kick, vehicle, anything).
                    enterFinished('damage while downed')
                    lastHealth = GetEntityHealth(PlayerPedId())
                else
                    -- Keep the 1 HP pinned while crawling.
                    if health > downedHealth() then
                        SetEntityHealth(ped, downedHealth())
                    end

                    lastHealth = downedHealth()

                    -- Crawl state controller: keeps the ped on the ground in
                    -- the wounded pose, never restarts the anim while playing.
                    applyCrawlPose(ped)
                end
            end
        elseif state == State.FINISHED then
            -- FINAL DEAD = fully immobile: resurrect behind the scenes if the
            -- engine killed the ped, pin the 1% health, lock every control,
            -- keep the body ragdolled on the ground and FROZEN.
            if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
                ped = resurrectLocalPlayer(ped)

                -- A resurrected ped stands up: put the body back on the ground.
                dropLifeless(ped)
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
            FreezeEntityPosition(ped, true)

            if not IsPedInAnyVehicle(ped, false) and not IsPedRagdoll(ped) then
                if IsPedGettingUp(ped) or IsPedWalking(ped) or IsPedRunning(ped)
                    or IsPedJumping(ped) or GetEntitySpeed(ped) > 0.5
                    or GetEntityHeightAboveGround(ped) > 0.5 then
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
    downedAt = GetGameTimer()

    finishRetries = finishRetries + 1

    print(('^3[DEATH]^7 finish refused by server (attempt %s), retrying...'):format(tostring(finishRetries)))

    if finishRetries >= 5 then
        -- Give up: stay downed, the player can still be finished by damage.
        print('^1[DEATH]^7 finish retry limit reached, staying downed.')

        local ped = PlayerPedId()

        if ped and ped ~= 0 and DoesEntityExist(ped) then
            releaseFromRagdoll(ped)
        end

        if crawlEnabled() then
            applyCrawlPose(ped)
        end

        return
    end

    SetTimeout(1500, function()
        if state == State.DOWNED then
            enterFinished('retry after refusal')
        end
    end)
end)

-- Someone started executing us: lie flat, no crawl until it is over.
RegisterNetEvent('amb_client:executionStarted', function(executorSrc, executorName)
    isBeingExecuted = true

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        stopCrawlPose(ped)
        dropLifeless(ped)

        -- During the execution the body may be frozen so the executor's
        -- animation lines up cleanly.
        FreezeEntityPosition(ped, true)
    end

    Framework.Notify(_L('being_executed', {
        name = tostring(executorName or ('Player ' .. tostring(executorSrc or '?')))
    }), 'error')
end)

-- Execution was cancelled: back to the crawl.
RegisterNetEvent('amb_client:executionStopped', function()
    isBeingExecuted = false

    if state ~= State.DOWNED then
        return
    end

    -- Cancelled execution: back to the DOWNED state exactly as before -
    -- crawl enabled, standing disabled, NO freeze, NO stuck ragdoll.
    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        releaseFromRagdoll(ped)

        if crawlEnabled() then
            applyCrawlPose(ped)
        end
    end
end)

RegisterNetEvent('amb_client:setCarried', function(carried)
    isCarried = carried == true

    -- The crawl pose must not fight the carry; the loop re-applies it once
    -- the player is put down again.
    if isCarried then
        local ped = PlayerPedId()

        if ped and ped ~= 0 and DoesEntityExist(ped) then
            stopCrawlPose(ped)
        end
    end
end)

RegisterNetEvent('amb_client:syncCPRAnimation', function()
    isTreated = true

    -- Stop the crawl while CPR is running; it comes back once it ends.
    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        stopCrawlPose(ped)
    end
end)

RegisterNetEvent('amb_client:stopCPRAnimation', function()
    isTreated = false
end)

AddEventHandler('amb_client:onPlayerRevive', function()
    state = State.ALIVE
    downedAt = 0
    isCarried = false
    isTreated = false
    isBeingExecuted = false
    finishRetries = 0

    DisablePlayerFiring(PlayerId(), false)

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        stopCrawlPose(ped)

        -- Revived = everything released: no crawl, no freeze, normal movement.
        FreezeEntityPosition(ped, false)
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

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        -- The body was frozen and ragdolled while FINISHED: release it all so
        -- the hospital respawn can stand the player up.
        stopCrawlPose(ped)
        ClearPedTasksImmediately(ped)
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

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        stopCrawlPose(ped)
        ClearPedTasksImmediately(ped)
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
