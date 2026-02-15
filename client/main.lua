local tabletOpen = false
local actionBusy = false
local actionCancelled = false
local playerState = nil
local objectiveBlip = nil
local stagePoiBlips = {}
local longlineBlips = {}
local currentInsideZone = nil
local lastHintTick = 0
local catchVisualEntities = {}
local catchVisualCursor = 0
local ensureModelLoaded

local function pushFeedText(text)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandThefeedPostTicker(false, false)
end

local function pushToast(toastType, text)
    SendNUIMessage({ action = 'toast', toast = { type = toastType, text = text } })
    if text and text ~= '' then pushFeedText(text) end
end

local function drawHelpText(message)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(message)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

local function drawText3D(coords, text)
    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(coords.x, coords.y, coords.z)
    if not onScreen then return end
    SetTextScale(0.32, 0.32)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(255, 255, 255, 220)
    SetTextCentre(true)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(sx, sy)
end

local function drawCornerObjective(text)
    SetTextFont(4)
    SetTextScale(0.37, 0.37)
    SetTextColour(235, 245, 255, 225)
    SetTextDropShadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 205)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(('Objective: %s'):format(text))
    EndTextCommandDisplayText(0.015, 0.76)
end

local function showSubtitle(text)
    BeginTextCommandPrint('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandPrint(2800, true)
end

local function chatHint(text)
    TriggerEvent('chat:addMessage', { color = { 120, 200, 255 }, args = { 'kid_sea', text } })
end

local function openTablet(tab)
    if not Config.UI.TabletEnabled then
        pushFeedText('Sea tablet is disabled. Use classic mode controls.')
        return
    end
    tabletOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', tab = tab or 'run', title = Config.Ui.tabletTitle })
    if playerState then SendNUIMessage({ action = 'sync', state = playerState }) end
end

local function closeTablet()
    tabletOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
    SendNUIMessage({ action = 'progress', show = false })
end

local function getDistanceToCoords(coords)
    local pos = GetEntityCoords(PlayerPedId())
    local dx, dy, dz = pos.x - coords.x, pos.y - coords.y, pos.z - coords.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function isNearZone(zoneKey)
    local zone = Config.Zones[zoneKey]
    if not zone then return false end
    return getDistanceToCoords(zone.coords) <= zone.radius
end

local function isSeaDeployContext(ped)
    local p = ped or PlayerPedId()
    if p <= 0 then return false end

    local function isAllowedFishingBoat(vehicle)
        if not vehicle or vehicle <= 0 or not DoesEntityExist(vehicle) then return false end
        local modelHash = GetEntityModel(vehicle)
        for _, boat in pairs(Config.Boats or {}) do
            if boat and boat.model and GetHashKey(boat.model) == modelHash then
                return true
            end
        end
        return false
    end

    local function getNearbyFishingBoat(pos, radius)
        local candidates = {
            GetClosestVehicle(pos.x, pos.y, pos.z, radius, 0, 0),
            GetClosestVehicle(pos.x, pos.y, pos.z, radius, 0, 127),
            GetClosestVehicle(pos.x, pos.y, pos.z, radius, 0, 70)
        }
        for i = 1, #candidates do
            local veh = candidates[i]
            if isAllowedFishingBoat(veh) and IsEntityInWater(veh) then
                return veh
            end
        end
        return 0
    end

    local veh = GetVehiclePedIsIn(p, false)
    if isAllowedFishingBoat(veh) and IsEntityInWater(veh) then
        return true
    end

    if IsEntityInWater(p) then
        return true
    end

    local pos = GetEntityCoords(p)
    local nearest = getNearbyFishingBoat(pos, 20.0)
    if not nearest or nearest <= 0 or not DoesEntityExist(nearest) then
        return false
    end

    if IsEntityTouchingEntity(p, nearest) then
        return true
    end

    local modelHash = GetEntityModel(nearest)
    local minDim, maxDim = GetModelDimensions(modelHash)
    local rel = GetOffsetFromEntityGivenWorldCoords(nearest, pos.x, pos.y, pos.z)
    if rel then
        local padXY = 2.25
        local padUp = 4.5
        local padDown = 1.5
        if rel.x >= (minDim.x - padXY) and rel.x <= (maxDim.x + padXY)
            and rel.y >= (minDim.y - padXY) and rel.y <= (maxDim.y + padXY)
            and rel.z >= (minDim.z - padDown) and rel.z <= (maxDim.z + padUp) then
            return true
        end
    end

    local vPos = GetEntityCoords(nearest)
    local dx, dy, dz = pos.x - vPos.x, pos.y - vPos.y, pos.z - vPos.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    local zDiff = math.abs(pos.z - vPos.z)
    return dist <= 8.0 and zDiff <= 5.0
end

local function getUnixNow()
    local t = GetCloudTimeAsInt()
    if t and t > 0 then
        return t
    end
    return os.time()
end

local function expectedZoneFromStage()
    if not playerState then return nil end
    local stage = playerState.stage
    if stage == 'go_harbor' or stage == 'board_boat' then return 'harbor' end
    if stage == 'return_sell' then return 'market' end
    return nil
end

local function promptForZone(zoneKey)
    if not playerState or not playerState.seaEnabled then
        if zoneKey == 'harbor' and Config.ClassicMode.startMarkerAtHarbor then return 'Press ~INPUT_CONTEXT~ to start sea fishing.' end
        return 'Use /sea to start sea fishing.'
    end

    if playerState.stage == 'daily_complete' then return Config.DailyLimit.friendlyMessage end

    local expected = expectedZoneFromStage()
    if expected and zoneKey ~= expected then
        local expectedLabel = Config.Zones[expected] and Config.Zones[expected].label or expected
        return ('You need to go to %s next.'):format(expectedLabel)
    end

    if zoneKey == 'harbor' and playerState.stage == 'go_harbor' then return 'Press ~INPUT_CONTEXT~ to prepare your sea run.' end
    if zoneKey == 'harbor' and playerState.stage == 'board_boat' then return 'Board a fishing boat, then press ~INPUT_CONTEXT~ again to start run.' end
    if zoneKey == 'market' and playerState.stage == 'return_sell' then return 'Press ~INPUT_CONTEXT~ to sell your catches.' end
    return 'Follow your objective marker.'
end

local function getCurrentLine()
    local run = playerState and playerState.activeRun
    if not run or type(run.lines) ~= 'table' then return nil, nil end

    if playerState and (playerState.stage == 'reel_line' or playerState.stage == 'wait_reel') then
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local nearestLine, nearestIndex, nearestDist = nil, nil, nil

        for i = 1, #run.lines do
            local line = run.lines[i]
            if line and line.deployed and not line.reeled and line.x and line.y and line.z then
                local dx, dy, dz = pos.x - line.x, pos.y - line.y, pos.z - line.z
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if nearestDist == nil or dist < nearestDist then
                    nearestLine, nearestIndex, nearestDist = line, i, dist
                end
            end
        end

        if nearestLine then return nearestLine, nearestIndex end
    end

    local idx = tonumber(run.currentLine or 1) or 1
    idx = math.floor(idx)
    if idx < 1 then idx = 1 end
    if idx > #run.lines then idx = #run.lines end

    local line = run.lines[idx]
    if line and line.x and line.y and line.z then
        return line, idx
    end

    return nil, nil
end

local function getReelGuideInfo()
    if not playerState or (playerState.stage ~= 'reel_line' and playerState.stage ~= 'wait_reel') then
        return nil
    end
    local run = playerState.activeRun
    if not run or type(run.lines) ~= 'table' then
        return nil
    end

    local nowTs = getUnixNow()
    local total = 0
    local ready = 0
    local nextReadyIn = nil
    for i = 1, #run.lines do
        local line = run.lines[i]
        if line and line.deployed and not line.reeled and line.x and line.y and line.z then
            total = total + 1
            local readyIn = math.max(0, (tonumber(line.readyAt) or 0) - nowTs)
            if readyIn <= 0 then
                ready = ready + 1
            end
            if nextReadyIn == nil or readyIn < nextReadyIn then
                nextReadyIn = readyIn
            end
        end
    end

    return {
        total = total,
        ready = ready,
        nextReadyIn = math.max(0, math.floor(nextReadyIn or 0))
    }
end

local function buildReelGuideText(info)
    if not info or info.total <= 0 then
        return 'Go to a longline icon and press ~INPUT_CONTEXT~ to reel.'
    end
    if info.ready > 0 then
        return ('Longlines ready: ~g~%d/%d~s~.~n~Go to a line icon and press ~INPUT_CONTEXT~ to reel.'):format(info.ready, info.total)
    end
    return ('Longlines soaking: ~y~0/%d ready~s~.~n~Next line ready in ~b~%ds~s~.'):format(info.total, info.nextReadyIn)
end

local function isNearCurrentLine(action)
    local line = select(1, getCurrentLine())
    if not line then return false, math.huge end
    local radius = action == 'reel' and ((Config.Longline and Config.Longline.reelRadius) or 18.0) or ((Config.Longline and Config.Longline.deployRadius) or 16.0)
    local dist = getDistanceToCoords(vec3(line.x, line.y, line.z))
    return dist <= radius, dist
end

local function getDeployProgressInfo(ped)
    if not playerState or playerState.stage ~= 'deploy_line' then return nil end
    local run = playerState.activeRun
    if not run or type(run.lines) ~= 'table' then return nil end

    local p = ped or PlayerPedId()
    if p <= 0 then return nil end
    local pos = GetEntityCoords(p)

    local minStartDist = math.max(1.0, tonumber(Config.Longline and Config.Longline.minDeployDistanceFromStartMeters or 500.0) or 500.0)
    local minSpacing = math.max(1.0, tonumber(Config.Longline and Config.Longline.minSpacingMeters or 100.0) or 100.0)

    local startPos = run.startPos
    local sx, sy, sz
    if type(startPos) == 'table' and startPos.x and startPos.y then
        sx, sy, sz = tonumber(startPos.x) or 0.0, tonumber(startPos.y) or 0.0, tonumber(startPos.z) or pos.z
    elseif Config.Zones and Config.Zones.harbor and Config.Zones.harbor.coords then
        sx, sy, sz = Config.Zones.harbor.coords.x, Config.Zones.harbor.coords.y, Config.Zones.harbor.coords.z
    else
        sx, sy, sz = pos.x, pos.y, pos.z
    end

    local dx, dy, dz = pos.x - sx, pos.y - sy, pos.z - sz
    local startDist = math.sqrt(dx * dx + dy * dy + dz * dz)
    local startRemaining = math.max(0.0, minStartDist - startDist)
    local startOk = startDist >= minStartDist

    local nearestSpacingDist = nil
    for i = 1, #run.lines do
        local line = run.lines[i]
        if line and line.deployed and line.x and line.y and line.z then
            local lx, ly, lz = line.x, line.y, line.z
            local vx, vy, vz = pos.x - lx, pos.y - ly, pos.z - lz
            local d = math.sqrt(vx * vx + vy * vy + vz * vz)
            if not nearestSpacingDist or d < nearestSpacingDist then
                nearestSpacingDist = d
            end
        end
    end

    local spacingOk = true
    local spacingRemaining = 0.0
    if nearestSpacingDist then
        spacingRemaining = math.max(0.0, minSpacing - nearestSpacingDist)
        spacingOk = nearestSpacingDist >= minSpacing
    end

    return {
        minStartDist = minStartDist,
        minSpacing = minSpacing,
        startDist = startDist,
        startRemaining = startRemaining,
        startOk = startOk,
        nearestSpacingDist = nearestSpacingDist,
        spacingRemaining = spacingRemaining,
        spacingOk = spacingOk,
        ready = startOk and spacingOk
    }
end

local function buildDeployGuideText(info, contextReady)
    if not info then
        return 'Press ~INPUT_CONTEXT~ to place longline.~n~Type /putlongline to deploy.'
    end

    local startLine
    if info.startOk then
        startLine = ('500m offshore: ~g~%dm/%dm OK~s~'):format(math.floor(info.startDist + 0.5), math.floor(info.minStartDist + 0.5))
    else
        startLine = ('500m offshore: ~y~%dm/%dm~s~ (%dm left)'):format(math.floor(info.startDist + 0.5), math.floor(info.minStartDist + 0.5), math.floor(info.startRemaining + 0.5))
    end

    local spacingLine
    if not info.nearestSpacingDist then
        spacingLine = ('100m spacing: ~g~FIRST LINE (no spacing check)~s~')
    elseif info.spacingOk then
        spacingLine = ('100m spacing: ~g~%dm/%dm OK~s~'):format(math.floor(info.nearestSpacingDist + 0.5), math.floor(info.minSpacing + 0.5))
    else
        spacingLine = ('100m spacing: ~y~%dm/%dm~s~ (%dm left)'):format(math.floor(info.nearestSpacingDist + 0.5), math.floor(info.minSpacing + 0.5), math.floor(info.spacingRemaining + 0.5))
    end

    local stateLine = info.ready and '~g~READY TO DEPLOY~s~' or '~y~NOT READY YET~s~'
    if not contextReady then
        stateLine = stateLine .. '~n~Context: stand in sea water or on boat deck.'
    end

    return startLine .. '~n~' .. spacingLine .. '~n~' .. stateLine .. '~n~Type /putlongline to deploy.'
end

local function clearCatchVisuals()
    for i = #catchVisualEntities, 1, -1 do
        local ent = catchVisualEntities[i]
        if ent and ent > 0 and DoesEntityExist(ent) then
            DetachEntity(ent, true, true)
            DeleteEntity(ent)
        end
        catchVisualEntities[i] = nil
    end
end

local function getCurrentBoat()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh and veh > 0 then return veh end
    return 0
end

local function getCatchVisualModel(index, modelPool)
    local cfg = Config.CatchVisuals
    if not cfg or not cfg.enabled then return nil end
    local models = modelPool or cfg.models or {}
    if #models == 0 then return nil end
    local i = ((index - 1) % #models) + 1
    return models[i]
end

local function resolveCatchVisualModel(payload)
    local explicit = payload and tostring(payload.model or '') or ''
    if explicit ~= '' then
        return explicit
    end

    local fishKey = payload and tostring(payload.fishKey or ''):lower() or ''
    local hugeRare = payload and payload.hugeRare and true or false

    if hugeRare then
        catchVisualCursor = catchVisualCursor + 1
        return getCatchVisualModel(catchVisualCursor, { 'a_c_humpback', 'a_c_killerwhale' })
    end

    if fishKey == 'swordfish' or fishKey == 'marlin' or fishKey == 'bluefin' then
        catchVisualCursor = catchVisualCursor + 1
        return getCatchVisualModel(catchVisualCursor, { 'a_c_sharkhammer', 'a_c_sharktiger' })
    end

    catchVisualCursor = catchVisualCursor + 1
    return getCatchVisualModel(catchVisualCursor)
end

local function attachCatchVisualToBoat(vehicle, modelName, slotIndex)
    if not vehicle or vehicle <= 0 or not DoesEntityExist(vehicle) then return false end
    if not modelName or modelName == '' then return false end

    local hash = GetHashKey(modelName)
    if not IsModelInCdimage(hash) then return false end
    if not ensureModelLoaded(hash, 8000) then return false end

    local entity = 0
    if IsModelAPed(hash) then
        entity = CreatePed(28, hash, 0.0, 0.0, 0.0, 0.0, false, false)
    end
    if (not entity or entity <= 0) then
        entity = CreateObjectNoOffset(hash, 0.0, 0.0, 0.0, false, false, false)
    end
    if not entity or entity <= 0 then
        SetModelAsNoLongerNeeded(hash)
        return false
    end

    if IsEntityAPed(entity) then
        SetBlockingOfNonTemporaryEvents(entity, true)
        SetPedCanRagdoll(entity, false)
        TaskSetBlockingOfNonTemporaryEvents(entity, true)
    end

    local cfg = Config.CatchVisuals or {}
    local origin = cfg.attachOrigin or vec3(-0.55, -1.35, 0.25)
    local spacing = cfg.spacing or vec3(1.15, 1.0, 0.85)
    local maxPerRow = math.max(1, tonumber(cfg.maxPerRow) or 2)

    local idx = math.max(1, tonumber(slotIndex) or 1)
    local row = math.floor((idx - 1) / maxPerRow)
    local col = (idx - 1) % maxPerRow

    local ox = origin.x + (col * spacing.x)
    local oy = origin.y + (row * spacing.y)
    local oz = origin.z + (row * (spacing.z * 0.35))

    if modelName == 'a_c_humpback' or modelName == 'a_c_killerwhale' then
        oy = oy - 1.4
        oz = oz + 0.8
    elseif modelName == 'a_c_sharkhammer' or modelName == 'a_c_sharktiger' then
        oy = oy - 0.5
        oz = oz + 0.25
    end

    local bone = GetEntityBoneIndexByName(vehicle, cfg.attachBone or 'chassis')
    if bone == -1 then bone = 0 end

    SetEntityCollision(entity, false, false)
    SetEntityInvincible(entity, true)
    FreezeEntityPosition(entity, true)
    AttachEntityToEntity(entity, vehicle, bone, ox, oy, oz, 0.0, 0.0, 90.0 * col, false, false, false, false, 2, true)

    catchVisualEntities[#catchVisualEntities + 1] = entity
    SetModelAsNoLongerNeeded(hash)
    return true
end

local function addCatchVisual(payload)
    local cfg = Config.CatchVisuals
    if not cfg or not cfg.enabled then return end

    local maxEntities = math.max(1, tonumber(cfg.maxEntities) or 6)
    if #catchVisualEntities >= maxEntities then
        local first = table.remove(catchVisualEntities, 1)
        if first and first > 0 and DoesEntityExist(first) then
            DetachEntity(first, true, true)
            DeleteEntity(first)
        end
    end

    local vehicle = getCurrentBoat()
    if not vehicle or vehicle <= 0 then return end

    local model = resolveCatchVisualModel(payload)
    if model and model ~= '' then
        attachCatchVisualToBoat(vehicle, model, #catchVisualEntities + 1)
    end
end

local function syncCatchVisualsFromHold()
    local cfg = Config.CatchVisuals
    if not cfg or not cfg.enabled then return end

    local holdRows = playerState and playerState.fishHold or {}
    if type(holdRows) ~= 'table' or #holdRows <= 0 then
        if #catchVisualEntities > 0 then clearCatchVisuals() end
        return
    end

    for i = #catchVisualEntities, 1, -1 do
        local ent = catchVisualEntities[i]
        if not ent or ent <= 0 or not DoesEntityExist(ent) then
            table.remove(catchVisualEntities, i)
        end
    end

    local vehicle = getCurrentBoat()
    if not vehicle or vehicle <= 0 then
        return
    end

    local maxVis = math.max(1, tonumber(cfg.maxEntities) or 6)
    local target = math.min(maxVis, #holdRows)
    while #catchVisualEntities < target do
        addCatchVisual({})
    end
end

ensureModelLoaded = function(modelHash, timeoutMs)
    local timeoutAt = GetGameTimer() + (timeoutMs or 7000)
    RequestModel(modelHash)
    while not HasModelLoaded(modelHash) do
        if GetGameTimer() > timeoutAt then return false end
        Wait(20)
    end
    return true
end

local function spawnBoat(modelName, label, coords, heading, placeInBoat)
    local modelHash = GetHashKey(modelName)
    if not IsModelInCdimage(modelHash) or not IsModelAVehicle(modelHash) then
        pushToast('error', ('Boat model invalid: %s'):format(modelName))
        return
    end

    if not ensureModelLoaded(modelHash, 9000) then
        pushToast('error', ('Could not load boat model: %s'):format(modelName))
        return
    end

    local vehicle = CreateVehicle(modelHash, coords.x, coords.y, coords.z, heading or 0.0, true, false)
    if not vehicle or vehicle <= 0 then
        pushToast('error', 'Boat spawn failed.')
        return
    end

    SetVehicleOnGroundProperly(vehicle)
    SetEntityAsMissionEntity(vehicle, true, true)
    SetModelAsNoLongerNeeded(modelHash)

    if placeInBoat then
        local ped = PlayerPedId()
        SetPedIntoVehicle(ped, vehicle, -1)
    end

    pushToast('success', ('Spawned boat: %s'):format(label or modelName))
end

local function refreshObjectiveBlip()
    if objectiveBlip and DoesBlipExist(objectiveBlip) then
        RemoveBlip(objectiveBlip)
        objectiveBlip = nil
    end

    if not playerState or not Config.ObjectiveBlip.enabled then return end
    local objective = playerState.objective
    if not objective then return end

    local coords = nil
    local label = nil

    if playerState.routeTarget and playerState.zones and playerState.zones[playerState.routeTarget] then
        local zone = playerState.zones[playerState.routeTarget]
        coords = zone.coords
        label = zone.label
    elseif objective.zone and Config.Zones[objective.zone] then
        local zone = Config.Zones[objective.zone]
        coords = { x = zone.coords.x, y = zone.coords.y, z = zone.coords.z }
        label = zone.label
    elseif objective.coords then
        coords = objective.coords
        label = 'Longline Point'
    end

    if not coords then return end

    objectiveBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(objectiveBlip, Config.ObjectiveBlip.sprite)
    SetBlipColour(objectiveBlip, Config.ObjectiveBlip.colour)
    SetBlipScale(objectiveBlip, Config.ObjectiveBlip.scale)
    SetBlipAsShortRange(objectiveBlip, false)

    local routeOn = Config.ObjectiveBlip.routeEnabled and playerState.preferences and playerState.preferences.waypoint
    SetBlipRoute(objectiveBlip, routeOn and true or false)

    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName((Config.ObjectiveBlip.labelPrefix or 'Sea: ') .. (label or 'Objective'))
    EndTextCommandSetBlipName(objectiveBlip)
end

local function clearLonglineBlips()
    for key, blip in pairs(longlineBlips) do
        if blip and DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
        longlineBlips[key] = nil
    end
end

local function refreshLonglineBlips()
    local run = playerState and playerState.activeRun
    if not run or type(run.lines) ~= 'table' then
        clearLonglineBlips()
        return
    end

    local valid = {}
    local nowTs = getUnixNow()
    local cfg = Config.LonglineBlip or {}
    local sprite = tonumber(cfg.sprite) or 317
    local scale = tonumber(cfg.scale) or 0.72
    local colorWaiting = tonumber(cfg.waitingColour) or 5
    local colorReady = tonumber(cfg.readyColour) or 2

    for i = 1, #run.lines do
        local line = run.lines[i]
        if line and line.deployed and not line.reeled and line.x and line.y and line.z then
            valid[i] = true
            local blip = longlineBlips[i]
            if not blip or not DoesBlipExist(blip) then
                blip = AddBlipForCoord(line.x, line.y, line.z)
                longlineBlips[i] = blip
            else
                SetBlipCoords(blip, line.x, line.y, line.z)
            end

            local readyIn = math.max(0, (tonumber(line.readyAt) or 0) - nowTs)
            local ready = readyIn <= 0

            SetBlipSprite(blip, sprite)
            SetBlipScale(blip, scale)
            SetBlipColour(blip, ready and colorReady or colorWaiting)
            SetBlipAsShortRange(blip, false)
            ShowNumberOnBlip(blip, i)

            local label = ready and ('Longline #%d (Ready)'):format(i) or ('Longline #%d (%ds)'):format(i, readyIn)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(label)
            EndTextCommandSetBlipName(blip)
        end
    end

    for key, blip in pairs(longlineBlips) do
        if not valid[key] then
            if blip and DoesBlipExist(blip) then
                RemoveBlip(blip)
            end
            longlineBlips[key] = nil
        end
    end
end

local function clearStagePoiBlips()
    for i = 1, #stagePoiBlips do
        local blip = stagePoiBlips[i]
        if blip and DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
    stagePoiBlips = {}
end

local function buildStagePoiBlips()
    clearStagePoiBlips()
    local cfg = Config.StagePoiBlips
    if not cfg or not cfg.enabled or type(cfg.points) ~= 'table' then
        return
    end

    for i = 1, #cfg.points do
        local point = cfg.points[i]
        if point and point.coords then
            local blip = AddBlipForCoord(point.coords.x, point.coords.y, point.coords.z)
            SetBlipSprite(blip, tonumber(point.sprite) or 1)
            SetBlipColour(blip, tonumber(point.colour) or 0)
            SetBlipScale(blip, tonumber(point.scale) or 0.8)
            SetBlipDisplay(blip, 4)
            SetBlipAsShortRange(blip, cfg.shortRange and true or false)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(tostring(point.label or ('Sea Stage: ' .. tostring(point.stage or 'point'))))
            EndTextCommandSetBlipName(blip)
            stagePoiBlips[#stagePoiBlips + 1] = blip
        end
    end
end

local function stopCurrentAction(showToast)
    if actionBusy then
        actionCancelled = true
        local ped = PlayerPedId()
        if not IsPedInAnyVehicle(ped, false) then
            ClearPedTasks(ped)
        end
        if showToast then pushToast('warn', 'Stopped current action.') end
    elseif showToast then
        pushToast('info', 'No action is running right now.')
    end
end

local function suppressVehicleActionControls()
    DisableControlAction(0, 59, true) -- INPUT_VEH_MOVE_LR
    DisableControlAction(0, 60, true) -- INPUT_VEH_MOVE_UD
    DisableControlAction(0, 61, true) -- INPUT_VEH_MOVE_UP_ONLY
    DisableControlAction(0, 62, true) -- INPUT_VEH_MOVE_DOWN_ONLY
    DisableControlAction(0, 63, true) -- INPUT_VEH_MOVE_LEFT_ONLY
    DisableControlAction(0, 64, true) -- INPUT_VEH_MOVE_RIGHT_ONLY
    DisableControlAction(0, 71, true) -- INPUT_VEH_ACCELERATE
    DisableControlAction(0, 72, true) -- INPUT_VEH_BRAKE
    DisableControlAction(0, 75, true) -- INPUT_VEH_EXIT
    DisableControlAction(0, 76, true) -- INPUT_VEH_HANDBRAKE
end

local function runProgressAction(durationMs, scenario, label, cb, opts)
    if actionBusy then
        pushToast('warn', 'Please finish the current action first.')
        return
    end

    actionBusy = true
    actionCancelled = false

    local ped = PlayerPedId()
    local actionVehicle = 0
    local inVehicleAction = IsPedInAnyVehicle(ped, false)
    if inVehicleAction then
        actionVehicle = GetVehiclePedIsIn(ped, false)
    end

    local useScenario = (not inVehicleAction) and scenario and scenario ~= ''
    if useScenario then
        TaskStartScenarioInPlace(ped, scenario, 0, true)
    end

    local startTick = GetGameTimer()
    local duration = math.max(300, tonumber(durationMs) or 2000)

    while true do
        Wait(0)
        if actionCancelled then break end

        if inVehicleAction and actionVehicle > 0 and DoesEntityExist(actionVehicle) then
            suppressVehicleActionControls()
            SetVehicleBrake(actionVehicle, true)
            SetVehicleHandbrake(actionVehicle, true)
        end

        local elapsed = GetGameTimer() - startTick
        local pct = math.floor((elapsed / duration) * 100)
        if pct > 100 then pct = 100 end
        local liveLabel = label or 'Working...'
        if opts and opts.mode == 'reel' then
            local hint = tonumber(opts.reelHint or 1) or 1
            local pred = Config.CatchVisuals and Config.CatchVisuals.reelPrediction or {}
            if hint <= 1 then liveLabel = (label or 'Reeling catch...') .. ' - ' .. (pred.low or 'Light pull...')
            elseif hint == 2 then liveLabel = (label or 'Reeling catch...') .. ' - ' .. (pred.medium or 'Steady pull...')
            elseif hint == 3 then liveLabel = (label or 'Reeling catch...') .. ' - ' .. (pred.high or 'Heavy pull!')
            else liveLabel = (label or 'Reeling catch...') .. ' - ' .. (pred.extreme or 'Extreme pull!') end

            if pred.enableCameraShake and hint >= 3 then
                ShakeGameplayCam('SMALL_EXPLOSION_SHAKE', hint == 4 and 0.18 or 0.10)
            end
        end
        SendNUIMessage({ action = 'progress', show = true, label = liveLabel, percent = pct })
        if elapsed >= duration then break end
    end

    if useScenario then
        ClearPedTasks(ped)
    end
    if inVehicleAction and actionVehicle > 0 and DoesEntityExist(actionVehicle) then
        SetVehicleHandbrake(actionVehicle, false)
        SetVehicleBrake(actionVehicle, false)
    end
    SendNUIMessage({ action = 'progress', show = false })

    local cancelled = actionCancelled
    actionBusy = false
    actionCancelled = false

    if cancelled then
        pushToast('warn', 'Action canceled.')
        return
    end

    if cb then cb() end
end

local function runClassicInteract(zoneKey)
    if actionBusy then
        pushToast('warn', 'Please wait for the current action.')
        return
    end

    if not playerState or not playerState.seaEnabled then
        TriggerServerEvent('kid_sea:classicInteract', { zone = zoneKey })
        return
    end

    if playerState.stage == 'go_harbor' and zoneKey == 'harbor' then
        CreateThread(function()
            runProgressAction(Config.Actions.startDurationMs, Config.Actions.startScenario, 'Preparing harbor departure...', function()
                TriggerServerEvent('kid_sea:classicInteract', { zone = zoneKey })
            end)
        end)
        return
    end

    if playerState.stage == 'board_boat' and zoneKey == 'harbor' then
        CreateThread(function()
            runProgressAction(Config.Actions.startDurationMs, Config.Actions.startScenario, 'Starting sea run...', function()
                TriggerServerEvent('kid_sea:startRun')
            end)
        end)
        return
    end

    if playerState.stage == 'return_sell' and zoneKey == 'market' then
        CreateThread(function()
            runProgressAction(Config.Actions.sellDurationMs, Config.Actions.sellScenario, 'Selling fish...', function()
                TriggerServerEvent('kid_sea:sellCatch')
            end)
        end)
        return
    end

    TriggerServerEvent('kid_sea:classicInteract', { zone = zoneKey })
end

RegisterNetEvent('kid_sea:syncState', function(newState)
    playerState = newState
    SendNUIMessage({ action = 'sync', state = playerState })
    refreshObjectiveBlip()
    refreshLonglineBlips()
    syncCatchVisualsFromHold()
end)

RegisterNetEvent('kid_sea:status', function(newState)
    playerState = newState
    SendNUIMessage({ action = 'sync', state = playerState })
    refreshObjectiveBlip()
    refreshLonglineBlips()
    syncCatchVisualsFromHold()
end)

RegisterNetEvent('kid_sea:toast', function(payload)
    SendNUIMessage({ action = 'toast', toast = payload })
    if payload and payload.text then pushFeedText(payload.text) end
end)

RegisterNetEvent('kid_sea:runReceipt', function(receipt)
    SendNUIMessage({ action = 'receipt', receipt = receipt })
end)

RegisterNetEvent('kid_sea:levelUp', function(data)
    SendNUIMessage({ action = 'levelUp', data = data })
    if data and data.level then pushFeedText(('Sea level up! You are now level %d.'):format(data.level)) end
end)

RegisterNetEvent('kid_sea:addCatchVisual', function(payload)
    addCatchVisual(payload)
end)

RegisterNetEvent('kid_sea:clearCatchVisuals', function()
    clearCatchVisuals()
end)

RegisterNetEvent('kid_sea:lineReeled', function(payload)
    local idx = tonumber(payload and payload.lineIndex or nil)
    if not idx then return end

    local blip = longlineBlips[idx]
    if blip and DoesBlipExist(blip) then
        RemoveBlip(blip)
    end
    longlineBlips[idx] = nil

    local run = playerState and playerState.activeRun
    if run and type(run.lines) == 'table' and run.lines[idx] then
        run.lines[idx].reeled = true
        run.lines[idx].x = nil
        run.lines[idx].y = nil
        run.lines[idx].z = nil
    end

    refreshLonglineBlips()
end)

RegisterNetEvent('kid_sea:spawnBoat', function(payload)
    local p = type(payload) == 'table' and payload or {}
    local model = tostring(p.model or '')
    if model == '' then
        pushToast('warn', 'No boat model received from server.')
        return
    end
    local coords = p.coords and vec3(tonumber(p.coords.x) or 0.0, tonumber(p.coords.y) or 0.0, tonumber(p.coords.z) or 0.0) or vec3(0.0, 0.0, 0.0)
    spawnBoat(model, tostring(p.label or model), coords, tonumber(p.heading) or 0.0, p.placeInBoat and true or false)
end)

RegisterNUICallback('close', function(_, cb)
    closeTablet()
    cb({ ok = true })
end)

RegisterNUICallback('requestSync', function(_, cb)
    TriggerServerEvent('kid_sea:requestSync')
    cb({ ok = true })
end)

RegisterNUICallback('setWaypoint', function(data, cb)
    TriggerServerEvent('kid_sea:setWaypoint', data and data.enabled and true or false)
    cb({ ok = true })
end)

RegisterNUICallback('startRun', function(_, cb)
    cb({ ok = true })
    if not isNearZone('harbor') then
        pushToast('warn', 'Move to Harbor Dock first.')
        return
    end
    if playerState and playerState.stage == 'go_harbor' then
        pushToast('warn', 'Press E at Harbor first to prepare the run, then board your boat.')
        return
    end
    if playerState and playerState.stage ~= 'board_boat' then
        local objectiveText = playerState.objective and playerState.objective.text or 'You cannot start a run right now.'
        pushToast('warn', objectiveText)
        return
    end
    CreateThread(function()
        runProgressAction(Config.Actions.startDurationMs, Config.Actions.startScenario, 'Starting sea run...', function()
            TriggerServerEvent('kid_sea:startRun')
        end)
    end)
end)

local function runDeployLonglineAction()
    if actionBusy then
        pushToast('warn', 'Please finish the current action first.')
        return
    end

    if not playerState or playerState.stage ~= 'deploy_line' then
        local objectiveText = playerState and playerState.objective and playerState.objective.text or 'You cannot deploy a longline right now.'
        pushToast('warn', objectiveText)
        return
    end

    local ped = PlayerPedId()
    if not isSeaDeployContext(ped) then
        pushToast('warn', 'Be in sea water or on/in your fishing boat to place longline.')
        return
    end

    CreateThread(function()
        runProgressAction(Config.Actions.deployDurationMs, Config.Actions.deployScenario, 'Deploying longline...', function()
            TriggerServerEvent('kid_sea:deployLine')
        end)
    end)
end

RegisterNUICallback('deployLine', function(_, cb)
    cb({ ok = true })
    runDeployLonglineAction()
end)

local function runReelLonglineAction()
    if actionBusy then
        pushToast('warn', 'Please finish the current action first.')
        return
    end

    if not playerState or (playerState.stage ~= 'reel_line' and playerState.stage ~= 'wait_reel') then
        local objectiveText = playerState and playerState.objective and playerState.objective.text or 'You cannot reel a longline right now.'
        pushToast('warn', objectiveText)
        return
    end

    local line, lineIndex = getCurrentLine()
    if not line then
        pushToast('warn', 'No pending longline found.')
        return
    end

    local readyIn = math.max(0, (tonumber(line.readyAt) or 0) - getUnixNow())
    if readyIn > 0 then
        pushToast('info', ('This longline is still soaking. Ready in %ds.'):format(readyIn))
        return
    end

    local near, dist = isNearCurrentLine('reel')
    if not near then
        pushToast('warn', ('Move closer to longline (%.1fm).'):format(dist))
        return
    end

    CreateThread(function()
        local targetLine, targetLineIndex = getCurrentLine()
        runProgressAction(Config.Actions.reelDurationMs, Config.Actions.reelScenario, 'Reeling catch...', function()
            TriggerServerEvent('kid_sea:reelLine', { lineIndex = targetLineIndex or lineIndex })
        end, { mode = 'reel', reelHint = targetLine and targetLine.reelHint or 1 })
    end)
end

RegisterNUICallback('reelLine', function(_, cb)
    cb({ ok = true })
    runReelLonglineAction()
end)

RegisterNUICallback('sellCatch', function(_, cb)
    cb({ ok = true })
    if not isNearZone('market') then
        pushToast('warn', 'Move to Fish Market first.')
        return
    end
    CreateThread(function()
        runProgressAction(Config.Actions.sellDurationMs, Config.Actions.sellScenario, 'Selling fish...', function()
            TriggerServerEvent('kid_sea:sellCatch')
        end)
    end)
end)

RegisterNUICallback('selectBoat', function(data, cb)
    cb({ ok = true })
    TriggerServerEvent('kid_sea:selectBoat', {
        level = tonumber(data and data.level or nil),
        model = tostring(data and data.model or '')
    })
end)

RegisterNUICallback('spawnBoat', function(_, cb)
    cb({ ok = true })
    TriggerServerEvent('kid_sea:requestSpawnBoat')
end)

RegisterCommand(Config.Ui.command, function()
    if tabletOpen then
        closeTablet()
    else
        openTablet('run')
        TriggerServerEvent('kid_sea:requestSync')
    end
end, false)

RegisterKeyMapping(Config.Ui.command, 'Open Sea Tablet', 'keyboard', Config.Ui.keybind)
RegisterCommand('seasync', function()
    TriggerServerEvent('kid_sea:requestSync')
end, false)
RegisterCommand('seastopanim', function()
    stopCurrentAction(true)
end, false)

local function teleportToSeaZone(zoneKey)
    local zone = Config.Zones and Config.Zones[zoneKey] or nil
    if not zone then
        pushFeedText('Unknown sea zone.')
        return
    end

    local ped = PlayerPedId()
    if ped <= 0 then return end

    local targetZ = (zone.coords.z or 0.0) + 1.0
    SetEntityCoordsNoOffset(ped, zone.coords.x, zone.coords.y, targetZ, false, false, false)
    SetEntityHeading(ped, 0.0)
    pushFeedText(('Teleported to %s.'):format(zone.label or zoneKey))
end

if not Config.Commands or Config.Commands.seatp ~= false then
    RegisterCommand('seatp', function(_, args)
        local destination = tostring(args and args[1] or 'harbor'):lower()
        if destination == 'harbor' or destination == 'dock' then
            teleportToSeaZone('harbor')
            return
        end
        if destination == 'market' or destination == 'sell' then
            teleportToSeaZone('market')
            return
        end
        pushFeedText('Usage: /seatp harbor|market')
    end, false)

    RegisterCommand('seaharbor', function()
        teleportToSeaZone('harbor')
    end, false)
end

if not Config.Commands or Config.Commands.putlongline ~= false then
    RegisterCommand('putlongline', function()
        runDeployLonglineAction()
    end, false)
end
if not Config.Commands or Config.Commands.reellongline ~= false then
    RegisterCommand('reellongline', function()
        runReelLonglineAction()
    end, false)
end

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local nearestKey, nearestDist = nil, math.huge
        local drawZones = {}

        for zoneKey, zone in pairs(Config.Zones) do
            local dx, dy, dz = pos.x - zone.coords.x, pos.y - zone.coords.y, pos.z - zone.coords.z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dist < nearestDist then
                nearestDist = dist
                nearestKey = zoneKey
            end
            if dist <= (Config.Interaction.drawDistance or 65.0) then
                drawZones[#drawZones + 1] = { key = zoneKey, zone = zone, distance = dist }
            end
        end

        local line, lineIndex = getCurrentLine()
        local canDeploy = playerState and playerState.stage == 'deploy_line'
        local deployContextActive = canDeploy and isSeaDeployContext(ped)
        local canReel = playerState and (playerState.stage == 'reel_line' or playerState.stage == 'wait_reel')
        local lineDist = math.huge
        if canReel and line then
            local dx, dy, dz = pos.x - line.x, pos.y - line.y, pos.z - line.z
            lineDist = math.sqrt(dx * dx + dy * dy + dz * dz)
        end

        local sleep = 1200
        local nearest = nearestDist
        if canReel and lineDist < nearest then nearest = lineDist end
        if nearest <= 100.0 then sleep = 300 end
        if nearest <= 35.0 then sleep = 0 end

        if sleep == 0 then
            if Config.Guidance.showMarkers then
                for _, row in ipairs(drawZones) do
                    local z = row.zone
                    local c = z.markerColor or Config.Interaction.markerColor
                    DrawMarker(
                        Config.Interaction.markerType,
                        z.coords.x, z.coords.y, z.coords.z - 1.0,
                        0.0, 0.0, 0.0,
                        0.0, 0.0, 0.0,
                        Config.Interaction.markerScale.x,
                        Config.Interaction.markerScale.y,
                        Config.Interaction.markerScale.z,
                        c.r, c.g, c.b, c.a,
                        false, true, 2, false, nil, nil, false
                    )
                end
            end

            if canReel and line then
                DrawMarker(1, line.x, line.y, line.z - 1.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 3.0, 3.0, 0.55, 90, 200, 255, 200, false, true, 2, false, nil, nil, false)
                if Config.Guidance.show3DText and lineDist <= 35.0 then
                    local run = playerState and playerState.activeRun or nil
                    local total = run and run.totalLines or 1
                    local readyIn = math.max(0, (tonumber(line.readyAt) or 0) - getUnixNow())
                    local text
                    if readyIn > 0 then
                        text = ('Longline %d/%d - ready in %ds'):format(lineIndex or 1, total, readyIn)
                    else
                        text = ('Longline %d/%d - Press E to reel'):format(lineIndex or 1, total)
                    end
                    drawText3D(vec3(line.x, line.y, line.z + 0.6), text)
                end
            end

            if Config.Guidance.show3DText then
                for _, row in ipairs(drawZones) do
                    if row.distance <= (row.zone.radius + 8.0) then
                        drawText3D(vec3(row.zone.coords.x, row.zone.coords.y, row.zone.coords.z + 1.1), row.zone.label)
                    end
                end
            end
        end

        local interactPressed = IsControlJustReleased(0, Config.ClassicMode.interactKey or Config.Interaction.keyCode)
        local handledInteract = false
        local insideZone = nil
        if nearestKey then
            local zone = Config.Zones[nearestKey]
            if nearestDist <= zone.radius then insideZone = nearestKey end
            if nearestDist <= (zone.radius + 1.0) then
                if Config.Guidance.showHelpPrompt then
                    drawHelpText(promptForZone(nearestKey))
                end
            end
        end

        if canDeploy then
            local deployInfo = getDeployProgressInfo(ped)
            if Config.Guidance.showHelpPrompt then
                drawHelpText(buildDeployGuideText(deployInfo, deployContextActive))
            end
            if (not actionBusy) and deployContextActive and interactPressed then
                runDeployLonglineAction()
                handledInteract = true
            end
        elseif canReel and line then
            local reelInfo = getReelGuideInfo()
            if Config.Guidance.showHelpPrompt then
                drawHelpText(buildReelGuideText(reelInfo))
            end
            if lineDist <= 15.0 and interactPressed and not actionBusy then
                runReelLonglineAction()
                handledInteract = true
            end
        end

        if not handledInteract and interactPressed and nearestKey and nearestDist <= (Config.Zones[nearestKey].radius + 1.0) then
            if not deployContextActive then
                if Config.ClassicMode.enabled then
                    runClassicInteract(nearestKey)
                else
                    openTablet('run')
                    TriggerServerEvent('kid_sea:requestSync')
                end
            end
        end

        if insideZone ~= currentInsideZone then
            currentInsideZone = insideZone
            if currentInsideZone then
                TriggerServerEvent('kid_sea:arrivedZone', currentInsideZone)
            end
        end

        Wait(sleep)
    end
end)

CreateThread(function()
    while true do
        if Config.Guidance.showObjectiveHint and Config.Guidance.objectiveHintMode == 'corner' and playerState and playerState.objective and playerState.objective.text then
            drawCornerObjective(playerState.objective.text)
            Wait(0)
        else
            Wait(350)
        end
    end
end)

CreateThread(function()
    while true do
        Wait(1000)
        if Config.Guidance.showObjectiveHint and Config.Guidance.objectiveHintMode ~= 'corner' and playerState and playerState.objective and playerState.objective.text then
            local intervalMs = (Config.Guidance.objectiveHintIntervalSeconds or 20) * 1000
            local tick = GetGameTimer()
            if tick - lastHintTick >= intervalMs then
                lastHintTick = tick
                local text = ('Objective: %s'):format(playerState.objective.text)
                if Config.Guidance.objectiveHintMode == 'subtitle' then showSubtitle(text)
                elseif Config.Guidance.objectiveHintMode == 'chat' then chatHint(text) end
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(1000)
        refreshLonglineBlips()
        syncCatchVisualsFromHold()
    end
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    buildStagePoiBlips()
    Wait(1200)
    TriggerServerEvent('kid_sea:requestSync')
end)

AddEventHandler('playerSpawned', function()
    Wait(800)
    TriggerServerEvent('kid_sea:requestSync')
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if objectiveBlip and DoesBlipExist(objectiveBlip) then RemoveBlip(objectiveBlip) end
    clearStagePoiBlips()
    clearLonglineBlips()
    clearCatchVisuals()
end)







