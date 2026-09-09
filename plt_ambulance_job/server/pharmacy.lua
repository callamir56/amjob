local Core = exports.plt_ambulance_job:GetFramework()

local function findCertificateData(src, slot)
    local player = Core.GetPlayer(src)

    if not player then
        return nil
    end

    for index, item in pairs(Inventory.GetItems(src)) do
        if item and item.name == 'plt_ems_certificate' then
            local itemSlot = item.slot or index
            local matchesSlot = slot == nil or tonumber(itemSlot) == tonumber(slot)

            if matchesSlot then
                return item.info or item.metadata
            end
        end
    end

    return nil
end

local function getInsuranceMeta(src)
    return Core.GetMetaData(src, 'medical_insurance')
end

local function hasInsurance(src)
    local value = getInsuranceMeta(src)

    return value ~= nil and value ~= false and value ~= 0 and value ~= '0' and value ~= ''
end

local function getDefaultEmsJob()
    return (Config.Medical and Config.Medical.EMSJobs and Config.Medical.EMSJobs[1]) or 'ambulance'
end

Core.CreateCallback('amb_server:getPharmacyData', function(src, cb)
    local player = Core.GetPlayer(src)

    if not player then
        return cb(nil)
    end

    local prescriptions = {}

    for index, item in pairs(Inventory.GetItems(src)) do
        local info = item and (item.info or item.metadata)

        if item and item.name == 'plt_prescription' and info then
            local entry = {}

            for key, value in pairs(info) do
                entry[key] = value
            end

            entry.slot = item.slot or index

            table.insert(prescriptions, entry)
        end
    end

    cb({
        items = Config.Pharmacy.Items,
        cash = player.functions.GetMoney('cash'),
        hasInsurance = hasInsurance(src),
        insuranceCost = Config.Pharmacy.Insurance.Price,
        insuranceDiscount = Config.Pharmacy.Insurance.Discount,
        isEMS = exports.plt_ambulance_job:IsEMS(src),
        prescriptions = prescriptions
    })
end)

Core.CreateCallback('amb_server:getPlayerData', function(_, cb, targetSrc)
    local target = Core.GetPlayer(targetSrc)

    if target then
        cb({ name = target.name })
    else
        cb(nil)
    end
end)

Core.CreateCallback('amb_server:checkPrescription', function(src, cb)
    local player = Core.GetPlayer(src)

    if not player then
        return cb(nil)
    end

    for _, item in pairs(Inventory.GetItems(src)) do
        if item.name == 'plt_prescription' then
            local info = item.info or item.metadata

            if info then
                return cb(info)
            end
        end
    end

    cb(nil)
end)

RegisterNetEvent('amb_server:buyInsurance', function(_, linkedJob)
    local src = source
    local player = Core.GetPlayer(src)

    if not player then
        return
    end

    if Config.Debug then
        print(('[PHARMACY] buyInsurance event from %s'):format(tostring(src)))
    end

    local function refreshClient()
        TriggerClientEvent('amb_client:updateInsuranceStatus', src, hasInsurance(src))
        TriggerClientEvent('amb_client:updatePharmacyCash', src, player.functions.GetMoney('cash'))
        TriggerClientEvent('amb_client:refreshPharmacyData', src)
    end

    if hasInsurance(src) then
        Core.Notify(src, 'You already have medical insurance.', 'info')
        refreshClient()
        return
    end

    local price = tonumber(Config.Pharmacy and Config.Pharmacy.Insurance and Config.Pharmacy.Insurance.Price) or 0

    if price <= 0 then
        Core.Notify(src, 'Insurance is not configured correctly.', 'error')
        refreshClient()
        return
    end

    if not player.functions.RemoveMoney('cash', price, 'medical-insurance') then
        Core.Notify(src, _L('not_enough_cash'), 'error')
        refreshClient()
        return
    end

    local insuranceValue = (linkedJob and tostring(linkedJob) ~= '' and linkedJob) or true

    Core.SetMetaData(src, 'medical_insurance', insuranceValue)
    Core.Notify(src, _L('insurance_purchased'), 'success')
    refreshClient()

    if Core.Type == 'esx' then
        local storedValue = 1

        if type(insuranceValue) == 'string' and insuranceValue ~= '' then
            storedValue = insuranceValue
        end

        local identifier = player.identifier or player.citizenid

        if identifier then
            pcall(function()
                MySQL.Sync.execute('UPDATE users SET medical_insurance = ? WHERE identifier = ?', {
                    storedValue,
                    identifier
                })
            end)
        end
    end

    local jobName = (type(linkedJob) == 'string' and linkedJob ~= '' and linkedJob) or getDefaultEmsJob()

    if type(AddFinanceEntry) == 'function' then
        AddFinanceEntry(jobName, 'deposit', price, 'Insurance Purchase: ' .. player.name, 'PHARMACY')
    end
end)

RegisterNetEvent('amb_server:purchasePharmacyItem', function(data)
    local src = source
    local player = Core.GetPlayer(src)

    if not player then
        return
    end

    if type(data) ~= 'table' or type(data.item) ~= 'string' then
        return
    end

    local itemName = data.item
    local quantity = tonumber(data.quantity) or 1
    local prescriptionSlots = data.prescriptionSlots or {}
    local prescription = data.prescription

    if quantity < 1 then
        quantity = 1
    end

    local configItem = nil

    for _, entry in ipairs(Config.Pharmacy.Items) do
        if entry.name:lower() == itemName:lower() then
            configItem = entry
            break
        end
    end

    if not configItem then
        Core.Notify(src, _L('item_not_found'), 'error')
        return
    end

    local unitPrice = configItem.price

    if hasInsurance(src) and not configItem.professionalOnly then
        unitPrice = math.floor(unitPrice * Config.Pharmacy.Insurance.Discount)
    end

    local totalPrice = unitPrice * quantity
    local isEMS = exports.plt_ambulance_job:IsEMS(src)

    if configItem.professionalOnly and not isEMS then
        Core.Notify(src, _L('authorized_only_bang'), 'error')
        return
    end

    if configItem.prescriptionRequired or #prescriptionSlots > 0 then
        if not isEMS then
            local requiredPrescriptions = configItem.prescriptionRequired and quantity or #prescriptionSlots

            if configItem.prescriptionRequired and requiredPrescriptions > #prescriptionSlots then
                Core.Notify(src, _L('not_enough_prescriptions'), 'error')
                return
            end

            for index = 1, math.min(#prescriptionSlots, quantity) do
                local slot = prescriptionSlots[index]

                if slot then
                    Inventory.RemoveItem(src, 'plt_prescription', 1, slot)
                end
            end
        end
    elseif prescription then
        local prescribedItem = tostring(prescription.item or ''):lower():gsub('%s+', '')
        local requestedItem = tostring(itemName or ''):lower():gsub('%s+', '')

        if prescribedItem == requestedItem and prescription.slot then
            Inventory.RemoveItem(src, 'plt_prescription', 1, prescription.slot)
        end
    end

    if totalPrice > player.functions.GetMoney('cash') then
        Core.Notify(src, _L('not_enough_cash'), 'error')
        return
    end

    if not player.functions.RemoveMoney('cash', totalPrice, 'pharmacy-purchase') then
        return
    end

    local metadata = {}

    if #prescriptionSlots > 0 then
        for index, item in pairs(Inventory.GetItems(src)) do
            local itemSlot = item.slot or index

            if item.name == 'plt_prescription' and itemSlot == prescriptionSlots[1] then
                local info = item.info or item.metadata

                if info and info.duration then
                    metadata.duration = tonumber(info.duration)
                end

                break
            end
        end
    end

    if Config.Debug then
        print(('[PHARMACY] Adding %s with duration metadata: %s'):format(itemName, tostring(metadata.duration)))
    end

    Inventory.AddItem(src, itemName, quantity, metadata)

    local quantitySuffix = quantity > 1 and (' x' .. quantity) or ''

    Core.Notify(src, _L('purchase_successful', {
        label = configItem.label,
        qty = quantitySuffix
    }), 'success')

    TriggerClientEvent('amb_client:updatePharmacyCash', src, player.functions.GetMoney('cash'))
    TriggerClientEvent('amb_client:refreshPharmacyData', src)

    local jobName = data.linkedJob or getDefaultEmsJob()

    AddFinanceEntry(jobName, 'deposit', totalPrice,
        'Pharmacy Sale: ' .. configItem.label .. quantitySuffix .. ' (' .. player.name .. ')', 'PHARMACY')
end)

RegisterNetEvent('amb_server:issuePrescription', function(data)
    local src = source
    local player = Core.GetPlayer(src)

    if not player then
        return
    end

    if not exports.plt_ambulance_job:IsEMS(src) then
        return
    end

    local targetSrc = data.targetSrc
    local target = Core.GetPlayer(targetSrc)

    if not target then
        return
    end

    local prescription = {
        item = data.item,
        itemLabel = data.itemLabel,
        quantity = data.quantity or 1,
        patientName = target.name,
        doctorName = player.name,
        doctorDept = player.job.label or 'Medical Services',
        notes = data.notes,
        duration = tonumber(data.duration) or 10,
        issuedAt = os.date('%Y-%m-%d %H:%M:%S')
    }

    Inventory.AddItem(targetSrc, 'plt_prescription', 1, prescription)

    Core.Notify(src, _L('prescription_issued_to', { name = target.name }), 'success')
    Core.Notify(targetSrc, _L('prescription_received'), 'info')
end)

RegisterNetEvent('amb_server:issueCertificate', function(data)
    local src = source
    local player = Core.GetPlayer(src)

    if not player then
        return
    end

    if not exports.plt_ambulance_job:IsEMS(src) then
        Core.Notify(src, _L('authorized_only_bang'), 'error')
        return
    end

    local payload = (type(data) == 'table' and data) or {}

    local title = tostring(payload.title or ''):sub(1, 80)
    local details = tostring(payload.details or ''):sub(1, 700)
    local signature = tostring(payload.signatureData or '')

    if title == '' then
        Core.Notify(src, _L('ems_certificate_title_required'), 'error')
        return
    end

    if details == '' then
        Core.Notify(src, _L('ems_certificate_details_required'), 'error')
        return
    end

    if signature == '' then
        Core.Notify(src, _L('ems_certificate_signature_required'), 'error')
        return
    end

    if #signature > 120000 then
        Core.Notify(src, _L('ems_certificate_signature_too_large'), 'error')
        return
    end

    local certificate = {
        title = title,
        details = details,
        patientName = player.name,
        doctorName = player.name,
        doctorDept = (player.job and player.job.label) or 'Medical Services',
        signatureImage = signature,
        issuedAt = os.date('%Y-%m-%d %H:%M:%S')
    }

    if not Inventory.AddItem(src, 'plt_ems_certificate', 1, certificate) then
        Core.Notify(src, _L('cannot_carry_this_much'), 'error')
        return
    end

    Core.Notify(src, _L('ems_certificate_issued_self'), 'success')
end)

Core.CreateUseableItem('plt_prescription', function(src, item)
    local info

    if Bridge.Inventory == 'ox' or Bridge.Inventory == 'core' then
        info = item.metadata
    else
        info = item.info or item.metadata
    end

    if info then
        TriggerClientEvent('amb_client:viewPrescription', src, info)
    end
end)

Core.CreateUseableItem('plt_ems_certificate', function(src, item)
    local info

    if item then
        if Bridge.Inventory == 'ox' or Bridge.Inventory == 'core' then
            info = item.metadata
        else
            info = item.info or item.metadata
        end
    end

    if not info then
        info = findCertificateData(src, item and item.slot or nil)
    end

    if info then
        TriggerClientEvent('amb_client:viewCertificate', src, info)
    end
end)

