local MAX_STORED_CALLS = 100

local activeCalls = {}

local function normalizeCall(callData)
    if type(callData) ~= 'table' then
        return nil
    end

    local call = {}

    for key, value in pairs(callData) do
        call[key] = value
    end

    call.id = call.id or math.random(1000, 9999)
    call.source = call.source or 0
    call.time = call.time or os.date('%H:%M')
    call.code = call.code or '10-52'
    call.title = call.title or 'Medical Alert'
    call.location = call.location or call.locationName or 'Unknown Location'
    call.info = call.info or call.type or ''
    call.claimedBy = nil
    call.claimedName = nil
    call.status = 'open'

    local coords = call.coords

    if type(coords) == 'vector3' then
        call.coords = { x = coords.x, y = coords.y, z = coords.z }
    elseif type(coords) == 'table' then
        call.coords = {
            x = tonumber(coords.x or coords[1]) or 0.0,
            y = tonumber(coords.y or coords[2]) or 0.0,
            z = tonumber(coords.z or coords[3]) or 0.0
        }
    else
        call.coords = { x = 0.0, y = 0.0, z = 0.0 }
    end

    return call
end

local function storeCall(call)
    table.insert(activeCalls, 1, call)

    if #activeCalls > MAX_STORED_CALLS then
        table.remove(activeCalls)
    end
end

local function findCall(callId)
    if callId == nil then
        return nil
    end

    local wanted = tostring(callId)

    for _, call in ipairs(activeCalls) do
        if tostring(call.id) == wanted then
            return call
        end
    end

    return nil
end

-- activeCalls[1] is the newest; scan from the end for the oldest open call so
-- `/yes` with no id grabs the call that has been waiting the longest.
local function findOldestOpenCall()
    for index = #activeCalls, 1, -1 do
        local call = activeCalls[index]

        if not call.claimedBy and call.status == 'open' then
            return call
        end
    end

    return nil
end

local function getPlayerLabel(playerId)
    local player = Framework.GetPlayer(playerId)

    if not player then
        return _L('dispatch_unknown_medic')
    end

    -- Framework.GetPlayer returns a normalized table, not an xPlayer.
    if player.name and tostring(player.name) ~= '' then
        return tostring(player.name)
    end

    local raw = GetPlayerName(src)

    if raw and tostring(raw) ~= '' then
        return tostring(raw)
    end

    return _L('dispatch_unknown_medic')
end

local function isEmsOnDuty(playerId)
    local player = Framework.GetPlayer(playerId)
    local job = player and player.job
    local jobName = job and job.name

    if not jobName then
        return false
    end

    if job.onduty == false or job.onduty == 0 then
        return false
    end

    for _, emsJob in ipairs(Config.Medical and Config.Medical.EMSJobs or {}) do
        if tostring(jobName) == tostring(emsJob) then
            return true
        end
    end

    for _, node in ipairs(DepartmentData and DepartmentData.nodes or {}) do
        if node.type == 'department' then
            local departmentJob = (node.frameworkJob and node.frameworkJob ~= '' and node.frameworkJob) or node.id

            if tostring(jobName) == tostring(departmentJob) or tostring(jobName) == tostring(node.id) then
                return true
            end
        end
    end

    return false
end

-- Every on-duty EMS member receives this. Declared after isEmsOnDuty on
-- purpose: as a `local function` further down, referencing it earlier would
-- have captured nothing and every broadcast would have gone nowhere., used to keep the "who is responding"
-- state identical on every client.
local function broadcastToEms(eventName, ...)
    for _, playerId in ipairs(Framework.GetPlayers()) do
        local id = tonumber(playerId)

        if id and isEmsOnDuty(id) then
            TriggerClientEvent(eventName, id, ...)
        end
    end
end

local function dispatchCall(callData, src)
    src = tonumber(src) or 0

    if Config.Debug then
        print('^2[Dispatch]^7 Received dispatch call from source: ' .. tostring(src))
    end

    if type(callData) ~= 'table' then
        print('^1[Dispatch Error]^7 Invalid callData received from ' .. tostring(src))
        return false
    end

    callData.source = callData.source or src

    local call = normalizeCall(callData)

    if not call then
        return false
    end

    storeCall(call)

    local players = Framework.GetPlayers()
    local notified = 0

    if Config.Debug then
        print('^2[Dispatch]^7 Checking ' .. #players .. ' online players for EMS jobs...')
    end

    for _, playerId in ipairs(players) do
        local id = tonumber(playerId)

        if id and isEmsOnDuty(id) then
            TriggerClientEvent('amb_client:addDispatchCall', id, call)
            TriggerClientEvent('plt_mdt_ems:client:newDispatchCall', id, call)

            -- The dispatch panel is closed by default, so pushing the call into
            -- the NUI list alone is invisible. Send an actual notification too.
            Framework.Notify(id, _L('dispatch_call_received', {
                title = call.title,
                location = call.location
            }), 'error')

            notified = notified + 1
        end
    end

    if Config.Debug then
        print('^2[Dispatch]^7 Result: Call distributed to ' .. notified .. ' EMS members.')
    end

    if notified == 0 and src > 0 then
        Framework.Notify(src, _L('dispatch_no_ems_available'), 'error')
    end

    return true
end

--[[
    ------------------------------------------------------------
    Claiming a call
    ------------------------------------------------------------
    A call may be accepted by exactly ONE medic. The first one to accept owns
    it; everyone else is told it is already taken and gets no blip. Ownership is
    authoritative on the server so two medics cannot race for the same call.
]]
local function claimDispatchCall(src, callId)
    src = tonumber(src) or 0

    if src <= 0 then
        return false, 'invalid'
    end

    if not IsEMS(src) then
        return false, 'unauthorized'
    end

    local call = findCall(callId)

    -- `/yes` sends no id: take the oldest still-open call.
    if not call and callId == nil then
        call = findOldestOpenCall()
    end

    if not call then
        return false, 'notfound'
    end

    if call.claimedBy and call.claimedBy ~= src then
        -- Already taken: say who owns it, but do NOT hand over the call -
        -- that medic gets no blip and no patient handle.
        return false, 'taken', call.claimedName, nil
    end

    local alreadyMine = call.claimedBy == src

    call.claimedBy = src
    call.claimedName = getPlayerLabel(src)
    call.status = 'claimed'

    if Config.Debug then
        print('^2[Dispatch]^7 Call ' .. tostring(call.id) .. ' claimed by ' .. src .. ' (' .. tostring(call.claimedName) .. ')')
    end

    -- Tell every other medic the call is off the board, and give the claimant
    -- the live patient handle to blip.
    broadcastToEms('amb_client:dispatchCallClaimed', call.id, src, call.claimedName, call)

    if src > 0 then
        local patient = tonumber(call.source) or 0

        if patient > 0 and patient ~= src and not alreadyMine then
            Framework.Notify(patient, _L('dispatch_medic_on_way', {
                name = call.claimedName
            }), 'success')
        end
    end

    return true, 'claimed', call.claimedName, call
end

local function releaseDispatchCall(src, callId)
    src = tonumber(src) or 0

    local call = findCall(callId)

    if not call then
        return false
    end

    -- Only the owner (or an admin) can hand a call back.
    if call.claimedBy and call.claimedBy ~= src and not Framework.HasPermission(src, Config.Permission) then
        return false
    end

    call.claimedBy = nil
    call.claimedName = nil
    call.status = 'open'

    broadcastToEms('amb_client:dispatchCallReleased', call.id)

    return true
end

local function completeDispatchCall(src, callId)
    src = tonumber(src) or 0

    local call = findCall(callId)

    if not call then
        return false
    end

    if call.claimedBy and call.claimedBy ~= src then
        return false
    end

    call.status = 'completed'

    broadcastToEms('amb_client:dispatchCallCompleted', call.id, call)

    return true
end

RegisterNetEvent('amb_server:claimDispatchCall', function(callId)
    local src = source

    local ok, reason, extra, extra2 = claimDispatchCall(src, callId)

    -- `/yes` sends no id; report back the id of the call actually claimed.
    local claimedId = (type(extra2) == 'table' and extra2.id) or callId

    TriggerClientEvent('amb_client:dispatchClaimResult', src, ok, reason, claimedId, extra, extra2)
end)

RegisterNetEvent('amb_server:releaseDispatchCall', function(callId)
    releaseDispatchCall(source, callId)
end)

RegisterNetEvent('amb_server:completeDispatchCall', function(callId)
    completeDispatchCall(source, callId)
end)

-- Patient is back up: the call is finished, drop every claim and blip.
RegisterNetEvent('amb_server:dispatchPatientRecovered', function()
    local src = source

    for index = #activeCalls, 1, -1 do
        local call = activeCalls[index]

        if tonumber(call.source) == src then
            broadcastToEms('amb_client:dispatchCallCompleted', call.id, call)
            table.remove(activeCalls, index)

            if Config.Debug then
                print('^2[Dispatch]^7 Call ' .. tostring(call.id) .. ' closed - patient recovered.')
            end
        end
    end
end)

-- A medic who disconnects must not keep a call hostage.
AddEventHandler('playerDropped', function()
    local src = tonumber(source) or 0

    for _, call in ipairs(activeCalls) do
        if call.claimedBy == src then
            call.claimedBy = nil
            call.claimedName = nil
            call.status = 'open'

            broadcastToEms('amb_client:dispatchCallReleased', call.id)
        end
    end
end)

RegisterNetEvent('amb_server:sendDispatchCall', function(callData)
    -- A finished player cannot file new dispatch calls.
    if exports.plt_ambulance_job:IsPlayerFinished(source) then
        Framework.Notify(source, _L('player_finished_other'), 'error')
        return
    end

    dispatchCall(callData, source)
end)

-- Mercy system: close every open call filed by this patient (they are finished
-- and nobody can be revived any more), so medics' blips/routes disappear.
exports('ClosePatientCalls', function(src)
    src = tonumber(src) or 0

    for index = #activeCalls, 1, -1 do
        local call = activeCalls[index]

        if tonumber(call.source) == src then
            broadcastToEms('amb_client:dispatchCallCompleted', call.id, call)
            table.remove(activeCalls, index)
        end
    end
end)

exports('ClaimDispatchCall', function(src, callId)
    return claimDispatchCall(src, callId)
end)

exports('GetClaimedDispatchCall', function(src)
    src = tonumber(src) or 0

    for _, call in ipairs(activeCalls) do
        if call.claimedBy == src then
            return call
        end
    end

    return nil
end)

exports('SendExternalDispatch', function(callData, src)
    return dispatchCall(callData, src or 0)
end)

exports('GetActiveDispatchCalls', function()
    return activeCalls
end)

