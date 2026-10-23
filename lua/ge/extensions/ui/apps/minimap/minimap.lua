-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"ui_apps_minimap_topomap", "ui_apps_minimap_additionalInfo", "ui_apps_minimap_route", "ui_apps_minimap_utils", "ui_apps_minimap_roads", "ui_apps_minimap_vehicles", "gameplay_playmodeMarkers"}
local layers = require("ui/apps/minimap/layers")

local mode = settings.getValue("minimapMode") or "circle" -- "circle" or "rect"
local im = ui_imgui
local viewportsEnabled = true
local bufferLeft = 50
local bufferRight = 50
local bufferTop = 50
local bufferBottom = 50
local width, height
local centerX, centerY
local camPos, camRot, camRotInverse = vec3(), quat(), quat()
local cameraLook = vec3()
local scaleSetting = 0.5 -- px/m

local scale = scaleSetting
local scaleInverse = 1/scale
local td = nil
local singlePlayerTd = nil
local p = nil

M.getScale = function()
  return scale
end

local stats = { }
local function resetStats()
  stats.navgraphRoadsVisible = 0
  stats.roadsDrawnFG = 0
  stats.roadsDrawnBG = 0
  stats.totalLinesDrawn = 0
end
resetStats()

local debugSettingsOpen = false
local debugSettings = {
  drawRoadsBg = true,
  drawRoadsFg = true,
  drawNavigation = true,
  drawPlayer = true,
  drawOtherVehicles = true,
  drawParkedVehicles = false,
  drawTrafficVehicles = false,
  drawActivePoliceVehicles = true,
  drawPoliceInfo = true,
  drawCompass = true,
  draw100m = false,
  drawOcclusion = false,
  drawBounds = false,
  drawGrid = false,
  lookaheadEnabled = false,
  lookaheadValue = 3,

  drawPlaymodeMarkers = true,
  styleConstantWidth = true,
  styleRoadColorUnique = false,
  styleRoadColorAllWhite = false,
  styleRoadColorDrivability = true,
  behaviourRotateWithCam = true,
  useProfiler = false,
  useProfilerAlwaysLog = false,
  profileEveryNthFrame = 1,
  logGarbage = false,
}
local debugSettingsData = {
  lookaheadValue = {
    { name = "0%", value = 0.0 },
    { name = "low", value = 0.33 },
    { name = "medium", value = 0.55 },
    { name = "high", value = 0.77 },
  },
  profileEveryNthFrame = {
    { name = "off", value = 0 },
    { name = "10", value = 10 },
    { name = "20", value = 20 },
    { name = "30", value = 30 },
    { name = "40", value = 40 },
    { name = "50", value = 50 },
    { name = "100", value = 100 },
    { name = "200", value = 200 },
    { name = "300", value = 300 },
    { name = "400", value = 400 },
    { name = "500", value = 500 },
    { name = "1000", value = 1000 },
  },
}

local gcLast = 0
local gcSections = {}
local gcOrder = {}
local function gcStart()
  if debugSettings.logGarbage then
    gcLast = collectgarbage("count")
  end
end
local function gcMark(name)
  if not debugSettings.logGarbage then return end
  local now = collectgarbage("count")
  local delta = now - gcLast
  gcLast = now
  if delta < 0 then return end
  local section = gcSections[name]
  if not section then
    section = {last = 0, avg = 0}
    gcSections[name] = section
    gcOrder[#gcOrder + 1] = name
  end
  section.last = delta
  section.avg = section.avg * 0.98 + delta * 0.02
end
local function resetGcStats()
  table.clear(gcSections)
  table.clear(gcOrder)
end

local function drawCompass(offsetX, offsetY, dpi)
  local _, northX, _, northY = ui_apps_minimap_utils.getWorldToMapTransform()
  local colors = ui_apps_minimap_utils.colors
  td:northMarker(width, height, offsetX, offsetY, mode == "circle", northX, northY, dpi, colors.grayMuted, colors.navBgWhite, layers.COMPASS)
  return true
end

local cachedPlaymodeClusters = nil
local playmodeClustersById = {}
local focusedPlaymodeClusters = {}
local drawnPlaymodeClusterIds = {}

local function updatePlaymodeClusterCache(clusters)
  if clusters == cachedPlaymodeClusters then return end
  cachedPlaymodeClusters = clusters
  table.clear(playmodeClustersById)
  table.clear(focusedPlaymodeClusters)
  for _, cluster in ipairs(clusters) do
    playmodeClustersById[cluster.id] = cluster
    if cluster.focus then
      focusedPlaymodeClusters[#focusedPlaymodeClusters + 1] = cluster
    end
  end
end

local function drawPlaymodeCluster(cluster, dpi)
  local marker = gameplay_playmodeMarkers.getMarkerForCluster(cluster)
  if marker.drawOnMinimap then
    marker:drawOnMinimap(td, dpi)
  elseif cluster.showOnMinimap ~= false and marker.pos then
    ui_apps_minimap_utils.simpleCircle(marker.pos)
  end
end

local function drawPlaymodeMarkers(searchRadius)
  local clusters = gameplay_playmodeMarkers.getPlaymodeClusters()
  updatePlaymodeClusterCache(clusters)

  local clusterKd = gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree()
  local dpi = im.GetWindowDpiScale()
  local worldToMapXY = ui_apps_minimap_utils.worldToMapXY
  local centerMapX, centerMapY = bufferLeft + width * 0.5, bufferTop + height * 0.5
  table.clear(drawnPlaymodeClusterIds)

  for id in clusterKd:queryNotNested(camPos.x-searchRadius, camPos.y-searchRadius, camPos.x+searchRadius, camPos.y+searchRadius) do
    local cluster = playmodeClustersById[id]
    if cluster then
      local markerMapX, markerMapY = worldToMapXY(cluster.visibilityPos.x, cluster.visibilityPos.y)
      local visibilityRadius = cluster.visibilityRadius * scaleInverse
      local visible
      if mode == "circle" then
        local dx, dy = markerMapX - centerMapX, markerMapY - centerMapY
        local visibleRadius = width * 0.5 + visibilityRadius
        visible = dx * dx + dy * dy <= visibleRadius * visibleRadius
      else
        visible = markerMapX + visibilityRadius >= bufferLeft
          and markerMapX - visibilityRadius <= bufferLeft + width
          and markerMapY + visibilityRadius >= bufferTop
          and markerMapY - visibilityRadius <= bufferTop + height
      end

      if visible then
        drawPlaymodeCluster(cluster, dpi)
        drawnPlaymodeClusterIds[id] = true
      end
    end
  end

  for _, cluster in ipairs(focusedPlaymodeClusters) do
    if cluster.focus and not drawnPlaymodeClusterIds[cluster.id] then
      drawPlaymodeCluster(cluster, dpi)
      drawnPlaymodeClusterIds[cluster.id] = true
    end
  end

  local navigationPoiId = gameplay_markerInteraction and gameplay_markerInteraction.navigationPoiId
  if navigationPoiId and not drawnPlaymodeClusterIds[navigationPoiId] then
    local cluster = playmodeClustersById[navigationPoiId]
    if cluster then
      drawPlaymodeCluster(cluster, dpi)
    end
  end
end

-- Occlusion transforms & pixels
local occlusionTransforms = {}
local occlusionPixels = {}
local childSize = im.ImVec2(0,0)
local rad
local frameCount = 0
local imVec00 = im.ImVec2(0,0)
local imVec01 = im.ImVec2(0,1)
local cursorPos = im.ImVec2(0,0)
local boundsColor
local windowFlags
local canvasObjectCache
local lookWithoutZ = vec3()

local function drawMinimap(sizeX, sizeY, dtReal, dtSim, playerIndex)
  playerIndex = playerIndex or 0
  local dpi = im.GetWindowDpiScale()

  width, height = sizeX-bufferLeft-bufferRight, sizeY-bufferTop-bufferBottom
  width = width/dpi
  height = height/dpi
  childSize.x = width
  childSize.y = height
  local wx, wy = im.GetWindowPosXY()
  wx, wy = wx + bufferLeft, wy + bufferTop
  centerX, centerY = wx + width/2, wy + height/2

  width = width*dpi
  height = height*dpi

  local offsetX = bufferLeft
  local offsetY = bufferTop

  -- Camera setup for this player
  local ctxId = core_camera and core_camera.getContextIdForPlayer and core_camera.getContextIdForPlayer(playerIndex)
  local cPosX, cPosY, cPosZ = 0, 0, 0
  local cLookX, cLookY, cLookZ = 0, 1, 0
  local hasCam = false

  if ctxId and core_camera then
    cPosX, cPosY, cPosZ = core_camera.getPositionXYZ(ctxId)
    cLookX, cLookY, cLookZ = core_camera.getForwardXYZ(ctxId)
    hasCam = (cPosX ~= nil and cPosY ~= nil)
  end

  if not hasCam then
    local vehId = (playerIndex == 1 and careerSplitScreen and careerSplitScreen.getP2VehicleId and careerSplitScreen.getP2VehicleId()) or be:getPlayerVehicleID(playerIndex)
    if vehId and map.objects[vehId] then
      local v = map.objects[vehId]
      cPosX, cPosY, cPosZ = v.pos.x, v.pos.y, v.pos.z
      cLookX, cLookY, cLookZ = v.dirVec.x, v.dirVec.y, 0
      hasCam = true
    elseif core_camera then
      cPosX, cPosY, cPosZ = core_camera.getPositionXYZ()
      cLookX, cLookY, cLookZ = core_camera.getForwardXYZ()
    end
  end

  camPos:set(cPosX or 0, cPosY or 0, cPosZ or 0)
  cameraLook:set(cLookX or 0, cLookY or 1, 0)
  cameraLook.z = 0
  cameraLook:normalize()
  rad = -math.atan2(cameraLook.y, -cameraLook.x) + math.pi/2

  if debugSettings.behaviourRotateWithCam then
    camRot:setFromEuler(0, 0, rad)
  else
    camRot:set(0, 0, 0, 1)
  end
  camRotInverse:set(camRot)
  camRotInverse:inverse()

  if debugSettings.lookaheadEnabled and debugSettingsData.lookaheadValue and debugSettingsData.lookaheadValue[debugSettings.lookaheadValue] then
    local lookaheadValue = debugSettingsData.lookaheadValue[debugSettings.lookaheadValue].value
    lookWithoutZ:set(cameraLook.x, cameraLook.y, 0)
    lookWithoutZ:normalize()
    lookWithoutZ:setScaled(lookaheadValue * scale * height/2)
    camPos:setAdd(lookWithoutZ)
  end

  if ui_apps_minimap_utils then
    ui_apps_minimap_utils.setMinimapState(width, height, centerX, centerY, camPos, camRot, camRotInverse, scale, scaleInverse, td, offsetX, offsetY, mode, dpi)
  end
  if ui_apps_minimap_vehicles then
    ui_apps_minimap_vehicles.setMinimapState(width, height, centerX, centerY, camPos, camRot, camRotInverse, scale, scaleInverse, td, debugSettings, cameraLook, dpi)
  end

  im.Dummy(imVec01)



  if ui_apps_sdfTopomap and ui_apps_sdfTopomap.isLoaded() then
    ui_apps_sdfTopomap.drawContours(td, width, height, scale, camPos, ui_apps_minimap_utils.worldToMapXYZ)
  end

  if debugSettings.drawGrid then
    ui_apps_minimap_utils.drawGrid()
  end

  local radius = math.sqrt(width * width + height * height) * scale * 0.5
  if ui_apps_minimap_roads then
    ui_apps_minimap_roads.drawRoads(p, radius, td, debugSettings, camPos, scale, dpi)
  end

  if debugSettings.drawNavigation and ui_apps_minimap_route then
    ui_apps_minimap_route.drawNavigationRoute(td, dpi, camPos, radius + 4 * dpi * scale, playerIndex)
    ui_apps_minimap_route.drawRoutePointer(td, playerIndex)
  end

  if debugSettings.draw100m then
    local w = 20
    td:circle(width/2 + offsetX, height/2 + offsetY, 100/scale-w, w, 0, 0, color(255,255,255,0), color(255,255,255,250), 0, layers.GAMEPLAY_MARKERS)
  end

  if debugSettings.drawPlaymodeMarkers and gameplay_playmodeMarkers.isStateWithPlaymodeMarkers() then
    local markerSearchRadius = mode == "circle" and width * scale * 0.5 or radius
    drawPlaymodeMarkers(markerSearchRadius)
  end

  extensions.hook("onDrawOnMinimap", td)

  if ui_apps_minimap_vehicles then
    ui_apps_minimap_vehicles.drawOtherVehicles(dtReal, dtSim, playerIndex)
    local adjustedScale = ui_apps_minimap_vehicles.drawPlayer(dtReal, dtSim, playerIndex)
    scale = adjustedScale or scale or 1
    scaleInverse = 1/scale
  end

  M.drawOcclusion(offsetX, offsetY)



  if debugSettings.drawCompass then
    drawCompass(offsetX, offsetY, dpi)
  end

  if debugSettings.drawBounds then
    M.drawDebugOverlay()
  end
end

M.drawOcclusion = function(offsetX, offsetY)
  local white, transparent, flag = color(255,255,255,255), color(255,255,255,0), TextureDrawPrimitive.primitiveFlag_blendMultiply
  local dpi = im.GetWindowDpiScale()

  for _, transform in pairs(occlusionTransforms) do
    local left, right, h = transform[5]+5, transform[7]-5, transform[8]-transform[6]
    td:line(left, transform[6]+h/2, right, transform[6]+h/2, h/2-5, h/2-5, 5, 5, transparent, transparent, white, white, flag, layers.ROUND_OR_SQUARE_MASK)
  end

  local roundness, strikeWidth = 10, 100
  local buffer = 5

  if mode == "circle" then
    td:circle(width/2 + offsetX, height/2 + offsetY, width/2, width*2, white, white, transparent, transparent, flag, layers.ROUND_OR_SQUARE_MASK)
    td:circle(width/2 + offsetX, height/2 + offsetY, width/2-10*dpi, 12*dpi, white, white, white, transparent, flag, layers.ROUND_OR_SQUARE_MASK)
  end
  if mode == "rect" then
    td:line(bufferLeft+buffer*1.5, bufferTop+height/2, width+bufferLeft-buffer*1.5, bufferTop+height/2, height/2-buffer*2, height/2-buffer*2, roundness, strikeWidth, white, white, transparent, transparent, flag, layers.ROUND_OR_SQUARE_MASK)
    roundness, strikeWidth = 5, 10
    buffer = 5
    td:line(bufferLeft+buffer*1.5, bufferTop+height/2, width+bufferLeft-buffer*1.5, bufferTop+height/2, height/2-buffer*2, height/2-buffer*2, roundness, strikeWidth, white, white, white, transparent, flag, layers.ROUND_OR_SQUARE_MASK)
  end
end

M.drawDebugOverlay = function()
  local texWidth, texHeight = width + bufferLeft + bufferRight, height + bufferTop + bufferBottom
  td:circle(0,0, 5,5, 0, 0, color(0,255,0,255), color(0,255,0,255), 0, layers.DEBUG)
  td:circle(texWidth ,0, 5,5, 0, 0, color(0,255,0,255), color(0,255,0,255), 0, layers.DEBUG)
  td:circle(0,texHeight , 5,5, 0, 0, color(0,255,0,255), color(0,255,0,255), 0, layers.DEBUG)
  td:circle(texWidth ,texHeight , 5,5, 0, 0, color(0,255,0,255), color(0,255,0,255), 0, layers.DEBUG)
end

-- ImGui window setup & state
local lastSize = im.ImVec2(0,0)
local lastTexSize = im.ImVec2(0,0)
local drawTransform = {0,0,0,0}
local transparent = im.GetColorU322(im.ImVec4(0,0,0,0.0))
local padding = im.ImVec2(5,5)
local imPadding = 0
local point00 = Point2I(0,0)
local loggedMinimapErrors = false
local windowPos, windowSize = im.ImVec2(0,0), im.ImVec2(0,0)

-- Per-player split-screen minimap states
local playerStates = {}
local function getPlayerState(pId)
  pId = pId or 0
  local s = playerStates[pId]
  if not s then
    s = {
      lastSize = im.ImVec2(0,0),
      lastTexSize = im.ImVec2(0,0),
      td = nil,
      scale = scaleSetting
    }
    playerStates[pId] = s
  end
  return s
end

local function isSplitScreenActive()
  if extensions.isExtensionLoaded("render_splitScreen") then
    local splitEnabled, count, _, splitMode = render_splitScreen.getCurrentConfiguration()
    if splitEnabled and count and count > 1 and splitMode ~= "shared" then
      return true, count, splitMode
    end
  end
  return false, 1, nil
end

local splitWindowFlags = nil
local function getSplitWindowFlags()
  if splitWindowFlags then return splitWindowFlags end
  splitWindowFlags = 0
  local flagNames = {
    "WindowFlags_NoTitleBar",
    "WindowFlags_NoResize",
    "WindowFlags_NoMove",
    "WindowFlags_NoScrollbar",
    "WindowFlags_NoScrollWithMouse",
    "WindowFlags_NoCollapse",
    "WindowFlags_NoBackground",
    "WindowFlags_NoSavedSettings",
    "WindowFlags_NoInputs",
    "WindowFlags_NoFocusOnAppearing",
    "WindowFlags_NoBringToFrontOnFocus",
    "WindowFlags_NoDocking",
    "WindowFlags_NoNav",
  }
  for _, name in ipairs(flagNames) do
    local f = im[name]
    if type(f) == "number" then
      splitWindowFlags = bit.bor(splitWindowFlags, f)
    end
  end
  return splitWindowFlags
end

local function drawPlayerMinimap(pIdx, player, rect, canvasPosX, canvasPosY, canvasSizeX, canvasSizeY, dtReal, dtSim)
  local dpi = im.GetWindowDpiScale() or 1

  local vpPxW = rect[3] * canvasSizeX
  local vpPxH = rect[4] * canvasSizeY
  local vpPxX = canvasPosX + rect[1] * canvasSizeX
  local vpPxY = canvasPosY + rect[2] * canvasSizeY

  local baseSize = math.floor(math.min(220 * dpi, math.min(vpPxW * 0.30, vpPxH * 0.40)))
  local mapSizePx = math.max(140 * dpi, baseSize)

  local marginPx = math.floor(20 * dpi)
  local pBuf = math.floor(16 * dpi)
  bufferLeft = pBuf
  bufferRight = pBuf
  bufferTop = pBuf
  bufferBottom = pBuf

  -- Position minimap at bottom-left of player's viewport
  local winLeft = vpPxX + marginPx - pBuf
  local winTop = vpPxY + vpPxH - mapSizePx - marginPx - pBuf
  local winW = mapSizePx + pBuf * 2
  local winH = mapSizePx + pBuf * 2

  -- Strict clamping to main game canvas boundaries to prevent any negative or out-of-bounds coordinates
  if winLeft < canvasPosX then
    winLeft = canvasPosX
  end
  if winTop < canvasPosY then
    winTop = canvasPosY
  end
  if winLeft + winW > canvasPosX + canvasSizeX then
    winLeft = math.max(canvasPosX, (canvasPosX + canvasSizeX) - winW)
  end
  if winTop + winH > canvasPosY + canvasSizeY then
    winTop = math.max(canvasPosY, (canvasPosY + canvasSizeY) - winH)
  end

  windowPos.x = winLeft
  windowPos.y = winTop
  windowSize.x = winW
  windowSize.y = winH

  -- Strictly force the window into the main game viewport so ImGui never detaches it as a separate OS window
  if im.GetMainViewport and im.SetNextWindowViewport then
    local mainVp = im.GetMainViewport()
    if mainVp and mainVp.ID then
      im.SetNextWindowViewport(mainVp.ID)
    end
  end

  im.SetNextWindowPos(windowPos, im.Cond_Always, imVec00)
  im.SetNextWindowSize(windowSize, im.Cond_Always)
  im.PushStyleColor1(im.Col_WindowBg, transparent)
  im.PushStyleColor1(im.Col_Border, transparent)
  im.PushStyleColor1(im.Col_BorderShadow, transparent)
  im.PushStyleVar2(im.StyleVar_WindowPadding, imVec00)

  local winTitle = "###SDF_SplitMinimap_" .. tostring(player)
  local minimapWindowVisible = im.Begin(winTitle, nil, getSplitWindowFlags())

  if minimapWindowVisible then
    local sizeX, sizeY = im.GetContentRegionAvailXY()
    local texSizeX, texSizeY = math.floor(sizeX), math.floor(sizeY)
    if texSizeX > 0 and texSizeY > 0 then
      local pState = getPlayerState(player)
      if texSizeX ~= pState.lastTexSize.x or texSizeY ~= pState.lastTexSize.y or not pState.td then
        pState.td = TextureDrawPrimitiveRegistry:getOrCreate("sdfMinimap_" .. tostring(player), texSizeX, texSizeY)
        pState.td:setWidthHeight(texSizeX, texSizeY)
        pState.td:setClearColor(0)
        pState.td:setClearFlag("WhenDirty")
        pState.lastTexSize.x = texSizeX
        pState.lastTexSize.y = texSizeY
      end

      td = pState.td
      scale = pState.scale or scaleSetting
      scaleInverse = 1 / scale

      drawMinimap(sizeX, sizeY, dtReal, dtSim, player)
      pState.scale = scale

      td:ImGui_Image(pState.lastTexSize.x, pState.lastTexSize.y)
    end
  end

  im.End()
  im.PopStyleColor(3)
  im.PopStyleVar(1)
end

local function drawSplitScreenMinimaps(dtReal, dtSim)
  local canvasObject = canvasObjectCache or scenetree.findObject("Canvas")
  canvasObjectCache = canvasObject
  if not canvasObject or not canvasObject.getWindowClientSizeXY then return end

  local canvasSizeX, canvasSizeY = canvasObject:getWindowClientSizeXY()
  if not canvasSizeX or not canvasSizeY or canvasSizeX <= 0 or canvasSizeY <= 0 then return end

  local canvasPosX, canvasPosY = 0, 0
  if viewportsEnabled and canvasObject.clientToScreenXY then
    canvasPosX, canvasPosY = canvasObject:clientToScreenXY(point00)
    if not canvasPosX or not canvasPosY then return end
  end

  local uiState = render_splitScreen and render_splitScreen.getUiState and render_splitScreen.getUiState()
  if not uiState or not uiState.layout or not uiState.players then return end

  local soloView = render_splitScreen.getSoloView and render_splitScreen.getSoloView()
  if soloView then
    drawPlayerMinimap(1, soloView.player, {0, 0, 1, 1}, canvasPosX, canvasPosY, canvasSizeX, canvasSizeY, dtReal, dtSim)
    return
  end

  local pCount = math.min(#uiState.layout, #uiState.players)
  for pIdx = 1, pCount do
    local player = uiState.players[pIdx].player
    local rect = uiState.layout[pIdx]
    if rect and player ~= nil then
      drawPlayerMinimap(pIdx, player, rect, canvasPosX, canvasPosY, canvasSizeX, canvasSizeY, dtReal, dtSim)
    end
  end
end

local function drawSinglePlayerMinimap(dtReal, dtSim)
  if drawTransform[3] <= 0 or drawTransform[4] <= 0 then return end

  canvasObjectCache = canvasObjectCache or scenetree.findObject("Canvas")
  local canvasObject = canvasObjectCache
  if not canvasObject or not canvasObject.getWindowClientSizeXY then return end

  local canvasSizeX, canvasSizeY = canvasObject:getWindowClientSizeXY()
  if not canvasSizeX or not canvasSizeY or canvasSizeX <= 0 or canvasSizeY <= 0 then return end

  local canvasPosX, canvasPosY
  if viewportsEnabled then
    canvasPosX, canvasPosY = canvasObject:clientToScreenXY(point00)
    if not canvasPosX or not canvasPosY then return end
  else
    canvasPosX, canvasPosY = 0, 0
  end

  bufferLeft, bufferRight, bufferTop, bufferBottom = 50, 50, 50, 50
  windowPos.x = canvasPosX + drawTransform[1] * canvasSizeX
  windowPos.y = canvasPosY + drawTransform[2] * canvasSizeY

  if windowPos.x - bufferLeft < canvasPosX then
    bufferLeft = windowPos.x - canvasPosX
  end
  if windowPos.y - bufferTop < canvasPosY then
    bufferTop = windowPos.y - canvasPosY
  end

  windowPos.x = windowPos.x - bufferLeft
  windowPos.y = windowPos.y - bufferTop

  windowSize.x = drawTransform[3] * canvasSizeX + bufferLeft
  windowSize.y = drawTransform[4] * canvasSizeY + bufferTop

  local bottom, right = windowPos.y + windowSize.y, windowPos.x + windowSize.x
  if right + bufferRight > canvasPosX + canvasSizeX then
    bufferRight = (canvasPosX + canvasSizeX) - right
  end
  if bottom + bufferBottom > canvasPosY + canvasSizeY then
    bufferBottom = (canvasPosY + canvasSizeY) - bottom
  end

  windowSize.x = windowSize.x + bufferRight
  windowSize.y = windowSize.y + bufferBottom

  im.SetNextWindowPos(windowPos, im.Cond_Always, imVec00)
  im.SetNextWindowSize(windowSize, im.Cond_Always)

  local backgroundColor = transparent
  if debugSettings.drawBounds then
    boundsColor = boundsColor or im.GetColorU322(im.ImVec4(0,0,0,0.25))
    backgroundColor = boundsColor
  end
  im.PushStyleColor1(im.Col_WindowBg, backgroundColor)
  im.PushStyleColor1(im.Col_Border, backgroundColor)
  im.PushStyleColor1(im.Col_BorderShadow, backgroundColor)
  im.PushStyleVar2(im.StyleVar_WindowPadding, padding)

  if im.GetMainViewport and im.SetNextWindowViewport then
    local mainVp = im.GetMainViewport()
    if mainVp and mainVp.ID then
      im.SetNextWindowViewport(mainVp.ID)
    end
  end

  if not windowFlags then
    windowFlags = bit.bor(
      im.WindowFlags_NoScrollbar,
      im.WindowFlags_NoScrollWithMouse,
      im.WindowFlags_NoTitleBar,
      im.WindowFlags_NoResize,
      im.WindowFlags_NoMove,
      im.WindowFlags_NoInputs,
      im.WindowFlags_Modal
    )
    if im.WindowFlags_NoDocking then
      windowFlags = bit.bor(windowFlags, im.WindowFlags_NoDocking)
    end
  end
  local minimapWindowVisible = im.Begin("SDF Minimap", nil, windowFlags)
  local drewMinimap = false

  if minimapWindowVisible then
    local cp = cursorPos
    cp.x, cp.y = im.GetCursorPosX(), im.GetCursorPosY()
    local sizeX, sizeY = im.GetContentRegionAvailXY()
    local innerX, innerY = sizeX - imPadding*2, sizeY - imPadding*2
    if innerX > 0 and innerY > 0 then
      if innerX ~= lastSize.x or innerY ~= lastSize.y or not singlePlayerTd then
        local texSizeX, texSizeY = math.floor(innerX), math.floor(innerY)
        singlePlayerTd = TextureDrawPrimitiveRegistry:getOrCreate("sdfMinimap", texSizeX, texSizeY)
        singlePlayerTd:setWidthHeight(texSizeX, texSizeY)
        singlePlayerTd:setClearColor(0)
        singlePlayerTd:setClearFlag("WhenDirty")
        lastSize.x, lastSize.y = innerX, innerY
        lastTexSize.x = texSizeX
        lastTexSize.y = texSizeY
      end
      td = singlePlayerTd

      table.clear(occlusionPixels)
      for id, transform in pairs(occlusionTransforms) do
        local ox, oy, ow, oh = transform[1], transform[2], transform[3], transform[4]
        local x1, y1 = ox * canvasSizeX, oy * canvasSizeY
        local x2, y2 = (ox + ow) * canvasSizeX, (oy + oh) * canvasSizeY
        transform[5], transform[6], transform[7], transform[8] = x1-windowPos.x+canvasPosX-cp.x, y1-windowPos.y+canvasPosY-cp.y, x2-windowPos.x+canvasPosX-cp.x, y2-windowPos.y+canvasPosY-cp.y
      end

      drawMinimap(sizeX, sizeY, dtReal, dtSim, 0)
      drewMinimap = true

      cp.x = cp.x + imPadding
      cp.y = cp.y + imPadding
      im.SetCursorPos(cp)
      td:ImGui_Image(lastTexSize.x, lastTexSize.y)
    end
  end
  im.End()
  im.PopStyleColor(3)
  im.PopStyleVar(1)
end

local function isGameplayActive()
  if editor and editor.active then return false end
  if freeroam_bigMapMode and (freeroam_bigMapMode.bigMapActive() or freeroam_bigMapMode.isTransitionActive()) then
    return false
  end
  local cur = extensions.ui_router and extensions.ui_router.getCurrent()
  local rName = cur and (cur.resolved and cur.resolved.name or cur.request and cur.request.name or cur.name)
  if not rName or rName == "" then
    return true
  end
  if rName == "bigmap" or rName == "menu" or rName == "menu.careerPause" or string.find(rName, "^pause") or string.find(rName, "^menu%.") then
    return false
  end
  if extensions.ui_menuManager and extensions.ui_menuManager.isGameplayRoute then
    return extensions.ui_menuManager.isGameplayRoute(rName)
  end
  return rName == "play" or rName == "multiseat"
end

local function updateBigMapVehicles()
  if not freeroam_bigMapMode or not freeroam_bigMapMode.bigMapActive() then return end
  local iconRenderer = gameplay_playmodeMarkers and gameplay_playmodeMarkers.getBigmapRendererObj and gameplay_playmodeMarkers.getBigmapRendererObj()
  if not iconRenderer then return end

  local players = render_splitScreen and render_splitScreen.getPlayers and render_splitScreen.getPlayers() or {}
  for _, pIdx in ipairs(players) do
    if pIdx > 0 then
      local pVeh = (pIdx == 1 and careerSplitScreen and careerSplitScreen.getP2Vehicle and careerSplitScreen.getP2Vehicle()) or getPlayerVehicle(pIdx)
      local iconName = "playerVehicle_" .. tostring(pIdx)
      if pVeh then
        local icon = iconRenderer:getIconByName(iconName)
        if not icon then
          iconRenderer:addIcon(iconName, "player_marker", pVeh:getPosition())
          icon = iconRenderer:getIconByName(iconName)
          if icon then
            if pIdx == 1 then
              icon.color = ColorI(0, 140, 255, 255)
            else
              icon.color = ColorI(40, 220, 100, 255)
            end
            icon.customSizeFactor = 0.7
          end
        else
          icon.pos = pVeh:getPosition()
        end
      end
    end
  end
end

local function drawBigMapPlayerSelector()
  if extensions.isExtensionLoaded("careerSplitScreen") then return end
  if not freeroam_bigMapMode or not freeroam_bigMapMode.bigMapActive() then return end
  if not render_splitScreen then return end
  local players = render_splitScreen.getPlayers and render_splitScreen.getPlayers() or {}
  if #players <= 1 then return end

  local canvas = canvasObjectCache or scenetree.findObject("Canvas")
  canvasObjectCache = canvas
  local winW, winH = 1920, 1080
  if canvas and canvas.getWindowClientSizeXY then
    winW, winH = canvas:getWindowClientSizeXY()
  end

  local btnW = 110
  local btnH = 32
  local spacing = 8
  local barW = 140 + #players * (btnW + spacing) + 105
  local barH = 48
  local posX = (winW - barW) * 0.5
  local posY = 16

  im.SetNextWindowPos(im.ImVec2(posX, posY), im.Cond_Always)
  im.SetNextWindowSize(im.ImVec2(barW, barH), im.Cond_Always)

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
    im.WindowFlags_NoNavFocus,
    im.WindowFlags_NoFocusOnAppearing
  )
  if im.WindowFlags_NoDocking then
    flags = bit.bor(flags, im.WindowFlags_NoDocking)
  end

  im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(10, 8))
  im.PushStyleVar1(im.StyleVar_WindowRounding, 8)
  im.PushStyleVar1(im.StyleVar_WindowBorderSize, 2)
  im.PushStyleColor1(im.Col_WindowBg, im.GetColorU322(im.ImVec4(0.06, 0.08, 0.12, 0.92)))
  im.PushStyleColor1(im.Col_Border, im.GetColorU322(im.ImVec4(0.25, 0.35, 0.5, 0.75)))

  if im.Begin("###BigMapPlayerSelector", nil, flags) then
    im.AlignTextToFramePadding()
    im.TextColored(im.ImVec4(0.85, 0.9, 1.0, 1.0), "Route For:")
    im.SameLine()

    local currentNavTarget = (core_groundMarkers and core_groundMarkers.getTargetPlayer and core_groundMarkers.getTargetPlayer()) or 0

    for i, pIdx in ipairs(players) do
      local isSelected = (currentNavTarget == pIdx)
      local pLabel = (pIdx == 0) and "P1 (Orange)" or ((pIdx == 1) and "P2 (Blue)" or ("P" .. tostring(pIdx + 1) .. " (Green)"))

      if isSelected then
        if pIdx == 0 then
          im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.95, 0.45, 0.05, 0.95)))
          im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(1.0, 0.55, 0.15, 1.0)))
        elseif pIdx == 1 then
          im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.10, 0.50, 0.95, 0.95)))
          im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.20, 0.60, 1.0, 1.0)))
        else
          im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.15, 0.75, 0.3, 0.95)))
          im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.25, 0.85, 0.4, 1.0)))
        end
        im.PushStyleColor1(im.Col_Text, im.GetColorU322(im.ImVec4(1, 1, 1, 1)))
      else
        im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.18, 0.20, 0.26, 0.8)))
        im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.28, 0.32, 0.40, 0.9)))
        im.PushStyleColor1(im.Col_Text, im.GetColorU322(im.ImVec4(0.7, 0.75, 0.8, 0.85)))
      end

      if im.Button(pLabel .. "###btn_nav_p_" .. tostring(pIdx), im.ImVec2(btnW, btnH)) then
        if core_groundMarkers and core_groundMarkers.setTargetPlayer then
          core_groundMarkers.setTargetPlayer(pIdx)
        end
      end
      im.PopStyleColor(3)

      if i < #players then
        im.SameLine()
      end
    end

    if core_groundMarkers and core_groundMarkers.getPathForPlayer and core_groundMarkers.getPathForPlayer(currentNavTarget) then
      im.SameLine()
      im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.55, 0.15, 0.15, 0.85)))
      im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.75, 0.2, 0.2, 1.0)))
      if im.Button("Clear###btn_nav_clear", im.ImVec2(65, btnH)) then
        if core_groundMarkers.clearPathForPlayer then
          core_groundMarkers.clearPathForPlayer(currentNavTarget)
        end
        if freeroam_bigMapMode and freeroam_bigMapMode.resetRoute then
          freeroam_bigMapMode.resetRoute()
        end
      end
      im.PopStyleColor(2)
    end
  end
  im.End()

  im.PopStyleColor(2)
  im.PopStyleVar(3)
end

local function draw(dtReal, dtSim)
  if not isGameplayActive() then
    if freeroam_bigMapMode and (freeroam_bigMapMode.bigMapActive() or (freeroam_bigMapMode.isTransitionActive and freeroam_bigMapMode.isTransitionActive())) then
      drawBigMapPlayerSelector()
      updateBigMapVehicles()
    end
    return
  end

  viewportsEnabled = im.GetConfigFlagsViewportsEnable()

  local splitActive = isSplitScreenActive()
  if splitActive then
    drawSplitScreenMinimaps(dtReal, dtSim)
  else
    drawSinglePlayerMinimap(dtReal, dtSim)
  end
end

local function enableSplitScreenMinimaps()
  if M.onUpdate == nil then
    M.onUpdate = draw
    extensions.hookUpdate("onUpdate")
  end
end

local function disableSplitScreenMinimaps()
  table.clear(playerStates)
  td = singlePlayerTd
  lastSize = im.ImVec2(0, 0)
  lastTexSize = im.ImVec2(0, 0)

  local splitActive = isSplitScreenActive()
  if not splitActive and (drawTransform[3] <= 0 or drawTransform[4] <= 0) then
    M.onUpdate = nil
    extensions.hookUpdate("onUpdate")
  end
end

local function setBuffers(left, right, top, bottom)
  bufferLeft = left or 10
  bufferRight = right or 10
  bufferTop = top or 10
  bufferBottom = bottom or 10
end

local function setDrawTransform(x, y, w, h)
  if x < 0 or x > 1 or y < 0 or y > 1 or w < 0 or w > 1 or h < 0 or h > 1 then
    log("W","",string.format("Invalid minimap transform: %0.5f, %0.5f, %0.5f, %0.5f", x, y, w, h))
    M.hide()
    loggedMinimapErrors = true
    return
  end
  if drawTransform[1] ~= x or drawTransform[2] ~= y or drawTransform[3] ~= w or drawTransform[4] ~= h then
    drawTransform = {x, y, w, h}
    log("I","",string.format("Setting minimap transform: %0.5f, %0.5f, %0.5f, %0.5f", x, y, w, h))
  end
  if M.onUpdate == nil then
    M.onUpdate = draw
    loggedMinimapErrors = true
    extensions.hookUpdate("onUpdate")
  end
end

local function setOcclusionTransform(id, x, y, w, h)
  occlusionTransforms[id] = {x, y, w, h}
  if x > 1 or x < 0 or y > 1 or y < 0 or w > 1 or w < 0 or h > 1 or h < 0 then
    log("W","",string.format("Invalid minimap occlusion transform: %0.5f, %0.5f, %0.5f, %0.5f", x, y, w, h))
    occlusionTransforms[id] = nil
  end
end
M.setOcclusionTransform = setOcclusionTransform

local function resetOcclusionTransform(id)
  if type(id) == "string" and id ~= "" then
    occlusionTransforms[id] = nil
  else
    occlusionTransforms = {}
  end
end
M.resetOcclusionTransform = resetOcclusionTransform

local function hide()
  drawTransform = {0,0,0,0}
  local splitActive = isSplitScreenActive()
  if not splitActive then
    if M.onUpdate then
      M.onUpdate = nil
      extensions.hookUpdate("onUpdate")
    end
  end
end

local function toggledebugSettings()
  debugSettingsOpen = not debugSettingsOpen
end

local lookaheadValues = {
  disabled = 1,
  low = 2,
  medium = 3,
  high = 4
}

local function onMinimapSettingsChanged(m)
  mode = settings.getValue("minimapMode")
  debugSettings.behaviourRotateWithCam = settings.getValue("minimapOrientation") == "rotateWithCamera"
  debugSettings.drawGrid = settings.getValue("minimapDrawGrid") == "always"
  debugSettings.lookaheadEnabled = settings.getValue("minimapLookahead") ~= "disabled"
  debugSettings.lookaheadValue = lookaheadValues[settings.getValue("minimapLookahead")] or 3
  viewportsEnabled = im.GetConfigFlagsViewportsEnable()

  if mode ~= "circle" and mode ~= "rect" then
    mode = "rect"
  end
end

local function onSplitScreenChanged(splitScreenEnabled, playerCount, layout, splitMode)
  if splitScreenEnabled and playerCount > 1 and splitMode ~= "shared" then
    enableSplitScreenMinimaps()
  else
    disableSplitScreenMinimaps()
  end
end

M.onInit = function()
  setExtensionUnloadMode(M, "manual")
  onMinimapSettingsChanged()
  if isSplitScreenActive() then
    enableSplitScreenMinimaps()
  end
end

M.setDrawTransform = setDrawTransform
M.setBuffers = setBuffers
M.onUpdate = nil
M.hide = hide
M.toggledebugSettings = toggledebugSettings
M.onMinimapSettingsChanged = onMinimapSettingsChanged
M.onSplitScreenChanged = onSplitScreenChanged
M.enableSplitScreenMinimaps = enableSplitScreenMinimaps
M.disableSplitScreenMinimaps = disableSplitScreenMinimaps

M.getMode = function()
  return mode
end

M.getDebugSettingsData = function()
  return debugSettingsData
end

M.onClientEndMission = function()
  M.hide()
  disableSplitScreenMinimaps()
  if ui_apps_minimap_roads then
    ui_apps_minimap_roads.reset()
  end
end

M.onClientStartMission = function()
  M.hide()
  disableSplitScreenMinimaps()
  if ui_apps_minimap_roads then
    ui_apps_minimap_roads.reset()
  end
end

return M
