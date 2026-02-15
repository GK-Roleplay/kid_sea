Config = {}

Config.UI = {
    TabletEnabled = true
}

Config.Ui = {
    command = 'seatablet',
    keybind = 'F5',
    tabletTitle = 'Sea Explorer Tablet'
}

Config.ClassicMode = {
    enabled = true,
    interactKey = 38,
    interactKeyLabel = 'E',
    startMarkerAtHarbor = true,
    startMessage = 'Sea fishing started. Head to the harbor and begin your run.',
    stopMessage = 'Sea fishing stopped. Use /sea to start again.'
}

Config.Interaction = {
    keyCode = 38,
    keyLabel = 'E',
    markerType = 1,
    markerScale = vec3(2.0, 2.0, 0.45),
    markerColor = { r = 80, g = 174, b = 255, a = 185 },
    drawDistance = 65.0
}

Config.Guidance = {
    showMarkers = true,
    show3DText = true,
    showHelpPrompt = true,
    showObjectiveHint = true,
    objectiveHintMode = 'corner',
    objectiveHintIntervalSeconds = 20
}

Config.ObjectiveBlip = {
    enabled = true,
    routeEnabled = true,
    sprite = 410,
    colour = 3,
    scale = 0.9,
    labelPrefix = 'Sea: '
}

Config.StagePoiBlips = {
    enabled = true,
    shortRange = false,
    points = {
        { stage = 'go_harbor', label = 'Sea Stage: Harbor Start', sprite = 410, colour = 3, scale = 0.8, coords = vec3(-806.2, -1497.4, 1.6) },
        { stage = 'deploy_line', label = 'Sea Stage: Deploy Lines', sprite = 68, colour = 46, scale = 0.82, coords = vec3(-700.0, -1460.0, 0.4) },
        { stage = 'reel_line', label = 'Sea Stage: Reel Zone', sprite = 317, colour = 44, scale = 0.84, coords = vec3(-590.0, -1425.0, 0.4) },
        { stage = 'return_sell', label = 'Sea Stage: Fish Market Sell', sprite = 356, colour = 2, scale = 0.82, coords = vec3(-1847.3, -1193.2, 13.3) }
    }
}

Config.Objective = {
    defaultWaypoint = true
}

Config.Commands = {
    sea = true,
    seahelp = true,
    seastatus = true,
    searoute = true,
    seaboats = true,
    seaselect = true,
    seaspawn = true,
    seanext = true,
    seatp = true,
    putlongline = true,
    reellongline = true
}

Config.Persistence = {
    saveIntervalMs = 60000,
    saveDebounceMs = 1500
}

Config.Security = {
    distanceTolerance = 4.0,
    requireSelectedBoatModel = false,
    requireDriverSeat = true,
    rateLimitsMs = {
        requestSync = 800,
        requestStatus = 900,
        arrivedZone = 1000,
        toggleJob = 1100,
        setWaypoint = 700,
        setRoute = 700,
        classicInteract = 1200,
        startRun = 1600,
        deployLine = 1600,
        reelLine = 1400,
        sellCatch = 1800,
        boatspawn = 1200,
        boatselect = 900
    }
}

Config.Actions = {
    startDurationMs = 2200,
    deployDurationMs = 2200,
    reelDurationMs = 2600,
    sellDurationMs = 2400,
    startScenario = 'WORLD_HUMAN_CLIPBOARD',
    deployScenario = 'WORLD_HUMAN_STAND_FISHING',
    reelScenario = 'WORLD_HUMAN_STAND_IMPATIENT',
    sellScenario = 'WORLD_HUMAN_CLIPBOARD'
}

Config.Progression = {
    maxLevel = 18,
    levelThresholds = {
        0, 100, 240, 420, 650, 930, 1260, 1640, 2070,
        2550, 3080, 3660, 4290, 4970, 5700, 6480, 7310, 8190
    },
    levelBonusPerLevel = 0.02,
    levelBonusCap = 0.30,
    rareWeightBonusPerLevel = 0.03,
    lineBonusEveryLevels = 3,
    maxBonusLines = 5
}

Config.DailyLimit = {
    enabled = true,
    maxRuns = 24,
    friendlyMessage = 'Awesome fishing today. Let us continue tomorrow with fresh seas!'
}

Config.Longline = {
    baseLines = 5,
    spacingMeters = 100.0,
    minSpacingMeters = 100.0,
    minDeployDistanceFromStartMeters = 500.0,
    maxLines = 10,
    deployRadius = 16.0,
    reelRadius = 18.0,
    reelWaitSeconds = 50,
    minSeaDistanceFromHarbor = 100.0
}

Config.Boats = {
    [1] = { model = 'dinghy', label = 'Starter Dinghy', holdCapacityGrams = 45000, payoutBonus = 0.00 },
    [2] = { model = 'suntrap', label = 'Suntrap', holdCapacityGrams = 52000, payoutBonus = 0.01 },
    [3] = { model = 'seashark', label = 'Jet Ski', holdCapacityGrams = 56000, payoutBonus = 0.02 },
    [4] = { model = 'speeder', label = 'Light Speeder', holdCapacityGrams = 64000, payoutBonus = 0.03 },
    [5] = { model = 'squalo', label = 'Squalo', holdCapacityGrams = 71000, payoutBonus = 0.04 },
    [6] = { model = 'tropic', label = 'Tropic', holdCapacityGrams = 79000, payoutBonus = 0.05 },
    [7] = { model = 'jetmax', label = 'Jetmax', holdCapacityGrams = 90000, payoutBonus = 0.06 },
    [8] = { model = 'marquis', label = 'Marquis', holdCapacityGrams = 98000, payoutBonus = 0.07 },
    [9] = { model = 'longfin', label = 'Longfin', holdCapacityGrams = 106000, payoutBonus = 0.08 },
    [10] = { model = 'tug', label = 'Mini Tug', holdCapacityGrams = 115000, payoutBonus = 0.10 },
    [11] = { model = 'dinghy2', label = 'Dinghy Mk2', holdCapacityGrams = 124000, payoutBonus = 0.12 },
    [12] = { model = 'dinghy3', label = 'Dinghy Mk3', holdCapacityGrams = 133000, payoutBonus = 0.14 },
    [13] = { model = 'dinghy4', label = 'Dinghy Mk4', holdCapacityGrams = 142000, payoutBonus = 0.16 },
    [14] = { model = 'speeder2', label = 'Speeder Mk2', holdCapacityGrams = 152000, payoutBonus = 0.18 },
    [15] = { model = 'tropic2', label = 'Tropic Mk2', holdCapacityGrams = 162000, payoutBonus = 0.20 },
    [16] = { model = 'suntrap', label = 'Harbor Runner', holdCapacityGrams = 173000, payoutBonus = 0.23 },
    [17] = { model = 'jetmax', label = 'Ocean Runner', holdCapacityGrams = 184000, payoutBonus = 0.27 },
    [18] = { model = 'longfin', label = 'Master Trawler', holdCapacityGrams = 196000, payoutBonus = 0.32 }
}

Config.FishTypes = {
    anchovy = { label = 'Anchovy', rarityWeight = 42, minGrams = 120, maxGrams = 520, pricePerGram = 0.06, rare = false },
    sardine = { label = 'Sardine', rarityWeight = 38, minGrams = 140, maxGrams = 680, pricePerGram = 0.07, rare = false },
    mackerel = { label = 'Mackerel', rarityWeight = 28, minGrams = 500, maxGrams = 2400, pricePerGram = 0.12, rare = false },
    cod = { label = 'Cod', rarityWeight = 18, minGrams = 1200, maxGrams = 5400, pricePerGram = 0.16, rare = false },
    tuna = { label = 'Tuna', rarityWeight = 11, minGrams = 3500, maxGrams = 18000, pricePerGram = 0.26, rare = false },
    mahi = { label = 'Mahi-Mahi', rarityWeight = 8, minGrams = 2400, maxGrams = 9600, pricePerGram = 0.30, rare = false },
    swordfish = { label = 'Swordfish', rarityWeight = 4, minGrams = 12000, maxGrams = 62000, pricePerGram = 0.42, rare = true },
    marlin = { label = 'Marlin', rarityWeight = 2, minGrams = 15000, maxGrams = 78000, pricePerGram = 0.55, rare = true },
    bluefin = { label = 'Bluefin Giant', rarityWeight = 1, minGrams = 28000, maxGrams = 128000, pricePerGram = 0.74, rare = true }
}

Config.LuckyStrike = {
    enabled = true,
    cheapFishPriceThreshold = 0.13,
    cheapFishRatioThreshold = 0.65,
    hugeRareChance = 0.06,
    hugeRareMultiplierMin = 1.8,
    hugeRareMultiplierMax = 3.2,
    hugeRareFishPool = { 'swordfish', 'marlin', 'bluefin' }
}

Config.Xp = {
    startRun = 15,
    deployLine = 10,
    reelLine = 14,
    sellBase = 40,
    fullRouteBonus = 35
}

Config.Zones = {
    harbor = {
        label = 'Harbor Dock',
        description = 'Start and launch your sea run here.',
        coords = vec3(-806.2, -1497.4, 1.6),
        radius = 22.0,
        markerColor = { r = 82, g = 168, b = 255, a = 180 }
    },
    market = {
        label = 'Fish Market',
        description = 'Weigh and sell your catches here.',
        coords = vec3(-1847.3, -1193.2, 13.3),
        radius = 20.0,
        markerColor = { r = 98, g = 224, b = 145, a = 180 }
    }
}

Config.BoatSpawn = {
    waterZ = 0.4,
    slots = {
        { coords = vec3(-798.3, -1498.3, 0.2), heading = 109.0 },
        { coords = vec3(-792.8, -1501.2, 0.2), heading = 111.0 },
        { coords = vec3(-787.2, -1504.1, 0.2), heading = 112.0 }
    }
}

Config.CatchVisuals = {
    enabled = true,
    maxEntities = 6,
    models = {
        'a_c_fish',
        'a_c_humpback',
        'a_c_killerwhale',
        'a_c_sharkhammer',
        'a_c_sharktiger'
    },
    attachBone = 'chassis',
    attachOrigin = vec3(-0.55, -1.35, 0.25),
    spacing = vec3(1.15, 1.0, 0.85),
    maxPerRow = 2,
    reelPrediction = {
        enableCameraShake = true,
        low = 'Light pull...',
        medium = 'Steady pull...',
        high = 'Heavy pull! Could be good.',
        extreme = 'Extreme pull! Might be huge and rare!'
    }
}
Config.Payout = {
    resource = 'money_system',
    method = 'AddPlayerCash',
    useThirdArg = true,
    thirdArgValue = true
}

