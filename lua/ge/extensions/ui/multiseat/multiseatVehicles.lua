-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local playerLimits = require("ge/extensions/core/multiseatPlayerLimits")
local multiseatConfiguration = require("ge/extensions/ui/multiseat/multiseatConfiguration")
local digestButtonInstance = require("ge/extensions/ui/gridSelectorUtils/buttonModule").create()

M.dependencies = {
  "core_locales",
  "core_playerPersonas",
  "core_vehicle_configTarget",
  "ui_gridSelectorRouteLifecycleCallbacks",
  "ui_vehicleSelector_general",
}

local SETTINGS_ROUTE = "pause.multiseatSettings"
local VEHICLE_SELECTOR_ROUTE = "pause.multiseatSettings.vehicleSelector"
local QUICK_VEHICLE_SELECTOR_ROUTE = "pause.multiseatVehicleSelector"

local fallbackVehicles = {
  {model = "covet", config = "vehicles/covet/DXi_A.pc"},
  {model = "pessima", config = "vehicles/pessima/DX_A.pc"},
  {model = "pickup", config = "vehicles/pickup/d15_4wd_A.pc"},
  {model = "roamer", config = "vehicles/roamer/4wd_facelift.pc"},
  {model = "vivace", config = "vehicles/vivace/vivace_110_M.pc"},
}

local function getValidSuggestedVehicles(vehicles)
  local valid = {}
  if type(vehicles) ~= "table" then return valid end
  for _, vehicle in ipairs(vehicles) do
    if type(vehicle) == "table"
      and type(vehicle.model) == "string"
      and type(vehicle.config) == "string"
      and FS:fileExists("/" .. vehicle.config) then
      valid[#valid + 1] = vehicle
    else
      log("W", "multiseatVehicles", "Ignoring invalid multiseat vehicle config: " .. tostring(vehicle and vehicle.config))
    end
  end
  return valid
end

local function selectSuggestedVehicles(pool, playerCount)
  if #pool == 0 then pool = getValidSuggestedVehicles(fallbackVehicles) end
  if #pool == 0 then return {} end
  arrayShuffle(pool)

  local vehicles = {}
  local poolIndex = 1
  for index = 1, playerCount do
    vehicles[index] = pool[poolIndex]
    poolIndex = poolIndex % #pool + 1
  end
  return vehicles
end

function M.getSuggestedVehiclesForLevel(levelName, playerCount)
  playerCount = tonumber(playerCount) or 0
  if playerCount < 1 then return {} end

  local level = levelName and core_levels.getLevelByName(levelName) or nil
  local pool = getValidSuggestedVehicles(level and level.multiseat and level.multiseat.suggestedVehicles)
  return selectSuggestedVehicles(pool, playerCount)
end

function M.getSuggestedVehicles(levelName, playerCount)
  playerCount = tonumber(playerCount) or 0
  if playerCount < 1 then return {} end

  if mainLevel and type(mainLevel.getMultiseatSuggestedVehicles) == "function" then
    local ok, vehicles = pcall(mainLevel.getMultiseatSuggestedVehicles, playerCount)
    local valid = ok and type(vehicles) == "table" and getValidSuggestedVehicles(vehicles) or {}
    if #valid >= playerCount then return valid end
    log("W", "multiseatVehicles", "Level multiseat vehicle function did not return one valid vehicle per player")
  end

  local gamemodePool = gameplay_multiseat_gamemodeManager
    and gameplay_multiseat_gamemodeManager.getVehiclePool
    and gameplay_multiseat_gamemodeManager.getVehiclePool()
  local pool = getValidSuggestedVehicles(gamemodePool)
  if #pool > 0 then
    return selectSuggestedVehicles(pool, playerCount)
  end
  return M.getSuggestedVehiclesForLevel(levelName, playerCount)
end

local ownedByPersona = {}
local sessionByPersona = {}
local activeByPlayer = {}
local stagedByPlayer = {}
local initialStagedByPlayer = {}
local digestActionButtonsByPersona = {}
local pendingPlayer = nil
local pendingAllPlayers = false
local pendingQuickPlayer = nil
local pendingWaitingCallback = nil
local snapshotsInitialized = false
local buildingSnapshots = false
local applyingStagedChanges = false
local lastConfigurationRevision = -1
local preparedCommit = nil
local preserveVehiclesOnUnload = false
local reloadRestorePending = false
local reloadPreferencesByPersona = nil
local customSplitPlayers = nil
local stagedAutomaticColor = nil

local function valuesEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do
    if not valuesEqual(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

local function getAutomaticColorSetting()
  return settings.getValue("multiseatAutomaticColor", multiseatConfiguration.AUTOMATIC_COLOR_DEFAULT) == true
end

function M.getAutomaticColorEnabled()
  return stagedAutomaticColor == nil and getAutomaticColorSetting() or stagedAutomaticColor
end

local function getConfigKey(config)
  if type(config) ~= "string" then return nil end
  return config:match("([^/\\]+)%.pc$") or config
end

local function trackRecentVehicle(model, config)
  if model and config then
    ui_vehicleSelector_general.trackRecentVehicle(model, getConfigKey(config))
  end
end

local CLOSEST_PAINT_OPTIONS = 3
local PRIMARY_PAINT_WEIGHT = 3
local MAX_PERSONA_PAINT_DISTANCE_SQUARED = 0.2 * 0.2
local DARKER_PAINT_BRIGHTNESS_OFFSET = 0.35
local LIGHTER_PAINT_BRIGHTNESS_OFFSET = 0.2
local LIGHTER_PAINT_SATURATION_FACTOR = 0.8

local function paintDistanceSquared(paint, color)
  local baseColor = paint and paint.baseColor
  if type(baseColor) ~= "table" or type(color) ~= "table" then return math.huge end
  local red = baseColor[1] - color[1]
  local green = baseColor[2] - color[2]
  local blue = baseColor[3] - color[3]
  return red * red + green * green + blue * blue
end

local function colorHue(color)
  if type(color) ~= "table" then return nil end
  local red, green, blue = color[1], color[2], color[3]
  if type(red) ~= "number" or type(green) ~= "number" or type(blue) ~= "number" then return nil end
  local maximum = math.max(red, green, blue)
  local minimum = math.min(red, green, blue)
  local range = maximum - minimum
  if range == 0 then return nil end

  local hue
  if maximum == red then
    hue = ((green - blue) / range) % 6
  elseif maximum == green then
    hue = (blue - red) / range + 2
  else
    hue = (red - green) / range + 4
  end
  return hue / 6
end

local function hueDistance(first, second)
  local firstHue = colorHue(first)
  local secondHue = colorHue(second)
  if firstHue == nil or secondHue == nil then return math.huge end
  local distance = math.abs(firstHue - secondHue)
  return math.min(distance, 1 - distance)
end

-- the pick has to stay stable for a persona/vehicle pair, otherwise the color shown in the settings
-- screen would not be the one the vehicle spawns with
local function stablePick(seed, count)
  if count <= 1 then return 1 end
  local hash = 0
  for index = 1, #seed do
    hash = (hash * 31 + seed:byte(index)) % 1000003
  end
  return hash % count + 1
end

local function getModelPaints(modelKey)
  local modelData = core_vehicles.getModel(modelKey)
  local model = modelData and modelData.model
  if not model or type(model.paints) ~= "table" then return nil end
  return model, model.paints
end

local function makePaintSet(paint1, paint2, paint3)
  if not paint1 then return nil end
  return {
    paint = deepcopy(paint1),
    paint2 = deepcopy(paint2 or paint1),
    paint3 = deepcopy(paint3 or paint1),
  }
end

local function makeSinglePaintSet(paint)
  if not paint then return nil end
  local darker = deepcopy(paint)
  local lighter = deepcopy(paint)
  local baseColor = paint.baseColor
  if type(baseColor) ~= "table" then return makePaintSet(paint) end

  local hue, saturation, brightness = RGBtoHSV(baseColor[1], baseColor[2], baseColor[3])
  darker.baseColor[1], darker.baseColor[2], darker.baseColor[3] =
    HSVtoRGB(hue, saturation, math.max(0, brightness - DARKER_PAINT_BRIGHTNESS_OFFSET))
  lighter.baseColor[1], lighter.baseColor[2], lighter.baseColor[3] =
    HSVtoRGB(
      hue,
      saturation * LIGHTER_PAINT_SATURATION_FACTOR,
      math.min(1, brightness + LIGHTER_PAINT_BRIGHTNESS_OFFSET)
    )
  return makePaintSet(paint, lighter, darker)
end

-- the factory color combos a vehicle ships with, config ones win over the model wide ones
local function getPaintSetups(modelKey, configKey)
  local config = core_vehicles.getConfig(modelKey, configKey)
  local setups = config and config.multiPaintSetups
  if type(setups) == "table" and #setups > 0 then return setups end
  local model = getModelPaints(modelKey)
  setups = model and model.multiPaintSetups
  if type(setups) == "table" and #setups > 0 then return setups end
  return nil
end

local function getPersonaPaints(modelKey, configKey, personaColor, seed)
  local model, modelPaints = getModelPaints(modelKey)
  if not model then return nil end

  local candidates = {}
  local function addCandidate(paint1, paint2, paint3)
    if not paint1 then return end
    if not paint2 and not paint3 then
      local paints = makeSinglePaintSet(paint1)
      paint2, paint3 = paints.paint2, paints.paint3
    else
      paint2 = paint2 or paint1
      paint3 = paint3 or paint1
    end
    local primaryDistance = paintDistanceSquared(paint1, personaColor)
    if primaryDistance > MAX_PERSONA_PAINT_DISTANCE_SQUARED then return end
    candidates[#candidates + 1] = {
      paint = paint1,
      paint2 = paint2,
      paint3 = paint3,
      distance = PRIMARY_PAINT_WEIGHT * primaryDistance
        + paintDistanceSquared(paint2, personaColor)
        + paintDistanceSquared(paint3, personaColor),
    }
  end

  for _, setup in ipairs(getPaintSetups(modelKey, configKey) or {}) do
    addCandidate(
      modelPaints[setup.paintName1],
      modelPaints[setup.paintName2],
      modelPaints[setup.paintName3]
    )
  end
  for _, paint in pairs(modelPaints) do
    addCandidate(paint)
  end

  if #candidates == 0 then return nil end
  table.sort(candidates, function(a, b) return a.distance < b.distance end)
  local picked = candidates[stablePick(seed or "", math.min(CLOSEST_PAINT_OPTIONS, #candidates))]
  return makePaintSet(picked.paint, picked.paint2, picked.paint3)
end

local function getConfigPaints(modelKey, configKey)
  local model, modelPaints = getModelPaints(modelKey)
  if not model then return nil end
  local config = core_vehicles.getConfig(modelKey, configKey) or {}
  return makePaintSet(
    modelPaints[config.defaultPaintName1 or model.defaultPaintName1],
    modelPaints[config.defaultPaintName2 or model.defaultPaintName2],
    modelPaints[config.defaultPaintName3 or model.defaultPaintName3]
  )
end

local function getNamedPaints(modelKey, paintNames)
  if type(paintNames) ~= "table" then return nil end
  local model, modelPaints = getModelPaints(modelKey)
  if not model then return nil end
  return makePaintSet(
    modelPaints[paintNames.paint],
    modelPaints[paintNames.paint2],
    modelPaints[paintNames.paint3]
  )
end

local function getClosestHueFactoryPaints(modelKey, configKey, personaColor)
  local model, modelPaints = getModelPaints(modelKey)
  if not model then return nil end

  local candidates = {}
  for _, setup in ipairs(getPaintSetups(modelKey, configKey) or {}) do
    if modelPaints[setup.paintName1] then
      candidates[#candidates + 1] = {setup.paintName1, setup.paintName2, setup.paintName3}
    end
  end
  -- the paint libraries are marked custom, only the stock colors of the vehicle are wanted here
  for name, paint in pairs(modelPaints) do
    if paint.class ~= "custom" then candidates[#candidates + 1] = {name} end
  end
  if #candidates == 0 then return nil end

  local picked
  local closestHueDistance = math.huge
  local closestColorDistance = math.huge
  for _, candidate in ipairs(candidates) do
    local paint = modelPaints[candidate[1]]
    local candidateHueDistance = hueDistance(paint and paint.baseColor, personaColor)
    local candidateColorDistance = paintDistanceSquared(paint, personaColor)
    if candidateHueDistance < closestHueDistance
      or candidateHueDistance == closestHueDistance and candidateColorDistance < closestColorDistance then
      picked = candidate
      closestHueDistance = candidateHueDistance
      closestColorDistance = candidateColorDistance
    end
  end
  if not picked then return nil end
  return makePaintSet(modelPaints[picked[1]], modelPaints[picked[2]], modelPaints[picked[3]])
end

-- automatic colors are picked close to the persona color, manual ones use the selector pick or a factory color
local function resolveVehiclePaints(vehicle, personaId, personaColor, fallbackPaint)
  if type(vehicle) ~= "table" or not vehicle.model then return nil end
  local configKey = getConfigKey(vehicle.config)
  local automaticColor = vehicle.automaticColor
  if automaticColor == nil then automaticColor = getAutomaticColorSetting() end
  if not automaticColor then
    return getNamedPaints(vehicle.model, vehicle.paintNames)
      or getClosestHueFactoryPaints(vehicle.model, configKey, personaColor)
      or getConfigPaints(vehicle.model, configKey)
  end
  local seed = table.concat({tostring(personaId), tostring(vehicle.model), tostring(configKey)}, "|")
  return getPersonaPaints(vehicle.model, configKey, personaColor, seed)
    or makeSinglePaintSet(fallbackPaint)
    or getConfigPaints(vehicle.model, configKey)
end

local function applyVehicleColor(vehicle, personaId, personaColor, fallbackPaint)
  if type(vehicle) ~= "table" then return vehicle end
  if vehicle.automaticColor == nil then
    vehicle.automaticColor = getAutomaticColorSetting()
  end
  local paints = resolveVehiclePaints(vehicle, personaId, personaColor, fallbackPaint)
  vehicle.paint = paints and paints.paint or nil
  vehicle.paint2 = paints and paints.paint2 or nil
  vehicle.paint3 = paints and paints.paint3 or nil
  return vehicle
end

local function getVehiclePaints(vehicle, personaId, personaColor, fallbackPaint)
  if type(vehicle) ~= "table" then return nil end
  if vehicle.paint then return makePaintSet(vehicle.paint, vehicle.paint2, vehicle.paint3) end
  return resolveVehiclePaints(vehicle, personaId, personaColor, fallbackPaint)
end

-- paint tiles only need the extra slots when the vehicle actually uses more than one color
local function getPaintTiles(vehicle)
  local paint = type(vehicle) == "table" and vehicle.paint or nil
  if not paint then return nil end
  local paint2 = vehicle.paint2 or paint
  local paint3 = vehicle.paint3 or paint
  if valuesEqual(paint2, paint) and valuesEqual(paint3, paint) then return {deepcopy(paint)} end
  return {deepcopy(paint), deepcopy(paint2), deepcopy(paint3)}
end

-- recoloring a vehicle that is already spawned avoids replacing it just for a color change
local function repaintVehicle(veh, paints)
  if not veh or not paints or not core_vehicle_manager then return end
  local vehId = veh:getId()
  core_vehicle_manager.liveUpdateVehicleColors(vehId, veh, 1, paints.paint)
  core_vehicle_manager.liveUpdateVehicleColors(vehId, veh, 2, paints.paint2)
  core_vehicle_manager.liveUpdateVehicleColors(vehId, veh, 3, paints.paint3)
end

local function getVehicleLabel(vehicle)
  if type(vehicle) ~= "table" then return "" end

  local modelData = core_vehicles.getModel(vehicle.model)
  local model = modelData and modelData.model or {}
  local config = core_vehicles.getConfig(vehicle.model, getConfigKey(vehicle.config)) or {}
  local modelLabel = table.concat({
    model.Brand or "",
    model.Name or vehicle.model or "",
  }, " "):gsub("^%s+", ""):gsub("%s+$", "")
  local configLabel = config.Configuration or config.Name
  if configLabel and configLabel ~= "" then
    return modelLabel .. " — " .. configLabel
  end
  return modelLabel
end

local function getJoinedParticipant(player)
  player = tonumber(player)
  for _, participant in ipairs(core_multiseat.getJoinedParticipants()) do
    if participant.assignment.playerIndex == player then return participant end
  end
end

local function getOwnedEntryForPlayer(player)
  player = tonumber(player)
  for _, entry in pairs(ownedByPersona) do
    if entry.player == player then return entry end
  end
end

local function getOwnedVehicle(entry)
  if not entry or not entry.vehId then return nil end
  local veh = scenetree.findObjectById(entry.vehId)
  entry.veh = veh
  return veh
end

local function getActiveVehicleIds()
  local vehicleIds = {}
  for _, veh in activeVehiclesIterator() do
    if not veh.isTraffic and not veh.isParked then
      vehicleIds[#vehicleIds + 1] = veh:getId()
    end
  end
  return vehicleIds
end

local function removeUnownedVehicles(vehicleIds)
  local ownedVehicleIds = {}
  for _, entry in pairs(ownedByPersona) do
    local veh = getOwnedVehicle(entry)
    if veh then ownedVehicleIds[veh:getId()] = true end
  end
  for _, vehicleId in ipairs(vehicleIds or {}) do
    local veh = scenetree.findObjectById(vehicleId)
    if veh and not ownedVehicleIds[vehicleId] then veh:delete() end
  end
end

local function getJoinedParticipantByPersonaId(personaId)
  for _, participant in ipairs(core_multiseat.getJoinedParticipants()) do
    if participant.persona.id == personaId then return participant end
  end
end

local function getVehicleSelection(veh)
  if not veh then return nil end
  return {
    model = veh.JBeam or veh.jbeam or veh:getField("JBeam", "0"),
    config = veh.partConfig or veh:getField("partConfig", "0"),
  }
end

local function vehicleSelectionsEqual(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return a.model == b.model and getConfigKey(a.config) == getConfigKey(b.config)
end

local function vehicleMatchesSelection(veh, selection)
  return vehicleSelectionsEqual(getVehicleSelection(veh), selection)
end

local function getDefaultVehicle(player, suggestedVehicle)
  if suggestedVehicle then return deepcopy(suggestedVehicle) end
  local index = (tonumber(player) or 0) % #fallbackVehicles + 1
  return deepcopy(fallbackVehicles[index])
end

local function getVehiclePreferences(persona)
  local gearbox = settings.getValue("defaultGearboxBehavior", "arcade", persona)
  if gearbox ~= "arcade" and gearbox ~= "realistic" then gearbox = "arcade" end
  local ignitionLevel = tonumber(settings.getValue("spawnVehicleIgnitionLevel", 3, persona)) or 3
  if ignitionLevel < 0 or ignitionLevel > 3 or ignitionLevel % 1 ~= 0 then ignitionLevel = 3 end
  return {
    gearbox = gearbox,
    clutchAssist = settings.getValue("autoClutch", true, persona) == true,
    throttleAssist = settings.getValue("autoThrottle", true, persona) == true,
    ignitionLevel = ignitionLevel,
  }
end

local function personaUpdateData(persona)
  return {
    id = persona.id,
    displayName = persona.displayName,
    icon = persona.icon,
    color = deepcopy(persona.color),
    vehicle = deepcopy(persona.vehicle),
  }
end

local function ensurePersonaDefaults()
  local participants = core_multiseat.getJoinedParticipants()
  local suggestedVehicles = M.getSuggestedVehicles(getCurrentLevelIdentifier(), #participants)
  for index, participant in ipairs(participants) do
    local persona = participant.persona
    if type(persona.vehicle) ~= "table" then
      local data = personaUpdateData(persona)
      data.vehicle = applyVehicleColor(
        getDefaultVehicle(participant.assignment.playerIndex, suggestedVehicles[index]),
        persona.id,
        persona.color,
        persona.vehicleFallbackPaint
      )
      core_multiseat.setPlayerPersona(participant.assignment.playerIndex, data)
    end
  end
end

local function stateFromPersona(player, persona, previous, suggestedVehicle, automaticColor)
  local vehicle = previous and previous.vehicle
    or persona.vehicle
    or sessionByPersona[persona.id] and sessionByPersona[persona.id].vehicle
    or getDefaultVehicle(player, suggestedVehicle)
  vehicle = deepcopy(vehicle)
  vehicle.automaticColor = automaticColor
  applyVehicleColor(vehicle, persona.id, persona.color, persona.vehicleFallbackPaint)
  local preferences = previous and previous.preferences
    or persona.preferences
    or getVehiclePreferences(persona)
  return {
    player = player,
    optedIn = true,
    personaId = persona.id,
    personaNumber = persona.number,
    label = persona.displayName,
    icon = persona.icon,
    color = persona.colorHex,
    personaColor = deepcopy(persona.color),
    vehicleFallbackPaint = deepcopy(persona.vehicleFallbackPaint),
    vehicle = vehicle,
    preferences = deepcopy(preferences),
  }
end

local function buildLiveStates()
  local states = {}
  if settings.getValue("multiseat") ~= true then return states end
  local participants = core_multiseat.getJoinedParticipants()
  local suggestedVehicles = M.getSuggestedVehicles(getCurrentLevelIdentifier(), #participants)
  local automaticColor = getAutomaticColorSetting()
  for index, participant in ipairs(participants) do
    local player = participant.assignment.playerIndex
    states[player] = stateFromPersona(player, participant.persona, nil, suggestedVehicles[index], automaticColor)
  end
  return states
end

local function buildStagedStates(previousByPersona)
  local preview = multiseatConfiguration.getPreview()
  local states = {}
  local suggestedVehicles = M.getSuggestedVehicles(getCurrentLevelIdentifier(), #preview.availablePersonas)
  for index, summary in ipairs(preview.availablePersonas) do
    local persona = multiseatConfiguration.getPersona(summary.number)
    local previous = previousByPersona and previousByPersona[summary.id]
    states[summary.player] = stateFromPersona(
      summary.player,
      persona,
      previous,
      suggestedVehicles[index],
      M.getAutomaticColorEnabled()
    )
  end
  return states, preview.revision
end

local function ensureSnapshots()
  if snapshotsInitialized or buildingSnapshots then return end
  buildingSnapshots = true
  multiseatConfiguration.begin({source = "settings"})
  stagedAutomaticColor = getAutomaticColorSetting()
  activeByPlayer = buildLiveStates()
  stagedByPlayer, lastConfigurationRevision = buildStagedStates()
  initialStagedByPlayer = deepcopy(stagedByPlayer)
  snapshotsInitialized = true
  buildingSnapshots = false
end

local function reconcileSnapshotsWithCurrentPlayers()
  if buildingSnapshots then return end
  buildingSnapshots = true
  local previousStagedByPersona = {}
  for _, state in pairs(stagedByPlayer) do previousStagedByPersona[state.personaId] = state end
  stagedByPlayer, lastConfigurationRevision = buildStagedStates(previousStagedByPersona)
  snapshotsInitialized = true
  buildingSnapshots = false
end

local function syncStagedRoster()
  ensureSnapshots()
  local preview = multiseatConfiguration.getPreview()
  if preview.revision ~= lastConfigurationRevision then reconcileSnapshotsWithCurrentPlayers() end
end

local function getSortedStates(states, optedInOnly)
  local result = {}
  for _, state in pairs(states) do
    if not optedInOnly or state.optedIn then result[#result + 1] = state end
  end
  table.sort(result, function(a, b) return a.player < b.player end)
  return result
end

local function removeOwnedEntry(entry)
  if not entry then return end
  local veh = getOwnedVehicle(entry)
  if veh then
    if be:getPlayerVehicleID(entry.player) == entry.vehId then
      be:exitVehicle(entry.player)
    end
    veh:delete()
  end
  entry.veh = nil
  entry.vehId = nil
  ownedByPersona[entry.personaId] = nil
end

local function applyPreferences(persona, preferences, veh)
  if not persona or type(preferences) ~= "table" then return end
  local gearbox = preferences.gearbox
  if gearbox ~= "arcade" and gearbox ~= "realistic" then gearbox = "arcade" end
  settings.setValue("autoClutch", preferences.clutchAssist == true, persona)
  settings.setValue("autoThrottle", preferences.throttleAssist == true, persona)
  settings.setValue("defaultGearboxBehavior", gearbox, persona)
  settings.setValue("spawnVehicleIgnitionLevel", preferences.ignitionLevel, persona)
  if veh then
    local personaChanged = core_vehicles
      and core_vehicles.setVehiclePersona
      and core_vehicles.setVehiclePersona(veh:getId(), persona)
    if not personaChanged then
      local personaId = type(persona) == "table" and persona.id or persona
      veh:queueLuaCommand("setPlayerPersona(" .. serialize(personaId) .. "); onSettingsChanged()")
    end
  end
end

local function copyPlayerList(players)
  if type(players) ~= "table" then return nil end
  local copy = {}
  for i, player in ipairs(players) do
    copy[i] = player
  end
  return copy
end

local function syncSplitScreenPlayers()
  if not render_splitScreen or not render_splitScreen.setCustomPlayers then return end
  if customSplitPlayers then
    render_splitScreen.setCustomPlayers(customSplitPlayers)
  else
    render_splitScreen.setCustomPlayers(core_multiseat.getJoinedPlayers())
  end
end

function M.setCustomSplitPlayers(players)
  customSplitPlayers = copyPlayerList(players)
  syncSplitScreenPlayers()
end

function M.clearCustomSplitPlayers()
  customSplitPlayers = nil
  if render_splitScreen and render_splitScreen.clearCustomPlayers then
    render_splitScreen.clearCustomPlayers()
  else
    syncSplitScreenPlayers()
  end
end

local function trackOwnedVehicle(player, personaId, veh)
  local entry = ownedByPersona[personaId] or {}
  entry.veh = veh
  entry.vehId = veh:getId()
  entry.player = player
  entry.personaId = personaId
  ownedByPersona[personaId] = entry
  return entry
end

local ROAD_SPAWN_SEARCH_RADIUS = 100
local ROAD_SPAWN_GAP = 10

-- behind the anchor vehicle; without one, starting at the level spawn point
local function getRoadSpawnTransforms(anchor, count)
  if count < 1 or not core_multiSpawn then return nil end
  local pos, dir, startIndex
  if anchor then
    pos = anchor:getPosition()
    dir = vec3(anchor:getDirectionVector())
    startIndex = 1
  else
    local spawnPoint = spawn.pickSpawnPoint("player")
    if not spawnPoint then return nil end
    pos = spawnPoint:getPosition()
    dir = vec3(0, 1, 0):rotated(quat(spawnPoint:getRotation()) * quat(0, 0, 1, 0))
    startIndex = 0
  end
  if not map.findClosestRoad(pos, ROAD_SPAWN_SEARCH_RADIUS) then return nil end
  return core_multiSpawn.createSpawnPositions(count, {
    mode = "roadBehind",
    gap = ROAD_SPAWN_GAP,
    pos = pos,
    dir = dir,
    startIndex = startIndex,
  })
end

local function getAdjacentSpawnTransform(anchor)
  if not anchor then
    local spawnPoint = spawn.pickSpawnPoint("player")
    if not spawnPoint then return nil, nil end
    return spawnPoint:getPosition(), quat(spawnPoint:getRotation()) * quat(0, 0, 1, 0)
  end
  local forward = vec3(anchor:getDirectionVector())
  local up = vec3(anchor:getDirectionVectorUp())
  local rot = quatFromDir(forward, up)
  local right = rot * vec3(1, 0, 0)
  local halfExtents = anchor:getSpawnWorldOOBB():getHalfExtents()
  local spacing = math.max(halfExtents.x * 2 + 2.5, 4)
  return anchor:getPosition() + right * spacing, rot
end

local function applySpawnPlanPosition(veh, entry, player)
  if not veh or type(entry) ~= "table" then return end

  local parkingSpot = entry.parkingSpot
  if parkingSpot then
    parkingSpot:moveResetVehicleTo(veh:getID(), nil, false, nil, nil, true)
    core_camera.resetCamera(player)
    return
  end

  if entry.pos and entry.rot then
    spawn.safeTeleport(veh, entry.pos, entry.rot, nil, nil, nil, true, true, player)
    core_camera.resetCamera(player)
  end
end

local function buildSpawnOptionsForParticipant(participant, vehicle, entry)
  local spawningOptions = sanitizeVehicleSpawnOptions(vehicle.model, {
    config = vehicle.config,
    additionalVehicleData = {playerIndex = participant.assignment.playerIndex},
  })
  local parkingSpot = entry.parkingSpot
  spawningOptions.pos = parkingSpot and parkingSpot.pos or entry.pos
  spawningOptions.rot = parkingSpot and parkingSpot.rot or entry.rot
  local paints = getVehiclePaints(
    vehicle,
    participant.persona.id,
    participant.persona.color,
    participant.persona.vehicleFallbackPaint
  )
  if paints then
    spawningOptions.paint = paints.paint
    spawningOptions.paint2 = paints.paint2
    spawningOptions.paint3 = paints.paint3
  end
  spawningOptions.autoEnterVehicle = false
  spawningOptions.canSpawnAnotherVehicleCheck = false
  return spawningOptions
end

local function assignPlayerToVehicle(player, veh)
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking(player) then
    gameplay_walk.setWalkingMode(false, nil, nil, true, player)
  end
  be:enterVehicle(player, veh)
  if gameplay_seatOccupants and gameplay_seatOccupants.setOccupied then
    gameplay_seatOccupants.setOccupied(veh:getId(), nil, player)
  end
end

local function spawnPlanVehicle(participant, entry)
  local vehicle = participant and participant.persona.vehicle
  if not participant or not vehicle then return nil end

  local spawningOptions = buildSpawnOptionsForParticipant(participant, vehicle, entry)
  local veh = core_vehicles.spawnNewVehicle(spawningOptions.model, spawningOptions)
  if not veh then return nil end

  applySpawnPlanPosition(veh, entry, entry.player)
  assignPlayerToVehicle(entry.player, veh)
  core_camera.resetCamera(entry.player)
  return trackOwnedVehicle(entry.player, participant.persona.id, veh)
end

local function reconcileSpawnPlanEntry(entry)
  local participant = getJoinedParticipant(entry.player)
  local selectedVehicle = participant and participant.persona.vehicle
  if not participant or not selectedVehicle then return nil, "player_unavailable" end

  local owned = getOwnedEntryForPlayer(entry.player)
  local veh = getOwnedVehicle(owned)
  if veh then
    if not vehicleMatchesSelection(veh, selectedVehicle) then
      local spawningOptions = buildSpawnOptionsForParticipant(participant, selectedVehicle, entry)
      veh = core_vehicles.replaceVehicle(spawningOptions.model, spawningOptions, veh)
      if not veh then return nil, "vehicle_replace_failed" end
    end
    applySpawnPlanPosition(veh, entry, entry.player)
    assignPlayerToVehicle(entry.player, veh)
    core_camera.resetCamera(entry.player)
    return trackOwnedVehicle(entry.player, participant.persona.id, veh)
  end

  local spawned = spawnPlanVehicle(participant, entry)
  if not spawned then return nil, "vehicle_spawn_failed" end
  return spawned
end

function M.getStagedChanges()
  syncStagedRoster()
  local rosterChanged = multiseatConfiguration.hasChanges()
  local changes = {
    dirty = rosterChanged,
    requiresRestart = rosterChanged,
    rosterChanged = rosterChanged,
    vehicleChanged = false,
    colorChanged = false,
    iconChanged = false,
    preferencesChanged = false,
  }

  local activeByPersona = {}
  local stagedByPersona = {}
  for _, state in pairs(activeByPlayer) do
    if state.optedIn then activeByPersona[state.personaId] = state end
  end
  for _, state in pairs(stagedByPlayer) do
    if state.optedIn then stagedByPersona[state.personaId] = state end
  end

  for personaId in pairs(activeByPersona) do
    if not stagedByPersona[personaId] then
      changes.dirty = true
      changes.requiresRestart = true
      changes.rosterChanged = true
    end
  end
  for personaId, staged in pairs(stagedByPersona) do
    local active = activeByPersona[personaId]
    if not active then
      changes.dirty = true
      changes.requiresRestart = true
      changes.rosterChanged = true
    else
      -- a color change is applied to the running vehicle, only a different model/config needs a respawn
      if not vehicleSelectionsEqual(active.vehicle, staged.vehicle) then
        changes.dirty = true
        changes.requiresRestart = true
        changes.vehicleChanged = true
      elseif not valuesEqual(active.vehicle, staged.vehicle) then
        changes.dirty = true
        changes.colorChanged = true
      end
      if active.icon ~= staged.icon then
        changes.dirty = true
        changes.iconChanged = true
      end
      if not valuesEqual(active.preferences, staged.preferences) then
        changes.dirty = true
        changes.preferencesChanged = true
      end
    end
  end
  return changes
end

function M.hasUserChanges()
  syncStagedRoster()
  return not valuesEqual(initialStagedByPlayer, stagedByPlayer)
end

function M.getStagedPlayers()
  syncStagedRoster()
  local players = {}
  for _, state in ipairs(getSortedStates(stagedByPlayer, true)) do
    players[#players + 1] = state.player
  end
  return players
end

function M.getPersonaSelectorData()
  syncStagedRoster()
  local preview = multiseatConfiguration.getPreview()
  local joinedCount = #getSortedStates(stagedByPlayer, true)
  preview.playerLimit = playerLimits.getCurrentLevelState(joinedCount, preview.platformManagesPlayers)
  return preview
end

-- personas keep unique icons, so only the unused ones plus the own one can be picked
local function getSelectableIcons(currentIcon, usedIcons)
  local icons = {}
  -- personas that never got a pool icon still need their current one as an option
  if currentIcon and not extensions.core_playerPersonas.isPersonaIcon(currentIcon) then icons[1] = currentIcon end
  for _, icon in ipairs(extensions.core_playerPersonas.getIconPool()) do
    if icon == currentIcon or not usedIcons[icon] then icons[#icons + 1] = icon end
  end
  return icons
end

function M.getSettingsData()
  syncStagedRoster()
  local preview = multiseatConfiguration.getPreview()
  local connectedByPlayer = {}
  local deviceInfoByPlayer = {}
  local function addDeviceInfo(player, label, icon, connected)
    if player == nil or player < 0 then return end
    local info = deviceInfoByPlayer[player]
    if not info then
      info = {allLabels = {}, connectedLabels = {}}
      deviceInfoByPlayer[player] = info
    end
    info.allLabels[#info.allLabels + 1] = label
    info.allIcon = info.allIcon or icon
    if connected then
      connectedByPlayer[player] = true
      info.connectedLabels[#info.connectedLabels + 1] = label
      info.connectedIcon = info.connectedIcon or icon
    end
  end
  for _, device in ipairs(preview.availablePlayers or {}) do
    addDeviceInfo(device.player, device.label, device.icon, device.connected ~= false)
  end
  for _, group in ipairs(preview.deviceGroups or {}) do
    for _, device in ipairs(group.devices or {}) do
      addDeviceInfo(group.playerIndex, device.label, device.icon, group.connected ~= false and device.connected ~= false)
    end
  end
  local states = getSortedStates(stagedByPlayer, true)
  local usedIcons = {}
  for _, state in ipairs(states) do
    if state.icon then usedIcons[state.icon] = true end
  end
  local players = {}
  for _, state in ipairs(states) do
    local connected = connectedByPlayer[state.player] == true
    local deviceInfo = deviceInfoByPlayer[state.player]
    players[#players + 1] = {
      player = state.player,
      personaId = state.personaId,
      label = state.label,
      icon = state.icon,
      icons = getSelectableIcons(state.icon, usedIcons),
      color = state.color,
      connected = connected,
      deviceLabel = deviceInfo and table.concat(connected and deviceInfo.connectedLabels or deviceInfo.allLabels, ", ") or nil,
      deviceIcon = deviceInfo and (connected and deviceInfo.connectedIcon or deviceInfo.allIcon) or nil,
      vehicle = {
        model = state.vehicle.model,
        config = state.vehicle.config,
        label = getVehicleLabel(state.vehicle),
        paints = getPaintTiles(state.vehicle),
      },
      preferences = deepcopy(state.preferences),
    }
  end
  return {players = players}
end

function M.getDigestData()
  ensurePersonaDefaults()
  local players = {}
  for _, participant in ipairs(core_multiseat.getJoinedParticipants()) do
    local persona = participant.persona
    local personaId = persona.id
    local actionButtons = digestActionButtonsByPersona[personaId]
    if not actionButtons then
      actionButtons = {}
      digestActionButtonsByPersona[personaId] = actionButtons
    end
    if not actionButtons.changeVehicle then
      actionButtons.changeVehicle = digestButtonInstance.addButton(function()
        local currentParticipant = getJoinedParticipantByPersonaId(personaId)
        if not currentParticipant then return false end
        return M.openQuickVehicleSelectorForPlayer(currentParticipant.assignment.playerIndex)
      end, {
        action = "changeVehicle",
        personaId = personaId,
      })
    end
    if not actionButtons.configureVehicle then
      actionButtons.configureVehicle = digestButtonInstance.addButton(function()
        local currentParticipant = getJoinedParticipantByPersonaId(personaId)
        if not currentParticipant then return false end
        local playerId = currentParticipant.assignment.playerIndex
        return M.configurePlayerVehicle(getOwnedVehicle(getOwnedEntryForPlayer(playerId)), playerId)
      end, {
        action = "configureVehicle",
        personaId = personaId,
      })
    end

    local player = participant.assignment.playerIndex
    local veh = getOwnedVehicle(getOwnedEntryForPlayer(player))
    players[#players + 1] = {
      player = player,
      personaId = persona.id,
      label = persona.displayName,
      icon = persona.icon,
      color = persona.colorHex,
      connected = participant.assignment.connected ~= false,
      deviceLabel = participant.assignment.connected and participant.assignment.connectedDeviceLabel
        or participant.assignment.deviceLabel,
      deviceIcon = participant.assignment.connected and participant.assignment.connectedInputIcon
        or participant.inputIcon,
      vehicle = {
        id = veh and veh:getId() or nil,
        label = getVehicleLabel(persona.vehicle),
      },
      actions = {
        {
          id = "changeVehicle",
          buttonId = actionButtons.changeVehicle.buttonId,
          label = _tr("ui.multiseat.vehicleDigest.action.changeVehicle"),
          icon = "car",
          uiEvent = "ok",
          disabled = false,
        },
        {
          id = "configureVehicle",
          buttonId = actionButtons.configureVehicle.buttonId,
          label = _tr("ui.multiseat.vehicleDigest.action.configureVehicle"),
          icon = "adjust",
          uiEvent = "action_2",
          disabled = veh == nil,
        },
      },
    }
  end
  table.sort(players, function(a, b) return a.player < b.player end)
  return {players = players}
end

function M.executeDigestAction(buttonId, payload)
  if not buttonId then return false end
  return digestButtonInstance.executeButton(buttonId, payload)
end

function M.configurePlayerVehicle(vehicle, playerId)
  playerId = tonumber(playerId)
  local participant = playerId ~= nil and getJoinedParticipant(playerId) or nil
  local ownedVehicle = getOwnedVehicle(getOwnedEntryForPlayer(playerId))
  if not participant or not vehicle or ownedVehicle ~= vehicle then return false end

  local currentRoute = extensions.ui_router.getCurrent()
  local currentRouteName = currentRoute and currentRoute.resolved and currentRoute.resolved.name
  local returnRoute = currentRouteName == "pause" and "pause" or "pause.vehicle"
  if not extensions.core_vehicle_configTarget.begin(vehicle:getId(), {
    playerId = playerId,
    returnRoute = returnRoute,
  }) then
    return false
  end

  local soloViewStarted = true
  if render_splitScreen and render_splitScreen.beginSoloView then
    soloViewStarted = render_splitScreen.beginSoloView(playerId)
  end
  if not soloViewStarted then
    extensions.core_vehicle_configTarget.clear("soloViewFailed")
    return false
  end

  local ok, result = pcall(extensions.ui_router.navigate,
    "pause.vehicle.configurationcombined",
    {vehicleId = vehicle:getId(), playerId = playerId},
    {preferredScope = "pause-tab-combined-parts"})
  if not ok or not result or result.result == false then
    if render_splitScreen and render_splitScreen.endSoloView then
      render_splitScreen.endSoloView()
    end
    extensions.core_vehicle_configTarget.clear("navigationFailed")
    return false
  end
  return true
end

function M.stagePlayerOptIn(player, optedIn)
  if optedIn == true then return false end
  local changed = multiseatConfiguration.leavePlayer(player)
  if changed then reconcileSnapshotsWithCurrentPlayers() end
  return changed
end

function M.cycleDevicePlayer(deviceId)
  local changed = multiseatConfiguration.cycleDevicePlayer(deviceId)
  if changed then reconcileSnapshotsWithCurrentPlayers() end
  return changed
end

function M.toggleDevicePlayer(deviceId)
  local changed = multiseatConfiguration.toggleDevicePlayer(deviceId)
  if changed then reconcileSnapshotsWithCurrentPlayers() end
  return changed
end

function M.moveDevicePlayer(deviceId, direction)
  local changed = multiseatConfiguration.moveDevicePlayer(deviceId, direction)
  if changed then reconcileSnapshotsWithCurrentPlayers() end
  return changed
end

function M.setDevicePlayer(deviceId, personaNumber)
  local changed = multiseatConfiguration.setDevicePlayer(deviceId, personaNumber)
  if changed then reconcileSnapshotsWithCurrentPlayers() end
  return changed
end

function M.removeDevice(deviceId)
  local changed = multiseatConfiguration.removeDevice(deviceId)
  if changed then reconcileSnapshotsWithCurrentPlayers() end
  return changed
end

function M.joinDeviceGroup(groupId)
  local changed = multiseatConfiguration.joinDeviceGroup(groupId)
  if changed then reconcileSnapshotsWithCurrentPlayers() end
  return changed
end

function M.leaveDeviceGroup(player)
  local changed = multiseatConfiguration.leavePlayer(player)
  if changed then reconcileSnapshotsWithCurrentPlayers() end
  return changed
end

-- the single way a desired vehicle gets staged, used by the selectors and shared vehicle action
local function stageVehicleForState(state, model, config, paintNames)
  if not state or not state.optedIn or not model or not config then return false end

  local vehicle = {
    model = model,
    config = config,
    -- the color the user picked in the selector, used whenever the automatic color is turned off
    paintNames = deepcopy(paintNames),
  }
  -- Keep the globally staged color mode while replacing this player's vehicle selection.
  if type(state.vehicle) == "table" then vehicle.automaticColor = state.vehicle.automaticColor end
  state.vehicle = applyVehicleColor(vehicle, state.personaId, state.personaColor, state.vehicleFallbackPaint)
  multiseatConfiguration.setPersonaData(state.personaNumber, {vehicle = deepcopy(state.vehicle)})
  return true
end

function M.stagePlayerVehiclePreferences(player, preferences)
  syncStagedRoster()
  player = tonumber(player)
  local state = player ~= nil and stagedByPlayer[player] or nil
  if not state or not state.optedIn or type(preferences) ~= "table" then return false end

  local gearbox = preferences.gearbox
  if gearbox ~= "arcade" and gearbox ~= "realistic" then return false end
  local ignitionLevel = tonumber(preferences.ignitionLevel)
  if ignitionLevel == nil or ignitionLevel < 0 or ignitionLevel > 3 or ignitionLevel % 1 ~= 0 then return false end
  state.preferences = {
    gearbox = gearbox,
    clutchAssist = preferences.clutchAssist == true,
    throttleAssist = preferences.throttleAssist == true,
    ignitionLevel = ignitionLevel,
  }
  multiseatConfiguration.setPersonaData(state.personaNumber, {preferences = state.preferences})
  return true
end

function M.stagePlayerIcon(player, icon)
  syncStagedRoster()
  player = tonumber(player)
  local state = player ~= nil and stagedByPlayer[player] or nil
  if not state or not state.optedIn or not extensions.core_playerPersonas.isPersonaIcon(icon) then return false end
  if state.icon == icon then return false end
  for _, other in pairs(stagedByPlayer) do
    if other.optedIn and other.icon == icon then return false end
  end

  state.icon = icon
  multiseatConfiguration.setPersonaData(state.personaNumber, {icon = icon})
  return true
end

function M.stageAutomaticColorForAllPlayers(automaticColor)
  syncStagedRoster()
  automaticColor = automaticColor == true
  stagedAutomaticColor = automaticColor
  local changed = false
  for _, state in pairs(stagedByPlayer) do
    if state.optedIn and type(state.vehicle) == "table"
      and (state.vehicle.automaticColor == true) ~= automaticColor
    then
      state.vehicle.automaticColor = automaticColor
      applyVehicleColor(state.vehicle, state.personaId, state.personaColor, state.vehicleFallbackPaint)
      multiseatConfiguration.setPersonaData(state.personaNumber, {vehicle = deepcopy(state.vehicle)})
      changed = true
    end
  end
  return changed
end

function M.getSharedVehicleOptions()
  syncStagedRoster()
  local states = getSortedStates(stagedByPlayer, true)
  if #states < 2 then return nil end

  local options = {}
  local distinctVehicles = {}
  local sharedValue
  for _, state in ipairs(states) do
    if type(state.vehicle) == "table" then
      local duplicate = false
      for _, vehicle in ipairs(distinctVehicles) do
        if vehicleSelectionsEqual(vehicle, state.vehicle) then
          duplicate = true
          break
        end
      end
      if not duplicate then
        distinctVehicles[#distinctVehicles + 1] = state.vehicle
        if #distinctVehicles == 1 then sharedValue = state.player end
        options[#options + 1] = {
          value = state.player,
          label = getVehicleLabel(state.vehicle),
        }
      end
    end
  end
  if #distinctVehicles ~= 1 then sharedValue = nil end

  local recentCount = 0
  for _, recent in ipairs(ui_vehicleSelector_general.getRecentVehicles()) do
    local valid = core_vehicles.getModel(recent.model)
      and core_vehicles.getConfig(recent.model, getConfigKey(recent.config))
    local duplicate = false
    for _, vehicle in ipairs(distinctVehicles) do
      if vehicleSelectionsEqual(vehicle, recent) then
        duplicate = true
        break
      end
    end
    if valid and not duplicate then
      if recentCount == 0 then
        options[#options + 1] = {
          value = "divider:recent",
          label = "────────────────",
          disabled = true,
        }
      end
      distinctVehicles[#distinctVehicles + 1] = recent
      options[#options + 1] = {
        value = "recent:" .. recent.model .. "/" .. recent.config,
        label = getVehicleLabel(recent),
      }
      recentCount = recentCount + 1
      if recentCount >= 8 then break end
    end
  end
  return options, sharedValue
end

local function stageVehicleForAllPlayers(vehicle)
  if type(vehicle) ~= "table" then return false end
  local changed = false
  for _, state in ipairs(getSortedStates(stagedByPlayer, true)) do
    local previousVehicle = deepcopy(state.vehicle)
    if stageVehicleForState(state, vehicle.model, vehicle.config, vehicle.paintNames)
      and not valuesEqual(previousVehicle, state.vehicle)
    then
      changed = true
    end
  end
  return changed
end

function M.stageSameVehicleForAllPlayers(source)
  syncStagedRoster()
  if type(source) == "string" then
    local model, config = source:match("^recent:([^/]+)/(.+)$")
    if model and config then
      return stageVehicleForAllPlayers({model = model, config = config})
    end
  end
  local state = stagedByPlayer[tonumber(source)]
  return state and state.optedIn and stageVehicleForAllPlayers(state.vehicle) or false
end

function M.getGatherVehicleOptions()
  local owned = M.getOwnedVehicles()
  if #owned < 2 then return nil end
  local options = {}
  for _, entry in ipairs(owned) do
    local participant = getJoinedParticipantByPersonaId(entry.personaId)
    local playerLabel = participant and participant.persona.displayName or {
      txt = "ui.multiseat.playerTag",
      context = {number = entry.player + 1},
    }
    options[#options + 1] = {
      value = entry.player,
      label = playerLabel,
    }
  end

  local level = core_levels.getLevelByName(getCurrentLevelIdentifier())
  local spawnPointHeaderAdded = false
  for _, spawnPoint in ipairs(level and level.spawnPoints or {}) do
    local objectName = spawnPoint.objectname
    if objectName and scenetree.findObject(objectName) then
      if not spawnPointHeaderAdded then
        options[#options + 1] = {
          value = "divider:spawnPoints",
          label = "────────────────",
          disabled = true,
        }
        spawnPointHeaderAdded = true
      end
      options[#options + 1] = {
        value = "spawnPoint:" .. objectName,
        label = spawnPoint.translationId or spawnPoint.name or objectName,
      }
    end
  end
  return options
end

local function gatherVehiclesAtSpawnPoint(owned, objectName)
  local spawnPoint = scenetree.findObject(objectName)
  if not spawnPoint then return false end

  local anchor
  local gathered = false
  for _, entry in ipairs(owned) do
    local veh = getOwnedVehicle(entry)
    if veh then
      local pos, rot
      if anchor then
        pos, rot = getAdjacentSpawnTransform(anchor)
      else
        pos = spawnPoint:getPosition()
        rot = quat(0, 0, 1, 0) * spawnPoint:getRotation()
      end
      applySpawnPlanPosition(veh, {pos = pos, rot = rot}, entry.player)
      anchor = veh
      gathered = true
    end
  end
  return gathered
end

function M.gatherVehicles(target)
  local owned = M.getOwnedVehicles()
  if type(target) == "string" then
    local objectName = target:match("^spawnPoint:(.+)$")
    if objectName then return gatherVehiclesAtSpawnPoint(owned, objectName) end
  end

  local anchorPlayer = tonumber(target)
  local anchorEntry
  for _, entry in ipairs(owned) do
    if entry.player == anchorPlayer then
      anchorEntry = entry
      break
    end
  end
  local anchor = getOwnedVehicle(anchorEntry)
  if not anchor then return false end

  local gathered = false
  for _, entry in ipairs(owned) do
    if entry ~= anchorEntry then
      local veh = getOwnedVehicle(entry)
      if veh then
        local pos, rot = getAdjacentSpawnTransform(anchor)
        applySpawnPlanPosition(veh, {pos = pos, rot = rot}, entry.player)
        anchor = veh
        gathered = true
      end
    end
  end
  return gathered
end

function M.reseatAllPlayers()
  local reseated = false
  for _, entry in ipairs(M.getOwnedVehicles()) do
    local veh = getOwnedVehicle(entry)
    if veh and be:getPlayerVehicleID(entry.player) ~= entry.vehId then
      assignPlayerToVehicle(entry.player, veh)
      reseated = true
    end
  end
  return reseated
end

function M.openVehicleSelectorForPlayer(player)
  syncStagedRoster()
  player = tonumber(player)
  local state = player ~= nil and stagedByPlayer[player] or nil
  if not state or not state.optedIn then return false end

  pendingAllPlayers = false
  pendingPlayer = player
  ui_vehicleSelector_general.openVehicleSelectorForChallenge(function(model, config, additionalData)
    local selectedPlayer = pendingPlayer
    pendingPlayer = nil
    local selectedState = selectedPlayer ~= nil and stagedByPlayer[selectedPlayer] or nil
    local paintNames = type(additionalData) == "table" and {
      paint = additionalData.paint,
      paint2 = additionalData.paint2,
      paint3 = additionalData.paint3,
    } or nil
    if stageVehicleForState(selectedState, model, config, paintNames) then
      trackRecentVehicle(model, config)
    end
    extensions.ui_router.navigate(SETTINGS_ROUTE)
  end, VEHICLE_SELECTOR_ROUTE, {unrestricted = true})
  return true
end

function M.openVehicleSelectorForAllPlayers()
  syncStagedRoster()
  if #getSortedStates(stagedByPlayer, true) < 2 then return false end

  pendingPlayer = nil
  pendingAllPlayers = true
  ui_vehicleSelector_general.openVehicleSelectorForChallenge(function(model, config, additionalData)
    local shouldStage = pendingAllPlayers
    pendingAllPlayers = false
    if shouldStage and model and config then
      trackRecentVehicle(model, config)
      stageVehicleForAllPlayers({
        model = model,
        config = config,
        paintNames = type(additionalData) == "table" and {
          paint = additionalData.paint,
          paint2 = additionalData.paint2,
          paint3 = additionalData.paint3,
        } or nil,
      })
    end
    extensions.ui_router.navigate(SETTINGS_ROUTE)
  end, VEHICLE_SELECTOR_ROUTE, {unrestricted = true})
  return true
end

function M.onVehicleSelectorLeave(toRoute)
  if not toRoute or toRoute.name ~= VEHICLE_SELECTOR_ROUTE then
    pendingPlayer = nil
    pendingAllPlayers = false
  end
end

local function getSelectedPaintNames(additionalData)
  if type(additionalData) ~= "table" then return nil end
  if not additionalData.paint and not additionalData.paint2 and not additionalData.paint3 then return nil end
  return {
    paint = additionalData.paint,
    paint2 = additionalData.paint2,
    paint3 = additionalData.paint3,
  }
end

local function replaceLiveParticipantVehicle(participant, selectedVehicle)
  local player = participant.assignment.playerIndex
  local persona = participant.persona
  local owned = ownedByPersona[persona.id] or getOwnedEntryForPlayer(player)
  local veh = getOwnedVehicle(owned)

  if veh then
    local options = buildSpawnOptionsForParticipant(participant, selectedVehicle, {})
    veh = core_vehicles.replaceVehicle(options.model, options, veh)
    if not veh then return nil, "vehicle_replace_failed" end
  else
    local ownedVehicles = M.getOwnedVehicles()
    local anchor = ownedVehicles[#ownedVehicles] and ownedVehicles[#ownedVehicles].veh or getPlayerVehicle(0)
    local pos, rot = getAdjacentSpawnTransform(anchor)
    local options = buildSpawnOptionsForParticipant(participant, selectedVehicle, {pos = pos, rot = rot})
    options.safeSpawn = true
    veh = core_vehicles.spawnNewVehicle(options.model, options)
    if not veh then return nil, "vehicle_spawn_failed" end
  end

  trackOwnedVehicle(player, persona.id, veh)
  assignPlayerToVehicle(player, veh)
  core_camera.resetCamera(player)
  return veh
end

function M.replacePlayerVehicle(player, model, config, additionalData)
  player = tonumber(player)
  local participant = player ~= nil and getJoinedParticipant(player) or nil
  if settings.getValue("multiseat") ~= true or not participant then
    return {success = false, reason = "player_unavailable"}
  end
  if not model or not config then
    return {success = false, reason = "invalid_vehicle_selection"}
  end

  local oldPersonaData = personaUpdateData(participant.persona)
  local selectedVehicle = {
    model = model,
    config = config,
    paintNames = getSelectedPaintNames(additionalData),
    automaticColor = getAutomaticColorSetting(),
  }
  applyVehicleColor(
    selectedVehicle,
    participant.persona.id,
    participant.persona.color,
    participant.persona.vehicleFallbackPaint
  )

  local nextPersonaData = personaUpdateData(participant.persona)
  nextPersonaData.vehicle = deepcopy(selectedVehicle)
  if not core_multiseat.setPlayerPersona(player, nextPersonaData) then
    return {success = false, reason = "persona_update_failed"}
  end

  local updatedParticipant = getJoinedParticipant(player)
  local veh, reason
  if updatedParticipant then
    veh, reason = replaceLiveParticipantVehicle(updatedParticipant, selectedVehicle)
  else
    reason = "player_unavailable"
  end
  if not veh then
    core_multiseat.setPlayerPersona(player, oldPersonaData)
    return {success = false, reason = reason or "player_unavailable"}
  end

  sessionByPersona[updatedParticipant.persona.id] = {vehicle = deepcopy(selectedVehicle)}
  snapshotsInitialized = false
  lastConfigurationRevision = -1
  return {success = true}
end

function M.openQuickVehicleSelectorForPlayer(player)
  player = tonumber(player)
  if settings.getValue("multiseat") ~= true or not getJoinedParticipant(player) then return false end

  pendingQuickPlayer = player
  ui_vehicleSelector_general.openVehicleSelectorForChallenge(function(model, config, additionalData)
    local selectedPlayer = pendingQuickPlayer
    pendingQuickPlayer = nil
    extensions.ui_router.navigate("pause")
    if model and config and selectedPlayer ~= nil then
      trackRecentVehicle(model, config)
      guihooks.trigger("app:waiting", true)
      pendingWaitingCallback = function()
        local result = M.replacePlayerVehicle(selectedPlayer, model, config, additionalData)
        if result.success == false then
          log("E", "multiseatVehicles", "Could not replace player vehicle: " .. tostring(result.reason))
        end
        guihooks.trigger("app:waiting", false)
      end
    end
  end, QUICK_VEHICLE_SELECTOR_ROUTE, {unrestricted = true})
  return true
end

function M.onQuickVehicleSelectorEnter(context, toRoute, fromRoute, data)
  ui_gridSelectorRouteLifecycleCallbacks.onRouteEnter(context, toRoute, fromRoute, data)
end

function M.onQuickVehicleSelectorMount(context, toRoute, fromRoute, data)
  ui_gridSelectorRouteLifecycleCallbacks.onRouteMount(context, toRoute, fromRoute, data)
end

function M.onQuickVehicleSelectorLeave(context, toRoute, fromRoute, data)
  ui_gridSelectorRouteLifecycleCallbacks.onRouteLeave(context, toRoute, fromRoute, data)
  if not toRoute or toRoute.name ~= QUICK_VEHICLE_SELECTOR_ROUTE then
    pendingQuickPlayer = nil
  end
end

function M.adoptFreeroamVehicle(player, veh)
  player = tonumber(player)
  local participant = player ~= nil and getJoinedParticipant(player) or nil
  local vehicle = getVehicleSelection(veh)
  if not participant or not vehicle then return false end

  local data = personaUpdateData(participant.persona)
  data.vehicle = vehicle
  sessionByPersona[participant.persona.id] = {
    vehicle = deepcopy(data.vehicle),
  }
  if not core_multiseat.setPlayerPersona(player, data) then return false end

  trackOwnedVehicle(player, participant.persona.id, veh)
  snapshotsInitialized = false
  return true
end

function M.setPlayerVehicleSelection(player, vehicle)
  player = tonumber(player)
  local participant = player ~= nil and getJoinedParticipant(player) or nil
  if not participant or type(vehicle) ~= "table" or not vehicle.model or not vehicle.config then
    return false
  end

  local data = personaUpdateData(participant.persona)
  data.vehicle = {
    model = vehicle.model,
    config = vehicle.config,
  }
  sessionByPersona[participant.persona.id] = {
    vehicle = deepcopy(data.vehicle),
  }
  if not core_multiseat.setPlayerPersona(player, data) then return false end

  snapshotsInitialized = false
  return true
end

function M.reconcileFreeroamVehicles(options)
  if career_career and career_career.isActive and career_career.isActive() then return true end
  options = options or {}
  ensurePersonaDefaults()
  local participants = core_multiseat.getJoinedParticipants()
  local joinedByPersona = {}
  for _, participant in ipairs(participants) do
    joinedByPersona[participant.persona.id] = participant
  end

  local removed = {}
  for _, entry in pairs(ownedByPersona) do
    if not joinedByPersona[entry.personaId] then removed[#removed + 1] = entry end
  end
  for _, entry in ipairs(removed) do removeOwnedEntry(entry) end

  for _, participant in ipairs(participants) do
    local entry = ownedByPersona[participant.persona.id]
    if entry then entry.player = participant.assignment.playerIndex end
  end

  local anchors = {}
  for _, entry in ipairs(M.getOwnedVehicles()) do anchors[#anchors + 1] = entry.veh end

  local missingCount = 0
  for _, participant in ipairs(participants) do
    if not getOwnedVehicle(ownedByPersona[participant.persona.id]) then missingCount = missingCount + 1 end
  end
  local roadTransforms = getRoadSpawnTransforms(anchors[#anchors] or getPlayerVehicle(0), missingCount)
  local roadTransformIndex = 0

  for _, participant in ipairs(participants) do
    local player = participant.assignment.playerIndex
    local persona = participant.persona
    local selectedVehicle = persona.vehicle
    local entry = ownedByPersona[persona.id]
    if entry then entry.player = player end
    local veh = getOwnedVehicle(entry)

    if veh then
      if not options.preserveOwned and not vehicleMatchesSelection(veh, selectedVehicle) then
        local spawningOptions = buildSpawnOptionsForParticipant(participant, selectedVehicle, {})
        veh = core_vehicles.replaceVehicle(spawningOptions.model, spawningOptions, veh)
        if not veh then return false, "vehicle_replace_failed" end
      end
    else
      roadTransformIndex = roadTransformIndex + 1
      local roadTransform = roadTransforms and roadTransforms[roadTransformIndex]
      local pos, rot
      if roadTransform then
        pos, rot = roadTransform.pos, roadTransform.rot
      else
        pos, rot = getAdjacentSpawnTransform(anchors[#anchors] or getPlayerVehicle(0))
      end
      local spawningOptions = buildSpawnOptionsForParticipant(participant, selectedVehicle, {pos = pos, rot = rot})
      spawningOptions.safeSpawn = true
      veh = core_vehicles.spawnNewVehicle(spawningOptions.model, spawningOptions)
      if not veh then return false, "vehicle_spawn_failed" end
    end

    trackOwnedVehicle(player, persona.id, veh)
    anchors[#anchors + 1] = veh
    assignPlayerToVehicle(player, veh)
  end

  syncSplitScreenPlayers()
  return true
end

local function clearPreparedCommit()
  if not preparedCommit then return end
  for _, veh in ipairs(preparedCommit.spawned or {}) do
    if veh and scenetree.findObjectById(veh:getId()) then veh:delete() end
  end
  preparedCommit = nil
end

function M.prepareStagedChanges()
  clearPreparedCommit()
  syncStagedRoster()
  local changes = M.getStagedChanges()
  local stagedPlayers = getSortedStates(stagedByPlayer, true)
  if #stagedPlayers == 0 then return {success = false, reason = "no_players"} end

  if career_career and career_career.isActive and career_career.isActive() then
    local plan = {
      byPersona = {},
      spawned = {},
      preexistingVehicleIds = nil,
    }
    for _, staged in ipairs(stagedPlayers) do
      local pVeh = getPlayerVehicle(staged.player) or getPlayerVehicle(0)
      if pVeh then
        plan.byPersona[staged.personaId] = {
          player = staged.player,
          personaId = staged.personaId,
          vehicle = pVeh,
        }
      end
    end
    preparedCommit = plan
    return {success = true, changes = changes}
  end
  local limitState = playerLimits.getCurrentLevelState(#stagedPlayers, multiseatConfiguration.getPreview().platformManagesPlayers)
  if limitState.hard and limitState.exceeded then return {success = false, reason = "player_limit_exceeded"} end
  for _, staged in pairs(stagedByPlayer) do
    if staged.optedIn then
      if type(staged.vehicle) ~= "table" or not staged.vehicle.model or not staged.vehicle.config then
        return {success = false, reason = "invalid_vehicle_selection"}
      end
      multiseatConfiguration.setPersonaData(staged.personaNumber, {
        icon = staged.icon,
        vehicle = deepcopy(staged.vehicle),
        preferences = deepcopy(staged.preferences),
      }, false)
    end
  end

  local commitConfig = multiseatConfiguration.getCommitConfiguration()
  local adoptVehicle = commitConfig.adoptVehicleId and scenetree.findObjectById(commitConfig.adoptVehicleId) or nil
  local startingMultiseat = settings.getValue("multiseat") ~= true
  local plan = {
    byPersona = {},
    spawned = {},
    preexistingVehicleIds = startingMultiseat and getActiveVehicleIds() or nil,
  }
  preparedCommit = plan
  local anchors = {}
  for _, entry in ipairs(M.getOwnedVehicles()) do anchors[#anchors + 1] = entry.veh end
  if adoptVehicle then anchors[#anchors + 1] = adoptVehicle end
  local roadTransforms = getRoadSpawnTransforms(anchors[#anchors] or getPlayerVehicle(0), #stagedPlayers)
  local roadTransformIndex = 0

  for _, staged in ipairs(stagedPlayers) do
    local persona = multiseatConfiguration.getPersona(staged.personaNumber)
    local oldEntry = ownedByPersona[staged.personaId]
    local oldVehicle = getOwnedVehicle(oldEntry)
    local retained = oldVehicle or (staged.personaNumber == 1 and adoptVehicle or nil)
    local selectedVehicle = retained
    if not retained or not vehicleMatchesSelection(retained, staged.vehicle) then
      local pos, rot
      if retained then
        pos = retained:getPosition()
        rot = quatFromDir(retained:getDirectionVector(), retained:getDirectionVectorUp())
      else
        roadTransformIndex = roadTransformIndex + 1
        local roadTransform = roadTransforms and roadTransforms[roadTransformIndex]
        if roadTransform then
          pos, rot = roadTransform.pos, roadTransform.rot
        else
          pos, rot = getAdjacentSpawnTransform(anchors[#anchors] or getPlayerVehicle(0))
        end
      end
      local participant = {
        assignment = {playerIndex = staged.player},
        persona = persona,
      }
      local options = buildSpawnOptionsForParticipant(participant, staged.vehicle, {pos = pos, rot = rot})
      options.safeSpawn = true
      selectedVehicle = core_vehicles.spawnNewVehicle(options.model, options)
      if not selectedVehicle then
        clearPreparedCommit()
        return {success = false, reason = "vehicle_spawn_failed"}
      end
      plan.spawned[#plan.spawned + 1] = selectedVehicle
      anchors[#anchors + 1] = selectedVehicle
    else
      repaintVehicle(retained, getVehiclePaints(staged.vehicle, persona.id, persona.color, persona.vehicleFallbackPaint))
    end
    plan.byPersona[staged.personaId] = {
      oldEntry = oldEntry,
      player = staged.player,
      personaId = staged.personaId,
      vehicle = selectedVehicle,
    }
  end
  return {success = true, changes = changes}
end

function M.finalizeStagedChanges(changes, committedConfig)
  applyingStagedChanges = true
  if not preparedCommit then
    applyingStagedChanges = false
    return {success = false, reason = "vehicles_not_prepared"}
  end

  if career_career and career_career.isActive and career_career.isActive() then
    preparedCommit = nil
    syncSplitScreenPlayers()
    applyingStagedChanges = false
    snapshotsInitialized = false
    stagedAutomaticColor = nil
    lastConfigurationRevision = -1
    return {success = true, changes = changes or {}}
  end
  local stagedByPersona = {}
  for _, staged in pairs(stagedByPlayer) do stagedByPersona[staged.personaId] = staged end
  local participants = core_multiseat.getJoinedParticipants()
  for _, participant in ipairs(participants) do
    if not preparedCommit.byPersona[participant.persona.id] then
      applyingStagedChanges = false
      return {success = false, reason = "prepared_vehicle_missing"}
    end
  end

  local removed = {}
  for personaId, entry in pairs(ownedByPersona) do
    local prepared = preparedCommit.byPersona[personaId]
    if not prepared or getOwnedVehicle(entry) ~= prepared.vehicle then removed[#removed + 1] = entry end
  end
  for _, entry in ipairs(removed) do removeOwnedEntry(entry) end

  for _, participant in ipairs(participants) do
    local staged = stagedByPersona[participant.persona.id]
    local prepared = preparedCommit.byPersona[participant.persona.id]
    sessionByPersona[participant.persona.id] = {vehicle = deepcopy(staged.vehicle)}
    trackOwnedVehicle(participant.assignment.playerIndex, participant.persona.id, prepared.vehicle)
    assignPlayerToVehicle(participant.assignment.playerIndex, prepared.vehicle)
    applyPreferences(participant.persona, staged.preferences, prepared.vehicle)
  end
  removeUnownedVehicles(preparedCommit.preexistingVehicleIds)
  preparedCommit = nil
  syncSplitScreenPlayers()
  applyingStagedChanges = false
  snapshotsInitialized = false
  stagedAutomaticColor = nil
  lastConfigurationRevision = -1
  return {success = true, changes = changes or {}}
end

function M.applyStagedChanges()
  local prepared = M.prepareStagedChanges()
  if prepared.success == false then return prepared end
  local committed, configOrReason = multiseatConfiguration.commitCore()
  if not committed then
    clearPreparedCommit()
    return {success = false, reason = configOrReason}
  end
  local finalized = M.finalizeStagedChanges(prepared.changes, configOrReason)
  if finalized.success == false then
    multiseatConfiguration.rollbackCommit()
    clearPreparedCommit()
    return finalized
  end
  multiseatConfiguration.completeCommit()
  return finalized
end


function M.cancelPreparedChanges()
  clearPreparedCommit()
end

function M.discardStagedChanges()
  clearPreparedCommit()
  snapshotsInitialized = false
  stagedAutomaticColor = nil
  table.clear(initialStagedByPlayer)
  lastConfigurationRevision = -1
  return true
end

function M.resetSettingsSnapshots()
  clearPreparedCommit()
  snapshotsInitialized = false
  stagedAutomaticColor = nil
  table.clear(initialStagedByPlayer)
  lastConfigurationRevision = -1
end

function M.getVehicleForPlayer(player)
  ensurePersonaDefaults()
  local participant = getJoinedParticipant(player)
  return participant and deepcopy(participant.persona.vehicle) or nil
end

function M.spawnAll(spawnPlan)
  M.removeAll()
  ensurePersonaDefaults()

  local spawned = {}
  for _, entry in ipairs(spawnPlan or {}) do
    local participant = getJoinedParticipant(entry.player)
    local owned = spawnPlanVehicle(participant, entry)
    if owned then spawned[#spawned + 1] = owned end
  end
  return spawned
end

function M.reconcileSpawnPlan(spawnPlan, options)
  ensurePersonaDefaults()
  options = options or {}
  local removeMissing = options.removeMissing ~= false
  local desiredPlayers = {}
  local reconciled = {}

  for _, entry in ipairs(spawnPlan or {}) do
    desiredPlayers[entry.player] = true
    local owned, reason = reconcileSpawnPlanEntry(entry)
    if not owned then return reconciled, reason end
    reconciled[#reconciled + 1] = owned
  end

  if removeMissing then
    local removed = {}
    for _, entry in pairs(ownedByPersona) do
      if not desiredPlayers[entry.player] then removed[#removed + 1] = entry end
    end
    for _, entry in ipairs(removed) do removeOwnedEntry(entry) end
  end

  if options.customPlayers then
    customSplitPlayers = copyPlayerList(options.customPlayers)
  end
  syncSplitScreenPlayers()
  return reconciled
end

function M.removeAll()
  local entries = {}
  for _, entry in pairs(ownedByPersona) do entries[#entries + 1] = entry end
  for _, entry in ipairs(entries) do removeOwnedEntry(entry) end
end

function M.clearSession()
  clearPreparedCommit()
  table.clear(sessionByPersona)
  table.clear(activeByPlayer)
  table.clear(stagedByPlayer)
  table.clear(initialStagedByPlayer)
  snapshotsInitialized = false
  buildingSnapshots = false
  applyingStagedChanges = false
  stagedAutomaticColor = nil
  lastConfigurationRevision = -1
  reloadPreferencesByPersona = nil
end

-- stop tracking a player's vehicle without deleting it, so it survives the multiseat teardown.
function M.abandonPlayerVehicle(player)
  local entry = getOwnedEntryForPlayer(player)
  if not entry then return nil end
  local veh = getOwnedVehicle(entry)
  ownedByPersona[entry.personaId] = nil
  return veh
end

function M.getOwnedVehicles()
  local result = {}
  for _, entry in pairs(ownedByPersona) do
    if getOwnedVehicle(entry) then
      result[#result + 1] = entry
    end
  end
  table.sort(result, function(a, b) return a.player < b.player end)
  return result
end

function M.setFrozen(spawned, frozen)
  for _, entry in ipairs(spawned or M.getOwnedVehicles()) do
    local veh = getOwnedVehicle(entry)
    if veh then
      core_vehicleBridge.requestValue(veh, function()
        core_vehicleBridge.executeAction(veh, "setFreeze", frozen == true)
      end, "mainController", "freezeState")
    end
  end
end

function M.repaintOwnedVehicles()
  for _, entry in pairs(ownedByPersona) do
    local veh = getOwnedVehicle(entry)
    if not veh then goto continue end
    local participant = getJoinedParticipantByPersonaId(entry.personaId)
    if not participant then goto continue end
    local persona = participant.persona
    local paints = getVehiclePaints(persona.vehicle, persona.id, persona.color, persona.vehicleFallbackPaint)
    repaintVehicle(veh, paints)
    ::continue::
  end
end

function M.areVehiclesReady(spawned)
  for _, entry in ipairs(spawned or M.getOwnedVehicles()) do
    local veh = getOwnedVehicle(entry)
    if not veh or not veh:isReady() then
      return false
    end
  end
  return true
end

function M.isSynchronizing()
  return buildingSnapshots or applyingStagedChanges or preparedCommit ~= nil
end

local function onSerialize(reason)
  if not core_multiseat.isMultiseatActive() then
    log("I", "multiseatReload", "vehicles serialize skipped: no active multiseat session")
    return
  end

  clearPreparedCommit()
  local ownedVehicles = {}
  local preferencesByPersona = {}
  for _, participant in ipairs(core_multiseat.getJoinedParticipants()) do
    preferencesByPersona[participant.persona.id] = getVehiclePreferences(participant.persona)
  end
  for _, entry in pairs(ownedByPersona) do
    local veh = getOwnedVehicle(entry)
    if veh then
      ownedVehicles[#ownedVehicles + 1] = {
        personaId = entry.personaId,
        player = entry.player,
        vehId = veh:getId(),
      }
    end
  end
  table.sort(ownedVehicles, function(a, b) return a.player < b.player end)
  preserveVehiclesOnUnload = true
  log("I", "multiseatReload", string.format(
    "vehicles serialize: reason=%s owned=%d sessions=%d preferences=%d preserveOnUnload=true",
    tostring(reason),
    #ownedVehicles,
    tableSize(sessionByPersona),
    tableSize(preferencesByPersona)
  ))
  return {
    ownedVehicles = ownedVehicles,
    sessionByPersona = deepcopy(sessionByPersona),
    preferencesByPersona = preferencesByPersona,
  }
end

local function onDeserialized(data)
  if type(data) ~= "table" then
    log("I", "multiseatReload", "vehicles deserialize skipped: invalid snapshot")
    return
  end

  table.clear(ownedByPersona)
  sessionByPersona = deepcopy(data.sessionByPersona or {})
  reloadPreferencesByPersona = deepcopy(data.preferencesByPersona or {})
  local restoredVehicles = 0
  for _, serialized in ipairs(data.ownedVehicles or {}) do
    local vehId = tonumber(serialized.vehId)
    local veh = vehId and scenetree.findObjectById(vehId) or nil
    if veh and serialized.personaId ~= nil and tonumber(serialized.player) ~= nil then
      trackOwnedVehicle(tonumber(serialized.player), serialized.personaId, veh)
      assignPlayerToVehicle(tonumber(serialized.player), veh)
      restoredVehicles = restoredVehicles + 1
    end
  end
  syncSplitScreenPlayers()
  reloadRestorePending = true
  log("I", "multiseatReload", string.format(
    "vehicles deserialize: serialized=%d relinked=%d sessions=%d preferences=%d pendingReconcile=true",
    #(data.ownedVehicles or {}),
    restoredVehicles,
    tableSize(sessionByPersona),
    tableSize(reloadPreferencesByPersona)
  ))
end

local function onUpdate()
  if not reloadRestorePending or not core_multiseat.isMultiseatActive() then return end
  if #core_multiseat.getJoinedParticipants() == 0 then return end

  reloadRestorePending = false
  settings.setValue("multiseat", true)
  local success, reason = M.reconcileFreeroamVehicles({preserveOwned = true})
  local restoredPreferences = 0
  for _, participant in ipairs(core_multiseat.getJoinedParticipants()) do
    local preferences = reloadPreferencesByPersona and reloadPreferencesByPersona[participant.persona.id]
    if preferences then
      local entry = getOwnedEntryForPlayer(participant.assignment.playerIndex)
      applyPreferences(participant.persona, preferences, getOwnedVehicle(entry))
      restoredPreferences = restoredPreferences + 1
    end
  end
  reloadPreferencesByPersona = nil
  M.setFrozen(nil, false)
  log("I", "multiseatReload", string.format(
    "vehicles post-restore: reconciled=%s reason=%s owned=%d preferences=%d unfreezeRequested=true",
    tostring(success),
    tostring(reason),
    #M.getOwnedVehicles(),
    restoredPreferences
  ))
  if not success then
    log("E", "multiseatVehicles", "Could not restore multiseat vehicles after Lua reload: " .. tostring(reason))
  end
end

local function onUiWaitingState()
  if pendingWaitingCallback then
    local callback = pendingWaitingCallback
    pendingWaitingCallback = nil
    callback()
  end
end

-- the level teardown takes the vehicles with it, so only the bookkeeping has to go
function M.onClientEndMission()
  pendingPlayer = nil
  pendingAllPlayers = false
  pendingQuickPlayer = nil
  pendingWaitingCallback = nil
  digestButtonInstance.clearButtonFunctions()
  table.clear(digestActionButtonsByPersona)
  table.clear(ownedByPersona)
  table.clear(sessionByPersona)
  table.clear(activeByPlayer)
  table.clear(stagedByPlayer)
  table.clear(initialStagedByPlayer)
  snapshotsInitialized = false
  buildingSnapshots = false
  applyingStagedChanges = false
  preparedCommit = nil
  stagedAutomaticColor = nil
  lastConfigurationRevision = -1
  preserveVehiclesOnUnload = false
  reloadRestorePending = false
  reloadPreferencesByPersona = nil
  customSplitPlayers = nil
end

function M.onExtensionUnloaded()
  pendingPlayer = nil
  pendingAllPlayers = false
  pendingQuickPlayer = nil
  pendingWaitingCallback = nil
  digestButtonInstance.clearButtonFunctions()
  table.clear(digestActionButtonsByPersona)
  if preserveVehiclesOnUnload then
    table.clear(ownedByPersona)
  else
    clearPreparedCommit()
    M.removeAll()
  end
  table.clear(sessionByPersona)
  table.clear(activeByPlayer)
  table.clear(stagedByPlayer)
  table.clear(initialStagedByPlayer)
  snapshotsInitialized = false
  buildingSnapshots = false
  applyingStagedChanges = false
  preparedCommit = nil
  stagedAutomaticColor = nil
  lastConfigurationRevision = -1
  preserveVehiclesOnUnload = false
  reloadRestorePending = false
  reloadPreferencesByPersona = nil
  customSplitPlayers = nil
end

M.onUpdate = onUpdate
M.onUiWaitingState = onUiWaitingState
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
