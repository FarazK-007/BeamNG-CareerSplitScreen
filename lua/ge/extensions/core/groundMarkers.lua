-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min = math.min
local max = math.max
local abs = math.abs
local acos = math.acos
local ceil = math.ceil
local pi = math.pi

local M = {}
M.dependencies = {'core_groundMarkerArrows'}
M.routePlanner = require('/lua/ge/extensions/gameplay/route/route')()
M.debugPath = false
local pathRequestIdByPlayer = {}
local pathPendingByPlayer = {}
local pathPending = false

local decals = {}
local numDecals = 0

local upVec = vec3(0,0,1)
M.colorSet = 'blue'
M.colorSets = {
  blue = {
    decals = {0, 0.4, 1},
    arrows = {0, 0.48, 0.77},
  },
  green = {
    decals = {0, 1, 0},
    arrows = {0, 1, 0},
  },

}

local routePlannersByPlayer = {}
local endWPByPlayer = {}
routePlannersByPlayer[0] = M.routePlanner
M.targetPlayerIndex = 0
local lastGenerationPosByPlayer = {}

local function getRoutePlanner(playerIndex)
  playerIndex = playerIndex or 0
  if not routePlannersByPlayer[playerIndex] then
    routePlannersByPlayer[playerIndex] = require('/lua/ge/extensions/gameplay/route/route')()
  end
  return routePlannersByPlayer[playerIndex]
end

local function getTargetVeh(playerIndex)
  playerIndex = playerIndex or M.targetPlayerIndex or 0
  if playerIndex == 0 then
    return getPlayerVehicle(0)
  elseif playerIndex == 1 then
    if careerSplitScreen and careerSplitScreen.getP2Vehicle then
      local p2 = careerSplitScreen.getP2Vehicle()
      if p2 then return p2 end
    end
    return getPlayerVehicle(1)
  else
    return getPlayerVehicle(playerIndex)
  end
end

local function setTargetPlayer(playerIndex)
  playerIndex = tonumber(playerIndex) or 0
  M.targetPlayerIndex = playerIndex
  if playerIndex == 1 then
    M.color = {1, 0.5, 0}
    M.floatingArrowColor = {1, 0.6, 0.1}
  elseif playerIndex >= 2 then
    M.color = {0, 1, 0.3}
    M.floatingArrowColor = {0, 1, 0.4}
  else
    M.color = M.colorSets[M.colorSet] and M.colorSets[M.colorSet].decals or {0, 0.4, 1}
    M.floatingArrowColor = M.colorSets[M.colorSet] and M.colorSets[M.colorSet].arrows or {0, 0.48, 0.77}
  end

  M.routePlanner = getRoutePlanner(playerIndex)
  M.endWP = endWPByPlayer[playerIndex]

  if freeroam_bigMapMode and freeroam_bigMapMode.resetRoute then
    freeroam_bigMapMode.resetRoute()
  end
end
M.setTargetPlayer = setTargetPlayer
M.getTargetPlayer = function() return M.targetPlayerIndex or 0 end

-- global functions for backwards compatibility
local clearPathForPlayer
local deprecationWarningDone = {}
local function deprecationWarning(oldFunction, newFunction)
  if not deprecationWarningDone[oldFunction] then
    log('W', logTag, string.format('function "%s" is deprecated. Please use function "%s" instead', oldFunction, newFunction))
    deprecationWarningDone[oldFunction] = true
  end
end

local function getPathLength()
  if pathPending then return math.huge end
  if M.routePlanner.path and M.routePlanner.path[1] then
    return M.routePlanner.path[1].distToTarget
  end
  return 0
end

local function getPathPositionDirection(dist, lastNodeData)
  local walkDist = lastNodeData.dist
  for i = lastNodeData.i, (lastNodeData.pathSize - 1) do
    local a = lastNodeData.path[i].pos
    local b = lastNodeData.path[i + 1].pos
    local nodeDist = (b-a):length()
    if walkDist + nodeDist >= dist then
      local factor = (dist - walkDist) / nodeDist
      local position = (a * (1 - factor)) + (b * factor)
      local normal = (b-a):normalized()
      lastNodeData.i = i
      lastNodeData.dist = walkDist
      return position, normal
    else
      walkDist = walkDist + nodeDist
    end
  end
  lastNodeData.i = lastNodeData.pathSize
  lastNodeData.dist = walkDist
  return nil
end

local decalScale = 3
local function getNewData()
  -- create decals
  local data = {
    texture = 'art/shapes/arrows/arrow_groundmarkers_1.png',
    pos = vec3(),
    position = vec3(0, 0, 0),
    forwardVec = vec3(0, 0, 0),
    color = ColorF(M.color[1], M.color[2], M.color[3], 0 ),
    scale = vec3(0.5*decalScale, 1*decalScale, 2),
    fadeStart = 100,
    fadeEnd = 120
  }
  return data
end

local function calculateAlpha(pos, start, dist)
  local linearAlpha = min(dist, max(0, pos - start)) / dist
  return 0.5-square(square(1-linearAlpha)) -- increase opacity much sooner than a linear ramp
end

M.decalPool = {}
M.decalPoolCount = 0
M.decalDrawingDistance = 120--m
M.decalBlendOffset = 1 --m
M.decalBlendStart = 10--m
M.decalBlendEnd = 100--m
-- M.stepDistance = 5
local function increaseDecalPool(max)
  while M.decalPoolCount < max do
    M.decalPoolCount = M.decalPoolCount +1
    table.insert(M.decalPool, getNewData())
  end
end

local function inverseLerp(min, max, value)
 if abs(max - min) < 1e-30 then return min end
 return (value - min) / (max - min)
end

local function generateDecalsForSegment(from, to, idx, first, colorRgb)
  local step = M.stepDistance or 3
  local last = M.startingStep - ceil(to.distToTarget / step)
  for i = first+1, last, 1 do

    local t = inverseLerp(M.startingStep-from.distToTarget/step, M.startingStep-to.distToTarget/step, i)
    local distFromVehicle = M.startingDist-lerp(from.distToTarget, to.distToTarget, t)
    if distFromVehicle > M.decalDrawingDistance then return idx, false, i end

    if idx > M.decalPoolCount then
      increaseDecalPool(idx + 10)
    end

    M.decalPool[idx].pos = lerp(from.pos, to.pos, t)
    M.decalPool[idx].position:set(M.decalPool[idx].pos.x, M.decalPool[idx].pos.y, M.decalPool[idx].pos.z)
    local normal = (to.pos - from.pos):normalized()
    M.decalPool[idx].forwardVec:set(normal.x, normal.y, normal.z)
    local alpha = 0
    if distFromVehicle > M.decalBlendEnd then
      alpha = max(0, 1-(distFromVehicle - M.decalBlendEnd) / (M.decalDrawingDistance-M.decalBlendEnd))
    elseif distFromVehicle < M.decalBlendStart then
      alpha = max(0, ((distFromVehicle-M.decalBlendOffset) / (M.decalBlendStart-M.decalBlendOffset)))
    else
      alpha = 1
    end

    local c = colorRgb or M.color or {0, 0.4, 1}
    M.decalPool[idx].color.r = c[1]
    M.decalPool[idx].color.g = c[2]
    M.decalPool[idx].color.b = c[3]
    M.decalPool[idx].color.a = alpha

    idx = idx + 1
  end
  return idx, (M.startingDist-to.distToTarget) < M.decalDrawingDistance, last
end

local function generateDecalsForRoute(path, startPos, startIdx, colorRgb)
  if not path or not path[1] or #path < 2 then return startIdx end

  local step = M.stepDistance or 3
  local totalDist = (startPos - path[1].pos):length() + (path[1].distToTarget or 0)
  M.startingDist = totalDist
  M.startingStep = ceil(totalDist / step) + 1

  local nextIdx, cont, first = startIdx, true, 1
  local i = 1

  while cont do
    if path[i+1] then
      nextIdx, cont, first = generateDecalsForSegment(path[i], path[i+1], nextIdx, first, colorRgb)
      i = i + 1
      cont = cont and path[i+1]
    else
      cont = nil
    end
  end

  return nextIdx
end

local function generateRouteDecals(startPos)
  profilerPushEvent("Groundmarkers generateRouteDecals")

  if (settings.getValue("showNavigationGroundmarkers") ~= false) and M.decalPoolCount < 320 then
    increaseDecalPool(320)
  end

  local isSplitActive = (careerSplitScreen and careerSplitScreen.isActive and careerSplitScreen.isActive())
    or (render_splitScreen and render_splitScreen.isEnabled and render_splitScreen.isEnabled())

  local nextIdx = 1

  if isSplitActive then
    for pIdx, rp in pairs(routePlannersByPlayer) do
      if endWPByPlayer[pIdx] and rp and rp.path and #rp.path >= 2 then
        local pVeh = getTargetVeh(pIdx)
        local pPos = pVeh and pVeh:getPosition() or (rp.path and rp.path[1] and rp.path[1].pos) or core_camera.getPosition()
        local pCol = (pIdx == 0) and (M.colorSets[M.colorSet] and M.colorSets[M.colorSet].decals or {0, 0.4, 1})
          or ((pIdx == 1) and {1.0, 0.5, 0.05} or {0.1, 0.9, 0.3})
        nextIdx = generateDecalsForRoute(rp.path, pPos, nextIdx, pCol)
      end
    end
  else
    local targetRp = getRoutePlanner(M.targetPlayerIndex or 0)
    if targetRp and targetRp.path and #targetRp.path >= 2 and endWPByPlayer[M.targetPlayerIndex or 0] then
      local veh = getTargetVeh(M.targetPlayerIndex)
      local pos = veh and veh:getPosition() or startPos or (targetRp.path and targetRp.path[1] and targetRp.path[1].pos) or core_camera.getPosition()
      nextIdx = generateDecalsForRoute(targetRp.path, pos, nextIdx, M.color)
    end
  end

  M.activeDecalCount = math.max(0, nextIdx - 1)
  for i = nextIdx, M.decalPoolCount do
    if M.decalPool[i] and M.decalPool[i].color then
      M.decalPool[i].color.a = 0
    end
  end

  -- Update floating 3D arrows for active player
  if settings.getValue("showNavigationArrows") then
    local arrowPIdx = M.targetPlayerIndex or 0
    local arrowRp = getRoutePlanner(arrowPIdx)
    if not (arrowRp and arrowRp.path and #arrowRp.path >= 2 and endWPByPlayer[arrowPIdx]) then
      for otherIdx, rp in pairs(routePlannersByPlayer) do
        if endWPByPlayer[otherIdx] and rp and rp.path and #rp.path >= 2 then
          arrowPIdx = otherIdx
          arrowRp = rp
          break
        end
      end
    end

    if arrowRp and arrowRp.path and #arrowRp.path >= 2 and endWPByPlayer[arrowPIdx] then
      local aVeh = getTargetVeh(arrowPIdx)
      local aPos = aVeh and aVeh:getPosition() or core_camera.getPosition()
      local totalDist = (aPos - arrowRp.path[1].pos):length() + (arrowRp.path[1].distToTarget or 0)
      local arrowCol = (arrowPIdx == 0) and (M.colorSets[M.colorSet] and M.colorSets[M.colorSet].arrows or {0, 0.48, 0.77})
        or ((arrowPIdx == 1) and {1, 0.6, 0.1} or {0, 1, 0.4})
      M.floatingArrowColor = arrowCol
      core_groundMarkerArrows.updateArrows(arrowRp.path, totalDist)
    else
      core_groundMarkerArrows.clearArrows()
    end
  end

  profilerPopEvent('generateRouteDecals')
end

local appTimer = 0
local appInterval = 0.25
local lastGenerationPos
local playerVehPos = vec3()

local function onPreRender(dt)
  if photoModeOpen then return end
  profilerPushEvent("Groundmarkers onPreRender")

  -- Track vehicles for each player's route planner
  for pIdx, rp in pairs(routePlannersByPlayer) do
    if endWPByPlayer[pIdx] and rp and rp.path and rp.path[1] then
      local pVeh = getTargetVeh(pIdx)
      if pVeh then
        rp:trackVehicle(pVeh)
      end
      if rp.done and M.clearPathOnReachingTarget then
        clearPathForPlayer(pIdx)
      end
    end
  end

  local isSplitActive = (careerSplitScreen and careerSplitScreen.isActive and careerSplitScreen.isActive())
    or (render_splitScreen and render_splitScreen.isEnabled and render_splitScreen.isEnabled())

  local needsRegen = false
  if freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive() then
    needsRegen = true
  elseif not lastGenerationPos then
    needsRegen = true
  else
    if isSplitActive then
      for pIdx, rp in pairs(routePlannersByPlayer) do
        if endWPByPlayer[pIdx] and rp and rp.path and #rp.path >= 2 then
          local pVeh = getTargetVeh(pIdx)
          local pPos = pVeh and pVeh:getPosition() or (rp.path and rp.path[1] and rp.path[1].pos)
          if pPos and (not lastGenerationPosByPlayer[pIdx] or lastGenerationPosByPlayer[pIdx]:distance(pPos) > 1) then
            needsRegen = true
            lastGenerationPosByPlayer[pIdx] = lastGenerationPosByPlayer[pIdx] or vec3()
            lastGenerationPosByPlayer[pIdx]:set(pPos)
          end
        end
      end
    else
      local veh = getTargetVeh(M.targetPlayerIndex)
      local pos = veh and veh:getPosition() or (targetRp and targetRp.path and targetRp.path[1] and targetRp.path[1].pos) or core_camera.getPosition()
      if pos and (not lastGenerationPos or lastGenerationPos:distance(pos) > 1) then
        needsRegen = true
        lastGenerationPos = lastGenerationPos or vec3()
        lastGenerationPos:set(pos)
      end
    end
  end

  if M.renderDecals ~= false and needsRegen then
    local p0Veh = getTargetVeh(0)
    local p0Pos = p0Veh and p0Veh:getPosition() or core_camera.getPosition()
    lastGenerationPos = lastGenerationPos or vec3()
    lastGenerationPos:set(p0Pos)
    generateRouteDecals(p0Pos)
  end

  if M.renderDecals ~= false and (settings.getValue("showNavigationGroundmarkers") ~= false) and M.activeDecalCount and M.activeDecalCount > 0 then
    Engine.Render.DynamicDecalMgr.addDecals(M.decalPool, M.activeDecalCount)
  end

  if M.debugPath then
    for i, wp in ipairs(M.routePathTmp or {}) do
      debugDrawer:drawSphere(vec3(wp), 0.25, ColorF(1, 0.4, 1,0.2))
      debugDrawer:drawTextAdvanced(wp, String(i), ColorF(1,1,1,1), true, false, ColorI(0,0,0,192))
    end
    for i, e in ipairs(M.routePlanner.path or {}) do
      debugDrawer:drawSphere(vec3(e.pos), 1, ColorF(0.23, 0.4, 0.1,0.6))
      if i > 1 then
        debugDrawer:drawSquarePrism(
          vec3(e.pos), vec3(M.routePlanner.path[i-1].pos),
          Point2F(2,0.5),
          Point2F(2,0.5),
          ColorF(0.23, 0.5,0.2, 0.6))
      end
    end
  end

  appTimer = appTimer + dt
  if appTimer > appInterval then
    appTimer = 0
    M.sendToApp()
  end
  profilerPopEvent('Groundmarkers onPreRender')
end

local function sendToApp()
  local targetRp = getRoutePlanner(M.targetPlayerIndex or 0)
  local data = {
    markers = {},
    color = string.format("#%02X%02X%02XFF", M.color[1]*255, M.color[2]*255, M.color[3]*255)
  }
  local id = 1
  if targetRp and targetRp.path then
    for i, e in ipairs(targetRp.path) do
      data.markers[id] = e.pos.x
      data.markers[id+1] = e.pos.y
      id = id+2
    end
  end

  guihooks.trigger("NavigationGroundMarkersUpdate", data)
end

local function setPath(wp, options)
  profilerPushEvent("Groundmarkers setPath")
  options = options or {}
  local pIdx = (options and options.playerIndex) or M.targetPlayerIndex or 0
  local rp = getRoutePlanner(pIdx)

  pathRequestIdByPlayer[pIdx] = (pathRequestIdByPlayer[pIdx] or 0) + 1
  local requestId = pathRequestIdByPlayer[pIdx]
  pathPendingByPlayer[pIdx] = false

  local isTargetSelected = (pIdx == (M.targetPlayerIndex or 0))

  M.clearPathOnReachingTarget = options.clearPathOnReachingTarget
  M.stepDistance = options.step or 3
  M.color = options.color or (pIdx == 1 and {1, 0.5, 0} or (pIdx >= 2 and {0, 1, 0.3} or M.colorSets[M.colorSet].decals))
  M.floatingArrowColor = (pIdx == 1 and {1, 0.6, 0.1} or (pIdx >= 2 and {0, 1, 0.4} or M.colorSets[M.colorSet].arrows))

  M.cutOffDrivability = options.cutOffDrivability
  M.penaltyAboveCutoff = options.penaltyAboveCutoff
  M.penaltyBelowCutoff = options.penaltyBelowCutoff
  M.dirMult = options.dirMult
  M.wD = options.wD
  M.wZ = options.wZ
  M.renderDecals = options.renderDecals ~= false
  rp.lockFixedNodes = options.lockFixedNodes or false

  if not wp or (type(wp) == 'table' and tableIsEmpty(wp)) then
    endWPByPlayer[pIdx] = nil
    rp:clear()
    lastGenerationPos = nil
    lastGenerationPosByPlayer[pIdx] = nil
    if isTargetSelected then
      M.endWP = nil
      M.routePlanner = rp
      local data = { markers = {} }
      guihooks.trigger("NavigationGroundMarkersUpdate", data)
      core_groundMarkerArrows.clearArrows()
    end
    generateRouteDecals()
  else
    local targetWP = (type(wp) == 'table' and wp) or {wp}
    endWPByPlayer[pIdx] = targetWP
    lastGenerationPos = nil
    lastGenerationPosByPlayer[pIdx] = nil
    if isTargetSelected then
      M.endWP = targetWP
      M.routePlanner = rp
    end

    local veh = getTargetVeh(pIdx)
    local vehiclePos = vec3(veh and veh:getPosition() or core_camera.getPosition())
    local multiPath = {}
    table.insert(multiPath, vehiclePos)
    for _, w in ipairs(targetWP) do
      if type(w) == 'string' then
        if not map.getMap().nodes[w] then
          log("W","","Could not find WP to build route! Ignoring WP: " .. dumps(w))
        else
          table.insert(multiPath, map.getMap().nodes[w].pos)
        end
      elseif type(w) == 'table' and #w == 3 then
        table.insert(multiPath, vec3(w))
      else
        table.insert(multiPath, w)
      end
    end

    profilerPushEvent("Groundmarkers route setupPath")
    if isTargetSelected then
      M.routePathTmp = multiPath
    end
    rp:setRouteParams(M.cutOffDrivability, M.dirMult, M.penaltyAboveCutoff, M.penaltyBelowCutoff, M.wD, M.wZ)
    local function onPathReady()
      if requestId ~= pathRequestIdByPlayer[pIdx] or not endWPByPlayer[pIdx] then return end
      pathPendingByPlayer[pIdx] = false
      local currentVeh = getTargetVeh(pIdx)
      if currentVeh then
        rp:trackVehicle(currentVeh)
      end
      lastGenerationPos = nil
      lastGenerationPosByPlayer[pIdx] = nil
      generateRouteDecals()
      if isTargetSelected then
        M.sendToApp()
        core_groundMarkerArrows.createArrowPool(M.floatingArrowColor)
      end
      if options.onComplete then
        options.onComplete()
      end
    end

    if options.async then
      pathPendingByPlayer[pIdx] = true
      if isTargetSelected then
        guihooks.trigger("NavigationGroundMarkersUpdate", { markers = {} })
        core_groundMarkerArrows.clearArrows()
      end
      rp:setupPathMultiJob(multiPath, onPathReady)
    else
      rp:setupPathMulti(multiPath)
      onPathReady()
    end
    profilerPopEvent('Groundmarkers route setupPath')
  end

  profilerPopEvent('Groundmarkers setPath')
end

local function unflagFirstFixedNode()
  if not M.endWP or #M.endWP == 0 then return false end

  local newEndWP = {}
  for i = 2, #M.endWP do
    newEndWP[i - 1] = M.endWP[i]
  end
  M.endWP = newEndWP

  if #M.endWP == 0 then
    M.routePlanner:clear()
    M.endWP = nil
    guihooks.trigger("NavigationGroundMarkersUpdate", { markers = {} })
    core_groundMarkerArrows.clearArrows()
    return true
  end

  M.routePlanner:unflagFirstFixedNode()
  return true
end

local function setFocus(wp, step, _fadeStart, _fadeEnd, _endPos, _disableVeh, _color, _cutOffDrivability, _penaltyAboveCutoff, _penaltyBelowCutoff, _renderDecals)
  deprecationWarning("core_groundmarkers.setFocus", "core_groundmarkers.setPath")
  local options = {
    step = step,
    color = _color,
    cutOffDrivability = _cutOffDrivability,
    penaltyAboveCutoff = _penaltyAboveCutoff,
    penaltyBelowCutoff = _penaltyBelowCutoff,
    renderDecals = _renderDecals,
  }
  setPath(wp, options)
end

local function resetAll()
  -- cleanup on level exit
  for pIdx, rp in pairs(routePlannersByPlayer) do
    if rp then rp:clear() end
  end
  table.clear(endWPByPlayer)
  setPath(nil)

  decals = {}

  M.cutOffDrivability = nil
  M.penaltyAboveCutoff = nil
  M.penaltyBelowCutoff = nil
  M.dirMult = nil
  M.wD = nil
  M.wZ = nil
  M.renderDecals = nil

  core_groundMarkerArrows.clearArrows()
end

local function onClientEndMission()
  resetAll()
end

local function onExtensionUnloaded()
  resetAll()
end

local function onSerialize()
  core_groundMarkerArrows.clearArrows()
end

local function currentlyHasTarget(playerIndex)
  playerIndex = playerIndex or M.targetPlayerIndex or 0
  return endWPByPlayer[playerIndex] ~= nil
end

local function getTargetPos(playerIndex)
  playerIndex = playerIndex or M.targetPlayerIndex or 0
  local wp = endWPByPlayer[playerIndex]
  return wp and wp[1]
end

local function getPathForPlayer(playerIndex)
  playerIndex = playerIndex or 0
  local rp = routePlannersByPlayer[playerIndex]
  if rp and rp.path and rp.path[1] then
    return rp.path
  end
  if playerIndex == 0 and M.routePlanner and M.routePlanner.path and M.routePlanner.path[1] then
    return M.routePlanner.path
  end
  return nil
end

local function getEndWPForPlayer(playerIndex)
  playerIndex = playerIndex or 0
  return endWPByPlayer[playerIndex]
end

local function clearPathForPlayer(playerIndex)
  playerIndex = playerIndex or 0
  setPath(nil, {playerIndex = playerIndex})
end

local showNavigationArrows
local showNavigationGroundmarkers
local function onSettingsChanged()
  local newShowNavigationArrows = settings.getValue('showNavigationArrows')
  if newShowNavigationArrows ~= showNavigationArrows then
    showNavigationArrows = newShowNavigationArrows
    if showNavigationArrows then
      core_groundMarkerArrows.createArrowPool(M.floatingArrowColor)
      lastGenerationPos = nil
    else
      core_groundMarkerArrows.clearArrows()
    end
  end

  local newShowNavigationGroundmarkers = settings.getValue('showNavigationGroundmarkers')
  if newShowNavigationGroundmarkers ~= showNavigationGroundmarkers then
    showNavigationGroundmarkers = newShowNavigationGroundmarkers
    if showNavigationGroundmarkers then
      lastGenerationPos = nil
    end
  end
end

M.onAnyMissionChanged = function(state) if state == "started" or state == "stopped" then M.resetAll() end end

-- public interface
M.onPreRender = onPreRender
M.setPath = setPath
M.unflagFirstFixedNode = unflagFirstFixedNode
M.getPathLength = getPathLength
M.onClientEndMission = onClientEndMission
M.onExtensionUnloaded = onExtensionUnloaded
M.onSerialize = onSerialize
M.onSettingsChanged = onSettingsChanged
M.resetAll = resetAll
M.generateRouteDecals = generateRouteDecals
M.sendToApp = sendToApp
M.currentlyHasTarget = currentlyHasTarget
M.getTargetPos = getTargetPos
M.getPathForPlayer = getPathForPlayer
M.getEndWPForPlayer = getEndWPForPlayer
M.clearPathForPlayer = clearPathForPlayer

-- deprecated
M.setFocus = setFocus

return M
