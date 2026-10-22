-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

require("utils")
local splitScreenLayouts = require("ge/extensions/render/splitScreenLayouts")
local M = {}
M.dependencies = {
  "core_playerPersonas",
  "render_playerTags",
  "render_playerCompassMarkers",
}

local maxViews = 64 -- one view per player; more just shrink, cap keeps it sane
local views = {}                 -- { {name=, rv=, player=}, ... }, view index 1..n
local enabled = false
local lastW, lastH = 0, 0
local lastLayoutId = nil
local customPlayers = nil        -- optional override list; nil = use core_multiseat.getPlayers()
local uiState = nil              -- last state sent to the HUD, re-sent when the HUD route mounts
local lastParticipantRevision = -1
local lastPlayers = {}
local lastShared = nil
local lastRenderedShared = nil
local soloView = nil             -- temporary fullscreen view without changing participants/HUD state
local beginSoloView, endSoloView

local function getConfiguredLayoutId(playerCount)
  local settingsPlayerCount = splitScreenLayouts.getSettingsPlayerCount(playerCount)
  return settings.getValue("multiseatLayout" .. settingsPlayerCount, "automatic")
end

local hudRoute = "multiseat"
local blockedActionsGroup = "splitScreenBlockedActions"
local blockedActions = core_input_actionFilter.createActionTemplate({"vehicleMenues"})

-- split screen renders the world once per view, so each view takes a quality cut that grows with
-- the view count. This is a per-view RenderView override, the user's graphics settings are untouched.
local qualityFactors = {[1] = 1.0, [2] = 0.75, [3] = 0.6, [4] = 0.5}
local minQualityFactor = 0.5

local performancePresetName = "Prioritize Performance"
local performancePresetActive = false

local function setPerformancePreset(active)
  if active == performancePresetActive then return end
  if active then
    performancePresetActive = core_settings_graphic.setPresetOverride({name = performancePresetName, enforce = true}) == true
  else
    core_settings_graphic.setPresetOverride(nil)
    performancePresetActive = false
  end
end

local function viewName(i) return "splitscreen" .. (i - 1) end

local function mainRenderView() return RenderViewManagerInstance:getView("main") end

local function resetExposure()
  local localExposure = scenetree.findObject("PostEffectLocalExposureObject")
  if localExposure then localExposure:resetAutoexposure() end
end

local function isCareerModeActive()
  return (career_career and career_career.isActive and career_career.isActive())
    or (overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive())
    or (core_gamestate and core_gamestate.state and (core_gamestate.state.state == "career" or core_gamestate.state.state == "overhaul"))
end

local function setActionBlocking(block)
  if isCareerModeActive() then
    block = false -- Never block vehicleMenues or radial menu in Career Mode!
  end
  core_input_actionFilter.setGroup(blockedActionsGroup, blockedActions)
  core_input_actionFilter.addAction(0, blockedActionsGroup, block)
end

local function emitUiState()
  if not uiState or (soloView and soloView.mainView) then
    guihooks.trigger('MultiseatHudData', 0)
    return
  end
  guihooks.trigger('MultiseatHudData', uiState.count, uiState.layout, uiState.players, uiState.mode)
end

local function currentRouteName()
  local current = extensions.ui_router.getCurrent()
  return current and current.resolved and current.resolved.name or nil
end

-- the player list defaults to multiseat; missions can override via setCustomPlayers
local function getPlayers(result)
  result = result or {}
  table.clear(result)
  if customPlayers then
    for index, player in ipairs(customPlayers) do result[index] = player end
  elseif core_multiseat then
    core_multiseat.getPlayers(result)
  end
  while #result > maxViews do table.remove(result) end
  if #result == 0 then result[1] = 0 end
  return result
end

local function getParticipants(players)
  if core_multiseat and core_multiseat.getParticipants then
    return core_multiseat.getParticipants(players)
  end
  local participants = {}
  for _, player in ipairs(players) do
    participants[#participants + 1] = {
      id = "local-player:" .. player,
      persona = {
        displayName = extensions.core_playerPersonas.getDefaultDisplayName(player + 1),
        color = {1, 1, 1},
        colorHex = "#ffffff",
        icon = "user",
      },
      assignment = {playerIndex = player, devices = {}, deviceIds = {}},
    }
  end
  return participants
end

-- fractional layout -> pixel rects {x, y, w, h}; edge-based so adjacent views don't gap
local function pixelRects(layout, w, h)
  local r = {}
  for _, f in ipairs(layout) do
    local x, y = math.floor(f[1] * w), math.floor(f[2] * h)
    r[#r + 1] = {x, y, math.max(2, math.floor((f[1] + f[3]) * w) - x), math.max(2, math.floor((f[2] + f[4]) * h) - y)}
  end
  return r
end

local function normalizedRects(rects, w, h)
  local result = {}
  for _, rect in ipairs(rects) do
    result[#result + 1] = {rect[1] / w, rect[2] / h, rect[3] / w, rect[4] / h}
  end
  return result
end

local function destroyViews()
  -- main is inactive while split screen renders, so its exposure would be stale.
  if views[1] and views[1].rv then
    local main = mainRenderView()
    if main then main.currentExposure = views[1].rv.currentExposure end
  end
  for _, v in ipairs(views) do
    if core_camera then core_camera.destroyContext(v.name) end
    if v.rv then RenderViewManagerInstance:destroyView(v.rv) end
  end
  views = {}
end

local function playerMarkersEnabled()
  return false
end

local function rebuildTags(players, shared)
  if extensions.render_playerTags and extensions.render_playerTags.destroy then
    extensions.render_playerTags.destroy()
  end
  if extensions.render_playerCompassMarkers and extensions.render_playerCompassMarkers.destroy then
    extensions.render_playerCompassMarkers.destroy()
  end
end

local function applyQualityOverrides()
  local defaultFactor = qualityFactors[#views] or minQualityFactor
  for _, v in ipairs(views) do
    local isSoloTarget = soloView and v.player == soloView.player
    local factor = isSoloTarget and 1 or defaultFactor
    local s = RenderSettings.getGlobals()
    s.meshDetailAdjust = s.meshDetailAdjust * factor
    s.groundCoverScale = s.groundCoverScale * factor
    if not isSoloTarget then
      s.vehicleMirrorsEnabled = false -- each mirror is an extra cubemap render, too expensive per view
      s.vehicleDynamicReflectionsEnabled = false
    end
    v.rv.settingsOverride = s -- returned by value, the whole struct has to be written back
    v.rv.settingsOverrideEnabled = true
  end
end

local function buildViews(players)
  destroyViews()
  local main = mainRenderView()
  for i, player in ipairs(players) do
    local name = viewName(i)
    local rv = RenderViewManagerInstance:getOrCreateView(name)
    rv.luaOwned = true
    rv.renderEditorIcons = false
    rv.namedTexTargetColor = name -- render to an offscreen texture, composited by C++
    if main then
      rv.upscaleMode = main.upscaleMode
      rv.upscaleRenderScale = main.upscaleRenderScale
      rv.upscaleSharpness = main.upscaleSharpness
      rv.currentExposure = main.currentExposure -- a new view starts at the default exposure and blows out until it adapts
    end
    views[i] = {name = name, rv = rv, player = player}
    rv.playerIndex = player
    rv:maskSet(player)
    if core_camera then
      core_camera.createContext(name, name, player)
      core_camera.setContextCamera(name, "orbit", false)
      if core_camera.resetCamera then core_camera.resetCamera(player) end
    end
  end
  applyQualityOverrides()
  rebuildTags(players, false)
end

local function applyLayout(rects)
  for i, v in ipairs(views) do
    local r = rects[i]
    local vw, vh = math.max(2, r[3]), math.max(2, r[4])
    v.markerRect = r
    v.rv.resolution = Point2I(vw, vh)
    v.rv.viewPort = RectI(0, 0, vw, vh)              -- fill the view's own texture
    v.rv.compositeRect = RectI(r[1], r[2], vw, vh)   -- where C++ copies it in the window
  end
end

local function applySoloLayout(w, h)
  for _, v in ipairs(views) do
    if v.player == soloView.player then
      v.rv.resolution = Point2I(w, h)
      v.rv.viewPort = RectI(0, 0, w, h)
      v.rv.compositeRect = RectI(0, 0, w, h)
    else
      v.rv.resolution = Point2I(2, 2)
      v.rv.viewPort = RectI(0, 0, 2, 2)
      v.rv.compositeRect = RectI(-2, -2, 2, 2)
    end
  end
end

local function windowSize()
  local canvas = scenetree.findObject("Canvas")
  if canvas and canvas.getWindowClientSizeXY then
    local w, h = canvas:getWindowClientSizeXY()
    if w and h and w >= 2 and h >= 2 then
      return w, h
    end
  end
  local vm = GFXDevice.getVideoMode()
  return vm.width, vm.height
end

-- rebuild when the player list changes, relayout when the window size changes
local reconfigurePlayers = {}
local function reconfigure(dt)
  local w, h = windowSize()
  if not w or not h or w < 2 or h < 2 then return end

  local players = getPlayers(reconfigurePlayers)
  local playerCountChanged = #players ~= #lastPlayers
  local playersChanged = playerCountChanged
  for i = 1, #players do if lastPlayers[i] ~= players[i] then playersChanged = true end end
  local participantRevision = (core_multiseat and core_multiseat.getParticipantRevision and core_multiseat.getParticipantRevision()) or 0
  local participantsChanged = participantRevision ~= lastParticipantRevision
  local layoutId = getConfiguredLayoutId(#players)
  local shared = splitScreenLayouts.isShared(layoutId)
  local renderedShared = (shared and soloView == nil) or (soloView ~= nil and soloView.mainView == true)
  local telemetryChanged = playersChanged or layoutId ~= lastLayoutId or shared ~= lastShared
  if playersChanged or renderedShared ~= lastRenderedShared then
    if renderedShared then
      destroyViews()
      setRenderWorldMain(true)
      rebuildTags(players, true)
    else
      setRenderWorldMain(false)
      buildViews(players)
    end
    lastW, lastH = 0, 0 -- force a relayout
  elseif participantsChanged then
    rebuildTags(players, shared)
  end
  local tagsEnabled = playerMarkersEnabled()
  if tagsEnabled and #players > 0 and not extensions.render_playerTags.hasTags() then
    rebuildTags(players, shared)
  elseif not tagsEnabled and extensions.render_playerTags.hasTags() then
    extensions.render_playerTags.destroy()
  end
  if w ~= lastW or h ~= lastH or participantsChanged or layoutId ~= lastLayoutId then
    local layout = splitScreenLayouts.getLayout(#players, layoutId, w, h)
    local rects = pixelRects(layout, w, h)
    if not renderedShared then
      if soloView then
        applySoloLayout(w, h)
      else
        applyLayout(rects)
      end
    end
    resetExposure()
    local playerInfos = {}
    for _, participant in ipairs(getParticipants(players)) do
      playerInfos[#playerInfos + 1] = {
        id = participant.id,
        player = participant.assignment.playerIndex,
        label = participant.persona.displayName,
        icon = participant.persona.icon,
        color = participant.persona.colorHex,
        device = participant.assignment.connected and participant.assignment.connectedDeviceLabel
          or participant.assignment.deviceLabel,
        deviceIcon = participant.assignment.connected and participant.assignment.connectedInputIcon
          or participant.inputIcon,
        deviceIds = participant.assignment.deviceIds,
        connected = participant.assignment.connected ~= false,
      }
    end
    uiState = {count = #players, layout = normalizedRects(rects, w, h), players = playerInfos, mode = shared and "shared" or "split"}
    emitUiState()
    extensions.hook("onSplitScreenLayoutChanged")
    if telemetryChanged then
      extensions.hook("onSplitScreenChanged", true, #players, layoutId, uiState.mode)
    end
    lastW, lastH = w, h
    lastLayoutId = layoutId
  end
  table.clear(lastPlayers)
  for i = 1, #players do lastPlayers[i] = players[i] end
  lastShared = shared
  lastRenderedShared = renderedShared
  lastParticipantRevision = participantRevision
  if tagsEnabled and not soloView then extensions.render_playerTags.updatePositions(dt) end
end

-- players: ordered list of player indices that should get a view, or nil to clear the override
local function setCustomPlayers(players)
  if players == nil then
    customPlayers = nil
  else
    customPlayers = {}
    for _, player in ipairs(players) do
      customPlayers[#customPlayers + 1] = player
      if #customPlayers >= maxViews then break end
    end
    if #customPlayers == 0 then customPlayers = nil end
  end
  if enabled then
    lastW, lastH = 0, 0
    reconfigure()
  end
end

local function clearCustomPlayers()
  setCustomPlayers(nil)
end

local function enable()
  if enabled then return end
  enabled = true
  setActionBlocking(true)
  settings.setValue('multiseat', true) -- device->player assignment, seating, MultiseatActionMap
  --setPerformancePreset(true)
  extensions.ui_menuManager.setGameplayRoute(hudRoute)
  if currentRouteName() == "play" then
    extensions.ui_router.navigate(hudRoute)
  end
  lastW, lastH = 0, 0
  reconfigure()
end

local function disable(preserveRoute)
  if not enabled then return end
  extensions.hook("onSplitScreenChanged", false)
  enabled = false
  if core_camera and core_camera.setInputTargetPlayer then
    core_camera.setInputTargetPlayer(nil)
  end
  if soloView and not soloView.mainView and soloView.contextId and soloView.cameraState and core_camera then
    core_camera.setContextCameraState(soloView.contextId, soloView.cameraState)
  end
  soloView = nil
  setActionBlocking(false)
  customPlayers = nil
  uiState = nil
  lastParticipantRevision = -1
  lastLayoutId = nil
  lastPlayers = {}
  lastShared = nil
  lastRenderedShared = nil
  destroyViews()
  extensions.render_playerTags.reset()
  setRenderWorldMain(true)
  resetExposure()
  --setPerformancePreset(false)
  extensions.render_playerCompassMarkers.destroy()
  guihooks.trigger('MultiseatHudData', 0)
  if not preserveRoute then
    extensions.ui_menuManager.setGameplayRoute(nil)
    if currentRouteName() == hudRoute then
      extensions.ui_router.navigate("play")
    end
  end
  lastW, lastH = 0, 0
end

local function onBeforeBigMapActivated()
  if enabled and not soloView then
    beginSoloView(0, {mainView = true})
  end
end

local function onActivateBigMapCallback()
  if enabled and not soloView then
    beginSoloView(0, {mainView = true})
  end
end

local function onDeactivateBigMapCallback()
  if enabled and soloView and soloView.mainView then
    endSoloView()
    if extensions.ui_router and currentRouteName() ~= hudRoute and not string.find(currentRouteName() or "", "pause") then
      extensions.ui_router.navigate(hudRoute)
    end
  end
end

-- the HUD view mounts with its route, so re-send the state every time that route is entered
local function onAfterRouteChange(context)
  local toRoute = context and context.toRoute
  local toRouteName = toRoute and toRoute.name
  if enabled and toRouteName == hudRoute then
    if not (soloView and soloView.mainView) then
      emitUiState()
    else
      guihooks.trigger('MultiseatHudData', 0)
    end
  elseif enabled and not soloView and toRouteName == "play" then
    extensions.ui_router.navigate(hudRoute)
  elseif enabled and (toRouteName == "bigmap" or toRouteName == "pause" or toRouteName == "menu") then
    guihooks.trigger('MultiseatHudData', 0)
  end
end

local function onUpdate(dtReal, dtSim)
  if enabled then
    reconfigure(dtReal)
    if extensions.render_playerCompassMarkers and extensions.render_playerCompassMarkers.destroy then
      extensions.render_playerCompassMarkers.destroy()
    end
  end
end

-- the overrides snapshot the global settings, so they have to be rebuilt when those change
local function onSettingsChanged()
  if enabled then applyQualityOverrides() end
end

local function viewForPlayer(player)
  for _, v in ipairs(views) do
    if v.player == player then return v end
  end
end

endSoloView = function()
  if not soloView then return false end
  local previous = soloView
  if core_camera and core_camera.setInputTargetPlayer then
    core_camera.setInputTargetPlayer(nil)
  end
  soloView = nil
  lastW, lastH = 0, 0
  if enabled then
    reconfigure()
    for _, v in ipairs(views) do
      if core_camera then
        local st = previous.savedCameraStates and previous.savedCameraStates[v.name]
        if st and st.cam and st.cam ~= "free" and st.cam ~= "bigMap" and st.cam ~= "transition" then
          core_camera.setContextCameraState(v.name, st)
        else
          core_camera.setContextCamera(v.name, "orbit", false)
        end
        if core_camera.resetCamera then core_camera.resetCamera(v.player) end
      end
    end
    applyQualityOverrides()
    local players = getPlayers()
    local layoutId = getConfiguredLayoutId(#players)
    rebuildTags(players, splitScreenLayouts.isShared(layoutId))
    emitUiState()
  end
  return true
end

beginSoloView = function(player, options)
  player = tonumber(player)
  if player == nil then return false end
  local mainView = type(options) == "table" and options.mainView == true
  if soloView and soloView.player == player and (soloView.mainView == true) == mainView then return true end
  if soloView then endSoloView() end

  local found = false
  for _, configuredPlayer in ipairs(getPlayers()) do
    if configuredPlayer == player then
      found = true
      break
    end
  end
  if not found then return false end

  if mainView then
    local contextId = core_camera and core_camera.getContextIdForPlayer and core_camera.getContextIdForPlayer(player) or nil
    local cameraState = core_camera and core_camera.getContextCameraState and core_camera.getContextCameraState(contextId) or nil
    local savedStates = {}
    for _, v in ipairs(views) do
      if core_camera and core_camera.getContextCameraState then
        savedStates[v.name] = core_camera.getContextCameraState(v.name)
      end
    end
    soloView = {
      player = player,
      mainView = true,
      contextId = contextId,
      cameraState = cameraState,
      savedCameraStates = savedStates,
    }
    if core_camera and core_camera.setInputTargetPlayer then
      core_camera.setInputTargetPlayer(player)
    end
    lastW, lastH = 0, 0
    if enabled then reconfigure() end
    extensions.render_playerTags.destroy()
    emitUiState()
    return true
  end

  soloView = {player = player}
  lastW, lastH = 0, 0
  if enabled then reconfigure() end

  local view = viewForPlayer(player)
  if not view then
    soloView = nil
    lastW, lastH = 0, 0
    if enabled then reconfigure() end
    return false
  end

  soloView.contextId = view.name
  if core_camera then
    if core_camera.setInputTargetPlayer then
      core_camera.setInputTargetPlayer(player)
    end
    soloView.cameraState = core_camera.getContextCameraState(view.name)
    core_camera.setContextCamera(view.name, "orbit", false)
  end
  extensions.render_playerTags.destroy()
  applyQualityOverrides()
  lastW, lastH = 0, 0
  if enabled then reconfigure() end
  return true
end

-- step this player's own view to the next camera group.
-- returns false if the player has no split-screen view, so the caller can fall back
-- to the regular main-camera toggle.
local function toggleFreeCam(player)
  local v = viewForPlayer(player)
  if not v or not core_camera then return false end
  core_camera.cycleCameraGroup(player) -- per-context: steps this view to the next camera group
  return true
end

local function refreshLayout()
  lastW, lastH = 0, 0
  lastLayoutId = nil
  if enabled then reconfigure() end
end

local function getCurrentConfiguration()
  if not enabled or not uiState then return false end
  return true, uiState.count, lastLayoutId, uiState.mode
end

local function isSharedView()
  return enabled and lastRenderedShared == true and soloView == nil
end

local function onSerialize(reason)
  local data = {customPlayers = deepcopy(customPlayers)}
  log("I", "multiseatReload", string.format(
    "split-screen serialize: reason=%s customPlayers=%d soloOverrideCleared=%s",
    tostring(reason),
    #(data.customPlayers or {}),
    tostring(soloView ~= nil)
  ))
  disable(true)
  return data
end

local function onDeserialized(data)
  setCustomPlayers(type(data) == "table" and data.customPlayers or nil)
  enable()
  log("I", "multiseatReload", string.format(
    "split-screen deserialize: customPlayers=%d enabled=%s soloOverride=false",
    #(customPlayers or {}),
    tostring(enabled)
  ))
end

local function onExtensionLoaded(data)
  setCustomPlayers(type(data) == "table" and data.customPlayers or nil)
  enable()
  log("I", "multiseatReload", string.format(
    "split-screen extension loaded: serializedData=%s customPlayers=%d",
    tostring(type(data) == "table"),
    #(customPlayers or {})
  ))
end

M.getPlayers = getPlayers
M.getCurrentConfiguration = getCurrentConfiguration
M.isSharedView = isSharedView
M.setCustomPlayers = setCustomPlayers
M.clearCustomPlayers = clearCustomPlayers
M.toggleFreeCam = toggleFreeCam
M.refreshLayout = refreshLayout
M.beginSoloView = beginSoloView
M.endSoloView = endSoloView
M.getUiState = function() return uiState end
M.getViews = function() return views end
M.getSoloView = function() return soloView end
M.isEnabled = function() return enabled end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = disable
M.onUpdate = onUpdate
M.onAfterRouteChange = onAfterRouteChange
M.onSettingsChanged = onSettingsChanged
M.onBeforeBigMapActivated = onBeforeBigMapActivated
M.onActivateBigMapCallback = onActivateBigMapCallback
M.onDeactivateBigMapCallback = onDeactivateBigMapCallback
M.onClientEndMission = endSoloView
M.onSerialize = onSerialize     -- tear down C++ views before a GE/Lua reload
M.onDeserialized = onDeserialized

return M
