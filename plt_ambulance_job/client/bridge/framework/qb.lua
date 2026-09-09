if Bridge.Framework ~= 'qb-core' and Bridge.Framework ~= 'qb_core' then return end

local Core
local lastError

for attempt = 1, 200 do
    local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)

    if ok and type(obj) == 'table' then
        Core = obj
        break
    end

    lastError = ok and ('returned ' .. type(obj)) or tostring(obj)

    if attempt == 1 then
        print(('^3[plt_ambulance] qb-core GetCoreObject not ready yet (state=%s): %s^7')
            :format(GetResourceState('qb-core'), lastError))
    end

    Wait(50)
end

if not Core then
    print(('^1[plt_ambulance] qb-core did not answer GetCoreObject after 10s (state=%s). Last error: %s^7')
        :format(GetResourceState('qb-core'), tostring(lastError)))

    TriggerEvent('QBCore:GetObject', function(obj)
        Core = obj
    end)

    for _ = 1, 100 do
        if type(Core) == 'table' then break end
        Wait(50)
    end

    if type(Core) ~= 'table' then
        print('^1[plt_ambulance] QBCore:GetObject fallback also failed; framework bridge disabled.^7')
        return
    end

    print('^2[plt_ambulance] Recovered core object via QBCore:GetObject fallback.^7')
end
Framework.Core = Core
Framework.Resource = 'qb-core'
Framework.PlayerLoadedEvent = 'QBCore:Client:OnPlayerLoaded'
Framework.JobUpdateEvent = 'QBCore:Client:OnJobUpdate'
Framework.PlayerDataEvents = { 'QBCore:Player:SetPlayerData', 'QBCore:Client:OnPlayerUpdated' }

function Framework.IsPlayerLoaded()
    local data = Core.Functions.GetPlayerData()
    return data and data.citizenid ~= nil
end

function Framework.GetPlayerData()
    local data = Core.Functions.GetPlayerData()
    if not data or not data.job then return nil end
    local charinfo = data.charinfo or {}
    local grade = data.job.grade or {}
    return {
        citizenid = data.citizenid,
        name = ((charinfo.firstname or '') .. ' ' .. (charinfo.lastname or '')):gsub('^%s*(.-)%s*$', '%1'),
        charinfo = charinfo,
        job = {
            name = data.job.name,
            label = data.job.label,
            grade = type(grade) == 'table' and grade.level or grade,
            gradeLabel = type(grade) == 'table' and grade.name or nil,
            onduty = data.job.onduty,
            dept = data.job.dept
        },
        money = data.money
    }
end

function Framework.TriggerCallback(name, cb, ...)
    local callback = cb
    if type(cb) == 'function' then
        callback = function(...)
            local ok, err = pcall(cb, ...)
            if not ok then
                print(("[plt_ambulance] Callback '%s' handler failed: %s"):format(tostring(name), tostring(err)))
            end
        end
    end
    Core.Functions.TriggerCallback(name, callback, ...)
end

function Framework.SetVehicleProperties(vehicle, properties)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or type(properties) ~= 'table' then return false end
    local ok, result = pcall(Core.Functions.SetVehicleProperties, vehicle, properties)
    if not ok then
        print(("[plt_ambulance] SetVehicleProperties failed: %s"):format(tostring(result)))
        return false
    end
    return result
end

function Framework.GetPlate(vehicle)
    return Core.Functions.GetPlate(vehicle)
end

function Framework.GetClosestPlayer()
    return Core.Functions.GetClosestPlayer()
end

function Framework.GetClosestVehicle(coords)
    return Core.Functions.GetClosestVehicle(coords)
end

function Framework.ShowTextUI(message)
    TriggerEvent('qb-core:client:DrawText', message, 'right')
end

function Framework.HideTextUI()
    TriggerEvent('qb-core:client:HideText')
end

function Framework.Progressbar(name, label, duration, useWhileDead, canCancel, disableControls, animation, prop, propTwo, onFinish, onCancel)
    Core.Functions.Progressbar(name, label, duration, useWhileDead, canCancel, disableControls, animation, prop, propTwo, onFinish, onCancel)
end

