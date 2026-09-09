local DEAD_DICT = 'dead'
local DEAD_ANIM = 'dead_a'
local SIT_DICT = 'veh@low@front_ps@idle_duck'
local SIT_ANIM = 'sit'

local injuries = {
    head = { level = 0, bullet = false, bandaged = false, isFractured = false, fractureTime = 0 },
    chest = { level = 0, bullet = false, bandaged = false, isFractured = false, fractureTime = 0 },
    left_arm = { level = 0, bullet = false, bandaged = false, isFractured = false, fractureTime = 0 },
    right_arm = { level = 0, bullet = false, bandaged = false, hunger = false, isFractured = false, fractureTime = 0 },
    left_leg = { level = 0, bullet = false, bandaged = false, isFractured = false, fractureTime = 0 },
    right_leg = { level = 0, bullet = false, bandaged = false, isFractured = false, fractureTime = 0 },
    bleeding = 0
}

local isPatientBandaged = false
local isDowned = false
local medicalState = Framework.MedicalState.ALIVE
local downedSince = 0
local isBleedingOut = false
local isKnockedOut = false
local isReviving = false
local isTreating = false
local isDeathScreenOpen = false
local isBeingTreated = false
local isInLastStand = false
local bleedTimer = 0
local knockoutTimer = 0
local fractureTimer = 0
local fractureTickAt = 0
local proofsApplied = true
local useBuiltInDeathscreen = not Config.Deathscreen or Config.Deathscreen.UseBuiltIn ~= false
local UNARMED_WEAPON = -1569615261

local removedClothes = {
    model = nil,
    top = nil,
    bottom = nil
}

local savedHealth = nil
local healthRestored = false
local lastAppliedHealth = nil
local lastDamageTime = 0
local deadRestrictionsActive = false
local lastBleedTick = 0
local voiceMuted = false
local actionsBlockedUntil = 0
local isUsingMedication = false
local walkingAidItem = nil
local crutchProp = nil
local spawnManagerDisabled = false

local function pushMedicalState(state)
    if Config.DisableDeathSystem == true then
        return
    end

    if Framework and Framework.HasAuthoritativeMedicalState() then
        TriggerServerEvent('amb_server:SetMedicalState', Framework.NormalizeMedicalState(state))
        return
    end

    TriggerServerEvent('amb_server:SetDowned', state ~= Framework.MedicalState.ALIVE)
end

local function requestMedicalStateSync()
    if not (Framework and Framework.HasAuthoritativeMedicalState()) then
        return
    end

    Framework.TriggerCallback('amb_server:getMedicalState', function(state, elapsed)
        if not state then
            return
        end

        TriggerEvent('amb_client:syncMedicalState', state, elapsed)
    end)
end

local function disableAutoSpawn()
    if Config.DisableDeathSystem == true then
        return
    end

    if not (Framework and Framework.Type == 'qb') then
        return
    end

    if GetResourceState('spawnmanager') ~= 'started' then
        return
    end

    local ok, err = pcall(function()
        exports.spawnmanager:setAutoSpawn(false)
    end)

    if ok then
        if Config.Debug and not spawnManagerDisabled then
            print('^2[plt_ambulance] Disabled spawnmanager auto-spawn for QBCore death handling.^7')
        end

        spawnManagerDisabled = true
    elseif not spawnManagerDisabled then
        print(('[plt_ambulance] Could not disable spawnmanager auto-spawn: %s'):format(tostring(err)))
    end
end

CreateThread(function()
    Wait(1000)

    disableAutoSpawn()
    requestMedicalStateSync()
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= 'spawnmanager' and resourceName ~= GetCurrentResourceName() then
        return
    end

    Wait(500)
    disableAutoSpawn()
end)

local function getWalkingAidClipset()
    return (Config and Config.WalkingAidClipset)
        or (Config and Config.Health and Config.Health.LimpAnimation)
        or 'move_m@limping@a'
end

local function getCrutchesClipset()
    return (Config and Config.CrutchesClipset) or 'move_lester_CaneUp'
end

local function getActiveAidClipset()
    if walkingAidItem == 'plt_crutches' then
        return getCrutchesClipset()
    end

    return getWalkingAidClipset()
end

local function removeCrutchProp()
    if crutchProp and DoesEntityExist(crutchProp) then
        DetachEntity(crutchProp, true, true)
        DeleteEntity(crutchProp)
    end

    crutchProp = nil
end

local function attachCrutchProp(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    if walkingAidItem ~= 'plt_crutches' then
        removeCrutchProp()
        return
    end

    local model = joaat((Config and Config.CrutchesModel) or 'v_med_crutch01')

    if not IsModelInCdimage(model) or not IsModelValid(model) then
        print('^1[plt_ambulance] Invalid crutch model. Set Config.CrutchesModel to a valid model name.^7')
        return
    end

    Framework.RequestModel(model)

    if not HasModelLoaded(model) then
        return
    end

    local coords = GetEntityCoords(ped)
    local prop = CreateObject(model, coords.x, coords.y, coords.z, true, false, false)

    if not prop or not DoesEntityExist(prop) then
        SetModelAsNoLongerNeeded(model)
        return
    end

    SetEntityCollision(prop, false, false)

    AttachEntityToEntity(prop, ped, 70,
        1.18, -0.36, -0.2,
        -20.0, -87.0, -20.0,
        true, true, false, true, 1, true)

    crutchProp = prop

    SetModelAsNoLongerNeeded(model)
end

local function playGetUpAnimation()
    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    if isDowned or isInLastStand then
        return
    end

    if IsPedInAnyVehicle(ped, false) then
        return
    end

    if IsPedDeadOrDying(ped, true) then
        return
    end

    local proneDict = 'get_up@directional@transition@prone_to_knees@action'
    local proneAnim = 'front'
    local kneesDict = 'get_up@directional@movement@from_knees@action'
    local kneesAnim = 'getup_l_0'

    ClearPedTasksImmediately(ped)

    Framework.RequestAnimDict(proneDict)
    TaskPlayAnim(ped, proneDict, proneAnim, 4.0, 4.0, 900, 0, 0.0, false, false, false)

    Wait(750)

    Framework.RequestAnimDict(kneesDict)
    TaskPlayAnim(ped, kneesDict, kneesAnim, 4.0, 4.0, 1400, 0, 0.0, false, false, false)
end

local function disableHealthRegen()
    local playerId = PlayerId()

    SetPlayerHealthRechargeMultiplier(playerId, 0.0)
    SetPlayerHealthRechargeLimit(playerId, 0.0)
end

local function getDeadRestrictions()
    local restrictions = Config.Health and Config.Health.DeadRestrictions

    if type(restrictions) ~= 'table' then
        return {
            DisableVoice = false,
            DisableInventory = false
        }
    end

    return {
        DisableVoice = restrictions.DisableVoice == true,
        DisableInventory = restrictions.DisableInventory == true
    }
end

local function useBandageOverlay()
    return (Config.Health and Config.Health.BandageAsClothing) == true
end

local function setVoiceMuted(muted)
    if not getDeadRestrictions().DisableVoice then
        muted = false
    end

    if muted == voiceMuted then
        return
    end

    local ok = pcall(function()
        MumbleSetPlayerMuted(PlayerId(), muted)
    end)

    if ok then
        voiceMuted = muted
    end
end

local function closeInventory()
    if Inventory and Inventory.Close then
        Inventory.Close()
    end
end

local function setInventoryBlocked(blocked)
    if not getDeadRestrictions().DisableInventory then
        blocked = false
    end

    local state = LocalPlayer and LocalPlayer.state

    if state then
        state:set('dead', blocked, true)
        state:set('invBusy', blocked, true)
        state:set('invOpen', false, false)
        state:set('invHotkeys', not blocked, false)
        state:set('canUseWeapons', not blocked, false)
    end

    if blocked then
        closeInventory()
    end
end

local function applyDeadRestrictions(active)
    setVoiceMuted(active)
    setInventoryBlocked(active)

    deadRestrictionsActive = active
end

local function clampHealth(value)
    local health = tonumber(value)

    if not health then
        return nil
    end

    health = math.floor(health)

    if health < 100 then
        health = 100
    end

    if health > 200 then
        health = 200
    end

    return health
end

local function blockActionsFor(duration)
    actionsBlockedUntil = GetGameTimer() + math.max(0, tonumber(duration) or 0)
end

local function areActionsBlocked()
    return GetGameTimer() < actionsBlockedUntil
end

local function loadSavedHealth()
    Framework.TriggerCallback('amb_server:getSavedHealth', function(health)
        local value = clampHealth(health)

        if Framework and Framework.HasAuthoritativeMedicalState() and value and value <= 110 then
            local serverId = GetPlayerServerId(PlayerId())

            Framework.TriggerCallback('amb_server:isPlayerDowned', function(downed)
                if downed == true then
                    savedHealth = value
                else
                    savedHealth = nil
                end

                healthRestored = false
            end, serverId)

            return
        end

        savedHealth = value
        healthRestored = false
    end)
end

local function resetInjuries()
    isPatientBandaged = false

    for key, injury in pairs(injuries) do
        if type(injury) == 'table' then
            injury.level = 0
            injury.bullet = false
            injury.bandaged = false

            if injury.hunger ~= nil then
                injury.hunger = false
            end

            injury.needsFludro = false
            injury.isFractured = false
            injury.fractureTime = 0
        else
            injuries[key] = 0
        end
    end
end

local function syncInjuries()
    local payload = {}

    for key, value in pairs(injuries) do
        payload[key] = value
    end

    payload.isPatientBandaged = isPatientBandaged

    TriggerServerEvent('amb_server:syncInjuryData', payload)
end

local function applySavedHealth()
    if healthRestored or not savedHealth then
        return
    end

    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    CreateThread(function()
        Wait(750)

        local currentPed = PlayerPedId()

        if not currentPed or currentPed == 0 or not DoesEntityExist(currentPed) then
            return
        end

        SetEntityHealth(currentPed, savedHealth)

        healthRestored = true
        lastAppliedHealth = savedHealth
    end)
end

local function getComponentVariation(ped, component)
    return {
        drawable = GetPedDrawableVariation(ped, component),
        texture = GetPedTextureVariation(ped, component),
        palette = GetPedPaletteVariation(ped, component)
    }
end

local function getClothesKvpKey()
    local playerData = Framework.GetPlayerData()
    local identifier = playerData and (playerData.citizenid or playerData.identifier or playerData.license)

    if not identifier then
        identifier = GetPlayerServerId(PlayerId())
    end

    return ('plt_amb_removed_clothes_%s'):format(tostring(identifier))
end

local function saveRemovedClothes()
    local key = getClothesKvpKey()

    if not key then
        return
    end

    local hasRemoved = removedClothes and (removedClothes.top or removedClothes.bottom)

    pcall(function()
        if hasRemoved then
            SetResourceKvp(key, json.encode(removedClothes))
        else
            DeleteResourceKvp(key)
        end
    end)
end

local function loadRemovedClothes()
    if removedClothes.top or removedClothes.bottom then
        return
    end

    local key = getClothesKvpKey()

    if not key then
        return
    end

    local raw = nil

    pcall(function()
        raw = GetResourceKvpString(key)
    end)

    if not raw or raw == '' then
        return
    end

    local ok, decoded = pcall(json.decode, raw)

    if not ok or type(decoded) ~= 'table' then
        return
    end

    removedClothes.model = decoded.model
    removedClothes.top = decoded.top
    removedClothes.bottom = decoded.bottom
end

local function captureClothing(part)
    local ped = PlayerPedId()

    if not DoesEntityExist(ped) then
        return
    end

    loadRemovedClothes()

    local model = GetEntityModel(ped)

    if removedClothes.model ~= model then
        removedClothes.model = model
        removedClothes.top = nil
        removedClothes.bottom = nil
    end

    if part == 'top' then
        if not removedClothes.top then
            removedClothes.top = {
                torso = getComponentVariation(ped, 3),
                undershirt = getComponentVariation(ped, 8),
                top = getComponentVariation(ped, 11)
            }
        end
    elseif part == 'bottom' then
        if not removedClothes.bottom then
            removedClothes.bottom = getComponentVariation(ped, 4)
        end
    end

    saveRemovedClothes()
end

local function restoreRemovedClothes()
    local ped = PlayerPedId()

    if not DoesEntityExist(ped) then
        return false
    end

    loadRemovedClothes()

    if not removedClothes.top and not removedClothes.bottom then
        return false
    end

    if removedClothes.model and GetEntityModel(ped) ~= removedClothes.model then
        removedClothes.model = nil
        removedClothes.top = nil
        removedClothes.bottom = nil

        saveRemovedClothes()

        return false
    end

    local top = removedClothes.top

    if top then
        if top.torso then
            SetPedComponentVariation(ped, 3, top.torso.drawable, top.torso.texture or 0, top.torso.palette or 0)
        end

        if top.undershirt then
            SetPedComponentVariation(ped, 8, top.undershirt.drawable, top.undershirt.texture or 0, top.undershirt.palette or 0)
        end

        if top.top then
            SetPedComponentVariation(ped, 11, top.top.drawable, top.top.texture or 0, top.top.palette or 0)
        end
    end

    if removedClothes.bottom then
        SetPedComponentVariation(ped, 4, removedClothes.bottom.drawable,
            removedClothes.bottom.texture or 0, removedClothes.bottom.palette or 0)
    end

    removedClothes.model = nil
    removedClothes.top = nil
    removedClothes.bottom = nil

    saveRemovedClothes()

    return true
end

RegisterNetEvent('amb_client:restoreRemovedClothes', function()
    if restoreRemovedClothes() then
        Framework.Notify('Previous clothing restored.', 'success')
    else
        Framework.Notify('No removed clothing snapshot found.', 'error')
    end
end)

exports('RestoreRemovedClothes', function()
    return restoreRemovedClothes()
end)

--[[
    /dress            - put your own clothes back on
    /dress [serverId] - dress another patient (medic only, checked server side)

    Clothes were only being restored automatically on revive, so a patient who
    was undressed for treatment but never revived stayed undressed for the rest
    of the session. This gives both sides a manual way back.
]]
RegisterCommand('dress', function(source, args)
    local targetId = tonumber(args[1])

    if targetId and targetId > 0 then
        TriggerServerEvent('amb_server:restoreClothes', targetId)

        return
    end

    if restoreRemovedClothes() then
        Framework.Notify(_L('clothing_restored'), 'success')
    else
        Framework.Notify(_L('clothing_nothing_to_restore'), 'error')
    end
end, false)

RegisterCommand('undress', function()
    TriggerServerEvent('amb_server:removeClothes', GetPlayerServerId(PlayerId()), 'top')
end, false)

local function getDeathTypeFromWeapon(weaponHash)
    if weaponHash == UNARMED_WEAPON then
        return 'unconscious'
    end

    return 'dead'
end

local function isDownedByHealth(ped, forced)
    if Config.DisableDeathSystem == true then
        return false
    end

    local threshold = tonumber(Config.Health and Config.Health.DownedThreshold) or 0
    local health = GetEntityHealth(ped)
    local isForced = forced == true or forced == 1

    if threshold <= 0 then
        return isForced or IsPedDeadOrDying(ped, true) or health <= 100
    end

    return isForced or threshold >= health
end

local function setKnockoutFor(duration)
    local ms = tonumber(duration) or 0

    knockoutTimer = GetGameTimer() + math.max(0, ms)
    isKnockedOut = ms > 0
end

local function isKnockoutActive()
    if isKnockedOut and GetGameTimer() >= knockoutTimer then
        isKnockedOut = false
    end

    return isKnockedOut
end

local function clearKnockoutDamage(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    if not isKnockoutActive() then
        return
    end

    if injuries.bleeding and injuries.bleeding > 0 then
        injuries.bleeding = 0
    end

    local health = GetEntityHealth(ped)

    if health and health < 140 then
        SetEntityHealth(ped, 200)
    end
end

local VEHICLE_DAMAGE_HASHES = {
    [-1553120962] = true,
    [133987706] = true,
    [341774354] = true,
    [-868994466] = true,
    [148160082] = true
}

local function getDamageContext(ped, weaponHash, attacker)
    local causeOfDeath = GetPedCauseOfDeath(ped)
    local isFall = weaponHash == -1438083414 or causeOfDeath == -1438083414
    local isVehicleImpact = VEHICLE_DAMAGE_HASHES[weaponHash] == true or VEHICLE_DAMAGE_HASHES[causeOfDeath] == true

    if attacker and attacker ~= 0 and DoesEntityExist(attacker) and IsEntityAVehicle(attacker) then
        isVehicleImpact = true
    end

    return isFall, isVehicleImpact
end

local function tryFracture(part, cause)
    if not part or not injuries[part] then
        return false
    end

    if injuries[part].isFractured then
        return false
    end

    local chance = Config.Health.FractureChance or 80

    if chance < math.random(1, 100) then
        return false
    end

    injuries[part].isFractured = true
    injuries[part].fractureTime = Config.Health.FractureTime or 600

    if Config.Debug then
        print(('^1[FRACTURE] %s (%s)^7'):format(part, tostring(cause or 'impact')))
    end

    return true
end

local BONE_TO_PART = {
    [31086] = 'head',
    [39317] = 'head',
    [12844] = 'head',
    [65068] = 'head',
    [24816] = 'chest',
    [24817] = 'chest',
    [24818] = 'chest',
    [10706] = 'chest',
    [11816] = 'chest',
    [57597] = 'chest',
    [23553] = 'chest',
    [64729] = 'left_arm',
    [45509] = 'left_arm',
    [61163] = 'left_arm',
    [18905] = 'left_arm',
    [26610] = 'left_arm',
    [26611] = 'left_arm',
    [40269] = 'right_arm',
    [28252] = 'right_arm',
    [57005] = 'right_arm',
    [58866] = 'right_arm',
    [58867] = 'right_arm',
    [58271] = 'left_leg',
    [63931] = 'left_leg',
    [63923] = 'left_leg',
    [2108] = 'left_leg',
    [14201] = 'left_leg',
    [51826] = 'right_leg',
    [36864] = 'right_leg',
    [52301] = 'right_leg',
    [20781] = 'right_leg',
    [35502] = 'right_leg'
}

local function getDamagedPart(ped)
    local found, bone = GetPedLastDamageBone(ped)

    if not found or not bone or bone == 0 then
        Wait(0)
        found, bone = GetPedLastDamageBone(ped)
    end

    if found and bone and BONE_TO_PART[bone] then
        return BONE_TO_PART[bone]
    end

    return 'chest'
end

function GetInjuryType()
    if isDowned then
        return 'fatal'
    end

    if injuries.bleeding and injuries.bleeding > 0 then
        return 'severe'
    end

    local totalLevel = 0

    for _, injury in pairs(injuries) do
        if type(injury) == 'table' and injury.level then
            totalLevel = totalLevel + injury.level
        end
    end

    return 'minor'
end

exports('GetInjuryType', GetInjuryType)

CreateThread(function()
    while true do
        Wait(2000)

        local ped = PlayerPedId()

        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local health = clampHealth(GetEntityHealth(ped))

            if health then
                local now = GetGameTimer()

                if not lastAppliedHealth or (now - lastDamageTime) >= 10000 then
                    TriggerServerEvent('amb_server:cacheHealth', health)

                    lastAppliedHealth = health
                    lastDamageTime = now
                end
            end
        end
    end
end)

if Framework.PlayerLoadedEvent then
    RegisterNetEvent(Framework.PlayerLoadedEvent, function()
        blockActionsFor(10000)
        disableHealthRegen()

        if Framework.Type == 'qb' then
            disableAutoSpawn()
        end

        loadSavedHealth()
        requestMedicalStateSync()
    end)
end

local function syncStateFromMetadata(metadata)
    if Framework.Type ~= 'qb' or type(metadata) ~= 'table' then
        return
    end

    local state = Framework.MedicalState.ALIVE

    if metadata.isdead == true then
        state = Framework.MedicalState.DEAD
    elseif metadata.inlaststand == true then
        state = Framework.MedicalState.LASTSTAND
    end

    if state == medicalState then
        return
    end

    local startedAt = tonumber(metadata.plt_medical_started_at) or 0
    local cloudTime = GetCloudTimeAsInt()
    local elapsed = 0

    if startedAt > 0 and cloudTime > 0 then
        elapsed = math.max(0, cloudTime - startedAt)
    end

    TriggerEvent('amb_client:syncMedicalState', state, elapsed)
end

for _, eventName in ipairs(Framework.PlayerDataEvents or {}) do
    RegisterNetEvent(eventName, function(dataType, value)
        if type(dataType) == 'table' then
            syncStateFromMetadata(dataType.metadata)
        elseif dataType == 'metadata' then
            syncStateFromMetadata(value)
        elseif dataType == 'all' and type(value) == 'table' then
            syncStateFromMetadata(value.metadata)
        end
    end)
end

AddEventHandler('playerSpawned', function()
    blockActionsFor(10000)
    disableHealthRegen()
    applySavedHealth()
end)

CreateThread(function()
    while true do
        disableHealthRegen()
        Wait(5000)
    end
end)

local DEATH_DISABLED_CONTROLS = { 24, 25, 30, 31, 32, 33, 34, 35, 21, 22, 23, 38, 44, 73, 177 }
local DEATH_ENABLED_CONTROLS = { 1, 2, 245, 246, 47 }

local function freezePlayerOnDeath()
    local playerId = PlayerId()
    local ped = PlayerPedId()

    if not IsPedInAnyVehicle(ped, false) then
        SetEntityVelocity(ped, 0.0, 0.0, 0.0)
    end

    SetPlayerControl(playerId, true, 0)

    CreateThread(function()
        local ticks = 0

        while isDowned and ticks < 120 do
            for _, control in ipairs(DEATH_DISABLED_CONTROLS) do
                DisableControlAction(0, control, true)
            end

            for _, control in ipairs(DEATH_ENABLED_CONTROLS) do
                EnableControlAction(0, control, true)
            end

            SetPlayerControl(PlayerId(), true, 0)

            ticks = ticks + 1

            Wait(0)
        end
    end)
end

local function getPedSeat(ped, vehicle)
    if not DoesEntityExist(vehicle) then
        return -1
    end

    local seats = GetVehicleModelNumberOfSeats(GetEntityModel(vehicle))

    for seat = -1, seats - 2 do
        if GetPedInVehicleSeat(vehicle, seat) == ped then
            return seat
        end
    end

    return -1
end

local function resurrectPlayer(ped)
    if GetEntityHealth(ped) <= 0 or IsPedDeadOrDying(ped, true) then
        local coords = GetEntityCoords(ped)
        local heading = GetEntityHeading(ped)
        local inVehicle = IsPedInAnyVehicle(ped, false)
        local vehicle = inVehicle and GetVehiclePedIsIn(ped, false) or 0
        local seat = inVehicle and getPedSeat(ped, vehicle) or -1
        local isQb = Framework and Framework.Type == 'qb'

        if isQb then
            NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z + 0.5, heading, true, false)
        else
            NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, heading, true, false)
        end

        Wait(0)

        ped = PlayerPedId()

        if inVehicle and DoesEntityExist(vehicle) then
            SetPedIntoVehicle(ped, vehicle, seat)
        elseif isQb then
            SetEntityHeading(ped, heading)
        else
            SetEntityCoordsNoOffset(ped, coords.x, coords.y, coords.z, false, false, false)
            SetEntityHeading(ped, heading)
        end

        SetEntityVisible(ped, true, false)
        ResetEntityAlpha(ped)

        if not inVehicle then
            SetPedCanRagdoll(ped, true)
            SetPedToRagdoll(ped, 2000, 2000, 0, false, false, false)
        end
    elseif not IsPedInAnyVehicle(ped, false) then
        SetPedCanRagdoll(ped, true)
        SetPedToRagdoll(ped, 2000, 2000, 0, false, false, false)
    end

    return ped
end

local function waitForRagdollToSettle()
    Wait(1000)

    local ticks = 0
    local ped = PlayerPedId()

    while ticks < 250 do
        if GetEntitySpeed(ped) <= 0.5 and not IsPedRagdoll(ped) then
            break
        end

        Wait(10)

        ticks = ticks + 1
        ped = PlayerPedId()
    end
end

local function isQbFramework()
    return Framework and Framework.Type == 'qb'
end

--[[
    Health a downed player is pinned at.

    This used to be 100 on ESX, which is *exactly* GTA's player death
    threshold. The ped was therefore permanently on the dying boundary: the game
    knocked it down, resurrectPlayer() got it back up, the health was forced to
    100 again and it fell over once more - the get-up / fall-down loop.

    The value has to sit above 100 (so the engine stops treating the ped as
    dying) and below Config.Health.DownedThreshold (so isDownedByHealth() still
    reports the player as down). 110 satisfies both with the default 125
    threshold.
]]
local function getDownedHealth()
    local configured = tonumber(Config.Health and Config.Health.DownedHealth)

    if configured and configured > 100 then
        local threshold = tonumber(Config.Health and Config.Health.DownedThreshold) or 0

        if threshold > 100 and configured >= threshold then
            return threshold - 1
        end

        return math.floor(configured)
    end

    return isQbFramework() and 200 or 110
end

local function setDownedHealth(ped)
    ped = ped or PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    SetEntityHealth(ped, getDownedHealth())
end

local function enforceDownedHealth(ped)
    ped = ped or PlayerPedId()

    local target = getDownedHealth()

    if GetEntityHealth(ped) ~= target then
        SetEntityHealth(ped, target)
    end
end

local function applyDownedProofs(ped)
    proofsApplied = true

    -- Keep the downed player alive with invincibility only. The full
    -- SetEntityProofs block was removed on purpose: it swallows damage events
    -- completely (bullets would never register a hit), which made the mercy /
    -- finish system unable to detect the finishing shot. With plain
    -- invincibility the damage is zeroed but CEventNetworkEntityDamage still
    -- fires, so head shots / any damage while downed can finish the player.
    SetEntityInvincible(ped, true)
end

local function clearDownedProofs(ped)
    if not proofsApplied then
        return
    end

    proofsApplied = false

    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)
    SetPedCanRagdoll(ped, true)
    SetPedCanRagdollFromPlayerImpact(ped, true)
end

exports('IsPlayerDowned', function()
    if Framework.HasAuthoritativeMedicalState() then
        return medicalState == Framework.MedicalState.LASTSTAND
    end

    return isDowned == true
end)

local function isDeathScreenActive()
    local active = false

    pcall(function()
        active = exports.plt_ambulance_job:IsDeathScreenActive() == true
    end)

    return active
end

--[[
    Crawl phase.

    When a player goes down they stay conscious and able to crawl for
    Config.Health.CrawlTime milliseconds before they pass out, fall, and the
    death screen + automatic EMS request kick in. While crawling the lying-down
    enforcement below is suspended so the player can actually move.
]]
local isCrawling = false
local crawlUsedThisDown = false
local crawlEndsAt = 0
local isCarried = false
local carriedBySrc = 0

-- Players who were mercy-killed ("finished") while downed. Synced from the
-- server; a finished player cannot be revived, only body-bagged.
local finishedPlayers = {}

exports('IsPlayerFinished', function(src)
    return finishedPlayers[tonumber(src) or 0] == true
end)

local function endCrawlVisuals()
    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    SetPedStealthMovement(ped, false, '')
    ResetPedMovementClipset(ped, 0)
end

local function tryStartCrawl()
    local crawlTime = tonumber(Config.Health and Config.Health.CrawlTime) or 0

    if crawlTime <= 0 or Framework.HasAuthoritativeMedicalState() then
        return false
    end

    if isCrawling or crawlUsedThisDown then
        return false
    end

    isCrawling = true
    crawlUsedThisDown = true
    crawlEndsAt = GetGameTimer() + crawlTime

    local ped = PlayerPedId()

    -- a truly dead ped cannot move, so bring it back to the downed health
    -- first; otherwise the "crawl" would just be a corpse on the floor.
    if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
        ped = resurrectPlayer(ped)
    end

    SetPedCanRagdoll(ped, false)
    SetPedCanRagdollFromPlayerImpact(ped, false)

    RequestAnimSet('move_m@injured')

    local waited = 0
    while not HasAnimSetLoaded('move_m@injured') and waited < 1000 do
        Wait(50)
        waited = waited + 50
    end

    SetPedMovementClipset(ped, 'move_m@injured', 0.45)
    SetPedStealthMovement(ped, true, '')

    Framework.Notify(_L('crawl_wounded', {
        seconds = math.floor(crawlTime / 1000)
    }), 'warning')

    return true
end

exports('IsCrawling', function()
    return isCrawling == true
end)

exports('IsCarried', function()
    return isCarried == true
end)

-- Fired (via the server) on the patient while somebody carries them. The
-- patient's own downed enforcement must stand down, otherwise it keeps pinning
-- velocity and replaying the lying anim every tick and the carrier freezes.
RegisterNetEvent('amb_client:setCarried', function(state, carrierSrc)
    isCarried = state == true

    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    if isCarried then
        carriedBySrc = tonumber(carrierSrc) or 0

        SetPedCanRagdoll(ped, false)
        SetPedCanRagdollFromPlayerImpact(ped, false)
        ClearPedTasksImmediately(ped)

        RequestAnimDict('nm')

        local waited = 0
        while not HasAnimDictLoaded('nm') and waited < 1000 do
            Wait(50)
            waited = waited + 50
        end

        TaskPlayAnim(ped, 'nm', 'firemans_carry', 8.0, -8.0, -1, 33, 0, false, false, false)

        -- Attach OUR OWN ped to the carrier. We own this ped, so the self-attach
        -- is authoritative and syncs cleanly; attaching a remote ped from the
        -- carrier (the old way) is what froze both players.
        local function tryAttach()
            local index = GetPlayerFromServerId(carriedBySrc)

            if index ~= -1 and NetworkIsPlayerActive(index) then
                local carrier = GetPlayerPed(index)

                if carrier and carrier ~= 0 and DoesEntityExist(carrier) then
                    local bone = GetEntityBoneIndexByName(carrier, 'SKEL_Spine_Root')

                    if bone == -1 then
                        bone = 0
                    end

                    AttachEntityToEntity(ped, carrier, bone, 0.27, 0.15, 0.63,
                        0.0, 0.0, 0.0, false, true, false, false, 0, true)

                    return true
                end
            end

            return false
        end

        if not tryAttach() then
            CreateThread(function()
                local tries = 0

                while isCarried and carriedBySrc > 0 and tries < 20 do
                    if tryAttach() then
                        return
                    end

                    tries = tries + 1
                    Wait(250)
                end
            end)
        end
    else
        carriedBySrc = 0

        DetachEntity(ped, true, true)
        ClearPedTasks(ped)
        SetPedCanRagdoll(ped, true)
        SetPedCanRagdollFromPlayerImpact(ped, true)
    end
end)

local function shouldEnforceDownedState()
    -- The death system is removed: no downed pose is ever enforced.
    if Config.DisableDeathSystem == true then
        return false
    end

    if isInLastStand or isKnockoutActive() then
        return false
    end

    if isCrawling then
        return false
    end

    if isCarried then
        return false
    end

    return isDowned or isDeathScreenActive()
end

local DOWNED_DISABLED_CONTROLS = {
    21, 22, 23, 24, 25, 30, 31, 32, 33, 34, 35, 36, 37, 38, 44, 45, 55, 73, 75,
    140, 141, 142, 143, 177, 257, 263, 264, 322
}

local function disableDownedControls()
    for index = 1, #DOWNED_DISABLED_CONTROLS do
        DisableControlAction(0, DOWNED_DISABLED_CONTROLS[index], true)
    end
end

local function enterDownedState()
    if isDeathScreenActive() and not isInLastStand and not isKnockoutActive() then
        return
    end

    if isDowned then
        return
    end

    isDowned = true

    knockoutTimer = 0

    applyDeadRestrictions(true)

    local ped = PlayerPedId()

    if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
        ped = resurrectPlayer(ped)
    end

    setDownedHealth(ped)
    applyDownedProofs(ped)

    pushMedicalState(Framework.MedicalState.LASTSTAND)

    tryStartCrawl()
end

local function enforceDownedPose(ped, now)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    if isBeingTreated then
        return
    end

    if isCarried then
        return
    end

    enforceDownedHealth(ped)
    applyDownedProofs(ped)

    if IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 0 then
        ped = resurrectPlayer(ped)
        setDownedHealth(ped)
        applyDownedProofs(ped)
    end

    if IsPedInAnyVehicle(ped, false) then
        if not HasAnimDictLoaded(SIT_DICT) then
            Framework.RequestAnimDict(SIT_DICT)
        end
    else
        if not HasAnimDictLoaded(DEAD_DICT) then
            Framework.RequestAnimDict(DEAD_DICT)
        end
    end

    if now < knockoutTimer then
        SetPedCanRagdoll(ped, true)

        if not IsPedInAnyVehicle(ped, false) and not IsPedRagdoll(ped) then
            SetPedToRagdoll(ped, 1000, 1000, 0, false, false, false)
        end

        return
    end

    if not IsPlayerControlOn(PlayerId()) then
        SetPlayerControl(PlayerId(), true, 0)
    end

    SetPedCanRagdoll(ped, false)
    SetPedCanRagdollFromPlayerImpact(ped, false)
    SetPedCanPlayAmbientAnims(ped, false)
    SetPedCanPlayAmbientBaseAnims(ped, false)
    SetEntityVelocity(ped, 0.0, 0.0, 0.0)
    SetBlockingOfNonTemporaryEvents(ped, true)

    if IsPedInAnyVehicle(ped, false) then
        if not IsEntityPlayingAnim(ped, SIT_DICT, SIT_ANIM, 3) then
            ClearPedTasksImmediately(ped)
            TaskPlayAnim(ped, SIT_DICT, SIT_ANIM, 1.0, 1.0, -1, 1, 0.0, false, false, false)
        end
    else
        local playingDeadAnim = IsEntityPlayingAnim(ped, DEAD_DICT, DEAD_ANIM, 3)

        if IsPedGettingUp(ped) or IsPedRagdoll(ped) or not playingDeadAnim then
            ClearPedTasksImmediately(ped)
            TaskPlayAnim(ped, DEAD_DICT, DEAD_ANIM, 8.0, 8.0, -1, 1, 0.0, false, false, false)
        end
    end

    if not isBleedingOut then
        isBleedingOut = true

        SetPedConfigFlag(ped, 184, true)
        SetPedConfigFlag(ped, 241, true)
    end
end

exports('EnforceDownedState', function()
    if not shouldEnforceDownedState() then
        return false
    end

    enterDownedState()

    enforceDownedPose(PlayerPedId(), GetGameTimer())

    if not useBuiltInDeathscreen then
        disableDownedControls()
    end

    return true
end)

CreateThread(function()
    while true do
        if shouldEnforceDownedState() then
            enterDownedState()

            if not deadRestrictionsActive then
                applyDeadRestrictions(true)
            end

            enforceDownedPose(PlayerPedId(), GetGameTimer())

            if not useBuiltInDeathscreen then
                disableDownedControls()

                EnableControlAction(0, 1, true)
                EnableControlAction(0, 2, true)
                EnableControlAction(0, 245, true)
                EnableControlAction(0, 246, true)
                EnableControlAction(0, 47, true)
            end

            Wait(0)
        else
            Wait(250)
        end
    end
end)

local DOWNED_LOOP_DISABLED = {
    24, 25, 30, 31, 32, 33, 34, 35, 21, 22, 23, 38, 44, 75, 59, 60, 61, 62, 63,
    64, 71, 72, 76, 85, 86, 140, 141, 142, 257
}

CreateThread(function()
    local nextInvincibleRefresh = 0
    local nextAnimRefresh = 0

    while true do
        local sleep = 1000
        local ped = PlayerPedId()
        local now = GetGameTimer()

        clearKnockoutDamage(ped)

        if not isDowned then
            if proofsApplied and not shouldEnforceDownedState() then
                clearDownedProofs(ped)
            end

            if now - fractureTickAt >= 1000 then
                fractureTickAt = now

                for part, injury in pairs(injuries) do
                    if type(injury) == 'table' and injury.isFractured then
                        if injury.fractureTime > 0 then
                            injury.fractureTime = injury.fractureTime - 1
                        else
                            injury.isFractured = false

                            TriggerEvent('amb_client:Notify', _L('fracture_healed', {
                                part = part:gsub('_', ' ')
                            }), 'success')
                        end
                    end
                end
            end

            local legsFractured = injuries.left_leg.isFractured or injuries.right_leg.isFractured
            local needsLimp = isUsingMedication
                or injuries.left_leg.level > 0
                or injuries.right_leg.level > 0
                or legsFractured

            if needsLimp then
                sleep = 0

                DisableControlAction(0, 21, true)

                if not isReviving then
                    local clipset = getActiveAidClipset()

                    Framework.RequestAnimSet(clipset)
                    SetPedMovementClipset(ped, clipset, 1.0)

                    isReviving = true
                end

                if isUsingMedication and walkingAidItem == 'plt_crutches' then
                    if not crutchProp or not DoesEntityExist(crutchProp) then
                        attachCrutchProp(ped)
                    end
                end
            elseif isReviving then
                ResetPedMovementClipset(ped, 0)
                isReviving = false
            end

            local armsFractured = injuries.left_arm.isFractured or injuries.right_arm.isFractured

            if armsFractured then
                sleep = 0
                DisableControlAction(0, 21, true)
            end

            if injuries.left_arm.level > 0 or injuries.right_arm.level > 0 or armsFractured then
                if IsControlPressed(0, 25) then
                    sleep = 0

                    local shake = (injuries.left_arm.level + injuries.right_arm.level) * 0.5

                    if armsFractured then
                        shake = shake + 1.5
                    end

                    ShakeGameplayCam('HAND_SHAKE', shake)
                end
            end

            if injuries.head.level > 0 then
                sleep = 0

                if Config.EnableBlurEffect ~= false and not isTreating then
                    TriggerScreenblurFadeIn(1000.0)
                    isTreating = true
                end
            elseif isTreating then
                TriggerScreenblurFadeOut(1000.0)
                isTreating = false
            end

            if injuries.bleeding > 0 then
                sleep = Config.Health.BleedInterval or 2000

                local damage = (Config.Health.BleedRate or 1) * injuries.bleeding

                SetEntityHealth(ped, GetEntityHealth(ped) - damage)

                if injuries.bleeding > (Config.Health.BleedDecalMin or 2) then
                    local coords = GetEntityCoords(ped)

                    AddDecal(1010, coords.x, coords.y, coords.z - 1.0,
                        0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                        0.2, 0.2, 255, 0, 0, 255, 60.0, false, false, false)
                end
            end
        else
            sleep = useBuiltInDeathscreen and 40 or 0

            if crutchProp then
                removeCrutchProp()
            end

            if not deadRestrictionsActive then
                applyDeadRestrictions(true)
            end

            if nextInvincibleRefresh <= now then
                enforceDownedHealth(ped)
                applyDownedProofs(ped)

                nextInvincibleRefresh = now + 500
            end

            if nextAnimRefresh <= now then
                if IsPedInAnyVehicle(ped, false) then
                    if not HasAnimDictLoaded(SIT_DICT) then
                        Framework.RequestAnimDict(SIT_DICT)
                    end
                elseif not HasAnimDictLoaded(DEAD_DICT) then
                    Framework.RequestAnimDict(DEAD_DICT)
                end

                nextAnimRefresh = now + 1500
            end

            if not useBuiltInDeathscreen then
                for _, control in ipairs(DOWNED_LOOP_DISABLED) do
                    DisableControlAction(0, control, true)
                end

                if getDeadRestrictions().DisableInventory then
                    DisableControlAction(0, 37, true)
                end

                EnableControlAction(0, 1, true)
                EnableControlAction(0, 2, true)
                EnableControlAction(0, 3, true)
                EnableControlAction(0, 4, true)
                EnableControlAction(0, 245, true)
                EnableControlAction(0, 246, true)
                EnableControlAction(0, 47, true)

                if not IsPlayerControlOn(PlayerId()) then
                    SetPlayerControl(PlayerId(), true, 0)
                end

                if IsPedInAnyVehicle(ped, false) then
                    local vehicle = GetVehiclePedIsIn(ped, false)

                    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
                        SetVehicleUndriveable(vehicle, true)
                        SetVehicleEngineOn(vehicle, false, true, true)
                        SetVehicleForwardSpeed(vehicle, 0.0)
                        SetEntityVelocity(vehicle, 0.0, 0.0, 0.0)
                    end
                end
            end
        end

        Wait(sleep)
    end
end)

local BULLET_WEAPON_GROUPS = {
    [416676503] = true,
    [-95745345] = true,
    [860033945] = true,
    [970310034] = true
}

local LIMB_PARTS = { 'left_leg', 'right_leg', 'left_arm', 'right_arm' }

local function forceBaselineTrauma()
    local totalLevel = 0

    for _, injury in pairs(injuries) do
        if type(injury) == 'table' and injury.level then
            totalLevel = totalLevel + injury.level
        end
    end

    if totalLevel == 0 then
        injuries.chest.level = 2

        if Config.Debug then
            print('^3[VICTIM DEBUG] No injuries found upon death. Forcing baseline trauma.^7')
        end
    end
end

local function applyDownedFracture(isFall, isVehicle)
    if not isFall and not isVehicle then
        return
    end

    local part = LIMB_PARTS[math.random(1, #LIMB_PARTS)]

    if isFall then
        if math.random(1, 100) > 20 then
            part = math.random(1, 2) == 1 and 'left_leg' or 'right_leg'
        else
            part = math.random(1, 2) == 1 and 'left_arm' or 'right_arm'
        end
    end

    tryFracture(part, isFall and 'downed_fall' or 'downed_vehicle')
end

local function playDownedAnimation(ped)
    if IsPedInAnyVehicle(ped, false) then
        if not IsEntityPlayingAnim(ped, SIT_DICT, SIT_ANIM, 3) then
            ClearPedTasksImmediately(ped)
            TaskPlayAnim(ped, SIT_DICT, SIT_ANIM, 1.0, 1.0, -1, 1, 0.0, false, false, false)
        end
    else
        if not IsEntityPlayingAnim(ped, DEAD_DICT, DEAD_ANIM, 3) then
            ClearPedTasksImmediately(ped)
            TaskPlayAnim(ped, DEAD_DICT, DEAD_ANIM, 1.0, 1.0, -1, 1, 0.0, false, false, false)
        end
    end
end

AddEventHandler('gameEventTriggered', function(eventName, args)
    if eventName ~= 'CEventNetworkEntityDamage' then
        return
    end

    local victim = args[1]
    local isFatal = args[4] == true
    local attacker = args[2]
    local weaponHash = args[7]

    if victim ~= PlayerPedId() then
        return
    end

    if isKnockoutActive() or areActionsBlocked() then
        return
    end

    -- The death system is removed: this resource does not react to damage at
    -- all (no injuries, no downed state, no death handling).
    if Config.DisableDeathSystem == true then
        return
    end

    if isDowned then
        setDownedHealth(victim)
        applyDownedProofs(victim)

        if GetGameTimer() >= knockoutTimer and not isBeingTreated then
            SetEntityVelocity(victim, 0.0, 0.0, 0.0)
            playDownedAnimation(victim)
        end

        return
    end

    local part = getDamagedPart(victim)

    if part then
        injuries[part].level = math.min(Config.Health.MaxInjuryLevel or 5, injuries[part].level + 1)

        local isFall, isVehicle = getDamageContext(victim, weaponHash, attacker)

        if isFall or isVehicle then
            if isFall then
                local legPart = math.random(1, 2) == 1 and 'left_leg' or 'right_leg'

                if not tryFracture(legPart, 'fall') then
                    tryFracture(part, 'fall_fallback')
                end
            else
                tryFracture(part, 'vehicle')
            end
        end

        local isBulletWound = BULLET_WEAPON_GROUPS[GetWeapontypeGroup(weaponHash)] == true

        if isBulletWound then
            injuries[part].bullet = true
        end

        local bleedChance = isBulletWound
            and (Config.Health.BulletBleedChance or 90)
            or (Config.Health.BleedChance or 40)

        if bleedChance > math.random(1, 100) then
            injuries.bleeding = injuries.bleeding + 1
        end

        syncInjuries()
    end

    if not isDownedByHealth(victim, isFatal) then
        return
    end

    if isDowned then
        return
    end

    isDowned = true

    pushMedicalState(Framework.MedicalState.LASTSTAND)

    fractureTimer = fractureTimer + 1

    local sequence = fractureTimer

    knockoutTimer = GetGameTimer() + 1000

    freezePlayerOnDeath()

    if not IsPedInAnyVehicle(victim, false) then
        waitForRagdollToSettle()

        if not isDowned or fractureTimer ~= sequence or isKnockoutActive() then
            return
        end
    end

    resurrectPlayer(victim)

    if not isDowned or fractureTimer ~= sequence or isKnockoutActive() then
        return
    end

    local isFall, isVehicle = getDamageContext(victim, weaponHash, attacker)

    applyDownedFracture(isFall, isVehicle)

    setDownedHealth(victim)
    applyDownedProofs(victim)

    forceBaselineTrauma()

    if Config.Debug then
        print('^1[DEBUG] Player death detected, triggering death screen...^7')
    end
end)

CreateThread(function()
    while true do
        Wait(250)

        if Config.DisableDeathSystem == true then
            -- The death system is removed: nothing to detect here.
        elseif not isDowned and not isKnockoutActive() and not areActionsBlocked() then
            local ped = PlayerPedId()

            if DoesEntityExist(ped) and (IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 100) then
                isDowned = true
                pushMedicalState(Framework.MedicalState.LASTSTAND)

                fractureTimer = fractureTimer + 1

                local sequence = fractureTimer

                knockoutTimer = GetGameTimer() + 1000

                freezePlayerOnDeath()

                local settled = true

                if not IsPedInAnyVehicle(ped, false) then
                    waitForRagdollToSettle()

                    settled = isDowned and fractureTimer == sequence and not isKnockoutActive()
                end

                if settled then
                    ped = resurrectPlayer(ped)

                    if isDowned and fractureTimer == sequence and not isKnockoutActive() then
                        setDownedHealth(ped)
                        applyDownedProofs(ped)

                        forceBaselineTrauma()

                        if Config.Debug then
                            print('^3[HEALTH FALLBACK]^7 Forced downed state from fallback detector.')
                        end

                        local causeOfDeath = GetPedCauseOfDeath(ped)
                        local isFall, isVehicle = getDamageContext(ped, causeOfDeath, 0)

                        if isFall or isVehicle then
                            local part = LIMB_PARTS[math.random(1, #LIMB_PARTS)]

                            if isFall then
                                part = math.random(1, 2) == 1 and 'left_leg' or 'right_leg'
                            end

                            tryFracture(part, isFall and 'fallback_fall' or 'fallback_vehicle')
                        end
                    end
                end
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(1000)

        if isKnockedOut and GetGameTimer() > (knockoutTimer + 2000) then
            setKnockoutFor(0)
        end

        if isInLastStand and not isDowned and not isKnockoutActive() then
            isInLastStand = false
        end
    end
end)

local function revivePlayer()
    if isDeathScreenOpen then
        return
    end

    -- Finished players cannot be revived, not even client side.
    if finishedPlayers[GetPlayerServerId(PlayerId())] then
        return
    end

    local ped = PlayerPedId()
    local playerId = PlayerId()
    local wasDowned = isDowned or isDeathScreenActive()

    if not wasDowned and GetEntityHealth(ped) >= 200 then
        local isHealthy = true

        for _, injury in pairs(injuries) do
            if type(injury) == 'table' and injury.level > 0 then
                isHealthy = false
                break
            end
        end

        if isHealthy and not isPatientBandaged then
            return
        end
    end

    isDeathScreenOpen = true
    lastBleedTick = GetGameTimer()
    isDowned = false

    DisablePlayerFiring(PlayerId(), false)

    applyDeadRestrictions(false)

    fractureTimer = fractureTimer + 1
    isBleedingOut = false
    knockoutTimer = 0

    setKnockoutFor(8000)

    isBeingTreated = false

    if not Framework.HasAuthoritativeMedicalState() then
        pushMedicalState(Framework.MedicalState.ALIVE)
    end

    TriggerEvent('amb_client:onPlayerRevive')

    SendNUIMessage({
        action = 'amb_toggleDeathScreen',
        show = false
    })

    if useBandageOverlay() then
        SetPedComponentVariation(ped, 7, 0, 0, 0)
    end

    resetInjuries()

    injuries.bleeding = 0

    if isTreating then
        TriggerScreenblurFadeOut(500.0)
        isTreating = false
    end

    if isReviving then
        ResetPedMovementClipset(ped, 0)
        isReviving = false
    end

    ClearPedBloodDamage(ped)
    ClearPedLastDamageBone(ped)
    ClearEntityLastDamageEntity(ped)

    local inVehicle = IsPedInAnyVehicle(ped, false)
    local vehicle = inVehicle and GetVehiclePedIsIn(ped, false) or 0

    local needsResurrect = GetEntityHealth(ped) <= 5 or IsPedDeadOrDying(ped, 1)

    if isQbFramework() then
        if not needsResurrect then
            needsResurrect = wasDowned
        end
    elseif not needsResurrect then
        needsResurrect = IsEntityPlayingAnim(ped, DEAD_DICT, DEAD_ANIM, 3)
            or IsEntityPlayingAnim(ped, 'misslamar1dead_body', 'dead_idle', 3)
    end

    if needsResurrect then
        local coords = GetEntityCoords(ped)

        NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, GetEntityHeading(ped), true, false)

        Wait(100)

        ped = PlayerPedId()

        SetEntityVisible(ped, true, false)
        ResetEntityAlpha(ped)
    end

    restoreRemovedClothes()

    DetachEntity(ped, true, true)
    SetEntityMaxHealth(ped, 200)
    SetEntityHealth(ped, 200)
    proofsApplied = false
    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)
    SetPedCanRagdoll(ped, true)
    SetPedCanRagdollFromPlayerImpact(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, false)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
    SetPlayerControl(playerId, true, 0)
    SetPedToRagdoll(ped, 0, 0, 0, false, false, false)

    if not inVehicle then
        ClearPedTasksImmediately(ped)

        local coords = GetEntityCoords(ped)

        SetEntityCoords(ped, coords.x, coords.y, coords.z + 0.1, false, false, false, false)
    else
        StopAnimTask(ped, SIT_DICT, SIT_ANIM, 1.0)
        StopAnimTask(ped, DEAD_DICT, DEAD_ANIM, 1.0)
        StopAnimTask(ped, 'misslamar1dead_body', 'dead_idle', 1.0)
        ClearPedSecondaryTask(ped)

        if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
            SetVehicleUndriveable(vehicle, false)
            SetVehicleEngineOn(vehicle, true, true, false)
        end
    end

    EnableAllControlActions(0)

    if Framework.Type == 'esx' and wasDowned then
        TriggerEvent('esx:onPlayerSpawn')
        TriggerServerEvent('esx:onPlayerSpawn')
        TriggerEvent('playerSpawned')
    end

    if isQbFramework() then
        TriggerServerEvent('hud:server:RelieveStress', 100)
    end

    SetPedConfigFlag(ped, 184, false)
    SetPedConfigFlag(ped, 241, false)

    CreateThread(function()
        local ticks = 0

        while ticks < 120 do
            Wait(10)

            if isDowned then
                break
            end

            local currentPed = PlayerPedId()

            clearKnockoutDamage(currentPed)

            if GetEntityHealth(currentPed) < 120 then
                SetEntityHealth(currentPed, 200)
            end

            EnableAllControlActions(0)
            SetPlayerControl(PlayerId(), true, 0)
            FreezeEntityPosition(currentPed, false)
            SetEntityInvincible(currentPed, false)

            ticks = ticks + 1
        end

        setKnockoutFor(0)

        isDeathScreenOpen = false
    end)
end

exports('RevivePlayer', function()
    if Framework.HasAuthoritativeMedicalState() then
        pushMedicalState(Framework.MedicalState.ALIVE)
        return
    end

    revivePlayer()
end)

RegisterNetEvent('hospital:client:Revive', function()
    exports.plt_ambulance_job:RevivePlayer()
end)

RegisterNetEvent('amb_client:RevivePlayer', function()
    exports.plt_ambulance_job:RevivePlayer()
end)

local function healInjuries()
    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    if isDowned or IsPedDeadOrDying(ped, true) or GetEntityHealth(ped) <= 110 then
        exports.plt_ambulance_job:RevivePlayer()

        TriggerServerEvent('amb_server:cacheHealth', GetEntityHealth(PlayerPedId()))

        syncInjuries()

        Framework.Notify(_L('healed'), 'success')

        return
    end

    isDowned = false

    applyDeadRestrictions(false)

    fractureTimer = fractureTimer + 1
    isBleedingOut = false
    knockoutTimer = 0
    isBeingTreated = false

    resetInjuries()

    DetachEntity(ped, true, true)
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    proofsApplied = false
    SetEntityInvincible(ped, false)
    SetEntityProofs(ped, false, false, false, false, false, false, false, false)
    SetBlockingOfNonTemporaryEvents(ped, false)
    SetPlayerControl(PlayerId(), true, 0)
    EnableAllControlActions(0)
    FreezeEntityPosition(ped, false)
    ClearPedBloodDamage(ped)
    ClearPedLastDamageBone(ped)
    ClearEntityLastDamageEntity(ped)

    restoreRemovedClothes()

    if IsPedInAnyVehicle(ped, false) then
        local vehicle = GetVehiclePedIsIn(ped, false)

        if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
            SetVehicleUndriveable(vehicle, false)
            SetVehicleEngineOn(vehicle, true, true, false)
        end
    end

    if isTreating then
        TriggerScreenblurFadeOut(500.0)
        isTreating = false
    end

    if isReviving then
        ResetPedMovementClipset(ped, 0)
        isReviving = false
    end

    pushMedicalState(Framework.MedicalState.ALIVE)

    TriggerServerEvent('amb_server:cacheHealth', GetEntityHealth(ped))

    syncInjuries()

    Framework.Notify(_L('healed'), 'success')
end

RegisterNetEvent('amb_client:HealInjuries', healInjuries)
RegisterNetEvent('hospital:client:HealInjuries', healInjuries)

RegisterNetEvent('amb_client:playWakeUpAnimation', function()
    playGetUpAnimation()
end)

local function setDeathStatus(downed, skipStatePush)
    local ped = PlayerPedId()

    if not downed then
        isDowned = false
        isCrawling = false
        crawlUsedThisDown = false

        endCrawlVisuals()

        applyDeadRestrictions(false)

        fractureTimer = fractureTimer + 1

        if not skipStatePush then
            pushMedicalState(Framework.MedicalState.ALIVE)
        end

        return
    end

    if Config.DisableDeathSystem == true then
        return
    end

    if lastBleedTick > 0 and (GetGameTimer() - lastBleedTick) < 10000 then
        pushMedicalState(Framework.MedicalState.ALIVE)
        return
    end

    if not isInLastStand and not isKnockoutActive() then
        if isQbFramework() or GetEntityHealth(ped) > 150 then
            pushMedicalState(Framework.MedicalState.ALIVE)
            return
        end
    end

    if isDowned then
        return
    end

    isDowned = true

    if not skipStatePush then
        pushMedicalState(Framework.MedicalState.LASTSTAND)
    end

    fractureTimer = fractureTimer + 1

    -- Crawl phase: stay conscious and mobile; defer the freeze / ragdoll until
    -- the player passes out.
    if tryStartCrawl() then
        setDownedHealth(ped)
        applyDownedProofs(ped)

        return
    end

    local sequence = fractureTimer

    knockoutTimer = GetGameTimer() + 1000

    freezePlayerOnDeath()

    if not IsPedInAnyVehicle(ped, false) then
        waitForRagdollToSettle()

        if not isDowned or fractureTimer ~= sequence or isKnockoutActive() then
            return
        end
    end

    ped = resurrectPlayer(ped)

    if not isDowned or fractureTimer ~= sequence or isKnockoutActive() then
        return
    end

    setDownedHealth(ped)
    applyDownedProofs(ped)
end

RegisterNetEvent('hospital:client:SetDeathStatus', function(downed)
    setDeathStatus(downed)
end)

RegisterNetEvent('amb_client:SetDeathStatus', setDeathStatus)

RegisterNetEvent('amb_client:syncMedicalState', function(state, elapsed)
    -- The death system is removed: never touch the medical state, never
    -- resurrect (this would fight the framework's default death handling).
    if Config.DisableDeathSystem == true then
        return
    end

    if not Framework.HasAuthoritativeMedicalState() then
        return
    end

    state = Framework.NormalizeMedicalState(state)

    medicalState = state
    downedSince = math.max(0, tonumber(elapsed) or 0)

    if state == Framework.MedicalState.ALIVE then
        applyDeadRestrictions(false)

        if isDowned or isDeathScreenActive() or IsPedDeadOrDying(PlayerPedId(), true) then
            revivePlayer()
        end

        return
    end

    if not isDowned then
        setDeathStatus(true, true)
    end

    if not isDeathScreenActive() then
        TriggerEvent('amb_client:onPlayerDeath', 'dead', downedSince, state)
    end
end)

RegisterNetEvent('amb_client:KillPlayer', function()
    if isDowned then
        return
    end

    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    isDeathScreenOpen = false

    setKnockoutFor(0)

    isDowned = true
    pushMedicalState(Framework.MedicalState.LASTSTAND)

    fractureTimer = fractureTimer + 1

    local sequence = fractureTimer

    knockoutTimer = GetGameTimer() + 1000

    freezePlayerOnDeath()

    SetEntityHealth(ped, 0)

    if not IsPedInAnyVehicle(ped, false) then
        waitForRagdollToSettle()

        if not isDowned or fractureTimer ~= sequence then
            return
        end
    end

    ped = resurrectPlayer(ped)

    if not isDowned or fractureTimer ~= sequence then
        return
    end

    forceBaselineTrauma()

    injuries.bleeding = math.max(tonumber(injuries.bleeding) or 0, 1)

    setDownedHealth(ped)
    applyDownedProofs(ped)

    TriggerServerEvent('amb_server:cacheHealth', getDownedHealth())

    syncInjuries()
end)

RegisterNetEvent('hospital:client:KillPlayer', function()
    if not isQbFramework() then
        return
    end

    TriggerEvent('amb_client:KillPlayer')
end)

RegisterNetEvent('amb_client:requestInjuryData', function()
    if Config.Debug then
        print('^3[VICTIM DEBUG] Sending Injury Data to EMS...^7')
    end

    syncInjuries()
end)

local MEDICATION_ITEMS = {
    plt_bandage = true,
    plt_painkillers = true,
    plt_painkillers_adv = true,
    plt_antibiotics = true,
    plt_medkit = true,
    iak_wheelchair = true,
    plt_walking_stick = true,
    plt_cane = true,
    plt_crutches = true
}

local XRAY_CLIPBOARD_ITEMS = {
    as_xray_clipboard_01 = true,
    as_xray_clipboard_02 = true,
    as_xray_clipboard_03 = true,
    as_xray_clipboard_04 = true
}

local CLIPBOARD_MODELS = {
    as_xray_clipboard_01 = { 'as_xray_clipboard_01', 'as_xray_clipboard1', 'as_xray_clipboard_1' },
    as_xray_clipboard_02 = { 'as_xray_clipboard_02', 'as_xray_clipboard2', 'as_xray_clipboard_2' },
    as_xray_clipboard_03 = { 'as_xray_clipboard_03', 'as_xray_clipboard3', 'as_xray_clipboard_3' },
    as_xray_clipboard_04 = { 'as_xray_clipboard_04', 'as_xray_clipboard4', 'as_xray_clipboard_4' }
}

local clipboardProp = nil
local clipboardModel = nil
local holdingClipboard = false
local clipboardSession = 0

local DEFAULT_MEDICATION = {
    plt_bandage = { duration = 4000, dict = 'missheistprowlprepb', anim = 'low_reach_loop', label = 'applying_bandage' },
    plt_painkillers = { duration = 3000, dict = 'mp_suicide', anim = 'pill', label = 'taking_medication' },
    plt_painkillers_adv = { duration = 3500, dict = 'mp_suicide', anim = 'pill', label = 'taking_medication' },
    plt_antibiotics = { duration = 3500, dict = 'mp_suicide', anim = 'pill', label = 'taking_medication' },
    plt_medkit = { duration = 5000, dict = 'missheistprowlprepb', anim = 'low_reach_loop', label = 'applying_first_aid' }
}

local function getMedicationConfig(itemName)
    local settings = Config.Health and Config.Health.Medication and Config.Health.Medication[itemName]

    if type(settings) ~= 'table' then
        settings = DEFAULT_MEDICATION[itemName]
    end

    if type(settings) ~= 'table' then
        return nil
    end

    local defaults = DEFAULT_MEDICATION[itemName] or {}

    return {
        duration = tonumber(settings.duration) or defaults.duration or 3000,
        dict = settings.dict or defaults.dict or 'mp_suicide',
        anim = settings.anim or defaults.anim or 'pill',
        label = settings.label or defaults.label or 'taking_medication',
        flag = tonumber(settings.flag) or defaults.flag or 49
    }
end

local function playMedicationAnimation(itemName)
    local settings = getMedicationConfig(itemName)

    if not settings then
        return true
    end

    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false
    end

    if isDowned then
        return false
    end

    return Framework.ProgressBar(_L(settings.label), settings.duration, {
        dict = settings.dict,
        anim = settings.anim,
        flag = settings.flag,
        canCancel = true
    }) == true
end

local function hasTreatableInjuries()
    if injuries.bleeding and injuries.bleeding > 0 then
        return true
    end

    for _, injury in pairs(injuries) do
        if type(injury) == 'table' then
            if (injury.level and injury.level > 0) or injury.bullet or injury.isFractured then
                return true
            end
        end
    end

    return GetEntityHealth(PlayerPedId()) < 200
end

local function canUseMedication(itemName)
    if itemName == 'iak_wheelchair' or itemName == 'plt_walking_stick'
        or itemName == 'plt_cane' or itemName == 'plt_crutches' then
        return true
    end

    if isDowned then
        return false
    end

    return hasTreatableInjuries()
end

local function setWalkingAid(enabled, itemName)
    local ped = PlayerPedId()

    if not ped or ped == 0 then
        return
    end

    isUsingMedication = enabled == true

    if isUsingMedication then
        walkingAidItem = itemName or walkingAidItem or 'plt_walking_stick'

        local clipset = getActiveAidClipset()

        Framework.RequestAnimSet(clipset)
        SetPedMovementClipset(ped, clipset, 1.0)

        attachCrutchProp(ped)

        local label = 'Walking Stick'

        if itemName == 'plt_cane' then
            label = 'Cane'
        elseif itemName == 'plt_crutches' then
            label = 'Crutches'
        end

        Framework.Notify(label .. ' equipped. Limp walk enabled.', 'success')
    else
        walkingAidItem = nil

        removeCrutchProp()
        ResetPedMovementClipset(ped, 0)

        Framework.Notify('Walking aid removed. Normal walk restored.', 'info')
    end
end

local function removeClipboard()
    if clipboardProp and DoesEntityExist(clipboardProp) then
        DetachEntity(clipboardProp, true, true)
        DeleteEntity(clipboardProp)
    end

    clipboardProp = nil

    if clipboardModel then
        SetModelAsNoLongerNeeded(clipboardModel)
    end

    clipboardModel = nil

    local ped = PlayerPedId()

    if ped and ped ~= 0 and DoesEntityExist(ped) then
        ClearPedSecondaryTask(ped)
    end

    holdingClipboard = false
end

local function useXrayClipboard(itemName)
    if not XRAY_CLIPBOARD_ITEMS[itemName] then
        return
    end

    if isDowned then
        Framework.Notify(_L('cannot_use_incapacitated'), 'error')
        return
    end

    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    if holdingClipboard then
        removeClipboard()
    end

    local model = nil

    for _, candidate in ipairs(CLIPBOARD_MODELS[itemName] or { itemName }) do
        local hash = joaat(candidate)

        if IsModelInCdimage(hash) and IsModelValid(hash) then
            Framework.RequestModel(hash)

            if HasModelLoaded(hash) then
                model = hash
                break
            end
        end
    end

    if not model then
        print('^1[plt_ambulance] Clipboard model could not be loaded. Check ytyp/fxmanifest.^7')
        return
    end

    local coords = GetEntityCoords(ped)
    local prop = CreateObject(model, coords.x, coords.y, coords.z + 0.2, true, true, false)

    if not prop or not DoesEntityExist(prop) then
        SetModelAsNoLongerNeeded(model)
        return
    end

    SetEntityCollision(prop, false, false)

    AttachEntityToEntity(prop, ped, GetPedBoneIndex(ped, 36029),
        0.16, 0.08, 0.1, -130.0, -50.0, 0.0,
        true, true, false, true, 1, true)

    Framework.RequestAnimDict('missfam4')
    TaskPlayAnim(ped, 'missfam4', 'base', 8.0, -8.0, -1, 49, 1.0, false, false, false)

    clipboardProp = prop
    clipboardModel = model
    holdingClipboard = true
    clipboardSession = clipboardSession + 1

    local session = clipboardSession

    CreateThread(function()
        while holdingClipboard and session == clipboardSession do
            Wait(0)

            local currentPed = PlayerPedId()

            if not currentPed or currentPed == 0 or not DoesEntityExist(currentPed) or isDowned then
                break
            end

            if not IsEntityPlayingAnim(currentPed, 'missfam4', 'base', 3) then
                TaskPlayAnim(currentPed, 'missfam4', 'base', 8.0, -8.0, -1, 49, 1.0, false, false, false)
            end

            if IsControlJustPressed(0, 73) then
                break
            end
        end

        if session == clipboardSession then
            removeClipboard()
        end
    end)
end

local function notifyCannotTreat(itemName)
    if itemName == 'plt_bandage' then
        Framework.Notify(_L('not_bleeding_now'), 'info')
    else
        Framework.Notify(_L('no_injuries_to_treat'), 'info')
    end
end

exports('plt_use_medication', function(item, slot)
    local itemName = item and item.name

    if not itemName or not MEDICATION_ITEMS[itemName] then
        return
    end

    if isDowned and itemName ~= 'iak_wheelchair' then
        Framework.Notify(_L('cannot_use_incapacitated'), 'error')
        return
    end

    if not canUseMedication(itemName) then
        notifyCannotTreat(itemName)
        return
    end

    if itemName == 'iak_wheelchair' then
        local duration = item and item.metadata and item.metadata.duration

        TriggerServerEvent('amb_server:consumeMedication', itemName, slot, false, { duration = duration })
        return
    end

    if itemName == 'plt_walking_stick' or itemName == 'plt_cane' or itemName == 'plt_crutches' then
        TriggerServerEvent('amb_server:consumeMedication', itemName, slot, true)
        return
    end

    if Bridge.Inventory ~= 'ox' then
        TriggerEvent('amb_client:useMedication', itemName)
        return
    end

    TriggerServerEvent('amb_server:consumeMedication', itemName, slot, true)
end)

exports('plt_use_xray_clipboard', function(item)
    local itemName = item and item.name

    if not itemName or not XRAY_CLIPBOARD_ITEMS[itemName] then
        return
    end

    useXrayClipboard(itemName)
end)

RegisterNetEvent('amb_client:useMedication', function(itemName, metadata)
    local ped = PlayerPedId()

    if isDowned and itemName ~= 'iak_wheelchair' then
        Framework.Notify(_L('cannot_use_incapacitated'), 'error')
        return
    end

    if not canUseMedication(itemName) then
        notifyCannotTreat(itemName)
        return
    end

    if itemName == 'plt_bandage' then
        TriggerEvent('amb_client:selfBandage')
        return
    end

    CreateThread(function()
        if not playMedicationAnimation(itemName) then
            Framework.Notify(_L('medication_cancelled'), 'error')
            return
        end

        local healAmount = 1
        local maxLevel = 5

        if itemName == 'plt_painkillers' then
            healAmount = 1
            maxLevel = 1
        elseif itemName == 'plt_painkillers_adv' then
            healAmount = 4
            maxLevel = 5
        elseif itemName == 'plt_antibiotics' then
            healAmount = 2
            maxLevel = 5
        elseif itemName == 'plt_medkit' then
            healAmount = 3
            maxLevel = 5
        end

        if itemName == 'iak_wheelchair' then
            local duration = metadata and metadata.duration

            if not duration then
                local playerData = Framework.GetPlayerData()

                if playerData and playerData.items then
                    for _, item in pairs(playerData.items) do
                        if item.name == itemName then
                            local info = item.info or item.metadata

                            if info and info.duration then
                                duration = info.duration
                            end

                            break
                        end
                    end
                end
            end

            TriggerEvent('amb_client:useWheelchair', duration)
            return
        end

        local treatedAny = false
        local tooWeak = false

        for _, injury in pairs(injuries) do
            if type(injury) == 'table' and injury.level and injury.level > 0 then
                if maxLevel >= injury.level then
                    injury.level = math.max(0, injury.level - healAmount)

                    if injury.level == 0 then
                        injury.bullet = false
                        injury.bandaged = false
                    end

                    treatedAny = true
                else
                    tooWeak = true
                end
            end
        end

        if injuries.bleeding and injuries.bleeding > 0 then
            injuries.bleeding = 0
            treatedAny = true
        end

        local health = GetEntityHealth(ped)

        if health < 200 then
            SetEntityHealth(ped, math.min(200, health + (healAmount * 20)))
            treatedAny = true
        end

        if treatedAny then
            Framework.Notify(_L('injuries_feel_better'), 'success')

            if itemName == 'plt_medkit' then
                ClearPedBloodDamage(ped)
                ClearPedLastDamageBone(ped)
            end

            syncInjuries()
        elseif tooWeak and itemName == 'plt_painkillers' then
            Framework.Notify(_L('otc_too_weak'), 'error')
        end
    end)
end)

RegisterNetEvent('amb_client:useXrayClipboard', function(itemName)
    useXrayClipboard(itemName)
end)

RegisterNetEvent('amb_client:toggleWalkingAid', function(itemName)
    setWalkingAid(not isUsingMedication, itemName)
end)

RegisterNetEvent('amb_client:HealPart', function(part, amount)
    local injury = injuries[part]

    if not injury then
        return
    end

    local function notifyTreated()
        TriggerEvent('amb_client:Notify', _L('body_part_treated', {
            part = part:gsub('_', ' '):upper()
        }), 'success')
    end

    if type(injury) == 'table' then
        injury.level = math.max(0, injury.level - amount)

        if amount >= 2 then
            injury.bullet = false
        end

        if injury.level == 0 then
            injury.bullet = false
            notifyTreated()
        end
    else
        injuries[part] = math.max(0, injuries[part] - amount)

        if injuries[part] == 0 then
            notifyTreated()
        end
    end

    syncInjuries()
end)

RegisterNetEvent('amb_client:applyIVStabilization', function(part)
    local ped = PlayerPedId()

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return
    end

    local health = GetEntityHealth(ped)

    if isDowned or IsPedDeadOrDying(ped, true) or IsPedFatallyInjured(ped)
        or health <= getDownedHealth() then
        return
    end

    local newHealth = math.min(200, health + 12)

    if health < newHealth then
        SetEntityHealth(ped, newHealth)
        TriggerServerEvent('amb_server:cacheHealth', newHealth)
        Framework.Notify('IV stabilized the patient. Minor health restored.', 'success')
    end

    if part and injuries[part] and type(injuries[part]) == 'table' then
        local level = injuries[part].level or 0

        if level > 0 then
            injuries[part].level = math.max(0, level - 1)
            syncInjuries()
        end
    end
end)

RegisterNetEvent('amb_client:removeClothes', function(part)
    part = tostring(part or ''):lower()

    if part ~= 'top' and part ~= 'bottom' then
        return
    end

    local ped = PlayerPedId()
    local isFemale = GetEntityModel(ped) == -1667301416
    local gender = isFemale and 'female' or 'male'
    local genderConfig = Config.ClothingRemoval[gender]
    local components = genderConfig and genderConfig[part]

    if type(components) ~= 'table' then
        return
    end

    captureClothing(part)

    for _, component in ipairs(components) do
        SetPedComponentVariation(ped,
            tonumber(component.component) or 0,
            tonumber(component.drawable) or 0,
            tonumber(component.texture) or 0,
            tonumber(component.palette) or 0)
    end

    TriggerEvent('amb_client:requestInjuryData')
end)

RegisterNetEvent('amb_client:updateHungerWorkflow', function()
    injuries.right_arm.level = 0
    injuries.right_arm.hunger = false
    injuries.head.level = 1
    injuries.head.needsFludro = true

    TriggerEvent('amb_client:Notify', _L('vitals_stabilized_fludro'), 'info')
    TriggerEvent('amb_client:requestInjuryData')
end)

RegisterNetEvent('amb_client:giveFludro', function()
    injuries.head.level = 0
    injuries.head.needsFludro = false

    TriggerEvent('amb_client:Notify', _L('fludro_given'), 'success')
    TriggerEvent('amb_client:requestInjuryData')

    SetEntityHealth(PlayerPedId(), 140)
end)

RegisterNetEvent('amb_client:clampBleeding', function()
    injuries.bleeding = 0

    TriggerEvent('amb_client:Notify', _L('arterial_bleeding_controlled'), 'success')
    TriggerEvent('amb_client:requestInjuryData')
end)

local BANDAGE_COMPONENTS = {
    chest = 192,
    right_leg = 193,
    left_leg = 194,
    head = 195,
    right_arm = 196,
    left_arm = 197
}

RegisterNetEvent('amb_client:applyBandage', function(part)
    local ped = PlayerPedId()

    if type(part) ~= 'string' then
        part = 'chest'
    end

    injuries.bleeding = 0
    isPatientBandaged = true

    if injuries[part] and type(injuries[part]) == 'table' then
        injuries[part].bandaged = true
    end

    if not isDowned then
        local health = GetEntityHealth(ped)

        if health and health > 110 and health < 200 then
            SetEntityHealth(ped, 200)
        end
    end

    local component = BANDAGE_COMPONENTS[part]

    if component and useBandageOverlay() then
        SetPedComponentVariation(ped, 7, component, 0, 0)
    end

    syncInjuries()
end)

RegisterNetEvent('amb_client:selfBandage', function()
    if isDowned then
        return
    end

    CreateThread(function()
        if not playMedicationAnimation('plt_bandage') then
            Framework.Notify(_L('medication_cancelled'), 'error')
            return
        end

        if injuries.bleeding > 0 then
            injuries.bleeding = 0

            Framework.Notify(_L('bleeding_stopped'), 'success')

            syncInjuries()
        else
            Framework.Notify(_L('bandage_applied'), 'info')
        end
    end)
end)

RegisterNetEvent('amb_client:syncCPRAnimation', function(_, role, phase)
    local ped = PlayerPedId()
    local dict = role == 'ems' and 'mini@cpr@char_a@cpr_str' or 'mini@cpr@char_b@cpr_str'
    local anim = phase == 'success' and 'cpr_success' or 'cpr_pumpchest'

    isBeingTreated = true

    if Config.Debug then
        print('^3[PLT_MEDIC] CPR Animation Sync: Role=' .. role .. ' Phase=' .. phase .. '^7')
    end

    Framework.RequestAnimDict(dict)

    if not IsEntityPlayingAnim(ped, dict, anim, 3) then
        if role ~= 'patient' then
            ClearPedTasks(ped)
        end

        TaskPlayAnim(ped, dict, anim, 8.0, -8.0, -1, phase == 'success' and 0 or 1, 1.0, false, false, false)
    end
end)

RegisterNetEvent('amb_client:stopCPRAnimation', function()
    local ped = PlayerPedId()

    isBeingTreated = false

    if isDowned or isDeathScreenActive() then
        enforceDownedPose(ped, GetGameTimer())
    else
        ClearPedTasks(ped)
    end
end)

RegisterCommand('hungerdie', function()
    local ped = PlayerPedId()

    isDowned = true
    pushMedicalState(Framework.MedicalState.LASTSTAND)

    injuries.right_arm.level = 2
    injuries.right_arm.hunger = true

    setDownedHealth(ped)
    applyDownedProofs(ped)

    Framework.Notify(_L('hunger_test_triggered'), 'info')
end)


--[[
    Downed-state watchdog (ESX and other non-authoritative frameworks).

    On QBCore the server owns the medical state and pushes
    `amb_client:syncMedicalState`, and that event is what opens the death
    screen. ESX has no authoritative server state
    (Framework.HasAuthoritativeMedicalState() is false), the client handler for
    that same event returns early, and nothing anywhere triggered
    `amb_client:SetDownedState` - so on ESX the death screen never appeared at
    all, which also made the "call EMS" button on it unreachable.

    This watches the local downed state and fires the transition event that
    client/deathscreen.lua and client/compat_exports.lua already listen for.
    Both listeners are idempotent, so a repeated value is harmless.
]]
if not Framework.HasAuthoritativeMedicalState() then
    CreateThread(function()
        local lastDowned = nil

        while true do
            Wait(500)

            local downed = (isDowned == true and not isCrawling) or isDeathScreenActive()

            if lastDowned ~= downed then
                lastDowned = downed

                if Config.Debug then
                    print(('^3[HEALTH]^7 Downed state changed: %s'):format(tostring(downed)))
                end

                TriggerEvent('amb_client:SetDownedState', downed)
            end
        end
    end)
end

--[[
    Crawl-phase driver. While crawling, keep the downed health / proofs pinned
    without the lying-down enforcement. When the timer expires the player passes
    out (falls), the watchdog above opens the death screen, and EMS is called
    automatically.
]]
CreateThread(function()
    while true do
        if isCrawling then
            Wait(250)

            local ped = PlayerPedId()

            if not isDowned then
                isCrawling = false

                endCrawlVisuals()
            elseif GetGameTimer() >= crawlEndsAt then
                isCrawling = false

                endCrawlVisuals()

                -- pass out: fall over; the enforcement loop then pins the pose
                SetPedToRagdoll(ped, 3000, 3000, 0, false, false, false)

                CreateThread(function()
                    Wait(700)

                    if isDowned and not isCrawling then
                        TriggerEvent('amb_client:markEmsCalled')
                    end
                end)
            else
                enforceDownedHealth(ped)
                applyDownedProofs(ped)
            end
        else
            Wait(500)
        end
    end
end)

-- ---------------------------------------------------------------
-- Mercy / finished state
-- ---------------------------------------------------------------
RegisterNetEvent('amb_client:syncFinishedPlayer', function(src, state)
    src = tonumber(src)

    if not src then
        return
    end

    finishedPlayers[src] = state == true

    TriggerEvent('amb_client:finishedStateChanged', src, state == true)

    if state and src == GetPlayerServerId(PlayerId()) then
        -- If WE are the one who got finished, the crawl phase is over and the
        -- body drops lifelessly on the ground: stop whatever pose is playing
        -- and ragdoll. Finished players never play any animation.
        if isCrawling then
            isCrawling = false
            endCrawlVisuals()
        end

        local ped = PlayerPedId()

        if ped and ped ~= 0 and DoesEntityExist(ped) and not IsPedInAnyVehicle(ped, false) then
            -- Drop lifeless on the ground: stop whatever pose is playing and
            -- ragdoll with no animation at all.
            ClearPedTasksImmediately(ped)
            SetPedCanRagdoll(ped, true)
            SetPedCanRagdollFromPlayerImpact(ped, true)
            SetPedToRagdoll(ped, 99999999, 99999999, 1, false, false, false)
        end
    end
end)
