local BLOOD_TYPES = { 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-' }

local VALID_BLOOD_TYPES = {
    ['A+'] = true,
    ['A-'] = true,
    ['B+'] = true,
    ['B-'] = true,
    ['AB+'] = true,
    ['AB-'] = true,
    ['O+'] = true,
    ['O-'] = true
}

local newsList = {}
local newsLoaded = false
local pcrList = {}
local pcrsLoaded = false
local pcrTableAvailable = true
local balances = {}
local finances = {}
local financesLoaded = false
local patientProfiles = {}
local emsInvoices = {}
local invoiceCounter = 0

CreateThread(function()
    while not MySQL do
        Wait(10)
    end

    local newsRows = MySQL.Sync.fetchAll('SELECT value FROM plt_ambulance_job_data WHERE `key` = ?', { 'news' })

    if newsRows[1] then
        newsList = json.decode(newsRows[1].value) or {}
    end

    newsLoaded = true

    if Framework.Type == 'esx' then
        local ok, rows = pcall(function()
            return MySQL.Sync.fetchAll('SHOW TABLES LIKE ?', { 'plt_ambulance_job_pcrs' })
        end)

        if ok and rows then
            pcrTableAvailable = rows[1] ~= nil
        else
            pcrTableAvailable = ok and rows
        end
    end

    if pcrTableAvailable then
        pcrList = MySQL.Sync.fetchAll('SELECT * FROM plt_ambulance_job_pcrs ORDER BY id DESC LIMIT 50', {}) or {}
    else
        pcrList = {}
        print("^3[plt_ambulance][ESX] Table 'plt_ambulance_job_pcrs' not found; PCR persistence disabled until table is created.^7")
    end

    pcrsLoaded = true

    local balanceRows = MySQL.Sync.fetchAll('SELECT value FROM plt_ambulance_job_data WHERE `key` = ?', { 'balances' })

    if balanceRows[1] then
        balances = json.decode(balanceRows[1].value) or {}
    end

    local financeRows = MySQL.Sync.fetchAll('SELECT value FROM plt_ambulance_job_data WHERE `key` = ?', { 'finances' })

    if financeRows[1] then
        finances = json.decode(financeRows[1].value) or {}
    end

    financesLoaded = true

    local profileRows = MySQL.Sync.fetchAll('SELECT value FROM plt_ambulance_job_data WHERE `key` = ?', { 'patient_profiles' })

    if profileRows[1] then
        patientProfiles = json.decode(profileRows[1].value) or {}
    end
end)

function SaveNews()
    MySQL.Async.execute(
        'INSERT INTO plt_ambulance_job_data (`key`, `value`) VALUES (@key, @value) ON DUPLICATE KEY UPDATE `value` = @value',
        {
            ['@key'] = 'news',
            ['@value'] = json.encode(newsList)
        })

    TriggerClientEvent('amb_client:SyncNews', -1, newsList)
end

function SaveFinances(departmentId)
    MySQL.Async.execute(
        'INSERT INTO plt_ambulance_job_data (`key`, `value`) VALUES (@key, @value) ON DUPLICATE KEY UPDATE `value` = @value',
        {
            ['@key'] = 'balances',
            ['@value'] = json.encode(balances)
        })

    MySQL.Async.execute(
        'INSERT INTO plt_ambulance_job_data (`key`, `value`) VALUES (@key, @value) ON DUPLICATE KEY UPDATE `value` = @value',
        {
            ['@key'] = 'finances',
            ['@value'] = json.encode(finances)
        })

    TriggerClientEvent('amb_client:SyncData', -1, {
        balances = balances,
        finances = finances,
        transactions = departmentId and finances[departmentId] or nil
    })
end

local function savePatientProfiles()
    MySQL.Async.execute(
        'INSERT INTO plt_ambulance_job_data (`key`, `value`) VALUES (@key, @value) ON DUPLICATE KEY UPDATE `value` = @value',
        {
            ['@key'] = 'patient_profiles',
            ['@value'] = json.encode(patientProfiles)
        })
end

local function normalizeBloodType(value)
    if type(value) ~= 'string' then
        return nil
    end

    local bloodType = value:upper():gsub('%s+', '')

    if VALID_BLOOD_TYPES[bloodType] then
        return bloodType
    end

    return nil
end

local function ensurePatientProfile(citizenId, charInfo)
    local key = tostring(citizenId)
    local profile = patientProfiles[key] or {}

    local bloodType = normalizeBloodType(profile.blood_type)

    if bloodType then
        profile.blood_type = bloodType
    else
        profile.blood_type = (charInfo and normalizeBloodType(charInfo.bloodtype))
            or BLOOD_TYPES[math.random(1, #BLOOD_TYPES)]
    end

    local allergy = profile.known_allergy

    if type(allergy) ~= 'string' or allergy:gsub('%s+', '') == '' then
        local charAllergies = charInfo and charInfo.allergies

        if type(charAllergies) == 'string' and charAllergies:gsub('%s+', '') ~= '' then
            profile.known_allergy = charAllergies
        else
            profile.known_allergy = 'None'
        end
    end

    patientProfiles[key] = profile

    return profile
end

local function safeQuery(query, params, label)
    local ok, result = pcall(function()
        return MySQL.Sync.fetchAll(query, params or {})
    end)

    if not ok then
        print(('[plt_ambulance][ESX][%s] Query failed: %s'):format(label or 'unknown', tostring(result)))
        return nil
    end

    return result
end

local function normalizeEsxJob(jobName)
    local name = tostring(jobName or '')

    if name:sub(1, 4) == 'off_' then
        return name:sub(5), false
    end

    if name:sub(1, 3) == 'off' and #name > 3 then
        return name:sub(4), false
    end

    if name:sub(-8) == '_offduty' then
        return name:sub(1, -9), false
    end

    if name:sub(-4) == '_off' then
        return name:sub(1, -5), false
    end

    return name, true
end

local function getRankNodeForDepartment(departmentId)
    if not (DepartmentData and DepartmentData.links and DepartmentData.nodes) then
        return nil
    end

    local deptId = tostring(departmentId or '')

    for _, link in ipairs(DepartmentData.links) do
        local from = tostring(link.from or '')
        local to = tostring(link.to or '')
        local linkedId = nil

        if from == deptId then
            linkedId = to
        elseif to == deptId then
            linkedId = from
        end

        if linkedId then
            for _, node in ipairs(DepartmentData.nodes) do
                if tostring(node.id) == linkedId and node.type == 'rank' then
                    return node
                end
            end
        end
    end

    return nil
end

local function getRankPay(rankNode, grade)
    if not rankNode or type(rankNode.ranks) ~= 'table' then
        return 0
    end

    local level = tonumber(grade) or 0

    for _, rank in ipairs(rankNode.ranks) do
        if tonumber(rank.level) == level then
            return math.max(0, tonumber(rank.pay) or 0)
        end
    end

    return 0
end

local function getPlayerDepartmentId(player)
    if not player or not player.job then
        return nil
    end

    if type(GetDepartmentIdForFrameworkJob) == 'function' then
        local departmentId = GetDepartmentIdForFrameworkJob(player.job.name)

        if departmentId then
            return departmentId
        end
    end

    if Framework.Type == 'esx' then
        local baseJob = normalizeEsxJob(player.job.name)

        if type(GetDepartmentIdForFrameworkJob) == 'function' then
            local departmentId = GetDepartmentIdForFrameworkJob(baseJob)

            if departmentId then
                return departmentId
            end
        end
    end

    if MemberData and player.citizenid and MemberData[player.citizenid] and MemberData[player.citizenid].job then
        return MemberData[player.citizenid].job
    end

    return nil
end

local function collectSalaryRecipients(departmentId)
    local rankNode = getRankNodeForDepartment(departmentId)

    if not rankNode then
        return {}, 0
    end

    local recipients = {}
    local total = 0

    for _, playerId in ipairs(GetPlayers()) do
        local src = tonumber(playerId)
        local player = Framework.GetPlayer(src)

        if player then
            local playerDepartment = getPlayerDepartmentId(player)

            if tostring(playerDepartment) == tostring(departmentId) then
                local pay = getRankPay(rankNode, (player.job and player.job.grade) or 0)

                if pay > 0 then
                    recipients[#recipients + 1] = {
                        source = src,
                        amount = pay,
                        name = player.name or ('ID ' .. tostring(src))
                    }

                    total = total + pay
                end
            end
        end
    end

    return recipients, total
end

local function paySalary(entry)
    return Framework.AddMoney(entry.source, 'bank', entry.amount, 'department-salary')
end

local function getFinanceSystem()
    if type(Config.DepartmentFinance) == 'string' then
        return Config.DepartmentFinance
    end

    if type(Config.DepartmentFinance) == 'table' then
        return Config.DepartmentFinance.System or 'internal'
    end

    return 'internal'
end

local function getRenewedResourceName()
    if type(Config.DepartmentFinance) == 'table' and Config.DepartmentFinance.RenewedResource then
        return Config.DepartmentFinance.RenewedResource
    end

    return 'Renewed-Banking'
end

local function isRenewedBanking()
    local system = tostring(getFinanceSystem()):lower()

    if system ~= 'renewed-banking' and system ~= 'renewed_banking' then
        return false
    end

    return GetResourceState('Renewed-Banking') == 'started'
end

local function getDepartmentAccountName(departmentId)
    local prefix = 'ems_'

    if type(Config.DepartmentFinance) == 'table' and Config.DepartmentFinance.AccountPrefix then
        prefix = Config.DepartmentFinance.AccountPrefix
    end

    return tostring(prefix) .. tostring(departmentId)
end

local function callBankingExport(methodNames, ...)
    local resourceName = getRenewedResourceName()

    if GetResourceState(resourceName) ~= 'started' then
        return false, nil
    end

    local args = { ... }

    for _, methodName in ipairs(methodNames) do
        local ok, result = pcall(function()
            return exports[resourceName][methodName](table.unpack(args))
        end)

        if ok then
            return true, result
        end
    end

    return false, nil
end

local function getDepartmentBalance(departmentId)
    if not balances[departmentId] then
        balances[departmentId] = Config.DefaultDeptBalance or 500000
    end

    if not isRenewedBanking() then
        return balances[departmentId]
    end

    local accountName = getDepartmentAccountName(departmentId)
    local ok, result = callBankingExport({
        'getAccountMoney',
        'GetAccountMoney',
        'getAccountBalance',
        'GetAccountBalance',
        'getBalance',
        'GetBalance'
    }, accountName)

    if ok and tonumber(result) ~= nil then
        balances[departmentId] = tonumber(result)
    end

    return balances[departmentId]
end

local function applyBalanceChange(departmentId, changeType, amount, label, author)
    if not isRenewedBanking() then
        if not balances[departmentId] then
            balances[departmentId] = Config.DefaultDeptBalance or 500000
        end

        if changeType == 'deposit' then
            balances[departmentId] = balances[departmentId] + amount
            return true, balances[departmentId]
        elseif changeType == 'withdraw' then
            if amount > balances[departmentId] then
                return false, balances[departmentId]
            end

            balances[departmentId] = balances[departmentId] - amount
            return true, balances[departmentId]
        end

        return true, balances[departmentId]
    end

    local accountName = getDepartmentAccountName(departmentId)
    local reason = ('%s | %s'):format(tostring(label or 'Transaction'), tostring(author or 'SYSTEM'))
    local currentBalance = getDepartmentBalance(departmentId)

    if changeType == 'withdraw' and amount > currentBalance then
        return false, currentBalance
    end

    if changeType == 'deposit' then
        local ok = callBankingExport({
            'addAccountMoney',
            'AddAccountMoney',
            'addBalance',
            'AddBalance'
        }, accountName, amount, reason)

        if not ok then
            return false, currentBalance
        end
    elseif changeType == 'withdraw' then
        local ok = callBankingExport({
            'removeAccountMoney',
            'RemoveAccountMoney',
            'removeBalance',
            'RemoveBalance'
        }, accountName, amount, reason)

        if not ok then
            return false, currentBalance
        end
    end

    return true, getDepartmentBalance(departmentId)
end

function AddFinanceEntry(departmentId, changeType, amount, label, author)
    finances[departmentId] = finances[departmentId] or {}

    local ok, newBalance = applyBalanceChange(departmentId, changeType, amount, label, author)

    if not ok then
        return false
    end

    balances[departmentId] = newBalance

    table.insert(finances[departmentId], 1, {
        id = #finances[departmentId] + 1,
        type = changeType,
        amount = amount,
        label = label,
        author = author or 'SYSTEM',
        date = os.date('%B %d, %Y %H:%M'),
        balance = newBalance
    })

    if #finances[departmentId] > 50 then
        table.remove(finances[departmentId])
    end

    SaveFinances(departmentId)

    return true
end

exports('AddFinanceEntry', AddFinanceEntry)

local function getInvoiceConfig()
    return Config.EMSInvoice or {}
end

local function trim(value)
    if type(value) ~= 'string' then
        return ''
    end

    return value:gsub('^%s+', ''):gsub('%s+$', '')
end

local function getInvoiceDepartment(player)
    if not player or not player.job then
        return 'ambulance'
    end

    if type(GetDepartmentIdForFrameworkJob) == 'function' then
        local departmentId = GetDepartmentIdForFrameworkJob(player.job.name)

        if departmentId then
            return departmentId
        end
    end

    if MemberData and player.citizenid and MemberData[player.citizenid] and MemberData[player.citizenid].job then
        return MemberData[player.citizenid].job
    end

    return player.job.name or 'ambulance'
end

local function isWithinDistance(srcA, srcB, maxDistance)
    local distanceLimit = tonumber(maxDistance) or 0

    if distanceLimit <= 0 then
        return true
    end

    local pedA = GetPlayerPed(srcA)
    local pedB = GetPlayerPed(srcB)

    if not pedA or pedA == 0 or not pedB or pedB == 0 then
        return true
    end

    local coordsA = GetEntityCoords(pedA)
    local coordsB = GetEntityCoords(pedB)

    if not coordsA or not coordsB then
        return true
    end

    return #(coordsA - coordsB) <= distanceLimit
end

local function cleanupExpiredInvoices()
    local expireSeconds = (tonumber(getInvoiceConfig().ExpireMinutes) or 10) * 60

    if expireSeconds <= 0 then
        return
    end

    local now = os.time()

    for invoiceId, invoice in pairs(emsInvoices) do
        if not invoice.createdAt or (now - invoice.createdAt) > expireSeconds then
            emsInvoices[invoiceId] = nil
        end
    end
end

local function findInvoice(patientSrc, invoiceId)
    cleanupExpiredInvoices()

    if invoiceId then
        local invoice = emsInvoices[invoiceId]

        if invoice and invoice.patientSrc == patientSrc then
            return invoice
        end

        return nil
    end

    local latest = nil

    for _, invoice in pairs(emsInvoices) do
        if invoice.patientSrc == patientSrc then
            if not latest or invoice.id > latest.id then
                latest = invoice
            end
        end
    end

    return latest
end

local function chargeInvoice(player, amount)
    local accounts = getInvoiceConfig().PaymentAccounts

    if type(accounts) ~= 'table' or #accounts == 0 then
        accounts = { 'bank', 'cash' }
    end

    for _, accountName in ipairs(accounts) do
        local account = tostring(accountName or '')

        if account ~= '' then
            local available = tonumber(player.functions.GetMoney(account)) or 0

            if amount <= available then
                if player.functions.RemoveMoney(account, amount, 'ems-invoice-payment') then
                    return true, account
                end
            end
        end
    end

    return false, nil
end

local function createInvoice(src, targetId, amount, reason)
    local medic = Framework.GetPlayer(src)

    if not medic then
        return
    end

    if not exports.plt_ambulance_job:IsEMS(src) and not Framework.HasPermission(src, Config.Permission) then
        Framework.Notify(src, _L('not_authorized'), 'error')
        return
    end

    targetId = tonumber(targetId)

    if not targetId or not GetPlayerName(targetId) then
        Framework.Notify(src, _L('player_not_found'), 'error')
        return
    end

    local invoiceConfig = getInvoiceConfig()

    amount = math.floor(tonumber(amount) or 0)

    local maxAmount = tonumber(invoiceConfig.MaxAmount) or 100000

    if amount <= 0 or amount > maxAmount then
        Framework.Notify(src, _L('ems_invoice_bad_amount', { max = maxAmount }), 'error')
        return
    end

    reason = trim(reason)

    if reason == '' then
        Framework.Notify(src, _L('ems_invoice_no_reason'), 'error')
        return
    end

    if #reason > 120 then
        reason = reason:sub(1, 120)
    end

    if not isWithinDistance(src, targetId, invoiceConfig.MaxDistance) then
        Framework.Notify(src, _L('ems_invoice_too_far'), 'error')
        return
    end

    local patient = Framework.GetPlayer(targetId)

    if not patient then
        Framework.Notify(src, _L('player_not_found'), 'error')
        return
    end

    cleanupExpiredInvoices()

    invoiceCounter = invoiceCounter + 1

    local departmentId = getInvoiceDepartment(medic)

    local invoice = {
        id = invoiceCounter,
        medicSrc = src,
        patientSrc = targetId,
        dept = departmentId,
        amount = amount,
        reason = reason,
        medicName = medic.name,
        patientName = patient.name,
        departmentLabel = medic.job.label or departmentId,
        createdAt = os.time()
    }

    emsInvoices[invoice.id] = invoice

    Framework.Notify(src, _L('ems_invoice_sent', {
        id = invoice.id,
        name = patient.name,
        amount = amount
    }), 'success')

    Framework.Notify(targetId, _L('ems_invoice_received', {
        department = invoice.departmentLabel,
        id = invoice.id,
        amount = amount,
        reason = reason,
        payCommand = invoiceConfig.PayCommandName or 'payemsinvoice',
        declineCommand = invoiceConfig.DeclineCommandName or 'declineemsinvoice'
    }), 'warning')

    TriggerClientEvent('amb_client:EMSInvoiceReceived', targetId, invoice)
end

local function payInvoice(src, invoiceIdArg)
    local player = Framework.GetPlayer(src)

    if not player then
        return
    end

    local invoiceId = tonumber(invoiceIdArg)

    if invoiceIdArg and tostring(invoiceIdArg) ~= '' and not invoiceId then
        Framework.Notify(src, _L('ems_invoice_not_found'), 'error')
        return
    end

    local invoice = findInvoice(src, invoiceId)

    if not invoice then
        Framework.Notify(src, _L(invoiceIdArg and 'ems_invoice_not_found' or 'ems_invoice_none'), 'error')
        return
    end

    local paid, account = chargeInvoice(player, invoice.amount)

    if not paid then
        Framework.Notify(src, _L('ems_invoice_no_money'), 'error')
        return
    end

    local label = ('EMS Invoice #%s - %s'):format(invoice.id, invoice.reason)

    if not AddFinanceEntry(invoice.dept, 'deposit', invoice.amount, label, player.name) then
        player.functions.AddMoney(account, invoice.amount, 'ems-invoice-refund')
        Framework.Notify(src, _L('ems_invoice_finance_error'), 'error')
        return
    end

    emsInvoices[invoice.id] = nil

    Framework.Notify(src, _L('ems_invoice_paid_patient', {
        id = invoice.id,
        amount = invoice.amount
    }), 'success')

    if GetPlayerName(invoice.medicSrc) then
        Framework.Notify(invoice.medicSrc, _L('ems_invoice_paid_ems', {
            id = invoice.id,
            amount = invoice.amount,
            name = player.name
        }), 'success')
    end
end

local function declineInvoice(src, invoiceIdArg)
    local player = Framework.GetPlayer(src)

    if not player then
        return
    end

    local invoiceId = tonumber(invoiceIdArg)

    if invoiceIdArg and tostring(invoiceIdArg) ~= '' and not invoiceId then
        Framework.Notify(src, _L('ems_invoice_not_found'), 'error')
        return
    end

    local invoice = findInvoice(src, invoiceId)

    if not invoice then
        Framework.Notify(src, _L(invoiceIdArg and 'ems_invoice_not_found' or 'ems_invoice_none'), 'error')
        return
    end

    emsInvoices[invoice.id] = nil

    Framework.Notify(src, _L('ems_invoice_declined_patient', { id = invoice.id }), 'info')

    if GetPlayerName(invoice.medicSrc) then
        Framework.Notify(invoice.medicSrc, _L('ems_invoice_declined_ems', {
            id = invoice.id,
            name = player.name
        }), 'warning')
    end
end

RegisterNetEvent('amb_server:createEMSInvoice', function(targetId, amount, reason)
    createInvoice(source, targetId, amount, reason)
end)

RegisterNetEvent('amb_server:payEMSInvoice', function(invoiceId)
    payInvoice(source, invoiceId)
end)

RegisterNetEvent('amb_server:declineEMSInvoice', function(invoiceId)
    declineInvoice(source, invoiceId)
end)

AddEventHandler('playerDropped', function()
    local src = source

    for invoiceId, invoice in pairs(emsInvoices) do
        if invoice.medicSrc == src or invoice.patientSrc == src then
            emsInvoices[invoiceId] = nil
        end
    end
end)

RegisterCommand(getInvoiceConfig().CommandName or 'emsinvoice', function(src, args)
    if src == 0 then
        return
    end

    local commandName = getInvoiceConfig().CommandName or 'emsinvoice'

    if #args < 3 then
        Framework.Notify(src, _L('ems_invoice_usage', { command = commandName }), 'error')
        return
    end

    local targetId = args[1]
    local amount = args[2]
    local reasonParts = {}

    for index = 3, #args do
        reasonParts[#reasonParts + 1] = args[index]
    end

    createInvoice(src, targetId, amount, table.concat(reasonParts, ' '))
end, false)

RegisterCommand(getInvoiceConfig().PayCommandName or 'payemsinvoice', function(src, args)
    if src == 0 then
        return
    end

    payInvoice(src, args[1])
end, false)

RegisterCommand(getInvoiceConfig().DeclineCommandName or 'declineemsinvoice', function(src, args)
    if src == 0 then
        return
    end

    declineInvoice(src, args[1])
end, false)

Framework.CreateCallback('amb_server:getBossMenuData', function(src, cb, requestedJob)
    local members = GetPlayersList()
    local player = Framework.GetPlayer(src)
    local departmentId = requestedJob or (player and player.job and player.job.name) or 'ambulance'

    balances[departmentId] = getDepartmentBalance(departmentId)
    finances[departmentId] = finances[departmentId] or {}

    local externalDepartments = {}

    if GetResourceState('plt_departments') == 'started' then
        externalDepartments = exports.plt_departments:GetDepartmentCatalog(2000) or {}
    end

    cb({
        data = DepartmentData,
        externalDepts = externalDepartments,
        members = members,
        news = newsList,
        pcrs = pcrList,
        dutyLogs = DeptDutyLogs or {},
        balances = balances,
        finances = finances,
        transactions = finances[departmentId]
    })
end)

RegisterNetEvent('amb_server:addPCR', function(data)
    local src = source

    if not exports.plt_ambulance_job:IsEMS(src) and not Framework.HasPermission(src, Config.Permission) then
        return
    end

    local player = Framework.GetPlayer(src)

    if not player then
        return
    end

    local pcr = {
        patient = data.patient,
        condition = data.condition,
        treatment = data.treatment,
        author = player.name,
        date = os.date('%B %d, %Y')
    }

    if pcrTableAvailable then
        MySQL.Async.insert(
            'INSERT INTO plt_ambulance_job_pcrs (patient, `condition`, treatment, author, date) VALUES (?, ?, ?, ?, ?)',
            { pcr.patient, pcr.condition, pcr.treatment, pcr.author, pcr.date },
            function(insertId)
                pcr.id = insertId

                table.insert(pcrList, pcr)

                if #pcrList > 50 then
                    table.remove(pcrList, 1)
                end

                TriggerClientEvent('amb_client:SyncData', -1, { pcrs = pcrList })
            end)

        return
    end

    pcr.id = #pcrList + 1

    table.insert(pcrList, 1, pcr)

    if #pcrList > 50 then
        table.remove(pcrList)
    end

    TriggerClientEvent('amb_client:SyncData', -1, { pcrs = pcrList })
end)

Framework.CreateCallback('amb_server:searchDMR', function(_, cb, data)
    local query = data.query

    if not query or #query < 2 then
        return cb({})
    end

    local results = {}
    local sql

    if Framework.Type == 'qb' then
        sql = 'SELECT citizenid as cid, charinfo FROM players WHERE LOWER(charinfo) LIKE ? OR LOWER(citizenid) LIKE ? LIMIT 10'
    else
        sql = "SELECT identifier as cid, firstname, lastname FROM users WHERE LOWER(CONCAT(firstname, ' ', lastname)) LIKE ? OR LOWER(identifier) LIKE ? LIMIT 10"
    end

    local rows = MySQL.Sync.fetchAll(sql, { '%' .. query .. '%', '%' .. query .. '%' })

    for _, row in ipairs(rows) do
        local name = 'Unknown'

        if Framework.Type == 'qb' then
            local charInfo = json.decode(row.charinfo)
            name = charInfo.firstname .. ' ' .. charInfo.lastname
        else
            name = row.firstname .. ' ' .. row.lastname
        end

        table.insert(results, {
            cid = row.cid,
            name = name
        })
    end

    cb(results)
end)

Framework.CreateCallback('amb_server:getDMRDetails', function(_, cb, data)
    local citizenId = data.cid

    if not citizenId then
        return cb({})
    end

    local name = 'Unknown'

    if Framework.Type == 'qb' then
        local rows = MySQL.Sync.fetchAll('SELECT charinfo FROM players WHERE citizenid = ?', { citizenId })

        if rows[1] then
            local charInfo = json.decode(rows[1].charinfo)
            name = charInfo.firstname .. ' ' .. charInfo.lastname
        end
    else
        local rows = MySQL.Sync.fetchAll('SELECT firstname, lastname FROM users WHERE identifier = ?', { citizenId })

        if rows[1] then
            name = rows[1].firstname .. ' ' .. rows[1].lastname
        end
    end

    local pcrs = {}

    if pcrTableAvailable then
        pcrs = MySQL.Sync.fetchAll('SELECT * FROM plt_ambulance_job_pcrs WHERE patient = ? ORDER BY id DESC', { name }) or {}
    else
        for _, pcr in ipairs(pcrList) do
            if pcr.patient == name then
                table.insert(pcrs, pcr)
            end
        end
    end

    local xrays = MySQL.Sync.fetchAll('SELECT * FROM plt_ambulance_job_xrays WHERE citizenid = ? ORDER BY id DESC', { citizenId })

    for _, xray in ipairs(xrays) do
        xray.injuries = json.decode(xray.injuries)
    end

    cb({
        name = name,
        pcrs = pcrs,
        xrays = xrays
    })
end)

RegisterNetEvent('amb_server:saveXRayResult', function(citizenId, injuries)
    MySQL.Async.execute('INSERT INTO plt_ambulance_job_xrays (citizenid, injuries, date) VALUES (?, ?, ?)', {
        citizenId,
        json.encode(injuries),
        os.date('%B %d, %Y')
    })
end)

Framework.CreateCallback('amb_server:searchPatients', function(_, cb, data)
    local query = data.query

    if not query or #query < 2 then
        return cb({})
    end

    local results = {}

    if Config.Debug then
        print('^2[plt_ambulance] Searching for Citizen:^7 ' .. tostring(query))
    end

    -- QBCore keeps characters in `players` (citizenid + charinfo JSON), ESX
    -- keeps them in `users` (identifier + firstname/lastname columns).
    local ok, rows

    if Framework.Type == 'qb' then
        ok, rows = pcall(function()
            return MySQL.Sync.fetchAll([[
                SELECT citizenid as cid, charinfo
                FROM players
                WHERE citizenid LIKE ?
                   OR charinfo LIKE ?
                LIMIT 20
            ]], { '%' .. query .. '%', '%' .. query .. '%' })
        end)
    else
        local like = '%' .. query .. '%'

        ok, rows = pcall(function()
            return MySQL.Sync.fetchAll([[
                SELECT identifier as cid, firstname, lastname, phone_number
                FROM users
                WHERE identifier LIKE ?
                   OR firstname LIKE ?
                   OR lastname LIKE ?
                LIMIT 20
            ]], { like, like, like })
        end)

        -- Older ESX schemas have no phone_number column.
        if not ok then
            ok, rows = pcall(function()
                return MySQL.Sync.fetchAll([[
                    SELECT identifier as cid, firstname, lastname
                    FROM users
                    WHERE identifier LIKE ?
                       OR firstname LIKE ?
                       OR lastname LIKE ?
                    LIMIT 20
                ]], { like, like, like })
            end)
        end
    end

    if ok and rows and #rows > 0 then
        for _, row in ipairs(rows) do
            local name = 'Unknown'
            local phone = 'N/A'

            if Framework.Type == 'qb' then
                local charInfo = row.charinfo

                if type(charInfo) == 'string' then
                    charInfo = json.decode(charInfo) or row.charinfo
                end

                if charInfo then
                    name = (charInfo.firstname or 'Unknown') .. ' ' .. (charInfo.lastname or 'Citizen')
                    phone = charInfo.phone or 'N/A'
                end
            else
                name = (row.firstname or 'Unknown') .. ' ' .. (row.lastname or 'Citizen')
                phone = row.phone_number or 'N/A'
            end

            table.insert(results, {
                cid = row.cid,
                name = name,
                phone = phone
            })
        end

        if Config.Debug then
            print('^2[plt_ambulance] Found ' .. #results .. ' citizens.^7')
        end
    else
        if not ok then
            print('^1[plt_ambulance] SQL ERROR:^7 ' .. tostring(rows))
        end

        if Config.Debug then
            print('^3[plt_ambulance] 0 results found.^7')
        end
    end

    cb(results)
end)

Framework.CreateCallback('amb_server:getPatientDetails', function(_, cb, data)
    local citizenId = data.cid

    if not citizenId then
        return cb({})
    end

    local details = {
        cid = citizenId,
        name = 'Unknown',
        pcrs = {},
        xrays = {},
        prescriptions = {},
        blood_type = 'Unknown',
        allergies = 'None',
        medical_notes = 'No notes recorded.',
        insurance = false
    }

    if Framework.Type == 'qb' then
        local rows = MySQL.Sync.fetchAll('SELECT charinfo, metadata FROM players WHERE citizenid = ?', { citizenId })

        if rows[1] then
            local charInfo = json.decode(rows[1].charinfo)
            local metadata = json.decode(rows[1].metadata)
            local profile = ensurePatientProfile(citizenId, metadata)

            details.name = charInfo.firstname .. ' ' .. charInfo.lastname
            details.phone = charInfo.phone
            details.dob = charInfo.birthdate
            details.gender = charInfo.gender == 0 and 'Male' or 'Female'
            details.blood_type = profile.blood_type
            details.allergies = profile.known_allergy
            details.medical_notes = metadata.medicalnotes or 'No notes recorded.'
            details.insurance = metadata.medical_insurance and true or false
            details.hunger = math.floor(metadata.hunger or 100)
            details.thirst = math.floor(metadata.thirst or 100)
            details.stress = math.floor(metadata.stress or 0)
            details.is_dead = metadata.isdead or false
            details.health = metadata.health or 100

            savePatientProfiles()
        end
    else
        local rows = MySQL.Sync.fetchAll(
            'SELECT firstname, lastname, dateofbirth, sex, phone_number, medical_insurance FROM users WHERE identifier = ?',
            { citizenId })

        if rows[1] then
            local profile = ensurePatientProfile(citizenId)

            details.name = rows[1].firstname .. ' ' .. rows[1].lastname
            details.dob = rows[1].dateofbirth
            details.gender = rows[1].sex == 'm' and 'Male' or 'Female'
            details.phone = rows[1].phone_number
            details.insurance = rows[1].medical_insurance == 1
            details.blood_type = profile.blood_type
            details.allergies = profile.known_allergy

            savePatientProfiles()
        end
    end

    if pcrTableAvailable then
        details.pcrs = MySQL.Sync.fetchAll(
            'SELECT * FROM plt_ambulance_job_pcrs WHERE patient = ? OR author = ? ORDER BY id DESC',
            { details.name, details.name }) or {}
    end

    details.xrays = MySQL.Sync.fetchAll(
        'SELECT * FROM plt_ambulance_job_xrays WHERE citizenid = ? ORDER BY id DESC', { citizenId })

    for _, xray in ipairs(details.xrays) do
        xray.injuries = json.decode(xray.injuries)
    end

    pcall(function()
        details.prescriptions = MySQL.Sync.fetchAll(
            'SELECT * FROM plt_ambulance_job_prescriptions WHERE citizenid = ? ORDER BY id DESC', { citizenId })
    end)

    cb(details)
end)

Framework.CreateCallback('amb_server:updatePatientAllergy', function(src, cb, data)
    if not exports.plt_ambulance_job:IsEMS(src) and not Framework.HasPermission(src, Config.Permission) then
        cb({ success = false, message = _L('not_authorized') })
        return
    end

    local citizenId = data and data.cid and tostring(data.cid) or nil

    if not citizenId or citizenId == '' then
        cb({ success = false, message = 'Missing patient ID.' })
        return
    end

    local allergy = data and data.known_allergy

    if type(allergy) ~= 'string' then
        allergy = ''
    end

    allergy = allergy:gsub('^%s+', ''):gsub('%s+$', '')

    if allergy == '' then
        allergy = 'None'
    end

    if #allergy > 120 then
        allergy = allergy:sub(1, 120)
    end

    local profile = ensurePatientProfile(citizenId)

    profile.known_allergy = allergy
    patientProfiles[citizenId] = profile

    savePatientProfiles()

    cb({ success = true, known_allergy = allergy })
end)

RegisterNetEvent('amb_server:financeAction', function(data)
    local src = source
    local player = Framework.GetPlayer(src)

    if not player then
        return
    end

    if not exports.plt_ambulance_job:IsEMS(src) and not Framework.HasPermission(src, Config.Permission) then
        Framework.Notify(src, _L('not_authorized_funds'), 'error')
        return
    end

    local departmentId = data.dept or player.job.name
    local action = data.action
    local amount = tonumber(data.amount)

    if not amount or amount <= 0 then
        return
    end

    balances[departmentId] = getDepartmentBalance(departmentId)
    finances[departmentId] = finances[departmentId] or {}

    if action == 'deposit' then
        if not player.functions.RemoveMoney('cash', amount, 'dept-deposit') then
            Framework.Notify(src, _L('not_enough_cash_short'), 'error')
            return
        end

        if AddFinanceEntry(departmentId, 'deposit', amount, 'Manual Deposit', player.name) then
            Framework.Notify(src, _L('deposited_funds', { amount = amount }), 'success')
        else
            player.functions.AddMoney('cash', amount, 'dept-deposit-refund')
            Framework.Notify(src, 'Department finance backend error.', 'error')
        end
    elseif action == 'withdraw' then
        local balance = getDepartmentBalance(departmentId)

        if not balance or amount > balance then
            Framework.Notify(src, _L('not_enough_department_funds'), 'error')
            return
        end

        if not AddFinanceEntry(departmentId, 'withdraw', amount, 'Manual Withdrawal', player.name) then
            Framework.Notify(src, _L('not_enough_department_funds'), 'error')
            return
        end

        if player.functions.AddMoney('cash', amount, 'dept-withdrawal') then
            Framework.Notify(src, _L('withdrew_funds', { amount = amount }), 'success')
        else
            AddFinanceEntry(departmentId, 'deposit', amount, 'Withdrawal Rollback', 'SYSTEM')
            Framework.Notify(src, 'Department finance backend error.', 'error')
        end
    end
end)

RegisterNetEvent('amb_server:distributeSalaries', function(data)
    local src = source
    local player = Framework.GetPlayer(src)

    if not player then
        return
    end

    if not exports.plt_ambulance_job:IsEMS(src) and not Framework.HasPermission(src, Config.Permission) then
        Framework.Notify(src, _L('not_authorized_funds'), 'error')
        return
    end

    local departmentId = (data and data.dept) or player.job.name

    if not departmentId or tostring(departmentId) == '' then
        Framework.Notify(src, 'Missing department for payout.', 'error')
        return
    end

    local recipients, total = collectSalaryRecipients(departmentId)

    if #recipients == 0 or total <= 0 then
        Framework.Notify(src, 'No eligible online members with configured salaries.', 'error')
        return
    end

    local balance = getDepartmentBalance(departmentId)

    if not balance or total > balance then
        Framework.Notify(src, _L('not_enough_department_funds'), 'error')
        return
    end

    local label = ('Salary payout (%d members)'):format(#recipients)

    if not AddFinanceEntry(departmentId, 'withdraw', total, label, player.name or 'SYSTEM') then
        Framework.Notify(src, _L('not_enough_department_funds'), 'error')
        return
    end

    local paidCount = 0
    local paidAmount = 0

    for _, recipient in ipairs(recipients) do
        if paySalary(recipient) then
            paidCount = paidCount + 1
            paidAmount = paidAmount + recipient.amount

            Framework.Notify(recipient.source, ('Salary received: $%d'):format(recipient.amount), 'success')
        end
    end

    local refund = total - paidAmount

    if refund > 0 then
        AddFinanceEntry(departmentId, 'deposit', refund, 'Salary payout refund', 'SYSTEM')
    end

    Framework.Notify(src, ('Salary payout complete: %d members paid ($%d).'):format(paidCount, paidAmount), 'success')
end)

RegisterNetEvent('amb_server:addNews', function(data)
    local src = source

    if not Framework.HasPermission(src, Config.Permission) then
        return
    end

    local player = Framework.GetPlayer(src)

    if not player then
        return
    end

    table.insert(newsList, {
        id = #newsList + 1,
        title = data.title,
        content = data.content,
        author = player.name,
        date = os.date('%B %d, %Y')
    })

    SaveNews()
end)

RegisterNetEvent('amb_server:deleteNews', function(newsId)
    local src = source

    if not Framework.HasPermission(src, Config.Permission) then
        return
    end

    local id = tonumber(newsId)

    if not id then
        return
    end

    for index, entry in ipairs(newsList) do
        if tonumber(entry.id) == id then
            table.remove(newsList, index)
            break
        end
    end

    SaveNews()
end)

Framework.CreateCallback('amb_server:getInsuredPlayers', function(src, cb, requestedJob)
    local player = Framework.GetPlayer(src)
    local departmentId = requestedJob or (player and player.job.name) or 'ambulance'

    if not exports.plt_ambulance_job:IsEMS(src) and not Framework.HasPermission(src, Config.Permission) then
        return cb({})
    end

    local insured = {}
    local seenIdentifiers = {}

    for _, playerId in ipairs(GetPlayers()) do
        local target = Framework.GetPlayer(tonumber(playerId))

        if target then
            local insurance = Framework.GetMetaData(tonumber(playerId), 'medical_insurance')

            if insurance then
                local allowed = insurance == departmentId
                    or insurance == true
                    or Framework.HasPermission(src, Config.Permission)

                if allowed then
                    local identifier = target.citizenid or target.identifier
                    local name = target.name

                    if not name and target.charinfo then
                        name = target.charinfo.firstname .. ' ' .. target.charinfo.lastname
                    end

                    seenIdentifiers[identifier] = true

                    table.insert(insured, {
                        cid = identifier,
                        name = name or 'Unknown',
                        isOnline = true,
                        serverId = tonumber(playerId)
                    })
                end
            end
        end
    end

    if Framework.Type == 'qb' then
        local rows = MySQL.Sync.fetchAll('SELECT citizenid, charinfo, metadata FROM players', {})

        for _, row in ipairs(rows) do
            if not seenIdentifiers[row.citizenid] then
                local metadata = row.metadata

                if type(metadata) == 'string' then
                    metadata = json.decode(metadata) or row.metadata
                end

                if metadata and metadata.medical_insurance then
                    local allowed = metadata.medical_insurance == departmentId
                        or metadata.medical_insurance == true
                        or Framework.HasPermission(src, Config.Permission)

                    if allowed then
                        local charInfo = row.charinfo

                        if type(charInfo) == 'string' then
                            charInfo = json.decode(charInfo) or row.charinfo
                        end

                        local name = charInfo and (charInfo.firstname .. ' ' .. charInfo.lastname) or row.citizenid

                        table.insert(insured, {
                            cid = row.citizenid,
                            name = (name ~= ' ' and name) or row.citizenid,
                            isOnline = false
                        })
                    end
                end
            end
        end
    elseif Framework.Type == 'esx' then
        local rows = safeQuery(
            'SELECT identifier, firstname, lastname, medical_insurance FROM users WHERE medical_insurance IS NOT NULL AND medical_insurance != 0',
            {}, 'insured_players_full')

        if not rows then
            rows = safeQuery(
                'SELECT identifier, medical_insurance FROM users WHERE medical_insurance IS NOT NULL AND medical_insurance != 0',
                {}, 'insured_players_minimal')
        end

        if rows then
            for _, row in ipairs(rows) do
                if not seenIdentifiers[row.identifier] then
                    local allowed = row.medical_insurance == departmentId
                        or row.medical_insurance == '1'
                        or row.medical_insurance == 1
                        or Framework.HasPermission(src, Config.Permission)

                    if allowed then
                        local name = ((row.firstname or '') .. ' ' .. (row.lastname or ''))
                            :gsub('^%s+', ''):gsub('%s+$', '')

                        if name == '' then
                            name = row.identifier or 'Unknown'
                        end

                        table.insert(insured, {
                            cid = row.identifier,
                            name = name,
                            isOnline = false
                        })
                    end
                end
            end
        else
            print('^3[plt_ambulance][ESX] users.medical_insurance column is missing or incompatible; offline insured list disabled.^7')
        end
    end

    cb(insured)
end)

RegisterNetEvent('amb_server:cancelInsurance', function(data)
    local src = source

    if not exports.plt_ambulance_job:IsEMS(src) and not Framework.HasPermission(src, Config.Permission) then
        Framework.Notify(src, _L('not_authorized'), 'error')
        return
    end

    local citizenId = data.cid
    local targetSrc = data.serverId

    if targetSrc and Framework.GetPlayer(targetSrc) then
        Framework.SetMetaData(targetSrc, 'medical_insurance', false)
        TriggerClientEvent('amb_client:updateInsuranceStatus', targetSrc, false)
        Framework.Notify(targetSrc, _L('insurance_cancelled_by_department'), 'error')
    end

    if Framework.Type == 'qb' then
        local rows = MySQL.Sync.fetchAll('SELECT metadata FROM players WHERE citizenid = ?', { citizenId })

        if rows[1] then
            local metadata = rows[1].metadata

            if type(metadata) == 'string' then
                metadata = json.decode(metadata) or rows[1].metadata
            end

            if metadata then
                metadata.medical_insurance = false

                MySQL.Async.execute('UPDATE players SET metadata = ? WHERE citizenid = ?', {
                    json.encode(metadata),
                    citizenId
                })
            end
        end
    elseif Framework.Type == 'esx' then
        local ok, err = pcall(function()
            MySQL.Sync.execute('UPDATE users SET medical_insurance = 0 WHERE identifier = ?', { citizenId })
        end)

        if not ok then
            print(('[plt_ambulance][ESX][cancel_insurance] Failed to update users.medical_insurance for %s: %s'):format(
                tostring(citizenId), tostring(err)))
        end
    end

    Framework.Notify(src, _L('insurance_subscription_cancelled'), 'success')
end)

local function canManageMembers(src)
    if Framework.HasPermission(src, Config.Permission) then
        return true
    end

    if Framework.Type == 'qb' and exports.plt_ambulance_job:IsEMS(src) then
        return true
    end

    return false
end

local function findRankLabel(departmentId, grade)
    local label = 'Rank ' .. grade

    for _, link in ipairs(DepartmentData.links or {}) do
        if link.from == departmentId then
            for _, node in ipairs(DepartmentData.nodes) do
                if node.id == link.to and node.type == 'rank' and node.ranks then
                    for _, rank in ipairs(node.ranks) do
                        if tonumber(rank.level) == grade then
                            label = rank.name or label
                            break
                        end
                    end
                end
            end
        end
    end

    return label
end

local function findDepartmentLabel(departmentId)
    for _, node in ipairs(DepartmentData.nodes) do
        if node.id == departmentId then
            return node.label
        end
    end

    return 'Unknown'
end

RegisterNetEvent('amb_server:hirePlayer', function(data)
    local src = source

    if not canManageMembers(src) then
        Framework.Notify(src, _L('not_authorized'), 'error')
        return
    end

    local targetId = tonumber(data.playerId)
    local target = Framework.GetPlayer(targetId)

    if not target then
        return
    end

    local departmentId = data.job
    local grade = tonumber(data.grade)
    local departmentLabel = findDepartmentLabel(departmentId)
    local gradeLabel = 'Rank ' .. grade

    Framework.SetJob(targetId, GetFrameworkJobForDepartment(departmentId), grade)

    Wait(300)

    local updated = Framework.GetPlayer(targetId)

    if updated then
        MemberData[updated.citizenid] = {
            name = updated.name,
            job = departmentId,
            grade = grade,
            jobLabel = departmentLabel,
            gradeLabel = gradeLabel,
            ratings = {}
        }

        SaveMemberToDB(updated.citizenid)
    end
end)

Framework.CreateCallback('amb_server:hireById', function(src, cb, data)
    if not canManageMembers(src) then
        return cb({ success = false, message = 'Not authorized' })
    end

    local rawId = data.id and tostring(data.id) or ''
    local identifier = rawId:match('^%s*(.-)%s*$') or rawId
    local departmentId = data.job
    local grade = tonumber(data.grade) or 0

    if not departmentId or departmentId == '' then
        return cb({ success = false, message = 'No department selected' })
    end

    if not identifier or identifier == '' then
        return cb({ success = false, message = 'Please enter a Citizen ID or Server ID' })
    end

    local targetSrc = nil
    local target = nil
    local citizenId = nil
    local playerName = 'Unknown'

    local numericId = tonumber(identifier)

    if numericId and numericId >= 1 and numericId <= 9999 then
        target = Framework.GetPlayer(numericId)

        if target then
            targetSrc = numericId
            citizenId = target.citizenid
            playerName = target.name
        end
    end

    if not target and Framework.GetPlayerByCitizenId then
        target = Framework.GetPlayerByCitizenId(identifier)

        if target then
            targetSrc = target.source
            citizenId = target.citizenid or identifier
            playerName = target.name
        end
    end

    if not target then
        for _, playerId in ipairs(GetPlayers()) do
            local candidate = Framework.GetPlayer(tonumber(playerId))

            if candidate and (candidate.citizenid == identifier or tostring(candidate.citizenid) == identifier) then
                target = candidate
                targetSrc = tonumber(playerId)
                citizenId = candidate.citizenid
                playerName = candidate.name
                break
            end
        end
    end

    local departmentLabel = findDepartmentLabel(departmentId)
    local gradeLabel = findRankLabel(departmentId, grade)

    if target and targetSrc then
        Framework.SetJob(targetSrc, GetFrameworkJobForDepartment(departmentId), grade)

        Wait(200)

        local updated = Framework.GetPlayer(targetSrc)

        if updated then
            MemberData[updated.citizenid] = {
                name = updated.name,
                job = departmentId,
                grade = grade,
                jobLabel = departmentLabel,
                gradeLabel = gradeLabel,
                ratings = {}
            }

            SaveMemberToDB(updated.citizenid)
            TriggerClientEvent('amb_client:SyncMembers', -1, MemberData)

            return cb({ success = true })
        end
    end

    if Framework.Type == 'qb' then
        local rows = MySQL.Sync.fetchAll('SELECT citizenid, charinfo FROM players WHERE citizenid = ?', { identifier })

        if not rows or not rows[1] then
            rows = MySQL.Sync.fetchAll('SELECT citizenid, charinfo FROM players WHERE LOWER(citizenid) = ?',
                { identifier:lower() })
        end

        if rows and rows[1] then
            citizenId = rows[1].citizenid

            local charInfo = rows[1].charinfo

            if type(charInfo) == 'string' then
                charInfo = json.decode(charInfo) or rows[1].charinfo
            end

            if charInfo then
                playerName = ((charInfo.firstname or '') .. ' ' .. (charInfo.lastname or '')) or citizenId
            else
                playerName = citizenId
            end

            local jobData = {
                name = GetFrameworkJobForDepartment(departmentId),
                label = departmentLabel,
                grade = {
                    level = grade,
                    name = gradeLabel
                },
                payment = 0,
                onduty = false,
                isboss = false
            }

            MySQL.Async.execute('UPDATE players SET job = ? WHERE citizenid = ?', {
                json.encode(jobData),
                citizenId
            }, function()
                MemberData[citizenId] = {
                    name = playerName,
                    job = departmentId,
                    grade = grade,
                    jobLabel = departmentLabel,
                    gradeLabel = gradeLabel,
                    ratings = {}
                }

                SaveMemberToDB(citizenId)
                TriggerClientEvent('amb_client:SyncMembers', -1, MemberData)

                cb({ success = true })
            end)

            return
        end
    end

    cb({
        success = false,
        message = 'Player not found. Use Citizen ID (e.g. ABC12345) or Server ID (#) if online.'
    })
end)

RegisterNetEvent('amb_server:manageMember', function(data)
    local src = source

    if not canManageMembers(src) then
        Framework.Notify(src, _L('not_authorized'), 'error')
        return
    end

    local citizenId = data.cid
    local action = data.action
    local member = MemberData[citizenId]

    if not member then
        return
    end

    if action == 'fire' then
        MemberData[citizenId] = nil

        MySQL.Sync.execute('DELETE FROM plt_ambulance_job_members WHERE citizenid = ?', { citizenId })

        for _, playerId in ipairs(GetPlayers()) do
            local player = Framework.GetPlayer(tonumber(playerId))

            if player and player.citizenid == citizenId then
                Framework.SetJob(tonumber(playerId), 'unemployed', 0)
                break
            end
        end
    elseif action == 'promote' or action == 'demote' then
        local grade = member.grade + (action == 'promote' and 1 or -1)

        if grade < 0 then
            grade = 0
        end

        member.grade = grade
        member.gradeLabel = findRankLabel(member.job, grade)

        SaveMemberToDB(citizenId)

        for _, playerId in ipairs(GetPlayers()) do
            local player = Framework.GetPlayer(tonumber(playerId))

            if player and player.citizenid == citizenId then
                Framework.SetJob(tonumber(playerId), GetFrameworkJobForDepartment(member.job), grade)
                break
            end
        end
    end
end)

function SendDepartmentMail(senderDept, receiverDept, senderName, subject, message, imageUrl)
    local date = os.date('%B %d, %Y')
    local time = os.date('%H:%M')
    local isLocalDepartment = false
    local resolvedReceiver = receiverDept

    for _, node in ipairs(DepartmentData.nodes) do
        if node.type == 'department' and (node.id == receiverDept or node.frameworkJob == receiverDept) then
            isLocalDepartment = true
            resolvedReceiver = node.id
            break
        end
    end

    if isLocalDepartment then
        MySQL.Async.insert(
            'INSERT INTO plt_ambulance_job_mails (sender_dept, receiver_dept, sender_name, subject, message, image_url, `date`, `time`) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            { senderDept, resolvedReceiver, senderName, subject, message, imageUrl or '', date, time },
            function(insertId)
                if not insertId then
                    return
                end

                for _, playerId in ipairs(GetPlayers()) do
                    local player = Framework.GetPlayer(tonumber(playerId))

                    if player then
                        local matches = player.job.name == resolvedReceiver
                            or player.job.name == GetFrameworkJobForDepartment(resolvedReceiver)

                        if matches then
                            Framework.Notify(tonumber(playerId),
                                'New department mail received from ' .. senderDept:upper(), 'info')

                            TriggerClientEvent('amb_client:SyncMail', tonumber(playerId))
                        end
                    end
                end
            end)

        return
    end

    if GetResourceState('plt_departments') == 'started' then
        exports.plt_departments:SendDepartmentMail(senderDept, receiverDept, senderName, subject, message, imageUrl)
    end

    MySQL.Async.insert(
        'INSERT INTO plt_ambulance_job_mails (sender_dept, receiver_dept, sender_name, subject, message, image_url, `date`, `time`, is_read) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)',
        { senderDept, receiverDept, senderName, subject, message, imageUrl or '', date, time })
end

exports('SendDepartmentMail', SendDepartmentMail)

Framework.CreateCallback('amb_server:getMails', function(_, cb, departmentId)
    local mails = MySQL.Sync.fetchAll(
        'SELECT * FROM plt_ambulance_job_mails WHERE receiver_dept = ? OR sender_dept = ? ORDER BY id DESC LIMIT 50',
        { departmentId, departmentId })

    cb(mails or {})
end)

RegisterNetEvent('amb_server:sendMail', function(data)
    local src = source
    local player = Framework.GetPlayer(src)

    if not player then
        return
    end

    SendDepartmentMail(data.senderDept, data.receiverDept, player.name, data.subject, data.message, data.imageUrl)
end)

RegisterNetEvent('amb_server:markMailRead', function(mailId)
    MySQL.Async.execute('UPDATE plt_ambulance_job_mails SET is_read = 1 WHERE id = ?', { mailId })
end)

RegisterNetEvent('amb_server:deleteMail', function(mailId)
    MySQL.Async.execute('DELETE FROM plt_ambulance_job_mails WHERE id = ?', { mailId })
end)

exports('GetDepartmentCatalog', function()
    local catalog = {}

    if not (DepartmentData and DepartmentData.nodes) then
        return catalog
    end

    for _, node in ipairs(DepartmentData.nodes) do
        if node.type == 'department' then
            table.insert(catalog, {
                id = node.id,
                label = node.label,
                frameworkJob = node.frameworkJob or node.id
            })
        end
    end

    return catalog
end)

exports('GetDepartmentsData', function()
    return DepartmentData
end)

