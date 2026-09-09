Framework = Framework or {}
Bridge = Bridge or {}
Utils = Utils or {}

Utils.rawPrint = Utils.rawPrint or print

local function findStartedResource(resources)
    for _, resourceName in ipairs(resources) do
        if GetResourceState(resourceName) == 'started' then
            return resourceName
        end
    end
end

local FRAMEWORK_CANDIDATES = {
    'es_extended',
    'qbx_core',
    'qbx-core',
    'qb-core',
    'qb_core'
}

local function findFramework()
    local preferred = Config and Config.PreferredFramework

    if type(preferred) == 'string' and preferred ~= '' and GetResourceState(preferred) == 'started' then
        return preferred
    end

    return findStartedResource(FRAMEWORK_CANDIDATES)
end

Bridge.Framework = findFramework()

Bridge.Target = findStartedResource({
    'ox_target',
    'qb-target'
})

Bridge.ProgressBar = findStartedResource({
    'ox_lib',
    'progressbar'
})

Bridge.InventoryResource = findStartedResource({
    'origen_inventory',
    'ox_inventory',
    'qb-inventory',
    'ps-inventory',
    -- ESX's built-in inventory (es_extended) is only picked up as a fallback
    -- when no dedicated inventory resource is running, so ox_inventory & co.
    -- always win on an ESX server that has one installed.
    'es_extended'
})

Bridge.KeysResource = findStartedResource({
    'mm_carkeys',
    'qbx_vehiclekeys',
    'qb-vehiclekeys',
    'wasabi_carkeys',
    'cd_garage',
    'okokGarage'
})

local INVENTORY_ALIASES = {
    origen_inventory = 'origen',
    ox_inventory = 'ox',
    ['ps-inventory'] = 'ps',
    ['qb-inventory'] = 'qb',
    es_extended = 'esx'
}

local KEYS_ALIASES = {
    mm_carkeys = 'mm',
    qbx_vehiclekeys = 'qbx',
    ['qb-vehiclekeys'] = 'qb',
    wasabi_carkeys = 'wasabi',
    cd_garage = 'cd',
    okokGarage = 'okok'
}

local INVENTORY_IMAGE_PATHS = {
    origen = 'nui://origen_inventory/ui/images/',
    ox = 'nui://ox_inventory/web/images/',
    ps = 'nui://ps-inventory/html/images/',
    qb = 'nui://qb-inventory/html/images/',
    esx = 'img/'
}

Bridge.Inventory = INVENTORY_ALIASES[Bridge.InventoryResource]
Bridge.Keys = KEYS_ALIASES[Bridge.KeysResource]
Bridge.InventoryImages = INVENTORY_IMAGE_PATHS[Bridge.Inventory] or 'img/'

local language = tostring(Config.Language or 'en'):lower()
local localeFile = LoadResourceFile(GetCurrentResourceName(), ('locales/%s.json'):format(language))

if localeFile then
    local ok, decoded = pcall(json.decode, localeFile)

    if ok then
        if type(decoded) == 'table' then
            Config.Locale = decoded
        end
    else
        print(('^1[plt_ambulance] Invalid locale file: locales/%s.json^7'):format(language))
    end
else
    print(('^1[plt_ambulance] Missing locale file: locales/%s.json^7'):format(language))
end

Config.Locale = Config.Locale or {}

function _L(key, params)
    local text = Config.Locale[key] or key

    if not params then
        return text
    end

    for placeholder, value in pairs(params) do
        text = text:gsub('{' .. tostring(placeholder) .. '}', tostring(value))
    end

    return text
end

Framework.MedicalState = {
    ALIVE = 'alive',
    LASTSTAND = 'laststand',
    DEAD = 'dead'
}

function Framework.NormalizeMedicalState(state)
    if state == Framework.MedicalState.LASTSTAND then
        return Framework.MedicalState.LASTSTAND
    end

    if state == Framework.MedicalState.DEAD then
        return Framework.MedicalState.DEAD
    end

    return Framework.MedicalState.ALIVE
end

function Framework.NormalizeEsxDutyJob(jobName)
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

Framework.Type = (Bridge.Framework == 'es_extended' and 'esx')
    or (Bridge.Framework and 'qb')
    or nil

function Framework.HasAuthoritativeMedicalState()
    return Framework.Type == 'qb'
end

if IsDuplicityVersion() then
    
    function Framework.Notify(source, message, notifyType)
        TriggerClientEvent('amb_client:Notify', source, message, notifyType)
    end

    function Framework.HasJob(source, jobs)
        local player = Framework.GetPlayer(source)

        if not player or not player.job then
            return false
        end

        if type(jobs) == 'table' then
            for _, jobName in ipairs(jobs) do
                if player.job.name == jobName then
                    return true
                end
            end

            return false
        end

        return player.job.name == jobs
    end
else
    
    Keys = Keys or { System = 'none' }

    function Keys.SetProvider(system, giveKeys)
        Keys.System = system

        function Keys.Give(vehicle)
            if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
                return false
            end

            local plate = tostring(Framework.GetPlate(vehicle) or '')
                :gsub('^%s+', '')
                :gsub('%s+$', '')

            if plate == '' then
                return false
            end

            giveKeys(plate, vehicle)

            return true
        end
    end

    function Keys.Give()
        return false
    end

    function Keys.GetSystem()
        return Keys.System
    end

    function Framework.Notify(message, notifyType)
        TriggerEvent('amb_client:Notify', message, notifyType)
    end

    function Framework.DeleteVehicle(vehicle)
        SetEntityAsMissionEntity(vehicle, true, true)
        DeleteVehicle(vehicle)
    end

    function Framework.RequestAnimDict(dict)
        RequestAnimDict(dict)

        local attempts = 0

        while not HasAnimDictLoaded(dict) and attempts < 100 do
            Wait(10)
            attempts = attempts + 1
        end
    end

    function Framework.RequestAnimSet(animSet)
        RequestAnimSet(animSet)

        local attempts = 0

        while not HasAnimSetLoaded(animSet) and attempts < 100 do
            Wait(10)
            attempts = attempts + 1
        end
    end

    function Framework.RequestModel(model)
        RequestModel(model)

        local attempts = 0

        while not HasModelLoaded(model) and attempts < 100 do
            Wait(10)
            attempts = attempts + 1
        end
    end

    function Framework.ProgressBar(label, duration, options)
        if type(options) ~= 'table' then
            options = {}
        end

        duration = tonumber(duration) or 3000

        if ProgressBar and ProgressBar.showProgress then
            local finished = false
            local success = false

            ProgressBar.showProgress({
                title = label,
                duration = duration,
                useWhileDead = options.useWhileDead == true,
                canCancel = options.canCancel ~= false,
                animation = (options.dict and options.anim) and {
                    dict = options.dict,
                    anim = options.anim,
                    flag = options.flag or 49
                } or nil,
                disable = {
                    move = true,
                    car = true,
                    combat = true,
                    mouse = false
                },
                prop = options.prop,
                propTwo = options.propTwo
            }, function()
                success = true
                finished = true
            end, function()
                finished = true
            end)

            while not finished do
                Wait(10)
            end

            return success
        end

        local ped = PlayerPedId()

        if options.dict and options.anim and DoesEntityExist(ped) then
            Framework.RequestAnimDict(options.dict)
            TaskPlayAnim(ped, options.dict, options.anim, 8.0, -8.0, -1, options.flag or 49, 0.0, false, false, false)
        end

        local startTime = GetGameTimer()
        local completed = true

        while duration > GetGameTimer() - startTime do
            Wait(0)

            local progress = (GetGameTimer() - startTime) / duration

            DrawRect(0.5, 0.9, 0.2, 0.03, 0, 0, 0, 150)
            DrawRect(0.4 + (0.1 * progress), 0.9, 0.2 * progress, 0.03, 0, 255, 204, 200)

            if options.canCancel ~= false and IsControlJustPressed(0, 177) then
                completed = false
                break
            end
        end

        if DoesEntityExist(ped) then
            ClearPedTasks(ped)
        end

        return completed
    end

    function Framework.HasJob(jobs)
        local playerData = Framework.GetPlayerData()

        if not playerData or not playerData.job then
            return false
        end

        if type(jobs) == 'table' then
            for _, jobName in ipairs(jobs) do
                if playerData.job.name == jobName then
                    return true
                end
            end

            return false
        end

        return playerData.job.name == jobs
    end
end

