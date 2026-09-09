RegisterNetEvent('amb_server:bleedOut', function()
    local src = source

    if Framework.HasAuthoritativeMedicalState() then
        local state, deadSince = Framework.GetMedicalState(src)

        if not state then
            return
        end

        deadSince = tonumber(deadSince) or 0

        local deathTimer = math.max(0, tonumber(Config.Health and Config.Health.DeathTimer) or 300)
        local elapsed = deadSince > 0 and math.max(0, os.time() - deadSince) or 0

        if state == Framework.MedicalState.DEAD then
            Framework.Notify(src, _L('bled_out'), 'error')
            return
        end

        if state ~= Framework.MedicalState.LASTSTAND or deathTimer > elapsed then
            return
        end

        exports.plt_ambulance_job:SetMedicalState(src, Framework.MedicalState.DEAD, deadSince)
    else
        Framework.SetDeathStatus(src, true)
    end

    Framework.Notify(src, _L('bled_out'), 'error')
end)

local function clearInventory(src)
    return (Inventory and Inventory.Clear and Inventory.Clear(src)) or false
end

RegisterNetEvent('amb_server:clearInventoryOnHospitalRespawn', function()
    local src = source

    if not (Config.Health and Config.Health.ClearInventoryOnHospitalRespawn == true) then
        return
    end

    clearInventory(src)
end)

