-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Career Mode Split-Screen Co-op Mod
-- Enables native local split-screen multiplayer inside BeamNG.drive Career Mode.

local M = {}

M.dependencies = {
  "core_multiseat",
  "core_camera",
}

local isSplitActive = false
local p2VehicleId = nil
local p2InventoryId = nil
local p2PassengerSeatId = nil
local p2IsWalking = false
local guestVehicleId = nil
local quickAccessInitialized = false

-- Universal Career Mode detection supporting Vanilla Career and RLS Career Overhaul
local function isCareerModeActive()
  if career_career and career_career.isActive and career_career.isActive() then
    return true
  end
  if overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive() then
    return true
  end
  if overhaul_shell_gameMode and overhaul_shell_gameMode.isActive and overhaul_shell_gameMode.isActive() then
    return true
  end
  local state = core_gamestate and core_gamestate.state and core_gamestate.state.state
  if state == "career" or state == "overhaul" then
    return true
  end
  return false
end

-- Universal Inventory resolver (Vanilla career_modules_inventory or RLS overhaul_career_garage_inventory)
local function getInventoryModule()
  if overhaul_career_garage_inventory then
    return overhaul_career_garage_inventory
  end
  if career_modules_inventory then
    return career_modules_inventory
  end
  return nil
end

local function isActive()
  return isSplitActive
end

local function getP2Vehicle()
  if not isSplitActive then return nil end
  local veh = getPlayerVehicle(1)
  if veh then return veh end
  if p2VehicleId then
    veh = getObjectByID(p2VehicleId)
    if veh then return veh end
  end
  if gameplay_walk and gameplay_walk.getCurrentUnicycle then
    local unicycle = gameplay_walk.getCurrentUnicycle(1)
    if unicycle then return unicycle end
  end
  return nil
end

local function isSplitModeActive()
  return isSplitActive or (render_splitScreen and render_splitScreen.isEnabled and render_splitScreen.isEnabled())
end

-- Hook marker interaction to ensure prompts are never suppressed during Career Split-Screen
local function hookMarkerInteraction()
  local function wrapPreRender(ext, name)
    if not ext or ext._careerSplitMarkerHooked then return end
    ext._careerSplitMarkerHooked = true
    local origPreRender = ext.onPreRender
    ext.onPreRender = function(...)
      if isSplitModeActive() and core_multiseat and core_multiseat.isMultiseatActive then
        local origIsMultiseatActive = core_multiseat.isMultiseatActive
        core_multiseat.isMultiseatActive = function() return false end
        local ok, err = pcall(origPreRender, ...)
        core_multiseat.isMultiseatActive = origIsMultiseatActive
        if not ok then
          log("E", "careerSplitScreen", "Error during " .. tostring(name) .. " onPreRender: " .. tostring(err))
        end
        return
      end
      if origPreRender then
        return origPreRender(...)
      end
    end
    log("I", "careerSplitScreen", "Hooked " .. tostring(name) .. " for split-screen marker interaction.")
  end

  wrapPreRender(gameplay_markerInteraction, "gameplay_markerInteraction")
  wrapPreRender(overhaul_integration_services_markerInteraction, "overhaul_integration_services_markerInteraction")
end

local function selectAtCursor()
  if not freeroam_bigMapMode or not freeroam_bigMapMode.bigMapActive() then return end

  -- 1. If a POI is hovered under the crosshair, select it
  if freeroam_bigMapMode.hoveredPoiId then
    if freeroam_bigMapMode.selectPoi then
      freeroam_bigMapMode.selectPoi(freeroam_bigMapMode.hoveredPoiId)
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Main>select')
      return
    end
  end

  -- 2. If a POI is currently selected, deselect it
  if freeroam_bigMapMode.selectedPoiId then
    if freeroam_bigMapMode.deselect then
      freeroam_bigMapMode.deselect()
      return
    end
  end

  -- 3. Raycast down from the center crosshair
  local camDir = core_camera.getQuat() * vec3(0, 1, 0)
  local ray = {pos = core_camera.getPosition(), dir = camDir}
  local hitDist = castRayStatic(ray.pos, ray.dir, 50000)
  if hitDist < 50000 then
    local hitPos = ray.pos + ray.dir * hitDist
    local currentTarget = (core_groundMarkers and core_groundMarkers.getTargetPlayer and core_groundMarkers.getTargetPlayer()) or 0
    if core_groundMarkers and core_groundMarkers.currentlyHasTarget and core_groundMarkers.currentlyHasTarget(currentTarget) then
      freeroam_bigMapMode.setNavFocus(nil)
    else
      freeroam_bigMapMode.setNavFocus(hitPos)
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Main>Click_Tonal_01')
    end
  end
end

local function bindBigMapSelectKeys()
  local am = scenetree.findObject("BigMapActionMap")
  if am and core_input_actions and core_input_actions.actionToCommands then
    local success, actionMap, actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp, isRelative, ctx, isCentered = core_input_actions.actionToCommands("bigMapControllerSelect")
    local jsonFfb = jsonEncode({updateType = 0})
    for devname, _ in pairs(core_input_bindings.devices or {}) do
      if string.find(devname, "keyboard") then
        pcall(function()
          am:bind(devname, "bigMapControllerSelect", "return", isCentered, 0, 0, 1, 0, 0, false, false, false, false, 0, 0, 0, jsonFfb, actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp, 0, isRelative, 0, ctx)
          am:bind(devname, "bigMapControllerSelect", "enter", isCentered, 0, 0, 1, 0, 0, false, false, false, false, 0, 0, 0, jsonFfb, actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp, 0, isRelative, 0, ctx)
          am:bind(devname, "bigMapControllerSelect", "numpadenter", isCentered, 0, 0, 1, 0, 0, false, false, false, false, 0, 0, 0, jsonFfb, actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp, 0, isRelative, 0, ctx)
          am:bind(devname, "bigMapControllerSelect", "space", isCentered, 0, 0, 1, 0, 0, false, false, false, false, 0, 0, 0, jsonFfb, actsOnChange, onChange, actsOnDown, onDown, actsOnUp, onUp, 0, isRelative, 0, ctx)
        end)
      end
    end
  end
end

local function hookBigMapMode()
  if freeroam_bigMapMode and not freeroam_bigMapMode._careerSplitHooked then
    freeroam_bigMapMode._careerSplitHooked = true

    -- Hook camMode.onMouseButton: in split-screen mode, left click should not drag or pan the map
    local camMode = core_camera and core_camera.getGlobalCameras and core_camera.getGlobalCameras()["bigMap"]
    if camMode and not camMode._careerSplitHooked then
      camMode._careerSplitHooked = true
      local origCamOnMouseButton = camMode.onMouseButton
      camMode.onMouseButton = function(self, buttonDown, mouseDragging, ...)
        if isSplitModeActive() then
          -- In split-screen: left click should not drag or pan the map
          return
        end
        if origCamOnMouseButton then
          return origCamOnMouseButton(self, buttonDown, mouseDragging, ...)
        end
      end
    end

    local origToggleBigMap = freeroam_bigMapMode.toggleBigMap
    freeroam_bigMapMode.toggleBigMap = function(...)
      if isSplitModeActive() or isCareerModeActive() then
        if freeroam_bigMapMode.bigMapActive() then
          freeroam_bigMapMode.exitBigMap(true, true)
          return
        else
          if overhaul_phone_phone and overhaul_phone_phone.isPhoneOpen and overhaul_phone_phone.isPhoneOpen() then
            overhaul_phone_phone.closePhone()
          end
          freeroam_bigMapMode.enterBigMap({instant = true, forceOpen = true})
          return
        end
      end
      if origToggleBigMap then
        return origToggleBigMap(...)
      end
    end

    local origEnterBigMap = freeroam_bigMapMode.enterBigMap
    freeroam_bigMapMode.enterBigMap = function(options, ...)
      options = options or {}
      if isSplitModeActive() then
        options.instant = true
        options.forceOpen = true
      end
      if origEnterBigMap then
        local res = origEnterBigMap(options, ...)
        if isSplitModeActive() then
          bindBigMapSelectKeys()
        end
        return res
      end
    end

    local origExitBigMap = freeroam_bigMapMode.exitBigMap
    freeroam_bigMapMode.exitBigMap = function(instant, closeEscMenu, forceGameCam, ...)
      if isSplitModeActive() then
        instant = true
      end
      local res
      if origExitBigMap then
        res = origExitBigMap(instant, closeEscMenu, forceGameCam, ...)
      end
      if isSplitModeActive() then
        if extensions.ui_menuManager and extensions.ui_menuManager.setGameplayRoute then
          extensions.ui_menuManager.setGameplayRoute("multiseat")
        end
        if extensions.ui_router and extensions.ui_router.reload then
          extensions.ui_router.reload("multiseat", nil, {force = true})
        end
      end
      return res
    end

    -- Hook onCameraPreRender: crosshair is always visible ONLY in split-screen mode
    local origOnCameraPreRender = freeroam_bigMapMode.onCameraPreRender
    freeroam_bigMapMode.onCameraPreRender = function(camData, ...)
      if origOnCameraPreRender then
        origOnCameraPreRender(camData, ...)
      end
      if isSplitModeActive() and freeroam_bigMapMode.bigMapActive() then
        local iconRenderer = gameplay_playmodeMarkers and gameplay_playmodeMarkers.getBigmapRendererObj and gameplay_playmodeMarkers.getBigmapRendererObj()
        if iconRenderer then
          local crosshair = iconRenderer:getIconByName("controllerCrosshair")
          if crosshair then
            crosshair.color = ColorI(255, 255, 255, 255)
          end
        end
      end
    end

    -- Hook onMouseButton: in split-screen mode, mouse left click sets route or selects POI without dragging the map
    local origOnMouseButton = freeroam_bigMapMode.onMouseButton
    freeroam_bigMapMode.onMouseButton = function(buttonDown, ...)
      if isSplitModeActive() and freeroam_bigMapMode.bigMapActive() then
        -- Check if mouse click is on our ImGui Top Bar (Route For: P1, P2)
        local im = ui_imgui
        if im and im.GetMousePos then
          local mPos = im.GetMousePos()
          local canvas = scenetree.findObject("Canvas")
          local winW = 1920
          if canvas and canvas.getWindowClientSizeXY then
            winW = canvas:getWindowClientSizeXY()
          end
          local barW = 540
          local minX = (winW - barW) * 0.5
          local maxX = (winW + barW) * 0.5
          if mPos and mPos.x >= minX and mPos.x <= maxX and mPos.y >= 0 and mPos.y <= 75 then
            -- Click is inside the Top Bar; let ImGui handle it exclusively
            return
          end
        end

        local cMode = core_camera and core_camera.getGlobalCameras and core_camera.getGlobalCameras()["bigMap"]
        if cMode and cMode.onMouseButton then
          cMode:onMouseButton(false, false)
        end

        if not buttonDown then
          -- Left mouse release: set route or select hovered POI without map drag
          if freeroam_bigMapMode.hoveredPoiId then
            if freeroam_bigMapMode.selectPoi then
              freeroam_bigMapMode.selectPoi(freeroam_bigMapMode.hoveredPoiId)
              Engine.Audio.playOnce('AudioGui', 'event:>UI>Main>select')
              return
            end
          end

          local ray = getCameraMouseRay()
          if ray then
            local hitDist = castRayStatic(ray.pos, ray.dir, 50000)
            if hitDist < 50000 then
              local hitPos = ray.pos + ray.dir * hitDist
              local currentTarget = (core_groundMarkers and core_groundMarkers.getTargetPlayer and core_groundMarkers.getTargetPlayer()) or 0
              if core_groundMarkers and core_groundMarkers.currentlyHasTarget and core_groundMarkers.currentlyHasTarget(currentTarget) then
                freeroam_bigMapMode.setNavFocus(nil)
              else
                freeroam_bigMapMode.setNavFocus(hitPos)
                Engine.Audio.playOnce('AudioGui', 'event:>UI>Main>Click_Tonal_01')
              end
              return
            end
          end
        end
        return
      end

      if origOnMouseButton then
        return origOnMouseButton(buttonDown, ...)
      end
    end

    -- Hook onControllerSelect: sets route or selects POI under the center crosshair
    local origOnControllerSelect = freeroam_bigMapMode.onControllerSelect
    freeroam_bigMapMode.onControllerSelect = function(...)
      if isSplitModeActive() and freeroam_bigMapMode.bigMapActive() then
        selectAtCursor()
        return
      end

      if origOnControllerSelect then
        return origOnControllerSelect(...)
      end
    end

    log("I", "careerSplitScreen", "Hooked freeroam_bigMapMode: split-screen controller crosshair and drag-free route clicks.")
  end
end

-- Safely orient and place Player 2 relative to Player 1
local function positionP2NearP1(p1Veh, p2Veh, resetVehicle)
  if not p1Veh or not p2Veh then return end
  local p1Pos = p1Veh:getPosition()
  local p1Dir = p1Veh:getDirectionVector()
  local p1Up = vec3(0, 0, 1)
  local p1Right = p1Dir:cross(p1Up):normalized()
  local p1Rot = quatFromDir(p1Dir, p1Up)

  -- Place 7.5 meters behind and 3.5 meters to the right (like a follower vehicle)
  local targetPos = p1Pos - (p1Dir * 7.5) + (p1Right * 3.5)
  spawn.safeTeleport(p2Veh, targetPos, p1Rot, nil, nil, nil, true, resetVehicle or false)
  core_vehicleBridge.executeAction(p2Veh, 'setIgnitionLevel', 2)
end

-- Look for an owned vehicle or spawn a guest vehicle
local function findOrSpawnP2Vehicle(callback, preferredInvId)
  local inv = getInventoryModule()
  local currentInvId = inv and inv.getCurrentVehicle and inv.getCurrentVehicle()
  local invMap = inv and inv.getMapInventoryIdToVehId and inv.getMapInventoryIdToVehId() or {}
  local vehicles = inv and inv.getVehicles and inv.getVehicles() or {}

  -- 1. Try preferred inventory vehicle if requested
  if preferredInvId and vehicles[preferredInvId] and preferredInvId ~= currentInvId then
    if invMap[preferredInvId] then
      local veh = getObjectByID(invMap[preferredInvId])
      if veh and veh:getActive() then
        callback(veh, preferredInvId, false)
        return
      end
    else
      if inv and inv.spawnVehicle then
        inv.spawnVehicle(preferredInvId, nil, function(spawnedVeh)
          if not spawnedVeh and inv.getVehicleIdFromInventoryId then
            local vId = inv.getVehicleIdFromInventoryId(preferredInvId)
            if vId then spawnedVeh = getObjectByID(vId) end
          end
          callback(spawnedVeh, preferredInvId, false)
        end)
        return
      end
    end
  end

  -- 2. Check if another owned vehicle is already spawned in the world
  for invId, vehId in pairs(invMap) do
    if invId ~= currentInvId then
      local veh = getObjectByID(vehId)
      if veh and veh:getActive() then
        callback(veh, invId, false)
        return
      end
    end
  end

  -- 3. Check if an owned vehicle exists in inventory that is not yet spawned
  for invId, vehData in pairs(vehicles) do
    if invId ~= currentInvId and not invMap[invId] then
      if inv and inv.spawnVehicle then
        inv.spawnVehicle(invId, nil, function(spawnedVeh)
          if not spawnedVeh and inv.getVehicleIdFromInventoryId then
            local vId = inv.getVehicleIdFromInventoryId(invId)
            if vId then spawnedVeh = getObjectByID(vId) end
          end
          callback(spawnedVeh, invId, false)
        end)
        return
      end
    end
  end

  -- 4. No secondary vehicle owned. Spawn a temporary buddy/guest vehicle
  local p1Veh = getPlayerVehicle(0)
  if not p1Veh then
    callback(nil, nil, false)
    return
  end

  local p1Pos = p1Veh:getPosition()
  local p1Dir = p1Veh:getDirectionVector()
  local p1Up = vec3(0, 0, 1)
  local p1Right = p1Dir:cross(p1Up):normalized()
  local spawnPos = p1Pos - (p1Dir * 7.5) + (p1Right * 3.5)
  local spawnRot = quatFromDir(p1Dir, p1Up)

  local guestModel = "covet"
  local guestConfig = "vehicles/covet/DXi_A.pc"
  if not FS:fileExists("/" .. guestConfig) then
    guestConfig = nil
  end

  local spawnData = {
    model = guestModel,
    config = guestConfig,
    pos = spawnPos,
    rot = spawnRot,
    autoEnterVehicle = false
  }

  core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = true})
  local guestVeh = core_vehicles.spawnNewVehicle(guestModel, spawnData)
  if guestVeh then
    callback(guestVeh, nil, true)
  else
    callback(nil, nil, false)
  end
end

local function startSplitScreen()
  if isSplitActive then
    guihooks.trigger("toastrMsg", {
      type = "warning",
      title = "Career Split-Screen",
      msg = "Split-Screen is already active!"
    })
    return
  end

  if not isCareerModeActive() then
    guihooks.trigger("toastrMsg", {
      type = "warning",
      title = "Career Split-Screen",
      msg = "Career Mode must be active to start."
    })
    return
  end

  local p1Veh = getPlayerVehicle(0)
  if not p1Veh then
    guihooks.trigger("toastrMsg", {
      type = "error",
      title = "Career Split-Screen",
      msg = "You must be inside or near a vehicle to start split-screen."
    })
    return
  end

  local p1VehId = p1Veh:getId()
  local p1IsWalking = (gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking(0))
    or (p1Veh.getJBeamFilename and p1Veh:getJBeamFilename() == "unicycle")

  -- Check if Player 1's vehicle has an available passenger seat
  local assignedSeatId = nil
  if not p1IsWalking and gameplay_seatOccupants and gameplay_seatOccupants.getSeats then
    local seats = gameplay_seatOccupants.getSeats(p1VehId) or {}
    for _, s in ipairs(seats) do
      if not s.occupied and not s.isDriver then
        assignedSeatId = s.seatId
        break
      end
    end
  end

  if assignedSeatId then
    -- Player 2 sits as passenger in the SAME vehicle as Player 1 (NO teleporting, NO extra car)
    if gameplay_seatOccupants and gameplay_seatOccupants.setOccupied then
      gameplay_seatOccupants.setOccupied(p1VehId, assignedSeatId, 1)
    end
    be:enterVehicle(1, p1Veh)
    p2VehicleId = p1VehId
    p2PassengerSeatId = assignedSeatId
    p2IsWalking = false
  else
    -- Fallback: If vehicle seats are full, 1-seater, or player is walking: spawn Player 2 walking next to the vehicle
    local p1Pos = p1Veh:getPosition()
    local p1Dir = p1Veh:getDirectionVector()
    local p1Up = vec3(0, 0, 1)
    local p1Right = p1Dir:cross(p1Up):normalized()
    local walkPos = p1Pos + (p1Right * 1.8)
    local walkRot = quatFromDir(p1Dir, p1Up)

    if gameplay_walk and gameplay_walk.setWalkingMode then
      gameplay_walk.setWalkingMode(true, walkPos, walkRot, true, 1)
    end
    local p2Unicycle = gameplay_walk and gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle(1)
    p2VehicleId = p2Unicycle and p2Unicycle:getId() or nil
    p2PassengerSeatId = nil
    p2IsWalking = true
  end

  -- Auto-configure controller/keyboard device mapping
  if core_input_bindings and core_input_bindings.devices then
    local devices = core_input_bindings.devices
    local gamepads = {}
    for devname, _ in pairs(devices) do
      if string.find(devname, "xinput") or string.find(devname, "dinput") or string.find(devname, "joystick") then
        table.insert(gamepads, devname)
      end
    end
    table.sort(gamepads)

    local devMap = {}
    if #gamepads >= 2 then
      devMap[gamepads[1]] = 0
      devMap[gamepads[2]] = 1
      devMap["keyboard0"] = 0
      if devices["mouse0"] then devMap["mouse0"] = 0 end
    elseif #gamepads == 1 then
      devMap["keyboard0"] = 0
      if devices["mouse0"] then devMap["mouse0"] = 0 end
      devMap[gamepads[1]] = 1
    else
      devMap["keyboard0"] = 0
      if devices["mouse0"] then devMap["mouse0"] = 0 end
    end

    for devname, player in pairs(devMap) do
      if core_multiseat and core_multiseat.setDevicePlayer then
        core_multiseat.setDevicePlayer(devname, player)
      end
      core_input_bindings.setPlayerToDevice(devname, player)
    end
  end

  -- Enable multiseat settings & extensions
  settings.setValue('multiseat', true)
  if core_multiseat then
    core_multiseat.setMultiseatActive(true)
    if core_multiseat.joinPlayer then
      core_multiseat.joinPlayer(0)
      core_multiseat.joinPlayer(1)
    end
  end

  -- CRUCIAL: refreshAssignedPlayers with seatPlayers = false so multiseat does not unseat players!
  if core_input_bindings and core_input_bindings.refreshAssignedPlayers then
    core_input_bindings.refreshAssignedPlayers(false, false)
  end

  if ui_apps_minimap_minimap and ui_apps_minimap_minimap.disableSplitScreenMinimaps then
    ui_apps_minimap_minimap.disableSplitScreenMinimaps()
  end

  -- Load and initialize split screen render views
  extensions.load("render_splitScreen")
  if render_splitScreen and render_splitScreen.setCustomPlayers then
    render_splitScreen.setCustomPlayers({0, 1})
  end

  -- Re-verify seating
  be:enterVehicle(0, p1Veh)
  if p2PassengerSeatId then
    be:enterVehicle(1, p1Veh)
  elseif p2IsWalking then
    local p2Unicycle = gameplay_walk and gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle(1)
    if p2Unicycle then
      be:enterVehicle(1, p2Unicycle)
    end
  end

  if core_camera then
    core_camera.resetCamera(0)
    core_camera.resetCamera(1)
  end

  extensions.load("gameplay_traffic_source")
  if gameplay_traffic_source and gameplay_traffic_source.autoAddPlayers then
    gameplay_traffic_source.autoAddPlayers()
  end

  -- Unblock radial menu in Career Mode so Player 0 can still use the radial menu (E)
  if core_input_actionFilter and core_input_actionFilter.addAction then
    core_input_actionFilter.addAction(0, "splitScreenBlockedActions", false)
  end

  isSplitActive = true
  hookBigMapMode()
  hookMarkerInteraction()

  if overhaul_integration_services_markerInteraction and overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt then
    overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
  end
  if gameplay_markerInteraction and gameplay_markerInteraction.setForceReevaluateOpenPrompt then
    gameplay_markerInteraction.setForceReevaluateOpenPrompt()
  end

  -- Set the gameplay route to multiseat so MultiseatHud mounts and displays speedometers for both players
  if extensions.ui_menuManager and extensions.ui_menuManager.setGameplayRoute then
    extensions.ui_menuManager.setGameplayRoute("multiseat")
  end
  if extensions.ui_router and extensions.ui_router.reload then
    extensions.ui_router.reload("multiseat", nil, {force = true})
  end

  -- Enable split-screen minimaps for each player
  extensions.load("ui_apps_minimap_minimap")
  if ui_apps_minimap_minimap and ui_apps_minimap_minimap.enableSplitScreenMinimaps then
    ui_apps_minimap_minimap.enableSplitScreenMinimaps()
  end

  local joinMsg = assignedSeatId
    and "Player 2 joined as passenger in Player 1's vehicle. Press F to get out and walk."
    or "Player 2 spawned walking next to vehicle (seats full). Press F near a vehicle to enter."

  guihooks.trigger("toastrMsg", {
    type = "success",
    title = "Career Split-Screen Active!",
    msg = joinMsg
  })
end

local function stopSplitScreen()
  if not isSplitActive then return end
  isSplitActive = false

  local oldP2VehId = p2VehicleId

  -- 1. Eject Player 1 and clear occupancy / 3D dummy character completely so "seat occupied" never occurs
  if be and be.exitVehicle then
    be:exitVehicle(1)
  end
  if gameplay_seatOccupants then
    if gameplay_seatOccupants.clearOccupied then
      gameplay_seatOccupants.clearOccupied(nil, 1) -- clears Player 1 from all vehicles
      if oldP2VehId then
        gameplay_seatOccupants.clearOccupied(oldP2VehId)
      end
    end
    if gameplay_seatOccupants.clearDummyOccupants and oldP2VehId then
      gameplay_seatOccupants.clearDummyOccupants(oldP2VehId)
    end
  end
  if gameplay_walk then
    if gameplay_walk.setWalkingMode then
      gameplay_walk.setWalkingMode(false, nil, nil, true, 1)
    end
    local p2Unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle(1)
    if p2Unicycle then p2Unicycle:delete() end
  end

  -- If Player 2 had a temporary guest vehicle, clean it up
  if guestVehicleId then
    local gVeh = getObjectByID(guestVehicleId)
    if gVeh then
      gVeh:delete()
    end
    guestVehicleId = nil
  end

  p2VehicleId = nil
  p2InventoryId = nil
  p2PassengerSeatId = nil
  p2IsWalking = false

  -- Unload split-screen views
  extensions.unload("render_splitScreen")

  -- Reset traffic sources
  if gameplay_traffic_source then
    gameplay_traffic_source.resetSources()
  end
  extensions.unload("gameplay_traffic_source")

  -- Deactivate multiseat
  if core_multiseat then
    core_multiseat.clearJoinedPlayers()
    core_multiseat.setMultiseatActive(false)
  end
  settings.setValue('multiseat', false)

  -- Restore UI gameplay route back to single-player "play"
  if extensions.ui_menuManager and extensions.ui_menuManager.setGameplayRoute then
    extensions.ui_menuManager.setGameplayRoute(nil)
  end
  if extensions.ui_router and extensions.ui_router.reload then
    extensions.ui_router.reload("play", nil, {force = true})
  end

  -- Ensure Player 0 is in their vehicle and camera is restored
  local p1Veh = getPlayerVehicle(0)
  if p1Veh then
    be:enterVehicle(0, p1Veh)
    commands.setGameCamera()
    if core_camera then
      core_camera.resetCamera(0)
    end
  end

  -- Reset all devices to Player 0
  if core_input_bindings and core_input_bindings.devices then
    for devname, _ in pairs(core_input_bindings.devices) do
      if core_multiseat and core_multiseat.setDevicePlayer then
        core_multiseat.setDevicePlayer(devname, 0)
      end
      core_input_bindings.setPlayerToDevice(devname, 0)
    end
  end

  if core_input_bindings and core_input_bindings.refreshAssignedPlayers then
    core_input_bindings.refreshAssignedPlayers(false, false)
  end

  guihooks.trigger("toastrMsg", {
    type = "info",
    title = "Career Split-Screen",
    msg = "Split-Screen deactivated. Returned to single-player."
  })
end

local function toggle()
  if isSplitActive then
    stopSplitScreen()
  else
    startSplitScreen()
  end
end

local function teleportP2ToP1()
  if not isSplitActive then
    guihooks.trigger("toastrMsg", {
      type = "warning",
      title = "Career Split-Screen",
      msg = "Split-Screen is not active."
    })
    return
  end

  local p1Veh = getPlayerVehicle(0)
  if not p1Veh then return end

  if p2PassengerSeatId then
    guihooks.trigger("toastrMsg", {
      type = "info",
      title = "Career Split-Screen",
      msg = "Player 2 is already inside Player 1's vehicle."
    })
    return
  end

  if p2IsWalking then
    local p2Unicycle = gameplay_walk and gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle(1)
    if p2Unicycle then
      local p1Pos = p1Veh:getPosition()
      local p1Dir = p1Veh:getDirectionVector()
      local p1Up = vec3(0, 0, 1)
      local p1Right = p1Dir:cross(p1Up):normalized()
      local walkPos = p1Pos + (p1Right * 1.8)
      local walkRot = quatFromDir(p1Dir, p1Up)
      spawn.safeTeleport(p2Unicycle, walkPos, walkRot)
      guihooks.trigger("toastrMsg", {
        type = "info",
        title = "Career Split-Screen",
        msg = "Player 2 teleported next to Player 1."
      })
    end
    return
  end

  if p2VehicleId then
    local p2Veh = getObjectByID(p2VehicleId)
    if p2Veh then
      positionP2NearP1(p1Veh, p2Veh, true)
      p2Veh:resetBrokenFlexMesh()
      guihooks.trigger("toastrMsg", {
        type = "info",
        title = "Career Split-Screen",
        msg = "Player 2 vehicle teleported and repaired next to Player 1."
      })
    end
  end
end

local function switchP2Vehicle()
  if not isSplitActive then return end
  local inv = getInventoryModule()
  local currentInvId = inv and inv.getCurrentVehicle and inv.getCurrentVehicle()
  local vehicles = inv and inv.getVehicles and inv.getVehicles() or {}

  local candidates = {}
  for invId, _ in pairs(vehicles) do
    if invId ~= currentInvId and invId ~= p2InventoryId then
      table.insert(candidates, invId)
    end
  end

  local oldP2VehId = p2VehicleId
  -- Clean up old occupancy before assigning new vehicle
  if be and be.exitVehicle then
    be:exitVehicle(1)
  end
  if gameplay_seatOccupants then
    if gameplay_seatOccupants.clearOccupied then
      gameplay_seatOccupants.clearOccupied(nil, 1)
      if p2PassengerSeatId and oldP2VehId then
        gameplay_seatOccupants.clearOccupied(oldP2VehId, p2PassengerSeatId)
      elseif oldP2VehId and oldP2VehId ~= (getPlayerVehicle(0) and getPlayerVehicle(0):getId()) then
        gameplay_seatOccupants.clearOccupied(oldP2VehId)
      end
    end
    if gameplay_seatOccupants.clearDummyOccupants and oldP2VehId then
      gameplay_seatOccupants.clearDummyOccupants(oldP2VehId)
    end
  end
  if gameplay_walk then
    if gameplay_walk.setWalkingMode then
      gameplay_walk.setWalkingMode(false, nil, nil, true, 1)
    end
    local p2Unicycle = gameplay_walk.getCurrentUnicycle and gameplay_walk.getCurrentUnicycle(1)
    if p2Unicycle then p2Unicycle:delete() end
  end
  p2PassengerSeatId = nil
  p2IsWalking = false

  if guestVehicleId then
    local gVeh = getObjectByID(guestVehicleId)
    if gVeh then gVeh:delete() end
    guestVehicleId = nil
  end

  local nextInvId = candidates[1]
  findOrSpawnP2Vehicle(function(newVeh, invId, isGuest)
    if newVeh then
      local p1Veh = getPlayerVehicle(0)
      p2VehicleId = newVeh:getId()
      p2InventoryId = invId
      if isGuest then guestVehicleId = newVeh:getId() end

      positionP2NearP1(p1Veh, newVeh, false)
      be:enterVehicle(1, newVeh)
      if core_camera then core_camera.resetCamera(1) end
      local name = (invId and inv and inv.getVehicleNiceNameTranslated and inv.getVehicleNiceNameTranslated(invId)) or (isGuest and "Guest Vehicle" or "Vehicle")
      guihooks.trigger("toastrMsg", {
        type = "info",
        title = "Career Split-Screen",
        msg = "Assigned Player 2 to vehicle: " .. name
      })
    end
  end, nextInvId)
end

local function toggleLayout()
  local cur = settings.getValue("multiseatLayout2", "horizontal")
  local nxt = (cur == "vertical") and "horizontal" or "vertical"
  settings.setValue("multiseatLayout2", nxt)
  if render_splitScreen and render_splitScreen.refreshLayout then
    render_splitScreen.refreshLayout()
  end
  ui_message("Split-Screen layout set to: " .. nxt, 3, "splitscreen", "settings")
  return true
end

local function openSettings()
  if ui_multiseat_freeroam then
    ui_multiseat_freeroam.deactivate()
  end
  local multiseatConfiguration = require("ge/extensions/ui/multiseat/multiseatConfiguration")
  if multiseatConfiguration and multiseatConfiguration.begin then
    multiseatConfiguration.begin({source = "settings"})
  end
  return extensions.ui_router.navigate("pause.multiseatSettings") ~= false
end

-- Pause menu hook: Populates Split-Screen actions when ESC menu is opened
local function onPauseHomeRailBuildMultiseatActions(actions, context, registerButton)
  if not isSplitActive then return end

  local curLayout = settings.getValue("multiseatLayout2", "horizontal")
  local isVertical = (curLayout == "vertical")
  local layoutLabel = isVertical and "Layout: Vertical (Switch to Horizontal)" or "Layout: Horizontal (Switch to Vertical)"

  table.insert(actions, registerButton({
    id = "home.careerSplitScreenToggleLayout",
    label = layoutLabel,
    icon = "splitScreen",
    visible = true,
    enabled = true,
  }, function()
    toggleLayout()
    return true
  end))

  table.insert(actions, registerButton({
    id = "home.careerSplitScreenTeleport",
    label = "Teleport P2 to P1",
    icon = "fastTravel",
    visible = true,
    enabled = true,
  }, function()
    teleportP2ToP1()
    return extensions.ui_router.navigate("multiseat") ~= false
  end))

  table.insert(actions, registerButton({
    id = "home.careerSplitScreenSwitchVeh",
    label = "Get / Switch P2 Car",
    icon = "carToWheels",
    visible = true,
    enabled = true,
  }, function()
    switchP2Vehicle()
    return extensions.ui_router.navigate("multiseat") ~= false
  end))

  table.insert(actions, registerButton({
    id = "home.careerSplitScreenSettings",
    label = "Split-Screen Settings",
    icon = "wrench",
    visible = true,
    enabled = true,
  }, function()
    openSettings()
    return true
  end))

  table.insert(actions, registerButton({
    id = "home.careerSplitScreenExit",
    label = "Exit Split-Screen",
    icon = "abandon",
    flavor = "danger",
    visible = true,
    enabled = true,
  }, function()
    stopSplitScreen()
    return extensions.ui_router.navigate("play") ~= false
  end))
end

-- Radial menu integration: Places items cleanly at the exact bottom (Slot 7, 6 o'clock)
local function onBeforeRadialOpened()
  if not isCareerModeActive() then return end
  if quickAccessInitialized then return end
  quickAccessInitialized = true

  if core_quickAccess and core_quickAccess.addEntry then
    core_quickAccess.addEntry({
      level = "/root/",
      uniqueID = "careerSplitRootGenerator",
      generator = function(entries)
        if not isCareerModeActive() then return end

        -- Remove the empty root_down dynamic slot and any stale split entries so Slot 7 (6 o'clock) is free
        for i = #entries, 1, -1 do
          local e = entries[i]
          if type(e) == "table" then
            if (e.dynamicSlot and e.dynamicSlot.id == "root_down") or (e.startSlot == 7 and e.dynamicSlot) then
              table.remove(entries, i)
            elseif e.uniqueID and string.find(e.uniqueID, "^careerSplit") then
              table.remove(entries, i)
            end
          end
        end

        if not isSplitActive then
          table.insert(entries, {
            title = "Start Split-Screen",
            icon = "splitScreen",
            startSlot = 7,
            endSlot = 7,
            position = 0.75,
            size = 0.125,
            priority = 1,
            uniqueID = "careerSplitStart",
            ignoreAsRecentAction = true,
            onSelect = function()
              if core_quickAccess and core_quickAccess.setEnabled then
                core_quickAccess.setEnabled(false)
              end
              core_jobsystem.create(function()
                startSplitScreen()
              end, 0.05)
              return {"hide"}
            end
          })
        else
          table.insert(entries, {
            title = "Split-Screen",
            icon = "splitScreen",
            startSlot = 7,
            endSlot = 7,
            position = 0.75,
            size = 0.125,
            priority = 1,
            uniqueID = "careerSplitMenu",
            ignoreAsRecentAction = true,
            ["goto"] = "/root/career/splitScreen/"
          })
        end
      end
    })

    -- Sub-menu when split-screen is active: clean 4-button wheel
    core_quickAccess.addEntry({
      level = "/root/career/splitScreen/",
      uniqueID = "careerSplitSubGenerator",
      generator = function(entries)
        for i = #entries, 1, -1 do
          local e = entries[i]
          if type(e) == "table" and e.uniqueID and string.find(e.uniqueID, "^careerSplit") then
            table.remove(entries, i)
          end
        end

        table.insert(entries, {
          title = "Split-Screen Settings",
          icon = "wrench",
          startSlot = 3,
          endSlot = 3,
          position = 0.25,
          size = 0.125,
          priority = 1,
          uniqueID = "careerSplitSubSettings",
          ignoreAsRecentAction = true,
          onSelect = function()
            if core_quickAccess and core_quickAccess.setEnabled then
              core_quickAccess.setEnabled(false)
            end
            core_jobsystem.create(function()
              openSettings()
            end, 0.05)
            return {"hide"}
          end
        })
        table.insert(entries, {
          title = "Teleport P2 to P1",
          icon = "fastTravel",
          startSlot = 1,
          endSlot = 1,
          position = 0.0,
          size = 0.125,
          priority = 2,
          uniqueID = "careerSplitSubTeleport",
          ignoreAsRecentAction = true,
          onSelect = function()
            if core_quickAccess and core_quickAccess.setEnabled then
              core_quickAccess.setEnabled(false)
            end
            core_jobsystem.create(function()
              teleportP2ToP1()
            end, 0.05)
            return {"hide"}
          end
        })
        table.insert(entries, {
          title = "Get / Switch P2 Car",
          icon = "carsChange",
          startSlot = 5,
          endSlot = 5,
          position = 0.5,
          size = 0.125,
          priority = 3,
          uniqueID = "careerSplitSubSwitch",
          ignoreAsRecentAction = true,
          onSelect = function()
            if core_quickAccess and core_quickAccess.setEnabled then
              core_quickAccess.setEnabled(false)
            end
            core_jobsystem.create(function()
              switchP2Vehicle()
            end, 0.05)
            return {"hide"}
          end
        })
        table.insert(entries, {
          title = "Exit Split-Screen",
          icon = "abandon",
          startSlot = 7,
          endSlot = 7,
          position = 0.75,
          size = 0.125,
          priority = 4,
          uniqueID = "careerSplitSubExit",
          ignoreAsRecentAction = true,
          onSelect = function()
            if core_quickAccess and core_quickAccess.setEnabled then
              core_quickAccess.setEnabled(false)
            end
            core_jobsystem.create(function()
              stopSplitScreen()
            end, 0.05)
            return {"hide"}
          end
        })
      end
    })
  end
end

-- Seamlessly switch to full-screen solo camera during structured missions
local function onAnyMissionChanged(state, mission)
  if not isSplitActive then return end
  if state == "started" then
    log("I", "careerSplitScreen", "Mission started - switching to solo view for Player 0")
    if render_splitScreen and render_splitScreen.beginSoloView then
      render_splitScreen.beginSoloView(0)
    end
  elseif state == "stopped" then
    log("I", "careerSplitScreen", "Mission ended - restoring split-screen view")
    if render_splitScreen and render_splitScreen.endSoloView then
      render_splitScreen.endSoloView()
    end
  end
end

local function onClientEndMission()
  if isSplitActive then
    stopSplitScreen()
  end
  quickAccessInitialized = false
end

local function onCareerActive(active)
  if not active and isSplitActive then
    stopSplitScreen()
  end
  quickAccessInitialized = false
end

local function onOverhaulModeStarted(saveName)
  quickAccessInitialized = false
end

local function onOverhaulModeStopped()
  if isSplitActive then
    stopSplitScreen()
  end
  quickAccessInitialized = false
end

local function onGameStateUpdate(gameState)
  if gameState and (gameState.state == "career" or gameState.state == "overhaul") then
    quickAccessInitialized = false
  elseif gameState and gameState.state == "freeroam" and isSplitActive then
    stopSplitScreen()
  end
end

-- ==============================================================================
-- On-Screen Player Interaction Prompt (Right-Middle Screen)
-- Displays keycap badge [E] / (A) and activity label (Refuel, Enter Garage, etc.)
-- for Player 0 and Player 1 in their respective screen viewports.
-- ==============================================================================
local playerPrompts = {}
local clustersById = {}
local clustersByIdGen = -1
local pBB1, pBB2, pBB3, pBB4, pBB5, pBB6, pBB7, pBB8 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()

local function getBBPoints(bbCenter, bbAxis0, bbAxis1, bbAxis2)
  pBB1:set(bbCenter) pBB1:setAdd(bbAxis0) pBB1:setAdd(bbAxis1) pBB1:setSub(bbAxis2)
  pBB2:set(bbCenter) pBB2:setAdd(bbAxis0) pBB2:setAdd(bbAxis1) pBB2:setAdd(bbAxis2)
  pBB3:set(bbCenter) pBB3:setSub(bbAxis0) pBB3:setAdd(bbAxis1) pBB3:setAdd(bbAxis2)
  pBB4:set(bbCenter) pBB4:setSub(bbAxis0) pBB4:setAdd(bbAxis1) pBB4:setSub(bbAxis2)
  pBB5:set(bbCenter) pBB5:setAdd(bbAxis0) pBB5:setSub(bbAxis1) pBB5:setSub(bbAxis2)
  pBB6:set(bbCenter) pBB6:setAdd(bbAxis0) pBB6:setSub(bbAxis1) pBB6:setAdd(bbAxis2)
  pBB7:set(bbCenter) pBB7:setSub(bbAxis0) pBB7:setSub(bbAxis1) pBB7:setAdd(bbAxis2)
  pBB8:set(bbCenter) pBB8:setSub(bbAxis0) pBB8:setSub(bbAxis1) pBB8:setSub(bbAxis2)
  return {pBB1, pBB2, pBB3, pBB4, pBB5, pBB6, pBB7, pBB8}
end

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

local function isPlayerActuallyInsideMarker(marker, pData)
  if not marker or not pData then return false end

  -- 1. Gas station pumps
  if marker.pumps then
    if pData.isWalking then return false end
    for _, pump in ipairs(marker.pumps) do
      if pump.areaPos and pump.xVec and pump.yVec and pump.zVec and pData.bbCenter and pData.bbHalfAxis0 then
        if overlapsOBB_OBB and overlapsOBB_OBB(pData.bbCenter, pData.bbHalfAxis0, pData.bbHalfAxis1, pData.bbHalfAxis2, pump.areaPos, pump.xVec, pump.yVec, pump.zVec) then
          return true
        end
      end
      if pump.iconPos and pData.vehPos and pData.vehPos:distance(pump.iconPos) <= 5.0 then
        return true
      end
      if pump.areaPos and pData.vehPos and pData.vehPos:distance(pump.areaPos) <= 5.0 then
        return true
      end
    end
    return false
  end

  -- 2. walkingMarker (doors / dealership / garage computer)
  if marker.doors then
    if not pData.isWalking then return false end
    for _, area in ipairs(marker.doors) do
      if area.areaPos and area.xVec and area.yVec and area.zVec and pData.bbCenter and pData.bbHalfAxis0 then
        if overlapsOBB_OBB and overlapsOBB_OBB(pData.bbCenter, pData.bbHalfAxis0, pData.bbHalfAxis1, pData.bbHalfAxis2, area.areaPos, area.xVec, area.yVec, area.zVec) then
          return true
        end
      end
      if area.iconPos and pData.vehPos and pData.vehPos:distance(area.iconPos) <= 3.0 then
        return true
      end
      if area.areaPos and pData.vehPos and pData.vehPos:distance(area.areaPos) <= 3.0 then
        return true
      end
    end
    return false
  end

  -- 3. parkingMarker (parking spots, garage deliveries, dealerships, mod shops)
  if marker.checkParking then
    if pData.isWalking then return false end
    if type(marker.checkParking) == "function" then
      pcall(function() marker:checkParking(pData) end)
      if marker.parked or marker.overlap then return true end
    end
    if marker.pos and pData.vehPos then
      local dist = pData.vehPos:distance(marker.pos)
      if dist <= 4.0 then return true end
      if dist <= (marker.radius or 12) and marker.xVec and marker.yVec and marker.zVec and pData.bbCenter and pData.bbHalfAxis0 then
        if marker.mode == "contained" and containsOBB_OBB then
          if containsOBB_OBB(marker.pos, marker.xVec, marker.yVec, marker.zVec, pData.bbCenter, pData.bbHalfAxis0, pData.bbHalfAxis1, pData.bbHalfAxis2) then
            return true
          end
        end
        if overlapsOBB_OBB and overlapsOBB_OBB(marker.pos, marker.xVec, marker.yVec, marker.zVec, pData.bbCenter, pData.bbHalfAxis0, pData.bbHalfAxis1, pData.bbHalfAxis2) then
          return true
        end
      end
    end
    return false
  end

  -- 4. missionMarker
  if marker.playerIsInArea then
    local ok, inArea = pcall(function() return marker:playerIsInArea(pData) end)
    if ok and inArea then return true end
  end

  -- 5. zoneMarker
  if marker.zones then
    if pData.isWalking then return false end
    for _, z in ipairs(marker.zones) do
      if z and z.containsPoint2D then
        if pData.bbPoints and pData.bbPoints[1] and z:containsPoint2D(pData.bbPoints[1]) then return true end
        if pData.vehPos and z:containsPoint2D(pData.vehPos) then return true end
      end
    end
    return false
  end

  -- 6. Generic trigger with pos/radius
  if marker.pos and pData.vehPos then
    local r = marker.radius or 5.0
    if pData.vehPos:distance(marker.pos) <= r then return true end
  end

  if marker.cluster and marker.cluster.pos and pData.vehPos then
    local r = marker.cluster.radius or 5.0
    if pData.vehPos:distance(marker.cluster.pos) <= r then return true end
  end

  return false
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
  pData.canInteract = isWalking or (speed <= 2.2)
  pData.playerPosition = pData.vehPos
  pData.dt = dtSim or 0
  pData.cruisingSpeedFactor = 0
  pData.parkingSpeedFactor = 1
  pData.camPos = pData.vehPos
  return pData
end

local function sortActivityData(a, b)
  local hasSortingA = a.sorting ~= nil
  local hasSortingB = b.sorting ~= nil
  if hasSortingA and not hasSortingB then return true
  elseif not hasSortingA and hasSortingB then return false
  elseif hasSortingA and hasSortingB then
    if a.sorting.type == "mission" and b.sorting.type ~= "mission" then return true
    elseif a.sorting.type ~= "mission" and b.sorting.type == "mission" then return false
    elseif a.sorting.type ~= b.sorting.type then return a.sorting.type < b.sorting.type
    else
      if (a.sorting.order or 0) == (b.sorting.order or 0) then
        return (a.sorting.id or a.heading) < (b.sorting.id or b.heading)
      end
      return (a.sorting.order or 0) < (b.sorting.order or 0)
    end
  else
    return (a.heading or "") < (b.heading or "")
  end
end

local function getAssignedDeviceForPlayer(playerIndex)
  if core_multiseat and core_multiseat.getDevicesByPlayer then
    local ok, pDevices = pcall(core_multiseat.getDevicesByPlayer)
    if ok and pDevices and pDevices[playerIndex] and #pDevices[playerIndex] > 0 then
      for _, dev in ipairs(pDevices[playerIndex]) do
        if dev.id and dev.connected ~= false then
          return dev.id
        end
      end
    end
  end

  if core_input_bindings and core_input_bindings.getAssignedPlayers then
    local ok, assigned = pcall(core_input_bindings.getAssignedPlayers)
    if ok and assigned and type(assigned) == "table" then
      for devname, p in pairs(assigned) do
        if p == playerIndex then
          return devname
        end
      end
    end
  end

  return nil
end

local function formatBindingControl(rawControl, devType)
  if not rawControl or rawControl == "" then return nil end

  local parts = {}
  for part in string.gmatch(rawControl, "%S+") do
    table.insert(parts, part)
  end

  local displayParts = {}
  for _, p in ipairs(parts) do
    local lp = string.lower(p)
    if string.find(lp, "^modifier%d*$") then
      -- Skip internal modifier tokens like modifier1, modifier2
    elseif lp == "shift" or lp == "lshift" or lp == "rshift" then
      table.insert(displayParts, "Shift")
    elseif lp == "ctrl" or lp == "lcontrol" or lp == "rcontrol" or lp == "control" then
      table.insert(displayParts, "Ctrl")
    elseif lp == "alt" or lp == "lalt" or lp == "ralt" then
      table.insert(displayParts, "Alt")
    elseif lp == "space" then
      table.insert(displayParts, "Space")
    elseif lp == "return" or lp == "enter" then
      table.insert(displayParts, "Enter")
    elseif lp == "escape" or lp == "esc" then
      table.insert(displayParts, "Esc")
    elseif lp == "tab" then
      table.insert(displayParts, "Tab")
    elseif lp == "backspace" then
      table.insert(displayParts, "Backspace")
    -- Gamepad / Xbox
    elseif lp == "btn_a" then
      table.insert(displayParts, "A")
    elseif lp == "btn_b" then
      table.insert(displayParts, "B")
    elseif lp == "btn_x" then
      table.insert(displayParts, "X")
    elseif lp == "btn_y" then
      table.insert(displayParts, "Y")
    elseif lp == "btn_l" then
      table.insert(displayParts, "LB")
    elseif lp == "btn_r" then
      table.insert(displayParts, "RB")
    elseif lp == "triggerl" then
      table.insert(displayParts, "LT")
    elseif lp == "triggerr" then
      table.insert(displayParts, "RT")
    elseif lp == "btn_back" then
      table.insert(displayParts, "View")
    elseif lp == "btn_start" then
      table.insert(displayParts, "Menu")
    elseif lp == "btn_lt" or lp == "thumbl" then
      table.insert(displayParts, "LS")
    elseif lp == "btn_rt" or lp == "thumbr" then
      table.insert(displayParts, "RS")
    elseif lp == "dpov" then
      table.insert(displayParts, "D-Down")
    elseif lp == "upov" then
      table.insert(displayParts, "D-Up")
    elseif lp == "lpov" then
      table.insert(displayParts, "D-Left")
    elseif lp == "rpov" then
      table.insert(displayParts, "D-Right")
    -- PlayStation / DirectInput
    elseif lp == "button0" then
      table.insert(displayParts, (devType and string.find(devType, "sce") and "Square") or "X")
    elseif lp == "button1" then
      table.insert(displayParts, (devType and string.find(devType, "sce") and "Cross") or "A")
    elseif lp == "button2" then
      table.insert(displayParts, (devType and string.find(devType, "sce") and "Circle") or "B")
    elseif lp == "button3" then
      table.insert(displayParts, (devType and string.find(devType, "sce") and "Triangle") or "Y")
    elseif lp == "button4" then
      table.insert(displayParts, "L1")
    elseif lp == "button5" then
      table.insert(displayParts, "R1")
    elseif lp == "button6" then
      table.insert(displayParts, "L2")
    elseif lp == "button7" then
      table.insert(displayParts, "R2")
    elseif lp == "button8" then
      table.insert(displayParts, "Share")
    elseif lp == "button9" then
      table.insert(displayParts, "Options")
    elseif #lp == 1 then
      table.insert(displayParts, string.upper(lp))
    else
      table.insert(displayParts, lp:sub(1,1):upper() .. lp:sub(2))
    end
  end

  if #displayParts == 0 then
    local lastPart = parts[#parts] or rawControl
    return string.upper(lastPart)
  end

  return table.concat(displayParts, " + ")
end

local function getInteractKeyPromptForPlayer(playerIndex)
  local actionName = "gameplay_interact"

  if core_input_bindings and core_input_bindings.bindings then
    local assignedDev = getAssignedDeviceForPlayer(playerIndex)

    -- 1. Check explicitly assigned device
    if assignedDev then
      for _, devData in ipairs(core_input_bindings.bindings) do
        if devData.devname == assignedDev then
          local contents = devData.contents or {}
          for _, b in ipairs(contents.bindings or {}) do
            if b.action == actionName and not b.unused and b.control then
              local formatted = formatBindingControl(b.control, contents.devicetype)
              if formatted and formatted ~= "" then
                return formatted
              end
            end
          end
        end
      end
    end

    -- 2. Check player preferred device in bindings
    for _, devData in ipairs(core_input_bindings.bindings) do
      local contents = devData.contents or {}
      local devType = contents.devicetype
      local isController = (devType ~= "keyboard" and devType ~= "mouse")

      local match = false
      if playerIndex == 0 then
        match = true
      else
        match = isController
      end

      if match then
        for _, b in ipairs(contents.bindings or {}) do
          if b.action == actionName and not b.unused and b.control then
            local formatted = formatBindingControl(b.control, devType)
            if formatted and formatted ~= "" then
              return formatted
            end
          end
        end
      end
    end

    -- 3. Fallback: check all bindings
    for _, devData in ipairs(core_input_bindings.bindings) do
      local contents = devData.contents or {}
      for _, b in ipairs(contents.bindings or {}) do
        if b.action == actionName and not b.unused and b.control then
          local formatted = formatBindingControl(b.control, contents.devicetype)
          if formatted and formatted ~= "" then
            return formatted
          end
        end
      end
    end
  end

  if playerIndex == 0 then
    return "E"
  else
    return "A"
  end
end

local function onActivityAcceptUpdate(content)
  if content and #content > 0 then
    playerPrompts[0] = content[1]
    playerPrompts[0].fromMissionInfo = true
  end
end

local function onMissionInfoChangedState(fromState, toState, content)
  if toState == "closed" then
    if playerPrompts[0] and playerPrompts[0].fromMissionInfo then
      playerPrompts[0] = nil
    end
  elseif toState == "opened" and content and #content > 0 then
    playerPrompts[0] = content[1]
    playerPrompts[0].fromMissionInfo = true
  end
end

local function evaluatePlayerInteractions(dtSim)
  if not isSplitModeActive() then
    if next(playerPrompts) then
      table.clear(playerPrompts)
    end
    return
  end

  if not gameplay_playmodeMarkers or not gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree then return end
  local clusterQt = gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree()
  if not clusterQt then return end

  local checkPlayers = {0}
  local p1Veh = getPlayerVehicle(1)
  if p1Veh and p1Veh ~= getPlayerVehicle(0) then
    table.insert(checkPlayers, 1)
  else
    playerPrompts[1] = nil
  end

  for _, pIdx in ipairs(checkPlayers) do
    local pData = getPlayerDataForInteraction(pIdx, dtSim)
    if pData and pData.canInteract then
      local pInteractableElements = {}
      local searchRadius = 35
      for id in clusterQt:queryNotNested(pData.vehPos.x - searchRadius, pData.vehPos.y - searchRadius, pData.vehPos.x + searchRadius, pData.vehPos.y + searchRadius) do
        local cluster = getClusterById(id)
        if cluster then
          local marker = gameplay_playmodeMarkers.getMarkerForCluster and gameplay_playmodeMarkers.getMarkerForCluster(cluster)
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
          if not (pIdx == 0 and playerPrompts[0] and playerPrompts[0].fromMissionInfo) then
            playerPrompts[pIdx] = nil
          end
        end
      else
        if not (pIdx == 0 and playerPrompts[0] and playerPrompts[0].fromMissionInfo) then
          playerPrompts[pIdx] = nil
        end
      end
    else
      if not (pIdx == 0 and playerPrompts[0] and playerPrompts[0].fromMissionInfo) then
        playerPrompts[pIdx] = nil
      end
    end
  end
end

local function drawInteractPromptForPlayer(player, prompt, rect, canvasPosX, canvasPosY, canvasSizeX, canvasSizeY)
  local im = ui_imgui
  if not im then return end

  local cellW = rect[3] * canvasSizeX
  local cellH = rect[4] * canvasSizeY
  local cellX = canvasPosX + rect[1] * canvasSizeX
  local cellY = canvasPosY + rect[2] * canvasSizeY

  local labelText = prompt.heading or "Interact"
  if prompt.buttonLabel and _tr then
    local trBtn = _tr(prompt.buttonLabel, prompt.buttonLabel)
    if trBtn and trBtn ~= "" and trBtn ~= prompt.buttonLabel then
      if prompt.heading and prompt.heading ~= "" and prompt.heading ~= trBtn then
        labelText = trBtn .. " - " .. _tr(prompt.heading, prompt.heading)
      else
        labelText = trBtn
      end
    else
      labelText = _tr(labelText, labelText)
    end
  elseif _tr then
    labelText = _tr(labelText, labelText)
  end

  local keyText = getInteractKeyPromptForPlayer(player) or "E"

  local keySize = im.CalcTextSize(keyText)
  local headingSize = im.CalcTextSize(labelText)

  local boxH = 36
  local boxW = math.max(160, math.min(keySize.x + headingSize.x + 60, cellW - 40))

  -- Right-middle of player's screen viewport
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
  im.PushStyleColor1(im.Col_WindowBg, im.GetColorU322(im.ImVec4(0.10, 0.11, 0.14, 0.92)))
  im.PushStyleColor1(im.Col_Border, im.GetColorU322(im.ImVec4(0.35, 0.38, 0.44, 0.75)))

  local winTitle = "###SDF_InteractPrompt_" .. tostring(player)
  if im.Begin(winTitle, nil, flags) then
    -- Keycap badge container
    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(8, 3))
    im.PushStyleVar1(im.StyleVar_FrameRounding, 4)
    im.PushStyleVar1(im.StyleVar_FrameBorderSize, 1)
    im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.95, 0.45, 0.10, 0.95))) -- BeamNG Orange
    im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.95, 0.45, 0.10, 0.95)))
    im.PushStyleColor1(im.Col_ButtonActive, im.GetColorU322(im.ImVec4(0.95, 0.45, 0.10, 0.95)))
    im.PushStyleColor1(im.Col_Border, im.GetColorU322(im.ImVec4(1.0, 0.65, 0.30, 0.85)))
    im.PushStyleColor1(im.Col_Text, im.GetColorU322(im.ImVec4(1.0, 1.0, 1.0, 1.0)))

    im.Button(keyText)

    im.PopStyleColor(5)
    im.PopStyleVar(3)

    im.SameLine()
    im.SetCursorPosY(im.GetCursorPosY() + 3)
    im.TextColored(im.ImVec4(0.95, 0.96, 0.98, 1.0), labelText)
  end
  im.End()

  im.PopStyleColor(2)
  im.PopStyleVar(3)
end

local function drawPlayerInteractPrompts()
  local im = ui_imgui
  if not im then return end
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

  if not isSplitModeActive() then return end
  if not render_splitScreen or not render_splitScreen.getUiState then return end
  local uiState = render_splitScreen.getUiState()
  if not uiState or not uiState.layout or not uiState.players or #uiState.players <= 1 then return end

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

  if ui_missionInfo and ui_missionInfo.buttonsTable and #ui_missionInfo.buttonsTable > 0 then
    ui_missionInfo.performActivityAction(1)
    return true
  end

  return false
end

local function onGameplayInteract()
  if not isCareerModeActive() and not isSplitModeActive() then return end
  if performInteract() then
    log("I", "careerSplitScreen", "onGameplayInteract: performed prompt action")
    return true
  end
  return false
end

local function onPreRender(dt)
  evaluatePlayerInteractions(dt)
  drawPlayerInteractPrompts()

  if freeroam_bigMapMode and not freeroam_bigMapMode._careerSplitHooked then
    hookBigMapMode()
  end
  if (gameplay_markerInteraction and not gameplay_markerInteraction._careerSplitMarkerHooked)
     or (overhaul_integration_services_markerInteraction and not overhaul_integration_services_markerInteraction._careerSplitMarkerHooked) then
    hookMarkerInteraction()
  end

  if freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive() then
    if isSplitModeActive() then
      -- Guarantee the crosshair icon stays white and visible in split screen
      local iconRenderer = gameplay_playmodeMarkers and gameplay_playmodeMarkers.getBigmapRendererObj and gameplay_playmodeMarkers.getBigmapRendererObj()
      if iconRenderer then
        local crosshair = iconRenderer:getIconByName("controllerCrosshair")
        if crosshair then
          crosshair.color = ColorI(255, 255, 255, 255)
        end
      end

      -- Check keyboard Enter / Space press
      local im = ui_imgui
      if im and im.IsKeyPressed and im.GetKeyIndex then
        local enterPressed = im.IsKeyPressed(im.GetKeyIndex(im.Key_Enter))
          or (im.Key_KeypadEnter and im.IsKeyPressed(im.GetKeyIndex(im.Key_KeypadEnter)))
          or (im.Key_Space and im.IsKeyPressed(im.GetKeyIndex(im.Key_Space)))
        if enterPressed then
          selectAtCursor()
        end
      end
    end
  end
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
  hookBigMapMode()
  hookMarkerInteraction()
  log("I", "careerSplitScreen", "Career Split-Screen extension initialized.")
end

M.startSplitScreen = startSplitScreen
M.stopSplitScreen = stopSplitScreen
M.toggle = toggle
M.teleportP2ToP1 = teleportP2ToP1
M.switchP2Vehicle = switchP2Vehicle
M.openSettings = openSettings
M.toggleLayout = toggleLayout
M.isActive = isActive
M.isSplitModeActive = isSplitModeActive
M.getP2Vehicle = getP2Vehicle
M.getP2VehicleId = function() return p2VehicleId end

M.onExtensionLoaded = onExtensionLoaded
M.onPreRender = onPreRender
M.onGameplayInteract = onGameplayInteract
M.onActivityAcceptUpdate = onActivityAcceptUpdate
M.onMissionInfoChangedState = onMissionInfoChangedState
M.performInteract = performInteract
M.drawPlayerInteractPrompts = drawPlayerInteractPrompts
M.onClientEndMission = onClientEndMission
M.onCareerActive = onCareerActive
M.onOverhaulModeStarted = onOverhaulModeStarted
M.onOverhaulModeStopped = onOverhaulModeStopped
M.onGameStateUpdate = onGameStateUpdate
M.isCareerModeActive = isCareerModeActive
M.getInventoryModule = getInventoryModule
M.onBeforeRadialOpened = onBeforeRadialOpened
M.onAnyMissionChanged = onAnyMissionChanged
M.onPauseHomeRailBuildMultiseatActions = onPauseHomeRailBuildMultiseatActions

return M
