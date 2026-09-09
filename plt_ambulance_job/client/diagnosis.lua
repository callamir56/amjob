local REQUIRE_VEIN_INSERT = false

local diagnosisActive = false
local diagnosisCam = nil
local targetPed = nil
local targetServerId = nil
local injuryData = {}
local clothingState = { top = true, bottom = true }
local chestListenCompleted = false
local chestListenActive = false
local veinInsertCompleted = not REQUIRE_VEIN_INSERT
local veinInsertActive = false
local pendingRefreshPart = nil

local BODY_PARTS = {
    { name = 'head', label = _L('body_head'), bone = 31086, ox = 0.0, oy = 0.0, oz = 0.03 },
    { name = 'chest', label = _L('body_chest'), bone = 24817, ox = 0.0, oy = 0.0, oz = 0.0 },
    { name = 'left_arm', label = _L('body_left_arm'), bone = 18905, ox = 0.0, oy = 0.0, oz = 0.0 },
    { name = 'right_arm', label = _L('body_right_arm'), bone = 57005, ox = 0.0, oy = 0.0, oz = 0.0 },
    { name = 'left_leg', label = _L('body_left_leg'), bone = 14201, ox = 0.0, oy = 0.0, oz = 0.02 },
    { name = 'right_leg', label = _L('body_right_leg'), bone = 52301, ox = 0.0, oy = 0.0, oz = 0.02 }
}

local VALID_PARTS = {
    head = true,
    chest = true,
    left_arm = true,
    right_arm = true,
    left_leg = true,
    right_leg = true
}

local KNEEL_DICT = 'amb@medic@standing@kneel@base'
local KNEEL_ANIM = 'base'
local MEDIC_SCENARIO = 'CODE_HUMAN_MEDIC_TEND_TO_KNOT'

local startChestListen
local startVeinInsert

local function isPlayerStateDowned(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false
    end

    local playerIndex = NetworkGetPlayerIndexFromPed(ped)

    if not playerIndex or playerIndex < 0 then
        return false
    end

    local serverId = GetPlayerServerId(playerIndex)
    local state = serverId and Player(serverId) and Player(serverId).state
    local medicalState = state and state.medicalState

    return medicalState == 'laststand' or medicalState == 'dead'
end

local function isTargetDowned(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false
    end

    return isPlayerStateDowned(ped)
        or IsPedDeadOrDying(ped, true)
        or IsPedRagdoll(ped)
        or GetEntityHealth(ped) <= 120
        or IsEntityPlayingAnim(ped, 'dead', 'dead_a', 3)
        or IsEntityPlayingAnim(ped, 'veh@low@front_ps@idle_duck', 'sit', 3)
end

local function normalizePartName(part)
    if type(part) ~= 'string' then
        return 'chest'
    end

    local normalized = string.lower(part):gsub('%s+', '_')

    if VALID_PARTS[normalized] then
        return normalized
    end

    return 'chest'
end

local function getTargetHealthPercent()
    if not targetPed or targetPed == 0 or not DoesEntityExist(targetPed) then
        return 100
    end

    local health = math.floor(GetEntityHealth(targetPed) - 100)

    if health < 0 then
        health = 0
    end

    if health > 100 then
        health = 100
    end

    return health
end

local function isPedFemale(ped)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return false
    end

    local ok, isMale = pcall(IsPedMale, ped)

    if ok and isMale ~= nil then
        return not isMale
    end

    return GetEntityModel(ped) == -1667301416
end

local function isTargetFemale()
    if not targetPed or targetPed == 0 or not DoesEntityExist(targetPed) then
        return false
    end

    return isPedFemale(targetPed)
end

local function refreshDiagnosis(part)
    if not diagnosisActive or not targetPed then
        return
    end

    pendingRefreshPart = part

    Citizen.SetTimeout(500, function()
        if not diagnosisActive or not targetPed then
            return
        end

        TriggerServerEvent('amb_server:requestInjuries', targetServerId)

        local ped = PlayerPedId()

        Framework.RequestAnimDict(KNEEL_DICT)

        if not IsEntityPlayingAnim(ped, KNEEL_DICT, KNEEL_ANIM, 3) then
            TaskPlayAnim(ped, KNEEL_DICT, KNEEL_ANIM, 8.0, -8.0, -1, 1, 1.0, false, false, false)
        end

        SetNuiFocus(true, true)

        SendNUIMessage({ action = 'amb_showDiagnosis' })
    end)
end

local function getPrimaryTreatmentPart(injuries)
    if type(injuries) ~= 'table' then
        return nil
    end

    local primaryPart = nil
    local highestScore = 0
    local bleeding = tonumber(injuries.bleeding) or 0

    for _, partName in ipairs({ 'head', 'chest', 'left_arm', 'right_arm', 'left_leg', 'right_leg' }) do
        local part = injuries[partName]

        if type(part) == 'table' then
            local score = (tonumber(part.level) or 0) * 10

            if part.bullet then
                score = score + 25
            end

            if part.isFractured then
                score = score + 20
            end

            if part.needsFludro then
                score = score + 15
            end

            if part.hunger then
                score = score + 12
            end

            if bleeding > 0 then
                score = score + 5
            end

            if partName == 'chest' and not part.bullet and not part.isFractured
                and (tonumber(part.level) or 0) <= 2 then
                score = score - 8
            end

            if score > highestScore then
                highestScore = score
                primaryPart = partName
            end
        end
    end

    if highestScore <= 0 then
        return nil
    end

    return primaryPart
end

function StartDiagnosis(ped)
    if diagnosisActive then
        return
    end

    targetPed = ped
    targetServerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(targetPed))

    chestListenCompleted = false
    chestListenActive = false
    veinInsertCompleted = not REQUIRE_VEIN_INSERT
    veinInsertActive = false

    if targetServerId == 0 then
        Framework.Notify(_L('diagnosis_no_patient_id'), 'error')
        return
    end

    local playerPed = PlayerPedId()

    SetPedConfigFlag(playerPed, 184, true)

    Framework.RequestAnimDict(KNEEL_DICT)
    TaskPlayAnim(playerPed, KNEEL_DICT, KNEEL_ANIM, 8.0, -8.0, -1, 1, 1.0, false, false, false)

    clothingState.top = GetPedDrawableVariation(targetPed, 11) ~= 15
    clothingState.bottom = GetPedDrawableVariation(targetPed, 4) ~= 21

    TriggerServerEvent('amb_server:requestInjuries', targetServerId)

    Framework.Notify(_L('diagnosis_preparing'), 'info')

    local targetCoords = GetEntityCoords(targetPed)

    diagnosisCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)

    if isTargetDowned(targetPed) then
        SetCamCoord(diagnosisCam, targetCoords.x, targetCoords.y, targetCoords.z + 0.85)
        SetCamRot(diagnosisCam, -90.0, 0.0, GetEntityHeading(targetPed) + 120.0)
    else
        local camCoords = GetOffsetFromEntityInWorldCoords(targetPed, 0.0, 1.5, 0.4)

        SetCamCoord(diagnosisCam, camCoords.x, camCoords.y, camCoords.z)
        PointCamAtEntity(diagnosisCam, targetPed, 0.0, 0.0, 0.2, true)
    end

    SetCamActive(diagnosisCam, true)
    RenderScriptCams(true, true, 1000, true, true)

    diagnosisActive = true

    SetNuiFocus(true, true)

    Wait(1000)

    if not next(injuryData) then
        if Config.Debug then
            print('^3[EMS DEBUG] No injury data received yet. Retrying request...^7')
        end

        TriggerServerEvent('amb_server:requestInjuries', targetServerId)
    end

    CreateThread(function()
        while diagnosisActive do
            local dots = {}

            for _, part in ipairs(BODY_PARTS) do
                local boneCoords = GetPedBoneCoords(targetPed, part.bone, part.ox or 0.0, part.oy or 0.0, part.oz or 0.0)
                local onScreen, screenX, screenY = GetScreenCoordFromWorldCoord(boneCoords.x, boneCoords.y, boneCoords.z)

                if onScreen then
                    local safeZone = GetSafeZoneSize()
                    local safeOffset = (1.0 - safeZone) * 0.5

                    screenX = (screenX - safeOffset) / safeZone
                    screenY = (screenY - safeOffset) / safeZone

                    if screenX < 0.0 then
                        screenX = 0.0
                    elseif screenX > 1.0 then
                        screenX = 1.0
                    end

                    if screenY < 0.0 then
                        screenY = 0.0
                    elseif screenY > 1.0 then
                        screenY = 1.0
                    end

                    local injury = injuryData[part.name] or {
                        level = 0,
                        bullet = false,
                        isFractured = false
                    }

                    table.insert(dots, {
                        name = part.name,
                        label = part.label,
                        x = screenX * 100,
                        y = screenY * 100,
                        hasHits = injury.level > 0,
                        hasBullet = injury.bullet == true,
                        isFractured = injury.isFractured == true
                    })
                end
            end

            SendNUIMessage({
                action = 'amb_updateDiagnosisDots',
                dots = dots
            })

            Wait(33)
        end
    end)
end

RegisterNetEvent('amb_client:receiveDiagnosisData', function(injuries)
    if not diagnosisActive then
        return
    end

    if Config.Debug then
        print('^2[EMS DEBUG] Received Injury Data Sync for target^7')

        if injuries and injuries.head then
            print('^2[EMS DEBUG] Head level: ' .. tostring(injuries.head.level)
                .. ' Bullet: ' .. tostring(injuries.head.bullet) .. '^7')
        end
    end

    injuryData = injuries

    SendNUIMessage({
        action = 'amb_openDiagnosisUI',
        injuries = injuries,
        isEMS = exports.plt_ambulance_job:IsEMS(),
        isDowned = isTargetDowned(targetPed)
    })

    if pendingRefreshPart then
        if Config.Debug then
            print('^3[DEBUG] Auto-refreshing part: ' .. tostring(pendingRefreshPart) .. '^7')
        end

        SendNUIMessage({
            action = 'amb_refreshDiagnosisPart',
            part = pendingRefreshPart
        })

        pendingRefreshPart = nil
    end
end)

RegisterNUICallback('closeDiagnosis', function(_, cb)
    diagnosisActive = false

    TriggerServerEvent('amb_server:stopDiagnosisSync')

    SetNuiFocus(false, false)
    RenderScriptCams(false, true, 1000, true, true)
    DestroyCam(diagnosisCam, false)

    diagnosisCam = nil
    targetPed = nil
    targetServerId = nil
    injuryData = {}
    chestListenCompleted = false
    chestListenActive = false
    veinInsertCompleted = not REQUIRE_VEIN_INSERT
    veinInsertActive = false

    local ped = PlayerPedId()

    FreezeEntityPosition(ped, false)
    SetPedConfigFlag(ped, 184, false)
    ClearPedTasks(ped)

    cb('ok')
end)

exports('GetDiagnosisTarget', function()
    return targetServerId
end)

startChestListen = function(part)
    if not diagnosisActive then
        return
    end

    chestListenActive = true

    local targetHealth = getTargetHealthPercent()

    SendNUIMessage({
        action = 'amb_startChestListenMinigame',
        targetSrc = targetServerId,
        part = part or 'chest',
        targetHealth = targetHealth,
        hasAnomaly = targetHealth < 80,
        isFemale = isTargetFemale()
    })

    SetNuiFocus(true, true)
end

startVeinInsert = function(part)
    if not diagnosisActive then
        return
    end

    veinInsertCompleted = true
    veinInsertActive = false

    refreshDiagnosis(part or 'left_arm')
end

RegisterNUICallback('getPartDetail', function(data, cb)
    local partName = data.part
    local injury = injuryData[partName] or {
        level = 0,
        bullet = false,
        bandaged = false,
        hunger = false,
        needsFludro = false,
        isFractured = false,
        fractureTime = 0
    }

    local info = _L('diagnosis_no_significant')
    local needsClothingRemoval = false
    local clothingType = ''
    local clothingTypeId = nil

    if partName == 'chest' or partName == 'left_arm' or partName == 'right_arm' then
        if clothingState.top then
            needsClothingRemoval = true
            clothingType = _L('clothing_top')
            clothingTypeId = 'top'
        end
    elseif partName == 'left_leg' or partName == 'right_leg' then
        if clothingState.bottom then
            needsClothingRemoval = true
            clothingType = _L('clothing_bottom')
            clothingTypeId = 'bottom'
        end
    end

    if injury.isFractured then
        info = _L('diagnosis_info_fracture', {
            mins = ('%02d'):format(math.floor(injury.fractureTime / 60)),
            secs = ('%02d'):format(injury.fractureTime % 60)
        })
    elseif injury.bullet then
        info = _L('diagnosis_info_bullet')
    elseif injury.needsFludro then
        info = _L('diagnosis_info_fludro')
    elseif injury.hunger then
        info = _L('diagnosis_info_hunger')
    elseif injury.level >= 5 then
        info = _L('diagnosis_info_level5')
    elseif injury.level >= 3 then
        info = _L('diagnosis_info_level3')
    elseif injury.level >= 1 then
        info = _L('diagnosis_info_level1')
    end

    if injury.bandaged then
        info = info .. ' ' .. _L('diagnosis_part_bandaged')
    end

    local targetDowned = isTargetDowned(targetPed)
    local primaryPart = getPrimaryTreatmentPart(injuryData)

    cb({
        label = partName:gsub('_', ' '):upper(),
        level = injury.level or 0,
        info = info,
        topClothesOn = clothingState.top == true,
        needsClothingRemoval = needsClothingRemoval,
        clothingType = clothingType,
        clothingTypeId = clothingTypeId,
        hasBullet = injury.bullet == true,
        isBandaged = injury.bandaged == true,
        isPatientBandaged = injuryData.isPatientBandaged == true,
        isHunger = injury.hunger == true,
        needsFludro = injury.needsFludro == true,
        isBleeding = (injuryData.bleeding or 0) > 0,
        isFractured = injury.isFractured == true,
        primaryTreatmentPart = primaryPart,
        isPrimaryTreatmentPart = primaryPart == nil or partName == primaryPart,
        targetDowned = targetDowned,
        canRevive = targetDowned,
        targetHealth = getTargetHealthPercent(),
        chestListenCompleted = chestListenCompleted,
        chestListenRequired = not chestListenCompleted,
        veinInsertCompleted = veinInsertCompleted,
        veinInsertRequired = targetDowned and not veinInsertCompleted
    })
end)

RegisterNUICallback('startExamination', function(data, cb)
    local partName = normalizePartName(data and data.part)

    if not diagnosisActive or not targetPed then
        cb('ok')
        return
    end

    if clothingState.top then
        Framework.Notify("Remove the patient's top clothing before examination.", 'error')
        cb('ok')
        return
    end

    if not chestListenCompleted then
        startChestListen(partName)
        cb('ok')
        return
    end

    if isTargetDowned(targetPed) and not veinInsertCompleted then
        startVeinInsert(partName)
        cb('ok')
        return
    end

    Framework.Notify('Primary examination already completed.', 'info')
    cb('ok')
end)

RegisterNUICallback('startTreatment', function(data, cb)
    if not chestListenCompleted then
        Framework.Notify('You must auscultate the chest first.', 'error')
        cb('ok')
        return
    end

    if isTargetDowned(targetPed) and not veinInsertCompleted then
        Framework.Notify('You must complete IV insertion first.', 'error')
        cb('ok')
        return
    end

    local partName = data.part
    local treatmentType = data.type
    local patientSrc = GetPlayerServerId(NetworkGetPlayerIndexFromPed(targetPed))

    if treatmentType == 'bullet' or treatmentType == 'heal' then
        local blocked = false
        local clothingLabel = ''

        if partName == 'chest' or partName == 'left_arm' or partName == 'right_arm' then
            if clothingState.top then
                blocked = true
                clothingLabel = 'TOP'
            end
        elseif partName == 'left_leg' or partName == 'right_leg' then
            if clothingState.bottom then
                blocked = true
                clothingLabel = 'BOTTOM'
            end
        end

        if blocked then
            local action = treatmentType == 'bullet'
                and _L('diagnosis_action_surgery')
                or _L('diagnosis_action_treatment')

            Framework.Notify(_L('diagnosis_remove_clothing', {
                clothingType = clothingLabel,
                action = action
            }), 'error')

            cb('ok')
            return
        end
    end

    local requiredItem = 'plt_medkit'

    if treatmentType == 'bullet' then
        requiredItem = 'plt_surgical_kit'
    elseif treatmentType == 'clamp' then
        requiredItem = 'plt_surgical_kit'
    elseif treatmentType == 'bp' then
        requiredItem = 'plt_bp_monitor'
    end

    Framework.TriggerCallback('amb_server:hasRequiredItem', function(hasItem)
        if not hasItem then
            local itemLabel = _L('diagnosis_item_supplies')

            if requiredItem == 'plt_medkit' then
                itemLabel = _L('item_medkit')
            elseif requiredItem == 'plt_surgical_kit' then
                itemLabel = _L('item_surgical_kit')
            elseif requiredItem == 'plt_bp_monitor' then
                itemLabel = _L('item_bp_monitor')
            end

            Framework.Notify(_L('diagnosis_need_item', { item = itemLabel }), 'error')
            return
        end

        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'amb_hideDiagnosis' })

        if treatmentType == 'bp' then
            TriggerEvent('amb_client:startBPMinigame', patientSrc, partName)
        elseif treatmentType == 'clamp' then
            TriggerEvent('amb_client:startClampMinigame', patientSrc, partName)
        elseif treatmentType == 'bullet' then
            TriggerEvent('amb_client:startBulletMinigame', patientSrc, partName)
        elseif treatmentType == 'fludro' then
            TriggerEvent('amb_client:giveFludroTreatment', patientSrc, partName)
        else
            TriggerEvent('amb_client:startSutureMinigame', patientSrc, partName)
        end
    end, requiredItem)

    cb('ok')
end)

RegisterNUICallback('startChestListen', function(data, cb)
    startChestListen((data and data.part) or 'chest')
    cb('ok')
end)

RegisterNUICallback('chestListenMinigameResult', function(data, cb)
    local success = data and data.success == true

    chestListenActive = false

    if success then
        chestListenCompleted = true

        if isTargetDowned(targetPed) then
            if not veinInsertCompleted then
                startVeinInsert('left_arm')
            end
        else
            SetNuiFocus(false, false)
            refreshDiagnosis((data and data.part) or 'chest')
        end
    else
        chestListenCompleted = false

        Framework.Notify('Chest auscultation is required before treatment.', 'error')

        SetNuiFocus(false, false)

        if diagnosisActive then
            refreshDiagnosis((data and data.part) or 'chest')
        end
    end

    cb('ok')
end)

local function startMedicScenario()
    TaskStartScenarioInPlace(PlayerPedId(), MEDIC_SCENARIO, 0, true)
end

RegisterNetEvent('amb_client:startSutureMinigame', function(patientSrc, partName)
    startMedicScenario()

    SendNUIMessage({
        action = 'amb_startSutureMinigame',
        targetSrc = patientSrc,
        part = partName
    })

    SetNuiFocus(true, true)
end)

RegisterNUICallback('sutureMinigameResult', function(data, cb)
    SetNuiFocus(false, false)
    ClearPedTasks(PlayerPedId())

    if data.success then
        TriggerServerEvent('amb_server:HealPlayer', data.targetSrc, data.part, 1)
        Framework.Notify(_L('diagnosis_wound_treated'), 'success')
    end

    refreshDiagnosis(data.part)
    cb('ok')
end)

RegisterNetEvent('amb_client:giveFludroTreatment', function(patientSrc, partName)
    local ped = PlayerPedId()

    TaskStartScenarioInPlace(ped, MEDIC_SCENARIO, 0, true)

    local completed = Framework.ProgressBar(_L('diagnosis_progress_fludro'), 5000)

    ClearPedTasks(ped)

    if completed then
        TriggerServerEvent('amb_server:giveFludro', patientSrc)
    end

    refreshDiagnosis(partName)
end)

RegisterNetEvent('amb_client:startBPMinigame', function(patientSrc, partName)
    startMedicScenario()

    SendNUIMessage({
        action = 'amb_startBPMinigame',
        targetSrc = patientSrc,
        part = partName
    })

    SetNuiFocus(true, true)
end)

RegisterNUICallback('bpMinigameResult', function(data, cb)
    SetNuiFocus(false, false)
    ClearPedTasks(PlayerPedId())

    if data.success then
        Framework.Notify(_L('diagnosis_bp_stable'), 'success')

        if injuryData.right_arm then
            injuryData.right_arm.level = 0
            injuryData.right_arm.hunger = false
        end

        if not injuryData.head then
            injuryData.head = {
                level = 0,
                bullet = false,
                bandaged = false
            }
        end

        injuryData.head.level = 1
        injuryData.head.needsFludro = true

        TriggerServerEvent('amb_server:updateHungerWorkflow', data.targetSrc)
    end

    refreshDiagnosis(data.part)
    cb('ok')
end)

RegisterNetEvent('amb_client:startClampMinigame', function(patientSrc, partName)
    startMedicScenario()

    SendNUIMessage({
        action = 'amb_startClampMinigame',
        targetSrc = patientSrc,
        part = partName
    })

    SetNuiFocus(true, true)
end)

RegisterNUICallback('clampMinigameResult', function(data, cb)
    SetNuiFocus(false, false)
    ClearPedTasks(PlayerPedId())

    if data.success then
        TriggerServerEvent('amb_server:ClampBleeding', data.targetSrc)
        Framework.Notify(_L('diagnosis_bleeding_clamped'), 'success')
    end

    refreshDiagnosis(data.part)
    cb('ok')
end)

RegisterNUICallback('applyBandage', function(data, cb)
    if not chestListenCompleted then
        Framework.Notify('You must auscultate the chest first.', 'error')
        cb('ok')
        return
    end

    if isTargetDowned(targetPed) and not veinInsertCompleted then
        Framework.Notify('You must complete IV insertion first.', 'error')
        cb('ok')
        return
    end

    local patientSrc = GetPlayerServerId(NetworkGetPlayerIndexFromPed(targetPed))

    Framework.TriggerCallback('amb_server:hasRequiredItem', function(hasItem)
        if not hasItem then
            Framework.Notify(_L('diagnosis_need_bandage'), 'error')
            return
        end

        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'amb_hideDiagnosis' })

        TriggerEvent('amb_client:startBandageMinigame', patientSrc, data.part)
    end, 'plt_bandage')

    cb('ok')
end)

RegisterNetEvent('amb_client:startBandageMinigame', function(patientSrc, partName)
    startMedicScenario()

    SendNUIMessage({
        action = 'amb_startBandageMinigame',
        targetSrc = patientSrc,
        part = partName
    })

    SetNuiFocus(true, true)
end)

RegisterNUICallback('bandageMinigameResult', function(data, cb)
    SetNuiFocus(false, false)
    ClearPedTasks(PlayerPedId())

    local patientSrc = (data and tonumber(data.targetSrc)) or targetServerId
    local partName = normalizePartName(data and data.part)

    if data.success and patientSrc then
        TriggerServerEvent('amb_server:applyBandage', patientSrc, partName)
        Framework.Notify(_L('diagnosis_bandage_applied'), 'success')
    end

    refreshDiagnosis(partName)
    cb('ok')
end)

RegisterNetEvent('amb_client:startBulletMinigame', function(patientSrc, partName)
    startMedicScenario()

    SendNUIMessage({
        action = 'amb_startBulletMinigame',
        targetSrc = patientSrc,
        part = partName
    })

    SetNuiFocus(true, true)
end)

RegisterNUICallback('bulletMinigameResult', function(data, cb)
    SetNuiFocus(false, false)
    ClearPedTasks(PlayerPedId())

    if data.success then
        TriggerServerEvent('amb_server:HealPlayer', data.targetSrc, data.part, 2)
        Framework.Notify(_L('diagnosis_bullet_extracted'), 'success')
    end

    refreshDiagnosis(data.part)
    cb('ok')
end)

RegisterNUICallback('performCPR', function(_, cb)
    if not chestListenCompleted then
        Framework.Notify('You must auscultate the chest first.', 'error')
        cb('ok')
        return
    end

    if isTargetDowned(targetPed) and not veinInsertCompleted then
        Framework.Notify('You must complete IV insertion first.', 'error')
        cb('ok')
        return
    end

    local patientSrc = GetPlayerServerId(NetworkGetPlayerIndexFromPed(targetPed))

    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'amb_hideDiagnosis' })

    local ped = PlayerPedId()

    FreezeEntityPosition(ped, false)

    local patientHeading = GetEntityHeading(targetPed)
    local cprCoords = GetOffsetFromEntityInWorldCoords(targetPed, -0.7196, -0.2604, 3.0E-4)
    local foundGround, groundZ = GetGroundZFor_3dCoord(cprCoords.x, cprCoords.y, cprCoords.z + 1.0, false)

    if foundGround then
        cprCoords = vector3(cprCoords.x, cprCoords.y, groundZ)
    end

    SetEntityCoords(ped, cprCoords.x, cprCoords.y, cprCoords.z, false, false, false, true)
    SetEntityHeading(ped, patientHeading - 90.0)

    TriggerServerEvent('amb_server:startCombinedCPR', patientSrc)

    SetPedConfigFlag(ped, 184, true)
    FreezeEntityPosition(ped, true)

    if Framework.ProgressBar('Performing CPR', 20000) then
        TriggerServerEvent('amb_server:finishCPR', patientSrc)
        Framework.Notify(_L('diagnosis_cpr_success'), 'success')

        diagnosisActive = false

        SetPedConfigFlag(ped, 184, false)
        ClearPedTasks(ped)
        RenderScriptCams(false, true, 300, true, true)

        if diagnosisCam then
            DestroyCam(diagnosisCam, false)
            diagnosisCam = nil
        end

        FreezeEntityPosition(ped, false)

        targetPed = nil
        targetServerId = nil
    else
        TriggerServerEvent('amb_server:stopCombinedCPR', patientSrc)
        ClearPedTasks(ped)
        refreshDiagnosis()
    end

    cb('ok')
end)

RegisterNUICallback('removePatientClothes', function(data, cb)
    local patientSrc = GetPlayerServerId(NetworkGetPlayerIndexFromPed(targetPed))

    Framework.TriggerCallback('amb_server:hasRequiredItem', function(hasItem)
        if not hasItem then
            Framework.Notify(_L('diagnosis_need_scissors'), 'error')
            return
        end

        local clothingType = tostring(data.type or ''):lower()

        if clothingType == 'top' or clothingType == 'shirt' then
            clothingState.top = false
            TriggerServerEvent('amb_server:removeClothes', patientSrc, 'top')
        elseif clothingType == 'bottom' or clothingType == 'pants' then
            clothingState.bottom = false
            TriggerServerEvent('amb_server:removeClothes', patientSrc, 'bottom')
        else
            Framework.Notify('Invalid clothing selection.', 'error')
            return
        end

        refreshDiagnosis(data.part)
    end, 'plt_surgical_scissors')

    cb('ok')
end)

RegisterNUICallback('dressPatientClothes', function(data, cb)
    local patientSrc = GetPlayerServerId(NetworkGetPlayerIndexFromPed(targetPed))

    local clothingType = tostring((data and data.type) or 'all'):lower()

    if clothingType == 'top' then
        clothingState.top = true
    elseif clothingType == 'bottom' then
        clothingState.bottom = true
    else
        clothingState.top = true
        clothingState.bottom = true
    end

    TriggerServerEvent('amb_server:restoreClothes', patientSrc)

    refreshDiagnosis(data and data.part)

    cb('ok')
end)

local function resolveTargetSrc(value)
    local serverId = tonumber(value)

    if serverId and serverId > 0 then
        return serverId
    end

    return GetPlayerServerId(PlayerId())
end

local function startChestMinigameCommand(args)
    local mode = (args and args[1] and string.lower(tostring(args[1]))) or 'auto'
    local partName = normalizePartName((args and args[2]) or 'chest')
    local patientSrc = resolveTargetSrc(args and args[3])

    local targetHealth
    local hasAnomaly = false

    if mode == 'normal' then
        targetHealth = 95
        hasAnomaly = false
    elseif mode == 'anomaly' then
        targetHealth = 60
        hasAnomaly = true
    elseif tonumber(mode) then
        targetHealth = math.floor(tonumber(mode))

        if targetHealth < 0 then
            targetHealth = 0
        end

        if targetHealth > 100 then
            targetHealth = 100
        end

        hasAnomaly = targetHealth < 80
    else
        targetHealth = 100
        hasAnomaly = false
    end

    SendNUIMessage({
        action = 'amb_startChestListenMinigame',
        targetSrc = patientSrc,
        part = partName,
        targetHealth = targetHealth,
        hasAnomaly = hasAnomaly,
        isFemale = isPedFemale(PlayerPedId())
    })

    SetNuiFocus(true, true)

    Framework.Notify(('Chest minigame started (%s, health %d%%).'):format(
        hasAnomaly and 'anomaly' or 'normal', targetHealth), 'info')
end

RegisterCommand('bandageminigame', function(_, args)
    local partName = normalizePartName(args and args[1])
    local patientSrc = tonumber(args and args[2]) or GetPlayerServerId(PlayerId())

    TriggerEvent('amb_client:startBandageMinigame', patientSrc, partName)
    Framework.Notify(('Bandage minigame started (%s).'):format(partName), 'info')
end, false)

RegisterCommand('minigames', function()
    Framework.Notify('/minigame1=Suture | /minigame2=Clamp | /minigame3=Bullet | /minigame4=BP | /minigame5=Bandage | /minigame6=Chest', 'info')
end, false)

RegisterCommand('minigame1', function(_, args)
    local partName = normalizePartName((args and args[1]) or 'chest')
    local patientSrc = resolveTargetSrc(args and args[2])

    TriggerEvent('amb_client:startSutureMinigame', patientSrc, partName)
    Framework.Notify(('Suture minigame started (%s).'):format(partName), 'info')
end, false)

RegisterCommand('minigame2', function(_, args)
    local partName = normalizePartName((args and args[1]) or 'chest')
    local patientSrc = resolveTargetSrc(args and args[2])

    TriggerEvent('amb_client:startClampMinigame', patientSrc, partName)
    Framework.Notify(('Clamp minigame started (%s).'):format(partName), 'info')
end, false)

RegisterCommand('minigame3', function(_, args)
    local partName = normalizePartName((args and args[1]) or 'chest')
    local patientSrc = resolveTargetSrc(args and args[2])

    TriggerEvent('amb_client:startBulletMinigame', patientSrc, partName)
    Framework.Notify(('Bullet extraction minigame started (%s).'):format(partName), 'info')
end, false)

RegisterCommand('minigame4', function(_, args)
    local partName = normalizePartName((args and args[1]) or 'right_arm')
    local patientSrc = resolveTargetSrc(args and args[2])

    TriggerEvent('amb_client:startBPMinigame', patientSrc, partName)
    Framework.Notify(('Blood pressure minigame started (%s).'):format(partName), 'info')
end, false)

RegisterCommand('minigame5', function(_, args)
    local partName = normalizePartName((args and args[1]) or 'chest')
    local patientSrc = resolveTargetSrc(args and args[2])

    TriggerEvent('amb_client:startBandageMinigame', patientSrc, partName)
    Framework.Notify(('Bandage minigame started (%s).'):format(partName), 'info')
end, false)

RegisterCommand('minigame6', function(_, args)
    startChestMinigameCommand(args)
end, false)

