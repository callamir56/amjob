local function hasPermission(src)
    if src == 0 then
        return true
    end

    local allowed = Framework.HasPermission(src, Config.Permission)

    if not allowed then
        allowed = exports.plt_ambulance_job:IsEMS(src)
    end

    return allowed
end

RegisterNetEvent('amb_server:compat:resetVitals', function()
    local src = source

    if not src then
        return
    end

    Framework.SetMetaData(src, 'hunger', 100)
    Framework.SetMetaData(src, 'thirst', 100)
    Framework.SetMetaData(src, 'stress', 0)
end)

RegisterNetEvent('amb_server:compat:sedateTarget', function(targetId)
    local src = source

    targetId = tonumber(targetId)

    if not targetId then
        return
    end

    if not hasPermission(src) then
        return
    end

    TriggerClientEvent('amb_client:compat:applySedative', targetId)
end)

RegisterNetEvent('amb_server:compat:placeInVehicle', function(targetId, vehicleNetId, seat)
    local src = source

    targetId = tonumber(targetId)
    seat = tonumber(seat)

    if not (targetId and vehicleNetId) or seat == nil then
        return
    end

    if not hasPermission(src) then
        return
    end

    TriggerClientEvent('amb_client:compat:warpIntoVehicle', targetId, vehicleNetId, seat)
end)

RegisterNetEvent('amb_server:compat:loadOnStretcher', function(targetId, stretcherNetId)
    local src = source

    targetId = tonumber(targetId)

    if not targetId or not stretcherNetId then
        return
    end

    if not hasPermission(src) then
        return
    end

    TriggerClientEvent('amb_client:compat:loadOnStretcher', targetId, stretcherNetId)
end)

exports('RevivePlayer', function(targetId)
    targetId = tonumber(targetId)

    if not targetId then
        return false
    end

    exports.plt_ambulance_job:InternalRevive(targetId)

    return true
end)

exports('disableKnockoutLoop', function(targetId, disabled)
    targetId = tonumber(targetId)

    if not targetId then
        return false
    end

    TriggerClientEvent('amb_client:compat:setKnockoutDisabled', targetId, disabled == true)

    return true
end)

exports('manuallyKnockout', function(targetId, knockedOut)
    targetId = tonumber(targetId)

    if not targetId then
        return false
    end

    local isKnockedOut = knockedOut == true

    TriggerClientEvent('amb_client:compat:manualKnockout', targetId, isKnockedOut)

    if not isKnockedOut then
        exports.plt_ambulance_job:InternalRevive(targetId)
    end

    return true
end)

