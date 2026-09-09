DepartmentData = {
    nodes = {},
    links = {},
    pan = { x = 0, y = 0, zoom = 1 },
    divisions = {}
}

MemberData = {}
DeptDutyLogs = {}
DataLoaded = false

local registeredStashes = {}
local esxDutyGrades = {}
local pendingExitProbes = {}

local isLicenseWhitelisted

local function getVehicleRearOffset(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return nil
    end

    local coords = GetEntityCoords(entity)
    local heading = GetEntityHeading(entity) or 0.0
    local radians = math.rad(heading)
    local distance = 5.2
    local heightOffset = 0.2

    return {
        x = coords.x - (math.sin(radians) * distance),
        y = coords.y - (math.cos(radians) * distance),
        z = coords.z + heightOffset,
        heading = heading
    }
end

local function countTableEntries(value)
    if type(value) ~= 'table' then
        return 0
    end

    local count = 0

    for _ in pairs(value) do
        count = count + 1
    end

    return count
end

local function countNodes(data)
    if type(data) ~= 'table' or type(data.nodes) ~= 'table' then
        return 0
    end

    local count = #data.nodes

    if count > 0 then
        return count
    end

    return countTableEntries(data.nodes)
end

local function ensureDepartmentShape(data)
    if type(data) ~= 'table' then
        return {
            nodes = {},
            links = {},
            pan = { x = 0, y = 0, zoom = 1 },
            divisions = {}
        }
    end

    if type(data.nodes) ~= 'table' then
        data.nodes = {}
    end

    if type(data.links) ~= 'table' then
        data.links = {}
    end

    if type(data.pan) ~= 'table' then
        data.pan = { x = 0, y = 0, zoom = 1 }
    end

    if type(data.divisions) ~= 'table' then
        data.divisions = {}
    end

    return data
end

local function isTable(value)
    return type(value) == 'table'
end

local function decodeDepartmentJson(raw)
    if not raw or raw == '' then
        return nil
    end

    local ok, decoded = pcall(json.decode, raw)

    if not ok or type(decoded) ~= 'table' then
        return nil
    end

    if not isTable(decoded) then
        return nil
    end

    return ensureDepartmentShape(decoded)
end

--[[
    Writes one key/value row into plt_ambulance_job_data.

    The old version returned whatever `pcall` said, which is NOT the same as
    "the row was written": oxmysql reports a failed query by returning nil
    instead of raising, so a missing table or a bad column produced
    "Configuration Saved and Synced!" on screen while nothing reached the
    database - and the placement was gone after the next restart.

    Now the write is read back and compared. Returns ok, reason.
]]
local function saveDataRow(key, value)
    if not key or not value then
        return false, 'missing key or value'
    end

    local queries = {
        {
            sql = 'INSERT INTO plt_ambulance_job_data (`key`, `value`) VALUES (?, ?) '
                .. 'ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)',
            params = { key, value }
        },
        {
            sql = 'INSERT INTO plt_ambulance_job_data (`key`, `value`) VALUES (@key, @value) '
                .. 'ON DUPLICATE KEY UPDATE `value` = @value',
            params = { ['@key'] = key, ['@value'] = value }
        }
    }

    local writeError

    for _, attempt in ipairs(queries) do
        local ok, err = pcall(MySQL.Sync.execute, attempt.sql, attempt.params)

        if ok then
            writeError = nil
            break
        end

        writeError = tostring(err)
    end

    if writeError then
        print(('^1[plt_ambulance] saveDataRow(%s) failed: %s^7'):format(tostring(key), writeError))

        return false, writeError
    end

    -- Verify. Without this a silently-failing INSERT looks like a success.
    local readOk, rows = pcall(MySQL.Sync.fetchAll,
        'SELECT `value` FROM plt_ambulance_job_data WHERE `key` = ?', { key })

    if not readOk then
        return false, 'could not verify write: ' .. tostring(rows)
    end

    if type(rows) ~= 'table' or type(rows[1]) ~= 'table' or rows[1].value == nil then
        return false, 'row is missing after write (is plt_ambulance_job_data present?)'
    end

    if tostring(rows[1].value) ~= tostring(value) then
        return false, 'read-back mismatch (value was truncated?)'
    end

    return true
end

local function createTables()
    local queries = {
        [[CREATE TABLE IF NOT EXISTS `plt_ambulance_job_data` (
            `key` VARCHAR(50) PRIMARY KEY,
            `value` LONGTEXT DEFAULT NULL
        );]],
        [[CREATE TABLE IF NOT EXISTS `plt_ambulance_job_members` (
            `citizenid` varchar(50) NOT NULL PRIMARY KEY,
            `name` varchar(100) DEFAULT NULL,
            `job` varchar(50) DEFAULT NULL,
            `grade` int(11) DEFAULT 0,
            `jobLabel` varchar(100) DEFAULT NULL,
            `gradeLabel` varchar(100) DEFAULT NULL,
            `ratings` LONGTEXT DEFAULT NULL
        );]],
        [[CREATE TABLE IF NOT EXISTS `plt_ambulance_job_pcrs` (
            `id` int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY,
            `patient` varchar(100) DEFAULT NULL,
            `condition` varchar(255) DEFAULT NULL,
            `treatment` text DEFAULT NULL,
            `author` varchar(100) DEFAULT NULL,
            `date` varchar(50) DEFAULT NULL,
            `timestamp` timestamp DEFAULT CURRENT_TIMESTAMP
        );]],
        [[CREATE TABLE IF NOT EXISTS `plt_ambulance_job_xrays` (
            `id` int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY,
            `citizenid` varchar(50) DEFAULT NULL,
            `injuries` text DEFAULT NULL,
            `date` varchar(50) DEFAULT NULL,
            `timestamp` timestamp DEFAULT CURRENT_TIMESTAMP
        );]],
        [[CREATE TABLE IF NOT EXISTS `plt_ambulance_job_duty_logs` (
            `id` int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY,
            `dept_job` varchar(50) DEFAULT NULL,
            `officer` varchar(100) DEFAULT NULL,
            `action` varchar(50) DEFAULT NULL,
            `date` varchar(50) DEFAULT NULL,
            `time` varchar(20) DEFAULT NULL,
            `timestamp` timestamp DEFAULT CURRENT_TIMESTAMP,
            INDEX `idx_dept_job` (`dept_job`),
            INDEX `idx_timestamp` (`timestamp`)
        );]],
        [[CREATE TABLE IF NOT EXISTS `plt_ambulance_job_mails` (
            `id` int(11) NOT NULL AUTO_INCREMENT PRIMARY KEY,
            `sender_dept` varchar(50) DEFAULT NULL,
            `receiver_dept` varchar(50) DEFAULT NULL,
            `sender_name` varchar(100) DEFAULT NULL,
            `subject` varchar(255) DEFAULT NULL,
            `message` longtext DEFAULT NULL,
            `image_url` varchar(500) DEFAULT NULL,
            `date` varchar(50) DEFAULT NULL,
            `time` varchar(20) DEFAULT NULL,
            `is_read` tinyint(1) DEFAULT 0,
            `timestamp` timestamp DEFAULT CURRENT_TIMESTAMP
        );]]
    }

    for _, query in ipairs(queries) do
        local ok = pcall(function()
            MySQL.Sync.execute(query, {})
        end)

        if not ok then
            print('^1[plt_ambulance] SQL init query failed, continuing.^7')
        end
    end
end

local function columnExists(tableName, columnName)
    local ok, result = pcall(function()
        return MySQL.Sync.fetchAll([[
            SELECT 1
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME = ?
              AND COLUMN_NAME = ?
            LIMIT 1
        ]], { tableName, columnName })
    end)

    if ok and result then
        return result[1] ~= nil
    end

    return ok and result
end

local function migrateDutyLogsTable()
    local tableName = 'plt_ambulance_job_duty_logs'

    if not columnExists(tableName, 'dept_job') then
        local ok = pcall(function()
            MySQL.Sync.execute(
                ('ALTER TABLE `%s` ADD COLUMN `dept_job` varchar(50) DEFAULT NULL AFTER `id`'):format(tableName), {})
        end)

        if not ok then
            print('^1[plt_ambulance] Failed to add dept_job column to duty logs table.^7')
        end
    end

    local hasDeptJob = columnExists(tableName, 'dept_job')
    local hasLegacyJob = columnExists(tableName, 'job')

    if hasDeptJob and hasLegacyJob then
        pcall(function()
            MySQL.Sync.execute(
                ("UPDATE `%s` SET `dept_job` = `job` WHERE (`dept_job` IS NULL OR `dept_job` = '') AND `job` IS NOT NULL AND `job` != ''"):format(tableName),
                {})
        end)
    end

    if hasDeptJob then
        pcall(function()
            MySQL.Sync.execute(('ALTER TABLE `%s` ADD INDEX `idx_dept_job` (`dept_job`)'):format(tableName), {})
        end)
    end

    pcall(function()
        MySQL.Sync.execute(('ALTER TABLE `%s` ADD INDEX `idx_timestamp` (`timestamp`)'):format(tableName), {})
    end)
end

local function migrateMailsTable()
    local tableName = 'plt_ambulance_job_mails'

    if columnExists(tableName, 'image_url') then
        return
    end

    local ok = pcall(function()
        MySQL.Sync.execute(
            ('ALTER TABLE `%s` ADD COLUMN `image_url` varchar(500) DEFAULT NULL AFTER `message`'):format(tableName), {})
    end)

    if not ok then
        print('^1[plt_ambulance] Failed to add image_url column to mails table.^7')
    end
end

local function fetchDutyLogs()
    local ok, rows = pcall(function()
        return MySQL.Sync.fetchAll(
            'SELECT dept_job, officer, action, `date`, `time` FROM plt_ambulance_job_duty_logs ORDER BY id DESC', {})
    end)

    if ok and rows then
        return rows
    end

    local legacyOk, legacyRows = pcall(function()
        return MySQL.Sync.fetchAll(
            'SELECT `job` AS dept_job, officer, action, `date`, `time` FROM plt_ambulance_job_duty_logs ORDER BY id DESC', {})
    end)

    if legacyOk and legacyRows then
        return legacyRows
    end

    return {}
end

exports('GetFramework', function()
    return Framework
end)

createTables()
migrateDutyLogsTable()
migrateMailsTable()

local function loadData()
    local ok, rows = pcall(function()
        return MySQL.Sync.fetchAll('SELECT * FROM plt_ambulance_job_data', {})
    end)

    if not ok or type(rows) ~= 'table' then
        print('^3[plt_ambulance] Department DB load failed, trying local cache fallback.^7')
        rows = {}
    end

    local departmentsRaw = nil
    local departmentsBackupRaw = nil

    for _, row in ipairs(rows) do
        if row.key == 'departments' then
            departmentsRaw = row.value
        elseif row.key == 'departments_backup' then
            departmentsBackupRaw = row.value
        end
    end

    local departments = decodeDepartmentJson(departmentsRaw)
    local departmentsBackup = decodeDepartmentJson(departmentsBackupRaw)

    if departments and countNodes(departments) > 0 then
        DepartmentData = departments
    elseif departmentsBackup and countNodes(departmentsBackup) > 0 then
        DepartmentData = departmentsBackup

        print('^3[plt_ambulance] departments row was empty/invalid, restored from departments_backup.^7')

        saveDataRow('departments', json.encode(DepartmentData))
    elseif departments then
        DepartmentData = ensureDepartmentShape(departments)
    else
        DepartmentData = ensureDepartmentShape(DepartmentData)
    end

    local membersOk, memberRows = pcall(function()
        return MySQL.Sync.fetchAll('SELECT * FROM plt_ambulance_job_members', {})
    end)

    if not membersOk or type(memberRows) ~= 'table' then
        print('^3[plt_ambulance] Member DB load failed; continuing with empty member cache.^7')
        memberRows = {}
    end

    for _, row in ipairs(memberRows) do
        MemberData[row.citizenid] = {
            name = row.name,
            job = row.job,
            grade = row.grade,
            jobLabel = row.jobLabel,
            gradeLabel = row.gradeLabel,
            ratings = json.decode(row.ratings or '{}')
        }
    end

    local dutyLogs = fetchDutyLogs()

    if dutyLogs then
        for _, log in ipairs(dutyLogs) do
            local deptJob = log.dept_job or 'ambulance'

            DeptDutyLogs[deptJob] = DeptDutyLogs[deptJob] or {}

            if #DeptDutyLogs[deptJob] < 100 then
                table.insert(DeptDutyLogs[deptJob], {
                    officer = log.officer,
                    action = log.action,
                    date = log.date,
                    time = log.time
                })
            end
        end
    end

    DataLoaded = true
end

loadData()

CreateThread(function()
    Wait(1500)

    TriggerClientEvent('amb_client:SyncJobs', -1, DepartmentData)
    TriggerClientEvent('amb_client:SyncMembers', -1, MemberData)
end)

function SaveDepartments()
    DepartmentData = ensureDepartmentShape(DepartmentData)

    local encoded = json.encode(DepartmentData)

    if not encoded or encoded == '' or encoded == 'null' then
        print('^1[plt_ambulance] SaveDepartments aborted: failed to encode department data.^7')
        return false
    end

    local savedMain, mainReason = saveDataRow('departments', encoded)
    local savedBackup, backupReason = saveDataRow('departments_backup', encoded)

    if not savedMain or not savedBackup then
        print(('^1[plt_ambulance] SaveDepartments warning: departments=%s (%s) backup=%s (%s)^7'):format(
            tostring(savedMain), tostring(mainReason),
            tostring(savedBackup), tostring(backupReason)))
    end

    if not savedMain and not savedBackup then
        return false, (mainReason or backupReason or 'SQL write failed')
    end

    TriggerClientEvent('amb_client:SyncJobs', -1, DepartmentData)

    return true
end

function GetFrameworkJobForDepartment(departmentId)
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

function GetDepartmentIdForFrameworkJob(jobName)
    if not (DepartmentData and DepartmentData.nodes) then
        return nil
    end

    for _, node in ipairs(DepartmentData.nodes) do
        if node.type == 'department' then
            local nodeJob = (node.frameworkJob and node.frameworkJob ~= '' and node.frameworkJob) or node.id

            if tostring(nodeJob) == tostring(jobName) then
                return node.id
            end
        end
    end

    return nil
end

--[[
    IsEMS.

    The framework job in Config.Medical.EMSJobs is checked FIRST and on its own.
    It used to sit behind a `DepartmentData.nodes` guard, so on a fresh install
    with no departments configured in the editor IsEMS() returned false for
    everybody - including a player whose job was literally `ambulance` after
    /setjob. The department-node lookup below is an *extra* for custom
    departments, not a precondition.
]]
function IsEMS(src)
    if Framework.HasPermission(src, Config.Permission) and Config.AdminBypass then
        return true
    end

    local player = Framework.GetPlayer(src)

    if not player then
        return false
    end

    local jobName = (player.job and player.job.name) or 'none'
    local citizenId = player.citizenid
    local memberJob = (MemberData[citizenId] and MemberData[citizenId].job) or 'none'

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
            local nodeJob = (node.frameworkJob and node.frameworkJob ~= '' and node.frameworkJob) or node.id

            if tostring(jobName) == tostring(node.id)
                or tostring(jobName) == tostring(nodeJob)
                or tostring(memberJob) == tostring(node.id) then
                return true
            end
        end
    end

    return false
end

exports('IsEMS', IsEMS)
exports('GetDepartmentIdForFrameworkJob', GetDepartmentIdForFrameworkJob)
exports('GetFrameworkJobForDepartment', GetFrameworkJobForDepartment)

exports('GetDutyLogs', function()
    return DeptDutyLogs or {}
end)

local function esxJobExists(jobName)
    if Framework.Type ~= 'esx' or not jobName or jobName == '' then
        return false
    end

    local ok, rows = pcall(function()
        return MySQL.Sync.fetchAll('SELECT `name` FROM `jobs` WHERE `name` = ? LIMIT 1', { jobName })
    end)

    if ok and rows then
        return rows[1] ~= nil
    end

    return ok and rows
end

local function resolveEsxDutyJobs(currentJobName, departmentJob)
    local currentJob = tostring(currentJobName or '')
    local baseJob = tostring(departmentJob or currentJob)

    if currentJob:sub(1, 4) == 'off_' then
        return currentJob:sub(5), currentJob, false
    end

    if currentJob:sub(1, 3) == 'off' and #currentJob > 3 then
        return currentJob:sub(4), currentJob, false
    end

    if currentJob:sub(-8) == '_offduty' then
        return currentJob:sub(1, -9), currentJob, false
    end

    if currentJob:sub(-4) == '_off' then
        return currentJob:sub(1, -5), currentJob, false
    end

    local candidates = {
        'off' .. baseJob,
        'off_' .. baseJob,
        baseJob .. '_offduty',
        baseJob .. '_off'
    }

    for _, candidate in ipairs(candidates) do
        if esxJobExists(candidate) then
            return baseJob, candidate, true
        end
    end

    return baseJob, candidates[1], true
end

local function resolveEsxGrade(jobName, grade)
    local requestedGrade = tonumber(grade) or 0

    if Framework.Type ~= 'esx' or not jobName or jobName == '' then
        return requestedGrade
    end

    local ok, rows = pcall(function()
        return MySQL.Sync.fetchAll(
            'SELECT `grade` FROM `job_grades` WHERE `job_name` = ? AND `grade` = ? LIMIT 1',
            { jobName, requestedGrade })
    end)

    if ok and rows and rows[1] then
        return requestedGrade
    end

    local fallbackOk, fallbackRows = pcall(function()
        return MySQL.Sync.fetchAll(
            'SELECT `grade` FROM `job_grades` WHERE `job_name` = ? ORDER BY `grade` ASC LIMIT 1',
            { jobName })
    end)

    if fallbackOk and fallbackRows and fallbackRows[1] and fallbackRows[1].grade ~= nil then
        return tonumber(fallbackRows[1].grade) or 0
    end

    return requestedGrade
end

local function rememberEsxGrade(src, jobName, grade)
    if Framework.Type ~= 'esx' then
        return
    end

    local job = tostring(jobName or '')

    if job == '' then
        return
    end

    if type(esxDutyGrades[src]) ~= 'table' then
        esxDutyGrades[src] = {}
    end

    esxDutyGrades[src][job] = tonumber(grade) or 0
end

local function getRememberedEsxGrade(src, jobName)
    local grades = esxDutyGrades[src]

    if type(grades) ~= 'table' then
        return nil
    end

    local job = tostring(jobName or '')

    if job == '' then
        return nil
    end

    return tonumber(grades[job])
end

local function canManage(src)
    local allowed = Framework.HasPermission(src, Config.Permission)

    if not allowed then
        allowed = isLicenseWhitelisted(src)
    end

    return allowed
end

RegisterNetEvent('amb_server:save', function(data)
    local src = source

    if not canManage(src) then
        Framework.Notify(src, _L('no_command_permission'), 'error')
        return
    end

    if not data then
        return
    end

    if not isTable(data) then
        Framework.Notify(src, 'Invalid department data format.', 'error')
        return
    end

    data = ensureDepartmentShape(data)

    local incomingNodes = countNodes(data)
    local existingNodes = countNodes(DepartmentData)

    if existingNodes > 0 and incomingNodes == 0 then
        Framework.Notify(src, 'Blocked save: received empty nodes while existing configuration is not empty.', 'error')

        print(('[plt_ambulance] Blocked potentially destructive save from %s (%s): existingNodes=%s incomingNodes=%s'):format(
            tostring(GetPlayerName(src) or 'unknown'),
            tostring(src),
            tostring(existingNodes),
            tostring(incomingNodes)))

        return
    end

    DepartmentData = data

    local saved, reason = SaveDepartments()

    if saved then
        Framework.Notify(src, _L('config_saved_synced'), 'success')
    else
        Framework.Notify(src, 'Failed to persist department data: ' .. tostring(reason or 'unknown error'), 'error')
    end
end)

Framework.CreateCallback('amb_server:getData', function(_, cb)
    local attempts = 0

    while not DataLoaded and attempts < 100 do
        Wait(50)
        attempts = attempts + 1
    end

    cb({
        dept = DepartmentData,
        members = MemberData
    })
end)

Framework.CreateCallback('amb_server:checkPermissions', function(src, cb, permission)
    local hasPermission = Framework.HasPermission(src, permission)
    local whitelisted = isLicenseWhitelisted(src)

    cb(hasPermission or whitelisted)
end)

RegisterNetEvent('amb_server:requestManageEMSDirect', function()
    local src = source

    if not Framework.HasPermission(src, Config.Permission) and not isLicenseWhitelisted(src) then
        Framework.Notify(src, _L('command_no_permission'), 'error')
        return
    end

    TriggerClientEvent('amb_client:openManageEMSDirect', src, {
        dept = DepartmentData,
        members = MemberData
    })
end)

local function isPlayerOnDuty(player)
    return player and player.job and (player.job.onduty == true or player.job.onduty == 1)
end

Framework.CreateCallback('amb_server:getEMSOnDutyCount', function(_, cb)
    local count = 0

    for _, playerId in ipairs(Framework.GetPlayers()) do
        local src = tonumber(playerId)

        if exports.plt_ambulance_job:IsEMS(src) then
            local player = Framework.GetPlayer(src)

            if isPlayerOnDuty(player) then
                count = count + 1
            end
        end
    end

    cb(count)
end)

Framework.CreateCallback('amb_server:isAnyEMSOnDuty', function(_, cb)
    for _, playerId in ipairs(Framework.GetPlayers()) do
        local src = tonumber(playerId)

        if exports.plt_ambulance_job:IsEMS(src) then
            local player = Framework.GetPlayer(src)

            if isPlayerOnDuty(player) then
                cb(true)
                return
            end
        end
    end

    cb(false)
end)

function GetPlayersList()
    local players = {}
    local onlineCitizenIds = {}

    for _, playerId in ipairs(GetPlayers()) do
        local player = Framework.GetPlayer(tonumber(playerId))

        if player then
            local citizenId = player.citizenid
            local member = MemberData[citizenId]

            table.insert(players, {
                id = tonumber(playerId),
                cid = citizenId,
                name = player.name,
                jobName = (member and member.job) or 'none',
                jobLabel = (member and member.jobLabel) or 'Not Hired',
                jobGradeLabel = (member and member.gradeLabel) or 'Civilian',
                jobGradeLevel = (member and member.grade) or 0,
                isOnline = true
            })

            onlineCitizenIds[citizenId] = true
        end
    end

    for citizenId, member in pairs(MemberData) do
        if not onlineCitizenIds[citizenId] then
            table.insert(players, {
                id = 0,
                cid = citizenId,
                name = member.name or 'Unknown',
                jobName = member.job or 'none',
                jobLabel = member.jobLabel or 'Not Hired',
                jobGradeLabel = member.gradeLabel or 'None',
                jobGradeLevel = member.grade or 0,
                isOnline = false
            })
        end
    end

    return players
end

Framework.CreateCallback('amb_server:getPlayers', function(_, cb)
    cb(GetPlayersList())
end)

Framework.CreateCallback('amb_server:prepareDepartmentStash', function(_, cb, data)
    local stashId = (data and tostring(data.stashId or '')) or ''

    if stashId == '' then
        cb({ ok = false })
        return
    end

    local label = (data and tostring(data.label or 'Department Stash')) or 'Department Stash'
    local slots = tonumber(data and data.slots) or 80
    local maxWeight = tonumber(data and data.maxWeight) or 400000
    local inventory = Bridge.Inventory or 'none'
    local cacheKey = inventory .. ':' .. stashId

    if registeredStashes[cacheKey] ~= true then
        if not (Inventory and Inventory.RegisterStash and Inventory.RegisterStash(stashId, label, slots, maxWeight)) then
            cb({ ok = false })
            return
        end

        registeredStashes[cacheKey] = true
    end

    cb({
        ok = true,
        stashId = stashId,
        inventory = inventory
    })
end)

Framework.CreateCallback('amb_server:getEMSInventoryData', function(_, cb)
    local items = {}

    for category, entries in pairs(Config.EMSItems or {}) do
        items[category] = entries
    end

    cb(items)
end)

RegisterNetEvent('amb_server:takeEMSInventoryItem', function(data)
    local src = source

    if not Framework.GetPlayer(src) then
        return
    end

    local itemName = data.item

    if Inventory.CanCarryItem(src, itemName, 1) then
        Inventory.AddItem(src, itemName, 1)
        Framework.Notify(src, _L('received_item', { item = itemName }), 'success')
    else
        Framework.Notify(src, _L('cannot_carry_more_item'), 'error')
    end
end)

RegisterNetEvent('amb_server:ToggleDuty', function(departmentId)
    local src = source
    local player = Framework.GetPlayer(src)

    if not player then
        return
    end

    local deptId = departmentId or (player.job and player.job.name) or 'ambulance'

    DeptDutyLogs[deptId] = DeptDutyLogs[deptId] or {}

    local nowOnDuty = false

    if Framework.Type == 'qb' then
        nowOnDuty = not player.job.onduty
        player.functions.SetJobDuty(nowOnDuty)
    elseif Framework.Type == 'esx' then
        local departmentJob = GetFrameworkJobForDepartment(deptId)
        local currentJob = player.job and (player.job.rawName or player.job.name)
        local onDutyJob, offDutyJob, isOnDuty = resolveEsxDutyJobs(currentJob, departmentJob)
        local currentGrade = tonumber(player.job.grade) or 0
        local targetJob = (isOnDuty and offDutyJob) or onDutyJob
        local targetGrade = currentGrade

        if isOnDuty then
            rememberEsxGrade(src, onDutyJob, currentGrade)
        else
            targetGrade = getRememberedEsxGrade(src, onDutyJob) or currentGrade
        end

        if not esxJobExists(targetJob) then
            Framework.Notify(src, ("Duty toggle failed: ESX job '%s' does not exist."):format(tostring(targetJob)), 'error')
            return
        end

        Framework.SetJob(src, targetJob, resolveEsxGrade(targetJob, targetGrade))

        Wait(100)

        local updatedPlayer = Framework.GetPlayer(src)
        local updatedJob = updatedPlayer and updatedPlayer.job and (updatedPlayer.job.rawName or updatedPlayer.job.name)

        if tostring(updatedJob) ~= tostring(targetJob) then
            Framework.Notify(src, 'Duty toggle failed: framework job did not update.', 'error')
            return
        end

        nowOnDuty = not isOnDuty
    end

    local officerName = player.name

    if not officerName then
        if player.charinfo then
            officerName = (player.charinfo.firstname or '') .. ' ' .. (player.charinfo.lastname or '')
        else
            officerName = 'Unknown'
        end
    end

    local action = nowOnDuty and 'Clocked On' or 'Clocked Off'
    local date = os.date('%B %d, %Y')
    local time = os.date('%H:%M')

    table.insert(DeptDutyLogs[deptId], {
        officer = officerName,
        action = action,
        date = date,
        time = time
    })

    if #DeptDutyLogs[deptId] > 100 then
        table.remove(DeptDutyLogs[deptId], 1)
    end

    local logged = pcall(function()
        MySQL.Sync.execute(
            'INSERT INTO plt_ambulance_job_duty_logs (dept_job, officer, action, `date`, `time`) VALUES (?, ?, ?, ?, ?)',
            { deptId, officerName, action, date, time })
    end)

    if not logged then
        pcall(function()
            MySQL.Sync.execute(
                'INSERT INTO plt_ambulance_job_duty_logs (`job`, officer, action, `date`, `time`) VALUES (?, ?, ?, ?, ?)',
                { deptId, officerName, action, date, time })
        end)
    end

    TriggerClientEvent('amb_client:SyncData', -1, { dutyLogs = DeptDutyLogs })
    TriggerClientEvent('amb_client:RefreshCheckInZones', -1)

    local status = nowOnDuty and _L('duty_status_on') or _L('duty_status_off')

    Framework.Notify(src, _L('duty_now', { status = status }), 'info')
end)

AddEventHandler('playerDropped', function()
    esxDutyGrades[source] = nil
end)

function SaveMemberToDB(citizenId)
    local member = MemberData[citizenId]

    if not member then
        return
    end

    MySQL.Async.execute(
        'INSERT INTO plt_ambulance_job_members (`citizenid`, `name`, `job`, `grade`, `jobLabel`, `gradeLabel`, `ratings`) VALUES (@cid, @name, @job, @grade, @jobLabel, @gradeLabel, @ratings) ON DUPLICATE KEY UPDATE `name` = @name, `job` = @job, `grade` = @grade, `jobLabel` = @jobLabel, `gradeLabel` = @gradeLabel, `ratings` = @ratings',
        {
            ['@cid'] = citizenId,
            ['@name'] = member.name,
            ['@job'] = member.job,
            ['@grade'] = member.grade,
            ['@jobLabel'] = member.jobLabel,
            ['@gradeLabel'] = member.gradeLabel,
            ['@ratings'] = json.encode(member.ratings or {})
        })

    TriggerClientEvent('amb_client:SyncMembers', -1, MemberData)
end

function SyncPlayerJobWithMemberData(src)
    local player = Framework.GetPlayer(src)

    if not player then
        return
    end

    local jobName = player.job.name
    local grade = tonumber(player.job.grade) or 0
    local citizenId = player.citizenid
    local departmentId = GetDepartmentIdForFrameworkJob(jobName)

    if not departmentId then
        if MemberData[citizenId] then
            MemberData[citizenId] = nil

            MySQL.Async.execute('DELETE FROM plt_ambulance_job_members WHERE citizenid = ?', { citizenId })

            TriggerClientEvent('amb_client:SyncMembers', -1, MemberData)
        end

        return
    end

    local departmentLabel = 'Unknown'
    local gradeLabel = 'Rank ' .. grade

    for _, node in ipairs(DepartmentData.nodes or {}) do
        if node.type == 'department' and node.id == departmentId then
            departmentLabel = node.label or departmentId

            for _, link in ipairs(DepartmentData.links or {}) do
                if link.from == departmentId then
                    for _, linkedNode in ipairs(DepartmentData.nodes) do
                        if linkedNode.id == link.to and linkedNode.type == 'rank' and linkedNode.ranks then
                            for _, rank in ipairs(linkedNode.ranks) do
                                if tonumber(rank.level) == grade then
                                    gradeLabel = rank.name or gradeLabel
                                    break
                                end
                            end
                        end
                    end
                end
            end

            break
        end
    end

    MemberData[citizenId] = {
        name = player.name,
        job = departmentId,
        grade = grade,
        jobLabel = departmentLabel,
        gradeLabel = gradeLabel,
        ratings = (MemberData[citizenId] and MemberData[citizenId].ratings) or {}
    }

    SaveMemberToDB(citizenId)
end

if Framework.PlayerLoadedEvent then
    RegisterNetEvent(Framework.PlayerLoadedEvent, function(playerId)
        local target = tonumber(playerId) or source

        SyncPlayerJobWithMemberData(target)

        -- Make sure a joining player always receives the current department
        -- layout, even if they connect after the one-off startup broadcast.
        CreateThread(function()
            local attempts = 0

            while not DataLoaded and attempts < 100 do
                Wait(50)
                attempts = attempts + 1
            end

            TriggerClientEvent('amb_client:SyncJobs', target, DepartmentData)
            TriggerClientEvent('amb_client:SyncMembers', target, MemberData)
        end)
    end)
end

if Framework.JobUpdateEvent then
    RegisterNetEvent(Framework.JobUpdateEvent, function(playerId)
        SyncPlayerJobWithMemberData(tonumber(playerId) or source)
    end)
end

isLicenseWhitelisted = function(src)
    if Config.UseLicenseWhitelist ~= true then
        return false
    end

    local whitelist = Config.LicenseWhitelist

    if not whitelist or type(whitelist) ~= 'table' or #whitelist == 0 then
        return false
    end

    local function normalizeIdentifier(identifier)
        if type(identifier) ~= 'string' then
            return nil
        end

        identifier = identifier:gsub('^%s+', ''):gsub('%s+$', ''):lower()

        if identifier == '' then
            return nil
        end

        if not identifier:find(':', 1, true) and #identifier >= 20 then
            identifier = 'license:' .. identifier
        end

        return identifier
    end

    local function isPlaceholder(identifier)
        if type(identifier) ~= 'string' then
            return true
        end

        local value = identifier:lower():gsub('%s+', '')

        if value == '' then
            return true
        end

        value = value:gsub('^license2?:', '')

        if value == '' then
            return true
        end

        if value:find('^x+$') then
            return true
        end

        if value:find('^example') or value:find('^changeme') or value:find('^your_') or value:find('^your%-') then
            return true
        end

        return false
    end

    local allowedIdentifiers = {}
    local hasValidEntry = false

    for _, entry in ipairs(whitelist) do
        local identifier = normalizeIdentifier(entry)

        if identifier and not isPlaceholder(identifier) then
            allowedIdentifiers[identifier] = true

            if identifier:sub(1, 9) == 'license2:' then
                allowedIdentifiers['license:' .. identifier:sub(10)] = true
            elseif identifier:sub(1, 8) == 'license:' then
                allowedIdentifiers['license2:' .. identifier:sub(9)] = true
            end

            hasValidEntry = true
        end
    end

    if not hasValidEntry then
        return false
    end

    for _, rawIdentifier in ipairs(GetPlayerIdentifiers(src)) do
        local identifier = normalizeIdentifier(rawIdentifier)

        if identifier then
            local isLicense = identifier:sub(1, 8) == 'license:' or identifier:sub(1, 9) == 'license2:'

            if isLicense then
                if allowedIdentifiers[identifier] then
                    return true
                end

                if identifier:sub(1, 9) == 'license2:' then
                    if allowedIdentifiers['license:' .. identifier:sub(10)] then
                        return true
                    end
                elseif identifier:sub(1, 8) == 'license:' then
                    if allowedIdentifiers['license2:' .. identifier:sub(9)] then
                        return true
                    end
                end
            end
        end
    end

    return false
end

RegisterNetEvent('amb_server:setPlayerRoutingBucket', function(bucket)
    local src = source
    local bucketId = tonumber(bucket) or 0

    if bucketId < 0 then
        bucketId = 0
    end

    if bucketId > 2147483646 then
        bucketId = 2147483646
    end

    SetPlayerRoutingBucket(src, bucketId)
end)

Framework.CreateCallback('amb_server:getAmbulanceInteriorExitData', function(_, cb, netId)
    local vehicleNetId = tonumber(netId)

    if not vehicleNetId or vehicleNetId <= 0 then
        cb(nil)
        return
    end

    local entity = NetworkGetEntityFromNetworkId(vehicleNetId)

    if not entity or entity == 0 or not DoesEntityExist(entity) then
        cb(nil)
        return
    end

    cb(getVehicleRearOffset(entity))
end)

RegisterNetEvent('amb_server:requestAmbulanceExitData', function(requestKey, netId)
    local src = source
    local key = tostring(requestKey or '')
    local vehicleNetId = tonumber(netId)

    if key == '' or not vehicleNetId or vehicleNetId <= 0 then
        TriggerClientEvent('amb_client:receiveAmbulanceExitData', src, key, nil)
        return
    end

    local entity = NetworkGetEntityFromNetworkId(vehicleNetId)

    if entity and entity ~= 0 and DoesEntityExist(entity) then
        TriggerClientEvent('amb_client:receiveAmbulanceExitData', src, key, getVehicleRearOffset(entity))
        return
    end

    pendingExitProbes[key] = {
        requester = src,
        createdAt = GetGameTimer()
    }

    TriggerClientEvent('amb_client:probeAmbulanceExitData', -1, key, vehicleNetId, src)

    CreateThread(function()
        Wait(1500)

        local probe = pendingExitProbes[key]

        if not probe then
            return
        end

        pendingExitProbes[key] = nil

        if GetPlayerPing(probe.requester) > 0 then
            TriggerClientEvent('amb_client:receiveAmbulanceExitData', probe.requester, key, nil)
        end
    end)
end)

RegisterNetEvent('amb_server:submitAmbulanceExitDataProbe', function(requestKey, requesterId, exitData)
    local key = tostring(requestKey or '')
    local requester = tonumber(requesterId)

    if key == '' or not requester or requester <= 0 then
        return
    end

    local probe = pendingExitProbes[key]

    if not probe then
        return
    end

    if tonumber(probe.requester) ~= requester then
        return
    end

    if type(exitData) ~= 'table' or exitData.x == nil or exitData.y == nil or exitData.z == nil then
        return
    end

    pendingExitProbes[key] = nil

    if GetPlayerPing(requester) <= 0 then
        return
    end

    TriggerClientEvent('amb_client:receiveAmbulanceExitData', requester, key, {
        x = tonumber(exitData.x) or 0.0,
        y = tonumber(exitData.y) or 0.0,
        z = tonumber(exitData.z) or 0.0,
        heading = tonumber(exitData.heading) or 0.0
    })
end)

RegisterNetEvent('amb_server:enterAmbulanceInteriorWithPatient', function(patientId, bucket, vehicleNetId, exitData, stretcherNetId)
    local src = source
    local patient = tonumber(patientId)
    local bucketId = tonumber(bucket) or 0
    local stretcher = tonumber(stretcherNetId)

    if bucketId < 0 then
        bucketId = 0
    end

    if bucketId > 2147483646 then
        bucketId = 2147483646
    end

    SetPlayerRoutingBucket(src, bucketId)

    if not patient or patient <= 0 or patient == src then
        return
    end

    if GetPlayerPing(patient) <= 0 then
        return
    end

    SetPlayerRoutingBucket(patient, bucketId)

    if stretcher and stretcher > 0 then
        local stretcherEntity = NetworkGetEntityFromNetworkId(stretcher)

        if stretcherEntity and stretcherEntity ~= 0 and DoesEntityExist(stretcherEntity) then
            DeleteEntity(stretcherEntity)
        end
    end

    TriggerClientEvent('amb_client:enterAmbulanceInteriorAsPatient', patient, {
        vehicleNetId = tonumber(vehicleNetId) or 0,
        bucket = bucketId,
        exitData = (type(exitData) == 'table' and exitData) or nil
    })
end)

