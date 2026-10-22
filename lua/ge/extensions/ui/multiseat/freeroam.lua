-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
--[[
Multiseat levels can provide a multiseat.suggestedVehicles list in info.json, or implement mainLevel.getMultiseatSuggestedVehicles(playerCount) for exact per-player choices.
They can also implement mainLevel.getMultiseatSpawnPositions(playerCount), returning raw pos/rot entries or parking spots.
Missing level data falls back to shared multiseat vehicle defaults and the placement logic in this file.
]]
local M = {}
local multiseatConfiguration = require("ge/extensions/ui/multiseat/multiseatConfiguration")

M.dependencies = {
  "gameplay_city",
  "gameplay_parking",
  "gameplay_traffic",
  "ui_multiseat_multiseatSettings",
  "ui_multiseat_multiseatVehicles",
}

local PARKING_CLUSTER_RADIUS = 30

local active = false
local reloadRestorePending = false

local function assignSuggestedVehicles(levelName, participants)
  local vehicles = ui_multiseat_multiseatVehicles.getSuggestedVehicles(levelName, #participants)
  for index, participant in ipairs(participants) do
    local vehicle = vehicles[index]
    local player = participant.assignment.playerIndex
    if not vehicle or not ui_multiseat_multiseatVehicles.setPlayerVehicleSelection(player, vehicle) then
      return false
    end
  end
  return true
end

local function getFilteredParkingSpots(parkingSpots)
  return gameplay_parking.filterParkingSpots(parkingSpots, {
    checkVehicles = true,
    standardSize = true,
    useProbability = false,
  })
end

local function buildParkingSpawnPlan(players)
  local allParkingSpots = gameplay_parking.getParkingSpots()
  if not allParkingSpots or not allParkingSpots.sorted or #allParkingSpots.sorted == 0 then return nil end

  local anchorData = {}
  for _, parkingSpot in ipairs(allParkingSpots.sorted) do
    anchorData[#anchorData + 1] = {
      ps = parkingSpot,
      squaredDistance = 0,
    }
  end
  getFilteredParkingSpots(anchorData)
  arrayShuffle(anchorData)

  for _, anchor in ipairs(anchorData) do
    local nearby = gameplay_parking.findParkingSpots(anchor.ps.pos, 0, PARKING_CLUSTER_RADIUS)
    getFilteredParkingSpots(nearby)
    if #nearby >= #players then
      local selectedSpots = {}
      for index = 1, #players do
        selectedSpots[index] = nearby[index].ps
      end
      arrayShuffle(selectedSpots)

      local spawnPlan = {}
      for index, player in ipairs(players) do
        spawnPlan[index] = {
          player = player,
          parkingSpot = selectedSpots[index],
        }
      end
      return spawnPlan
    end
  end
end

local function buildLevelSpawnPlan(players)
  if not mainLevel or type(mainLevel.getMultiseatSpawnPositions) ~= "function" then return nil end

  local ok, positions = pcall(mainLevel.getMultiseatSpawnPositions, #players)
  if not ok or type(positions) ~= "table" or #positions < #players then
    log("W", "multiseatFreeroam", "Level multiseat spawn function did not return one position per player")
    return nil
  end

  local spawnPlan = {}
  for index, player in ipairs(players) do
    local position = positions[index]
    if type(position) ~= "table" then return nil end

    if position.parkingSpot then
      spawnPlan[index] = {player = player, parkingSpot = position.parkingSpot}
    elseif type(position.moveResetVehicleTo) == "function" then
      spawnPlan[index] = {player = player, parkingSpot = position}
    elseif position.pos and position.rot then
      spawnPlan[index] = {player = player, pos = position.pos, rot = position.rot}
    else
      log("W", "multiseatFreeroam", "Level multiseat spawn function returned an invalid position")
      return nil
    end
  end
  return spawnPlan
end

function M.activate()
  if career_career and career_career.isActive and career_career.isActive() then
    active = false
    return
  end
  extensions.load("gameplay_multiseat_gamemodeManager")
  active = true
end

function M.deactivate()
  active = false
  reloadRestorePending = false
end

function M.isActive()
  return active
end

function M.restoreAfterReload()
  active = true
  reloadRestorePending = true
  log("I", "multiseatReload", "freeroam restore queued")
end

function M.startSplitscreenFreeroam(levelName)
  local participants = core_multiseat.getJoinedParticipants()
  if #participants == 0 then return false, "no_players" end
  if not assignSuggestedVehicles(levelName, participants) then return false, "vehicle_assignment_failed" end

  local players = {}
  for _, participant in ipairs(participants) do
    players[#players + 1] = participant.assignment.playerIndex
  end

  local spawnPlan = buildLevelSpawnPlan(players) or buildParkingSpawnPlan(players)
  local success, reason
  if spawnPlan then
    local spawned = ui_multiseat_multiseatVehicles.spawnAll(spawnPlan)
    success = #spawned == #spawnPlan
    reason = success and nil or "vehicle_spawn_failed"
    if not success then ui_multiseat_multiseatVehicles.removeAll() end
  else
    log("W", "multiseatFreeroam", "No nearby parking cluster found; placing vehicles on the road")
    success, reason = ui_multiseat_multiseatVehicles.reconcileFreeroamVehicles()
  end

  if success then M.activate() end
  return success, reason
end

function M.openSettings()
  multiseatConfiguration.begin({source = "settings"})
  if extensions.ui_router.navigate("pause.multiseatSettings") == false then
    multiseatConfiguration.discard()
    return false
  end
  return true
end

function M.onMultiseatSettingsApplied(changeSet, result)
  if career_career and career_career.isActive and career_career.isActive() then
    active = false
    if render_splitScreen and render_splitScreen.refreshLayout then
      render_splitScreen.refreshLayout()
    end
    return
  end
  if result.success == false then return end
  if result.exitAfterApply == true then return end
  local players = core_multiseat.getJoinedPlayers()

  M.activate()

  if #players > 1 then
    extensions.load("render_splitScreen")
    if render_splitScreen and render_splitScreen.setCustomPlayers then
      render_splitScreen.setCustomPlayers(players)
    end
    extensions.load("gameplay_traffic_source")
    gameplay_traffic_source.autoAddPlayers()
  else
    extensions.unload("render_splitScreen")
    if gameplay_traffic_source then gameplay_traffic_source.resetSources() end
    extensions.unload("gameplay_traffic_source")
  end

  extensions.ui_menuManager.closeMenu()
end

-- back to regular single player freeroam: keep one vehicle for player 0, remove the rest
function M.exitMultiseat(options)
  options = type(options) == "table" and options or {}
  local cachedAssignments = core_multiseat.getCachedPlayerAssignments
    and core_multiseat.getCachedPlayerAssignments() or nil
  log("I", "multiseatAssignmentCache", "exit multiseat: explicitCache="
    .. tostring(options.assignmentCache ~= nil) .. " cachedBefore=" .. dumps(cachedAssignments))
  -- stopping the gamemode hands the session back to freeroam, which is what gets torn down below
  if gameplay_multiseat_gamemodeManager and gameplay_multiseat_gamemodeManager.isActive() then
    gameplay_multiseat_gamemodeManager.stop()
  end
  if not active then return false end

  if options.assignmentCache then
    if not core_multiseat.cachePlayerAssignments
      or not core_multiseat.cachePlayerAssignments(options.assignmentCache)
    then
      return false
    end
  end
  if gameplay_drag_dragBridge then
    gameplay_drag_dragBridge.stopDragRace()
    guihooks.trigger("onDragRaceTimeslipData", nil)
    guihooks.trigger("onDragReset")
  end
  local crawlTrail = gameplay_crawl_general and gameplay_crawl_general.activeTrail
  if crawlTrail and not crawlTrail.isFromMission then
    gameplay_crawl_utils.stopCrawl(true)
  end

  multiseatConfiguration.discard()
  if core_multiseat.isConfigurationEditActive and core_multiseat.isConfigurationEditActive() then
    core_multiseat.endConfigurationEdit(
      core_input_bindings and core_input_bindings.devices or nil,
      core_input_bindings and core_input_bindings.getAssignedPlayers() or nil
    )
  end
  local keepVeh = ui_multiseat_multiseatVehicles.abandonPlayerVehicle(0)
  ui_multiseat_multiseatVehicles.removeAll()
  ui_multiseat_multiseatVehicles.clearSession()
  core_multiseat.clearJoinedPlayers()
  core_multiseat.setPersonaOptInMode(false)
  core_multiseat.setMultiseatActive(false)
  extensions.unload("render_splitScreen")
  if gameplay_traffic_source then gameplay_traffic_source.resetSources() end
  extensions.unload("gameplay_traffic_source")
  settings.setValue("multiseat", false)
  if keepVeh then
    be:enterVehicle(0, keepVeh)
    commands.setGameCamera()
    core_camera.resetCamera(0)
  end
  if core_input_bindings and core_input_bindings.refreshAssignedPlayers then
    core_input_bindings.refreshAssignedPlayers(false, true)
  end

  M.deactivate()
  return true
end

function M.onMultiseatSettingsClosed()
end

function M.onPauseHomeRailBuildMultiseatActions(actions, _context, registerButton)
  if career_career and career_career.isActive and career_career.isActive() then
    return -- CareerSplitScreen manages its own split-screen pause buttons in Career mode
  end
  -- these stay available while a gamemode owns the session, so they cannot key off `active`
  local gamemodeActive = gameplay_multiseat_gamemodeManager and gameplay_multiseat_gamemodeManager.isActive()
  if not active and not gamemodeActive then return end
  actions[#actions + 1] = registerButton({
    id = "home.changeMultiseatSettings",
    label = _tr("ui.multiseat.settings.title"),
    icon = "splitScreen",
    visible = true,
    enabled = true,
  }, function()
    return extensions.ui_router.navigate("pause.multiseatSettings") ~= false
  end)
  actions[#actions + 1] = registerButton({
    id = "home.exitMultiseat",
    label = _tr("ui.multiseat.exit"),
    icon = "abandon",
    flavor = "danger",
    confirmText = _tr("ui.multiseat.confirmExit"),
    visible = true,
    enabled = true,
  }, function()
    if not M.exitMultiseat() then return false end
    return extensions.ui_router.navigate("play") ~= false
  end)
end

local function onSerialize(reason)
  local gamemodeActive = gameplay_multiseat_gamemodeManager and gameplay_multiseat_gamemodeManager.isActive()
  if not active and not gamemodeActive then
    log("I", "multiseatReload", "freeroam serialize skipped: session inactive")
    return
  end
  log("I", "multiseatReload", string.format(
    "freeroam serialize: reason=%s active=%s gamemodeActive=%s",
    tostring(reason),
    tostring(active),
    tostring(gamemodeActive == true)
  ))
  return {restoreAsFreeroam = true}
end

local function onDeserialized(data)
  if type(data) == "table" and data.restoreAsFreeroam == true then
    log("I", "multiseatReload", "freeroam deserialize: restore marker received")
    M.restoreAfterReload()
  else
    log("I", "multiseatReload", "freeroam deserialize skipped: no restore marker")
  end
end

local function onUiReady()
  if not reloadRestorePending then return end

  multiseatConfiguration.discard()
  settings.setValue("multiseat", true)
  core_multiseat.setMultiseatActive(true)
  if gameplay_multiseat_gamemodeManager then
    gameplay_multiseat_gamemodeManager.stop()
  end

  local players = core_multiseat.getJoinedPlayers()
  if #players > 1 then
    extensions.load("render_splitScreen")
    if render_splitScreen and render_splitScreen.setCustomPlayers then
      render_splitScreen.setCustomPlayers(players)
    end
    extensions.load("gameplay_traffic_source")
    gameplay_traffic_source.autoAddPlayers()
  end

  extensions.ui_menuManager.setGameplayRoute("multiseat")
  local route = extensions.ui_router.getCurrent()
  local routeName = route and route.resolved and route.resolved.name or nil
  local navigationResult = extensions.ui_router.reload("multiseat", nil, {force = true})
  log("I", "multiseatReload", string.format(
    "freeroam UI-ready restore: players=%d multiseatSetting=%s previousRoute=%s navigationResult=%s",
    #players,
    tostring(settings.getValue("multiseat") == true),
    tostring(routeName),
    tostring(navigationResult and navigationResult.result)
  ))
  if navigationResult and navigationResult.result == true then
    reloadRestorePending = false
    log("I", "multiseatReload", "freeroam post-restore complete")
  else
    log("E", "multiseatReload", "Could not restore the multiseat UI route")
  end
end

function M.onClientEndMission()
  M.deactivate()
  reloadRestorePending = false
end

M.onUiReady = onUiReady
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
