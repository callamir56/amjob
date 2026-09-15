local diagnosisWatchers = {}

local function resolveTarget(targetId)
    targetId = tonumber(targetId)

    if targetId and GetPlayerName(targetId) then
        return targetId
    end
end

local function isAuthorized(src)
    if exports.plt_ambulance_job:IsEMS(src) then
        return true
    end

    return Framework.HasPermission(src, Config.Permission)
end

RegisterNetEvent('amb_server:requestInjuries', function(patientId)
    local src = source

    if not diagnosisWatchers[patientId] then
        diagnosisWatchers[patientId] = {}
    end

    local alreadyWatching = false

    for _, watcherId in ipairs(diagnosisWatchers[patientId]) do
        if watcherId == src then
            alreadyWatching = true
            break
        end
    end

    if not alreadyWatching then
        table.insert(diagnosisWatchers[patientId], src)
    end

    TriggerClientEvent('amb_client:requestInjuryData', patientId)
end)

RegisterNetEvent('amb_server:syncInjuryData', function(injuryData)
    local src = source
    local watchers = diagnosisWatchers[src]

    if not watchers then
        return
    end

    for index = #watchers, 1, -1 do
        local watcherId = watchers[index]

        if GetPlayerName(watcherId) then
            TriggerClientEvent('amb_client:receiveDiagnosisData', watcherId, injuryData)
        else
            table.remove(watchers, index)
        end
    end
end)

RegisterNetEvent('amb_server:stopDiagnosisSync', function(patientId)
    local src = source

    if not diagnosisWatchers[patientId] then
        return
    end

    for index, watcherId in ipairs(diagnosisWatchers[patientId]) do
        if watcherId == src then
            table.remove(diagnosisWatchers[patientId], index)
            break
        end
    end
end)

RegisterNetEvent('amb_server:removeClothes', function(targetId, clothingPart)
    local src = source

    targetId = resolveTarget(targetId)

    if not targetId then
        return
    end

    -- Undressing another player is a medic action; it used to be open to anyone.
    if targetId ~= src and not isAuthorized(src) then
        return
    end

    local part = tostring(clothingPart or ''):lower()

    if part ~= 'top' and part ~= 'bottom' then
        return
    end

    TriggerClientEvent('amb_client:removeClothes', targetId, part)
end)

-- Dresses the patient again from the snapshot taken by amb_client:removeClothes.
RegisterNetEvent('amb_server:restoreClothes', function(targetId)
    local src = source

    targetId = resolveTarget(targetId)

    if not targetId then
        return
    end

    if targetId ~= src and not isAuthorized(src) then
        return
    end

    TriggerClientEvent('amb_client:restoreRemovedClothes', targetId)
end)

RegisterNetEvent('amb_server:forcePatientInteriorMaskLastSlot', function(targetId)
    local src = source

    targetId = resolveTarget(targetId)

    if not targetId then
        return
    end

    if not isAuthorized(src) then
        return
    end

    TriggerClientEvent('amb_client:forceMaskLastSlot', targetId)
end)

RegisterNetEvent('amb_server:applyBandage', function(targetId, bodyPart)
    local src = source

    if Inventory.RemoveItem(src, 'plt_bandage', 1) then
        TriggerClientEvent('amb_client:applyBandage', targetId, bodyPart)
    end
end)

RegisterNetEvent('amb_server:updateHungerWorkflow', function(targetId)
    TriggerClientEvent('amb_client:updateHungerWorkflow', targetId)
end)

RegisterNetEvent('amb_server:giveFludro', function(targetId)
    local src = source

    if Inventory.RemoveItem(src, 'plt_medkit', 1) then
        TriggerClientEvent('amb_client:giveFludro', targetId)
    end
end)

RegisterNetEvent('amb_server:ClampBleeding', function(targetId)
    local src = source

    if Inventory.GetItemCount(src, 'plt_surgical_kit') > 0 then
        TriggerClientEvent('amb_client:clampBleeding', targetId)
    end
end)

RegisterNetEvent('amb_server:applyIVStabilization', function(targetId, ivType)
    local src = source

    targetId = resolveTarget(targetId)

    if not targetId then
        return
    end

    if not isAuthorized(src) then
        return
    end

    TriggerClientEvent('amb_client:applyIVStabilization', targetId, ivType)
end)

RegisterNetEvent('amb_server:startCombinedCPR', function(patientId)
    local src = source

    TriggerClientEvent('amb_client:syncCPRAnimation', patientId, src, 'patient', 'loop')
    TriggerClientEvent('amb_client:syncCPRAnimation', src, patientId, 'ems', 'loop')
end)

RegisterNetEvent('amb_server:successCPR', function(patientId)
    local src = source

    TriggerClientEvent('amb_client:syncCPRAnimation', patientId, src, 'patient', 'success')
    TriggerClientEvent('amb_client:syncCPRAnimation', src, patientId, 'ems', 'success')
end)

RegisterNetEvent('amb_server:stopCombinedCPR', function(patientId)
    local src = source

    TriggerClientEvent('amb_client:stopCPRAnimation', patientId)
    TriggerClientEvent('amb_client:stopCPRAnimation', src)
end)

RegisterNetEvent('amb_server:finishCPR', function(patientId)
    local src = source

    TriggerClientEvent('amb_client:syncCPRAnimation', patientId, src, 'patient', 'success')
    TriggerClientEvent('amb_client:syncCPRAnimation', src, patientId, 'ems', 'success')

    diagnosisWatchers[patientId] = nil

    TriggerClientEvent('amb_client:stopCPRAnimation', patientId)
    TriggerClientEvent('amb_client:stopCPRAnimation', src)

    exports.plt_ambulance_job:InternalRevive(patientId)
end)

Framework.CreateCallback('amb_server:hasRequiredItem', function(src, cb, itemName)
    cb(Inventory.GetItemCount(src, itemName) > 0)
end)

