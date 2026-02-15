local Profiles = {}
local Cooldowns = {}
local DbReady = false

local SAVE_DEBOUNCE_MS = (Config.Persistence and Config.Persistence.saveDebounceMs) or 1500
local SAVE_INTERVAL_MS = (Config.Persistence and Config.Persistence.saveIntervalMs) or 60000

local function nowMs() return GetGameTimer() end
local function todayDate() return os.date('%Y-%m-%d') end
local function roundNumber(n) return math.floor((tonumber(n) or 0) + 0.5) end

local function clampInt(value, minValue, maxValue)
    local n = math.floor(tonumber(value) or 0)
    if minValue and n < minValue then n = minValue end
    if maxValue and n > maxValue then n = maxValue end
    return n
end

local function normalizeModelName(name)
    if type(name) ~= 'string' then return nil end
    local model = name:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if model == '' or #model > 64 then return nil end
    if not model:match('^[a-z0-9_]+$') then return nil end
    return model
end

local function normalizeZone(zoneKey)
    local key = tostring(zoneKey or ''):lower()
    return Config.Zones[key] and key or nil
end

local function getIdentifier(source)
    for i = 0, GetNumPlayerIdentifiers(source) - 1 do
        local id = GetPlayerIdentifier(source, i)
        if id and id:sub(1, 8) == 'license:' then return id end
    end
    for i = 0, GetNumPlayerIdentifiers(source) - 1 do
        local id = GetPlayerIdentifier(source, i)
        if id and id ~= '' then return id end
    end
    return ('src:%d'):format(source)
end

local function rateLimit(source, actionKey)
    local limit = tonumber((Config.Security and Config.Security.rateLimitsMs and Config.Security.rateLimitsMs[actionKey]) or 0) or 0
    if limit <= 0 then return true end
    Cooldowns[source] = Cooldowns[source] or {}
    local tick = nowMs()
    local last = Cooldowns[source][actionKey] or 0
    if tick - last < limit then return false end
    Cooldowns[source][actionKey] = tick
    return true
end

local function seaChat(source, message, color)
    TriggerClientEvent('chat:addMessage', source, {
        color = color or { 120, 200, 255 },
        args = { 'kid_sea', message }
    })
end

local function seaToast(source, toastType, text)
    TriggerClientEvent('kid_sea:toast', source, { type = toastType, text = text })
end

local function markDirty(profile)
    profile._dirty = true
    profile._nextSaveAt = nowMs() + SAVE_DEBOUNCE_MS
end

local function getLevelFromXp(xp)
    local thresholds = (Config.Progression and Config.Progression.levelThresholds) or { 0 }
    local maxLevel = clampInt((Config.Progression and Config.Progression.maxLevel) or #thresholds, 1, #thresholds)
    local level = 1
    for i = 1, #thresholds do
        if xp >= thresholds[i] then level = i else break end
    end
    if level > maxLevel then level = maxLevel end
    return level
end

local function getLevelProgressPct(xp, level)
    local thresholds = (Config.Progression and Config.Progression.levelThresholds) or { 0 }
    local current, nxt = thresholds[level] or 0, thresholds[level + 1]
    if not nxt or nxt <= current then return 100 end
    local p = (xp - current) / (nxt - current)
    if p < 0 then p = 0 elseif p > 1 then p = 1 end
    return roundNumber(p * 100)
end

local function getLevelBonusPct(level)
    local perLevel = (Config.Progression and Config.Progression.levelBonusPerLevel) or 0
    local cap = (Config.Progression and Config.Progression.levelBonusCap) or 0
    local pct = math.max(0, (level - 1) * perLevel)
    if pct > cap then pct = cap end
    return pct
end

local function getBoatByLevel(level)
    return Config.Boats and Config.Boats[level] or nil
end

local function sortedBoatLevels()
    local levels = {}
    for level in pairs(Config.Boats or {}) do levels[#levels + 1] = level end
    table.sort(levels)
    return levels
end

local function getBestAllowedBoatLevel(profile)
    local selected = clampInt(profile and profile.selectedBoatLevel or 1, 1)
    if profile and selected <= profile.level and getBoatByLevel(selected) then
        return selected
    end

    local best = nil
    for _, lvl in ipairs(sortedBoatLevels()) do
        if profile and lvl <= profile.level and getBoatByLevel(lvl) then
            best = lvl
        end
    end

    return best or 1
end

local function getBoatLevelByModel(modelName)
    local model = normalizeModelName(modelName)
    if not model then return nil end
    for level, boat in pairs(Config.Boats or {}) do
        if normalizeModelName(boat.model) == model then return level end
    end
    return nil
end

local function getBoatLevelByModelHash(modelHash)
    local hash = tonumber(modelHash)
    if not hash then return nil end
    for level, boat in pairs(Config.Boats or {}) do
        if GetHashKey(boat.model) == hash then return level end
    end
    return nil
end

local function fishConfigByKey(key)
    return Config.FishTypes and Config.FishTypes[key] or nil
end

local function getDailyRemaining(profile)
    if not (Config.DailyLimit and Config.DailyLimit.enabled) then return math.huge end
    return math.max(0, (Config.DailyLimit.maxRuns or 0) - (profile.daily.runs or 0))
end

local function isDailyBlocked(profile)
    if not (Config.DailyLimit and Config.DailyLimit.enabled) then return false end
    return (profile.daily.runs or 0) >= (Config.DailyLimit.maxRuns or 0)
end

local function setStage(profile, stage)
    if profile.stage ~= stage then profile.stage = stage; markDirty(profile) end
end

local function resetDailyIfNeeded(profile)
    local today = todayDate()
    if profile.daily.lastResetDate == today then return false end
    profile.daily.lastResetDate = today
    profile.daily.runs = 0
    if profile.seaEnabled and profile.holdUsedGrams <= 0 then
        setStage(profile, 'go_harbor')
    end
    markDirty(profile)
    return true
end

local function setSeaEnabled(profile, enabled)
    local flag = enabled and true or false
    if profile.seaEnabled ~= flag then profile.seaEnabled = flag; markDirty(profile) end
    if not flag then
        profile.activeRun = nil
        setStage(profile, 'job_off')
        profile.preferences.manualRoute = nil
        return
    end
    if profile.holdUsedGrams > 0 then
        setStage(profile, 'return_sell')
    elseif isDailyBlocked(profile) then
        setStage(profile, 'daily_complete')
    else
        setStage(profile, 'go_harbor')
    end
end

local function getBoatHoldCapacity(profile)
    local boat = getBoatByLevel(profile.selectedBoatLevel)
    return clampInt(boat and boat.holdCapacityGrams or 45000, 1000)
end

local function getLineCountForLevel(level)
    local baseLines = clampInt(Config.Longline and Config.Longline.baseLines or 5, 1)
    local every = clampInt(Config.Progression and Config.Progression.lineBonusEveryLevels or 3, 1)
    local maxBonus = clampInt(Config.Progression and Config.Progression.maxBonusLines or 5, 0)
    local bonus = math.floor(math.max(0, (level - 1)) / every)
    if bonus > maxBonus then bonus = maxBonus end
    local maxLines = clampInt(Config.Longline and Config.Longline.maxLines or (baseLines + maxBonus), baseLines)
    local lines = baseLines + bonus
    if lines > maxLines then lines = maxLines end
    return lines
end

local function pointDistance(ax, ay, az, bx, by, bz)
    local dx = (tonumber(ax) or 0.0) - (tonumber(bx) or 0.0)
    local dy = (tonumber(ay) or 0.0) - (tonumber(by) or 0.0)
    local dz = (tonumber(az) or 0.0) - (tonumber(bz) or 0.0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function getRunPlacedCount(run)
    local count = 0
    if not run or type(run.lines) ~= 'table' then return 0 end
    for i = 1, #run.lines do
        if run.lines[i].deployed then
            count = count + 1
        end
    end
    return count
end

local function findNextUndeployedLineIndex(run)
    if not run or type(run.lines) ~= 'table' then return nil end
    for i = 1, #run.lines do
        if not run.lines[i].deployed then
            return i
        end
    end
    return nil
end

local function findNextReelLineIndex(run)
    if not run or type(run.lines) ~= 'table' then return nil end
    for i = 1, #run.lines do
        local line = run.lines[i]
        if line.deployed and not line.reeled then
            return i
        end
    end
    return nil
end

local function findNextReadyReelLineIndex(run, nowTs)
    if not run or type(run.lines) ~= 'table' then return nil end
    local now = clampInt(nowTs, 0)
    if now <= 0 then now = os.time() end
    for i = 1, #run.lines do
        local line = run.lines[i]
        if line.deployed and not line.reeled and line.x and line.y and line.z and clampInt(line.readyAt, 0) <= now then
            return i
        end
    end
    return nil
end

local function getReelTimingSummary(run, nowTs)
    local out = { total = 0, readyCount = 0, nextReadyIn = 0, nextReadyIndex = nil }
    if not run or type(run.lines) ~= 'table' then return out end

    local now = clampInt(nowTs, 0)
    if now <= 0 then now = os.time() end

    local minReadyIn = nil
    local minReadyIndex = nil
    for i = 1, #run.lines do
        local line = run.lines[i]
        if line.deployed and not line.reeled and line.x and line.y and line.z then
            out.total = out.total + 1
            local readyIn = math.max(0, clampInt(line.readyAt, 0) - now)
            if readyIn <= 0 then
                out.readyCount = out.readyCount + 1
            end
            if minReadyIn == nil or readyIn < minReadyIn then
                minReadyIn = readyIn
                minReadyIndex = i
            end
        end
    end

    out.nextReadyIn = clampInt(minReadyIn or 0, 0)
    out.nextReadyIndex = minReadyIndex
    return out
end

local function syncRunStage(profile)
    local run = profile and profile.activeRun or nil
    if not run then return end

    local nextUnreeled = findNextReelLineIndex(run)
    if not nextUnreeled then
        setStage(profile, 'return_sell')
        return
    end

    local nextReady = findNextReadyReelLineIndex(run, os.time())
    if nextReady then
        run.currentLine = nextReady
        setStage(profile, 'reel_line')
    else
        run.currentLine = nextUnreeled
        setStage(profile, 'wait_reel')
    end
end

local function computeFishEntryValue(key, entry)
    local cfg = fishConfigByKey(key)
    if not cfg then return 0 end
    local grams = clampInt(entry and entry.grams or 0, 0)
    local base = (tonumber(cfg.pricePerGram) or 0) * grams
    local bonus = tonumber(entry and entry.bonusValue or 0) or 0
    return roundNumber(base + bonus)
end

local function getFishHoldValue(profile)
    local total = 0
    for key, entry in pairs(profile.fishHold or {}) do
        total = total + computeFishEntryValue(key, entry)
    end
    return clampInt(total, 0)
end

local function addFishToHold(profile, fishKey, grams, bonusValue)
    profile.fishHold = profile.fishHold or {}
    local current = profile.fishHold[fishKey]
    if type(current) ~= 'table' then
        current = { grams = 0, bonusValue = 0 }
        profile.fishHold[fishKey] = current
    end
    current.grams = clampInt(current.grams, 0) + clampInt(grams, 0)
    current.bonusValue = clampInt(current.bonusValue, 0) + clampInt(bonusValue, 0)
    profile.holdUsedGrams = clampInt(profile.holdUsedGrams, 0) + clampInt(grams, 0)
    markDirty(profile)
end

local function objectiveForProfile(profile)
    if not profile.seaEnabled then return { key = 'job_off', zone = nil, text = 'Use /sea to start deep-sea fishing.' } end
    if profile.stage == 'daily_complete' then return { key = 'daily_complete', zone = nil, text = Config.DailyLimit.friendlyMessage } end
    if profile.stage == 'go_harbor' then return { key = 'go_harbor', zone = 'harbor', text = 'Go to Harbor Dock and press E to prepare your run.' } end
    if profile.stage == 'board_boat' then return { key = 'board_boat', zone = 'harbor', text = 'Board your fishing boat at Harbor and press E again to start the run.' } end
    if profile.stage == 'return_sell' then return { key = 'return_sell', zone = 'market', text = 'Return to Fish Market and sell your catches.' } end

    local run = profile.activeRun
    if run and run.lines then
        if profile.stage == 'deploy_line' then
            local placed = getRunPlacedCount(run)
            local total = clampInt(run.totalLines, 1, #run.lines)
            local minStartDist = clampInt((Config.Longline and Config.Longline.minDeployDistanceFromStartMeters) or 500, 100)
            local minLineSpacing = clampInt((Config.Longline and Config.Longline.minSpacingMeters) or 100, 100)
            return {
                key = 'deploy_line',
                zone = nil,
                text = ('Place longline %d/%d anywhere at sea (>= %dm from start, >= %dm apart).'):format(placed + 1, total, minStartDist, minLineSpacing)
            }
        end

        if profile.stage == 'wait_reel' then
            local summary = getReelTimingSummary(run, os.time())
            local idx = summary.nextReadyIndex or findNextReelLineIndex(run) or clampInt(run.currentLine or 1, 1, #run.lines)
            local line = run.lines[idx]
            if line and line.x and line.y and line.z then
                local text
                if summary.readyCount > 0 then
                    text = ('Longlines ready: %d/%d. Go to a line icon and press E to reel.'):format(summary.readyCount, summary.total)
                else
                    text = ('Longlines are soaking. Next line ready in %ds. Follow line icons and wait to reel.'):format(summary.nextReadyIn)
                end
                return { key = 'wait_reel', zone = nil, coords = { x = line.x, y = line.y, z = line.z }, text = text }
            end
        end

        if profile.stage == 'reel_line' then
            local nowTs = os.time()
            local idx = findNextReadyReelLineIndex(run, nowTs) or findNextReelLineIndex(run) or clampInt(run.currentLine or 1, 1, #run.lines)
            local line = run.lines[idx]
            if line and line.x and line.y and line.z then
                local readyIn = math.max(0, clampInt(line.readyAt, 0) - nowTs)
                local suffix = readyIn > 0 and (' (ready in %ds)'):format(readyIn) or ''
                return { key = 'reel_line', zone = nil, coords = { x = line.x, y = line.y, z = line.z }, text = ('Reel longline %d/%d%s. Press E near the marker.'):format(idx, run.totalLines, suffix) }
            end
        end
    end

    return { key = profile.stage, zone = 'harbor', text = 'Follow your sea objective.' }
end
local function buildQuestSteps(profile)
    local stepHarborDone = profile.stage ~= 'go_harbor' and profile.stage ~= 'job_off'
    local hasRun = profile.activeRun ~= nil
    local run = profile.activeRun or {}
    local totalLines = clampInt(run.totalLines or 0, 0)
    local placedLines = 0
    local reeledLines = 0
    if hasRun and type(run.lines) == 'table' then
        for i = 1, #run.lines do
            if run.lines[i].deployed then placedLines = placedLines + 1 end
            if run.lines[i].reeled then reeledLines = reeledLines + 1 end
        end
    end

    local stepDeployDone = (totalLines > 0 and placedLines >= totalLines) or profile.stage == 'wait_reel' or profile.stage == 'reel_line' or profile.stage == 'return_sell'
    local stepReelDone = (totalLines > 0 and reeledLines >= totalLines) or profile.stage == 'return_sell'
    local stepSellDone = (profile.stage == 'go_harbor' or profile.stage == 'board_boat') and (profile.holdUsedGrams or 0) <= 0 and not hasRun
    local stepStartRunDone = hasRun or profile.stage == 'deploy_line' or profile.stage == 'wait_reel' or profile.stage == 'reel_line' or profile.stage == 'return_sell'

    return {
        { key = 'harbor', label = '1) Press E at Harbor Dock', done = stepHarborDone },
        { key = 'start', label = '2) Board boat and press E again', done = stepStartRunDone },
        { key = 'deploy', label = '3) Deploy all longlines', done = stepDeployDone },
        { key = 'reel', label = '4) Reel catches into hold', done = stepReelDone },
        { key = 'sell', label = '5) Sell fish at market', done = stepSellDone }
    }
end

local function selectedBoatState(profile)
    local boat = getBoatByLevel(profile.selectedBoatLevel)
    if not boat then return nil end
    return {
        level = profile.selectedBoatLevel,
        model = boat.model,
        label = boat.label,
        holdCapacityGrams = boat.holdCapacityGrams,
        payoutBonusPct = roundNumber((boat.payoutBonus or 0) * 100)
    }
end

local function serializeUnlockedBoats(profile)
    local out = {}
    for _, level in ipairs(sortedBoatLevels()) do
        local boat = getBoatByLevel(level)
        out[#out + 1] = {
            level = level,
            model = boat.model,
            label = boat.label,
            holdCapacityGrams = boat.holdCapacityGrams,
            payoutBonusPct = roundNumber((boat.payoutBonus or 0) * 100),
            unlocked = level <= profile.level
        }
    end
    return out
end

local function serializeFishHold(profile)
    local out = {}
    for key, entry in pairs(profile.fishHold or {}) do
        local cfg = fishConfigByKey(key)
        if cfg then
            local grams = clampInt(entry and entry.grams or 0, 0)
            if grams > 0 then
                out[#out + 1] = {
                    key = key,
                    label = cfg.label,
                    grams = grams,
                    pricePerGram = cfg.pricePerGram,
                    estValue = computeFishEntryValue(key, entry),
                    rare = cfg.rare and true or false
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.estValue > b.estValue end)
    return out
end

local function profileState(profile)
    local objective = objectiveForProfile(profile)
    local routeTarget = nil
    if profile.preferences.waypoint then
        if profile.preferences.manualRoute then routeTarget = profile.preferences.manualRoute
        elseif objective.zone then routeTarget = objective.zone end
    end

    local holdCapacity = profile.activeRun and profile.activeRun.holdCapacityGrams or getBoatHoldCapacity(profile)

    local zones = {}
    for key, zone in pairs(Config.Zones or {}) do
        zones[key] = { label = zone.label, coords = { x = zone.coords.x, y = zone.coords.y, z = zone.coords.z }, radius = zone.radius }
    end

    return {
        seaEnabled = profile.seaEnabled,
        stage = profile.stage,
        objective = objective,
        routeTarget = routeTarget,
        level = profile.level,
        xp = profile.xp,
        levelProgressPct = getLevelProgressPct(profile.xp, profile.level),
        levelBonusPct = roundNumber(getLevelBonusPct(profile.level) * 100),
        wallet = profile.wallet,
        selectedBoatLevel = profile.selectedBoatLevel,
        selectedBoat = selectedBoatState(profile),
        unlockedBoats = serializeUnlockedBoats(profile),
        activeRun = profile.activeRun,
        fishHold = serializeFishHold(profile),
        holdUsedGrams = clampInt(profile.holdUsedGrams, 0),
        holdCapacityGrams = holdCapacity,
        holdPct = holdCapacity > 0 and roundNumber((clampInt(profile.holdUsedGrams, 0) / holdCapacity) * 100) or 0,
        daily = {
            runs = profile.daily.runs,
            maxRuns = Config.DailyLimit and Config.DailyLimit.maxRuns or 0,
            remaining = getDailyRemaining(profile),
            lastResetDate = profile.daily.lastResetDate
        },
        stats = {
            runsCompleted = profile.stats.runsCompleted,
            totalEarned = profile.stats.totalEarned,
            totalFishGrams = profile.stats.totalFishGrams
        },
        preferences = {
            waypoint = profile.preferences.waypoint,
            manualRoute = profile.preferences.manualRoute
        },
        questSteps = buildQuestSteps(profile),
        zones = zones
    }
end

local function syncProfile(source, profile)
    TriggerClientEvent('kid_sea:syncState', source, profileState(profile))
end

local function safeDecode(str)
    if type(str) ~= 'string' or str == '' then return nil end
    local ok, obj = pcall(json.decode, str)
    if not ok or type(obj) ~= 'table' then return nil end
    return obj
end

local function createDefaultProfile(identifier)
    return {
        identifier = identifier,
        xp = 0,
        level = 1,
        wallet = 0,
        selectedBoatLevel = 1,
        seaEnabled = false,
        stage = 'job_off',
        activeRun = nil,
        fishHold = {},
        holdUsedGrams = 0,
        daily = { runs = 0, lastResetDate = todayDate() },
        stats = { runsCompleted = 0, totalEarned = 0, totalFishGrams = 0 },
        preferences = { waypoint = Config.Objective.defaultWaypoint and true or false, manualRoute = nil },
        _dirty = false,
        _nextSaveAt = 0,
        _saving = false
    }
end

local function sanitizeFishHold(raw)
    local out = {}
    if type(raw) ~= 'table' then return out end
    for key, entry in pairs(raw) do
        local fishKey = normalizeModelName(key)
        if fishKey and fishConfigByKey(fishKey) then
            local grams = clampInt(type(entry) == 'table' and entry.grams or entry, 0)
            local bonusValue = clampInt(type(entry) == 'table' and entry.bonusValue or 0, 0)
            if grams > 0 then out[fishKey] = { grams = grams, bonusValue = bonusValue } end
        end
    end
    return out
end

local function sanitizeRun(raw)
    if type(raw) ~= 'table' then return nil end
    local lines = {}
    local waterZ = (Config.BoatSpawn and Config.BoatSpawn.waterZ) or 0.5

    for i, line in ipairs(raw.lines or {}) do
        local x = tonumber(line.x)
        local y = tonumber(line.y)
        local z = tonumber(line.z)
        local deployed = line.deployed and true or false

        if not deployed then
            x = nil
            y = nil
            z = nil
        else
            z = z or waterZ
        end

        lines[i] = {
            index = i,
            x = x,
            y = y,
            z = z,
            deployed = deployed,
            reeled = line.reeled and true or false,
            readyAt = clampInt(line.readyAt, 0),
            fishType = normalizeModelName(line.fishType),
            grams = clampInt(line.grams, 0),
            hugeRare = line.hugeRare and true or false,
            reelHint = clampInt(line.reelHint, 1, 4),
            bonusValue = clampInt(line.bonusValue, 0)
        }
    end

    if #lines == 0 then return nil end

    local startPos = nil
    if type(raw.startPos) == 'table' then
        local sx = tonumber(raw.startPos.x)
        local sy = tonumber(raw.startPos.y)
        local sz = tonumber(raw.startPos.z)
        if sx and sy then
            startPos = { x = sx, y = sy, z = sz or waterZ }
        end
    end

    return {
        id = tostring(raw.id or ('sea_' .. tostring(os.time()))),
        boatLevel = clampInt(raw.boatLevel, 1),
        boatModel = normalizeModelName(raw.boatModel) or (getBoatByLevel(clampInt(raw.boatLevel, 1)) or {}).model,
        holdCapacityGrams = clampInt(raw.holdCapacityGrams, 1000),
        totalLines = clampInt(raw.totalLines, 1, #lines),
        currentLine = clampInt(raw.currentLine, 1, #lines),
        startedAt = clampInt(raw.startedAt, os.time()),
        hugeRareCount = clampInt(raw.hugeRareCount, 0),
        cheapFishGrams = clampInt(raw.cheapFishGrams, 0),
        totalStoredGrams = clampInt(raw.totalStoredGrams, 0),
        startPos = startPos,
        lines = lines
    }
end

local function loadProfile(source)
    local identifier = getIdentifier(source)
    local row = DB.fetchOne('SELECT * FROM kid_sea_players WHERE identifier = @identifier', { ['@identifier'] = identifier })
    local profile = createDefaultProfile(identifier)

    if row then
        profile.xp = clampInt(row.xp, 0)
        profile.level = getLevelFromXp(profile.xp)
        profile.wallet = clampInt(row.wallet, 0)
        profile.selectedBoatLevel = clampInt(row.selected_boat_level, 1)
        profile.seaEnabled = (tonumber(row.sea_enabled) or 0) == 1
        profile.stage = tostring(row.stage or (profile.seaEnabled and 'go_harbor' or 'job_off'))
        profile.activeRun = sanitizeRun(safeDecode(row.active_run))
        profile.fishHold = sanitizeFishHold(safeDecode(row.fish_hold))
        profile.holdUsedGrams = clampInt(row.hold_used_grams, 0)
        profile.daily.runs = clampInt(row.daily_runs, 0)
        profile.daily.lastResetDate = tostring(row.last_reset_date or todayDate())
        profile.stats.runsCompleted = clampInt(row.runs_completed, 0)
        profile.stats.totalEarned = clampInt(row.total_earned, 0)
        profile.stats.totalFishGrams = clampInt(row.total_fish_grams, 0)
        profile.preferences.waypoint = (tonumber(row.waypoint_enabled) or 0) == 1
        profile.preferences.manualRoute = normalizeZone(row.manual_route)

        if profile.selectedBoatLevel > profile.level then profile.selectedBoatLevel = profile.level; markDirty(profile) end
        if not getBoatByLevel(profile.selectedBoatLevel) then profile.selectedBoatLevel = 1; markDirty(profile) end

        local computed = 0
        for _, entry in pairs(profile.fishHold) do computed = computed + clampInt(entry.grams, 0) end
        if computed ~= profile.holdUsedGrams then profile.holdUsedGrams = computed; markDirty(profile) end
    else
        markDirty(profile)
    end

    resetDailyIfNeeded(profile)
    Profiles[source] = profile
    return profile
end

local function ensureProfile(source)
    if Profiles[source] then return Profiles[source] end
    if not DbReady then return nil end
    return loadProfile(source)
end

local function saveProfile(source, force)
    local profile = Profiles[source]
    if not profile then return end
    if profile._saving then return end
    if not force and not profile._dirty then return end

    profile._saving = true
    DB.execute([[ 
        INSERT INTO kid_sea_players (
            identifier, xp, level, wallet, selected_boat_level,
            sea_enabled, stage, active_run, fish_hold, hold_used_grams,
            daily_runs, last_reset_date, runs_completed, total_earned,
            total_fish_grams, waypoint_enabled, manual_route
        ) VALUES (
            @identifier, @xp, @level, @wallet, @selected_boat_level,
            @sea_enabled, @stage, @active_run, @fish_hold, @hold_used_grams,
            @daily_runs, @last_reset_date, @runs_completed, @total_earned,
            @total_fish_grams, @waypoint_enabled, @manual_route
        )
        ON DUPLICATE KEY UPDATE
            xp = VALUES(xp), level = VALUES(level), wallet = VALUES(wallet),
            selected_boat_level = VALUES(selected_boat_level),
            sea_enabled = VALUES(sea_enabled),
            stage = VALUES(stage),
            active_run = VALUES(active_run),
            fish_hold = VALUES(fish_hold),
            hold_used_grams = VALUES(hold_used_grams),
            daily_runs = VALUES(daily_runs),
            last_reset_date = VALUES(last_reset_date),
            runs_completed = VALUES(runs_completed),
            total_earned = VALUES(total_earned),
            total_fish_grams = VALUES(total_fish_grams),
            waypoint_enabled = VALUES(waypoint_enabled),
            manual_route = VALUES(manual_route)
    ]], {
        ['@identifier'] = profile.identifier,
        ['@xp'] = profile.xp,
        ['@level'] = profile.level,
        ['@wallet'] = profile.wallet,
        ['@selected_boat_level'] = profile.selectedBoatLevel,
        ['@sea_enabled'] = profile.seaEnabled and 1 or 0,
        ['@stage'] = profile.stage,
        ['@active_run'] = profile.activeRun and json.encode(profile.activeRun) or nil,
        ['@fish_hold'] = profile.fishHold and json.encode(profile.fishHold) or nil,
        ['@hold_used_grams'] = profile.holdUsedGrams,
        ['@daily_runs'] = profile.daily.runs,
        ['@last_reset_date'] = profile.daily.lastResetDate,
        ['@runs_completed'] = profile.stats.runsCompleted,
        ['@total_earned'] = profile.stats.totalEarned,
        ['@total_fish_grams'] = profile.stats.totalFishGrams,
        ['@waypoint_enabled'] = profile.preferences.waypoint and 1 or 0,
        ['@manual_route'] = profile.preferences.manualRoute
    })

    profile._dirty = false
    profile._nextSaveAt = 0
    profile._saving = false
end

local function ensureLoadedThen(source, action)
    local profile = ensureProfile(source)
    if not profile then
        seaToast(source, 'warn', 'Sea fishing data is loading. Please wait a moment.')
        return
    end
    resetDailyIfNeeded(profile)
    if profile.seaEnabled and profile.holdUsedGrams > 0 and not profile.activeRun and profile.stage ~= 'return_sell' then
        setStage(profile, 'return_sell')
    elseif profile.seaEnabled and not profile.activeRun and profile.holdUsedGrams <= 0 and profile.stage == 'return_sell' then
        setStage(profile, isDailyBlocked(profile) and 'daily_complete' or 'go_harbor')
    elseif profile.seaEnabled and not profile.activeRun and profile.holdUsedGrams <= 0
        and profile.stage ~= 'go_harbor' and profile.stage ~= 'board_boat' and profile.stage ~= 'daily_complete' then
        setStage(profile, isDailyBlocked(profile) and 'daily_complete' or 'go_harbor')
    elseif profile.seaEnabled and profile.activeRun then
        local run = profile.activeRun
        if profile.stage == 'deploy_line' and not findNextUndeployedLineIndex(run) then
            syncRunStage(profile)
        elseif profile.stage == 'wait_reel' or profile.stage == 'reel_line' then
            syncRunStage(profile)
        end
    end
    action(profile)
end
local function getDistanceToZone(source, zoneKey)
    local zone = Config.Zones[zoneKey]
    if not zone then return math.huge end
    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 then return math.huge end
    local pos = GetEntityCoords(ped)
    local dx, dy, dz = pos.x - zone.coords.x, pos.y - zone.coords.y, pos.z - zone.coords.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function isNearZone(source, zoneKey)
    local zone = Config.Zones[zoneKey]
    if not zone then return false end
    local tolerance = (Config.Security and Config.Security.distanceTolerance) or 3.5
    return getDistanceToZone(source, zoneKey) <= (zone.radius + tolerance)
end

local function getCurrentLine(profile)
    local run = profile.activeRun
    if not run or type(run.lines) ~= 'table' then return nil, nil end
    local idx = clampInt(run.currentLine or 1, 1, #run.lines)
    return run.lines[idx], idx
end

local function isNearCurrentLine(source, profile, action)
    local line = getCurrentLine(profile)
    if not line or not line.x or not line.y or not line.z then
        return false, math.huge
    end
    local radius = action == 'reel' and ((Config.Longline and Config.Longline.reelRadius) or 18.0) or ((Config.Longline and Config.Longline.deployRadius) or 16.0)
    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 then return false, math.huge end
    local pos = GetEntityCoords(ped)
    local dx, dy, dz = pos.x - line.x, pos.y - line.y, pos.z - line.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    local tolerance = (Config.Security and Config.Security.distanceTolerance) or 3.5
    return dist <= (radius + tolerance), dist
end

local function isNearLineIndex(source, profile, lineIndex, action)
    local run = profile and profile.activeRun or nil
    if not run or type(run.lines) ~= 'table' then
        return false, math.huge
    end

    local idx = clampInt(lineIndex, 1, #run.lines)
    local line = run.lines[idx]
    if not line or not line.x or not line.y or not line.z then
        return false, math.huge
    end

    local radius = action == 'reel'
        and ((Config.Longline and Config.Longline.reelRadius) or 18.0)
        or ((Config.Longline and Config.Longline.deployRadius) or 16.0)
    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 then return false, math.huge end
    local pos = GetEntityCoords(ped)
    local dx, dy, dz = pos.x - line.x, pos.y - line.y, pos.z - line.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    local tolerance = (Config.Security and Config.Security.distanceTolerance) or 3.5
    return dist <= (radius + tolerance), dist
end

local function findClosestPendingLineIndex(source, profile)
    local run = profile and profile.activeRun or nil
    if not run or type(run.lines) ~= 'table' then return nil end

    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 then return nil end
    local pos = GetEntityCoords(ped)

    local nearestIndex, nearestDist = nil, nil
    for i = 1, #run.lines do
        local line = run.lines[i]
        if line and line.deployed and not line.reeled and line.x and line.y and line.z then
            local dx, dy, dz = pos.x - line.x, pos.y - line.y, pos.z - line.z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if nearestDist == nil or dist < nearestDist then
                nearestIndex, nearestDist = i, dist
            end
        end
    end

    return nearestIndex
end

local function isPlayerInValidBoat(source, profile)
    local ped = GetPlayerPed(source)
    local veh = ped and GetVehiclePedIsIn(ped, false) or 0
    if not veh or veh <= 0 then return false, 'Board a fishing boat first.' end

    if Config.Security and Config.Security.requireDriverSeat and GetPedInVehicleSeat(veh, -1) ~= ped then
        return false, 'You must be the driver of the boat.'
    end

    local modelHash = GetEntityModel(veh)
    local boatLevel = getBoatLevelByModelHash(modelHash)
    if not boatLevel then return false, 'This is not a configured fishing boat.' end
    if boatLevel > profile.level then return false, ('This boat needs level %d.'):format(boatLevel) end

    if Config.Security and Config.Security.requireSelectedBoatModel and boatLevel ~= profile.selectedBoatLevel then
        return false, 'Use your selected boat for this run.'
    end

    return true, nil, veh, boatLevel, getBoatByLevel(boatLevel)
end

local function applyXp(source, profile, amount)
    amount = clampInt(amount, 0)
    if amount <= 0 then return end
    local before = profile.level
    profile.xp = clampInt(profile.xp + amount, 0)
    profile.level = getLevelFromXp(profile.xp)
    if profile.selectedBoatLevel > profile.level then profile.selectedBoatLevel = profile.level end
    if profile.level > before then
        TriggerClientEvent('kid_sea:levelUp', source, { previousLevel = before, level = profile.level })
    end
    markDirty(profile)
end

local function tryPayoutExternal(source, amount)
    local payoutCfg = Config.Payout or {}
    if not payoutCfg.resource or not payoutCfg.method then return false end
    if GetResourceState(payoutCfg.resource) ~= 'started' then return false end

    local ok, result
    if payoutCfg.useThirdArg then
        ok, result = pcall(function() return exports[payoutCfg.resource][payoutCfg.method](source, amount, payoutCfg.thirdArgValue) end)
    else
        ok, result = pcall(function() return exports[payoutCfg.resource][payoutCfg.method](source, amount) end)
    end
    return ok and result ~= false
end

local function chooseFish(profile, run)
    local entries = {}
    local totalWeight = 0.0
    local rareWeightBonus = math.max(0, (Config.Progression and Config.Progression.rareWeightBonusPerLevel or 0) * math.max(0, profile.level - 1))

    for key, cfg in pairs(Config.FishTypes or {}) do
        local w = tonumber(cfg.rarityWeight) or 0
        if cfg.rare then w = w * (1.0 + rareWeightBonus) end
        if w > 0 then
            totalWeight = totalWeight + w
            entries[#entries + 1] = { key = key, cfg = cfg, upto = totalWeight }
        end
    end

    if totalWeight <= 0 then return nil end

    local roll = math.random() * totalWeight
    local selected = entries[1]
    for _, row in ipairs(entries) do if roll <= row.upto then selected = row break end end

    local grams = math.random(clampInt(selected.cfg.minGrams, 1), clampInt(selected.cfg.maxGrams, 1))
    local ppg = tonumber(selected.cfg.pricePerGram) or 0
    local hugeRare = false

    if Config.LuckyStrike and Config.LuckyStrike.enabled then
        local cheapThreshold = tonumber(Config.LuckyStrike.cheapFishPriceThreshold) or 0.13
        local ratioThreshold = tonumber(Config.LuckyStrike.cheapFishRatioThreshold) or 0.65
        local chance = tonumber(Config.LuckyStrike.hugeRareChance) or 0.06
        local cheapRatio = 0.0
        if clampInt(run.totalStoredGrams, 0) > 0 then
            cheapRatio = clampInt(run.cheapFishGrams, 0) / clampInt(run.totalStoredGrams, 1)
        end

        if cheapRatio >= ratioThreshold and math.random() < chance then
            local pool = Config.LuckyStrike.hugeRareFishPool or {}
            if #pool > 0 then
                local key = pool[math.random(1, #pool)]
                local rareCfg = Config.FishTypes[key]
                if rareCfg then
                    selected = { key = key, cfg = rareCfg }
                    local minMul = tonumber(Config.LuckyStrike.hugeRareMultiplierMin) or 1.8
                    local maxMul = tonumber(Config.LuckyStrike.hugeRareMultiplierMax) or 3.2
                    local sizeMul = minMul + math.random() * (maxMul - minMul)
                    grams = roundNumber(math.random(clampInt(rareCfg.minGrams, 1), clampInt(rareCfg.maxGrams, 1)) * sizeMul)
                    ppg = (tonumber(rareCfg.pricePerGram) or 0) * (1.2 + sizeMul * 0.4)
                    hugeRare = true
                end
            end
        end
    end

    local basePpg = tonumber(selected.cfg.pricePerGram) or ppg
    local bonusValue = roundNumber(math.max(0, grams * ppg - grams * basePpg))

    return {
        key = selected.key,
        cfg = selected.cfg,
        grams = clampInt(grams, 1),
        hugeRare = hugeRare,
        basePpg = basePpg,
        bonusValue = bonusValue
    }
end

local spawnSelectedBoat

local function buildRunLineSlots(totalLines)
    local lines = {}
    local waterZ = (Config.BoatSpawn and Config.BoatSpawn.waterZ) or 0.5
    for i = 1, totalLines do
        lines[i] = {
            index = i,
            x = nil,
            y = nil,
            z = waterZ,
            deployed = false,
            reeled = false,
            readyAt = 0,
            fishType = nil,
            grams = 0,
            hugeRare = false,
            reelHint = 1,
            bonusValue = 0
        }
    end
    return lines
end

local function prepareRunStartAction(source, profile)
    if not profile.seaEnabled then seaToast(source, 'warn', 'Use /sea first.') return end
    if profile.stage ~= 'go_harbor' and profile.stage ~= 'board_boat' then
        seaToast(source, 'warn', objectiveForProfile(profile).text)
        return
    end
    if not isNearZone(source, 'harbor') then
        seaToast(source, 'warn', 'Move to Harbor Dock first.')
        return
    end
    if clampInt(profile.holdUsedGrams, 0) > 0 then
        setStage(profile, 'return_sell')
        seaToast(source, 'warn', 'Sell your current fish first.')
        return
    end

    setStage(profile, 'board_boat')

    local valid, reason = isPlayerInValidBoat(source, profile)
    if not valid then
        if reason == 'Board a fishing boat first.' then
            spawnSelectedBoat(source, profile)
            seaToast(source, 'info', 'Boat spawned at harbor. Board it, then press E again to start your run.')
            markDirty(profile)
            return
        end
        seaToast(source, 'warn', reason)
        markDirty(profile)
        return
    end

    seaToast(source, 'success', 'Boat ready. Press E again at Harbor to start longline deployment stage.')
    markDirty(profile)
end

local function startRunAction(source, profile)
    if not profile.seaEnabled then seaToast(source, 'warn', 'Use /sea first.') return end
    if profile.stage == 'go_harbor' then
        seaToast(source, 'warn', 'Press E at Harbor first, then board your boat and press E again to start.')
        return
    end
    if profile.stage ~= 'board_boat' then seaToast(source, 'warn', objectiveForProfile(profile).text) return end
    if not isNearZone(source, 'harbor') then seaToast(source, 'warn', 'Move to Harbor Dock first.') return end
    if clampInt(profile.holdUsedGrams, 0) > 0 then setStage(profile, 'return_sell'); seaToast(source, 'warn', 'Sell your current fish first.'); return end

    local valid, reason, veh, boatLevel, boat = isPlayerInValidBoat(source, profile)
    if not valid then
        if reason == 'Board a fishing boat first.' then
            spawnSelectedBoat(source, profile)
            seaToast(source, 'info', 'Boat spawned for your level. Board it and press E again at Harbor to start.')
            return
        end
        seaToast(source, 'warn', reason)
        return
    end

    local lineCount = getLineCountForLevel(profile.level)
    local startPos = GetEntityCoords(veh)
    profile.activeRun = {
        id = ('sea_%d_%d'):format(source, os.time()),
        boatLevel = boatLevel,
        boatModel = boat.model,
        holdCapacityGrams = clampInt(boat.holdCapacityGrams, 1000),
        totalLines = lineCount,
        currentLine = 1,
        startedAt = os.time(),
        hugeRareCount = 0,
        cheapFishGrams = 0,
        totalStoredGrams = 0,
        startPos = { x = startPos.x, y = startPos.y, z = startPos.z },
        lines = buildRunLineSlots(lineCount)
    }

    TriggerClientEvent('kid_sea:clearCatchVisuals', source)
    applyXp(source, profile, Config.Xp and Config.Xp.startRun or 15)
    setStage(profile, 'deploy_line')
    markDirty(profile)
    seaToast(source, 'success', ('Run started with %d longlines. Go at least %dm offshore before placing your first line.'):format(lineCount, clampInt((Config.Longline and Config.Longline.minDeployDistanceFromStartMeters) or 500, 100)))
end

local function deployLineAction(source, profile)
    if profile.stage ~= 'deploy_line' then seaToast(source, 'warn', objectiveForProfile(profile).text) return end
    if not profile.activeRun then seaToast(source, 'warn', 'No active run.') return end

    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 then return end

    local posEntity = ped
    if IsPedInAnyVehicle(ped, false) then
        local veh = GetVehiclePedIsIn(ped, false)
        if not veh or veh <= 0 then
            seaToast(source, 'warn', 'Invalid boat state. Try again.')
            return
        end

        local boatLevel = getBoatLevelByModelHash(GetEntityModel(veh))
        if not boatLevel then
            seaToast(source, 'warn', 'You must be on a configured fishing boat.')
            return
        end
        if boatLevel > profile.level then
            seaToast(source, 'warn', ('This boat needs level %d.'):format(boatLevel))
            return
        end
        if Config.Security and Config.Security.requireSelectedBoatModel and boatLevel ~= profile.selectedBoatLevel then
            seaToast(source, 'warn', 'Use your selected boat for this run.')
            return
        end

        posEntity = veh
    end

    local run = profile.activeRun
    local nextIdx = findNextUndeployedLineIndex(run)
    if not nextIdx then
        syncRunStage(profile)
        if profile.stage == 'reel_line' then
            seaToast(source, 'info', 'All longlines placed. At least one line is ready, go reel it with E.')
        elseif profile.stage == 'wait_reel' then
            local summary = getReelTimingSummary(run, os.time())
            seaToast(source, 'info', ('All longlines placed. First line ready in %ds.'):format(summary.nextReadyIn))
        else
            setStage(profile, 'return_sell')
            seaToast(source, 'warn', 'No deployable lines left.')
        end
        markDirty(profile)
        return
    end

    local pos = GetEntityCoords(posEntity)
    local minStartDist = clampInt((Config.Longline and Config.Longline.minDeployDistanceFromStartMeters) or 500, 100)
    local minSpacing = clampInt((Config.Longline and Config.Longline.minSpacingMeters) or 100, 100)

    local startPos = run.startPos
    if not (startPos and startPos.x and startPos.y) then
        startPos = { x = pos.x, y = pos.y, z = pos.z }
        run.startPos = startPos
    end

    local distFromStart = pointDistance(pos.x, pos.y, pos.z, startPos.x, startPos.y, startPos.z or pos.z)
    if distFromStart < minStartDist then
        seaToast(source, 'warn', ('Go further out to sea first (%dm minimum from start, %.1fm left).'):format(minStartDist, minStartDist - distFromStart))
        return
    end

    for i = 1, #run.lines do
        local other = run.lines[i]
        if other.deployed and other.x and other.y then
            local d = pointDistance(pos.x, pos.y, pos.z, other.x, other.y, other.z or pos.z)
            if d < minSpacing then
                seaToast(source, 'warn', ('Longlines must be at least %dm apart (%.1fm).'):format(minSpacing, d))
                return
            end
        end
    end

    local line = run.lines[nextIdx]
    line.deployed = true
    line.reeled = false
    line.x = pos.x
    line.y = pos.y
    line.z = pos.z
    line.readyAt = os.time() + clampInt(Config.Longline and Config.Longline.reelWaitSeconds or 180, 1)
    local hintRoll = math.random(1, 100)
    line.reelHint = (hintRoll <= 50 and 1) or (hintRoll <= 80 and 2) or (hintRoll <= 95 and 3) or 4

    applyXp(source, profile, Config.Xp and Config.Xp.deployLine or 10)

    local remainingDeploy = findNextUndeployedLineIndex(run)
    local placedCount = getRunPlacedCount(run)
    if remainingDeploy then
        run.currentLine = remainingDeploy
        setStage(profile, 'deploy_line')
        seaToast(source, 'success', ('Longline %d/%d placed. Place the next one >= %dm away.'):format(placedCount, run.totalLines, minSpacing))
    else
        syncRunStage(profile)
        if profile.stage == 'reel_line' then
            seaToast(source, 'success', ('All %d longlines placed. Go to a line icon and press E to reel.'):format(run.totalLines))
        elseif profile.stage == 'wait_reel' then
            local summary = getReelTimingSummary(run, os.time())
            seaToast(source, 'success', ('All %d longlines placed. Wait %ds then start reeling with E.'):format(run.totalLines, summary.nextReadyIn))
        else
            setStage(profile, 'return_sell')
            seaToast(source, 'warn', 'No lines available to reel. Returning to market stage.')
        end
    end

    markDirty(profile)
end

local function reelLineAction(source, profile, payload)
    if profile.stage ~= 'reel_line' and profile.stage ~= 'wait_reel' then
        seaToast(source, 'warn', objectiveForProfile(profile).text)
        return
    end
    if not profile.activeRun then seaToast(source, 'warn', 'No active run.') return end

    local valid, reason = isPlayerInValidBoat(source, profile)
    if not valid then seaToast(source, 'warn', reason) return end

    local run = profile.activeRun
    syncRunStage(profile)

    local idx = nil
    local targetIndex = tonumber(payload and payload.lineIndex or payload and payload.index or nil)
    if targetIndex then
        targetIndex = clampInt(targetIndex, 1, #run.lines)
        local targetLine = run.lines[targetIndex]
        if not (targetLine and targetLine.deployed and not targetLine.reeled and targetLine.x and targetLine.y and targetLine.z) then
            seaToast(source, 'warn', 'That longline is no longer available.')
            return
        end
        idx = targetIndex
    end

    if not idx and profile.stage == 'wait_reel' then
        local summary = getReelTimingSummary(run, os.time())
        seaToast(source, 'info', ('Lines still soaking. Next line ready in %ds.'):format(summary.nextReadyIn))
        markDirty(profile)
        return
    end

    if not idx then
        idx = findClosestPendingLineIndex(source, profile)
    end

    if not idx then
        idx = findNextReadyReelLineIndex(run, os.time())
        if not idx then
            syncRunStage(profile)
            if profile.stage == 'wait_reel' then
                local summary = getReelTimingSummary(run, os.time())
                seaToast(source, 'info', ('Lines still soaking. Next line ready in %ds.'):format(summary.nextReadyIn))
                markDirty(profile)
                return
            end
            idx = findNextReelLineIndex(run)
        end
    end

    if not idx then
        setStage(profile, 'return_sell')
        seaToast(source, 'info', 'All lines reeled. Return to Fish Market.')
        markDirty(profile)
        return
    end

    run.currentLine = idx
    local line = run.lines[idx]
    if not (line and line.x and line.y and line.z) then
        seaToast(source, 'warn', 'That line has no position. Deploy all lines first.')
        return
    end

    local near, dist
    if targetIndex then
        near, dist = isNearLineIndex(source, profile, idx, 'reel')
    else
        near, dist = isNearCurrentLine(source, profile, 'reel')
    end
    if not near then seaToast(source, 'warn', ('Move closer to line marker (%.1fm).'):format(dist)) return end

    local readyIn = clampInt(line.readyAt, 0) - os.time()
    if readyIn > 0 then
        seaToast(source, 'warn', ('Fish are still biting. Wait %d seconds.'):format(readyIn))
        return
    end

    local catch = chooseFish(profile, run)
    if not catch then seaToast(source, 'warn', 'Fish roll failed.') return end

    line.reeled = true
    line.fishType = catch.key
    line.grams = catch.grams
    line.hugeRare = catch.hugeRare
    line.bonusValue = catch.bonusValue
    line.x = nil
    line.y = nil
    line.z = nil
    TriggerClientEvent('kid_sea:lineReeled', source, { lineIndex = idx })

    local holdCap = clampInt(run.holdCapacityGrams, 1000)
    local available = holdCap - clampInt(profile.holdUsedGrams, 0)
    local storedGrams = math.max(0, math.min(catch.grams, available))
    local thrownBack = math.max(0, catch.grams - storedGrams)

    if storedGrams > 0 then
        local storedBonus = catch.grams > 0 and roundNumber(catch.bonusValue * (storedGrams / catch.grams)) or 0
        addFishToHold(profile, catch.key, storedGrams, storedBonus)
        TriggerClientEvent('kid_sea:addCatchVisual', source, { fishKey = catch.key, hugeRare = catch.hugeRare })
        run.totalStoredGrams = clampInt(run.totalStoredGrams, 0) + storedGrams
        if catch.basePpg <= (tonumber(Config.LuckyStrike and Config.LuckyStrike.cheapFishPriceThreshold or 0.13) or 0.13) then
            run.cheapFishGrams = clampInt(run.cheapFishGrams, 0) + storedGrams
        end
        if catch.hugeRare then
            run.hugeRareCount = clampInt(run.hugeRareCount, 0) + 1
            seaToast(source, 'success', ('HUGE RARE CATCH! %s (%dg stored).'):format(catch.cfg.label, storedGrams))
        else
            seaToast(source, 'success', ('Caught %s (%dg stored).'):format(catch.cfg.label, storedGrams))
        end
        if thrownBack > 0 then
            seaToast(source, 'warn', ('Hold limit reached. %dg of %s was thrown back.'):format(thrownBack, catch.cfg.label))
        end
    elseif thrownBack > 0 then
        seaToast(source, 'warn', ('Hold full. Entire %s catch (%dg) was thrown back.'):format(catch.cfg.label, thrownBack))
    end

    applyXp(source, profile, Config.Xp and Config.Xp.reelLine or 14)

    syncRunStage(profile)
    if profile.stage == 'reel_line' then
        seaToast(source, 'info', ('Longline %d reeled. Continue to the next ready line and press E.'):format(idx))
    elseif profile.stage == 'wait_reel' then
        local summary = getReelTimingSummary(run, os.time())
        seaToast(source, 'info', ('Longline %d reeled. Next line ready in %ds.'):format(idx, summary.nextReadyIn))
    else
        seaToast(source, 'info', 'All lines complete. Return to Fish Market.')
    end

    markDirty(profile)
end

local function sellCatchAction(source, profile)
    if profile.stage ~= 'return_sell' then seaToast(source, 'warn', objectiveForProfile(profile).text) return end
    if not isNearZone(source, 'market') then seaToast(source, 'warn', 'Move to Fish Market first.') return end

    local soldGrams = clampInt(profile.holdUsedGrams, 0)
    local subtotal = getFishHoldValue(profile)
    local levelBonus = getLevelBonusPct(profile.level)
    local boatLevel = profile.activeRun and profile.activeRun.boatLevel or profile.selectedBoatLevel
    local boat = getBoatByLevel(boatLevel)
    local boatBonus = tonumber(boat and boat.payoutBonus or 0) or 0

    local totalPayout = roundNumber(subtotal * (1.0 + levelBonus + boatBonus))
    if totalPayout > 0 then
        local paid = tryPayoutExternal(source, totalPayout)
        if not paid then profile.wallet = clampInt(profile.wallet + totalPayout, 0) end
    end

    local xpGain = clampInt(Config.Xp and Config.Xp.sellBase or 40, 0)
    if profile.activeRun then xpGain = xpGain + clampInt(Config.Xp and Config.Xp.fullRouteBonus or 35, 0) end
    applyXp(source, profile, xpGain)

    local hugeRareCount = profile.activeRun and clampInt(profile.activeRun.hugeRareCount, 0) or 0
    TriggerClientEvent('kid_sea:runReceipt', source, {
        soldGrams = soldGrams,
        subtotal = subtotal,
        totalPayout = totalPayout,
        levelBonusPct = roundNumber(levelBonus * 100),
        boatBonusPct = roundNumber(boatBonus * 100),
        xpGained = xpGain,
        hugeRareCount = hugeRareCount,
        fishBreakdown = serializeFishHold(profile)
    })

    profile.stats.runsCompleted = clampInt(profile.stats.runsCompleted, 0) + 1
    profile.stats.totalEarned = clampInt(profile.stats.totalEarned, 0) + totalPayout
    profile.stats.totalFishGrams = clampInt(profile.stats.totalFishGrams, 0) + soldGrams
    profile.daily.runs = clampInt(profile.daily.runs, 0) + 1

    profile.activeRun = nil
    profile.fishHold = {}
    profile.holdUsedGrams = 0
    TriggerClientEvent('kid_sea:clearCatchVisuals', source)

    if isDailyBlocked(profile) then setStage(profile, 'daily_complete')
    else setStage(profile, 'go_harbor') end

    markDirty(profile)
end

local function selectBoatAction(source, profile, level)
    local boat = getBoatByLevel(level)
    if not boat then seaToast(source, 'warn', 'Invalid boat level.') return end
    if level > profile.level then seaToast(source, 'warn', ('Boat locked. Reach level %d.'):format(level)); return end
    profile.selectedBoatLevel = level
    markDirty(profile)
    seaToast(source, 'success', ('Selected boat: L%d %s'):format(level, boat.label))
end

spawnSelectedBoat = function(source, profile)
    local allowedLevel = getBestAllowedBoatLevel(profile)
    local boat = getBoatByLevel(allowedLevel)
    if not boat then seaToast(source, 'warn', 'No selected boat.') return end
    if profile.selectedBoatLevel ~= allowedLevel then
        profile.selectedBoatLevel = allowedLevel
        markDirty(profile)
    end
    local slots = Config.BoatSpawn and Config.BoatSpawn.slots or {}
    local slot = slots[((tonumber(source) or 1) % math.max(1, #slots)) + 1] or { coords = vec3(-798.3, -1498.3, 0.2), heading = 109.0 }

    TriggerClientEvent('kid_sea:spawnBoat', source, {
        model = boat.model,
        label = boat.label,
        coords = { x = slot.coords.x, y = slot.coords.y, z = slot.coords.z },
        heading = slot.heading,
        placeInBoat = true
    })
end

local function registerEventsAndCommands()
    RegisterNetEvent('kid_sea:requestSync', function()
        local source = source
        if not rateLimit(source, 'requestSync') then return end
        ensureLoadedThen(source, function(profile) syncProfile(source, profile) end)
    end)

    RegisterNetEvent('kid_sea:requestStatus', function()
        local source = source
        if not rateLimit(source, 'requestStatus') then return end
        ensureLoadedThen(source, function(profile)
            TriggerClientEvent('kid_sea:status', source, profileState(profile))
        end)
    end)

    RegisterNetEvent('kid_sea:setWaypoint', function(enabled)
        local source = source
        if not rateLimit(source, 'setWaypoint') then return end
        ensureLoadedThen(source, function(profile)
            profile.preferences.waypoint = enabled and true or false
            if not profile.preferences.waypoint then profile.preferences.manualRoute = nil end
            markDirty(profile)
            syncProfile(source, profile)
        end)
    end)

    RegisterNetEvent('kid_sea:arrivedZone', function(zoneKey)
        local source = source
        if not rateLimit(source, 'arrivedZone') then return end
        local zone = normalizeZone(zoneKey)
        if not zone then return end
        ensureLoadedThen(source, function(profile)
            if not profile.seaEnabled then return end
            if not isNearZone(source, zone) then return end
            syncProfile(source, profile)
        end)
    end)

    RegisterNetEvent('kid_sea:startRun', function()
        local source = source
        if not rateLimit(source, 'startRun') then return end
        ensureLoadedThen(source, function(profile)
            startRunAction(source, profile)
            syncProfile(source, profile)
        end)
    end)

    RegisterNetEvent('kid_sea:deployLine', function()
        local source = source
        if not rateLimit(source, 'deployLine') then return end
        ensureLoadedThen(source, function(profile)
            deployLineAction(source, profile)
            syncProfile(source, profile)
        end)
    end)

    RegisterNetEvent('kid_sea:reelLine', function(payload)
        local source = source
        if not rateLimit(source, 'reelLine') then return end
        ensureLoadedThen(source, function(profile)
            reelLineAction(source, profile, payload)
            syncProfile(source, profile)
        end)
    end)

    RegisterNetEvent('kid_sea:sellCatch', function()
        local source = source
        if not rateLimit(source, 'sellCatch') then return end
        ensureLoadedThen(source, function(profile)
            sellCatchAction(source, profile)
            syncProfile(source, profile)
        end)
    end)

    RegisterNetEvent('kid_sea:selectBoat', function(payload)
        local source = source
        if not rateLimit(source, 'boatselect') then return end
        ensureLoadedThen(source, function(profile)
            local level = tonumber(payload and payload.level or nil)
            if not level and payload and payload.model then level = getBoatLevelByModel(payload.model) end
            if not level then seaToast(source, 'warn', 'Invalid boat selection.') return end
            selectBoatAction(source, profile, clampInt(level, 1))
            syncProfile(source, profile)
        end)
    end)

    RegisterNetEvent('kid_sea:requestSpawnBoat', function()
        local source = source
        if not rateLimit(source, 'boatspawn') then return end
        ensureLoadedThen(source, function(profile)
            spawnSelectedBoat(source, profile)
            syncProfile(source, profile)
        end)
    end)

    RegisterNetEvent('kid_sea:classicInteract', function(payload)
        local source = source
        if not Config.ClassicMode.enabled then return end
        if not rateLimit(source, 'classicInteract') then return end
        local zone = normalizeZone(payload and payload.zone)

        ensureLoadedThen(source, function(profile)
            if not profile.seaEnabled then
                if zone == 'harbor' and Config.ClassicMode.startMarkerAtHarbor then
                    setSeaEnabled(profile, true)
                    seaToast(source, 'success', Config.ClassicMode.startMessage)
                    syncProfile(source, profile)
                    return
                end
                seaToast(source, 'warn', 'Use /sea to start deep-sea fishing.')
                syncProfile(source, profile)
                return
            end

            if profile.stage == 'go_harbor' and zone == 'harbor' then
                prepareRunStartAction(source, profile)
                syncProfile(source, profile)
                return
            end
            if profile.stage == 'board_boat' and zone == 'harbor' then
                startRunAction(source, profile)
                syncProfile(source, profile)
                return
            end
            if profile.stage == 'return_sell' and zone == 'market' then
                sellCatchAction(source, profile)
                syncProfile(source, profile)
                return
            end

            seaToast(source, 'warn', objectiveForProfile(profile).text)
            syncProfile(source, profile)
        end)
    end)

    if Config.Commands.sea then
        RegisterCommand('sea', function(source, args)
            if source == 0 then return end
            if not rateLimit(source, 'toggleJob') then return end
            ensureLoadedThen(source, function(profile)
                local arg = tostring(args[1] or ''):lower()
                local enable
                if arg == 'on' or arg == 'start' then enable = true
                elseif arg == 'off' or arg == 'stop' then enable = false
                else enable = not profile.seaEnabled end
                setSeaEnabled(profile, enable)
                if enable then seaToast(source, 'success', Config.ClassicMode.startMessage) else seaToast(source, 'warn', Config.ClassicMode.stopMessage) end
                syncProfile(source, profile)
            end)
        end, false)
    end

    if Config.Commands.seastatus then
        RegisterCommand('seastatus', function(source)
            if source == 0 then return end
            ensureLoadedThen(source, function(profile)
                local objective = objectiveForProfile(profile)
                seaChat(source, ('Level %d | XP %d | Stage %s'):format(profile.level, profile.xp, profile.stage))
                seaChat(source, ('Hold: %dkg / %dkg'):format(roundNumber(profile.holdUsedGrams / 1000), roundNumber(getBoatHoldCapacity(profile) / 1000)))
                seaChat(source, ('Daily: %d/%d (remaining %d)'):format(profile.daily.runs, Config.DailyLimit.maxRuns, getDailyRemaining(profile)))
                seaChat(source, ('Objective: %s'):format(objective.text))
            end)
        end, false)
    end

    if Config.Commands.seahelp then
        RegisterCommand('seahelp', function(source)
            if source == 0 then return end
            seaChat(source, 'Loop: /sea -> Harbor (E) -> Board boat -> Harbor (E again) -> Deploy -> Reel -> Market sell.')
            seaChat(source, 'Commands: /seastatus, /seaboats, /seaselect <level|model>, /seaspawn, /seatablet')
        end, false)
    end

    if Config.Commands.seaboats then
        RegisterCommand('seaboats', function(source)
            if source == 0 then return end
            ensureLoadedThen(source, function(profile)
                seaChat(source, ('Selected boat level: %d'):format(profile.selectedBoatLevel))
                for _, lvl in ipairs(sortedBoatLevels()) do
                    local b = getBoatByLevel(lvl)
                    local status = lvl <= profile.level and 'UNLOCKED' or ('LOCKED L' .. tostring(lvl))
                    seaChat(source, ('L%d %s (%s) hold %dkg | %s'):format(lvl, b.label, b.model, roundNumber(b.holdCapacityGrams / 1000), status))
                end
            end)
        end, false)
    end

    if Config.Commands.searoute then
        RegisterCommand('searoute', function(source, args)
            if source == 0 then return end
            if not rateLimit(source, 'setRoute') then return end
            ensureLoadedThen(source, function(profile)
                local arg = tostring(args[1] or ''):lower()
                if arg == '' or arg == 'auto' or arg == 'objective' then
                    profile.preferences.manualRoute = nil
                    profile.preferences.waypoint = true
                    markDirty(profile)
                    seaToast(source, 'success', 'Route set to automatic objective mode.')
                    syncProfile(source, profile)
                    return
                end
                if arg == 'off' then
                    profile.preferences.manualRoute = nil
                    profile.preferences.waypoint = false
                    markDirty(profile)
                    seaToast(source, 'warn', 'Route guidance turned off.')
                    syncProfile(source, profile)
                    return
                end

                local zone = normalizeZone(arg)
                if not zone then
                    seaToast(source, 'warn', 'Usage: /searoute [harbor|market|off|auto]')
                    return
                end

                profile.preferences.manualRoute = zone
                profile.preferences.waypoint = true
                markDirty(profile)
                seaToast(source, 'success', ('Route locked to %s.'):format(Config.Zones[zone].label))
                syncProfile(source, profile)
            end)
        end, false)
    end

    if Config.Commands.seaselect then
        RegisterCommand('seaselect', function(source, args)
            if source == 0 then return end
            local arg = tostring(args[1] or '')
            if arg == '' then seaToast(source, 'warn', 'Usage: /seaselect <level|model>') return end
            ensureLoadedThen(source, function(profile)
                local level = tonumber(arg)
                if not level then level = getBoatLevelByModel(arg) end
                if not level then seaToast(source, 'warn', 'Unknown boat selection.') return end
                selectBoatAction(source, profile, clampInt(level, 1))
                syncProfile(source, profile)
            end)
        end, false)
    end

    if Config.Commands.seaspawn then
        RegisterCommand('seaspawn', function(source)
            if source == 0 then return end
            ensureLoadedThen(source, function(profile)
                spawnSelectedBoat(source, profile)
                syncProfile(source, profile)
            end)
        end, false)
    end
end

registerEventsAndCommands()

AddEventHandler('playerDropped', function()
    local source = source
    if Profiles[source] then saveProfile(source, true) end
    Profiles[source] = nil
    Cooldowns[source] = nil
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for source in pairs(Profiles) do saveProfile(source, true) end
end)

CreateThread(function()
    while true do
        Wait(1000)
        local tick = nowMs()
        for source, profile in pairs(Profiles) do
            if profile._dirty and profile._nextSaveAt > 0 and tick >= profile._nextSaveAt then
                saveProfile(source, false)
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(SAVE_INTERVAL_MS)
        for source, profile in pairs(Profiles) do
            if profile._dirty then saveProfile(source, false) end
        end
    end
end)

DB.ready(function()
    DB.execute([[ 
        CREATE TABLE IF NOT EXISTS kid_sea_players (
            identifier VARCHAR(80) NOT NULL PRIMARY KEY,
            xp INT NOT NULL DEFAULT 0,
            level INT NOT NULL DEFAULT 1,
            wallet INT NOT NULL DEFAULT 0,
            selected_boat_level INT NOT NULL DEFAULT 1,
            sea_enabled TINYINT(1) NOT NULL DEFAULT 0,
            stage VARCHAR(32) NOT NULL DEFAULT 'job_off',
            active_run LONGTEXT NULL,
            fish_hold LONGTEXT NULL,
            hold_used_grams INT NOT NULL DEFAULT 0,
            daily_runs INT NOT NULL DEFAULT 0,
            last_reset_date DATE NOT NULL,
            runs_completed INT NOT NULL DEFAULT 0,
            total_earned INT NOT NULL DEFAULT 0,
            total_fish_grams INT NOT NULL DEFAULT 0,
            waypoint_enabled TINYINT(1) NOT NULL DEFAULT 1,
            manual_route VARCHAR(32) NULL,
            updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            INDEX idx_kid_sea_level (level),
            INDEX idx_kid_sea_daily (last_reset_date)
        )
    ]])

    local function hasColumn(colName)
        local rows = DB.fetchAll(('SHOW COLUMNS FROM kid_sea_players LIKE "%s"'):format(colName))
        return rows and rows[1] ~= nil
    end

    local function ensureColumn(colName, alterSql)
        if not hasColumn(colName) then DB.execute(alterSql) end
    end

    ensureColumn('wallet', 'ALTER TABLE kid_sea_players ADD COLUMN wallet INT NOT NULL DEFAULT 0')
    ensureColumn('selected_boat_level', 'ALTER TABLE kid_sea_players ADD COLUMN selected_boat_level INT NOT NULL DEFAULT 1')
    ensureColumn('sea_enabled', 'ALTER TABLE kid_sea_players ADD COLUMN sea_enabled TINYINT(1) NOT NULL DEFAULT 0')
    ensureColumn('stage', 'ALTER TABLE kid_sea_players ADD COLUMN stage VARCHAR(32) NOT NULL DEFAULT "job_off"')
    ensureColumn('active_run', 'ALTER TABLE kid_sea_players ADD COLUMN active_run LONGTEXT NULL')
    ensureColumn('fish_hold', 'ALTER TABLE kid_sea_players ADD COLUMN fish_hold LONGTEXT NULL')
    ensureColumn('hold_used_grams', 'ALTER TABLE kid_sea_players ADD COLUMN hold_used_grams INT NOT NULL DEFAULT 0')
    ensureColumn('total_fish_grams', 'ALTER TABLE kid_sea_players ADD COLUMN total_fish_grams INT NOT NULL DEFAULT 0')
    ensureColumn('waypoint_enabled', 'ALTER TABLE kid_sea_players ADD COLUMN waypoint_enabled TINYINT(1) NOT NULL DEFAULT 1')
    ensureColumn('manual_route', 'ALTER TABLE kid_sea_players ADD COLUMN manual_route VARCHAR(32) NULL')

    DbReady = true
    print('[kid_sea] database ready and deep-sea fishing loop loaded.')
end)

