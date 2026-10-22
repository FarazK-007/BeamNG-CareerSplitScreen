-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'gameplay_missions_missions', 'gameplay_missions_missionManager','freeroam_bigMapMode', 'gameplay_playmodeMarkers', 'freeroam_bigMapPoiProvider','ui_missionInfo'}

local im = ui_imgui
local playerPrompts = {}
local skipIconFading = false
-- detect player velocity
local lastPosition = vec3(0,0,0)
local lastVel
local tmpVec = vec3()
local garageBorderClr = {1,0.5,0.5}
local forceReevaluateOpenPrompt = true
local markersVisibleTemporary = true

local vel = vec3()
local lastPositions = {}
local function getVelocity(dtSim, position, pIdx)
  if not position then return 0 end
  pIdx = pIdx or 0
  local lp = lastPositions[pIdx]
  if not lp then
    lp = vec3(position)
    lastPositions[pIdx] = lp
    return 0
  end

  local curVel = 0
  if dtSim > 0 then
    vel:setSub2(position, lp)
    curVel = vel:length() / dtSim
  end
  lp:set(position)
  return curVel
end

local function inverseLerp(min, max, value)
 if math.abs(max - min) < 1e-30 then return min end
 return (value - min) / (max - min)
end


local atParkingSpeed, atParkingSpeedPrev
local parkingSpeedMin, parkingSpeedMax = 1/3.6, 3/3.6
local function getParkingSpeedFactor(playerVelocity)
  if playerVelocity < parkingSpeedMin then atParkingSpeed =  true end
  if playerVelocity > parkingSpeedMax then atParkingSpeed = false end
  if atParkingSpeed == nil    then atParkingSpeed = playerVelocity < parkingSpeedMin end
  local atParkingSpeedChanged = atParkingSpeed ~= atParkingSpeedPrev
  atParkingSpeedPrev = atParkingSpeed
  return clamp(inverseLerp(parkingSpeedMin*1.25, parkingSpeedMin*0.75, playerVelocity),0,1), atParkingSpeed, atParkingSpeedChanged
end

local atCruisingSpeed, atCruisingSpeedPrev
local CruisingSpeedMin, CruisingSpeedMax = 20/3.6, 30/3.6
local function getCruisingSpeedFactor(playerVelocity)
  if playerVelocity < CruisingSpeedMin then atCruisingSpeed =  false end
  if playerVelocity > CruisingSpeedMax then atCruisingSpeed = true end
  if atCruisingSpeed == nil    then atCruisingSpeed = playerVelocity > CruisingSpeedMin end
  local atCruisingSpeedChanged = atCruisingSpeed ~= atCruisingSpeedPrev
  atCruisingSpeedPrev = atCruisingSpeed
  return (atCruisingSpeed and 1 or 0), atCruisingSpeed, atCruisingSpeedChanged
end


local currentInteractableElements = {}

local function isCareerModeActive()
  return (career_career and career_career.isActive and career_career.isActive())
    or (overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive())
    or (core_gamestate and core_gamestate.state and (core_gamestate.state.state == "career" or core_gamestate.state.state == "overhaul"))
end

local function getCurrentInteractableElements()
  return currentInteractableElements
end
M.getCurrentInteractableElements = getCurrentInteractableElements

M.formatMission = function(m)
  local info = {
    id = m.id,
    name = m.name,
    description = m.description,
    preview = m.previewFile,
    missionTypeLabel = m.missionTypeLabel or mission.missionType,
    userSettings = m:getUserSettingsData() or {},
    defaultUserSettings = m.defaultUserSettings or {},
    additionalAttributes = {},
    progress = m.saveData.progress,
    currentProgressKey = m.currentProgressKey or m.defaultProgressKey,
    unlocks = gameplay_missions_unlocks.constructUnlocksField(m),
    hasUserSettingsUnlocked = gameplay_missions_progress.missionHasUserSettingsUnlocked(m.id),
    devMission = m.devMission,
    tutorialActive = (career_career and career_career.isActive and career_career.isActive() and career_modules_tutorial and career_modules_tutorial.isActive and career_modules_tutorial.isActive()) or nil,
  }

  info.hasUserSettings = #info.userSettings > 0
  local additionalAttributes, additionalAttributesSortedKeys = gameplay_missions_missions.getAdditionalAttributes()

  for _, attKey in ipairs(additionalAttributesSortedKeys) do
    local att = additionalAttributes[attKey]
    local mAttKey = m.additionalAttributes[attKey]
    local val
    if type(mAttKey) == 'string' then
      val = att.valuesByKey[m.additionalAttributes[attKey]]
    elseif type(mAttKey) == 'table' then
      val = m.additionalAttributes[attKey]
    end
    if val then
      table.insert(info.additionalAttributes, {
        icon = att.icon or "",
        labelKey = att.translationKey,
        valueKey = val.translationKey
      })
    end
  end
  for _, customAtt in ipairs(m.customAdditionalAttributes or {}) do
    table.insert(info.additionalAttributes, customAtt)
  end
  info.formattedProgress =  gameplay_missions_progress.formatSaveDataForUi(m.id)
  info.leaderboardKey = m.defaultLeaderboardKey or 'recent'

  --info.gameContextUiButtons = {}
  info.gameContextUiButtons = m.getGameContextUiButtons and m:getGameContextUiButtons()
  return info
end
M.formatDataForUi = function()
  if not M.isStateWithPlaymodeMarkers() then return nil end
  local dataToSend = {}
  if not currentInteractableElements then return end
  for _, m in ipairs(currentInteractableElements or {}) do
    if m.missionId then
      table.insert(dataToSend, M.formatMission(gameplay_missions_missions.getMissionById(m.missionId)))
    end
  end
  table.sort(dataToSend, gameplay_missions_unlocks.depthIdSort)

  return dataToSend
end

M.startMissionById = function(id, userSettings, startingOptions)
log("E","","Deprecated startMissionById")
  print(debug.tracesimple())
end

M.stopMissionById = function(id, force)
  log("E","","Deprecated stopMissionById")
  print(debug.tracesimple())
end

M.changeUserSettings = function(id, settings)
  log("E","","Deprecated changeUserSettings")
  print(debug.tracesimple())
end

local preselectedMissionId = nil
M.setPreselectedMissionId = function(mId)
  preselectedMissionId = mId
end


local function getGameContext(fromMissionMenu)
  return gameplay_missions_missionScreen.getMissionScreenData()
end
M.getGameContext = getGameContext


local promptData = {}

local sortActivityData = function(a, b)
  -- Check if elements have a sorting table
  local hasSortingA = a.sorting ~= nil
  local hasSortingB = b.sorting ~= nil

  if hasSortingA and not hasSortingB then
    return true
  elseif not hasSortingA and hasSortingB then
    return false
  elseif hasSortingA and hasSortingB then
    -- Both have a sorting table; prioritize by type
    if a.sorting.type == "mission" and b.sorting.type ~= "mission" then
      return true
    elseif a.sorting.type ~= "mission" and b.sorting.type == "mission" then
      return false
    elseif a.sorting.type ~= b.sorting.type then
      return a.sorting.type < b.sorting.type
    else
      -- Same type; sort by order
      if (a.sorting.order or 0) == (b.sorting.order or 0) then
        return (a.sorting.id or a.heading) < (b.sorting.id or b.heading)
      end
      return (a.sorting.order or 0) < (b.sorting.order or 0)
    end
  else
    -- Neither have a sorting table; sort by heading
    return (a.heading or "") < (b.heading or "")
  end
end

local function openViewDetailPrompt(elemData)
  local activityData = {}
  extensions.hook("onActivityAcceptGatherData", elemData, activityData)

  table.sort(activityData, sortActivityData)
  --for _, a in ipairs(activityData) do
  --  dump(a.heading, (a.sorting and a.sorting.type) or "no type", a.sorting)
  --end
  ui_missionInfo.openActivityAcceptDialogue(activityData)
  --guihooks.trigger('ActivityAcceptUpdate', activityData)
end

local function onSelectDetailPromptClicked(idx)
  ui_missionInfo.closeDialogue()
  guihooks.trigger('ActivityAcceptUpdate', nil)
  local prompt = promptData[idx]
  if prompt and prompt.buttonFun then
    prompt.buttonFun()
  end
  table.clear(promptData)
end
M.onSelectDetailPromptClicked = onSelectDetailPromptClicked


local function closeViewDetailPrompt(force)
  if force then
    ui_missionInfo.closeDialogue()
    guihooks.trigger("onMissionAvailabilityChanged", {missionCount = 0})
    guihooks.trigger('ActivityAcceptUpdate', nil)
    extensions.hook("onMissionAvailabilityChanged", {missionCount = 0})
  end
end

local screenWidth, screenHeight, screenRatio = 1,1,1
local function onSettingsChanged()
  local vm = GFXDevice.getVideoMode()
  screenWidth = vm.width
  screenHeight = vm.height
  screenRatio = screenWidth / screenHeight
end
M.onSettingsChanged = onSettingsChanged

local p1, p2, p3, p4, p5, p6, p7, p8 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local bbPoints = {}
local function getBBPoints(bbCenter, bbAxis0, bbAxis1, bbAxis2)
  p1:set(bbCenter) p1:setAdd(bbAxis0) p1:setAdd(bbAxis1) p1:setSub(bbAxis2)
  p2:set(bbCenter) p2:setAdd(bbAxis0) p2:setAdd(bbAxis1) p2:setAdd(bbAxis2)
  p3:set(bbCenter) p3:setSub(bbAxis0) p3:setAdd(bbAxis1) p3:setAdd(bbAxis2)
  p4:set(bbCenter) p4:setSub(bbAxis0) p4:setAdd(bbAxis1) p4:setSub(bbAxis2)
  p5:set(bbCenter) p5:setAdd(bbAxis0) p5:setSub(bbAxis1) p5:setSub(bbAxis2)
  p6:set(bbCenter) p6:setAdd(bbAxis0) p6:setSub(bbAxis1) p6:setAdd(bbAxis2)
  p7:set(bbCenter) p7:setSub(bbAxis0) p7:setSub(bbAxis1) p7:setAdd(bbAxis2)
  p8:set(bbCenter) p8:setSub(bbAxis0) p8:setSub(bbAxis1) p8:setSub(bbAxis2)
  bbPoints[1] = p1; bbPoints[2] = p2; bbPoints[3] = p3; bbPoints[4] = p4;
  bbPoints[5] = p5; bbPoints[6] = p6; bbPoints[7] = p7; bbPoints[8] = p8;
  return bbPoints
end

local veh

local updateData = {}
local decals = {}
local nearbyIds = {}
local quadTreeSettings = {}
local clustersById = {}
local clustersByIdGen = -1

local function getClusterById(id)
  if not id then return nil end
  local gen = (gameplay_rawPois and gameplay_rawPois.getRawPoiGeneration and gameplay_rawPois.getRawPoiGeneration()) or 0
  if clustersByIdGen ~= gen or not clustersById[id] then
    table.clear(clustersById)
    clustersByIdGen = gen
    if gameplay_playmodeMarkers and gameplay_playmodeMarkers.getPlaymodeClusters then
      local ok, clusters = pcall(gameplay_playmodeMarkers.getPlaymodeClusters)
      if ok and clusters and type(clusters) == "table" then
        for _, c in ipairs(clusters) do
          if c and c.id then
            clustersById[c.id] = c
          end
        end
      end
    end
  end
  return clustersById[id]
end

if gameplay_playmodeMarkers then
  gameplay_playmodeMarkers.getClusterById = getClusterById
end

local interactableElements = {}

local lastCamPos = vec3()
local lastCamVel = vec3()
local playerVelLast = vec3()
local timeSincePlayerTeleport

local markerVisibilityBySetting = {}

local multiseatUpdateDataByPlayer = {}
local multiseatPlayerData = {}
local multiseatPlayers = {}
local multiseatActiveMarkers = {}
local multiseatMarkerGeneration = -1
local multiseatInteractionActive = false

local function displayMultiseatTriggers(dtReal)
  local markerGeneration = gameplay_rawPois.getRawPoiGeneration()
  if multiseatMarkerGeneration ~= markerGeneration then
    table.clear(multiseatActiveMarkers)
    multiseatMarkerGeneration = markerGeneration
  end
  table.clear(multiseatPlayerData)
  local clusterQt = gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree()
  local maxRadius = 100

  core_multiseat.getPlayers(multiseatPlayers)
  for _, playerIndex in ipairs(multiseatPlayers) do
    local playerVehicle = getPlayerVehicle(playerIndex)
    if playerVehicle then
      local data = multiseatUpdateDataByPlayer[playerIndex]
      if not data then
        data = {
          vehPos = vec3(),
          vehPos2d = vec3(),
          vehVelocity = vec3(),
          nearbyIds = {},
        }
        multiseatUpdateDataByPlayer[playerIndex] = data
      end

      data.playerIndex = playerIndex
      data.veh = playerVehicle
      data.vehPos:set(playerVehicle:getPositionXYZ())
      data.vehPos2d:set(data.vehPos)
      data.vehPos2d.z = 0
      data.vehVelocity:set(playerVehicle:getVelocityXYZ())
      data.isWalking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking(playerIndex) or false
      data.dt = dtReal
      table.clear(data.nearbyIds)

      for id in clusterQt:queryNotNested(
        data.vehPos.x - maxRadius,
        data.vehPos.y - maxRadius,
        data.vehPos.x + maxRadius,
        data.vehPos.y + maxRadius
      ) do
        data.nearbyIds[id] = true
      end
      table.insert(multiseatPlayerData, data)
    end
  end

  for _, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    local marker = multiseatActiveMarkers[cluster.id]
    local isNearby = false
    for _, data in ipairs(multiseatPlayerData) do
      if data.nearbyIds[cluster.id] then
        marker = marker or gameplay_playmodeMarkers.getMarkerForCluster(cluster)
        multiseatActiveMarkers[cluster.id] = marker
        if marker.interactWhileMoving then
          marker:interactWhileMoving(data)
        end
        isNearby = true
      end
    end
    if not isNearby and marker then
      marker:hide()
      multiseatActiveMarkers[cluster.id] = nil
    end
  end
end

local function getPlayerDataForInteraction(pIdx, dtSim)
  local playerVehicle = getPlayerVehicle(pIdx)
  if not playerVehicle then return nil end

  local pData = {
    playerIndex = pIdx,
    veh = playerVehicle,
    vehPos = vec3(playerVehicle:getPositionXYZ()),
    vehPos2d = vec3(playerVehicle:getPositionXYZ()),
    vehVelocity = vec3(playerVehicle:getVelocityXYZ()),
  }
  pData.vehPos2d.z = 0

  local vehId = playerVehicle:getID()
  pData.bbCenter = vec3(be:getObjectOOBBCenterXYZ(vehId))
  pData.bbHalfAxis0 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
  pData.bbHalfAxis1 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
  pData.bbHalfAxis2 = vec3(be:getObjectOOBBHalfAxisXYZ(vehId, 2))
  pData.bbPoints = getBBPoints(pData.bbCenter, pData.bbHalfAxis0, pData.bbHalfAxis1, pData.bbHalfAxis2)

  local isWalking = (playerVehicle.getJBeamFilename and playerVehicle:getJBeamFilename() == "unicycle")
    or (gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking(pIdx)) or false
  pData.isWalking = isWalking

  local speed = (playerVehicle.getVelocity and playerVehicle:getVelocity():len()) or 0
  pData.canInteract = isWalking or (speed <= 1.5)
  pData.playerPosition = pData.vehPos
  pData.dt = 0
  return pData
end

local function isPlayerActuallyInsideMarker(marker, pData)
  if not marker or not pData then return false end

  -- 1. walkingMarker (doors / dealership / garage computer)
  if marker.doors then
    if not pData.isWalking then return false end
    for _, area in ipairs(marker.doors) do
      if area.areaPos and area.xVec and area.yVec and area.zVec and pData.bbCenter and pData.bbHalfAxis0 then
        if overlapsOBB_OBB(pData.bbCenter, pData.bbHalfAxis0, pData.bbHalfAxis1, pData.bbHalfAxis2, area.areaPos, area.xVec, area.yVec, area.zVec) then
          return true
        end
      end
      if area.iconPos and pData.vehPos and pData.vehPos:distance(area.iconPos) <= 2.5 then
        return true
      end
    end
    return false
  end

  -- 2. missionMarker
  if marker.playerIsInArea then
    return marker:playerIsInArea(pData) == true
  end

  -- 3. parkingMarker (parking spots, garage deliveries)
  if marker.checkParking and marker.pos then
    if pData.isWalking then return false end
    local dist = pData.vehPos:distance(marker.pos)
    if dist > (marker.radius or 12) then return false end
    if marker.xVec and marker.yVec and marker.zVec and pData.bbCenter and pData.bbHalfAxis0 then
      if marker.mode == "contained" then
        return containsOBB_OBB(marker.pos, marker.xVec, marker.yVec, marker.zVec, pData.bbCenter, pData.bbHalfAxis0, pData.bbHalfAxis1, pData.bbHalfAxis2)
      else
        return overlapsOBB_OBB(marker.pos, marker.xVec, marker.yVec, marker.zVec, pData.bbCenter, pData.bbHalfAxis0, pData.bbHalfAxis1, pData.bbHalfAxis2)
      end
    end
    return dist <= 3.5
  end

  -- 4. zoneMarker
  if marker.zones then
    if pData.isWalking then return false end
    for _, z in ipairs(marker.zones) do
      if z and z.containsPoint2D and pData.bbPoints and pData.bbPoints[1] then
        if z:containsPoint2D(pData.bbPoints[1]) then return true end
      end
    end
    return false
  end

  -- 5. Gas station or generic trigger with pos/radius
  if marker.pos and pData.vehPos then
    local r = marker.radius or 5.0
    return pData.vehPos:distance(marker.pos) <= r
  end

  if marker.cluster and marker.cluster.pos and pData.vehPos then
    local r = marker.cluster.radius or 5.0
    return pData.vehPos:distance(marker.cluster.pos) <= r
  end

  return false
end

local function formatControlName(control, isGamepad)
  if not control or control == "" then return "" end
  local c = string.lower(control)
  if c == "btn_a" then return "(A)" end
  if c == "btn_b" then return "(B)" end
  if c == "btn_x" then return "(X)" end
  if c == "btn_y" then return "(Y)" end
  if c == "btn_l" then return "[LB]" end
  if c == "btn_r" then return "[RB]" end
  if c == "trigger_l" then return "[LT]" end
  if c == "trigger_r" then return "[RT]" end
  if c == "thumbl" then return "[LS]" end
  if c == "thumbr" then return "[RS]" end
  if c == "btn_start" then return "[Start]" end
  if c == "btn_back" or c == "btn_select" then return "[Back]" end
  if c == "upov" then return "[D-Pad Up]" end
  if c == "dpov" then return "[D-Pad Down]" end
  if c == "lpov" then return "[D-Pad Left]" end
  if c == "rpov" then return "[D-Pad Right]" end
  if c == "return" or c == "enter" then return "[Enter]" end
  if c == "space" then return "[Space]" end
  if c:match("^btn_%d+$") then
    local num = c:match("(%d+)")
    return "[Button " .. tostring(num) .. "]"
  end
  return "[" .. string.upper(control) .. "]"
end

local function getInteractKeyPromptForPlayer(playerIndex)
  playerIndex = playerIndex or 0
  local foundControls = {}
  local seenControls = {}

  local assignedDevs = {}
  if core_multiseat and core_multiseat.getDeviceAssignments then
    local assignments = core_multiseat.getDeviceAssignments()
    if assignments and assignments[playerIndex] then
      for _, d in ipairs(assignments[playerIndex]) do
        if d.id then assignedDevs[d.id] = true end
      end
    end
  end

  local hasAssigned = next(assignedDevs) ~= nil

  if core_input_bindings and core_input_bindings.bindings then
    for _, device in ipairs(core_input_bindings.bindings) do
      local devname = device.devname
      local matchesPlayer = false
      if hasAssigned then
        matchesPlayer = assignedDevs[devname] == true
      else
        if playerIndex == 0 then
          matchesPlayer = (devname == "keyboard0" or devname == "mouse0" or devname == "xinput0")
        elseif playerIndex == 1 then
          matchesPlayer = (devname == "xinput1" or devname == "xinput0")
        end
      end

      if matchesPlayer and device.contents and device.contents.bindings then
        local isGamepad = string.find(devname, "xinput") or string.find(devname, "gamepad") or string.find(devname, "joystick")
        for _, b in ipairs(device.contents.bindings) do
          if b.action == "gameplay_interact" and b.control and not b.unused then
            local formatted = formatControlName(b.control, isGamepad)
            if formatted ~= "" and not seenControls[formatted] then
              seenControls[formatted] = true
              table.insert(foundControls, formatted)
            end
          end
        end
      end
    end
  end

  if #foundControls > 0 then
    return table.concat(foundControls, " / ")
  end

  if playerIndex == 0 then
    return "[E] / (A)"
  else
    return "(A)"
  end
end

local function evaluatePlayerInteractions(dtSim, clusterQt)
  if not clusterQt then return end
  local isSplit = (careerSplitScreen and careerSplitScreen.isActive and careerSplitScreen.isActive())
    or (core_multiseat and core_multiseat.isMultiseatActive and core_multiseat.isMultiseatActive())
  if not isSplit then
    table.clear(playerPrompts)
    return
  end

  local p0Veh = getPlayerVehicle(0)
  local p1Veh = getPlayerVehicle(1)
  if not p0Veh and not p1Veh then return end

  local activePlayers = {0}
  if p1Veh and p1Veh ~= p0Veh then
    table.insert(activePlayers, 1)
  end

  for _, pIdx in ipairs(activePlayers) do
    local pData = getPlayerDataForInteraction(pIdx, dtSim)
    if pData and pData.canInteract then
      local pInteractableElements = {}
      local searchRadius = 15
      for id in clusterQt:queryNotNested(pData.vehPos.x - searchRadius, pData.vehPos.y - searchRadius, pData.vehPos.x + searchRadius, pData.vehPos.y + searchRadius) do
        local cluster = getClusterById(id)
        if cluster then
          local marker = gameplay_playmodeMarkers and gameplay_playmodeMarkers.getMarkerForCluster and gameplay_playmodeMarkers.getMarkerForCluster(cluster)
          if marker and marker.interactInPlayMode then
            if isPlayerActuallyInsideMarker(marker, pData) then
              local savedOverlap = marker.anyOverlap
              local savedParked = marker.parked
              marker.anyOverlap = true
              marker.parked = true

              pcall(function()
                marker:interactInPlayMode(pData, pInteractableElements)
              end)

              marker.anyOverlap = savedOverlap
              marker.parked = savedParked
            end
          end
        end
      end

      if #pInteractableElements > 0 then
        local pActivityData = {}
        pcall(function()
          extensions.hook("onActivityAcceptGatherData", pInteractableElements, pActivityData)
        end)
        table.sort(pActivityData, sortActivityData)
        if #pActivityData > 0 then
          playerPrompts[pIdx] = pActivityData[1]
        else
          playerPrompts[pIdx] = nil
        end
      else
        playerPrompts[pIdx] = nil
      end
    else
      playerPrompts[pIdx] = nil
    end
  end
end

local function performInteract(targetPlayerIdx)
  if targetPlayerIdx ~= nil and playerPrompts[targetPlayerIdx] then
    local prompt = playerPrompts[targetPlayerIdx]
    if prompt and prompt.buttonFun then
      prompt.buttonFun()
      playerPrompts[targetPlayerIdx] = nil
      return true
    end
  end

  if playerPrompts[0] and playerPrompts[0].buttonFun then
    playerPrompts[0].buttonFun()
    playerPrompts[0] = nil
    return true
  elseif playerPrompts[1] and playerPrompts[1].buttonFun then
    playerPrompts[1].buttonFun()
    playerPrompts[1] = nil
    return true
  end

  return false
end

local function displayMissionMarkers(level, dtSim, dtReal)
  profilerPushEvent("MissionMarker precalc")
  local multiseatActive = core_multiseat
    and core_multiseat.isMultiseatActive
    and core_multiseat.isMultiseatActive()
    or false
  if isCareerModeActive() then
    multiseatActive = false -- Keep full marker interactions in Career mode!
  end
  if multiseatActive then
    if not multiseatInteractionActive then
      table.clear(currentInteractableElements)
      closeViewDetailPrompt(true)
      multiseatInteractionActive = true
    end
    displayMultiseatTriggers(dtReal)
    profilerPopEvent("MissionMarker precalc")
    return
  elseif multiseatInteractionActive then
    multiseatInteractionActive = false
    table.clear(multiseatActiveMarkers)
    forceReevaluateOpenPrompt = true
  end

  local activeMission = gameplay_missions_missionManager.getForegroundMissionId()
  local globalAlpha = 1
  if activeMission then
    globalAlpha = 0
  end
  local p0Veh = getPlayerVehicle(0)
  local p1Veh = nil
  if isCareerModeActive() then
    p1Veh = getPlayerVehicle(1)
  end

  local selectedVeh = p0Veh
  local selectedPlayerIdx = 0

  if p1Veh and p1Veh ~= p0Veh then
    local clusterQt = gameplay_playmodeMarkers and gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree and gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree()

    local p0Pos = p0Veh and p0Veh:getPosition()
    local p1Pos = p1Veh:getPosition()

    local p0Speed = (p0Veh and p0Veh.getVelocity and p0Veh:getVelocity():len()) or 0
    local p1Speed = (p1Veh.getVelocity and p1Veh:getVelocity():len()) or 0

    local p0IsWalking = (p0Veh and p0Veh.getJBeamFilename and p0Veh:getJBeamFilename() == "unicycle")
      or (gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking(0))
    local p1IsWalking = (p1Veh.getJBeamFilename and p1Veh:getJBeamFilename() == "unicycle")
      or (gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking(1))

    local p0Stopped = p0IsWalking or p0Speed <= 2.0
    local p1Stopped = p1IsWalking or p1Speed <= 2.0

    local p0NearDist = 999999
    local p1NearDist = 999999
    local searchRad = 15
    if clusterQt then
      if p0Pos then
        for id in clusterQt:queryNotNested(p0Pos.x - searchRad, p0Pos.y - searchRad, p0Pos.x + searchRad, p0Pos.y + searchRad) do
          local cl = getClusterById(id)
          if cl and cl.pos then
            local d = p0Pos:distance(cl.pos)
            if d < p0NearDist then p0NearDist = d end
          else
            p0NearDist = math.min(p0NearDist, 8)
          end
        end
      end
      if p1Pos then
        for id in clusterQt:queryNotNested(p1Pos.x - searchRad, p1Pos.y - searchRad, p1Pos.x + searchRad, p1Pos.y + searchRad) do
          local cl = getClusterById(id)
          if cl and cl.pos then
            local d = p1Pos:distance(cl.pos)
            if d < p1NearDist then p1NearDist = d end
          else
            p1NearDist = math.min(p1NearDist, 8)
          end
        end
      end
    end

    -- Player 0 (P1) is the HOST and ALWAYS has top priority if stopped/walking near a marker.
    -- Player 1 (P2) is only selected if Player 0 is NOT near a marker (or moving fast), AND Player 1 IS stopped/walking near a marker.
    local p0AtMarker = p0Stopped and (p0NearDist <= 12)
    local p1AtMarker = p1Stopped and (p1NearDist <= 12)

    if not p0AtMarker and p1AtMarker then
      selectedVeh = p1Veh
      selectedPlayerIdx = 1
    else
      selectedVeh = p0Veh
      selectedPlayerIdx = 0
    end
  end

  veh = selectedVeh

  if veh then
    updateData.veh = veh
    updateData.vehPos = updateData.vehPos or vec3()
    updateData.vehPos:set(veh:getPositionXYZ())
    updateData.vehPos2d = updateData.vehPos2d or vec3()
    updateData.vehPos2d:set(updateData.vehPos)
    updateData.vehPos2d.z = 0
    updateData.vehVelocity = updateData.vehVelocity or vec3()
    updateData.vehVelocity:set(veh:getVelocityXYZ())

    local vehId = veh:getID()
    updateData.bbCenter = updateData.bbCenter or vec3()
    updateData.bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
    updateData.bbHalfAxis0 = updateData.bbHalfAxis0 or vec3()
    updateData.bbHalfAxis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
    updateData.bbHalfAxis1 = updateData.bbHalfAxis1 or vec3()
    updateData.bbHalfAxis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
    updateData.bbHalfAxis2 = updateData.bbHalfAxis2 or vec3()
    updateData.bbHalfAxis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))

    updateData.bbPoints = getBBPoints(updateData.bbCenter, updateData.bbHalfAxis0, updateData.bbHalfAxis1, updateData.bbHalfAxis2)

    updateData.highestBBPointZ = math.max(updateData.bbPoints[2].z, math.max(updateData.bbPoints[3].z, math.max(updateData.bbPoints[6].z, updateData.bbPoints[7].z)))
  else
    updateData.veh = nil
  end

  updateData.playerPosition = veh and updateData.vehPos or updateData.camPos or vec3()


  local playerVelocity = 0
  if veh and veh.getVelocity then
    local vObj = veh:getVelocity()
    playerVelocity = vObj and vObj:len() or 0
  else
    playerVelocity = getVelocity(dtSim, updateData.playerPosition, selectedPlayerIdx)
  end

  if veh and veh.getJBeamFilename and veh:getJBeamFilename() == "unicycle" then
    updateData.isWalking = true
  elseif gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking(selectedPlayerIdx) then
    updateData.isWalking = true
  else
    updateData.isWalking = false
  end

  profilerPushEvent("MissionEnter parkingSpeedFactor")
  local parkingSpeedFactor, isAtParkingSpeed, parkingSpeedChanged = getParkingSpeedFactor(playerVelocity)
  local cruisingSpeedFactor, isAtcruisingSpeed, cruisingSpeedChanged = getCruisingSpeedFactor(playerVelocity)


  profilerPopEvent("MissionEnter parkingSpeedFactor")
  -- put reference for icon manager in
  updateData.parkingSpeedFactor = parkingSpeedFactor
  updateData.cruisingSpeedFactor = cruisingSpeedFactor
  updateData.dt = dtReal
  updateData.globalAlpha = globalAlpha
  updateData.camPos = updateData.camPos or vec3()
  updateData.camRot = updateData.camRot or quat()
  local ctxId = core_camera and core_camera.getContextIdForPlayer and core_camera.getContextIdForPlayer(selectedPlayerIdx)
  if ctxId and core_camera.getPositionXYZ(ctxId) then
    updateData.camPos:set(core_camera.getPositionXYZ(ctxId))
    updateData.camRot:set(core_camera.getQuatXYZW(ctxId))
  else
    updateData.camPos:set(core_camera.getPositionXYZ())
    updateData.camRot:set(core_camera.getQuatXYZW())
  end
  updateData.bigMapActive = freeroam_bigMapMode.bigMapActive()
  updateData.bigmapTransitionActive = freeroam_bigMapMode.isTransitionActive()
  updateData.isFreeCam = commands.isFreeCamera()
  updateData.windowAspectRatio = screenRatio
  updateData.screenHeight = screenHeight
  -- TODO: Clean this up
  table.clear(nearbyIds)
  -- hide all the markers behind the camera
  local maxRadius = 100
  profilerPushEvent("MissionEnter QTStuff")
      -- transitioning or normal play mode
  if   (not freeroam_bigMapMode.bigMapActive())
    or (freeroam_bigMapMode.bigMapActive() and freeroam_bigMapMode.isTransitionActive()) then
    local clusterQt = gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree()
    evaluatePlayerInteractions(dtSim, clusterQt)

    for id in clusterQt:queryNotNested(updateData.playerPosition.x-maxRadius, updateData.playerPosition.y-maxRadius, updateData.playerPosition.x+maxRadius, updateData.playerPosition.y + maxRadius) do
      nearbyIds[id] = true
    end

    if isCareerModeActive() then
      local p1Veh = getPlayerVehicle(1)
      if p1Veh and p1Veh ~= veh then
        local p1Pos = p1Veh:getPosition()
        for id in clusterQt:queryNotNested(p1Pos.x-maxRadius, p1Pos.y-maxRadius, p1Pos.x+maxRadius, p1Pos.y+maxRadius) do
          nearbyIds[id] = true
        end
      end
    end

    if updateData.isFreeCam then
      for id in clusterQt:queryNotNested(updateData.camPos.x-maxRadius, updateData.camPos.y-maxRadius, updateData.camPos.x+maxRadius, updateData.camPos.y + maxRadius) do
        nearbyIds[id] = true
      end
    end
  end

  if M.navigationPoiId  then
    nearbyIds[M.navigationPoiId] = true
  end

  profilerPopEvent("MissionEnter QTStuff")
  --table.clear(visibleIdsSorted)
  --tableKeys(visibleIds, visibleIdsSorted)
  --table.sort(visibleIdsSorted)
  profilerPopEvent("MissionEnter precalc")

  -- now cleared at the end
  --if not isAtParkingSpeed then
    --table.clear(currentInteractableElements)
  --end

  table.clear(decals)

  local decalCount = 0
  local careerActive = isCareerModeActive()
  local tutorialActive = gameplay_discover_freeroamTutorial_tutorial ~= nil
  table.clear(interactableElements)
  local showMissionMarkers = markersVisibleTemporary
  markerVisibilityBySetting.showMissionMarkers = (careerActive or tutorialActive or settings.getValue("showMissionMarkers"))
  --markerVisibilityBySetting.enableDragRaceInFreeroam = (careerActive or settings.getValue("enableDragRaceInFreeroam"))
  --markerVisibilityBySetting.enableDriftInFreeroam = (careerActive or settings.getValue("enableDriftInFreeroam"))
  --markerVisibilityBySetting.enableGasStationsInFreeroam = (careerActive or settings.getValue("enableGasStationsInFreeroam"))
  -- draw/show all visible markers.
  --[[
  if not timeSincePlayerTeleport then
    timeSincePlayerTeleport = objectTeleported(updateData.camPos, lastCamPos, playerVelLast, dtReal) and 0.5
  end
  if timeSincePlayerTeleport then
    timeSincePlayerTeleport = timeSincePlayerTeleport - dtReal
    if timeSincePlayerTeleport <= 0 then timeSincePlayerTeleport = nil end
  end]]
  --local testId = "parkingMarker#/levels/west_coast_usa/facilities/delivery/mechanics.sites.json#exhaustShop_parking"
  local anyMarkerIsInAreaChanged = false
  for i, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    local marker = gameplay_playmodeMarkers.getMarkerForCluster(cluster)
    if nearbyIds[cluster.id] or marker.focus then
      -- Check if the marker should be visible
      cluster.focus = cluster.focus or cluster.id == M.navigationPoiId
      local showMarker = not photoModeOpen
      and not (editor and editor.active)
      and (showMissionMarkers or cluster.focus)
      showMarker = showMarker and (not cluster.visibleBySetting or markerVisibilityBySetting[cluster.visibleBySetting] or cluster.focus)
      --dump(string.format("cluster %s, is nearby: %s, marker focus: %s, cluster focus: %s", cluster.id, nearbyIds[cluster.id], marker.focus, cluster.focus))
      --dump(string.format("cluster %s, is showMarker: %s", cluster.id, showMarker))
      --simpleDebugText3d(string.format("marker %s, is showMarker: %s", cluster.id, showMarker), cluster.pos)
      if showMarker then
        -- debug drawing for testing
        --debugDrawer:drawTextAdvanced(marker.pos, String(tostring(cluster.id)), ColorF(1,1,1,1), true, false, ColorI(0,0,0,192))
        --debugDrawer:drawSphere(cluster.pos, cluster.radius, ColorF(0.91,0.05,0.48,0.2))
        marker:show()
        marker:update(updateData)
        -- post-marker decals, so they can be all drawn at once

        -- TODO: optimize
        if marker.groundDecalData then
          if marker.groundDecalData.texture then
            decalCount = decalCount + 1
            decals[decalCount] = marker.groundDecalData
          else
            for _, decal in ipairs(marker.groundDecalData) do
              decalCount = decalCount + 1
              decals[decalCount] = decal
            end
          end
        end

        if veh then
          if not freeroam_bigMapMode.bigMapActive() and not activeMission and not
            (gameplay_drift_freeroam_driftSpots and gameplay_drift_freeroam_driftSpots.getIsInFreeroamChallenge()) then
            if marker.interactInPlayMode then
              local promptEmpty = not next(currentInteractableElements)
              local canInteract = isAtParkingSpeed and (forceReevaluateOpenPrompt or parkingSpeedChanged or promptEmpty)
              if updateData.isWalking then
                canInteract = marker.isInAreaChanged or forceReevaluateOpenPrompt or promptEmpty
                if marker.isInAreaChanged then
                  anyMarkerIsInAreaChanged = marker.isInAreaChanged
                end
              end

              updateData.canInteract = canInteract
              if updateData.canInteract then
                marker:interactInPlayMode(updateData, interactableElements)
              end
              --simpleDebugText3d(dumps(marker.cluster.clusterId), marker.cluster.pos, 0.25)
            end
            if marker.interactWhileMoving then
              marker:interactWhileMoving(updateData)
            end
          end
        end
      else
        marker:hide()
      end
    else
      marker:hide()
    end
  end
  lastCamPos:set(updateData.camPos)
  if veh then
    playerVelLast:set(be:getObjectVelocityXYZ(veh:getID()))
  end
  --print("Force forceReevaluateOpenPrompt " .. dumps(forceReevaluateOpenPrompt))
  forceReevaluateOpenPrompt = false
  if next(interactableElements) then
    table.clear(currentInteractableElements)
    for i, elem in ipairs(interactableElements) do
      currentInteractableElements[i] = elem
    end
    openViewDetailPrompt(interactableElements)
  end
  if not activeMission and not next(interactableElements) then
    if updateData.isWalking then
      if anyMarkerIsInAreaChanged == "out" then
        table.clear(currentInteractableElements)
        closeViewDetailPrompt(true)
      end
    elseif not isAtParkingSpeed or parkingSpeedChanged then
      table.clear(currentInteractableElements)
      closeViewDetailPrompt(parkingSpeedChanged)
    end
  end
  skipIconFading = false
  Engine.Render.DynamicDecalMgr.addDecals(decals, decalCount)
end

local pos2Offset = vec3(0, 0, 1000)
local columnColor = ColorF(1,1,1,1)
local function drawDistanceColumn(targetPos)
  local camPos = core_camera.getPosition()
  local dist = camPos:distance(targetPos)
  local radius = math.max(dist/400, 0.1)
  local targetPos2 = targetPos + pos2Offset
  local alpha = clamp((dist-50)/200, 0.1, 0.6)
  columnColor.alpha = alpha
  debugDrawer:drawCylinder(targetPos, targetPos2, radius, columnColor)
end

local function resetForceVisible()
  -- Set all markers forceVisible to false
  for i, cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do
    if string.startswith(cluster.id, "missionMarker") then
      cluster.focus = false
    end
  end

  M.reachedTargetPos = nil
  M.navigationPoiId = nil
end

local function reachedTarget()
  if not core_groundMarkers.clearPathOnReachingTarget then return end
  if settings.getValue("showMissionMarkers") or isCareerModeActive() then
    resetForceVisible()
  end
  M.reachedTargetPos = core_groundMarkers.endWP[1]
  extensions.hook("onReachedTargetPos")
  ui_message("bigmap.info.reachedTarget", nil, "bigmapTarget", "checkmark")
end


local function onPreRender(dtReal, dtSim)
  if not gameplay_playmodeMarkers.isStateWithPlaymodeMarkers() then
    gameplay_playmodeMarkers.clear()
    return
  end
  profilerPushEvent("MissionEnter onPreRender")
  profilerPushEvent("MissionEnter groundMarkers")
  -- Disable navigation when player is close to the goal
  if gameplay_missions_missionManager then
    if gameplay_missions_missionManager.getForegroundMissionId() == nil and core_groundMarkers.currentlyHasTarget() and core_groundMarkers.clearPathOnReachingTarget then
      if freeroam_bigMapMode and not freeroam_bigMapMode.bigMapActive() and type(core_groundMarkers.endWP[1]) == "cdata" then -- is vec3
        local nextFixedWP = core_groundMarkers.routePlanner:getNextFixedWP()
        if nextFixedWP then
          drawDistanceColumn(nextFixedWP)
        end
        --simpleDebugText3d(core_groundMarkers.getPathLength(),core_groundMarkers.getTargetPos(), 0.25)
        if core_groundMarkers.getPathLength() < 7 then
          reachedTarget()
        end
      end
    end
    if M.reachedTargetPos then
      local veh = getPlayerVehicle(0)
      if veh then
        local vehPos = veh:getPosition()
        if vehPos:distance(M.reachedTargetPos) > 20 then
          resetForceVisible()
        end
      end
    end
  end

  profilerPopEvent("MissionEnter groundMarkers")


  -- check if we've switched level
  local level = getCurrentLevelIdentifier()
  if level then
    profilerPushEvent("DisplayMissionMarkers")
    displayMissionMarkers(level, dtSim, dtReal)
    profilerPopEvent("DisplayMissionMarkers")
  end

  profilerPopEvent("MissionEnter onPreRender")

end


local function clearCache()
  M.setForceReevaluateOpenPrompt()
end


local function skipNextIconFading()
  skipIconFading = true
end

local function showMissionMarkersToggled(active)
  gameplay_rawPois.clear()
  freeroam_bigMapPoiProvider.forceSend()
end


local function onAnyMissionChanged(state)
  freeroam_bigMapPoiProvider.forceSend()
  if state == "started" then
    freeroam_bigMapMode.deselect()
    resetForceVisible()
    if ui_missionInfo.openState == "opened" then
      table.clear(currentInteractableElements)
      closeViewDetailPrompt(true)
    end
  end
end

local function onNavigateToMission(poiId)
  resetForceVisible()
  M.navigationPoiId = poiId
end



local function onClientEndMission(levelPath)
  M.navigationPoiId = nil
end

local function setMarkersVisibleTemporary(visible)
  markersVisibleTemporary = visible
end

M.closeViewDetailPrompt = closeViewDetailPrompt
M.showMissionMarkersToggled = showMissionMarkersToggled
M.setMarkersVisibleTemporary = setMarkersVisibleTemporary

M.restartCurrent = restartCurrent
M.abandonCurrent = abandonCurrent

M.skipNextIconFading = skipNextIconFading
M.onPreRender = onPreRender

M.getClusterMarker = getClusterMarker

M.onNavigateToMission = onNavigateToMission
M.onAnyMissionChanged = onAnyMissionChanged
M.onClientEndMission = onClientEndMission
M.clearCache = clearCache
M.setForceReevaluateOpenPrompt = function()
  forceReevaluateOpenPrompt = true
end

M.onUIPlayStateChanged = function(enteredPlay)
  if enteredPlay then
    M.setForceReevaluateOpenPrompt()
  end
end
local function drawInteractPromptForPlayer(player, prompt, rect, canvasPosX, canvasPosY, canvasSizeX, canvasSizeY)
  local cellW = rect[3] * canvasSizeX
  local cellH = rect[4] * canvasSizeY
  local cellX = canvasPosX + rect[1] * canvasSizeX
  local cellY = canvasPosY + rect[2] * canvasSizeY

  local heading = prompt.heading or "Interact"
  if _tr then
    heading = _tr(heading, heading)
  end

  local keyText = getInteractKeyPromptForPlayer(player)
  local keyDisplay = keyText
  if keyDisplay:sub(1, 1) == "[" and keyDisplay:sub(-1) == "]" then
    keyDisplay = keyDisplay:sub(2, -2)
  end

  local keySize = im.CalcTextSize(keyDisplay)
  local headingSize = im.CalcTextSize(heading)

  local boxH = 34
  local boxW = math.max(150, math.min(keySize.x + headingSize.x + 55, cellW - 40))

  -- Right-middle of player's screen
  local posX = cellX + cellW - boxW - 24
  local posY = cellY + (cellH - boxH) * 0.5

  im.SetNextWindowPos(im.ImVec2(posX, posY), im.Cond_Always)
  im.SetNextWindowSize(im.ImVec2(boxW, boxH), im.Cond_Always)

  if im.GetMainViewport and im.SetNextWindowViewport then
    local mainVp = im.GetMainViewport()
    if mainVp and mainVp.ID then
      im.SetNextWindowViewport(mainVp.ID)
    end
  end

  local flags = bit.bor(
    im.WindowFlags_NoTitleBar,
    im.WindowFlags_NoResize,
    im.WindowFlags_NoMove,
    im.WindowFlags_NoScrollbar,
    im.WindowFlags_NoCollapse,
    im.WindowFlags_NoInputs
  )
  if im.WindowFlags_NoDocking then
    flags = bit.bor(flags, im.WindowFlags_NoDocking)
  end

  -- Clean dark capsule pill styling matching BeamNG prompt style
  im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(12, 5))
  im.PushStyleVar1(im.StyleVar_WindowRounding, boxH * 0.5)
  im.PushStyleVar1(im.StyleVar_WindowBorderSize, 1)
  im.PushStyleColor1(im.Col_WindowBg, im.GetColorU322(im.ImVec4(0.11, 0.12, 0.15, 0.88)))
  im.PushStyleColor1(im.Col_Border, im.GetColorU322(im.ImVec4(0.30, 0.33, 0.38, 0.6)))

  local winTitle = "###SDF_InteractPrompt_" .. tostring(player)
  if im.Begin(winTitle, nil, flags) then
    -- Keycap badge container
    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(6, 2))
    im.PushStyleVar1(im.StyleVar_FrameRounding, 4)
    im.PushStyleVar1(im.StyleVar_FrameBorderSize, 1)
    im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.22, 0.25, 0.30, 0.95)))
    im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.22, 0.25, 0.30, 0.95)))
    im.PushStyleColor1(im.Col_ButtonActive, im.GetColorU322(im.ImVec4(0.22, 0.25, 0.30, 0.95)))
    im.PushStyleColor1(im.Col_Border, im.GetColorU322(im.ImVec4(0.65, 0.72, 0.82, 0.75)))
    im.PushStyleColor1(im.Col_Text, im.GetColorU322(im.ImVec4(0.96, 0.97, 0.98, 1.0)))

    im.Button(keyDisplay)

    im.PopStyleColor(5)
    im.PopStyleVar(3)

    im.SameLine()
    im.SetCursorPosY(im.GetCursorPosY() + 2)
    im.TextColored(im.ImVec4(0.92, 0.93, 0.96, 1.0), heading)
  end
  im.End()

  im.PopStyleColor(2)
  im.PopStyleVar(3)
end

local function drawPlayerInteractPrompts()
  if not render_splitScreen then return end
  local uiState = render_splitScreen.getUiState and render_splitScreen.getUiState()
  if not uiState or not uiState.layout or not uiState.players or #uiState.players <= 1 then return end
  if editor and editor.active then return end
  if freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive() then return end

  local cur = extensions.ui_router and extensions.ui_router.getCurrent()
  local rName = cur and (cur.resolved and cur.resolved.name or cur.request and cur.request.name or cur.name)
  if rName and (rName == "bigmap" or rName == "menu" or rName == "menu.careerPause" or string.find(rName, "^pause") or string.find(rName, "^menu%.")) then
    return
  end

  local canvas = scenetree.findObject("Canvas")
  if not canvas or not canvas.getWindowClientSizeXY then return end
  local canvasSizeX, canvasSizeY = canvas:getWindowClientSizeXY()
  if not canvasSizeX or not canvasSizeY or canvasSizeX <= 0 or canvasSizeY <= 0 then return end

  local canvasPosX, canvasPosY = 0, 0
  if im.GetConfigFlagsViewportsEnable() and canvas.clientToScreenXY then
    canvasPosX, canvasPosY = canvas:clientToScreenXY(Point2I(0, 0))
    if not canvasPosX or not canvasPosY then return end
  end

  local pCount = math.min(#uiState.layout, #uiState.players)
  for pIdx = 1, pCount do
    local player = uiState.players[pIdx].player
    local prompt = playerPrompts[player]
    local rect = uiState.layout[pIdx]
    if prompt and rect and player ~= nil then
      drawInteractPromptForPlayer(player, prompt, rect, canvasPosX, canvasPosY, canvasSizeX, canvasSizeY)
    end
  end
end

local function onUpdate(dtReal, dtSim)
  drawPlayerInteractPrompts()
end

M.onUpdate = onUpdate
M.performInteract = performInteract

return M