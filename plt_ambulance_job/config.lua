Config = {}

-- Full console logging for the mercy/finish and health systems. Keep it true
-- while testing; set to false in production.
Config.Debug = true

-- Which framework this build targets. Set to the resource name that is started
-- on your server. On an ESX server this must be "es_extended".
Config.PreferredFramework = "es_extended"

-- Language for locales/<name>.json. Available: "en".
Config.Language = "en"
Config.UseLicenseWhitelist = false 
Config.LicenseWhitelist = {
    "license:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
}

Config.CommandName = "manageems"
Config.Permission = "admin" 
Config.AdminBypass = false 
Config.ShowNotifications = true 
Config.EnableBlurEffect = true 
    
Config.MDT = {
    enabled = false, 
    type = 'export', 
}

Config.DefaultNodes = {
    departments = {
        { id = 'ambulance', label = 'Ambulance', type = 'department' },
        { id = 'fire', label = 'Fire Dept', type = 'department' },
    },
    permissions = {
        { id = 'garage', label = 'Access Garage', type = 'permission' },
        { id = 'vault', label = 'Open Safe', type = 'permission' },
    }
}

Config.EMSItems = {
    first_kit = {
        { name = "plt_medkit", label = "Medkit", icon = "plt_medkit.png", weight = 500 },
        { name = "plt_bandage", label = "Bandage", icon = "plt_bandage.png", weight = 100 },
        { name = "plt_painkillers", label = "Painkillers", icon = "plt_painkillers.png", weight = 50 },
    },
    operations = {
        { name = "plt_surgical_kit", label = "Surgical Kit", icon = "plt_surgical_kit.png", weight = 1000 },
        { name = "plt_surgical_scissors", label = "Surgical Scissors", icon = "plt_surgical_scissors.png", weight = 200 },
    },
    equipments = {
        { name = "plt_medical_bag", label = "Medical Bag", icon = "plt_medical_bag.png", weight = 2000 },
        { name = "plt_bp_monitor", label = "BP Monitor", icon = "plt_bp_monitor.png", weight = 500 },
    }
}

Config.Pharmacy = {
    Locations = {
        { coords = vector3(311.2, -594.3, 43.3), heading = 10.0, label = "Pillbox Medical Pharmacy" },
        { coords = vector3(1831.5, 3677.4, 34.3), heading = 210.0, label = "Sandy Shores Clinic" },
        { coords = vector3(-246.8, 6330.5, 32.4), heading = 315.0, label = "Paleto Bay Medical" }
    },
    Insurance = {
        Price = 5000, 
        Discount = 0.5, 
        Duration = 7, 
    },
    Items = {
        { name = "plt_bandage", label = "Elastic Bandage", price = 50, professionalOnly = false, prescriptionRequired = false, icon = "plt_bandage.png" },
        { name = "plt_painkillers", label = "Painkillers (OTC)", price = 150, professionalOnly = false, prescriptionRequired = false, icon = "plt_painkillers.png" },
        
        { name = "plt_antibiotics", label = "Antibiotics", price = 500, professionalOnly = false, prescriptionRequired = true, icon = "plt_antibiotics.png" },
        { name = "plt_medkit", label = "Advanced First Aid Kit", price = 1200, professionalOnly = false, prescriptionRequired = true, icon = "plt_medkit.png" },
        
        { name = "plt_surgical_scissors", label = "Surgical Scissors", price = 300, professionalOnly = true, prescriptionRequired = false, icon = "plt_surgical_scissors.png" },
        { name = "plt_bp_monitor", label = "Digital BP Monitor", price = 850, professionalOnly = true, prescriptionRequired = false, icon = "plt_bp_monitor.png" },
        { name = "plt_medical_bag", label = "EMS Field Bag", price = 1500, professionalOnly = true, prescriptionRequired = false, icon = "plt_medical_bag.png" },
        { name = "iak_wheelchair", label = "Wheelchair", price = 2500, professionalOnly = false, prescriptionRequired = true, icon = "wheelchair.png" },
        { name = "plt_walking_stick", label = "Walking Stick", price = 900, professionalOnly = false, prescriptionRequired = false, icon = "walking_stick.png" },
        { name = "plt_cane", label = "Cane", price = 900, professionalOnly = false, prescriptionRequired = false, icon = "cane.png" },
        { name = "plt_crutches", label = "Crutches", price = 1100, professionalOnly = false, prescriptionRequired = false, icon = "walking_stick.png" }
    }
}

Config.WheelchairItemName = "iak_wheelchair" 
Config.WheelchairDuration = 10 
Config.WalkingAidClipset = "move_m@limping@a" 
Config.CrutchesClipset = "move_lester_CaneUp" 
Config.CrutchesModel = "v_med_crutch01" 

Config.RadioCodes = {
    { label = "AVAIL", code = "10-8" },
    { label = "EN ROUTE", code = "10-97" },
    { label = "ON SCENE", code = "10-23" },
    { label = "BUSY", code = "10-6" },
    { label = "OFF DUTY", code = "10-7" },
    { label = "HOSPITAL", code = "10-15" },
    { label = "RTB", code = "10-19" },
}

-- Where your server keeps CASH. The pharmacy, the department deposit/withdrawal
-- and EMS invoices all go through this.
--
--   "auto"    - use the money item if the player is carrying any, otherwise fall
--               back to the ESX money account (xPlayer.getMoney)
--   "item"    - always the inventory item (ox_inventory / qb-style cash)
--   "account" - always the ESX money account
--
-- If the pharmacy says "not enough cash" while you can see money in your
-- inventory, ox_inventory is holding it as an item - "auto" or "item" fixes it.
Config.MoneySource = "auto"

-- Tried in order when looking for cash in the inventory.
Config.MoneyItems = { "money", "cash" }

-- Legacy aliases, kept so existing server.cfg edits do not break.
Config.MoneyAsItem = false
Config.MoneyItemName = "money"
Config.DefaultDeptBalance = 500000

Config.DepartmentFinance = "internal"

Config.EMSInvoice = {
    CommandName = "emsinvoice",
    PayCommandName = "payemsinvoice",
    DeclineCommandName = "declineemsinvoice",
    MaxDistance = 8.0,
    ExpireMinutes = 10,
    MaxAmount = 100000,
    PaymentAccounts = { "bank", "cash" }
}

Config.Health = {
    DownedThreshold = 125,
    -- Health a downed player is pinned at. MUST sit above GTA's player death
    -- threshold (100) and below DownedThreshold, otherwise the ped keeps
    -- dying/ragdolling and gets up and falls down again in a loop.
    DownedHealth = 110,
    -- How long (ms) a downed player can crawl before passing out, falling and
    -- automatically requesting a medic. 0 disables the crawl phase entirely.
    CrawlTime = 15000,
    MaxInjuryLevel = 5,       
    DeathTimer = 300,         
    UnconsciousTimer = 30,    
    CallEMSTimer = 0,        
    HospitalTransportDelay = 120, 
    ClearInventoryOnHospitalRespawn = false, 

    BleedChance = 0,         
    BleedInterval = 2000,     
    BleedRate = 1,            
    BulletBleedChance = 50,   
    BleedDecalMin = 2,        
    
    FractureChance = 60,      
    FractureTime = 600,      
    LimpAnimation = "move_m@limping@a", 
    BandageAsClothing = false, 

    DeadRestrictions = {
        DisableVoice = true,     
        DisableInventory = true  
    },

    Medication = {
        plt_bandage = { duration = 4000, dict = "missheistprowlprepb", anim = "low_reach_loop", label = "applying_bandage" },
        plt_painkillers = { duration = 3000, dict = "mp_suicide", anim = "pill", label = "taking_medication" },
        plt_painkillers_adv = { duration = 3500, dict = "mp_suicide", anim = "pill", label = "taking_medication" },
        plt_antibiotics = { duration = 3500, dict = "mp_suicide", anim = "pill", label = "taking_medication" },
        plt_medkit = { duration = 5000, dict = "missheistprowlprepb", anim = "low_reach_loop", label = "applying_first_aid" },
    },
}

Config.ClothingRemoval = {
    male = {
        top = {
            { component = 11, drawable = 15, texture = 0, palette = 0 },
            { component = 8, drawable = 15, texture = 0, palette = 0 },
            { component = 3, drawable = 15, texture = 0, palette = 0 },
        },
        bottom = {
            { component = 4, drawable = 21, texture = 0, palette = 0 },
        },
    },
    female = {
        top = {
            { component = 11, drawable = 15, texture = 0, palette = 0 },
            { component = 8, drawable = 34, texture = 0, palette = 0 },
            { component = 3, drawable = 15, texture = 0, palette = 0 },
        },
        bottom = {
            { component = 4, drawable = 15, texture = 0, palette = 0 },
        },
    },
}

Config.Deathscreen = {
    -- Built-in death screen stays off while the death system is removed.
    UseBuiltIn = false
}

Config.LocalDoctor = {
    HealTime = 5000, 
    LieAnim = { dict = "amb@world_human_sunbathe@male@back@base", name = "base" }, 
    DoctorPedModel = "s_m_m_doctor_01", 
}

Config.Medical = {
    EMSJobs = { 'ambulance', 'fire' }, 
    DiagnosisTime = 3000,              
    ReviveTime = 10000,                
    TreatmentTime = 5000,              
    EnablePronounceBodyBag = true,     
    BodyBagModel = "xm_prop_body_bag",
    BodyBagOffset = { x = 0.0, y = 0.0, z = 0.0 },
    BodyBagRotation = { x = 0.0, y = 0.0, z = 0.0 }
}

Config.FernocotModel = "fernocot" 

Config.FernocotVehicleModels = { 'ambulance', 'firetruk', 'ambulance2' }
Config.FernocotDisableVehicleCollision = true 

Config.FernocotLieOffset = { x = 0.020, y = 0.000, z = 2.100 }

Config.FernocotLieAnim = { dict = "amb@world_human_sunbathe@male@back@base", name = "base" }

Config.FernocotLieHeading = 86.0

Config.FernocotDragOffset = { x = -0.190, y = 1.520, z = -0.960 }
Config.FernocotDragRotation = { x = 0.0, y = 1.0, z = 96.0 }

-- Searching / carrying downed players (ALT + ox_target / qb-target).
Config.Search = {
    Enabled = true,
    -- Milliseconds a player must wait between searching downed players.
    Cooldown = 15000,
    -- How long (ms) the search progress bar takes before the inventory opens.
    Duration = 15000,
    -- How long (ms) to wait after the "wait" notification before the
    -- inventory actually opens.
    OpenDelay = 1000,
}

Config.Carry = {
    Enabled = true,
}

--[[
    ------------------------------------------------------------------
    DEATH SYSTEM: REMOVED / DISABLED
    ------------------------------------------------------------------
    Set this to true while the resource must NOT touch death at all.

    With it enabled:
      * no downed / unconscious state (nothing is pinned or forced);
      * no death screen, no EMS auto call, no hospital transport;
      * no finish / mercy logic, no 10 minute timer, no inventory wipe;
      * medics cannot revive or body-bag (no player is ever downed);
      * death behaves exactly like vanilla GTA / your framework default.

    Set it back to false only once the new death system is implemented.
]]
Config.DisableDeathSystem = true

Config.ShowFakePlayers = true
Config.FakePlayers = {
    { cid = "FAKE_1", name = "Dr. John Doe", jobLabel = "Ambulance", jobGradeLabel = "Chief", jobName = "ambulance", jobGradeLevel = 5, isOnline = true },
    { cid = "FAKE_2", name = "Jane Smith", jobLabel = "Ambulance", jobGradeLabel = "Paramedic", jobName = "ambulance", jobGradeLevel = 2, isOnline = false },
    { cid = "FAKE_3", name = "Mike Miller", jobLabel = "Fire Dept", jobGradeLabel = "Captain", jobName = "fire", jobGradeLevel = 4, isOnline = true },
}

