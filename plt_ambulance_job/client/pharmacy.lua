local pharmacyOpen = false

RegisterNetEvent('amb_client:openPharmacy', function(data)
    if pharmacyOpen then
        return
    end

    local linkedJob = (type(data) == 'table' and data.jobName) or data

    Framework.TriggerCallback('amb_server:getPharmacyData', function(pharmacyData)
        if not pharmacyData then
            return
        end

        pharmacyOpen = true

        SetNuiFocus(true, true)

        pharmacyData.linkedJob = linkedJob

        SendNUIMessage({
            action = 'amb_openPharmacy',
            data = pharmacyData
        })
    end)
end)

RegisterNUICallback('closePharmacy', function(_, cb)
    pharmacyOpen = false

    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('luaLog', function(data, cb)
    if Config.Debug and data and data.message then
        print('^5[PHARMACY UI] ' .. tostring(data.message) .. '^7')
    end

    cb('ok')
end)

RegisterNUICallback('pharmacyBuyItem', function(data, cb)
    TriggerServerEvent('amb_server:purchasePharmacyItem', data)
    cb('ok')
end)

RegisterNUICallback('buyInsurance', function(data, cb)
    if Config.Debug then
        print('^3[PHARMACY]^7 buyInsurance callback received from NUI')
    end

    local linkedJob = data and data.linkedJob or nil

    TriggerServerEvent('amb_server:buyInsurance', nil, linkedJob)
    cb('ok')
end)

RegisterNUICallback('checkPrescription', function(_, cb)
    Framework.TriggerCallback('amb_server:checkPrescription', function(result)
        cb(result)
    end)
end)

RegisterNetEvent('amb_client:updateInsuranceStatus', function(hasInsurance)
    SendNUIMessage({
        action = 'amb_updateInsuranceStatus',
        hasInsurance = hasInsurance
    })
end)

RegisterNetEvent('amb_client:updatePharmacyCash', function(cash)
    SendNUIMessage({
        action = 'amb_updatePharmacyCash',
        cash = cash
    })
end)

RegisterNetEvent('amb_client:refreshPharmacyData', function()
    if not pharmacyOpen then
        return
    end

    Framework.TriggerCallback('amb_server:getPharmacyData', function(pharmacyData)
        if not pharmacyData then
            return
        end

        SendNUIMessage({
            action = 'amb_refreshPharmacyData',
            data = pharmacyData
        })
    end)
end)

RegisterNetEvent('amb_client:viewPrescription', function(prescription)
    SetNuiFocus(true, true)

    SendNUIMessage({
        action = 'amb_viewPrescription',
        data = prescription
    })
end)

RegisterNUICallback('closePrescriptionViewer', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterCommand('emscertificate', function()
    if not exports.plt_ambulance_job:IsEMS() then
        Framework.Notify(_L('authorized_only_bang'), 'error')
        return
    end

    local playerData = Framework.GetPlayerData() or {}
    local staffName = playerData.name or GetPlayerName(PlayerId()) or 'EMS Staff'
    local department = (playerData.job and playerData.job.label) or 'Medical Services'

    SetNuiFocus(true, true)

    SendNUIMessage({
        action = 'amb_openCertificateEditor',
        data = {
            patientName = staffName,
            doctorName = staffName,
            doctorDept = department
        }
    })
end, false)

RegisterNUICallback('submitEMSCertificate', function(data, cb)
    TriggerServerEvent('amb_server:issueCertificate', data or {})
    cb('ok')
end)

RegisterNUICallback('closeCertificateViewer', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNetEvent('amb_client:viewCertificate', function(certificate)
    SetNuiFocus(true, true)

    SendNUIMessage({
        action = 'amb_viewCertificate',
        data = certificate
    })
end)

RegisterNUICallback('openPrescriptionWriter', function(_, cb)
    local targetSrc = GetTargetPlayerId()

    if targetSrc then
        Framework.TriggerCallback('amb_server:getPlayerData', function(targetData)
            if not targetData then
                return
            end

            SendNUIMessage({
                action = 'amb_setPrescriptionWriter',
                patientName = targetData.name,
                targetSrc = targetSrc
            })
        end, targetSrc)
    end

    cb('ok')
end)

RegisterNUICallback('issuePrescription', function(data, cb)
    TriggerServerEvent('amb_server:issuePrescription', data)
    cb('ok')
end)

function GetTargetPlayerId()
    return exports.plt_ambulance_job:GetDiagnosisTarget()
end

