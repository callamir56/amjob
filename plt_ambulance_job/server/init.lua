local BANNER = {
    '^2 ____  _   _   _ _____ ___    ____  _______     __^7',
    '^2|  _ \\| | | | | |_   _/ _ \\  |  _ \\| ____\\ \\   / /^7',
    '^2| |_) | | | | | | | || | | | | | | |  _|  \\ \\ / / ^7',
    '^2|  __/| |__| |_| | | || |_| | | |_| | |___  \\ V /  ^7',
    '^2|_|   |_____\\___/  |_| \\___/  |____/|_____|  \\_/   ^7',
    '',
    '^2Thank you for being a customer. If you encounter any issues, please open a ticket on the support Discord server.^7'
}

local CHANGELOG = {
    '^2[plt_ambulance_job] Changelog 2.0.9:^7',
    '^2[plt_ambulance_job]    - Fixed the corrupted death states for QBCore and ESX^7',
    '^2[plt_ambulance_job]    - Created !important folder and moved the MD files into it^7',
    '^2[plt_ambulance_job]    - Moved hardcoded language from config.lua into locales folder^7',
    '^2[plt_ambulance_job]    - Removed hardcoded debug prints and gated them via Config.Debug^7',
    '^2[plt_ambulance_job]    - Fixed the medical-state runtime event error^7',
    '^2[plt_ambulance_job]    - Removed hardcoded clothing components and added to the config^7',
    '^2[plt_ambulance_job]    - Removed duplicate /setjob and /reviveplayer commands^7',
    '^2[plt_ambulance_job]    - Completely overhauled the bridge system, separating the logic into applicable folders^7',
    '^2[plt_ambulance_job]    - Added es.json locale^7',
    '^2[plt_ambulance_job]    - Added a new inventory bridge for ps-inventory^7',
    '^2[plt_ambulance_job]    - Moved an exposed function out of the config.lua^7'
}

for _, line in ipairs(BANNER) do
    Utils.rawPrint(line)
end

for _, line in ipairs(CHANGELOG) do
    Utils.rawPrint(line)
end

local function reportResource(label, candidates, missingMessage)
    for _, resourceName in ipairs(candidates) do
        if GetResourceState(resourceName) == 'started' then
            Utils.rawPrint(('^2[plt_ambulance_job] %s: %s^7'):format(label, resourceName))
            return
        end
    end

    Utils.rawPrint(missingMessage)
end

if GetResourceState('oxmysql') ~= 'started' then
    Utils.rawPrint('^1[plt_ambulance_job] Database: oxmysql not found - script will not function^7')
end

reportResource('Framework', { 'qbx_core', 'qbx-core', 'qb-core', 'es_extended' },
    '^1[plt_ambulance_job] Framework: not found - ensure your framework starts before this script^7')

reportResource('Target', { 'ox_target', 'qb-target' },
    '^1[plt_ambulance_job] Target: not found - check the bridge folder for a compatible target resource^7')

reportResource('Progress', { 'ox_lib', 'progressbar' },
    '^1[plt_ambulance_job] Progress: not found - check the bridge folder for a compatible progress bar resource^7')

reportResource('Inventory', { 'ox_inventory', 'qb-inventory', 'ps-inventory' },
    '^1[plt_ambulance_job] Inventory: not found - check the bridge folder for a compatible inventory resource^7')

reportResource('Keys', { 'mm_carkeys', 'qbx_vehiclekeys', 'qb-vehiclekeys', 'wasabi_carkeys', 'cd_garage', 'okokGarage' },
    '^1[plt_ambulance_job] Keys: not found - check the bridge folder for a compatible key resource^7')

