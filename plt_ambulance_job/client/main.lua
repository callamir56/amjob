local blips = {}
local interactionZones = {}
local vehicleDeletePoints = {}
local civilianClothes = nil
local pharmacyZones = {}
local checkInZones = {}
local doctorPeds = {}
local spawnedPeds = {}
local targetZones = {}
local spawnedProps = {}
local propData = {}
local xrayPanels = {}
local deletePointDistance = 10.0
local monitorPower = {}
local isOnBed = false
local bedAnim = nil
local zoneVersion = 0
local dutySwipePromise = nil

local INTERIOR_SPAWN = {
    coords = vector3(687.44, 1494.29, 208.02),
    heading = nil
}

local checkInData = {}

local function openDutySwipe(jobName)
    if dutySwipePromise then
        return false
    end

    local playerData = Framework.GetPlayerData()
    local onDuty = playerData and playerData.job and playerData.job.onduty == true
    local nextState = onDuty and 'off' or 'on'

    dutySwipePromise = promise.new()

    SetNuiFocus(true, true)

    SendNUIMessage({
        action = 'amb_openDutySwipe',
        job = jobName,
        nextState = nextState
    })

    local result = Citizen.Await(dutySwipePromise)

    dutySwipePromise = nil

    return result == true
end

local function clearTargetEntities()
    for _, entity in pairs(spawnedPeds) do
        if type(entity) == 'number' and DoesEntityExist(entity) then
            if Target then
                Target.RemoveLocalEntity(entity)
            end

            DeleteEntity(entity)
        end
    end

    spawnedPeds = {}

    if Target then
        for _, zone in pairs(targetZones) do
            Target.RemoveZone(zone)
        end
    end

    targetZones = {}
end

local function nextZoneVersion()
    zoneVersion = zoneVersion + 1

    return zoneVersion
end

local function isCurrentZoneVersion(version)
    return version == zoneVersion
end

local function clearSpawnedProps()
    for _, prop in pairs(spawnedProps) do
        if DoesEntityExist(prop) then
            if Target then
                Target.RemoveLocalEntity(prop)
            end

            SetEntityAsMissionEntity(prop, true, true)
            DeleteObject(prop)
            DeleteEntity(prop)
        end
    end

    spawnedProps = {}
    propData = {}

    for _, panelId in pairs(xrayPanels) do
        TriggerEvent('plt_xray:client:destroyPanel', panelId)
    end

    xrayPanels = {}
    monitorPower = {}
end

local function createXrayPanel(entity, panelId, panelData)
    if not DoesEntityExist(entity) then
        return
    end

    if GetResourceState('plt_xray') == 'started' then
        TriggerEvent('plt_xray:client:createMonitorPanel', entity, panelId, panelData)
    elseif Config.Debug then
        print('^3[plt_ambulance] plt_xray not started yet; monitor panel queued for refresh.^7')
    end
end

local function getCivilianClothesKey()
    local playerData = Framework.GetPlayerData()
    local identifier = playerData and (playerData.citizenid or playerData.identifier or playerData.license)

    if not identifier then
        identifier = GetPlayerServerId(PlayerId())
    end

    return ('plt_amb_civilian_clothes_%s'):format(tostring(identifier))
end

local function saveCivilianClothes()
    local ped = PlayerPedId()

    civilianClothes = {}

    for component = 0, 11 do
        civilianClothes[component] = {
            drawable = GetPedDrawableVariation(ped, component),
            texture = GetPedTextureVariation(ped, component),
            palette = GetPedPaletteVariation(ped, component)
        }
    end

    civilianClothes.props = {}

    for propIndex = 0, 7 do
        civilianClothes.props[propIndex] = {
            drawable = GetPedPropIndex(ped, propIndex),
            texture = GetPedPropTextureIndex(ped, propIndex)
        }
    end

    local key = getCivilianClothesKey()
    local encoded = json.encode(civilianClothes)

    if key and encoded then
        pcall(function()
            SetResourceKvp(key, encoded)
        end)
    end
end

local function reloadFrameworkSkin()
    if GetResourceState('qb-clothing') == 'started' then
        TriggerEvent('qb-clothing:client:loadPlayerSkin')
        return true
    end

    if GetResourceState('illenium-appearance') == 'started' then
        TriggerEvent('illenium-appearance:client:reloadSkin')
        return true
    end

    if GetResourceState('origen_clothing') == 'started' then
        TriggerEvent('origen_clothing:client:reloadSkin')
        return true
    end

    if GetResourceState('rclothing') == 'started' then
        TriggerEvent('rclothing:client:reloadSkin')
        return true
    end

    if GetResourceState('esx_skin') == 'started' then
        TriggerEvent('esx_skin:getPlayerSkin', function(skin)
            TriggerEvent('skinchanger:loadSkin', skin)
        end)

        return true
    end

    return false
end

local function restoreCivilianClothes()
    local ped = PlayerPedId()

    if not civilianClothes then
        local key = getCivilianClothesKey()
        local stored = nil

        if key then
            local raw = nil

            pcall(function()
                raw = GetResourceKvpString(key)
            end)

            if raw and raw ~= '' then
                local ok, decoded = pcall(json.decode, raw)

                if ok and type(decoded) == 'table' then
                    stored = decoded
                end
            end
        end

        civilianClothes = stored

        if not civilianClothes then
            reloadFrameworkSkin()
            return
        end
    end

    for component = 0, 11 do
        local variation = civilianClothes[component]

        if variation then
            SetPedComponentVariation(ped, component, variation.drawable, variation.texture, variation.palette)
        end
    end

    for propIndex = 0, 7 do
        local prop = civilianClothes.props[propIndex]

        if prop then
            if prop.drawable == -1 then
                ClearPedProp(ped, propIndex)
            else
                SetPedPropIndex(ped, propIndex, prop.drawable, prop.texture, true)
            end
        end
    end

    civilianClothes = nil

    local key = getCivilianClothesKey()

    if key then
        pcall(function()
            DeleteResourceKvp(key)
        end)
    end
end

local function applyWardrobeOutfit(wardrobeId)
    if not (DepartmentData and DepartmentData.nodes) then
        return false
    end

    local wardrobe = nil

    for _, node in ipairs(DepartmentData.nodes) do
        if tostring(node.id) == tostring(wardrobeId) and node.type == 'wardrobe' then
            wardrobe = node
            break
        end
    end

    if not wardrobe or type(wardrobe.outfits) ~= 'table' then
        return false
    end

    local playerData = Framework.GetPlayerData()

    if not playerData or not playerData.job then
        return false
    end

    local grade = tonumber(type(playerData.job.grade) == 'table'
        and playerData.job.grade.level
        or playerData.job.grade) or 0

    local outfit = wardrobe.outfits['rank_' .. tostring(grade)]

    if type(outfit) ~= 'table' then
        return false
    end

    local ped = PlayerPedId()

    if not civilianClothes then
        saveCivilianClothes()
    end

    local function applyComponent(component, entry)
        if type(entry) ~= 'table' then
            return
        end

        local drawable = tonumber(entry.item)

        if drawable == nil then
            return
        end

        SetPedComponentVariation(ped, component, drawable, tonumber(entry.texture) or 0, 0)
    end

    applyComponent(4, outfit.pants)
    applyComponent(11, outfit.shirt)
    applyComponent(9, outfit.vest)
    applyComponent(6, outfit.shoes)

    if type(outfit.hat) == 'table' and outfit.hat.item ~= nil then
        local drawable = tonumber(outfit.hat.item) or -1
        local texture = tonumber(outfit.hat.texture) or 0

        if drawable < 0 then
            ClearPedProp(ped, 0)
        else
            SetPedPropIndex(ped, 0, drawable, texture, true)
        end
    end

    return true
end

RegisterNetEvent('amb_client:Notify', function(message, msgType)
    if not Config.ShowNotifications then
        return
    end

    local title = _L('notify_title_alert')

    if msgType == 'error' then
        title = _L('notify_title_error')
    elseif msgType == 'success' then
        title = _L('notify_title_success')
    elseif msgType == 'primary' or msgType == 'info' then
        title = _L('notify_title_info')
    elseif msgType == 'warning' then
        title = _L('notify_title_warning')
    end

    SendNUIMessage({
        action = 'amb_showNotification',
        title = title,
        message = message
    })
end)

RegisterNetEvent('amb_client:PushLocaleToUI', function(locale)
    SendNUIMessage({
        action = 'amb_setLocale',
        locale = locale or {}
    })
end)

local function pushUISettings()
    SendNUIMessage({
        action = 'amb_setUISettings',
        blurEnabled = Config.EnableBlurEffect ~= false
    })
end

CreateThread(function()
    Wait(500)
    pushUISettings()
end)

DepartmentData = { nodes = {}, links = {} }
MemberData = {}
LocalPlayerJob = { dept = 'none', grade = 0, onDuty = false }

local function getDepartmentFrameworkJob(departmentId)
    if not (DepartmentData and DepartmentData.nodes) then
        return departmentId
    end

    for _, node in ipairs(DepartmentData.nodes) do
        if node.type == 'department' and node.id == departmentId then
            if node.frameworkJob and node.frameworkJob ~= '' then
                return node.frameworkJob
            end

            return departmentId
        end
    end

    return departmentId
end

local function hasDepartmentJob(departmentId)
    if not departmentId then
        return true
    end

    local playerData = Framework.GetPlayerData()

    if not playerData then
        return false
    end

    if IsAdmin and Config.AdminBypass then
        return true
    end

    local jobName = (playerData.job and playerData.job.name) or 'none'
    local citizenId = playerData.citizenid
    local member = MemberData[citizenId]
    local memberJob = (member and member.job) or 'none'
    local frameworkJob = getDepartmentFrameworkJob(departmentId)

    -- A framework EMS job (or EMS department membership) makes the player a
    -- member of the EMS departments in this resource, even when a department
    -- was created under a custom id that was never linked to the framework
    -- job. Without this, a plain `/setjob ambulance` player was told
    -- "This is not your department!" while the boss menu still worked.
    for _, emsJob in ipairs(Config.Medical.EMSJobs) do
        if jobName == emsJob or memberJob == emsJob then
            return true
        end
    end

    if tostring(jobName) == tostring(departmentId)
        or tostring(jobName) == tostring(frameworkJob)
        or tostring(memberJob) == tostring(departmentId) then
        return true
    end

    for _, emsJob in ipairs(Config.Medical.EMSJobs) do
        if jobName == emsJob or memberJob == emsJob then
            if tostring(departmentId) == tostring(emsJob)
                or tostring(frameworkJob) == tostring(emsJob) then
                return true
            end
        end
    end

    return false
end

-- See the note on the server-side IsEMS: the framework job in
-- Config.Medical.EMSJobs is authoritative and no longer requires the
-- department editor to be configured first.
function IsEMS()
    local playerData = Framework.GetPlayerData()

    if not playerData then
        return false
    end

    if IsAdmin and Config.AdminBypass then
        return true
    end

    local jobName = (playerData.job and playerData.job.name) or 'none'
    local citizenId = playerData.citizenid
    local member = MemberData[citizenId]
    local memberJob = (member and member.job) or 'none'

    for _, emsJob in ipairs(Config.Medical.EMSJobs) do
        if jobName == emsJob or memberJob == emsJob then
            return true
        end
    end

    if not (DepartmentData and DepartmentData.nodes) then
        return false
    end

    for _, node in ipairs(DepartmentData.nodes) do
        if node.type == 'department' then
            local frameworkJob = (node.frameworkJob and node.frameworkJob ~= '' and node.frameworkJob) or node.id

            if tostring(jobName) == tostring(node.id)
                or tostring(jobName) == tostring(frameworkJob)
                or tostring(memberJob) == tostring(node.id) then
                return true
            end
        end
    end

    return false
end

exports('IsEMS', IsEMS)
exports('HasDepartmentJob', hasDepartmentJob)

local hasElevatedPermission = false

local function refreshPermissions()
    Framework.TriggerCallback('amb_server:checkPermissions', function(result)
        hasElevatedPermission = result
    end, Config.Permission)
end

local function headingToForward(heading)
    local rad = math.rad(heading)

    return vector3(-math.sin(rad), math.cos(rad), 0.0)
end

local function normalizeVector(vec)
    local length = math.sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)

    if length <= 1.0E-4 then
        return vector3(0.0, 0.0, 0.0)
    end

    return vector3(vec.x / length, vec.y / length, vec.z / length)
end

local function rotateAroundAxis(vec, axis, degrees)
    local rad = math.rad(degrees)
    local cos = math.cos(rad)
    local sin = math.sin(rad)

    local cross = vector3(
        axis.y * vec.z - axis.z * vec.y,
        axis.z * vec.x - axis.x * vec.z,
        axis.x * vec.y - axis.y * vec.x
    )

    local dot = axis.x * vec.x + axis.y * vec.y + axis.z * vec.z

    return vec * cos + cross * sin + axis * dot * (1 - cos)
end

local function getPropAxes(data)
    local forward = normalizeVector(headingToForward(data.h or 0.0))
    local up = vector3(0.0, 0.0, 1.0)
    local pitch = tonumber(data.pitch) or 0.0

    if math.abs(pitch) > 0.001 then
        local right = normalizeVector(vector3(
            forward.y * up.z - forward.z * up.y,
            forward.z * up.x - forward.x * up.z,
            forward.x * up.y - forward.y * up.x
        ))

        forward = normalizeVector(rotateAroundAxis(forward, right, pitch))
        up = normalizeVector(rotateAroundAxis(up, right, pitch))
    end

    return forward, up
end

local PLACEHOLDER_LABELS = {
    'new location',
    'new department',
    'new boss',
    'new vehicle',
    'new armory',
    'new door',
    'new rank',
    'new permission'
}

function GetCleanLabel(label, fallback)
    if not label or label == '' then
        return fallback
    end

    local lowered = label:lower()

    for _, placeholder in ipairs(PLACEHOLDER_LABELS) do
        if lowered:find(placeholder) then
            return fallback
        end
    end

    if lowered == fallback:lower() then
        return fallback
    end

    return label
end

exports('GetFramework', function()
    return Framework
end)

function GetLinkedNodeByType(nodeId, nodeType, graph)
    if not (graph and graph.links and graph.nodes) then
        return nil
    end

    local startId = tostring(nodeId)
    local visited = { [startId] = true }
    local queue = { startId }

    while #queue > 0 do
        local currentId = table.remove(queue, 1)

        for _, link in ipairs(graph.links) do
            local neighbourId = nil

            if tostring(link.to) == currentId then
                neighbourId = tostring(link.from)
            elseif tostring(link.from) == currentId then
                neighbourId = tostring(link.to)
            end

            if neighbourId and not visited[neighbourId] then
                for _, node in ipairs(graph.nodes) do
                    if tostring(node.id) == neighbourId then
                        if node.type == nodeType then
                            return node
                        end

                        visited[neighbourId] = true
                        table.insert(queue, neighbourId)
                        break
                    end
                end
            end
        end
    end

    return nil
end

local permissionTableAllows

function HasPermissionForNode(nodeId, permissionName, graph)
    if hasElevatedPermission and Config.AdminBypass then
        return true
    end

    local departmentId = GetDepartmentForNode(nodeId, graph)

    if not departmentId then
        return true
    end

    local playerData = Framework.GetPlayerData()

    if not playerData then
        return false
    end

    local citizenId = playerData.citizenid
    local jobName = (playerData.job and playerData.job.name) or 'none'
    local grade = tonumber(playerData.job
        and ((type(playerData.job.grade) == 'table' and playerData.job.grade.level) or playerData.job.grade)
        or 0)

    local member = MemberData[citizenId]

    if member and tostring(member.job) == tostring(departmentId) then
        jobName = member.job
        grade = tonumber(member.grade)
    end

    if not hasDepartmentJob(departmentId) then
        return false
    end

    local rankNode = GetLinkedNodeByType(departmentId, 'rank', graph)
    local isBossMenu = permissionName:lower() == 'boss_menu'

    if not rankNode then
        return not isBossMenu
    end

    if isBossMenu then
        local matchedRank = false

        if rankNode.ranks and type(rankNode.ranks) == 'table' then
            for _, rank in ipairs(rankNode.ranks) do
                if tonumber(rank.level) == grade then
                    matchedRank = true

                    if rank.bossMenu == true then
                        return true
                    end

                    break
                end
            end
        end

        if matchedRank then
            return false
        end
    end

    local permissionNode = GetLinkedNodeByType(rankNode.id, 'permission', graph)

    if not permissionNode then
        return not isBossMenu
    end

    local rankKey = 'rank_' .. tostring(grade)

    if permissionNode.rankPerms and type(permissionNode.rankPerms) == 'table' then
        local perms = permissionNode.rankPerms[rankKey]

        if perms and type(perms) == 'table' then
            return permissionTableAllows(perms, permissionName)
        end
    end

    return not isBossMenu
end

function GetDepartmentForNode(nodeId, graph)
    if not (graph and graph.links) then
        return nil
    end

    local startId = tostring(nodeId)

    for _, node in ipairs(graph.nodes) do
        if tostring(node.id) == startId and node.type == 'department' then
            return node.id
        end
    end

    local visited = { [startId] = true }
    local queue = { startId }

    while #queue > 0 do
        local currentId = table.remove(queue, 1)

        for _, link in ipairs(graph.links) do
            local neighbourId = nil

            if tostring(link.to) == currentId then
                neighbourId = tostring(link.from)
            elseif tostring(link.from) == currentId then
                neighbourId = tostring(link.to)
            end

            if neighbourId and not visited[neighbourId] then
                for _, node in ipairs(graph.nodes) do
                    if tostring(node.id) == neighbourId then
                        if node.type == 'department' then
                            return node.id
                        end

                        visited[neighbourId] = true
                        table.insert(queue, neighbourId)
                        break
                    end
                end
            end
        end
    end

    return nil
end

local function normalizePermissionKey(value)
    if type(value) ~= 'string' then
        return nil
    end

    local key = value:lower():gsub('[%s%-%_]', '')

    if key == '' then
        return nil
    end

    return key
end

local function getPermissionAliases(permission)
    local aliases = {}

    local function add(value)
        if type(value) == 'string' and value ~= '' then
            aliases[#aliases + 1] = value
        end
    end

    local key = tostring(permission or ''):lower()

    add(permission)
    add(_L('permission_' .. key))

    if key == 'duty' then
        add(_L('permission_duty'))
        add('Duty')
    elseif key == 'garage' or key == 'helipad' or key == 'vehicle' then
        add(_L('permission_garage'))
        add('Garage')
    elseif key == 'inventory' then
        add(_L('permission_inventory'))
        add('Inventory')
    elseif key == 'stash' or key == 'wardrobe' then
        add(_L('permission_stash'))
        add('Stash')
    elseif key == 'boss_menu' or key == 'boss menu' then
        add(_L('permission_boss_menu'))
        add('Boss Menu')
        add('BossMenu')
    elseif key == 'xray' or key == 'x-ray' then
        add(_L('permission_xray'))
        add('X-Ray')
        add('Xray')
        add('XRAY')
    elseif key == 'ceiling_monitor' or key == 'monitor' or key == 'eta_arrival' then
        add('Monitor')
        add('Ceiling Monitor')
        add('ETA Arrival')
        add('CeilingMonitor')
        add('Vitals Monitor')
        add('VitalsMonitor')
        add('monitor')
        add('ceiling_monitor')
    end

    return aliases
end

permissionTableAllows = function(perms, permission)
    if type(perms) ~= 'table' then
        return false
    end

    local normalized = {}

    for _, alias in ipairs(getPermissionAliases(permission)) do
        local key = normalizePermissionKey(alias)

        if key then
            normalized[key] = true
        end

        if perms[alias] == true then
            return true
        end
    end

    for key, value in pairs(perms) do
        if value == true then
            local normalizedKey = normalizePermissionKey(key)

            if normalizedKey and normalized[normalizedKey] then
                return true
            end
        end
    end

    return false
end

local function clearInteractionZones()
    if Target then
        for _, zone in pairs(interactionZones) do
            Target.RemoveZone(zone)
        end
    end

    interactionZones = {}
end

local function createNodeInteraction(nodeId, locType, coords, label, job, spawnKind, version)
    if version and not isCurrentZoneVersion(version) then
        return
    end

    local zoneName = ('plt_amb_%s_%s'):format(nodeId, locType)
    local prettyType = locType:gsub('_', ' '):gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
    local zoneLabel = GetCleanLabel(label, prettyType)

    local function canInteract()
        local playerData = Framework.GetPlayerData()

        if not playerData then
            return false
        end

        if hasElevatedPermission then
            return true
        end

        if not hasDepartmentJob(job) then
            return false
        end

        if not HasPermissionForNode(nodeId, locType, DepartmentData) then
            return false
        end

        if locType == 'duty' then
            return true
        end

        return playerData.job.onduty == true
    end

    if spawnKind == 'ped' then
        local existing = spawnedPeds[zoneName]

        if type(existing) == 'number' and DoesEntityExist(existing) then
            DeleteEntity(existing)
        end

        local modelName = (Config.LocalDoctor and Config.LocalDoctor.DoctorPedModel) or 's_m_m_doctor_01'
        local model = GetHashKey(modelName)

        RequestModel(model)

        local attempts = 0

        while not HasModelLoaded(model) and attempts < 100 do
            Wait(10)
            attempts = attempts + 1
        end

        if version and not isCurrentZoneVersion(version) then
            return
        end

        if HasModelLoaded(model) then
            local ped = CreatePed(4, model, coords.x, coords.y, coords.z, coords.h or 0.0, false, false)

            SetEntityAsMissionEntity(ped, true, true)
            SetEntityInvincible(ped, true)
            SetBlockingOfNonTemporaryEvents(ped, true)
            FreezeEntityPosition(ped, true)

            spawnedPeds[zoneName] = ped

            SetModelAsNoLongerNeeded(model)
        end
    end

    if version and not isCurrentZoneVersion(version) then
        return
    end

    if not Target then
        return
    end

    local options

    if locType == 'wardrobe' then
        options = {
            {
                icon = 'fas fa-user-nurse',
                label = 'Wear EMS Clothes',
                onSelect = function()
                    TriggerEvent('amb_client:Interact', {
                        locType = locType,
                        job = job,
                        nodeId = nodeId,
                        coords = coords,
                        label = zoneLabel,
                        wardrobeAction = 'ems'
                    })
                end,
                canInteract = canInteract
            },
            {
                icon = 'fas fa-user',
                label = 'Wear Civilian Clothes',
                onSelect = function()
                    TriggerEvent('amb_client:Interact', {
                        locType = locType,
                        job = job,
                        nodeId = nodeId,
                        coords = coords,
                        label = zoneLabel,
                        wardrobeAction = 'civilian'
                    })
                end,
                canInteract = canInteract
            }
        }
    else
        options = {
            {
                icon = 'fas fa-hand-pointer',
                label = zoneLabel,
                onSelect = function()
                    TriggerEvent('amb_client:Interact', {
                        locType = locType,
                        job = job,
                        nodeId = nodeId,
                        coords = coords,
                        label = zoneLabel
                    })
                end,
                canInteract = canInteract
            }
        }
    end

    interactionZones[zoneName] = Target.AddSphereZone({
        name = zoneName,
        coords = vector3(coords.x, coords.y, coords.z),
        radius = 1.2,
        distance = 3.0,
        options = options
    })
end

local placementActive = false

local function collectBedSpots(node)
    local spots = {}

    local function add(entry)
        if not (entry and entry.x and entry.y and entry.z) then
            return
        end

        spots[#spots + 1] = {
            x = tonumber(entry.x) or entry.x,
            y = tonumber(entry.y) or entry.y,
            z = tonumber(entry.z) or entry.z,
            h = tonumber(entry.h) or 0.0
        }
    end

    if not node then
        return spots
    end

    local bed = node.bed

    if type(bed) == 'table' then
        if bed.x and bed.y and bed.z then
            add(bed)
        else
            for _, entry in ipairs(bed) do
                add(entry)
            end
        end
    end

    local beds = node.beds

    if type(beds) == 'table' then
        if beds.x and beds.y and beds.z then
            add(beds)
        else
            for _, entry in ipairs(beds) do
                add(entry)
            end
        end
    end

    return spots
end

local function isSpotOccupied(spot, ignorePed)
    local coords = vector3(spot.x, spot.y, spot.z)

    for _, playerIndex in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(playerIndex)

        if ped and ped ~= 0 and ped ~= ignorePed and DoesEntityExist(ped)
            and not IsPedInAnyVehicle(ped, false)
            and #(GetEntityCoords(ped) - coords) <= 1.2 then
            return true
        end
    end

    return false
end

local function pickFreeSpot(spots, ignorePed)
    if not spots or #spots == 0 then
        return nil
    end

    for _, spot in ipairs(spots) do
        if not isSpotOccupied(spot, ignorePed) then
            return spot
        end
    end

    return spots[1]
end

local function oppositeHeading(heading)
    return ((tonumber(heading) or 0.0) + 180.0) % 360.0
end

local INTERIOR_BED_MODELS = {
    1631638868,
    2117668672,
    -1091386327,
    -1182962909
}

local function getInteriorBedHeading()
    if tonumber(INTERIOR_SPAWN.heading) then
        return tonumber(INTERIOR_SPAWN.heading)
    end

    local coords = INTERIOR_SPAWN.coords

    if not coords then
        return 0.0
    end

    local closest = nil
    local closestDistance = 9999.0

    for _, model in ipairs(INTERIOR_BED_MODELS) do
        local object = GetClosestObjectOfType(coords.x, coords.y, coords.z, 3.0, model, false, false, false)

        if object and object ~= 0 and DoesEntityExist(object) then
            local distance = #(GetEntityCoords(object) - coords)

            if distance < closestDistance then
                closestDistance = distance
                closest = object
            end
        end
    end

    if closest and DoesEntityExist(closest) then
        return GetEntityHeading(closest)
    end

    return 0.0
end

local function createInteriorBedZone()
    local coords = INTERIOR_SPAWN.coords

    if not coords then
        return
    end

    local zoneName = 'plt_static_interior_bed_main'
    local heading = getInteriorBedHeading()

    if not Target then
        return
    end

    targetZones[zoneName] = Target.AddBoxZone({
        name = zoneName,
        coords = coords,
        size = vector3(1.0, 2.0, 1.0),
        rotation = heading,
        distance = 2.0,
        options = {
            {
                name = zoneName,
                label = _L('bed_lie'),
                icon = 'fas fa-bed',
                onSelect = function()
                    LieOnTreatmentBed(coords, getInteriorBedHeading())
                end
            }
        }
    })
end

local function playBedGetUp(spot)
    local ped = PlayerPedId()

    if not (ped and ped ~= 0 and DoesEntityExist(ped)) then
        return
    end

    if IsPedInAnyVehicle(ped, false) then
        return
    end

    local heading = (oppositeHeading(spot and spot.h) + 90.0) % 360.0

    if spot and spot.x and spot.y and spot.z then
        SetEntityCoordsNoOffset(ped, spot.x, spot.y, spot.z + 0.02, false, false, false)
    end

    SetEntityHeading(ped, heading)

    local dict = 'switch@franklin@bed'
    local anim = 'sleep_getup_rubeyes'

    Framework.RequestAnimDict(dict)
    TaskPlayAnim(ped, dict, anim, 3.0, 3.0, 4000, 8, 0.0, false, false, false)

    Wait(4000)
    ClearPedTasks(ped)
end

local function createCheckInPoint(nodeId, checkinCoords, beds, locationName, isBusy, minEMS, version)
    if version and not isCurrentZoneVersion(version) then
        return
    end

    local zoneName = 'plt_amb_checkin_' .. nodeId
    local healTime = (Config.LocalDoctor and Config.LocalDoctor.HealTime) or 15000
    local lieAnim = (Config.LocalDoctor and Config.LocalDoctor.LieAnim)
        or { dict = 'amb@world_human_sunbathe@male@back@base', name = 'base' }
    local requiredEMS = minEMS or 1

    checkInData[nodeId] = {
        checkinCoords = checkinCoords,
        beds = beds,
        locationName = locationName,
        healTime = healTime,
        lieAnim = lieAnim,
        minEMS = requiredEMS
    }

    local existingPed = doctorPeds[zoneName]

    if existingPed and DoesEntityExist(existingPed) then
        DeleteEntity(existingPed)
    end

    local function startCheckIn()
        Framework.TriggerCallback('amb_server:getEMSOnDutyCount', function(onDutyCount)
            if onDutyCount >= requiredEMS then
                Framework.Notify(_L('local_doctor_busy', { count = onDutyCount }), 'info')
                return
            end

            local ped = PlayerPedId()

            exports.plt_ambulance_job:GetInjuryType()

            local spot = pickFreeSpot(beds, ped)

            if not spot then
                Framework.Notify(_L('no_checkin_bed'), 'error')
                return
            end

            SetEntityCoords(ped, spot.x, spot.y, spot.z, false, false, false, false)
            SetEntityHeading(ped, oppositeHeading(spot.h))
            FreezeEntityPosition(ped, true)

            Framework.RequestAnimDict(lieAnim.dict)
            TaskPlayAnim(ped, lieAnim.dict, lieAnim.name, 8.0, -8.0, -1, 1, 0.0, false, false, false)

            if not Framework.ProgressBar(_L('local_doctor_treating'), tonumber(healTime) or 5000) then
                FreezeEntityPosition(PlayerPedId(), false)
                ClearPedTasks(PlayerPedId())
                Framework.Notify(_L('treatment_cancelled'), 'error')
                return
            end

            FreezeEntityPosition(ped, false)
            ClearPedTasks(ped)

            TriggerEvent('amb_client:HealInjuries')

            CreateThread(function()
                Wait(150)
                playBedGetUp(spot)
            end)
        end)
    end

    local zoneZ = (checkinCoords.z or 0.0) + 0.9

    if Target then
        checkInZones[zoneName] = Target.AddSphereZone({
            name = zoneName,
            coords = vector3(checkinCoords.x, checkinCoords.y, zoneZ),
            radius = 1.5,
            distance = 3.0,
            options = {
                {
                    icon = 'fas fa-user-md',
                    label = _L('checkin_local_doctor'),
                    onSelect = startCheckIn
                }
            }
        })
    end

    local modelName = (Config.LocalDoctor and Config.LocalDoctor.DoctorPedModel) or 's_m_m_doctor_01'
    local model = GetHashKey(modelName)

    RequestModel(model)

    local attempts = 0

    while not HasModelLoaded(model) and attempts < 100 do
        Wait(10)
        attempts = attempts + 1
    end

    if version and not isCurrentZoneVersion(version) then
        return
    end

    if HasModelLoaded(model) then
        local ped = CreatePed(4, model, checkinCoords.x, checkinCoords.y, checkinCoords.z,
            checkinCoords.h or 0.0, false, false)

        if version and not isCurrentZoneVersion(version) then
            if DoesEntityExist(ped) then
                DeleteEntity(ped)
            end

            return
        end

        SetEntityAsMissionEntity(ped, true, true)
        SetEntityInvincible(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, true)
        FreezeEntityPosition(ped, true)

        doctorPeds[zoneName] = ped

        SetModelAsNoLongerNeeded(model)
    end
end

local function clearDoctorPeds()
    for _, ped in pairs(doctorPeds) do
        if DoesEntityExist(ped) then
            DeleteEntity(ped)
        end
    end

    doctorPeds = {}
end

function ToggleVitalsMonitor(monitorId)
    local key = tostring(monitorId)
    local state = monitorPower[key] ~= true

    monitorPower[key] = state

    TriggerServerEvent('plt_xray:server:setMonitorPower', key, state)

    Framework.Notify(_L('monitor_state', {
        state = state and _L('monitor_state_on') or _L('monitor_state_off')
    }), 'success')
end

RegisterNetEvent('plt_ambulance:client:setMonitorPowerMirror', function(monitorId, powered)
    local key = tostring(monitorId)
    local state = powered == true

    monitorPower[key] = state

    TriggerEvent('plt_xray:client:setMonitorPower', key, state)
end)

function LieOnTreatmentBed(coords, heading)
    local ped = PlayerPedId()

    if isOnBed then
        ClearPedTasks(ped)
        FreezeEntityPosition(ped, false)

        isOnBed = false
        bedAnim = nil

        LocalPlayer.state:set('isLyingOnBed', false, true)

        return
    end

    isOnBed = true

    LocalPlayer.state:set('isLyingOnBed', true, true)

    local bedHeading = oppositeHeading(heading)
    local dict = 'anim@gangops@morgue@table@'
    local anim = 'ko_front'

    RequestAnimDict(dict)

    while not HasAnimDictLoaded(dict) do
        Wait(10)
    end

    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, true)
    SetEntityHeading(ped, bedHeading)
    FreezeEntityPosition(ped, true)
    TaskPlayAnim(ped, dict, anim, 8.0, -8.0, -1, 1, 0, false, false, false)

    bedAnim = { ad = dict, anim = anim }

    Framework.Notify(_L('lying_on_bed_exit'), 'info')

    CreateThread(function()
        while isOnBed do
            if not IsEntityPlayingAnim(ped, dict, anim, 3) then
                TaskPlayAnim(ped, dict, anim, 8.0, -8.0, -1, 1, 0, false, false, false)
            end

            if IsControlJustPressed(0, 73) then
                LieOnTreatmentBed()
                break
            end

            Wait(0)
        end
    end)
end

function SitOnTreatmentBed(coords, heading)
    local ped = PlayerPedId()

    if isOnBed then
        ClearPedTasks(ped)
        FreezeEntityPosition(ped, false)

        isOnBed = false
        bedAnim = nil

        LocalPlayer.state:set('isLyingOnBed', false, true)

        return
    end

    isOnBed = true

    LocalPlayer.state:set('isLyingOnBed', true, true)

    local bedHeading = oppositeHeading(heading)
    local dict = 'anim@heists@fleeca_bank@ig_7_jetski_owner'
    local anim = 'owner_idle'

    RequestAnimDict(dict)

    while not HasAnimDictLoaded(dict) do
        Wait(10)
    end

    SetEntityCoords(ped, coords.x, coords.y, coords.z + 0.08, false, false, false, true)
    SetEntityHeading(ped, bedHeading)
    FreezeEntityPosition(ped, true)
    TaskPlayAnim(ped, dict, anim, 8.0, -8.0, -1, 1, 0, false, false, false)

    bedAnim = { ad = dict, anim = anim }

    Framework.Notify(_L('sitting_on_bed_exit'), 'info')

    CreateThread(function()
        while isOnBed do
            if not IsEntityPlayingAnim(ped, dict, anim, 3) then
                TaskPlayAnim(ped, dict, anim, 8.0, -8.0, -1, 1, 0, false, false, false)
            end

            if IsControlJustPressed(0, 73) then
                SitOnTreatmentBed()
                break
            end

            Wait(0)
        end
    end)
end

local function getNearbyBedPatient(coords, maxDistance)
    local playerPed = PlayerPedId()
    local range = maxDistance or 1.7

    for _, playerIndex in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(playerIndex)

        if ped and ped ~= 0 and ped ~= playerPed and DoesEntityExist(ped)
            and #(GetEntityCoords(ped) - coords) <= range then
            local serverId = GetPlayerServerId(playerIndex)
            local state = Player(serverId) and Player(serverId).state
            local isLying = state and state.isLyingOnBed == true

            if isLying or IsEntityPlayingAnim(ped, 'anim@gangops@morgue@table@', 'ko_front', 3) then
                return ped
            end
        end
    end

    return nil
end

local function canStartDiagnosis(coords)
    if not exports.plt_ambulance_job:IsEMS() and not hasElevatedPermission then
        return false
    end

    local playerData = Framework.GetPlayerData()

    if not playerData then
        return false
    end

    local onDuty = playerData.job and playerData.job.onduty == true

    if not onDuty and not (hasElevatedPermission and Config.AdminBypass) then
        return false
    end

    return getNearbyBedPatient(coords, 1.7) ~= nil
end

local function startDiagnosisOnPatient(coords)
    local patient = getNearbyBedPatient(coords, 1.7)

    if not patient then
        Framework.Notify(_L('diagnosis_no_patient_id'), 'error')
        return
    end

    if type(StartDiagnosis) == 'function' then
        StartDiagnosis(patient)
    else
        Framework.Notify(_L('diagnosis_no_patient_id'), 'error')
    end
end

exports('GetVitalsData', function()
    local ped = PlayerPedId()

    if not isOnBed and GetEntityHealth(ped) > 195 then
        return {
            pulse = 0,
            bp = '0/0',
            o2 = 0,
            stress = 0
        }
    end

    local health = GetEntityHealth(ped) - 100
    local maxHealth = GetEntityMaxHealth(ped) - 100
    local pulse = 60 + math.floor((maxHealth - health) * 0.4)

    if health < 10 then
        pulse = 0
    end

    local systolic = 110 + math.random(0, 20)
    local diastolic = 70 + math.random(0, 15)

    if health < 50 then
        systolic = systolic - (50 - health)
        diastolic = diastolic - ((50 - health) * 0.5)
    end

    local oxygen = 95 + math.random(0, 4)

    if health < 40 then
        oxygen = 80 + math.random(0, 10)
    end

    return {
        pulse = pulse,
        bp = ('%d/%d'):format(systolic, diastolic),
        o2 = oxygen,
        stress = math.random(10, 30)
    }
end)

exports('GetLocations', function()
    local locations = {}

    if DepartmentData and DepartmentData.nodes then
        for _, node in ipairs(DepartmentData.nodes) do
            if node.type == 'location' then
                locations[#locations + 1] = {
                    id = node.id,
                    label = GetCleanLabel(node.label, 'Location')
                }
            end
        end
    end

    return locations
end)

function RefreshBlipsAndZones(graph)
    local version = nextZoneVersion()

    DepartmentData = graph

    for _, blip in pairs(blips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end

    blips = {}

    clearInteractionZones()
    clearTargetEntities()
    clearDoctorPeds()
    clearSpawnedProps()

    vehicleDeletePoints = {}

    if Target then
        for _, zone in pairs(pharmacyZones) do
            Target.RemoveZone(zone)
        end
    end

    pharmacyZones = {}

    if Target then
        for _, zone in pairs(checkInZones) do
            Target.RemoveZone(zone)
        end
    end

    checkInZones = {}
    checkInData = {}

    createInteriorBedZone()

    if not (graph and graph.nodes) then
        return
    end

    for _, node in ipairs(graph.nodes) do
        local departmentId = GetDepartmentForNode(node.id, graph)

        if node.type == 'department' and node.coords then
            local blip = AddBlipForCoord(node.coords.x, node.coords.y, node.coords.z)

            SetBlipSprite(blip, node.blipId or 61)
            SetBlipColour(blip, node.blipColor or 1)
            SetBlipScale(blip, 0.8)
            SetBlipAsShortRange(blip, true)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentString(GetCleanLabel(node.label, 'Department'))
            EndTextCommandSetBlipName(blip)

            blips[node.id] = blip
        end

        if node.type == 'pharmacy' and node.coords and node.coords.x then
            local zoneName = 'plt_pharmacy_dynamic_' .. node.id

            if Target then
                pharmacyZones[node.id] = Target.AddBoxZone({
                    name = zoneName,
                    coords = vector3(node.coords.x, node.coords.y, node.coords.z),
                    size = vector3(1.2, 1.2, 2.0),
                    rotation = node.coords.h or 0.0,
                    distance = 2.0,
                    options = {
                        {
                            name = zoneName,
                            icon = 'fas fa-prescription-bottle-medical',
                            label = _L('pharmacy_terminal'),
                            onSelect = function()
                                TriggerEvent('amb_client:openPharmacy', departmentId)
                            end
                        }
                    }
                })
            end
        end

        if node.coordsList then
            if node.type == 'ceiling_monitor' or node.type == 'eta_arrival' then
                local monitor = node.coordsList.monitor
                local bed = node.coordsList.bed

                if monitor and monitor.x then
                    local model = node.type == 'eta_arrival' and 1503218008 or 389765485

                    RequestModel(model)

                    local attempts = 0

                    while not HasModelLoaded(model) and attempts < 100 do
                        Wait(10)
                        attempts = attempts + 1
                    end

                    if HasModelLoaded(model) then
                        local x = tonumber(monitor.x)
                        local y = tonumber(monitor.y)
                        local z = tonumber(monitor.z)
                        local heading = tonumber(monitor.h) or 0.0
                        local prop = CreateObject(model, x, y, z, false, false, false)

                        if DoesEntityExist(prop) then
                            local propKey = tostring(node.id)
                            local previous = propData[propKey]

                            if previous and DoesEntityExist(previous) then
                                SetEntityAsMissionEntity(previous, true, true)
                                DeleteObject(previous)
                                DeleteEntity(previous)
                            end

                            SetEntityHeading(prop, heading)
                            SetEntityCoords(prop, x, y, z, false, false, false, true)
                            SetEntityAsMissionEntity(prop, true, true)
                            FreezeEntityPosition(prop, true)

                            table.insert(spawnedProps, prop)

                            propData[propKey] = prop

                            if Config.Debug then
                                print('^2[plt_ambulance] Spawned ' .. node.type .. ' Prop at '
                                    .. tostring(vector3(x, y, z)) .. '^7')
                            end

                            if node.type == 'eta_arrival' then
                                TriggerEvent('plt_xray:client:createETAPanel', prop, node.id)
                            else
                                createXrayPanel(prop, node.id, bed)
                            end

                            monitorPower[node.id] = false

                            local monitorZoneName = 'plt_monitor_' .. node.id

                            local function canToggleMonitor()
                                if HasPermissionForNode(node.id, 'ceiling_monitor', DepartmentData) then
                                    return true
                                end

                                return exports.plt_ambulance_job:IsEMS()
                            end

                            if Target then
                                Target.AddLocalEntity(prop, {
                                    {
                                        name = monitorZoneName,
                                        label = _L('monitor_toggle'),
                                        icon = 'fas fa-power-off',
                                        onSelect = function()
                                            ToggleVitalsMonitor(node.id)
                                        end,
                                        canInteract = function()
                                            return canToggleMonitor()
                                        end
                                    }
                                }, 3.0)
                            end

                            if bed and bed.x then
                                local bedHeading = tonumber(bed.h) or 0.0
                                local bedCoords = vector3(tonumber(bed.x), tonumber(bed.y), tonumber(bed.z))
                                local bedZoneName = 'plt_bed_' .. node.id

                                if Target then
                                    targetZones[bedZoneName] = Target.AddBoxZone({
                                        name = bedZoneName,
                                        coords = bedCoords,
                                        size = vector3(1.0, 2.0, 1.0),
                                        rotation = bedHeading,
                                        distance = 2.0,
                                        options = {
                                            {
                                                name = bedZoneName,
                                                label = _L('bed_lie'),
                                                icon = 'fas fa-bed',
                                                onSelect = function()
                                                    LieOnTreatmentBed(bedCoords, bedHeading)
                                                end
                                            },
                                            {
                                                name = bedZoneName .. '_sit',
                                                label = _L('bed_sit'),
                                                icon = 'fas fa-chair',
                                                onSelect = function()
                                                    SitOnTreatmentBed(bedCoords, bedHeading)
                                                end
                                            },
                                            {
                                                name = bedZoneName .. '_diagnose',
                                                label = _L('diagnose_injuries'),
                                                icon = 'fas fa-stethoscope',
                                                onSelect = function()
                                                    startDiagnosisOnPatient(bedCoords)
                                                end,
                                                canInteract = function()
                                                    return canStartDiagnosis(bedCoords)
                                                end
                                            }
                                        }
                                    })
                                end
                            end
                        else
                            print('^1[plt_ambulance] ERROR: Failed to create Ceiling Monitor Prop!^7')
                        end

                        SetModelAsNoLongerNeeded(model)
                    else
                        print('^1[plt_ambulance] ERROR: Failed to load Ceiling Monitor Model!^7')
                    end
                end
            end

            if node.type == 'xray' then
                local pc = node.coordsList.pc
                local bed = node.coordsList.bed
                local screenWidth = tonumber(node.screenWidth) or 0.47
                local screenHeight = tonumber(node.screenHeight) or 0.31

                if (pc and pc.x) or (bed and bed.x) then
                    local screenNormal, screenUp

                    if pc and pc.x then
                        screenNormal, screenUp = getPropAxes(pc)
                    end

                    TriggerEvent('plt_xray:client:updateConfigFromNode', {
                        Computer = pc and {
                            pos = vector3(pc.x, pc.y, pc.z),
                            heading = pc.h or 0.0,
                            screenNormal = screenNormal or headingToForward(pc.h or 0.0),
                            screenUp = screenUp or vector3(0.0, 0.0, 1.0),
                            width = screenWidth,
                            height = screenHeight
                        } or nil,
                        ScanBed = bed and {
                            pos = vector3(bed.x, bed.y, bed.z),
                            radius = 2.0
                        } or nil
                    })
                end

                if pc and pc.x then
                    local pcZoneName = 'plt_xray_pc_' .. node.id

                    local function canUseXrayTerminal()
                        if not HasPermissionForNode(node.id, 'xray', DepartmentData) then
                            return false
                        end

                        if Framework.Type == 'esx' then
                            return true
                        end

                        if hasElevatedPermission and Config.AdminBypass then
                            return true
                        end

                        local playerData = Framework.GetPlayerData()

                        if not (playerData and playerData.job) then
                            return false
                        end

                        return playerData.job.onduty == true
                    end

                    if Target then
                        interactionZones[pcZoneName] = Target.AddSphereZone({
                            name = pcZoneName,
                            coords = vector3(pc.x, pc.y, pc.z),
                            radius = 1.0,
                            distance = 2.0,
                            options = {
                                {
                                    icon = 'fas fa-desktop',
                                    label = _L('xray_terminal'),
                                    onSelect = function()
                                        TriggerEvent('plt_xray:client:openFromNode')
                                    end,
                                    canInteract = canUseXrayTerminal
                                }
                            }
                        })
                    end
                end

                if bed and bed.x then
                    local bedHeading = tonumber(bed.h) or 0.0
                    local bedCoords = vector3(tonumber(bed.x), tonumber(bed.y), tonumber(bed.z))
                    local bedZoneName = 'plt_xray_bed_' .. node.id

                    if Target then
                        targetZones[bedZoneName] = Target.AddBoxZone({
                            name = bedZoneName,
                            coords = bedCoords,
                            size = vector3(1.0, 2.0, 1.0),
                            rotation = bedHeading,
                            distance = 2.0,
                            options = {
                                {
                                    name = bedZoneName,
                                    label = _L('bed_lie'),
                                    icon = 'fas fa-bed',
                                    onSelect = function()
                                        LieOnTreatmentBed(bedCoords, bedHeading)
                                    end
                                },
                                {
                                    name = bedZoneName .. '_sit',
                                    label = _L('bed_sit'),
                                    icon = 'fas fa-chair',
                                    onSelect = function()
                                        SitOnTreatmentBed(bedCoords, bedHeading)
                                    end
                                }
                            }
                        })
                    end
                end
            end

            for coordKey, coords in pairs(node.coordsList) do
                if coords and coords.x
                    and node.type ~= 'xray'
                    and node.type ~= 'check_in'
                    and node.type ~= 'ceiling_monitor'
                    and node.type ~= 'eta_arrival' then
                    local interactionType = (node.interactionTypes and node.interactionTypes[coordKey]) or 'zone'

                    createNodeInteraction(node.id, coordKey, coords, node.label, departmentId, interactionType, version)
                end
            end
        end

        if (node.type == 'vehicle' or node.type == 'helipad') and node.deletePoints then
            local allowedModels = {}

            if type(node.vehicles) == 'table' then
                for _, vehicle in ipairs(node.vehicles) do
                    if type(vehicle) == 'table' and vehicle.model and tostring(vehicle.model) ~= '' then
                        allowedModels[#allowedModels + 1] = tostring(vehicle.model):lower()
                    end
                end
            end

            for _, point in ipairs(node.deletePoints) do
                if point and point.x then
                    table.insert(vehicleDeletePoints, {
                        coords = point,
                        job = departmentId,
                        allowedModels = allowedModels
                    })
                end
            end
        end

        if node.type ~= 'department' and node.type ~= 'pharmacy'
            and node.type ~= 'ceiling_monitor' and node.type ~= 'eta_arrival'
            and node.coords and node.coords.x
            and not (node.coordsList and node.coordsList[node.type]) then
            createNodeInteraction(node.id, node.type, node.coords, node.label, departmentId, 'zone', version)
        end
    end

    Framework.TriggerCallback('amb_server:getEMSOnDutyCount', function(onDutyCount)
        if not isCurrentZoneVersion(version) then
            return
        end

        for _, node in ipairs(graph.nodes) do
            if node.type == 'check_in' then
                local checkin = node.coordsList and node.coordsList.checkin
                local beds = collectBedSpots(node.coordsList)
                local minEMS = tonumber(node.minEMS) or 1

                if checkin and checkin.x and #beds > 0 then
                    local locationNode = GetLinkedNodeByType(node.id, 'location', graph)
                    local label = (locationNode and locationNode.label) or node.label or _L('hospital')

                    createCheckInPoint(node.id, checkin, beds, label, onDutyCount >= minEMS, minEMS, version)
                end
            end
        end
    end)
end

RegisterNUICallback('startPlacement', function(data, cb)
    if placementActive then
        return cb('ok')
    end

    placementActive = true

    SetNuiFocus(false, false)

    SendNUIMessage({
        action = 'amb_togglePlacementHelp',
        visible = true,
        header = _L('placement_header'),
        confirmLabel = _L('placement_confirm'),
        rotateLabel = _L('placement_rotate')
    })

    CreateThread(function()
        local heading = GetEntityHeading(PlayerPedId())
        local pitch = 0.0
        local forwardOffset = 0.0
        local screenWidth = tonumber(data.screenWidth) or 0.47
        local screenHeight = tonumber(data.screenHeight) or 0.31
        local isMonitor = data.locType == 'monitor'
        local confirmed = false
        local model = nil
        local previewEntity = nil
        local isObject = false
        local isPed = false

        if data.locType == 'pc' and DepartmentData and DepartmentData.nodes then
            for _, node in ipairs(DepartmentData.nodes) do
                if tostring(node.id) == tostring(data.nodeId) then
                    screenWidth = tonumber(node.screenWidth) or screenWidth
                    screenHeight = tonumber(node.screenHeight) or screenHeight
                    break
                end
            end
        end

        if isMonitor then
            clearSpawnedProps()
        end

        if data.locType == 'spawn' then
            model = 1171614426

            if data.nodeId and data.nodeId:find('helipad') then
                model = 353883353
            end
        elseif data.locType == 'bed' then
            model = 1631638868
            isObject = true
        elseif data.locType == 'checkin' or data.interactionType == 'ped' then
            model = -730659924
            isPed = true
        elseif data.locType == 'monitor' then
            if data.nodeId and tostring(data.nodeId):find('eta_arrival') then
                model = 1503218008
            else
                model = 389765485
            end

            isObject = true
        end

        if model then
            RequestModel(model)

            local attempts = 0

            while not HasModelLoaded(model) and attempts < 100 do
                Wait(10)
                attempts = attempts + 1
            end
        end

        while placementActive do
            Wait(0)

            local hit, coords = RaycastFromCamera(100.0)

            if hit then
                local placeCoords = coords

                if data.locType == 'pc' then
                    local playerCoords = GetEntityCoords(PlayerPedId())
                    local dx = coords.x - playerCoords.x
                    local dy = coords.y - playerCoords.y
                    local length = math.sqrt(dx * dx + dy * dy)

                    if length > 0.001 then
                        placeCoords = vector3(
                            coords.x + (dx / length) * forwardOffset,
                            coords.y + (dy / length) * forwardOffset,
                            coords.z
                        )
                    end
                end

                if data.locType == 'bed' then
                    DrawMarker(1, coords.x, coords.y, coords.z - 1.0, 0, 0, 0, 0, 0, 0,
                        2.4, 2.4, 2.0, 220, 240, 255, 120, false, false, 2, nil, nil, false)
                    DrawMarker(28, coords.x, coords.y, coords.z, 0, 0, 0, 0, 0, 0,
                        0.1, 0.1, 0.1, 255, 255, 255, 200, false, false, 2, nil, nil, false)
                end

                if not model and data.locType ~= 'pc' and data.locType ~= 'bed' then
                    DrawMarker(28, coords.x, coords.y, coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                        0.15, 0.15, 0.15, 0, 255, 204, 150, false, false, 2, nil, nil, false)
                end

                if data.locType == 'pc' then
                    TriggerEvent('plt_xray:client:showPlacementPreview',
                        placeCoords, heading, pitch, screenWidth, screenHeight)
                end

                if model then
                    if not previewEntity then
                        if isObject then
                            previewEntity = CreateObject(model, coords.x, coords.y, coords.z, false, false, false)
                        elseif isPed then
                            previewEntity = CreatePed(4, model, coords.x, coords.y, coords.z - 1.0,
                                heading, false, false)

                            SetEntityAlpha(previewEntity, 180, false)
                            SetEntityCollision(previewEntity, false, false)
                            SetEntityInvincible(previewEntity, true)
                            FreezeEntityPosition(previewEntity, true)
                        else
                            previewEntity = CreateVehicle(model, coords.x, coords.y, coords.z,
                                heading, false, false)

                            SetVehicleDoorsLocked(previewEntity, 2)
                        end

                        if not isPed then
                            SetEntityAlpha(previewEntity, 180, false)
                            SetEntityCollision(previewEntity, false, false)
                            SetEntityInvincible(previewEntity, true)
                            FreezeEntityPosition(previewEntity, true)
                        end
                    else
                        SetEntityCoords(previewEntity, coords.x, coords.y, coords.z,
                            false, false, false, false)
                        SetEntityHeading(previewEntity, heading)
                    end
                end

                if IsControlPressed(0, 174) then
                    heading = heading + 2.0
                elseif IsControlPressed(0, 175) then
                    heading = heading - 2.0
                end

                if data.locType == 'pc' then
                    if IsControlPressed(0, 172) then
                        if IsControlPressed(0, 21) then
                            forwardOffset = math.min(3.0, forwardOffset + 0.01)
                        else
                            pitch = math.min(45.0, pitch + 0.5)
                        end
                    elseif IsControlPressed(0, 173) then
                        if IsControlPressed(0, 21) then
                            forwardOffset = math.max(-3.0, forwardOffset - 0.01)
                        else
                            pitch = math.max(-45.0, pitch - 0.5)
                        end
                    end
                end

                if IsControlJustPressed(0, 38) then
                    placementActive = false
                    confirmed = true

                    if data.locType == 'pc' then
                        TriggerEvent('plt_xray:client:hidePlacementPreview')
                    end

                    SendNUIMessage({
                        action = 'amb_placementDone',
                        nodeId = data.nodeId,
                        locType = data.locType,
                        pointIndex = data.pointIndex,
                        interactionType = data.interactionType,
                        coords = {
                            x = placeCoords.x,
                            y = placeCoords.y,
                            z = placeCoords.z,
                            h = heading,
                            pitch = data.locType == 'pc' and pitch or nil
                        }
                    })

                    SendNUIMessage({
                        action = 'amb_togglePlacementHelp',
                        visible = false
                    })

                    SetNuiFocus(true, true)
                    break
                end
            end

            if IsControlJustPressed(0, 177) or IsControlJustPressed(0, 202) or IsControlJustPressed(0, 47) then
                placementActive = false

                if data.locType == 'pc' then
                    TriggerEvent('plt_xray:client:hidePlacementPreview')
                end

                SendNUIMessage({ action = 'amb_placementCancelled' })
                SendNUIMessage({ action = 'amb_togglePlacementHelp', visible = false })
                SetNuiFocus(true, true)
                break
            end
        end

        if previewEntity then
            if isObject then
                DeleteObject(previewEntity)
            elseif isPed then
                DeleteEntity(previewEntity)
            else
                DeleteVehicle(previewEntity)
            end
        end

        if model then
            SetModelAsNoLongerNeeded(model)
        end

        if isMonitor and not confirmed and DepartmentData and DepartmentData.nodes then
            RefreshBlipsAndZones(DepartmentData)
        end
    end)

    cb('ok')
end)

RegisterNUICallback('startDoorPlacement', function(data, cb)
    cb('ok')

    if placementActive then
        return
    end

    placementActive = true

    SetNuiFocus(false, false)

    SendNUIMessage({
        action = 'amb_togglePlacementHelp',
        visible = true,
        header = _L('placement_header'),
        confirmLabel = _L('placement_confirm'),
        rotateLabel = ''
    })

    CreateThread(function()
        while placementActive do
            Wait(0)

            local hit, _, entity = RaycastFromCamera(25.0)
            local target = nil

            if hit and entity and entity ~= 0 and DoesEntityExist(entity)
                and GetEntityType(entity) == 3 then
                target = entity

                local coords = GetEntityCoords(target)

                DrawMarker(28, coords.x, coords.y, coords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    0.3, 0.3, 0.3, 0, 255, 140, 180, false, false, 2, nil, nil, false)
            end

            if IsControlJustPressed(0, 38) and target then
                local coords = GetEntityCoords(target)

                placementActive = false

                SendNUIMessage({
                    action = 'amb_doorPlacementDone',
                    nodeId = data.nodeId,
                    doorIndex = data.doorIndex,
                    coords = { x = coords.x, y = coords.y, z = coords.z },
                    hash = GetEntityModel(target)
                })

                SendNUIMessage({ action = 'amb_togglePlacementHelp', visible = false })
                SetNuiFocus(true, true)
                break
            end

            if IsControlJustPressed(0, 177) or IsControlJustPressed(0, 202)
                or IsControlJustPressed(0, 47) then
                placementActive = false

                SendNUIMessage({ action = 'amb_placementCancelled' })
                SendNUIMessage({ action = 'amb_togglePlacementHelp', visible = false })
                SetNuiFocus(true, true)
                break
            end
        end
    end)
end)

function RotationToDirection(rotation)
    local radians = {
        x = (math.pi / 180) * rotation.x,
        y = (math.pi / 180) * rotation.y,
        z = (math.pi / 180) * rotation.z
    }

    return {
        x = -math.sin(radians.z) * math.abs(math.cos(radians.x)),
        y = math.cos(radians.z) * math.abs(math.cos(radians.x)),
        z = math.sin(radians.x)
    }
end

function RaycastFromCamera(distance)
    local rotation = GetGameplayCamRot(2)
    local origin = GetGameplayCamCoord()
    local direction = RotationToDirection(rotation)

    local destination = {
        x = origin.x + direction.x * distance,
        y = origin.y + direction.y * distance,
        z = origin.z + direction.z * distance
    }

    local ray = StartShapeTestRay(origin.x, origin.y, origin.z,
        destination.x, destination.y, destination.z, -1, PlayerPedId(), 0)

    local _, hit, endCoords, _, entityHit = GetShapeTestResult(ray)

    return hit, endCoords, entityHit
end

RegisterNUICallback('amb_localRefresh', function(data, cb)
    if data and data.nodes then
        RefreshBlipsAndZones(data)
    end

    cb('ok')
end)

RegisterNUICallback('amb_save', function(data, cb)
    TriggerServerEvent('amb_server:save', data)
    cb('ok')
end)

RegisterNUICallback('amb_close', function(_, cb)
    SetNuiFocus(false, false)
    cb('ok')
end)

RegisterNUICallback('amb_dutySwipeResult', function(data, cb)
    SetNuiFocus(false, false)

    if dutySwipePromise then
        dutySwipePromise:resolve(data and data.success == true)
    end

    cb('ok')
end)

RegisterNUICallback('amb_payEMSInvoice', function(data, cb)
    SetNuiFocus(false, false)
    TriggerServerEvent('amb_server:payEMSInvoice', data and data.invoiceId)
    cb('ok')
end)

RegisterNUICallback('amb_declineEMSInvoice', function(data, cb)
    SetNuiFocus(false, false)
    TriggerServerEvent('amb_server:declineEMSInvoice', data and data.invoiceId)
    cb('ok')
end)

RegisterNUICallback('amb_takeEMSItem', function(data, cb)
    TriggerServerEvent('amb_server:takeEMSInventoryItem', data)
    cb('ok')
end)

RegisterNUICallback('amb_spawnVehicle', function(data, cb)
    local model = data.model
    local spawnPoints = data.spawnPoints

    if not (model and spawnPoints and #spawnPoints ~= 0) then
        return cb('ok')
    end

    local spawnPoint = nil

    for _, point in ipairs(spawnPoints) do
        if point and point.x and not IsAnyVehicleNearPoint(point.x, point.y, point.z, 3.0) then
            spawnPoint = point
            break
        end
    end

    if not spawnPoint then
        Framework.Notify(_L('spawn_blocked'), 'error')
        return cb('ok')
    end

    local modelHash = (type(model) == 'string' and GetHashKey(model)) or model

    RequestModel(modelHash)

    while not HasModelLoaded(modelHash) do
        Wait(0)
    end

    local vehicle = CreateVehicle(modelHash, spawnPoint.x, spawnPoint.y, spawnPoint.z,
        spawnPoint.h or 0.0, true, true)

    SetNetworkIdCanMigrate(NetworkGetNetworkIdFromEntity(vehicle), true)
    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleHasBeenOwnedByPlayer(vehicle, true)
    SetVehicleNeedsToBeHotwired(vehicle, false)
    SetVehRadioStation(vehicle, 'OFF')
    SetModelAsNoLongerNeeded(modelHash)
    SetVehicleNumberPlateText(vehicle, 'EMS' .. tostring(math.random(100, 999)))

    Wait(100)

    Keys.Give(vehicle)

    Framework.Notify(_L('vehicle_spawned'), 'success')

    cb('ok')
end)

CreateThread(function()
    local function isAllowedModel(vehicle, point)
        if not (vehicle and vehicle ~= 0 and point and type(point.allowedModels) == 'table') then
            return false
        end

        if #point.allowedModels == 0 then
            return false
        end

        local model = GetEntityModel(vehicle)
        local displayName = tostring(GetDisplayNameFromVehicleModel(model) or ''):lower()

        for _, allowed in ipairs(point.allowedModels) do
            local name = tostring(allowed or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')

            if name ~= '' and (displayName == name or GetHashKey(name) == model) then
                return true
            end
        end

        return false
    end

    local promptVisible = false

    while true do
        local sleep = 1000
        local ped = PlayerPedId()
        local vehicle = GetVehiclePedIsIn(ped, false)

        if vehicle ~= 0 then
            if GetPedInVehicleSeat(vehicle, -1) == ped then
                local coords = GetEntityCoords(ped)
                local nearPoint = false

                for _, point in ipairs(vehicleDeletePoints) do
                    local pointCoords = vector3(point.coords.x, point.coords.y, point.coords.z)

                    if #(coords - pointCoords) <= deletePointDistance then
                        sleep = 0

                        if hasDepartmentJob(point.job) or (hasElevatedPermission and Config.AdminBypass) then
                            nearPoint = true

                            if not promptVisible then
                                Framework.ShowTextUI(_L('store_vehicle_prompt'))
                                promptVisible = true
                            end

                            if IsControlJustPressed(0, 38) then
                                if not isAllowedModel(vehicle, point) then
                                    Framework.Notify(
                                        'This vehicle is not registered in this department vehicle node.',
                                        'error')
                                    break
                                end

                                Framework.HideTextUI()

                                promptVisible = false

                                Framework.DeleteVehicle(vehicle)
                                Framework.Notify(_L('vehicle_stored'), 'success')
                            end
                        end
                    end
                end

                if not nearPoint and promptVisible then
                    Framework.HideTextUI()
                    promptVisible = false
                end
            end
        elseif promptVisible then
            Framework.HideTextUI()
            promptVisible = false
        end

        Wait(sleep)
    end
end)

local function openManagementUI(payload)
    if payload and payload.dept then
        DepartmentData = payload.dept
        MemberData = payload.members or {}

        RefreshBlipsAndZones(DepartmentData)
    end

    SetNuiFocus(true, true)

    SendNUIMessage({
        action = 'amb_open',
        data = DepartmentData
    })
end

RegisterNetEvent('amb_client:openManageEMSDirect', function(payload)
    openManagementUI(payload)
end)

RegisterCommand(Config.CommandName, function()
    TriggerServerEvent('amb_server:requestManageEMSDirect')
end)

CreateThread(function()
    local invoiceConfig = Config.EMSInvoice or {}

    TriggerEvent('chat:addSuggestion', '/' .. (invoiceConfig.CommandName or 'emsinvoice'),
        'Send an EMS invoice to a nearby patient', {
            { name = 'patientId', help = 'Patient server ID' },
            { name = 'amount', help = 'Invoice amount' },
            { name = 'reason', help = 'Invoice reason' }
        })

    TriggerEvent('chat:addSuggestion', '/' .. (invoiceConfig.PayCommandName or 'payemsinvoice'),
        'Pay a pending EMS invoice', {
            { name = 'invoiceId', help = 'Optional invoice ID' }
        })

    TriggerEvent('chat:addSuggestion', '/' .. (invoiceConfig.DeclineCommandName or 'declineemsinvoice'),
        'Decline a pending EMS invoice', {
            { name = 'invoiceId', help = 'Optional invoice ID' }
        })
end)

RegisterNetEvent('amb_client:EMSInvoiceReceived', function(invoice)
    if type(invoice) ~= 'table' then
        return
    end

    local invoiceConfig = Config.EMSInvoice or {}

    invoice.expireMinutes = invoiceConfig.ExpireMinutes or 10

    SendNUIMessage({
        action = 'amb_openEMSInvoice',
        invoice = invoice
    })

    SetNuiFocus(true, true)

    TriggerEvent('chat:addMessage', {
        color = { 46, 204, 113 },
        multiline = true,
        args = {
            'EMS Invoice',
            ('#%s | $%s | %s. Pay: /%s %s | Decline: /%s %s'):format(
                tostring(invoice.id or ''),
                tostring(invoice.amount or 0),
                tostring(invoice.reason or 'Medical service'),
                invoiceConfig.PayCommandName or 'payemsinvoice',
                tostring(invoice.id or ''),
                invoiceConfig.DeclineCommandName or 'declineemsinvoice',
                tostring(invoice.id or '')
            )
        }
    })
end)

RegisterNetEvent('amb_client:LocalDoctorCheckIn', function(payload, fallbackPayload)
    local data = (type(payload) == 'table' and payload)
        or (type(fallbackPayload) == 'table' and fallbackPayload)
        or nil

    local nodeId = data and data.nodeId

    if not nodeId then
        local coords = GetEntityCoords(PlayerPedId())
        local closestId = nil
        local closestDistance = 999999.0

        for id, entry in pairs(checkInData) do
            if entry.checkinCoords and entry.checkinCoords.x then
                local distance = #(coords - vector3(
                    entry.checkinCoords.x,
                    entry.checkinCoords.y,
                    entry.checkinCoords.z))

                if distance < closestDistance then
                    closestDistance = distance
                    closestId = id
                end
            end
        end

        nodeId = closestId
    end

    if not (nodeId and checkInData[nodeId]) then
        return
    end

    local entry = checkInData[nodeId]
    local requiredEMS = entry.minEMS or 1

    Framework.TriggerCallback('amb_server:getEMSOnDutyCount', function(onDutyCount)
        if onDutyCount >= requiredEMS then
            Framework.Notify(_L('local_doctor_busy', { count = onDutyCount }), 'info')
            return
        end

        local ped = PlayerPedId()

        exports.plt_ambulance_job:GetInjuryType()

        local spot = pickFreeSpot(entry.beds, ped)

        if not spot then
            Framework.Notify(_L('no_checkin_bed'), 'error')
            return
        end

        SetEntityCoords(ped, spot.x, spot.y, spot.z, false, false, false, false)
        SetEntityHeading(ped, oppositeHeading(spot.h))
        FreezeEntityPosition(ped, true)

        local lieAnim = entry.lieAnim

        Framework.RequestAnimDict(lieAnim.dict)
        TaskPlayAnim(ped, lieAnim.dict, lieAnim.name, 8.0, -8.0, -1, 1, 0.0, false, false, false)

        if not Framework.ProgressBar(_L('local_doctor_treating'), tonumber(entry.healTime) or 5000) then
            FreezeEntityPosition(PlayerPedId(), false)
            ClearPedTasks(PlayerPedId())
            Framework.Notify(_L('treatment_cancelled'), 'error')
            return
        end

        FreezeEntityPosition(ped, false)
        ClearPedTasks(ped)

        TriggerEvent('amb_client:HealInjuries')

        CreateThread(function()
            Wait(150)
            playBedGetUp(spot)
        end)
    end)
end)

local function buildStashId(department, nodeId)
    local dept = tostring(department or 'ems'):gsub('%s+', '_'):lower()
    local node = tostring(nodeId or 'default'):gsub('%s+', '_'):lower()

    return ('plt_amb_stash_%s_%s'):format(dept, node)
end

local function openDepartmentStash(department, nodeId, label)
    local stashId = buildStashId(department, nodeId)
    local stashLabel = label or (tostring(department or 'EMS') .. ' Stash')
    local maxWeight = 400000
    local slots = 80

    if not (Inventory and Inventory.OpenStash) then
        Framework.Notify('Stash is not configured for this inventory.', 'error')
        return
    end

    Framework.TriggerCallback('amb_server:prepareDepartmentStash', function(result)
        if not (result and result.ok) then
            Framework.Notify('Unable to open stash right now.', 'error')
            return
        end

        if not Inventory.OpenStash(result.stashId or stashId, stashLabel, maxWeight, slots) then
            Framework.Notify('Unable to open stash right now.', 'error')
        end
    end, {
        stashId = stashId,
        label = stashLabel,
        slots = slots,
        maxWeight = maxWeight
    })
end

RegisterNetEvent('amb_client:Interact', function(data)
    if not (data and data.locType) then
        return
    end

    local locType = data.locType
    local job = data.job
    local nodeId = data.nodeId
    local coords = data.coords
    local playerData = Framework.GetPlayerData()

    if not playerData then
        return
    end

    local hasAccess = hasDepartmentJob(job)

    if locType == 'boss_menu' then
        if not hasAccess then
            Framework.Notify(_L('not_your_department'), 'error')
            return
        end

        if not HasPermissionForNode(nodeId, 'boss_menu', DepartmentData) then
            Framework.Notify(_L('not_authorized'), 'error')
            return
        end

        OpenBossMenu(job)
    elseif locType == 'garage' or locType == 'helipad' then
        if not hasAccess then
            Framework.Notify(_L('no_garage_access'), 'error')
            return
        end

        local primaryType = locType == 'helipad' and 'helipad' or 'vehicle'
        local vehicleNode = GetLinkedNodeByType(nodeId, primaryType, DepartmentData)

        if not vehicleNode then
            local fallbackType = locType == 'helipad' and 'vehicle' or 'helipad'

            vehicleNode = GetLinkedNodeByType(nodeId, fallbackType, DepartmentData)
        end

        local vehicles = (vehicleNode and vehicleNode.vehicles) or {}
        local spawnPoints = (vehicleNode and vehicleNode.spawnPoints) or { coords }
        local deptName = ((vehicleNode and vehicleNode.label) or tostring(job or 'EMS'):upper())
            .. _L('garage_title_suffix')

        SendNUIMessage({
            action = 'amb_openGarage',
            deptName = deptName,
            department = job,
            vehicles = vehicles,
            spawnPoints = spawnPoints
        })

        SetNuiFocus(true, true)
    elseif locType == 'inventory' then
        if not hasAccess then
            Framework.Notify(_L('no_inventory_access'), 'error')
            return
        end

        Framework.TriggerCallback('amb_server:getEMSInventoryData', function(items)
            SendNUIMessage({
                action = 'amb_openInventory',
                items = items
            })

            SetNuiFocus(true, true)
        end)
    elseif locType == 'stash' then
        if not hasAccess then
            Framework.Notify(_L('no_inventory_access'), 'error')
            return
        end

        openDepartmentStash(job, nodeId, data.label)
    elseif locType == 'wardrobe' then
        if not hasAccess then
            Framework.Notify(_L('not_your_department'), 'error')
            return
        end

        if data.wardrobeAction == 'civilian' then
            restoreCivilianClothes()
            Framework.Notify('Civilian clothes restored.', 'success')
            return
        end

        if applyWardrobeOutfit(nodeId) then
            Framework.Notify('EMS uniform equipped.', 'success')
        else
            Framework.Notify('No EMS outfit configured for your rank.', 'error')
        end
    elseif locType == 'duty' then
        if not hasAccess then
            Framework.Notify(_L('not_your_department'), 'error')
            return
        end

        if not openDutySwipe(job) then
            Framework.Notify(_L('duty_swipe_cancelled'), 'error')
            return
        end

        TriggerServerEvent('amb_server:ToggleDuty', job)
    end
end)

RegisterNetEvent('plt_xray:requestSync', function()
    if not (DepartmentData and DepartmentData.nodes) then
        return
    end

    for _, node in ipairs(DepartmentData.nodes) do
        if node.type == 'xray' then
            local pc = node.coordsList and node.coordsList.pc
            local bed = node.coordsList and node.coordsList.bed
            local screenWidth = tonumber(node.screenWidth) or 0.47
            local screenHeight = tonumber(node.screenHeight) or 0.31

            if (pc and pc.x) or (bed and bed.x) then
                local screenNormal, screenUp

                if pc and pc.x then
                    screenNormal, screenUp = getPropAxes(pc)
                end

                TriggerEvent('plt_xray:client:updateConfigFromNode', {
                    Computer = pc and {
                        pos = vector3(pc.x, pc.y, pc.z),
                        screenNormal = screenNormal or headingToForward(pc.h or 0.0),
                        screenUp = screenUp or vector3(0.0, 0.0, 1.0),
                        width = screenWidth,
                        height = screenHeight
                    } or nil,
                    ScanBed = bed and {
                        pos = vector3(bed.x, bed.y, bed.z),
                        radius = 2.0
                    } or nil
                })
            end
        end
    end
end)

RegisterNetEvent('amb_client:SyncJobs', function(data)
    DepartmentData = data or { nodes = {}, links = {} }

    RefreshBlipsAndZones(DepartmentData)
end)

RegisterNetEvent('amb_client:RefreshCheckInZones', function()
    local version = nextZoneVersion()

    if not (DepartmentData and DepartmentData.nodes) then
        return
    end

    if Target then
        for _, zone in pairs(checkInZones) do
            Target.RemoveZone(zone)
        end
    end

    checkInZones = {}
    checkInData = {}

    clearDoctorPeds()

    Framework.TriggerCallback('amb_server:getEMSOnDutyCount', function(onDutyCount)
        if not isCurrentZoneVersion(version) then
            return
        end

        for _, node in ipairs(DepartmentData.nodes) do
            if node.type == 'check_in' then
                local checkin = node.coordsList and node.coordsList.checkin
                local beds = collectBedSpots(node.coordsList)
                local minEMS = tonumber(node.minEMS) or 1

                if checkin and checkin.x and #beds > 0 then
                    local locationNode = GetLinkedNodeByType(node.id, 'location', DepartmentData)
                    local label = (locationNode and locationNode.label) or node.label or _L('hospital')

                    createCheckInPoint(node.id, checkin, beds, label, onDutyCount >= minEMS, minEMS, version)
                end
            end
        end
    end)
end)

RegisterNetEvent('amb_client:SyncMembers', function(members)
    MemberData = members or {}

    SendNUIMessage({
        action = 'amb_syncMembers',
        members = members
    })
end)

local function loadDepartmentData()
    Framework.TriggerCallback('amb_server:getData', function(result)
        if result and result.dept then
            DepartmentData = result.dept
            MemberData = result.members or {}

            RefreshBlipsAndZones(DepartmentData)
            TriggerEvent('amb_client:PushLocaleToUI', Config.Locale)
        end
    end)
end

if Framework.PlayerLoadedEvent then
    RegisterNetEvent(Framework.PlayerLoadedEvent, function()
        refreshPermissions()
        loadDepartmentData()
    end)
end

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        CreateThread(function()
            Wait(2000)
            refreshPermissions()
            loadDepartmentData()
        end)

        return
    end

    if resourceName == 'plt_xray' then
        CreateThread(function()
            Wait(1000)

            if DepartmentData and DepartmentData.nodes then
                if Config.Debug then
                    print('^2[plt_ambulance] plt_xray started; refreshing monitor panels.^7')
                end

                RefreshBlipsAndZones(DepartmentData)
            end
        end)
    end
end)

if Framework.JobUpdateEvent then
    RegisterNetEvent(Framework.JobUpdateEvent, function(job)
        refreshPermissions()

        if Framework.Type == 'qb' then
            local previousDept = LocalPlayerJob.dept
            local previousGrade = LocalPlayerJob.grade
            local newDept = (job and job.name) or previousDept
            local newGrade = tonumber(job
                and ((type(job.grade) == 'table' and job.grade.level) or job.grade))
                or previousGrade
                or 0

            LocalPlayerJob.dept = newDept
            LocalPlayerJob.grade = newGrade
            LocalPlayerJob.onDuty = (job and job.onduty) or LocalPlayerJob.onDuty

            if previousDept == newDept
                and tonumber(previousGrade or 0) == tonumber(newGrade or 0) then
                return
            end
        end

        RefreshBlipsAndZones(DepartmentData)
    end)
end

RegisterNetEvent('plt_mdt_ems:client:updateETA', function(eta)
    if not (DepartmentData and DepartmentData.nodes) then
        return
    end

    for _, node in ipairs(DepartmentData.nodes) do
        if node.type == 'eta_arrival' then
            TriggerEvent('plt_xray:client:updateETADisplay', node.id, eta)
        end
    end
end)

RegisterNetEvent('amb_client:addDispatchCall', function(call)
    if type(call) ~= 'table' then
        return
    end

    TriggerEvent('plt_xray:client:updateDispatchOnETA', call)
end)

CreateThread(function()
    Wait(1000)

    if Framework.GetPlayerData() then
        refreshPermissions()
        loadDepartmentData()
    end
end)

