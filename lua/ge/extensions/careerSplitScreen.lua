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

-- Forward declarations to ensure file-wide availability
local performInteract = nil
local getRouteTargetPlayer = nil
local setRouteTargetPlayer = nil
local toggleRouteTarget = nil
local ensureGroundMarkersLoaded = nil
local hookCoreGroundMarkers = nil

local cachedKeyPrompts = {}
local function invalidateKeyPromptCache()
  table.clear(cachedKeyPrompts)
end

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

-- Fix vanilla career_modules_reputation crashing on organizations with > 5 levels (e.g. RLS Utah)
local function patchReputationModule()
  if not career_modules_reputation or career_modules_reputation._careerSplitFixed then return end
  career_modules_reputation._careerSplitFixed = true

  local minimumValue = (career_modules_reputation.getMinimumValue and career_modules_reputation.getMinimumValue()) or -50
  local maximumValue = (career_modules_reputation.getMaximumValue and career_modules_reputation.getMaximumValue()) or 700

  local levelDefaults = {
    [-1] = {
      label = "ui.career.organizations.reputation.questionable",
      levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = -1}},
      requiredValue = minimumValue,
      loanerCut = { value = 0.5, icon = "boxPickUp03" },
      deliveryBonus = { value = 0.9 }
    },
    [0] = {
      label = "ui.career.organizations.reputation.neutral",
      levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 0}},
      requiredValue = -25,
      loanerCut = { value = 0.35, icon = "boxPickUp03" },
      deliveryBonus = { value = 1 }
    },
    [1] = {
      label = "ui.career.organizations.reputation.reliable",
      levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 1}},
      requiredValue = 40,
      loanerCut = { value = 0.25, icon = "boxPickUp03" },
      deliveryBonus = { value = 1.1 }
    },
    [2] = {
      label = "ui.career.organizations.reputation.preferred",
      levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 2}},
      requiredValue = 175,
      loanerCut = { value = 0.15, icon = "boxPickUp03" },
      deliveryBonus = { value = 1.2 }
    },
    [3] = {
      label = "ui.career.organizations.reputation.partner",
      levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 3}},
      requiredValue = 400,
      loanerCut = { value = 0, icon = "boxPickUp03" },
      deliveryBonus = { value = 1.4 }
    }
  }

  local function calcLevelFromReputationValue(val, organization)
    local level = -1
    local levels = organization.reputationLevels or {}
    for i, lvl in ipairs(levels) do
      if not lvl.requiredValue or val >= lvl.requiredValue then
        level = i
      end
    end
    local currentLevelRequiredValue = levels[level] and levels[level].requiredValue or minimumValue
    local nextLevelRequiredValue = levels[level+1] and levels[level+1].requiredValue or maximumValue

    local prevThreshold = currentLevelRequiredValue
    local neededForNext = nextLevelRequiredValue - currentLevelRequiredValue
    local curLvlProgress = val - currentLevelRequiredValue
    local nextThreshold = nextLevelRequiredValue
    return level - 2, curLvlProgress, neededForNext, prevThreshold, nextThreshold
  end

  career_modules_reputation.addReputationToOrg = function(organization)
    if not organization then return end

    local val = 0
    if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
      val = career_modules_playerAttributes.getAttributeValue(organization.id .. "Reputation") or 0
    end
    local level, curLvlProgress, neededForNext, prevThreshold, nextThreshold = calcLevelFromReputationValue(val, organization)
    local data = {
      value = val,
      level = level,
      curLvlProgress = curLvlProgress,
      neededForNext = neededForNext,
      prevThreshold = prevThreshold,
      nextThreshold = nextThreshold
    }

    local levels = organization.reputationLevels or {}
    for i, levelInfo in ipairs(levels) do
      local lvlIdx = i - 2
      local defaults = levelDefaults[lvlIdx] or {
        label = "ui.career.organizations.reputation.partner",
        levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = lvlIdx}},
        requiredValue = 400 + math.max(0, i - 5) * 200,
        loanerCut = { value = 0, icon = "boxPickUp03" },
        deliveryBonus = { value = 1.4 }
      }
      for attributeKey, attributeValue in pairs(defaults) do
        if levelInfo[attributeKey] then
          if type(levelInfo[attributeKey]) == "table" and type(attributeValue) == "table" then
            for key, value in pairs(attributeValue) do
              levelInfo[attributeKey][key] = levelInfo[attributeKey][key] or value
            end
          end
        else
          levelInfo[attributeKey] = attributeValue
        end
      end
      if levelInfo.label and core_locales and core_locales.translateWithOrWithoutContext then
        levelInfo.label = core_locales.translateWithOrWithoutContext(levelInfo.label)
      end
      if levelInfo.levelLabel and core_locales and core_locales.translateWithOrWithoutContext then
        levelInfo.levelLabel = core_locales.translateWithOrWithoutContext(levelInfo.levelLabel)
      end
    end
    organization.reputation = data
  end
  log("I", "careerSplitScreen", "Successfully patched career_modules_reputation.addReputationToOrg for multi-level org compatibility.")
end

-- Reputation module is patched on career activation


local function isSplitModeActive()
  return isSplitActive
    or (render_splitScreen and render_splitScreen.isEnabled and render_splitScreen.isEnabled())
end

local function isActive()
  return isSplitModeActive()
end

local function getP2Vehicle()
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

local interactingPlayer = nil
local lastInteractingVehicleId = nil



local function hookCareerJobsAndLogistics()
  -- 1. Hook overhaul_vehicles_playerVehicles for multi-player vehicle footprint
  if overhaul_vehicles_playerVehicles and not overhaul_vehicles_playerVehicles._careerSplitHooked then
    overhaul_vehicles_playerVehicles._careerSplitHooked = true

    local origFillInteraction = overhaul_vehicles_playerVehicles.fillInteractionVehicleIds
    overhaul_vehicles_playerVehicles.fillInteractionVehicleIds = function(into)
      local res = origFillInteraction(into) or into
      if isSplitModeActive() and not p2IsWalking then
        local p2Veh = getP2Vehicle()
        local isUnicycle = p2Veh and p2Veh.getJBeamFilename and p2Veh:getJBeamFilename() == "unicycle"
        local p2Id = (not isUnicycle) and p2Veh and p2Veh:getId()
        local p1Id = be:getPlayerVehicleID(0)
        if p2Id and p2Id ~= p1Id then
          local found = false
          for _, id in ipairs(res) do
            if id == p2Id then found = true; break end
          end
          if not found then
            table.insert(res, p2Id)
            if overhaul_vehicles_playerVehicles.fillCouplerGroup then
              overhaul_vehicles_playerVehicles.fillCouplerGroup(p2Id, res)
            end
          end
        end
      end
      return res
    end

    local origFillPlayer = overhaul_vehicles_playerVehicles.fillPlayerVehicleIds
    overhaul_vehicles_playerVehicles.fillPlayerVehicleIds = function(into)
      local res = origFillPlayer(into) or into
      if isSplitModeActive() and not p2IsWalking then
        local p2Veh = getP2Vehicle()
        local isUnicycle = p2Veh and p2Veh.getJBeamFilename and p2Veh:getJBeamFilename() == "unicycle"
        local p2Id = (not isUnicycle) and p2Veh and p2Veh:getId()
        local p1Id = be:getPlayerVehicleID(0)
        if p2Id and p2Id ~= p1Id then
          local found = false
          for _, id in ipairs(res) do
            if id == p2Id then found = true; break end
          end
          if not found then
            table.insert(res, p2Id)
            if overhaul_vehicles_playerVehicles.fillCouplerGroup then
              overhaul_vehicles_playerVehicles.fillCouplerGroup(p2Id, res)
            end
          end
        end
      end
      return res
    end

    local origGetPlayerVehicleIds = overhaul_vehicles_playerVehicles.getPlayerVehicleIds
    overhaul_vehicles_playerVehicles.getPlayerVehicleIds = function()
      local res = origGetPlayerVehicleIds and origGetPlayerVehicleIds() or {}
      if isSplitModeActive() and not p2IsWalking then
        local p2Veh = getP2Vehicle()
        local isUnicycle = p2Veh and p2Veh.getJBeamFilename and p2Veh:getJBeamFilename() == "unicycle"
        local p2Id = (not isUnicycle) and p2Veh and p2Veh:getId()
        local p1Id = be:getPlayerVehicleID(0)
        if p2Id and p2Id ~= p1Id then
          local found = false
          for _, id in ipairs(res) do
            if id == p2Id then found = true; break end
          end
          if not found then
            local copy = {}
            for _, id in ipairs(res) do table.insert(copy, id) end
            table.insert(copy, p2Id)
            if overhaul_vehicles_playerVehicles.fillCouplerGroup then
              overhaul_vehicles_playerVehicles.fillCouplerGroup(p2Id, copy)
            end
            return copy
          end
        end
      end
      return res
    end

    local origGetCount = overhaul_vehicles_playerVehicles.getPlayerVehicleCount
    overhaul_vehicles_playerVehicles.getPlayerVehicleCount = function()
      local count = origGetCount and origGetCount() or 1
      if isSplitModeActive() and not p2IsWalking then
        local p2Veh = getP2Vehicle()
        local isUnicycle = p2Veh and p2Veh.getJBeamFilename and p2Veh:getJBeamFilename() == "unicycle"
        local p2Id = (not isUnicycle) and p2Veh and p2Veh:getId()
        local p1Id = be:getPlayerVehicleID(0)
        if p2Id and p2Id ~= p1Id then
          count = count + 1
        end
      end
      return count
    end

    local origIsPlayer = overhaul_vehicles_playerVehicles.isPlayerVehicle
    overhaul_vehicles_playerVehicles.isPlayerVehicle = function(vehId)
      if isSplitModeActive() and not p2IsWalking then
        local p2Veh = getP2Vehicle()
        local isUnicycle = p2Veh and p2Veh.getJBeamFilename and p2Veh:getJBeamFilename() == "unicycle"
        local p2Id = (not isUnicycle) and p2Veh and p2Veh:getId()
        if p2Id and vehId == p2Id then return true end
      end
      if origIsPlayer then
        return origIsPlayer(vehId)
      end
      return false
    end
    log("I", "careerSplitScreen", "Hooked overhaul_vehicles_playerVehicles for multi-player footprint.")
  end

  -- Hook core_vehicleTriggers so pressing (A) on controller performs interact prompts
  if core_vehicleTriggers and not core_vehicleTriggers._careerSplitHooked then
    core_vehicleTriggers._careerSplitHooked = true
    local origOnActionEvent = core_vehicleTriggers.onActionEvent
    core_vehicleTriggers.onActionEvent = function(actionNumber, inputValue, player)
      player = player or 0
      if actionNumber == 0 and inputValue == 1 then
        if performInteract(player) then
          log("I", "careerSplitScreen", "core_vehicleTriggers: performed prompt action for player " .. tostring(player))
          return true
        end
      end
      if origOnActionEvent then
        return origOnActionEvent(actionNumber, inputValue, player)
      end
    end
    log("I", "careerSplitScreen", "Hooked core_vehicleTriggers for controller button (A) interaction.")
  end

  -- 2. Hook RLS overhaul delivery containers if present
  local function wrapDeliveryContainers(genMod, name)
    if not genMod or genMod._careerSplitContainersHooked then return end
    genMod._careerSplitContainersHooked = true
    local origGetNearbyContainers = genMod.getNearbyVehicleCargoContainers
    if origGetNearbyContainers then
      genMod.getNearbyVehicleCargoContainers = function(callback)
        if not isSplitModeActive() then
          return origGetNearbyContainers(callback)
        end
        local p0Veh = getPlayerVehicle(0)
        local p0Pos = p0Veh and p0Veh:getPosition() or (core_camera and core_camera.getPosition())
        local p1Veh = getP2Vehicle() or getPlayerVehicle(1)
        local p1Pos = p1Veh and p1Veh:getPosition()

        local candidateVehs = {}
        if p0Veh and p0Veh.getJBeamFilename and p0Veh:getJBeamFilename() ~= "unicycle" then
          candidateVehs[p0Veh:getID()] = p0Veh
        end
        if p1Veh and p1Veh.getJBeamFilename and p1Veh:getJBeamFilename() ~= "unicycle" then
          candidateVehs[p1Veh:getID()] = p1Veh
        end

        local nearbyRadius = 40 * 40
        local vehs = {}
        local refNodeClusterIdByVehId = {}
        local vehCargoData = {}
        if activeVehiclesIterator then
          for vehId, veh in activeVehiclesIterator() do
            if veh:getJBeamFilename() ~= "unicycle" and veh.playerUsable ~= false then
              local vPos = veh:getPosition()
              local isNear = (candidateVehs[vehId] ~= nil)
                or (p0Pos and (p0Pos - vPos):squaredLength() < nearbyRadius)
                or (p1Pos and (p1Pos - vPos):squaredLength() < nearbyRadius)
              if isNear then
                vehCargoData[vehId] = -1
                vehs[vehId] = veh
                refNodeClusterIdByVehId[vehId] = veh:getNodeClusterId(veh:getRefNodeId())
              end
            end
          end
        else
          for vehId, veh in pairs(candidateVehs) do
            vehCargoData[vehId] = -1
            vehs[vehId] = veh
            refNodeClusterIdByVehId[vehId] = veh:getNodeClusterId(veh:getRefNodeId())
          end
        end
        if not next(vehs) then
          if callback then callback({}) end
          return
        end
        local isOverhaulMod = (name and name:find("overhaul")) ~= nil
        local dParcelManager = (isOverhaulMod and overhaul_career_logistics_parcelManager) or career_modules_delivery_parcelManager
        local actionName = isOverhaulMod and "overhaulGetCargoContainers" or "getCargoContainers"
        for vehId, veh in pairs(vehs) do
          core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
            vehCargoData[vehId] = {}
            local deliveryContainers = {}
            for _, container in ipairs((vehCargoContainerData and vehCargoContainerData[1]) or {}) do
              local isPassOnly = false
              if container.cargoTypes then
                isPassOnly = true
                for _, ct in ipairs(container.cargoTypes) do
                  if ct ~= "passenger" then isPassOnly = false; break end
                end
              end
              if not isPassOnly then
                table.insert(deliveryContainers, container)
              end
            end
            for _, container in ipairs(deliveryContainers) do
              local vehName = genMod.getVehicleName and genMod.getVehicleName(vehId) or tostring(vehId)
              local elem = {
                vehId = vehId,
                containerId = container.id,
                location = {type = "vehicle", vehId = tonumber(veh:getID()), containerId = tonumber(container.id)},
                vehName = vehName,
                name = container.name,
                moveToLabel = vehName .. " " .. container.name,
                cargoTypesLookup = tableValuesAsLookupDict(container.cargoTypes),
                cargoTypesString = table.concat(container.cargoTypes, ", "),
                totalCargoSlots = container.capacity,
                usedCargoSlots = 0,
                transientCargoSlots = 0,
                freeCargoSlots = container.capacity,
                refNodeClusterId = refNodeClusterIdByVehId[vehId],
                clusterId = container.nodeId and veh:getNodeClusterId(container.nodeId),
                position = (container.nodeId and veh:getNodePosition(container.nodeId) or vec3(0,0,0)) + veh:getPosition(),
              }
              if not elem.clusterId or elem.refNodeClusterId == elem.clusterId then
                elem.attachmentStatus = "attached"
              else
                local dist = (elem.position - veh:getPosition()):length()
                elem.attachmentStatus = (dist < 10) and "nearby" or "lost"
              end
              if dParcelManager then
                elem.rawCargo = dParcelManager.getAllCargoForLocation(elem.location) or {}
                elem.transientCargo = dParcelManager.getTransientMovesForTargetLocationWithCargo(elem.location) or {}
              else
                elem.rawCargo = {}
                elem.transientCargo = {}
              end
              for _, cargo in ipairs(elem.rawCargo) do
                elem.usedCargoSlots = elem.usedCargoSlots + (cargo.slots or 0)
                elem.freeCargoSlots = elem.freeCargoSlots - (cargo.slots or 0)
              end
              for _, cargo in ipairs(elem.transientCargo) do
                elem.usedCargoSlots = elem.usedCargoSlots + (cargo.slots or 0)
                elem.transientCargoSlots = elem.transientCargoSlots + (cargo.slots or 0)
                elem.freeCargoSlots = elem.freeCargoSlots - (cargo.slots or 0)
              end
              table.insert(vehCargoData[vehId], elem)
            end
            for _, val in pairs(vehCargoData) do
              if val == -1 then return end
            end
            local ret = {}
            for _, list in pairs(vehCargoData) do
              for _, elem in ipairs(list) do
                table.insert(ret, elem)
              end
            end
            table.sort(ret, function(a, b)
              if a.vehId == b.vehId then return a.containerId < b.containerId else return a.vehId < b.vehId end
            end)
            if genMod.getMostRecentCargoContainerData then
              local okUv, _, uvVal = pcall(debug.getupvalue, genMod.getMostRecentCargoContainerData, 1)
              if okUv and uvVal then
                if type(uvVal) == "table" and uvVal.mostRecentCargoContainerData ~= nil then
                  uvVal.mostRecentCargoContainerData = ret
                else
                  pcall(debug.setupvalue, genMod.getMostRecentCargoContainerData, 1, ret)
                end
              end
            end
            if callback then callback(ret) end
          end, actionName)
        end
      end
      log("I", "careerSplitScreen", "Hooked " .. tostring(name) .. " cargo containers for Player 2.")
    end
  end

  -- Hook RLS playerAtFacilityStall so Player 2 can interact at facility parking stalls
  if overhaul_career_logistics_general and not overhaul_career_logistics_general._careerSplitStallHooked then
    overhaul_career_logistics_general._careerSplitStallHooked = true
    local origPlayerAtFacilityStall = overhaul_career_logistics_general.playerAtFacilityStall
    overhaul_career_logistics_general.playerAtFacilityStall = function(psPath, includeCoupled)
      if origPlayerAtFacilityStall and origPlayerAtFacilityStall(psPath, includeCoupled) then
        return true
      end
      if isSplitModeActive() and not p2IsWalking then
        local p2Veh = getP2Vehicle() or getPlayerVehicle(1)
        local isUnicycle = p2Veh and p2Veh.getJBeamFilename and p2Veh:getJBeamFilename() == "unicycle"
        if p2Veh and not isUnicycle and psPath then
          local spot = overhaul_career_logistics_general.getParkingSpotByPath and overhaul_career_logistics_general.getParkingSpotByPath(psPath)
          if spot then
            local vehId = p2Veh:getID()
            if spot.checkParking and spot:checkParking(vehId, 0, 8, 2.5) then
              return true
            end
            local pos = p2Veh:getPosition()
            if spot.containsPoint and spot:containsPoint(pos) then return true end
            if spot.pos then
              local radius = 5
              if spot.scl then
                radius = math.max(math.abs(spot.scl.x or 0), math.abs(spot.scl.y or 0), 3) * 0.5 + 1.25
              end
              if (pos - spot.pos):length() <= radius then return true end
            end
          end
        end
      end
      return false
    end
    log("I", "careerSplitScreen", "Hooked overhaul_career_logistics_general.playerAtFacilityStall for Player 2.")
  end

  -- Hook guihooks.trigger for cargoDataForUiReady vehicle prioritization
  if guihooks and not guihooks._careerSplitCargoHooked then
    guihooks._careerSplitCargoHooked = true
    local origTrigger = guihooks.trigger
    guihooks.trigger = function(hookName, ...)
      if hookName == "cargoDataForUiReady" then
        local uiData = ...
        if type(uiData) == "table" and uiData.player and type(uiData.player.vehicles) == "table" then
          local targetVehId = lastInteractingVehicleId
          if not targetVehId and isSplitModeActive() then
            local psPath = uiData.facility and uiData.facility.parkingSpotPath
            local spot = psPath and ((overhaul_career_logistics_general and overhaul_career_logistics_general.getParkingSpotByPath and overhaul_career_logistics_general.getParkingSpotByPath(psPath))
              or (career_modules_delivery_general and career_modules_delivery_general.getParkingSpotByPath and career_modules_delivery_general.getParkingSpotByPath(psPath)))
            if spot and spot.pos then
              local p0Veh = getPlayerVehicle(0)
              local p1Veh = getP2Vehicle() or getPlayerVehicle(1)
              local d0 = p0Veh and (p0Veh:getPosition() - spot.pos):squaredLength() or math.huge
              local d1 = p1Veh and (p1Veh:getPosition() - spot.pos):squaredLength() or math.huge
              if d1 < d0 and d1 < 30 * 30 then
                targetVehId = p1Veh:getID()
              elseif d0 < 30 * 30 then
                targetVehId = p0Veh and p0Veh:getID()
              end
            end
          end
          if targetVehId then
            local foundIdx = nil
            for idx, vInfo in ipairs(uiData.player.vehicles) do
              if vInfo.vehId == targetVehId then
                foundIdx = idx
                break
              end
            end
            if foundIdx and foundIdx > 1 then
              local vInfo = table.remove(uiData.player.vehicles, foundIdx)
              table.insert(uiData.player.vehicles, 1, vInfo)
              log("I", "careerSplitScreen", "Prioritized vehicle " .. tostring(targetVehId) .. " to index 1 in cargoOverview.")
            end

            -- Target vehicle prioritization and auto route target for co-op players
            -- Automatically set route target player based on the cargo vehicle being viewed
            if isSplitModeActive() then
              local p1Veh = getP2Vehicle() or getPlayerVehicle(1)
              local p1VehId = p1Veh and p1Veh:getID()
              if p1VehId and targetVehId == p1VehId then
                setRouteTargetPlayer(1, true)
                log("I", "careerSplitScreen", "Auto-set route target to Player 2 (cargo screen for P2 vehicle " .. tostring(targetVehId) .. ")")
              else
                local p0Veh = getPlayerVehicle(0)
                local p0VehId = p0Veh and p0Veh:getID()
                if p0VehId and targetVehId == p0VehId then
                  setRouteTargetPlayer(0, true)
                  log("I", "careerSplitScreen", "Auto-set route target to Player 1 (cargo screen for P1 vehicle " .. tostring(targetVehId) .. ")")
                end
              end
            end
          end
        end
      end
      return origTrigger(hookName, ...)
    end
    log("I", "careerSplitScreen", "Hooked guihooks.trigger for cargo overview vehicle selection.")
  end

  if career_modules_delivery_general and not career_modules_delivery_general._careerSplitContainersHooked then
    wrapDeliveryContainers(career_modules_delivery_general, "career_modules_delivery_general")
  end
  if overhaul_career_logistics_general and not overhaul_career_logistics_general._careerSplitContainersHooked then
    wrapDeliveryContainers(overhaul_career_logistics_general, "overhaul_career_logistics_general")
  end

  -- Hook parcelManager sameLocation to prevent string/number type mismatch on vehId
  local function hookParcelManager(parcelMgrMod, name)
    if not parcelMgrMod or parcelMgrMod._careerSplitSameLocationHooked then return end
    parcelMgrMod._careerSplitSameLocationHooked = true
    local origSame = parcelMgrMod.sameLocation
    parcelMgrMod.sameLocation = function(a, b)
      if not a or not b then return false end
      if a.type ~= b.type then return false end
      if a.type == "vehicle" then
        return (tonumber(a.vehId) == tonumber(b.vehId)) and (tonumber(a.containerId) == tonumber(b.containerId))
      elseif a.type == "facilityParkingspot" then
        return a.facId == b.facId and a.psPath == b.psPath
      end
      if origSame then return origSame(a, b) end
      for k, v in pairs(a) do
        if b[k] ~= v then return false end
      end
      return true
    end
    log("I", "careerSplitScreen", "Hooked " .. tostring(name) .. " sameLocation.")
  end

  if career_modules_delivery_parcelManager then
    hookParcelManager(career_modules_delivery_parcelManager, "career_modules_delivery_parcelManager")
  end
  if overhaul_career_logistics_parcelManager then
    hookParcelManager(overhaul_career_logistics_parcelManager, "overhaul_career_logistics_parcelManager")
  end

  -- Hook onActivityAcceptGatherData to guarantee [E] Drop Off prompt when cargo vehicle is at destination stall
  local function hookDeliveryActivity(genMod, parcelMgrMod, name)
    if not genMod or genMod._careerSplitActivityHooked then return end
    genMod._careerSplitActivityHooked = true

    local origGather = genMod.onActivityAcceptGatherData
    if origGather then
      genMod.onActivityAcceptGatherData = function(elemData, activityData)
        origGather(elemData, activityData)

        if not isSplitModeActive() then return end

        for _, elem in ipairs(elemData or {}) do
          if elem.type == "logisticsParking" and elem.psPath then
            local hasDropOff = false
            for _, act in ipairs(activityData or {}) do
              if act.buttonLabel == _tr("ui.career.delivery.general.dropOff")
                or (act.heading and act.heading == _tr("ui.career.delivery.general.deliveryDropOff")) then
                hasDropOff = true
                break
              end
            end

            if not hasDropOff and parcelMgrMod and parcelMgrMod.getAllCargoInVehicles then
              local ps = (genMod.getParkingSpotByPath and genMod.getParkingSpotByPath(elem.psPath))
                or (career_modules_delivery_generator and career_modules_delivery_generator.getParkingSpotByPath and career_modules_delivery_generator.getParkingSpotByPath(elem.psPath))
              local psPos = ps and ps.pos
              if psPos then
                local allCargo = parcelMgrMod.getAllCargoInVehicles()
                local matchingCargoCount = 0
                for _, cargo in ipairs(allCargo or {}) do
                  local destMatches = false
                  if cargo.destination then
                    if cargo.destination.type == "facilityParkingspot" and cargo.destination.psPath == elem.psPath then
                      destMatches = true
                    elseif cargo.destination.type == "multi" and cargo.destination.destinations then
                      for _, d in ipairs(cargo.destination.destinations) do
                        if d.psPath == elem.psPath then destMatches = true; break end
                      end
                    end
                  end

                  if destMatches and cargo.location and cargo.location.vehId then
                    local cVeh = scenetree.findObjectById(tonumber(cargo.location.vehId))
                    if cVeh then
                      local distSq = (cVeh:getPosition() - psPos):squaredLength()
                      if distSq < 30 * 30 then
                        matchingCargoCount = matchingCargoCount + 1
                      end
                    end
                  end
                end

                if matchingCargoCount > 0 then
                  log("I", "careerSplitScreen", string.format("Detected %d drop-offable parcels near stall %s! Injecting primary drop-off prompt.", matchingCargoCount, tostring(elem.psPath)))
                  local dropOffPoi = {
                    icon = "poi_dropoff_round",
                    heading = _tr("ui.career.delivery.general.deliveryDropOff"),
                    buttonLabel = _tr("ui.career.delivery.general.dropOff"),
                    buttonFun = function()
                      extensions.ui_router.navigate('career.cargoDropOff', {facilityId = elem.facId, parkingSpotPath = elem.psPath})
                    end,
                    props = {
                      {
                        icon = "checkmark",
                        keyLabel = matchingCargoCount > 1
                          and core_locales.contextTranslate("ui.career.delivery.general.parcelsDropoff", {count = matchingCargoCount})
                          or _tr("ui.career.delivery.general.parcelDropoff")
                      }
                    },
                    sorting = {
                      type = elem.type,
                      id = elem.id or "deliveryDropOff"
                    }
                  }
                  table.insert(activityData, 1, dropOffPoi)
                end
              end
            end
          end
        end
      end
      log("I", "careerSplitScreen", "Hooked " .. tostring(name) .. " onActivityAcceptGatherData for independent drop-off.")
    end
  end

  if career_modules_delivery_general and not career_modules_delivery_general._careerSplitActivityHooked then
    hookDeliveryActivity(career_modules_delivery_general, career_modules_delivery_parcelManager, "career_modules_delivery_general")
  end
  if overhaul_career_logistics_general and not overhaul_career_logistics_general._careerSplitActivityHooked then
    hookDeliveryActivity(overhaul_career_logistics_general, overhaul_career_logistics_parcelManager, "overhaul_career_logistics_general")
  end

  -- Hook cargoScreen enter, setCargoRoute, and setBestRoute for automatic player routing
  local function hookCargoScreenRouting(cScreenMod, parcelMgrMod, name)
    if not cScreenMod or cScreenMod._careerSplitRoutingHooked then return end
    cScreenMod._careerSplitRoutingHooked = true

    -- Hook enterCargoOverviewScreen
    local origEnter = cScreenMod.enterCargoOverviewScreen
    if origEnter then
      cScreenMod.enterCargoOverviewScreen = function(facilityId, parkingSpotPath)
        if isSplitModeActive() then
          local targetPIdx = interactingPlayer
          if targetPIdx == nil and parkingSpotPath then
            local spot = (overhaul_career_logistics_general and overhaul_career_logistics_general.getParkingSpotByPath and overhaul_career_logistics_general.getParkingSpotByPath(parkingSpotPath))
              or (career_modules_delivery_general and career_modules_delivery_general.getParkingSpotByPath and career_modules_delivery_general.getParkingSpotByPath(parkingSpotPath))
            if spot and spot.pos then
              local p0Veh = getPlayerVehicle(0)
              local p1Veh = getP2Vehicle() or getPlayerVehicle(1)
              local d0 = p0Veh and (p0Veh:getPosition() - spot.pos):squaredLength() or math.huge
              local d1 = p1Veh and (p1Veh:getPosition() - spot.pos):squaredLength() or math.huge
              if d1 < d0 and d1 < 35 * 35 then
                targetPIdx = 1
                lastInteractingVehicleId = p1Veh:getID()
              elseif d0 < 35 * 35 then
                targetPIdx = 0
                lastInteractingVehicleId = p0Veh and p0Veh:getID()
              end
            end
          end
          if targetPIdx ~= nil then
            setRouteTargetPlayer(targetPIdx, true)
          end
        end
        return origEnter(facilityId, parkingSpotPath)
      end
    end

    -- Hook formatCargoGroup so autoLoadLocations prioritize interacting player's vehicle
    local origFormatCargoGroup = cScreenMod.formatCargoGroup
    if origFormatCargoGroup then
      cScreenMod.formatCargoGroup = function(group, playerCargoContainers, showFirstSeen)
        local targetVehId = lastInteractingVehicleId
        if not targetVehId and isSplitModeActive() then
          local pIdx = interactingPlayer or (core_groundMarkers and core_groundMarkers.targetPlayerIndex) or selectedRoutePlayer or 0
          local targetVeh = (pIdx == 1) and (getP2Vehicle() or getPlayerVehicle(1)) or getPlayerVehicle(0)
          targetVehId = targetVeh and targetVeh:getID()
        end

        local containersToUse = playerCargoContainers
        if isSplitModeActive() and targetVehId and type(playerCargoContainers) == "table" and #playerCargoContainers > 1 then
          containersToUse = {}
          for _, c in ipairs(playerCargoContainers) do
            table.insert(containersToUse, c)
          end
          table.sort(containersToUse, function(a, b)
            local aMatch = (a and a.vehId and tonumber(a.vehId) == targetVehId) and 1 or 0
            local bMatch = (b and b.vehId and tonumber(b.vehId) == targetVehId) and 1 or 0
            if aMatch ~= bMatch then return aMatch > bMatch end
            if a.vehId == b.vehId then return a.containerId < b.containerId end
            return a.vehId < b.vehId
          end)
        end

        local ret = origFormatCargoGroup(group, containersToUse, showFirstSeen)

        if isSplitModeActive() and targetVehId and type(ret) == "table" and type(ret.ids) == "table" then
          -- Re-sort ret.targetLocations so target vehicle's containers appear first in dropdown
          if type(ret.targetLocations) == "table" and #ret.targetLocations > 1 then
            table.sort(ret.targetLocations, function(a, b)
              local aVeh = a and ((a.location and a.location.vehId) or (a.containerVehicleInfo and a.containerVehicleInfo.vehId))
              local bVeh = b and ((b.location and b.location.vehId) or (b.containerVehicleInfo and b.containerVehicleInfo.vehId))
              local aMatch = (aVeh and tonumber(aVeh) == targetVehId) and 1 or 0
              local bMatch = (bVeh and tonumber(bVeh) == targetVehId) and 1 or 0
              if aMatch ~= bMatch then return aMatch > bMatch end
              if a and b and a.maxAmount and b.maxAmount and a.maxAmount ~= b.maxAmount then
                return a.maxAmount > b.maxAmount
              end
              return false
            end)
          end

          -- Rebuild ret.autoLoadLocations strictly prioritizing targetVehId's containers
          local targetContainers = {}
          local otherContainers = {}
          for _, loc in ipairs(ret.targetLocations or {}) do
            if loc.enabled and (loc.maxAmount or 0) > 0 then
              local vId = loc.containerVehicleInfo and loc.containerVehicleInfo.vehId or (loc.location and loc.location.vehId)
              if vId and tonumber(vId) == targetVehId then
                table.insert(targetContainers, loc)
              else
                table.insert(otherContainers, loc)
              end
            end
          end

          local newAutoLoad = {}
          local remainingNeeded = #ret.ids
          for _, loc in ipairs(targetContainers) do
            for i = 1, (loc.maxAmount or 0) do
              if remainingNeeded > 0 and loc.location then
                table.insert(newAutoLoad, {
                  type = "vehicle",
                  vehId = tonumber(loc.location.vehId),
                  containerId = tonumber(loc.location.containerId)
                })
                remainingNeeded = remainingNeeded - 1
              end
            end
          end
          if remainingNeeded > 0 then
            for _, loc in ipairs(otherContainers) do
              for i = 1, (loc.maxAmount or 0) do
                if remainingNeeded > 0 and loc.location then
                  table.insert(newAutoLoad, {
                    type = "vehicle",
                    vehId = tonumber(loc.location.vehId),
                    containerId = tonumber(loc.location.containerId)
                  })
                  remainingNeeded = remainingNeeded - 1
                end
              end
            end
          end
          if #newAutoLoad > 0 then
            ret.autoLoadLocations = newAutoLoad
          end
        end
        return ret
      end
    end

    local origExit = cScreenMod.exitCargoOverviewScreen
    if origExit then
      cScreenMod.exitCargoOverviewScreen = function(...)
        lastInteractingVehicleId = nil
        interactingPlayer = nil
        return origExit(...)
      end
    end

    -- Hook setCargoRoute (e.g. clicking Set Route on a cargo card)
    local origSetCargoRoute = cScreenMod.setCargoRoute
    if origSetCargoRoute then
      cScreenMod.setCargoRoute = function(cargoId, origin)
        if isSplitModeActive() and cargoId and parcelMgrMod and parcelMgrMod.getCargoById then
          local cargo = parcelMgrMod.getCargoById(cargoId)
          local vId = cargo and ((cargo.location and cargo.location.vehId) or (cargo._transientMove and cargo._transientMove.targetLocation and cargo._transientMove.targetLocation.vehId))
          local p1Veh = getP2Vehicle() or getPlayerVehicle(1)
          if vId and p1Veh and vId == p1Veh:getID() then
            setRouteTargetPlayer(1, true)
          elseif vId then
            local p0Veh = getPlayerVehicle(0)
            if p0Veh and vId == p0Veh:getID() then
              setRouteTargetPlayer(0, true)
            end
          end
        end
        return origSetCargoRoute(cargoId, origin)
      end
    end

    -- Hook setBestRoute so it routes for the active player's vehicle
    local origSetBestRoute = cScreenMod.setBestRoute
    if origSetBestRoute then
      cScreenMod.setBestRoute = function(onlyClosestTarget)
        if not isSplitModeActive() then
          return origSetBestRoute(onlyClosestTarget)
        end

        local pIdx = core_groundMarkers and core_groundMarkers.targetPlayerIndex or selectedRoutePlayer or 0
        local targetVeh = (pIdx == 1) and (getP2Vehicle() or getPlayerVehicle(1)) or getPlayerVehicle(0)
        local targetVehId = targetVeh and targetVeh:getID()

        local origGetAllCargo = parcelMgrMod and parcelMgrMod.getAllCargoInVehicles
        if origGetAllCargo and targetVehId then
          parcelMgrMod.getAllCargoInVehicles = function(includeTransient)
            local list = origGetAllCargo(includeTransient)
            local filtered = {}
            for _, c in ipairs(list or {}) do
              local vId = (c.location and c.location.vehId) or (c._transientMove and c._transientMove.targetLocation and c._transientMove.targetLocation.vehId)
              if vId == targetVehId then
                table.insert(filtered, c)
              end
            end
            return filtered
          end
        end

        local origGetPlayerVehicle = _G.getPlayerVehicle
        if targetVeh and origGetPlayerVehicle then
          _G.getPlayerVehicle = function(idx)
            if idx == 0 or idx == nil then
              return targetVeh
            end
            return origGetPlayerVehicle(idx)
          end
        end

        local ok, res = pcall(origSetBestRoute, onlyClosestTarget)

        if origGetAllCargo then
          parcelMgrMod.getAllCargoInVehicles = origGetAllCargo
        end
        if origGetPlayerVehicle then
          _G.getPlayerVehicle = origGetPlayerVehicle
        end

        if not ok then
          log("E", "careerSplitScreen", "Error in " .. tostring(name) .. " setBestRoute: " .. tostring(res))
        end
        return res
      end
    end

    log("I", "careerSplitScreen", "Hooked " .. tostring(name) .. " for player-specific cargo routing.")
  end

  hookCargoScreenRouting(overhaul_career_logistics_cargoScreen, overhaul_career_logistics_parcelManager, "overhaul_career_logistics_cargoScreen")
  hookCargoScreenRouting(career_modules_delivery_cargoScreen, career_modules_delivery_parcelManager, "career_modules_delivery_cargoScreen")
end

local selectedRoutePlayer = 0

hookCoreGroundMarkers = function()
  if not core_groundMarkers then return end
  if core_groundMarkers._careerSplitHooked then return end
  core_groundMarkers._careerSplitHooked = true

  core_groundMarkers.targetPlayerIndex = core_groundMarkers.targetPlayerIndex or selectedRoutePlayer or 0

  if not core_groundMarkers.getTargetPlayer then
    core_groundMarkers.getTargetPlayer = function()
      return core_groundMarkers.targetPlayerIndex or selectedRoutePlayer or 0
    end
  end

  if not core_groundMarkers.setTargetPlayer then
    core_groundMarkers.setTargetPlayer = function(pIdx)
      pIdx = tonumber(pIdx) or 0
      selectedRoutePlayer = pIdx
      core_groundMarkers.targetPlayerIndex = pIdx
      if pIdx == 1 then
        core_groundMarkers.color = {0.0, 0.55, 1.0}
        core_groundMarkers.floatingArrowColor = {0.0, 0.55, 1.0}
      else
        core_groundMarkers.color = {1.0, 0.47, 0.08}
        core_groundMarkers.floatingArrowColor = {1.0, 0.55, 0.1}
      end
      if freeroam_bigMapMode and freeroam_bigMapMode.resetRoute then
        freeroam_bigMapMode.resetRoute()
      end
    end
  end

  if not core_groundMarkers.clearPathForPlayer then
    core_groundMarkers.clearPathForPlayer = function(pIdx)
      pIdx = pIdx or (core_groundMarkers.getTargetPlayer and core_groundMarkers.getTargetPlayer()) or 0
      if core_groundMarkers.setPath then
        core_groundMarkers.setPath(nil, {playerIndex = pIdx})
      end
    end
  end
end

ensureGroundMarkersLoaded = function()
  if not core_groundMarkers or not core_groundMarkers.setTargetPlayer then
    log("I", "careerSplitScreen", "core_groundMarkers missing multi-player routing; reloading extension from mod...")
    pcall(function()
      if extensions and extensions.reload then
        extensions.reload("core_groundMarkers")
      end
    end)
  end

  if core_groundMarkers and not core_groundMarkers.setTargetPlayer then
    log("W", "careerSplitScreen", "Reload did not provide setTargetPlayer, injecting runtime hooks...")
    hookCoreGroundMarkers()
  end
end

getRouteTargetPlayer = function()
  if core_groundMarkers and core_groundMarkers.getTargetPlayer then
    local p = core_groundMarkers.getTargetPlayer()
    if p ~= nil then return p end
  end
  return selectedRoutePlayer or 0
end

setRouteTargetPlayer = function(pIdx, silent)
  pIdx = tonumber(pIdx) or 0
  selectedRoutePlayer = pIdx
  ensureGroundMarkersLoaded()
  if core_groundMarkers and core_groundMarkers.setTargetPlayer then
    core_groundMarkers.setTargetPlayer(pIdx)
  end
  if not silent and Engine and Engine.Audio then
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Main>select')
  end
end

toggleRouteTarget = function()
  local cur = getRouteTargetPlayer()
  local nxt = (cur == 0) and 1 or 0
  setRouteTargetPlayer(nxt)
  if guihooks and guihooks.trigger then
    guihooks.trigger('toastrMsg', {
      type = 'info',
      title = 'Map Route Target',
      msg = (nxt == 0 and 'Routing for Player 1 (Orange)' or 'Routing for Player 2 (Blue)'),
      config = {timeOut = 1500}
    })
  end
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
    local currentTarget = getRouteTargetPlayer()
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

local function updateBigMapVehicles()
  if not freeroam_bigMapMode or not freeroam_bigMapMode.bigMapActive or not freeroam_bigMapMode.bigMapActive() then return end
  local iconRenderer = gameplay_playmodeMarkers and gameplay_playmodeMarkers.getBigmapRendererObj and gameplay_playmodeMarkers.getBigmapRendererObj()
  if not iconRenderer then return end

  local pVeh = getP2Vehicle()
  if pVeh then
    local iconName = "playerVehicle_1"
    local icon = iconRenderer:getIconByName(iconName)
    if not icon then
      iconRenderer:addIcon(iconName, "player_marker", pVeh:getPosition())
      icon = iconRenderer:getIconByName(iconName)
      if icon then
        icon.color = ColorI(0, 140, 255, 255)
        icon.customSizeFactor = 0.75
      end
    else
      icon.pos = pVeh:getPosition()
      icon.color = ColorI(0, 140, 255, 255)
    end
  end
end

local function drawBigMapPlayerSelector()
  if not freeroam_bigMapMode or not freeroam_bigMapMode.bigMapActive or not freeroam_bigMapMode.bigMapActive() then return end
  if not isSplitModeActive() then return end

  local im = ui_imgui
  if not im then return end

  ensureGroundMarkersLoaded()

  local canvas = scenetree.findObject("Canvas")
  local winW, winH = 1920, 1080
  if canvas and canvas.getWindowClientSizeXY then
    winW, winH = canvas:getWindowClientSizeXY()
  end

  local btnW = 125
  local btnH = 34
  local currentNavTarget = getRouteTargetPlayer()

  local hasTargetRoute = false
  if core_groundMarkers then
    if core_groundMarkers.currentlyHasTarget then
      hasTargetRoute = core_groundMarkers.currentlyHasTarget(currentNavTarget)
    elseif core_groundMarkers.getPathForPlayer then
      hasTargetRoute = (core_groundMarkers.getPathForPlayer(currentNavTarget) ~= nil)
    end
  end

  local barW = hasTargetRoute and 540 or 460
  local barH = 50
  local posX = (winW - barW) * 0.5
  local posY = 14

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

  im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(12, 8))
  im.PushStyleVar1(im.StyleVar_WindowRounding, 8)
  im.PushStyleVar1(im.StyleVar_WindowBorderSize, 2)
  im.PushStyleColor1(im.Col_WindowBg, im.GetColorU322(im.ImVec4(0.05, 0.07, 0.11, 0.94)))
  im.PushStyleColor1(im.Col_Border, im.GetColorU322(im.ImVec4(0.25, 0.38, 0.55, 0.85)))

  if im.Begin("###CareerBigMapPlayerSelector", nil, flags) then
    im.AlignTextToFramePadding()
    im.TextColored(im.ImVec4(0.85, 0.92, 1.0, 1.0), "Route For:")
    im.SameLine()

    -- P1 Button (Orange)
    local isP1Selected = (currentNavTarget == 0)
    if isP1Selected then
      im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.95, 0.45, 0.05, 0.95)))
      im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(1.0, 0.55, 0.15, 1.0)))
      im.PushStyleColor1(im.Col_Text, im.GetColorU322(im.ImVec4(1, 1, 1, 1)))
    else
      im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.18, 0.20, 0.26, 0.8)))
      im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.28, 0.32, 0.40, 0.9)))
      im.PushStyleColor1(im.Col_Text, im.GetColorU322(im.ImVec4(0.7, 0.75, 0.8, 0.85)))
    end

    if im.Button("P1 (Orange)###btn_nav_p1", im.ImVec2(btnW, btnH)) then
      setRouteTargetPlayer(0)
    end
    im.PopStyleColor(3)

    im.SameLine()

    -- P2 Button (Blue)
    local isP2Selected = (currentNavTarget == 1)
    if isP2Selected then
      im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.10, 0.50, 0.95, 0.95)))
      im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.20, 0.60, 1.0, 1.0)))
      im.PushStyleColor1(im.Col_Text, im.GetColorU322(im.ImVec4(1, 1, 1, 1)))
    else
      im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.18, 0.20, 0.26, 0.8)))
      im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.28, 0.32, 0.40, 0.9)))
      im.PushStyleColor1(im.Col_Text, im.GetColorU322(im.ImVec4(0.7, 0.75, 0.8, 0.85)))
    end

    if im.Button("P2 (Blue)###btn_nav_p2", im.ImVec2(btnW, btnH)) then
      setRouteTargetPlayer(1)
    end
    im.PopStyleColor(3)

    -- Clear Button (if current target has an active route)
    if hasTargetRoute then
      im.SameLine()
      im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.55, 0.15, 0.15, 0.85)))
      im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.75, 0.2, 0.2, 1.0)))
      im.PushStyleColor1(im.Col_Text, im.GetColorU322(im.ImVec4(1, 1, 1, 1)))
      if im.Button("Clear###btn_nav_clear", im.ImVec2(65, btnH)) then
        if core_groundMarkers and core_groundMarkers.clearPathForPlayer then
          core_groundMarkers.clearPathForPlayer(currentNavTarget)
        elseif freeroam_bigMapMode and freeroam_bigMapMode.setNavFocus then
          freeroam_bigMapMode.setNavFocus(nil)
        end
        if freeroam_bigMapMode and freeroam_bigMapMode.resetRoute then
          freeroam_bigMapMode.resetRoute()
        end
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Main>select')
      end
      im.PopStyleColor(3)
    end

    im.SameLine()
    im.TextColored(im.ImVec4(0.55, 0.65, 0.75, 0.85), "[Tab] Switch")
  end
  im.End()

  im.PopStyleColor(2)
  im.PopStyleVar(3)
end

local origToggleBigMap = nil
local origEnterBigMap = nil
local origExitBigMap = nil
local _bigMapToggling = false  -- re-entrancy guard to prevent RLS wrapper infinite recursion

local function careerToggleBigMap(...)
  -- Re-entrancy guard: some wrappers (e.g. RLS toggleBigMapWrapper) call freeroam_bigMapMode.toggleBigMap()
  -- which is now *this* function, causing infinite recursion. Block it.
  if _bigMapToggling then return end
  _bigMapToggling = true
  local ok, err = pcall(function(...)
    if isSplitModeActive() or isCareerModeActive() then
      if freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive and freeroam_bigMapMode.bigMapActive() then
        freeroam_bigMapMode.exitBigMap(true, true)
        return
      else
        local rName = extensions.ui_router and extensions.ui_router.getCurrent and extensions.ui_router.getCurrent()
        rName = rName and rName.resolved and rName.resolved.name
        if rName == "multiseat" or rName == "play" or rName == "pause" or string.find(rName or "", "pause") or not rName then
          if overhaul_phone_phone and overhaul_phone_phone.isPhoneOpen and overhaul_phone_phone.isPhoneOpen() then
            overhaul_phone_phone.closePhone()
          end
          if freeroam_bigMapMode and freeroam_bigMapMode.enterBigMap then
            freeroam_bigMapMode.enterBigMap({instant = true, forceOpen = true})
          end
          return
        end
      end
    end
    if origToggleBigMap and origToggleBigMap ~= careerToggleBigMap then
      origToggleBigMap(...)
      return
    end
    if freeroam_bigMapMode and freeroam_bigMapMode.enterBigMap then
      freeroam_bigMapMode.enterBigMap({instant = true, forceOpen = true})
    end
  end, ...)
  _bigMapToggling = false
  if not ok then log("E", "careerSplitScreen", "careerToggleBigMap error: " .. tostring(err)) end
end

local function careerEnterBigMap(options, ...)
  options = options or {}
  if isSplitModeActive() then
    options.instant = true
    options.forceOpen = true
    ensureGroundMarkersLoaded()
  end
  if origEnterBigMap and origEnterBigMap ~= careerEnterBigMap then
    local res = origEnterBigMap(options, ...)
    if isSplitModeActive() then
      bindBigMapSelectKeys()
    end
    return res
  end
end

local function careerExitBigMap(instant, closeEscMenu, forceGameCam, ...)
  if isSplitModeActive() then
    instant = true
  end
  local res
  if origExitBigMap and origExitBigMap ~= careerExitBigMap then
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

local function hookBigMapMode()
  if not freeroam_bigMapMode then return end

  if freeroam_bigMapMode.toggleBigMap ~= careerToggleBigMap then
    origToggleBigMap = freeroam_bigMapMode.toggleBigMap
    freeroam_bigMapMode.toggleBigMap = careerToggleBigMap
  end

  if freeroam_bigMapMode.enterBigMap ~= careerEnterBigMap then
    origEnterBigMap = freeroam_bigMapMode.enterBigMap
    freeroam_bigMapMode.enterBigMap = careerEnterBigMap
  end

  if freeroam_bigMapMode.exitBigMap ~= careerExitBigMap then
    origExitBigMap = freeroam_bigMapMode.exitBigMap
    freeroam_bigMapMode.exitBigMap = careerExitBigMap
  end

  if not freeroam_bigMapMode._careerSplitCamHooked then
    freeroam_bigMapMode._careerSplitCamHooked = true

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
          local barW = 560
          local minX = (winW - barW) * 0.5 - 20
          local maxX = (winW + barW) * 0.5 + 20
          if (mPos and mPos.x >= minX and mPos.x <= maxX and mPos.y >= 0 and mPos.y <= 85)
            or (im.GetIO and im.GetIO().WantCaptureMouse) then
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
              local currentTarget = getRouteTargetPlayer()
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

local customDeviceMap = {}

local function hookCoreMultiseat()
  if not core_multiseat or core_multiseat._careerSplitHooked then return end
  core_multiseat._careerSplitHooked = true

  core_multiseat.setDevicePlayer = function(devname, player)
    customDeviceMap[devname] = player
    if core_input_bindings and core_input_bindings.setPlayerToDevice then
      core_input_bindings.setPlayerToDevice(devname, player)
    end
  end

  if not core_multiseat.getDevicesByPlayer then
    core_multiseat.getDevicesByPlayer = function()
      local result = {}
      local devs = (core_input_bindings and core_input_bindings.devices) or {}
      for devname, info in pairs(devs) do
        local p = customDeviceMap[devname] or (core_input_bindings and core_input_bindings.assignedPlayers and core_input_bindings.assignedPlayers[devname]) or 0
        if not isSplitModeActive() then p = 0 end
        result[p] = result[p] or {}
        table.insert(result[p], {
          id = devname,
          productName = (Input and Input.getProductName and Input.getProductName(devname)) or devname,
          controllerIndex = tonumber(string.match(devname, "(%d+)$")),
          connected = true,
        })
      end
      return result
    end
  end

  local origGetAssignedPlayers = core_multiseat.getAssignedPlayers
  core_multiseat.getAssignedPlayers = function(devices, logEnabled, seatPlayers)
    if not isSplitModeActive() then
      local result = {}
      local devs = devices or (core_input_bindings and core_input_bindings.devices) or {}
      for devname in pairs(devs) do
        result[devname] = 0
      end
      return result
    end

    if isCareerModeActive() then seatPlayers = false end

    local result = {}
    local devs = devices or (core_input_bindings and core_input_bindings.devices) or {}
    for devname in pairs(devs) do
      local p = customDeviceMap[devname]
      if p == nil then
        if string.find(devname, "keyboard") or string.find(devname, "mouse") then
          p = 0
        else
          p = -1
        end
      end
      result[devname] = p
    end
    return result
  end

  local origGetPlayers = core_multiseat.getPlayers
  core_multiseat.getPlayers = function(result)
    result = result or {}
    table.clear(result)
    if isSplitModeActive() then
      result[1] = 0
      result[2] = 1
      return result
    end
    if origGetPlayers then return origGetPlayers(result) end
    result[1] = 0
    return result
  end

  local origIsPlayerActive = core_multiseat.isPlayerActive
  core_multiseat.isPlayerActive = function(player)
    if isSplitModeActive() and (player == 0 or player == 1) then
      return true
    end
    if origIsPlayerActive then return origIsPlayerActive(player) end
    return player == 0
  end

  local origGetParticipants = core_multiseat.getParticipants
  core_multiseat.getParticipants = function(players)
    local list = origGetParticipants and origGetParticipants(players) or {}
    if isSplitModeActive() then
      for _, p in ipairs(list) do
        if p.assignment then
          p.assignment.connected = true
          if not p.assignment.connectedDeviceLabel or p.assignment.connectedDeviceLabel == "" then
            p.assignment.connectedDeviceLabel = (p.assignment.playerIndex == 0 and "Keyboard & Mouse" or "Controller")
            p.assignment.deviceLabel = p.assignment.connectedDeviceLabel
          end
          if not p.assignment.connectedInputIcon then
            p.assignment.connectedInputIcon = (p.assignment.playerIndex == 0 and "keyboard" or "gamepad")
            p.inputIcon = p.assignment.connectedInputIcon
          end
        end
      end
    end
    return list
  end

  local origIsMultiseatActive = core_multiseat.isMultiseatActive
  core_multiseat.isMultiseatActive = function()
    if isSplitModeActive() or isCareerModeActive() then
      return false
    end
    if origIsMultiseatActive then return origIsMultiseatActive() end
    return false
  end

  local origSetMultiseatActive = core_multiseat.setMultiseatActive
  core_multiseat.setMultiseatActive = function(active)
    if isSplitModeActive() or isCareerModeActive() then
      if origSetMultiseatActive then origSetMultiseatActive(false) end
      return
    end
    if origSetMultiseatActive then origSetMultiseatActive(active) end
  end

  log("I", "careerSplitScreen", "Successfully hooked core_multiseat without reloading.")
end

local function ensureModExtensionsLoaded()
  hookCoreMultiseat()
  ensureGroundMarkersLoaded()
end

local function getConnectedDevicesSummary()
  local devices = (core_input_bindings and core_input_bindings.devices) or {}
  local keyboards = {}
  local mice = {}
  local controllers = {}

  for devname, _ in pairs(devices) do
    local lname = string.lower(devname)
    if string.find(lname, "mouse") then
      table.insert(mice, devname)
    elseif string.find(lname, "keyboard") then
      table.insert(keyboards, devname)
    else
      -- Gamepads, steering wheels, pedals, joysticks, xinput, dinput, etc.
      table.insert(controllers, devname)
    end
  end

  table.sort(keyboards)
  table.sort(mice)
  table.sort(controllers)

  return keyboards, controllers, mice
end

local function hasMultipleDevicesConnected()
  local keyboards, controllers, _ = getConnectedDevicesSummary()
  if #controllers >= 2 then
    return true
  end
  if #keyboards >= 1 and #controllers >= 1 then
    return true
  end
  if #keyboards >= 2 then
    return true
  end
  return false
end

local function isolateMenuActionMapsForPlayer0(enable)
  if not core_input_actionFilter or not core_input_actionFilter.setActionMapPlayerMask then return end

  local owner = "careerSplitScreen"
  if enable then
    -- Player 0 only = bitmask 1 (1 << 0). Player 1 (bitmask 2) is excluded.
    -- This guarantees Player 2's controller left analog stick (thumblx/thumbly) is NEVER intercepted by menu navigation!
    local p0Mask = 1
    core_input_actionFilter.setActionMapPlayerMask(owner, "MenuActionMap", p0Mask)
    core_input_actionFilter.setActionMapPlayerMask(owner, "MissionUIActionMap", p0Mask)
    if core_input_actions and core_input_actions.menuActionMapNames then
      for mapName, _ in pairs(core_input_actions.menuActionMapNames) do
        core_input_actionFilter.setActionMapPlayerMask(owner, mapName, p0Mask)
      end
    end
  else
    if core_input_actionFilter.clearActionMapPlayerMasks then
      core_input_actionFilter.clearActionMapPlayerMasks(owner)
    end
  end
end

local function ensureSinglePlayerInputState()
  if isSplitActive then return end
  table.clear(customDeviceMap)
  if settings and settings.getValue and settings.getValue('multiseat') then
    settings.setValue('multiseat', false)
  end
  if core_multiseat then
    if core_multiseat.clearJoinedPlayers then core_multiseat.clearJoinedPlayers() end
    if core_multiseat.setMultiseatActive then core_multiseat.setMultiseatActive(false) end
  end
  if core_input_bindings and core_input_bindings.devices then
    for devname, _ in pairs(core_input_bindings.devices) do
      if core_multiseat and core_multiseat.setDevicePlayer then
        core_multiseat.setDevicePlayer(devname, 0)
      end
      if core_input_bindings.setPlayerToDevice then
        core_input_bindings.setPlayerToDevice(devname, 0)
      end
    end
    if core_input_bindings.refreshAssignedPlayers then
      core_input_bindings.refreshAssignedPlayers(false, false)
    end
  end
  isolateMenuActionMapsForPlayer0(false)
  if core_input_actionFilter and core_input_actionFilter.addAction then
    core_input_actionFilter.addAction(0, "splitScreenBlockedActions", false)
  end
  if extensions.isExtensionLoaded("render_splitScreen") and not isSplitActive then
    extensions.unload("render_splitScreen")
  end
end

local function autoAssignDevices()
  if not core_input_bindings or not core_input_bindings.devices then return end
  local keyboards, controllers, mice = getConnectedDevicesSummary()

  local devMap = {}

  if #keyboards >= 1 and #controllers >= 1 then
    -- Default configuration:
    -- Keyboard (+ Mouse) -> Player 1 (Player index 0)
    -- Next device (First controller / gamepad / wheel) -> Player 2 (Player index 1)
    for _, k in ipairs(keyboards) do devMap[k] = 0 end
    for _, m in ipairs(mice) do devMap[m] = 0 end
    devMap[controllers[1]] = 1

    -- If a second controller is connected, assign it to Player 1 as well (so P1 can use gamepad or keyboard)
    if #controllers >= 2 then
      devMap[controllers[2]] = 0
    end
    -- Any additional controllers remain unassigned (-1)
    for i = 3, #controllers do
      devMap[controllers[i]] = -1
    end
  elseif #controllers >= 2 then
    -- No keyboards detected: Controller 1 -> Player 1, Controller 2 -> Player 2
    devMap[controllers[1]] = 0
    devMap[controllers[2]] = 1
    for _, k in ipairs(keyboards) do devMap[k] = 0 end
    for _, m in ipairs(mice) do devMap[m] = 0 end
    for i = 3, #controllers do
      devMap[controllers[i]] = -1
    end
  elseif #keyboards >= 2 then
    -- Two keyboards: Keyboard 1 -> Player 1, Keyboard 2 -> Player 2
    devMap[keyboards[1]] = 0
    devMap[keyboards[2]] = 1
    for _, m in ipairs(mice) do devMap[m] = 0 end
  else
    -- Fallback: assign all to Player 0
    for _, k in ipairs(keyboards) do devMap[k] = 0 end
    for _, m in ipairs(mice) do devMap[m] = 0 end
    for _, c in ipairs(controllers) do devMap[c] = 0 end
  end

  for devname, player in pairs(devMap) do
    if core_multiseat and core_multiseat.setDevicePlayer then
      core_multiseat.setDevicePlayer(devname, player)
    end
    if core_input_bindings and core_input_bindings.setPlayerToDevice then
      core_input_bindings.setPlayerToDevice(devname, player)
    end
  end

  if core_multiseat and core_multiseat.applyConfiguration then
    local commitConfig = {
      participants = {
        { playerIndex = 0, personaNumber = 1 },
        { playerIndex = 1, personaNumber = 2 },
      },
      manualAssignments = devMap,
      multiseatActive = false,
    }
    pcall(function()
      local ok, reason = core_multiseat.applyConfiguration(commitConfig)
      if core_multiseat.finalizeConfiguration then
        core_multiseat.finalizeConfiguration()
      end
      if core_multiseat.setMultiseatActive then
        core_multiseat.setMultiseatActive(false)
      end
      log("I", "careerSplitScreen", "Applied multiseat configuration directly: " .. tostring(ok) .. " " .. tostring(reason))
    end)
  end
  guihooks.trigger("MultiseatConfigurationChanged")
  guihooks.trigger("LocalParticipantsChanged")

  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
  if gameplay_playmodeMarkers and gameplay_playmodeMarkers.clear then
    gameplay_playmodeMarkers.clear()
  end

  log("I", "careerSplitScreen", "Auto-assigned devices: " .. dumps(devMap):gsub("\n", ""):gsub("  ", " "))
end

local function startSplitScreen()
  invalidateKeyPromptCache()
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

  -- Pre-flight check: Verify multiple controllable devices are connected
  local keyboards, controllers, mice = getConnectedDevicesSummary()
  if not hasMultipleDevicesConnected() then
    if Engine and Engine.Audio and Engine.Audio.playOnce then
      Engine.Audio.playOnce('AudioGui', 'event:>UI>Special>Error')
    end
    guihooks.trigger("toastrMsg", {
      type = "error",
      title = "Career Split-Screen",
      msg = "No multiple devices connected! Please connect a controller, gamepad, or steering wheel for Player 2.",
      config = { time = 6000 }
    })
    if ui_message then
      ui_message("No multiple devices connected! Split-screen co-op requires at least two controllers, or a keyboard and a controller / steering wheel.", 6, "error", "gamepad")
    end
    log("W", "careerSplitScreen", string.format("Cannot start split-screen: insufficient devices connected (keyboards: %d, controllers/wheels: %d)", #keyboards, #controllers))
    return
  end

  -- 1. CRITICAL: Mark split active FIRST so isSplitModeActive() returns true immediately
  isSplitActive = true

  -- 2. Hook core multiseat without reloading
  hookCoreMultiseat()

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

  -- 3. Auto-configure controller/keyboard device mapping
  autoAssignDevices()

  -- 4. Enable multiseat settings & extensions
  settings.setValue('multiseat', true)
  if core_multiseat then
    core_multiseat.setMultiseatActive(false)
    if core_multiseat.joinPlayer then
      core_multiseat.joinPlayer(0)
      core_multiseat.joinPlayer(1)
    end
  end

  -- 5. CRUCIAL: refreshAssignedPlayers with seatPlayers = false so multiseat does not unseat players!
  if core_input_bindings and core_input_bindings.refreshAssignedPlayers then
    core_input_bindings.refreshAssignedPlayers(false, false)
  end

  if ui_apps_minimap_minimap and ui_apps_minimap_minimap.disableSplitScreenMinimaps then
    ui_apps_minimap_minimap.disableSplitScreenMinimaps()
  end

  -- 6. Load and initialize split screen render views
  extensions.load("render_splitScreen")
  if render_splitScreen then
    if render_splitScreen.enable then
      render_splitScreen.enable()
    end
    if render_splitScreen.setCustomPlayers then
      render_splitScreen.setCustomPlayers({0, 1})
    end
  end

  -- 7. Re-verify seating
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

  -- 8. Unblock radial menu in Career Mode so Player 0 can still use the radial menu (E)
  if core_input_actionFilter and core_input_actionFilter.addAction then
    core_input_actionFilter.addAction(0, "splitScreenBlockedActions", false)
  end

  hookBigMapMode()
  hookCareerJobsAndLogistics()
  ensureGroundMarkersLoaded()
  setRouteTargetPlayer(0)

  if gameplay_rawPois and gameplay_rawPois.clear then
    gameplay_rawPois.clear()
  end
  if gameplay_playmodeMarkers and gameplay_playmodeMarkers.clear then
    gameplay_playmodeMarkers.clear()
  end
  if overhaul_integration_services_markerInteraction and overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt then
    overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
  end
  if gameplay_markerInteraction and gameplay_markerInteraction.setForceReevaluateOpenPrompt then
    gameplay_markerInteraction.setForceReevaluateOpenPrompt()
  end

  -- 9. Set the gameplay route to multiseat so MultiseatHud mounts and displays speedometers for both players
  if extensions.ui_menuManager and extensions.ui_menuManager.setGameplayRoute then
    extensions.ui_menuManager.setGameplayRoute("multiseat")
  end
  if extensions.ui_router and extensions.ui_router.navigate then
    extensions.ui_router.navigate("multiseat")
  end
  if render_splitScreen and render_splitScreen.emitUiState then
    render_splitScreen.emitUiState()
  end

  -- 10. Isolate menu action maps so UI menus never steal Player 2's controller steering
  isolateMenuActionMapsForPlayer0(true)
  if ui_missionInfo and ui_missionInfo.closeDialogue then
    ui_missionInfo.closeDialogue()
  end

  -- 11. Enable split-screen minimaps for each player
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
  invalidateKeyPromptCache()
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

  -- Restore menu action map masks
  ensureSinglePlayerInputState()

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
  else
    ensureSinglePlayerInputState()
  end
  quickAccessInitialized = false
end

local function onCareerActive(active)
  patchReputationModule()
  if not active and isSplitActive then
    stopSplitScreen()
  elseif not isSplitActive then
    ensureSinglePlayerInputState()
  end
  quickAccessInitialized = false
end

local function onOverhaulModeStarted(saveName)
  if not isSplitActive then
    ensureSinglePlayerInputState()
  end
  quickAccessInitialized = false
end

local function onOverhaulModeStopped()
  if isSplitActive then
    stopSplitScreen()
  else
    ensureSinglePlayerInputState()
  end
  quickAccessInitialized = false
end

local function onGameStateUpdate(gameState)
  if gameState and (gameState.state == "career" or gameState.state == "overhaul") then
    quickAccessInitialized = false
    if not isSplitActive then
      ensureSinglePlayerInputState()
    end
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
  local playerVehicle = (pIdx == 1 and getP2Vehicle()) or getPlayerVehicle(pIdx)
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
  if cachedKeyPrompts[playerIndex] then
    return cachedKeyPrompts[playerIndex]
  end

  local actionName = "gameplay_interact"
  local result = nil

  if core_input_bindings and core_input_bindings.bindings then
    local assignedDev = getAssignedDeviceForPlayer(playerIndex)
    if assignedDev then
      for _, devData in ipairs(core_input_bindings.bindings) do
        if devData.devname == assignedDev then
          local contents = devData.contents or {}
          for _, b in ipairs(contents.bindings or {}) do
            if b.action == actionName and not b.unused and b.control then
              local formatted = formatBindingControl(b.control, contents.devicetype)
              if formatted and formatted ~= "" then
                result = formatted
                break
              end
            end
          end
        end
        if result then break end
      end
    end

    if not result then
      for _, devData in ipairs(core_input_bindings.bindings) do
        local contents = devData.contents or {}
        local devType = contents.devicetype
        local isController = (devType ~= "keyboard" and devType ~= "mouse")
        local match = (playerIndex == 0) or isController
        if match then
          for _, b in ipairs(contents.bindings or {}) do
            if b.action == actionName and not b.unused and b.control then
              local formatted = formatBindingControl(b.control, devType)
              if formatted and formatted ~= "" then
                result = formatted
                break
              end
            end
          end
        end
        if result then break end
      end
    end
  end

  if not result then
    result = (playerIndex == 0) and "E" or "A"
  end

  cachedKeyPrompts[playerIndex] = result
  return result
end

local function onActivityAcceptUpdate(content)
  if isSplitModeActive() then return end
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

local evalInteractionTimer = 0
local function evaluatePlayerInteractions(dtSim)
  if not isSplitModeActive() then
    if next(playerPrompts) then
      table.clear(playerPrompts)
    end
    return
  end

  evalInteractionTimer = evalInteractionTimer + (dtSim or 0.016)
  if evalInteractionTimer < 0.15 then
    return
  end
  evalInteractionTimer = 0

  if not gameplay_playmodeMarkers or not gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree then return end
  local clusterQt = gameplay_playmodeMarkers.getPlaymodeClustersAsQuadtree()
  if not clusterQt then return end

  local checkPlayers = {0}
  local p1Veh = getP2Vehicle() or getPlayerVehicle(1)
  if p1Veh and p1Veh ~= getPlayerVehicle(0) then
    table.insert(checkPlayers, 1)
  else
    playerPrompts[1] = nil
  end

  for _, pIdx in ipairs(checkPlayers) do
    local pData = getPlayerDataForInteraction(pIdx, dtSim)
    if pData and pData.canInteract then
      local pInteractableElements = {}
      local searchRadius = 25
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
          playerPrompts[pIdx].playerIndex = pIdx
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
  if im.WindowFlags_NoNav then
    flags = bit.bor(flags, im.WindowFlags_NoNav)
  end
  if im.WindowFlags_NoNavInputs then
    flags = bit.bor(flags, im.WindowFlags_NoNavInputs)
  end
  if im.WindowFlags_NoNavFocus then
    flags = bit.bor(flags, im.WindowFlags_NoNavFocus)
  end
  if im.WindowFlags_NoFocusOnAppearing then
    flags = bit.bor(flags, im.WindowFlags_NoFocusOnAppearing)
  end
  if im.WindowFlags_NoBringToFrontOnFocus then
    flags = bit.bor(flags, im.WindowFlags_NoBringToFrontOnFocus)
  end
  if im.WindowFlags_NoMouseInputs then
    flags = bit.bor(flags, im.WindowFlags_NoMouseInputs)
  end
  if im.WindowFlags_NoDocking then
    flags = bit.bor(flags, im.WindowFlags_NoDocking)
  end

  -- Clean dark capsule pill styling matching BeamNG prompt style
  im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(10, 5))
  im.PushStyleVar1(im.StyleVar_WindowRounding, boxH * 0.5)
  im.PushStyleVar1(im.StyleVar_WindowBorderSize, 1)
  im.PushStyleColor1(im.Col_WindowBg, im.GetColorU322(im.ImVec4(0.10, 0.11, 0.14, 0.92)))
  im.PushStyleColor1(im.Col_Border, im.GetColorU322(im.ImVec4(0.35, 0.38, 0.44, 0.75)))

  local winTitle = "###SDF_InteractPrompt_" .. tostring(player)
  if im.Begin(winTitle, nil, flags) then
    local drawList = im.GetWindowDrawList()
    local winPos = im.GetWindowPos()
    local keyBadgePadX = 8
    local keyBadgeW = math.max(26, keySize.x + keyBadgePadX * 2)
    local keyBadgeH = 22
    local padX = 10
    local badgeMin = im.ImVec2(winPos.x + padX, winPos.y + (boxH - keyBadgeH) * 0.5)
    local badgeMax = im.ImVec2(winPos.x + padX + keyBadgeW, winPos.y + (boxH + keyBadgeH) * 0.5)

    -- Pure visual drawing for key badge: NO im.Button widget, preventing gamepad stick navigation lock!
    drawList:AddRectFilled(badgeMin, badgeMax, im.GetColorU322(im.ImVec4(0.95, 0.45, 0.10, 0.95)), 4, 0)
    drawList:AddRect(badgeMin, badgeMax, im.GetColorU322(im.ImVec4(1.0, 0.65, 0.30, 0.85)), 4, 0, 1)

    -- Key text inside badge
    local keyTextX = padX + (keyBadgeW - keySize.x) * 0.5
    local keyTextY = (boxH - keySize.y) * 0.5
    im.SetCursorPos(im.ImVec2(keyTextX, keyTextY))
    im.TextColored(im.ImVec4(1.0, 1.0, 1.0, 1.0), keyText)

    -- Action label next to badge
    local labelTextX = padX + keyBadgeW + 10
    local labelTextY = (boxH - headingSize.y) * 0.5
    im.SetCursorPos(im.ImVec2(labelTextX, labelTextY))
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

performInteract = function(targetPlayerIdx)
  if targetPlayerIdx ~= nil then
    local prompt = playerPrompts[targetPlayerIdx]
    if prompt and prompt.buttonFun then
      interactingPlayer = targetPlayerIdx
      if targetPlayerIdx == 0 then
        local p0 = getPlayerVehicle(0)
        lastInteractingVehicleId = p0 and p0:getID()
      else
        local p1 = getP2Vehicle() or getPlayerVehicle(1)
        lastInteractingVehicleId = p1 and p1:getID()
      end
      if isSplitModeActive() then
        setRouteTargetPlayer(targetPlayerIdx, true)
      end
      local ok, err = pcall(prompt.buttonFun)
      interactingPlayer = nil
      playerPrompts[targetPlayerIdx] = nil
      if not ok then
        log("E", "careerSplitScreen", "Error during performInteract: " .. tostring(err))
      end
      return true
    end
    -- Fallback: if specified player index has no prompt, check if the other player does
    -- Handles cases where controller button (A) reports player=0 even when Player 2 pressed it
    local otherIdx = (targetPlayerIdx == 0) and 1 or 0
    local otherPrompt = playerPrompts[otherIdx]
    if otherPrompt and otherPrompt.buttonFun then
      interactingPlayer = otherIdx
      if otherIdx == 0 then
        local p0 = getPlayerVehicle(0)
        lastInteractingVehicleId = p0 and p0:getID()
      else
        local p1 = getP2Vehicle() or getPlayerVehicle(1)
        lastInteractingVehicleId = p1 and p1:getID()
      end
      if isSplitModeActive() then
        setRouteTargetPlayer(otherIdx, true)
      end
      local ok, err = pcall(otherPrompt.buttonFun)
      interactingPlayer = nil
      playerPrompts[otherIdx] = nil
      if not ok then
        log("E", "careerSplitScreen", "Error during performInteract fallback: " .. tostring(err))
      end
      return true
    end
    return false
  end

  if playerPrompts[0] and playerPrompts[0].buttonFun then
    interactingPlayer = 0
    local p0 = getPlayerVehicle(0)
    lastInteractingVehicleId = p0 and p0:getID()
    if isSplitModeActive() then
      setRouteTargetPlayer(0, true)
    end
    local ok, err = pcall(playerPrompts[0].buttonFun)
    interactingPlayer = nil
    playerPrompts[0] = nil
    return true
  elseif playerPrompts[1] and playerPrompts[1].buttonFun then
    interactingPlayer = 1
    local p1 = getP2Vehicle() or getPlayerVehicle(1)
    lastInteractingVehicleId = p1 and p1:getID()
    if isSplitModeActive() then
      setRouteTargetPlayer(1, true)
    end
    local ok, err = pcall(playerPrompts[1].buttonFun)
    interactingPlayer = nil
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

local function formatCurrency(amount)
  if not amount or type(amount) ~= "number" then return "0.00" end
  local sign = amount < 0 and "-" or ""
  local absVal = math.abs(amount)
  local intPart = math.floor(absVal)
  local fracPart = math.floor((absVal - intPart) * 100 + 0.5)
  if fracPart >= 100 then
    intPart = intPart + 1
    fracPart = 0
  end
  local formattedInt = tostring(intPart)
  local k
  while true do
    formattedInt, k = string.gsub(formattedInt, "^(-?%d+)(%d%d%d)", '%1,%2')
    if k == 0 then break end
  end
  return string.format("%s%s.%02d", sign, formattedInt, fracPart)
end

local function getCareerMoney()
  local wallet = nil
  if overhaul_career_economy_playerAttributes and overhaul_career_economy_playerAttributes.getAttributeValue then
    wallet = overhaul_career_economy_playerAttributes.getAttributeValue("money")
  elseif career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
    wallet = career_modules_playerAttributes.getAttributeValue("money")
  end

  local bank = 0
  local hasBank = false
  if overhaul_career_economy_bank and overhaul_career_economy_bank.getAccounts then
    local ok, accs = pcall(overhaul_career_economy_bank.getAccounts)
    if ok and type(accs) == "table" and #accs > 0 then
      hasBank = true
      for _, acc in ipairs(accs) do
        if acc and acc.balance and type(acc.balance) == "number" then
          bank = bank + acc.balance
        end
      end
    end
  end

  return wallet, bank, hasBank
end

local lastRefreshTime = 0
local function refreshAllUI()
  local now = os.clock()
  if now - lastRefreshTime < 0.5 then return end
  lastRefreshTime = now

  log("I", "careerSplitScreen", "refreshAllUI: reloading multiseat UI, routes, and minimaps...")

  if isSplitModeActive() then
    if render_splitScreen and render_splitScreen.refreshLayout then
      render_splitScreen.refreshLayout()
    end
    if extensions.ui_menuManager and extensions.ui_menuManager.setGameplayRoute then
      extensions.ui_menuManager.setGameplayRoute("multiseat")
    end
    if extensions.ui_router and extensions.ui_router.reload then
      extensions.ui_router.reload("multiseat", nil, {force = true})
    end
    if ui_apps_minimap_minimap and ui_apps_minimap_minimap.enableSplitScreenMinimaps then
      ui_apps_minimap_minimap.enableSplitScreenMinimaps()
    end
    if ui_apps_minimap_minimap and ui_apps_minimap_minimap.onSplitScreenChanged then
      ui_apps_minimap_minimap.onSplitScreenChanged(true, 2, nil, "split")
    end
    if render_splitScreen and render_splitScreen.setCustomPlayers then
      render_splitScreen.setCustomPlayers({0, 1})
    end
  else
    if extensions.ui_menuManager and extensions.ui_menuManager.setGameplayRoute then
      extensions.ui_menuManager.setGameplayRoute("play")
    end
    if extensions.ui_router and extensions.ui_router.reload then
      extensions.ui_router.reload("play", nil, {force = true})
    end
  end

  guihooks.trigger("onUIReset")
  guihooks.trigger("appContainer:loadStreams")

  Engine.Audio.playOnce('AudioGui', 'event:>UI>Main>Click_Tonal_01')
  guihooks.trigger("toastrMsg", {
    type = "info",
    title = "UI Refreshed",
    msg = "Minimaps and multiseat HUD reloaded.",
    config = { timeOut = 2000 }
  })
end

local currencyTex = nil
local refreshTex = nil

local function getModIcon(filename)
  local im = ui_imgui
  local candidatePaths = {
    "/lua/ge/extensions/careerSplitScreen/icons/" .. filename,
    "/art/icons/" .. filename,
    "/ui/icons/" .. filename,
    "lua/ge/extensions/careerSplitScreen/icons/" .. filename,
    "art/icons/" .. filename,
    "ui/icons/" .. filename,
  }

  if im and im.ImTextureHandler then
    for _, path in ipairs(candidatePaths) do
      local ok, h = pcall(function()
        local handler = im.ImTextureHandler(path)
        if handler and handler.getID and handler:getID() then
          local sz = handler.getSize and handler:getSize()
          if sz and sz.x > 0 and sz.y > 0 then
            return handler
          end
        end
        return nil
      end)
      if ok and h then
        return { tex = h }
      end
    end
  end

  if ui_imguiUtils and ui_imguiUtils.texObj then
    for _, path in ipairs(candidatePaths) do
      local ok, res = pcall(ui_imguiUtils.texObj, path)
      if ok and res and res.tex and res.tex.getID and res.tex:getID() then
        local sz = res.tex.getSize and res.tex:getSize()
        if sz and sz.x > 0 and sz.y > 0 then
          return res
        end
      end
    end
  end

  return nil
end

local function drawCurrencyIconVector(drawList, im, minPos, size, col)
  local sx = size / 24
  local sy = size / 24
  local x = minPos.x
  local y = minPos.y
  drawList:AddRectFilled(im.ImVec2(x + 2 * sx, y + 10 * sy), im.ImVec2(x + 8 * sx, y + 12 * sy), col)
  drawList:AddRectFilled(im.ImVec2(x + 1 * sx, y + 14 * sy), im.ImVec2(x + 7 * sx, y + 16 * sy), col)
  drawList:AddRectFilled(im.ImVec2(x + 7.5 * sx, y + 4 * sy), im.ImVec2(x + 10.5 * sx, y + 20 * sy), col)
  drawList:AddRectFilled(im.ImVec2(x + 8 * sx, y + 4 * sy), im.ImVec2(x + 15 * sx, y + 6.5 * sy), col)
  drawList:AddRectFilled(im.ImVec2(x + 8 * sx, y + 11 * sy), im.ImVec2(x + 15.5 * sx, y + 13.5 * sy), col)
  drawList:AddRectFilled(im.ImVec2(x + 8 * sx, y + 17.5 * sy), im.ImVec2(x + 15 * sx, y + 20 * sy), col)
  drawList:AddRectFilled(im.ImVec2(x + 13.5 * sx, y + 5.5 * sy), im.ImVec2(x + 16 * sx, y + 12 * sy), col)
  drawList:AddRectFilled(im.ImVec2(x + 14 * sx, y + 12.5 * sy), im.ImVec2(x + 16.5 * sx, y + 19 * sy), col)
end

local function drawExitIconVector(drawList, im, cx, cy, radius, col)
  local r = radius or 4.5
  drawList:AddLine(im.ImVec2(cx - r, cy - r), im.ImVec2(cx + r, cy + r), col, 2.0)
  drawList:AddLine(im.ImVec2(cx - r, cy + r), im.ImVec2(cx + r, cy - r), col, 2.0)
end

local function drawRefreshIconVector(drawList, im, cx, cy, radius, col)
  local pi = math.pi
  drawList:PathClear()
  drawList:PathArcTo(im.ImVec2(cx, cy), radius, -0.8 * pi, -0.05 * pi, 12)
  drawList:PathStroke(col, 0, 2.0)
  local a1x = cx + radius * math.cos(-0.05 * pi)
  local a1y = cy + radius * math.sin(-0.05 * pi)
  drawList:AddTriangleFilled(
    im.ImVec2(a1x + 3, a1y - 3),
    im.ImVec2(a1x + 3, a1y + 3),
    im.ImVec2(a1x - 2, a1y),
    col
  )
  drawList:PathClear()
  drawList:PathArcTo(im.ImVec2(cx, cy), radius, 0.2 * pi, 0.95 * pi, 12)
  drawList:PathStroke(col, 0, 2.0)
  local a2x = cx + radius * math.cos(0.95 * pi)
  local a2y = cy + radius * math.sin(0.95 * pi)
  drawList:AddTriangleFilled(
    im.ImVec2(a2x - 3, a2y + 3),
    im.ImVec2(a2x - 3, a2y - 3),
    im.ImVec2(a2x + 2, a2y),
    col
  )
end

local moneyUpdateTimer = 0
local cachedWallet = nil
local cachedBank = 0
local cachedHasBank = false
local cachedCashStr = ""
local cachedBankStr = ""
local cachedCashSize = nil
local cachedBankSize = nil
local cachedMoneyW = 0

local function drawTopLeftMoneyAndRefresh()
  -- Strictly show ONLY when split-screen is actively running; hide when not started, during loading, menus, or single-player
  if not isSplitActive then return end
  if not isCareerModeActive() then return end

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

  if not currencyTex then
    currencyTex = getModIcon("beamCurrency.png")
  end
  if not refreshTex then
    refreshTex = getModIcon("refreshIcon.png")
  end

  local now = os.clock()
  if now - moneyUpdateTimer > 0.25 or cachedCashSize == nil then
    moneyUpdateTimer = now
    local careerActive = isCareerModeActive()
    if careerActive then
      cachedWallet, cachedBank, cachedHasBank = getCareerMoney()
      cachedWallet = cachedWallet or 0
    else
      cachedWallet, cachedBank, cachedHasBank = nil, 0, false
    end

    if cachedWallet ~= nil then
      cachedCashStr = formatCurrency(cachedWallet)
      cachedBankStr = (cachedHasBank and cachedBank ~= 0) and (" (Bank: " .. formatCurrency(cachedBank) .. ")") or ""
    else
      cachedCashStr = ""
      cachedBankStr = ""
    end

    cachedCashSize = (cachedCashStr ~= "") and im.CalcTextSize(cachedCashStr) or im.ImVec2(0, 0)
    cachedBankSize = (cachedBankStr ~= "") and im.CalcTextSize(cachedBankStr) or im.ImVec2(0, 0)
    cachedMoneyW = (cachedCashStr ~= "") and (cachedCashSize.x + cachedBankSize.x) or 0
  end

  local wallet = cachedWallet
  local bank = cachedBank
  local hasBank = cachedHasBank
  local hasMoney = (wallet ~= nil)
  local cashStr = cachedCashStr
  local bankStr = cachedBankStr
  local cashSize = cachedCashSize
  local bankSize = cachedBankSize

  local currencyIconSize = 18
  local iconGap = 6
  local btnSize = 24
  local boxH = 32
  local padX = 10

  local moneySectionW = 0
  if hasMoney then
    moneySectionW = currencyIconSize + iconGap + cashSize.x
    if bankStr ~= "" then
      moneySectionW = moneySectionW + bankSize.x
    end
  end

  local boxW
  if hasMoney then
    -- [padX] [icon] [gap] [cash] [bank?] [gap 8] [divider 1] [gap 8] [button] [padX]
    boxW = padX + moneySectionW + 8 + 1 + 8 + btnSize + padX
  else
    boxW = padX + btnSize + padX
  end

  -- Top Left position
  local posX = canvasPosX + 16
  local posY = canvasPosY + 12

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
    im.WindowFlags_NoCollapse
  )
  if im.WindowFlags_NoNav then
    flags = bit.bor(flags, im.WindowFlags_NoNav)
  end
  if im.WindowFlags_NoNavInputs then
    flags = bit.bor(flags, im.WindowFlags_NoNavInputs)
  end
  if im.WindowFlags_NoNavFocus then
    flags = bit.bor(flags, im.WindowFlags_NoNavFocus)
  end
  if im.WindowFlags_NoFocusOnAppearing then
    flags = bit.bor(flags, im.WindowFlags_NoFocusOnAppearing)
  end
  if im.WindowFlags_NoBringToFrontOnFocus then
    flags = bit.bor(flags, im.WindowFlags_NoBringToFrontOnFocus)
  end
  if im.WindowFlags_NoDocking then
    flags = bit.bor(flags, im.WindowFlags_NoDocking)
  end

  im.PushStyleVar2(im.StyleVar_WindowPadding, im.ImVec2(0, 0))
  im.PushStyleVar1(im.StyleVar_WindowRounding, 6)
  im.PushStyleVar1(im.StyleVar_WindowBorderSize, 1)
  im.PushStyleColor1(im.Col_WindowBg, im.GetColorU322(im.ImVec4(0.08, 0.09, 0.12, 0.88)))
  im.PushStyleColor1(im.Col_Border, im.GetColorU322(im.ImVec4(0.30, 0.34, 0.42, 0.75)))

  local winTitle = "###SDF_TopLeftMoneyRefresh"
  if im.Begin(winTitle, nil, flags) then
    local drawList = im.GetWindowDrawList()
    local winPos = im.GetWindowPos()
    local curX = padX

    if hasMoney then
      -- 1. BeamNG currency icon (stylized B with speed lines)
      local iconY = (boxH - currencyIconSize) * 0.5
      local iconMin = im.ImVec2(winPos.x + curX, winPos.y + iconY)
      local iconMax = im.ImVec2(iconMin.x + currencyIconSize, iconMin.y + currencyIconSize)
      local drawnCurrency = false
      if currencyTex and currencyTex.tex and currencyTex.tex.getID then
        local ok, texId = pcall(function() return currencyTex.tex:getID() end)
        if ok and texId then
          local okDraw = pcall(function()
            im.ImDrawList_AddImage(drawList, texId, iconMin, iconMax, im.ImVec2(0, 0), im.ImVec2(1, 1), im.GetColorU322(im.ImVec4(1, 1, 1, 1)))
          end)
          drawnCurrency = okDraw
        end
      end
      if not drawnCurrency then
        drawCurrencyIconVector(drawList, im, iconMin, currencyIconSize, im.GetColorU322(im.ImVec4(1, 1, 1, 1)))
      end
      curX = curX + currencyIconSize + iconGap

      -- 2. Cash text in bold crisp white (matching user reference image)
      local cashY = (boxH - cashSize.y) * 0.5
      im.SetCursorPos(im.ImVec2(curX, cashY))
      im.TextColored(im.ImVec4(0.96, 0.96, 0.98, 1.0), cashStr)
      if im.IsItemHovered() then
        local tip = string.format("Cash on Hand: %s", cashStr)
        if hasBank and bank ~= 0 then
          tip = tip .. string.format("\nBank Balance: %s\nTotal Wealth: %s", formatCurrency(bank), formatCurrency(wallet + bank))
        end
        im.SetTooltip(tip)
      end
      curX = curX + cashSize.x

      -- 3. Bank balance (if present and non-zero)
      if bankStr ~= "" then
        local bankY = (boxH - bankSize.y) * 0.5
        im.SetCursorPos(im.ImVec2(curX, bankY))
        im.TextColored(im.ImVec4(0.70, 0.75, 0.85, 0.85), bankStr)
        if im.IsItemHovered() then
          local tip = string.format("Bank Balance: %s\nCash on Hand: %s\nTotal Wealth: %s", formatCurrency(bank), cashStr, formatCurrency(wallet + bank))
          im.SetTooltip(tip)
        end
        curX = curX + bankSize.x
      end

      -- 4. Subtle vertical divider
      curX = curX + 8
      local sepMin = im.ImVec2(winPos.x + curX, winPos.y + 6)
      local sepMax = im.ImVec2(winPos.x + curX + 1, winPos.y + boxH - 6)
      drawList:AddLine(sepMin, sepMax, im.GetColorU322(im.ImVec4(0.35, 0.38, 0.44, 0.6)), 1.0)
      curX = curX + 8
    end

    -- 5. Square Hard Exit Split-Screen button
    local btnY = (boxH - btnSize) * 0.5
    im.SetCursorPos(im.ImVec2(curX, btnY))

    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(0, 0))
    im.PushStyleVar1(im.StyleVar_FrameRounding, 4)
    im.PushStyleColor1(im.Col_Button, im.GetColorU322(im.ImVec4(0.32, 0.12, 0.14, 0.85)))
    im.PushStyleColor1(im.Col_ButtonHovered, im.GetColorU322(im.ImVec4(0.85, 0.22, 0.22, 1.0)))
    im.PushStyleColor1(im.Col_ButtonActive, im.GetColorU322(im.ImVec4(0.55, 0.10, 0.10, 1.0)))

    local btnClicked = im.Button("###btn_hard_exit_splitscreen", im.ImVec2(btnSize, btnSize))
    local btnHovered = im.IsItemHovered()
    if btnHovered then
      im.SetTooltip("Exit Split-Screen (Return to Single-Player)")
    end

    local iconCol = btnHovered and im.GetColorU322(im.ImVec4(1.0, 1.0, 1.0, 1.0)) or im.GetColorU322(im.ImVec4(0.92, 0.90, 0.94, 0.92))
    drawExitIconVector(drawList, im, winPos.x + curX + btnSize * 0.5, winPos.y + btnY + btnSize * 0.5, 4.5, iconCol)

    im.PopStyleColor(3)
    im.PopStyleVar(2)

    if btnClicked then
      stopSplitScreen()
    end
  end
  im.End()

  im.PopStyleColor(2)
  im.PopStyleVar(3)
end


local function onPreRender(dt)
  evaluatePlayerInteractions(dt)
  local okPrompt, errPrompt = pcall(drawPlayerInteractPrompts)
  if not okPrompt then
    log("E", "careerSplitScreen", "Error in drawPlayerInteractPrompts: " .. tostring(errPrompt))
  end
  if isSplitActive then
    local ok, err = pcall(drawTopLeftMoneyAndRefresh)
    if not ok then
      log("E", "careerSplitScreen", "Error in drawTopLeftMoneyAndRefresh: " .. tostring(err))
    end
  end

  hookBigMapMode()
  if core_multiseat and (isSplitModeActive() or isCareerModeActive()) then
    if core_multiseat.isMultiseatActive() then
      hookCoreMultiseat()
      if core_multiseat.setMultiseatActive then
        core_multiseat.setMultiseatActive(false)
      end
    end
  end
    if (overhaul_vehicles_playerVehicles and not overhaul_vehicles_playerVehicles._careerSplitHooked)
    or (career_modules_delivery_general and (not career_modules_delivery_general._careerSplitContainersHooked or not career_modules_delivery_general._careerSplitActivityHooked))
    or (overhaul_career_logistics_general and (not overhaul_career_logistics_general._careerSplitContainersHooked or not overhaul_career_logistics_general._careerSplitActivityHooked))
    or (career_modules_delivery_parcelManager and not career_modules_delivery_parcelManager._careerSplitSameLocationHooked)
    or (overhaul_career_logistics_parcelManager and not overhaul_career_logistics_parcelManager._careerSplitSameLocationHooked) then
    hookCareerJobsAndLogistics()
  end

  if freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive() then
    if isSplitModeActive() then
      local okVeh, errVeh = pcall(updateBigMapVehicles)
      if not okVeh then
        log("E", "careerSplitScreen", "Error in updateBigMapVehicles: " .. tostring(errVeh))
      end

      local okSelector, errSelector = pcall(drawBigMapPlayerSelector)
      if not okSelector then
        log("E", "careerSplitScreen", "Error in drawBigMapPlayerSelector: " .. tostring(errSelector))
      end

      -- Check keyboard Tab to cycle player route target
      local im = ui_imgui
      if im and im.IsKeyPressed and im.GetKeyIndex and im.Key_Tab then
        if im.IsKeyPressed(im.GetKeyIndex(im.Key_Tab)) then
          toggleRouteTarget()
        end
      end

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

local function onExtensionLoaded(extName)
  ensureModExtensionsLoaded()
  ensureSinglePlayerInputState()
  patchReputationModule()
  setExtensionUnloadMode(M, "manual")
  hookBigMapMode()
  hookCareerJobsAndLogistics()
  log("I", "careerSplitScreen", "Career Split-Screen extension initialized.")
end

M.getRouteTargetPlayer = function() return getRouteTargetPlayer() end
M.setRouteTargetPlayer = function(pIdx) return setRouteTargetPlayer(pIdx) end
M.toggleRouteTarget = toggleRouteTarget
M.drawBigMapPlayerSelector = drawBigMapPlayerSelector
M.ensureSinglePlayerInputState = ensureSinglePlayerInputState
M.hasMultipleDevicesConnected = hasMultipleDevicesConnected
M.getConnectedDevicesSummary = getConnectedDevicesSummary
M.ensureModExtensionsLoaded = ensureModExtensionsLoaded
M.autoAssignDevices = autoAssignDevices
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
M.getCareerMoney = getCareerMoney
M.refreshAllUI = refreshAllUI
M.drawTopLeftMoneyAndRefresh = drawTopLeftMoneyAndRefresh
M.patchReputationModule = patchReputationModule
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
