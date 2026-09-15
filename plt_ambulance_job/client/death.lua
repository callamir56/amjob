--[[
    ------------------------------------------------------------------
    PLT AMBULANCE - DEATH SYSTEM v2 (client side)
    ------------------------------------------------------------------
    Animation-based design (NO ragdoll):

      * ANY fatal damage -> DOWNED (unconscious): the body lies on the
        ground playing a special lying animation (dead/dead_a), pinned at
        1 HP, no weapons, no normal respawn. Death UI + timer + CALL EMS.
        LB Phone keeps working.
      * KILLER info (name / id / weapon) captured at the moment of death,
        validated by the server.
      * While downed, other players can EXECUTE via the target interaction
        (progress bar, server validated).
      * Death timer: server-authoritative elapsed time; when it ends the
        player bleeds out and is FINISHED.
      * GIVE UP after the configured time -> FINISHED.
      * FINISHED: completely dead on the ground (own special lying
        animation, misslamar1dead_body/dead_idle, frozen), no revive, no
        EMS, nothing. Hospital respawn after the finished countdown with
        the whole ox_inventory wiped.
      * DOWNED means CRAWLING: the player belly-crawls slowly (prone
        locomotion) and stays vulnerable - ANY further damage (shot again,
        melee, explosion, ...) FINISHES them on the spot (server validated).
      * HEADSHOT = instant down: a bullet to the head drops the player to
        DOWNED right away, even from full health.

    Detection does not rely on FiveM damage events: one loop watches the
    player's health every frame, the same way the GTA engine itself
    detects death. Poses are plain looping animations, re-applied only
    when lost - deterministic, no physics, the body can never stand up,
    and nothing here fights other scripts in a loop.
]]

if Config.DisableDeathSystem == true then
    return
end

if Config.DeathSystem and Config.DeathSystem.Enabled == false then
    return
end

-- Special animations. All of them are already referenced by this resource,
-- so the revive cleanup in health.lua already knows and stops every one.
local DOWNED_DICT = 'dead'
local DOWNED_ANIM = 'dead_a'
local FINISHED_DICT = 'misslamar1dead_body'
local FINISHED_ANIM = 'dead_idle'
local SIT_DICT = 'veh@low@front_ps@idle_duck'
local SIT_ANIM = 'sit'

-- Belly-crawl locomotion while DOWNED. move_crawl is tried first; if the set
-- never streams in, the proven injured limp (move_m@injured + stealth, the
-- legacy mechanism) is used instead - never a stuck standing ped.
local CRAWL_SET = 'move_crawl'
local LIMP_SET = 'move_m@injured'
local CRAWL_SET_WAIT_MS = 2000

-- Head bones: any damage through one of these = instant DOWNED (headshot).
local HEAD_BONES = {
    [31086] = true, -- SKEL_Head
    [12844] = true, -- IK_Head
    [25260] = true, -- FB_L_Eye_000
    [27474] = true, -- FB_R_Eye_000
}
local HEADSHOT_MIN_DROP = 5

local State = {
    ALIVE = 1,
    DOWNED = 2,
    FINISHED = 3,
}

local state = State.ALIVE
local lastHealth = 0
local spawnGraceUntil = 0
local isCarried = false
local isTreated = false
local isBeingExecuted = false
local finishedFrozen = false -- finished freeze latches once the lying pose is confirmed
local nextVehicleSecureAt = 0
local crawlApplied = false -- a crawl clipset is currently driving locomotion
local crawlMode = 'none'   -- 'none' | 'prone' | 'limp'
local crawlProneFailed = false -- sticky per down: move_crawl did not load
local crawlFallbackAt = 0
local finishRequestedAt = 0 -- throttle for damage-finish requests

local lastAttackerEntity = 0
local lastDamageWeapon = 0

-- Only the server may authorize the final hospital respawn.
local hospitalRespawnAuthorized = false

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


-- Explicit UNCONSCIOUS / FINAL DEAD separation for other scripts:
--   UNCONSCIOUS: IsDowned() true,  IsFinished() false
--   FINAL DEAD:  IsDowned() false, IsFinished() true
--   REVIVED:     both false
exports('IsDowned', function()
    return state == State.DOWNED
end)

exports('IsFinished', function()
    return state == State.FINISHED
end)

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

local function ensureDict(dict)
    if not HasAnimDictLoaded(dict) then
        RequestAnimDict(dict)
    end
end

-- Which special pose fits right now: slumped in a seat inside vehicles,
-- the finished lying animation when FINISHED, the downed one otherwise.
local function poseFor(ped)
    if IsPedInAnyVehicle(ped, false) then
        return SIT_DICT, SIT_ANIM
    end

    if state == State.FINISHED then
        return FINISHED_DICT, FINISHED_ANIM
    end

    return DOWNED_DICT, DOWNED_ANIM
end

-- Plays the state's special lying animation. Only (re-)applies when the ped
-- is not already playing it - a deterministic correction, never a restart
-- loop. TaskPlayAnim replaces the current task itself, so no task clearing
-- is ever needed here, and replaying a static lying pose is invisible.
local function playPose(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    local dict, anim = poseFor(ped)

    ensureDict(dict)

    if not HasAnimDictLoaded(dict) then
        return
    end

    if not IsEntityPlayingAnim(ped, dict, anim, 3) then
        TaskPlayAnim(ped, dict, anim, 8.0, 8.0, -1, 1, 0.0, false, false, false)
    end
end

-- Stops our special animations WITHOUT clearing tasks: a revive or wake-up
-- animation playing afterwards must never be killed here.
local function stopPose(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    StopAnimTask(ped, DOWNED_DICT, DOWNED_ANIM, 1.0)
    StopAnimTask(ped, FINISHED_DICT, FINISHED_ANIM, 1.0)
    StopAnimTask(ped, SIT_DICT, SIT_ANIM, 1.0)
end

-- Removes any crawl locomotion (transition only - cheap to call every frame).
local function removeCrawl(ped)
    if not crawlApplied then
        return
    end

    crawlApplied = false
    crawlMode = 'none'

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    ResetPedMovementClipset(ped, 0.5)
    SetPedStealthMovement(ped, false, '')
    SetPedCanPlayAmbientAnims(ped, false)
    SetPedCanPlayAmbientBaseAnims(ped, false)
end

-- Applies a crawl clipset once. The lying tasks are stopped first so the
-- locomotion shows; ambient anims are allowed while crawling so the prone /
-- limp locomotion plays fully (tasks still win whenever one plays).
local function applyCrawl(ped, setName, stealth, mode)
    stopPose(ped)

    SetPedMovementClipset(ped, setName, 0.5)
    SetPedStealthMovement(ped, stealth, '')
    SetPedCanPlayAmbientAnims(ped, true)
    SetPedCanPlayAmbientBaseAnims(ped, true)

    crawlApplied = true
    crawlMode = mode
end

-- Unified DOWNED locomotion, safe to call every frame: only transitions act.
--   treated / carried  -> hands off, CPR / carry own the body
--   executed / vehicle -> lie still (dead_a) / slumped seat (sit)
--   free on foot       -> slow belly-crawl (prone set, proven limp fallback)
local function ensureDownedLocomotion(ped)
    if state ~= State.DOWNED then
        return
    end

    if isTreated or isCarried then
        return
    end

    if isBeingExecuted or IsPedInAnyVehicle(ped, false) then
        removeCrawl(ped)
        playPose(ped)
        return
    end

    if crawlApplied then
        return
    end

    local now = GetGameTimer()

    if not crawlProneFailed and HasAnimSetLoaded(CRAWL_SET) then
        applyCrawl(ped, CRAWL_SET, false, 'prone')
        print('^3[DEATH]^7 crawling (prone).')
        return
    end

    if not crawlProneFailed and now < crawlFallbackAt then
        RequestAnimSet(CRAWL_SET)
        playPose(ped) -- lie still while the set streams in
        return
    end

    crawlProneFailed = true

    if HasAnimSetLoaded(LIMP_SET) then
        applyCrawl(ped, LIMP_SET, true, 'limp')
        print('^3[DEATH]^7 move_crawl unavailable, crawling (injured limp).')
    else
        RequestAnimSet(LIMP_SET)
        playPose(ped) -- lie still while the fallback streams in
    end
end

-- Who hit us last (opportunistic, from the damage game event). The server
-- re-validates: offline / self / invalid ids are ignored there.
local function currentAttacker()
    local src = 0
    local weapon = lastDamageWeapon
    local attacker = lastAttackerEntity

    if attacker and attacker ~= 0 and DoesEntityExist(attacker) then
        local playerIndex = NetworkGetPlayerIndexFromPed(attacker)

        if playerIndex ~= -1 and NetworkIsPlayerActive(playerIndex) then
            src = GetPlayerServerId(playerIndex)
        end
    end

    return tonumber(src) or 0, tonumber(weapon) or 0
end

-- Damage while DOWNED finishes: one request, retried at most every 2s until
-- the server broadcast flips us to FINISHED.
local function requestDamageFinish()
    local now = GetGameTimer()

    if finishRequestedAt ~= 0 and now - finishRequestedAt < 2000 then
        return
    end

    finishRequestedAt = now

    local src, weapon = currentAttacker()

    TriggerServerEvent('amb_server:finishPlayer', 'damage', src, weapon)
end

-- A downed/finished driver must never drive off: lock the vehicle (throttled,
-- the death screen unlocks it again on revive).
local function secureVehicle(ped, now)
    if now < nextVehicleSecureAt then
        return
    end

    nextVehicleSecureAt = now + 500

    if not IsPedInAnyVehicle(ped, false) then
        return
    end

    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
        SetVehicleUndriveable(vehicle, true)
        SetVehicleEngineOn(vehicle, false, true, true)
        SetVehicleForwardSpeed(vehicle, 0.0)
        SetEntityVelocity(vehicle, 0.0, 0.0, 0.0)
    end
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

    local ped = PlayerPedId()

    local died = IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0

    local killerInfo = captureKiller(ped, died)

    ped = resurrectLocalPlayer(ped)

    SetEntityMaxHealth(ped, 200)
    SetEntityHealth(ped, downedHealth())
    lastHealth = downedHealth()

    -- DOWNED stays VULNERABLE on purpose: any further damage finishes the
    -- player (the loop below detects it). Never invincible: keeps every
    -- animation path clean.
    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)

    DisablePlayerFiring(PlayerId(), true)

    -- Downed means no weapons at all: holster whatever is drawn.
    pcall(function()
        if GetSelectedPedWeapon(ped) ~= GetHashKey('WEAPON_UNARMED') then
            SetCurrentPedWeapon(ped, GetHashKey('WEAPON_UNARMED'), true)
        end
    end)

    -- DOWNED is never frozen: the unconscious body just lies there.
    FreezeEntityPosition(ped, false)

    SetPedCanPlayAmbientAnims(ped, false)
    SetPedCanPlayAmbientBaseAnims(ped, false)
    SetBlockingOfNonTemporaryEvents(ped, true)

    -- DOWNED locomotion: slow belly-crawl on foot (slumped in a seat
    -- inside vehicles - the ped is never dragged out).
    crawlApplied = false
    crawlMode = 'none'
    crawlProneFailed = false
    crawlFallbackAt = GetGameTimer() + CRAWL_SET_WAIT_MS
    finishRequestedAt = 0
    RequestAnimSet(CRAWL_SET)
    RequestAnimSet(LIMP_SET)
    ensureDict(DOWNED_DICT)
    ensureDict(SIT_DICT)
    ensureDownedLocomotion(ped)
    secureVehicle(ped, 0)

    markDowned(killerInfo)
    reportKillerToServer(killerInfo)

    Framework.Notify(_L('downed_crawling', {
        seconds = math.floor(tonumber(Config.DeathSystem and Config.DeathSystem.DeathTimer) or 600)
    }), 'warning')

    print(('^3[DEATH]^7 downed (%s)'):format(tostring(reason)))
end

-- Runs ONLY from the server broadcast (amb_client:syncFinishedPlayer): the
-- server is the single authority that finishes players. Never echoes back,
-- so this can never finish a player on its own and needs no retry logic.
local function enterFinished()
    if state == State.FINISHED then
        return
    end

    state = State.FINISHED
    finishedFrozen = false

    local ped = PlayerPedId()

    ped = resurrectLocalPlayer(ped)

    SetEntityMaxHealth(ped, 200)
    SetEntityHealth(ped, downedHealth())
    lastHealth = downedHealth()

    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, true, true, true, true, true, true, true, true)

    DisablePlayerFiring(PlayerId(), true)

    -- The freeze is applied by the loop below, and only AFTER the finished
    -- lying animation is confirmed playing - freezing a static lying pose
    -- can never stand the body up.
    FreezeEntityPosition(ped, false)

    SetPedCanPlayAmbientAnims(ped, false)
    SetPedCanPlayAmbientBaseAnims(ped, false)
    SetBlockingOfNonTemporaryEvents(ped, true)

    -- Crawling is over: back to a static lying body.
    removeCrawl(ped)

    ensureDict(FINISHED_DICT)
    ensureDict(SIT_DICT)
    playPose(ped)
    secureVehicle(ped, 0)

    -- Finished while carried: get off the carrier's back right away (the
    -- carrier auto-drops through syncDownedPlayer(false) from the server).
    if isCarried then
        isCarried = false
        DetachEntity(ped, true, false)
        TriggerServerEvent('amb_server:dropCarried', GetPlayerServerId(PlayerId()))
    end

    markDowned()

    print('^1[DEATH]^7 FINISHED (server confirmed).')
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

-- Control blocking for the DOWNED state: combat / vehicle / action controls
-- only. Everything else - look, move, and in particular the LB Phone key -
-- keeps working. DisableControlAction is per-frame only, so this runs every
-- frame while downed - nothing here is sticky and nothing here freezes.
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
    DisableControlAction(0, 245, true) -- T / MP text chat
    DisableControlAction(0, 246, true) -- Y / push-to-talk / chat-related input
    DisableControlAction(0, 303, true) -- U / multiplayer info

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
                else
                    -- HEADSHOT = instant down, even from full health: drop
                    -- the HP to 0 and go DOWNED right away.
                    local boneOk, bone = GetPedLastDamageBone(ped)

                    if boneOk and HEAD_BONES[bone] and (lastHealth - health) >= HEADSHOT_MIN_DROP then
                        SetEntityHealth(ped, 0)
                        Wait(50) -- one tick of real death: registers cause of death
                        ped = PlayerPedId()
                        enterDowned('headshot')
                    end
                end

                lastHealth = GetEntityHealth(PlayerPedId())
            else
                lastHealth = health
            end
        elseif state == State.DOWNED then
            -- DOWNED = crawling body, never frozen, never standing. The
            -- player stays VULNERABLE: any new damage (shot again, melee,
            -- explosion, ...) requests an immediate server-validated FINISH.
            FreezeEntityPosition(ped, false)

            enforceDownedControls()
            ensureDownedLocomotion(ped)

            if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
                -- Killed while downed: come right back (no wasted screen)
                -- and finish through the server.
                ped = resurrectLocalPlayer(ped)

                SetEntityMaxHealth(ped, 200)
                SetEntityHealth(ped, downedHealth())
                SetEntityInvincible(ped, false)
                SetEntityProofs(ped, false, false, false, false, false, false, false, false)
                lastHealth = downedHealth()

                -- A resurrect wipes locomotion: force a re-apply next frame.
                crawlApplied = false
                crawlMode = 'none'

                requestDamageFinish()
            else
                local health = GetEntityHealth(ped)

                if health < downedHealth() then
                    -- Fresh damage while downed -> FINISH.
                    lastHealth = health
                    requestDamageFinish()
                elseif health > downedHealth() then
                    -- Never climb above the critical seal without a revive.
                    SetEntityHealth(ped, downedHealth())
                    lastHealth = downedHealth()
                else
                    lastHealth = health
                end

                secureVehicle(ped, now)
            end
        elseif state == State.FINISHED then
            -- FINAL DEAD = fully immobile: resurrect behind the scenes if the
            -- engine killed the ped, pin the 1% health, lock every control,
            -- keep the finished lying animation playing, then freeze it.
            if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
                ped = resurrectLocalPlayer(ped)
                finishedFrozen = false
            end

            local health = GetEntityHealth(ped)

            if health ~= downedHealth() then
                SetEntityHealth(ped, downedHealth())
            end

            lastHealth = downedHealth()

            DisableAllControlActions(0)
            DisableControlAction(0, 245, true) -- T / MP text chat
            DisableControlAction(0, 246, true) -- Y / chat-related input
            DisableControlAction(0, 303, true) -- U / multiplayer info
            DisablePlayerFiring(PlayerId(), true)
            SetPedCanPlayAmbientAnims(ped, false)
            SetPedCanPlayAmbientBaseAnims(ped, false)
            SetBlockingOfNonTemporaryEvents(ped, true)

            playPose(ped)
            secureVehicle(ped, now)

            -- Freeze only a CONFIRMED lying pose: the finished animation is
            -- static, so this latch can never catch an upright body.
            if not finishedFrozen then
                local dict, anim = poseFor(ped)

                if IsEntityPlayingAnim(ped, dict, anim, 3) then
                    FreezeEntityPosition(ped, true)
                    finishedFrozen = true
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
        enterFinished()
    end
end)

-- Someone started executing us: the body is ALREADY lying unconscious - leave
-- it exactly as it is. The DOWNED loop keeps the pose for the whole execution.
RegisterNetEvent('amb_client:executionStarted', function(executorSrc, executorName)
    isBeingExecuted = true

    -- Lie still right away: a victim cannot crawl away from an execution.
    if state == State.DOWNED then
        ensureDownedLocomotion(PlayerPedId())
    end

    Framework.Notify(_L('being_executed', {
        name = tostring(executorName or ('Player ' .. tostring(executorSrc or '?')))
    }), 'error')
end)

-- Execution was cancelled: back to the unconscious DOWNED pose.
RegisterNetEvent('amb_client:executionStopped', function()
    isBeingExecuted = false

    if state ~= State.DOWNED then
        return
    end

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        ensureDownedLocomotion(ped)
    end
end)

RegisterNetEvent('amb_client:setCarried', function(carried)
    -- The server never carries a finished body; refuse defensively anyway.
    if state == State.FINISHED then
        isCarried = false
        return
    end

    isCarried = carried == true

    -- Put down again: crawl again right away.
    if not isCarried and state == State.DOWNED then
        local ped = PlayerPedId()

        if ped and ped ~= 0 and DoesEntityExist(ped) then
            ensureDownedLocomotion(ped)
        end
    end
end)

RegisterNetEvent('amb_client:syncCPRAnimation', function()
    if state ~= State.DOWNED then
        return
    end

    -- CPR takes over the body; the pose comes back when it ends.
    isTreated = true
end)

RegisterNetEvent('amb_client:stopCPRAnimation', function()
    isTreated = false

    if state ~= State.DOWNED then
        return
    end

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        ensureDownedLocomotion(ped)
    end
end)

-- Fully releases the body: animations stopped, no freeze, no proofs, normal
-- movement. Never clears tasks, so a revive / wake-up animation survives.
local function releaseBody(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    FreezeEntityPosition(ped, false)
    stopPose(ped)

    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)

    ResetPedMovementClipset(ped, 0.5)
    ResetPedStrafeClipset(ped)
    ResetPedWeaponMovementClipset(ped)
    SetPedStealthMovement(ped, false, '')

    SetPedCanPlayAmbientAnims(ped, true)
    SetPedCanPlayAmbientBaseAnims(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, false)
end

local function resetStateFlags()
    state = State.ALIVE
    isCarried = false
    isTreated = false
    isBeingExecuted = false
    finishedFrozen = false
    hospitalRespawnAuthorized = false
    crawlApplied = false
    crawlMode = 'none'
    crawlProneFailed = false
    finishRequestedAt = 0

    DisablePlayerFiring(PlayerId(), false)
end

AddEventHandler('amb_client:onPlayerRevive', function()
    -- NEVER let a generic EMS/health revive clear FINISHED. The only legal
    -- FINISHED -> ALIVE transition is amb_client:finishedRespawn, issued by
    -- the server after the hospital timer expires.
    if state == State.FINISHED then
        print('^1[DEATH]^7 Blocked generic revive: player is FINISHED.')
        return
    end

    resetStateFlags()

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        releaseBody(ped)
        lastHealth = GetEntityHealth(ped)
    end

    print('^2[DEATH]^7 revived, state reset to ALIVE.')
end)

RegisterNetEvent('amb_client:authorizeFinishedRespawn', function()
    hospitalRespawnAuthorized = true
end)

RegisterNetEvent('amb_client:finishedRespawn', function(authorized)
    if authorized ~= true or hospitalRespawnAuthorized ~= true then
        print('^1[DEATH]^7 Blocked unauthorized finishedRespawn event.')
        return
    end

    resetStateFlags()

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        -- The body was frozen in its finished pose: release it all so the
        -- hospital respawn can stand the player up. Clearing tasks here is
        -- safe: the wake-up animation plays afterwards.
        releaseBody(ped)
        ClearPedTasksImmediately(ped)
        SetEntityCollision(ped, true, true)
        lastHealth = GetEntityHealth(ped)
    end

    print('^2[DEATH]^7 hospital respawn done, state reset to ALIVE.')
end)

RegisterNetEvent('amb_client:debugRespawn', function()
    resetStateFlags()

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        releaseBody(ped)
        ClearPedTasksImmediately(ped)
        SetEntityCollision(ped, true, true)
        lastHealth = GetEntityHealth(ped)
    end

    EnableAllControlActions(0)
    SendNUIMessage({ action = 'amb_toggleDeathScreen', show = false })
end)

-- Resource (re)start: never leave a player stuck dead / downed / frozen.
RegisterNetEvent('amb_client:deathSystemReset', function()
    resetStateFlags()

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        releaseBody(ped)
        ClearPedTasksImmediately(ped)
        SetEntityCollision(ped, true, true)
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
-- /mercytest  - forces the FINISHED state right away (visual test only:
--               the server does not know, so no hospital respawn follows -
--               use /mercyreset afterwards)
-- /mercyreset - clears everything through the server and stands up
RegisterCommand('mercydown', function()
    print('^1[DEATH]^7 /mercydown: forcing DOWNED state...')
    enterDowned('mercydown command')
end, false)

RegisterCommand('mercytest', function()
    print('^1[DEATH]^7 /mercytest: forcing FINISHED state (visual only)...')
    enterFinished()
end, false)

RegisterCommand('mercyreset', function()
    print('^1[DEATH]^7 /mercyreset: clearing death state...')
    TriggerServerEvent('amb_server:clearFinished')
end, false)
