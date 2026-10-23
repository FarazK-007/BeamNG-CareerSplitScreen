-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"core_vehicleBridge"}
local moduleVersion = 42
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehicleTasks, dTasklist, dParcelMods, dVehOfferManager, dTutorial
local step
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dVehicleTasks = career_modules_delivery_vehicleTasks
  dTasklist = career_modules_delivery_tasklist
  dParcelMods = career_modules_delivery_parcelMods
  dVehOfferManager = career_modules_delivery_vehicleOfferManager
  dTutorial = career_modules_delivery_tutorial
  step = util_stepHandler
end

local deliveryGameTime = 0
local deliveryGameTimePaused = false

local deliveryModeActive = false
local deliveryAbandonPenaltyFactor = 0.1
M.getDeliveryAbandonPenaltyFactor = function() return deliveryAbandonPenaltyFactor end



-- Career general systems interaction (save/load, level setup)

local saveFile = "logisticsDatabase.json"
local loadData = {}
local function loadSaveData()
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot then return end

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local outdated = not saveInfo or saveInfo.version < moduleVersion

  local data = (not outdated and savePath and jsonReadFile(savePath .. "/career/"..saveFile)) or {}

  loadData = data
  dProgress.setProgress(loadData.progress)
  dParcelMods.setProgress(loadData.parcelModProgress)
  loadData.facilities = loadData.facilities or {}
  loadData.settings = data.settings or {}

  if loadData.settings.automaticRoute == nil then
    loadData.settings.automaticRoute = true
  end

  deliveryGameTime = loadData.general and loadData.general.gameTime or deliveryGameTime
  if loadData.general and loadData.general.osTime then
    log("I","",string.format("Save data age: %ds",os.time() - loadData.general.osTime))
    -- delete save data if the save is older than an hour
    if os.time() - loadData.general.osTime > 3600 then
      log("I","",string.format("Save data is older than 3600s (%d), wiping cargo and facility timers",os.time() - loadData.general.osTime))
      loadData.cargo = {}
      for key, fac in pairs(loadData.facilities) do
        fac.logisticGenerators = nil
      end
    end
  end

  --log("I","",string.format("Loaded save data for logistics: %d cargo", #loadData.cargo))
end
M.loadSaveData = loadSaveData
local function saveableCargoFilter(cargo)
  return cargo.offerExpiresAt > M.time() and cargo.location.type == "facilityParkingspot" and cargo.generatorLabel ~= "addMaterialAsParcelToContainer"
end
local function onSaveCurrentProfile(currentSavePath)
  local filePath = currentSavePath .. "/career/" .. saveFile
  local saveData = {
    general = {},
    penalty = M.getDeliveryModePenalty(),
    parcels = {},
    vehicleOffers = {},
    facilities = {},
    settings = loadData.settings or {}
  }

  -- general data
  saveData.general.gameTime = M.time()
  saveData.general.osTime = os.time()
  saveData.progress = dProgress.getProgress()
  saveData.parcelModProgress = dParcelMods.getProgress()

  -- facility data

  -- parcels
  local saveableCargo = dParcelManager.getAllCargoCustomFilter(saveableCargoFilter)
  local maxGroupId = 0
  local groupMap = {}
  for _, cargo in ipairs(saveableCargo) do
    local elem = {
      rewards = cargo.rewards,
      templateId = cargo.templateId,
      name = cargo.name,
      type = cargo.type,
      slots = cargo.slots,
      offerExpiresAt = cargo.offerExpiresAt,
      location = cargo.location,
      origin = cargo.origin,
      destination = cargo.destination,
      data = cargo.data,
      generatorLabel = cargo.generatorLabel,
      modifiers = cargo.modifiers,
      generatedAtTimestamp = cargo.generatedAtTimestamp,
      weight = cargo.weight,
      density = cargo.density,
      groupSeed = cargo.groupSeed,
      automaticDropOff = cargo.automaticDropOff,
      organization = cargo.organization,
      materialType = cargo.materialType,
    }
    if not groupMap[cargo.groupId] then
      maxGroupId = maxGroupId + 1
      groupMap[cargo.groupId] = maxGroupId
    end
    elem.groupId = groupMap[cargo.groupId]
    table.insert(saveData.parcels, elem)
  end
  saveData.general.maxGroupId = maxGroupId

  local saveableVehicleOffers = dVehOfferManager.getAllOfferUnexpired()
  for _, offer in ipairs(saveableVehicleOffers) do
    -- vehicle offers dont need to be trunkated/cut before saving
    table.insert(saveData.vehicleOffers, offer)
  end

  -- facility data
  for _, facility in ipairs(dGenerator.getFacilities()) do
    local elem = {
      logisticGenerators = {},
      progress = facility.progress,
      materialStorages = facility.materialStorages,
    }
    for i, generator in ipairs(facility.logisticGenerators or {}) do
      elem.logisticGenerators[i] = {
        nextGenerationTimestamp = generator.nextGenerationTimestamp
      }
    end
    saveData.facilities[facility.id] = elem
  end

  -- save the data to file
  career_saveSystem.jsonWriteFileSafe(filePath, saveData, true)
end
M.onSaveCurrentProfile = onSaveCurrentProfile

local function onCareerActive(active)
  if not active then return end
  loadSaveData()
  map.assureLoad()
  dGenerator.setup(loadData)
end
M.onCareerActive = onCareerActive


local fast = 1
M.time = function() return deliveryGameTime end



-- vehicle management

local function getVehicleName(vehId)
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  local niceVehicleName = inventoryId and career_modules_inventory.getVehicleNiceNameTranslated(inventoryId)
  return niceVehicleName and niceVehicleName or core_locales.contextTranslate("ui.career.delivery.general.vehicleFallback", {id = vehId})
end
M.getVehicleName = getVehicleName


local mostRecentCargoContainerData = {}
local nearbyRadius = 25*25
local sortByVehIdAndContainerId = function(a,b) if a.vehId == b.vehId then return a.containerId < b.containerId else return a.vehId < b.vehId end end
local function isPassengerOnly(cargoTypes)
  if not cargoTypes then return false end
  local hasPassenger = false
  for _, cargoType in ipairs(cargoTypes) do
    if cargoType ~= "passenger" then return false end
    hasPassenger = true
  end
  return hasPassenger
end

local function isSplitModeActive()
  return (careerSplitScreen and careerSplitScreen.isSplitModeActive and careerSplitScreen.isSplitModeActive())
    or (careerSplitScreen and careerSplitScreen.isActive and careerSplitScreen.isActive())
    or (render_splitScreen and render_splitScreen.isEnabled and render_splitScreen.isEnabled())
    or (core_multiseat and core_multiseat.isMultiseatActive and core_multiseat.isMultiseatActive())
    or (getPlayerVehicle(1) ~= nil and getPlayerVehicle(1) ~= getPlayerVehicle(0))
end

local function getNearbyVehicleCargoContainers(callback)
  if not core_vehicleBridge then return {} end
  callback = callback or nop
  local vehCargoData = {}

  local p0Veh = getPlayerVehicle(0)
  local p0Pos = p0Veh and p0Veh:getPosition() or (core_camera and core_camera.getPosition())

  local p1Veh = (careerSplitScreen and careerSplitScreen.getP2Vehicle and careerSplitScreen.getP2Vehicle()) or getPlayerVehicle(1)
  local p1Pos = p1Veh and p1Veh:getPosition()

  -- Gather candidate vehicles: ONLY player vehicles and player inventory vehicles
  -- NEVER include AI/traffic vehicles which do not load cargo extensions and stall the bridge
  local candidateVehs = {}
  if p0Veh and p0Veh.getJBeamFilename and p0Veh:getJBeamFilename() ~= "unicycle" then
    candidateVehs[p0Veh:getID()] = p0Veh
  end
  if p1Veh and p1Veh.getJBeamFilename and p1Veh:getJBeamFilename() ~= "unicycle" then
    candidateVehs[p1Veh:getID()] = p1Veh
  end
  if career_modules_inventory and career_modules_inventory.getVehicles then
    local ok, inv = pcall(career_modules_inventory.getVehicles)
    if ok and type(inv) == "table" then
      for invId, _ in pairs(inv) do
        local gameVehId = career_modules_inventory.getVehicleIdFromInventoryId(invId)
        if gameVehId then
          local vehObj = scenetree.findObjectById(gameVehId)
          if vehObj and vehObj.getJBeamFilename and vehObj:getJBeamFilename() ~= "unicycle" then
            candidateVehs[gameVehId] = vehObj
          end
        end
      end
    end
  end

  local vehs = {}
  local refNodeClusterIdByVehId = {}
  for vehId, veh in pairs(candidateVehs) do
    local vPos = veh:getPosition()
    local isNear = (p0Pos and (p0Pos - vPos):squaredLength() < nearbyRadius)
      or (p1Pos and (p1Pos - vPos):squaredLength() < nearbyRadius)
    if isNear then
      vehCargoData[vehId] = -1
      vehs[vehId] = veh
      refNodeClusterIdByVehId[vehId] = veh:getNodeClusterId(veh:getRefNodeId())
    end
  end

  if not next(vehs) then
    mostRecentCargoContainerData = {}
    callback({})
    return
  end
  for vehId, veh in pairs(vehs) do

    core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
      vehCargoData[vehId] = {}

      local deliveryContainers = {}
      for _, container in ipairs(vehCargoContainerData[1]) do
        if not isPassengerOnly(container.cargoTypes) then
          table.insert(deliveryContainers, container)
        end
      end

      for _, container in ipairs(deliveryContainers) do
        local vehName = getVehicleName(vehId)
        local elem = {
          vehId = vehId,
          containerId = container.id,
          location = {type = "vehicle", vehId = veh:getID(), containerId = container.id},
          vehName = vehName,
          name = container.name,
          moveToLabel = vehName .. " " .. container.name,
          cargoTypesLookup = tableValuesAsLookupDict(container.cargoTypes),
          cargoTypesString = table.concat(container.cargoTypes,", "),
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
          local dist = (elem.position-veh:getPosition()):length()
          if dist < 10 then
            elem.attachmentStatus = "nearby"
          else
            elem.attachmentStatus = "lost"
          end
        end
        elem.rawCargo = dParcelManager.getAllCargoForLocation(elem.location)

        elem.transientCargo = dParcelManager.getTransientMovesForTargetLocationWithCargo(elem.location)


        --for key, amount in pairs(elem.totalCargoSlots) do
        --  elem.usedCargoSlots[key] = 0
        --end
        for _, cargo in ipairs(elem.rawCargo) do
          elem.usedCargoSlots = elem.usedCargoSlots + cargo.slots
          elem.freeCargoSlots = elem.freeCargoSlots - cargo.slots
        end

        for _, cargo in ipairs(elem.transientCargo) do
          elem.usedCargoSlots = elem.usedCargoSlots + cargo.slots
          elem.transientCargoSlots = elem.transientCargoSlots + cargo.slots
          elem.freeCargoSlots = elem.freeCargoSlots - cargo.slots
        end

        table.insert(vehCargoData[vehId], elem)
      end

      -- check if all cargo was sent
      for key, val in pairs(vehCargoData) do
        if val == -1 then return end
      end

      -- if we're still here, call the function callback to send data back
      local ret = {}
      for _, list in pairs(vehCargoData) do
        for _, elem in ipairs(list) do
          table.insert(ret, elem)
        end
      end
      table.sort(ret, sortByVehIdAndContainerId)
      mostRecentCargoContainerData = ret
      callback(ret)

    end, "getCargoContainers")
  end
  if not next(vehs) then
    callback({})
  end

end
M.getNearbyVehicleCargoContainers = getNearbyVehicleCargoContainers
M.getMostRecentCargoContainerData = function() return mostRecentCargoContainerData end


local function defaultDelayCallback(data)
  local maxDelay = 0
  for _, delay in pairs(data) do
    maxDelay = math.max(delay, maxDelay)
  end
  if maxDelay > 0 then
    maxDelay = math.max(maxDelay, 1)
    -- make
    local sequence = {
      step.makeStepWait(maxDelay+0.5),
      step.makeStepReturnTrueFunction(function()
        for vehId, data in pairs(data) do
          local veh = scenetree.findObjectById(vehId)
          core_vehicleBridge.executeAction(veh, 'setFreeze', false)
        end
        gameplay_markerInteraction.setForceReevaluateOpenPrompt()
      return true
      end
      )
    }
    step.startStepSequence(sequence, callback)
    -- add loading progress bar
    guihooks.trigger("OpenSimpleDelayPopup",{timer=maxDelay, heading=_tr("ui.career.delivery.general.loadingCargo")})
  else
    -- 1s delay, no freeze
    for vehId, data in pairs(data) do
      local veh = scenetree.findObjectById(vehId)
      core_vehicleBridge.executeAction(veh, 'setFreeze', false)
    end
    gameplay_markerInteraction.setForceReevaluateOpenPrompt()
  end
  log("I","",string.format("%0.2fs delay after adjusting weights for cargo.", maxDelay))
end

local updateWeightsScheduled = false
M.requestUpdateContainerWeights = function() updateWeightsScheduled = true end
local function updateContainerWeights(delayCallback)
  if not updateWeightsScheduled then
    return
  end
  delayCallback = delayCallback or defaultDelayCallback
  updateWeightsScheduled = false
  log("I","","updateContainerWeights...")
  local updatePerVehicle = {}
  local p0Veh = getPlayerVehicle(0)
  if p0Veh and p0Veh.getJBeamFilename and p0Veh:getJBeamFilename() ~= "unicycle" then
    updatePerVehicle[p0Veh:getID()] = {}
  end
  local p1Veh = (careerSplitScreen and careerSplitScreen.getP2Vehicle and careerSplitScreen.getP2Vehicle()) or getPlayerVehicle(1)
  if p1Veh and p1Veh.getJBeamFilename and p1Veh:getJBeamFilename() ~= "unicycle" then
    updatePerVehicle[p1Veh:getID()] = {}
  end
  if career_modules_inventory and career_modules_inventory.getVehicles then
    local ok, inv = pcall(career_modules_inventory.getVehicles)
    if ok and type(inv) == "table" then
      for invId, _ in pairs(inv) do
        local gameVehId = career_modules_inventory.getVehicleIdFromInventoryId(invId)
        if gameVehId then
          local vehObj = scenetree.findObjectById(gameVehId)
          if vehObj and vehObj.getJBeamFilename and vehObj:getJBeamFilename() ~= "unicycle" then
            updatePerVehicle[gameVehId] = {}
          end
        end
      end
    end
  end
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
    updatePerVehicle[cargo.location.vehId][cargo.location.containerId] = updatePerVehicle[cargo.location.vehId][cargo.location.containerId] or {
      volume = 0,
      density = 1,
      containerId = cargo.location.containerId
    }
    if not cargo.weight then log("W","","No weight on cargo? " .. dumps(cargo.name)) dump(cargo) end

    if cargo.type == "parcel" then
      -- add up load/weight
      updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume = updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume + (cargo.weight or 0)
    end

    if cargo.type == "fluid" or cargo.type == "dryBulk" then
      -- add up volume
      updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume = updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume + (cargo.slots or 0)
      -- only keep one density, since all cargo in one container have the same density
      updatePerVehicle[cargo.location.vehId][cargo.location.containerId].density = (cargo.density or 1)
    end

  end
  --if next(updatePerVehicle) then
  for vehId, data in pairs(updatePerVehicle) do
    local veh = scenetree.findObjectById(vehId)

    core_vehicleBridge.executeAction(veh, "setCargoContainers", updatePerVehicle[vehId] or {}, "updateDelivery")
    core_vehicleBridge.executeAction(veh, 'setFreeze', true)

    for _, con in pairs(updatePerVehicle[vehId]) do
      log("I","",string.format("Container %d => volume %0.1f | density: %0.1f",con.containerId, con.volume or 0, con.density or 1))
    end
  end

  -- check loading delay
  local delayData = {}
  for vehId, data in pairs(updatePerVehicle) do
    delayData[vehId] = -1
  end

  local completed = false
  local function tryFinish()
    if completed then return end
    for _, val in pairs(delayData) do
      if val == -1 then return end
    end
    completed = true
    delayCallback(delayData)
  end

  for vehId, data in pairs(updatePerVehicle) do
    local veh = scenetree.findObjectById(vehId)
    if veh then
      core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
        local maxForContainer = 0
        if vehCargoContainerData and vehCargoContainerData[1] then
          for _, container in ipairs(vehCargoContainerData[1]) do
            if not isPassengerOnly(container.cargoTypes) then
              maxForContainer = math.max(maxForContainer, container.reachTargetTimeRemaining or 0)
            end
          end
        end
        delayData[vehId] = maxForContainer
        tryFinish()
      end, "getCargoContainers")
    else
      delayData[vehId] = 0
      tryFinish()
    end
  end
  if not next(updatePerVehicle) then
    completed = true
    delayCallback(delayData)
  end

end
M.updateContainerWeights = updateContainerWeights


local colorForAttachmentDebug = {
  attached = ColorF(0.2,1,0.2, 0.75),
  nearby = ColorF(1,1,0.2, 0.75),
  lost = ColorF(1,0.2,0.2, 0.75),
}
local tickTimer = 0
M.setDeliveryTimePaused = function(paused) deliveryGameTimePaused = paused end
M.onUpdate = function(dtReal, dtSim, dtRaw)
  profilerPushEvent("Delivery DeliveryManager")
  -- update game time
  --if freeroam_bigMapMode.bigMapActive() and not freeroam_bigMapMode.isTransitionActive() and not deliveryGameTimePaused then
    --deliveryGameTime = deliveryGameTime + dtReal * fast
  --else
  --end
  if not deliveryGameTimePaused then
    deliveryGameTime = deliveryGameTime + dtSim * fast
  end

  -- handle penalty from previous save
  if loadData.penalty and next(loadData.penalty) then
    local anyValue = false
    for key, value in pairs(loadData.penalty) do
      if value ~= 0 then
        anyValue = true
      end
    end
    if anyValue then
      guihooks.trigger("toastrMsg", {type="warning", title=_tr("ui.career.delivery.general.cargoAbandonedTitle"), msg=core_locales.contextTranslate("ui.career.delivery.general.cargoAbandonedFromSave", {penalty = string.format("%0.2f", -loadData.penalty.money or 0)})})
      career_modules_playerAttributes.addAttributes(loadData.penalty, {tags={"gameplay", "delivery","fine"}, label="ui.career.delivery.general.penaltyAbandonLabel"})
    end
    loadData.penalty = nil
  end

  tickTimer = tickTimer + dtSim
  if tickTimer > 1 then
    M.getNearbyVehicleCargoContainers(nop)
    tickTimer = tickTimer - 1
  end

  -- check if container weights need to be updated, only if unpauses
  if dtSim > 10e-10 then
    M.updateContainerWeights()
  end

  -- debug display for cargo boxes
  --[[
  if deliveryModeActive then
    for _, container in ipairs(mostRecentCargoContainerData) do
      simpleDebugText3d(container.name, container.position, 0.15, colorForAttachmentDebug[container.attachmentStatus])
    end
  end
  ]]

  profilerPopEvent("Delivery DeliveryManager")
end


local function addInteractivePoi(list, id, field, elem)
  if not list[id] then list[id] = {dropOffs = {}, pickUps = {}, vehicles = {}} end
  table.insert(list[id][field], elem)
end
local function getInteractivePois()
  local interactiveParkingSpots = {}
  local targetFacilityIds = {}
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
    if cargo.destination.type == "facilityParkingspot" then
      addInteractivePoi(interactiveParkingSpots, cargo.destination.psPath, "dropOffs", cargo)
      if cargo.destination.facId then
        targetFacilityIds[cargo.destination.facId] = true
      end
    elseif cargo.destination.type == "multi" then
      for _, dest in ipairs(cargo.destination.destinations) do
        addInteractivePoi(interactiveParkingSpots, dest.psPath, "dropOffs", cargo)
      end
    end
  end

  for _, cargo in ipairs(dParcelManager.getTransientMoveCargo()) do
    local locPsPath = cargo.location.psPath
    addInteractivePoi(interactiveParkingSpots, locPsPath, "pickUps", cargo)
  end

  -- figure out which facilities need to be active in order to drop of vehicles.
  local trailerTargetDestinations = dVehicleTasks.getTargetDestinationsForActiveTasks()
  for _, destination in ipairs(trailerTargetDestinations) do
    targetFacilityIds[destination.facId] = true
    addInteractivePoi(interactiveParkingSpots, destination.psPath, "vehicles", "vehicle")
  end

  return interactiveParkingSpots, targetFacilityIds
end
-- poi list stuff
local function onGetRawPoiListForLevel(levelIdentifier, elements)

  --local nearbyVehicles = M.getNearbyVehicleCargoContainers()
  local interactiveParkingSpots, targetFacilityIds = getInteractivePois()
  local isCargoDeliveryTutorialActive = dTutorial.isCargoDeliveryTutorialActive()

  for _, fac in ipairs(freeroam_facilities.getFacilitiesByType("deliveryProvider")) do
    -- only process facilities if the facility is visible
    local includeFac = dProgress.isFacilityVisible(fac.id, isCargoDeliveryTutorialActive) or targetFacilityIds[fac.id]

    if includeFac then
      local totalCargoCount = 0
      local lastPsPos = nil

      -- look up all relevant parking spots for this facility
      local spotsForThisFacLookup = {}

      for name, ap in pairs(fac.accessPointsByName) do
        local ps = ap.ps
        local id = string.format("delivery-parking-%s-%s", fac.id, ps:getPath())
        local loc = {type = "facilityParkingspot", facId = fac.id, psPath = ps:getPath()}
        local cargoCount = #dParcelManager.getAllCargoForLocationUnexpiredUndelivered(loc)
        totalCargoCount = totalCargoCount + cargoCount
        lastPsPos = ps.pos
        local icon = "poi_pickup_round"
        if interactiveParkingSpots[ps:getPath()] then
          icon = "poi_dropoff_round"
        end

        local focus = interactiveParkingSpots[ps:getPath()] ~= nil
        local elem = {
          id = id,
          data = {type = "logisticsParking", facId = fac.id, psPath = ps:getPath(), canInspectCargo = ap.isInspectSpot, hasPlayerCargo = interactiveParkingSpots[ps:getPath()] and true or false },
          markerInfo = {
            -- only include parking marker if there is an action
            parkingMarker = cargoCount and {path = ps:getPath(), pos = ps.pos, rot = ps.rot, scl = ps.scl, icon = icon, focus = focus} or nil,
          }
        }
        --print(string.format("including: %s-%s (%s). visible: %s, target: %s",
        --  fac.id, ps.id,
        --  dParcelManager.getLocationLabelShort({type="facilityParkingspot", facId = fac.id, psPath = ps:getPath()}),
        --  dumps(dProgress.isFacilityVisible(fac.id)),
        --  dumps(targetFacilityIds[fac.id] and true or false)
        --  ))
        if dCargoScreen.isCargoScreenOpen() then
          elem.markerInfo.bigmapMarker = {pos = ps.pos, name = _tr("ui.career.delivery.general.pickupPrefix") .. _tr(fac.name), icon = icon}
        else
          if interactiveParkingSpots[ps:getPath()] then

            local tasks = {}
            if next(interactiveParkingSpots[ps:getPath()].dropOffs) then
              table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.deliverCargoItemsHere", {count = #interactiveParkingSpots[ps:getPath()].dropOffs}))
            end
            if next(interactiveParkingSpots[ps:getPath()].pickUps) then
              table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.pickUpCargoItemsHere", {count = #interactiveParkingSpots[ps:getPath()].pickUps}))
            end
            if next(interactiveParkingSpots[ps:getPath()].vehicles) then
              table.insert(tasks, core_locales.contextTranslate("ui.career.delivery.general.deliverVehiclesHere", {count = #interactiveParkingSpots[ps:getPath()].vehicles}))
            end

            local desc = table.concat(tasks, '<br/>')
            elem.markerInfo.bigmapMarker = {
              pos = ps.pos,
              name = dParcelManager.getLocationLabelShort(loc),
              description = desc,
              icon = "poi_dropoff_round",
              previews = {fac.preview},
              thumbnail = fac.preview,
            }
          end
        end
        if interactiveParkingSpots[ps:getPath()] or ap.isInspectSpot or dCargoScreen.isCargoScreenOpen() then
          --dump(string.format("%s -> %s", fac.name, name))
          --dumpz(ap, 1)
          table.insert(elements, elem)
        end
      end
      --[[
      -- add trailer spots in a separate entry.
      if dCargoScreen.isCargoScreenOpen() then
        for _, ps in ipairs(fac.trailerSpots) do

          local id = string.format("delivery-parking-%s-%s", fac.id, ps:getPath())
          local loc = {type = "facilityParkingspot", facId = fac.id, psPath = ps:getPath()}

          local icon = "poi_pickup_round"
          if interactiveParkingSpots[ps:getPath()] then
            icon = "poi_dropoff_round"
          end

          local elem = {
            id = id,
            data = {type = "logisticsParking", facId = fac.id, psPath = ps:getPath(), hasPlayerCargo = interactiveParkingSpots[ps:getPath()] and true or false },
            markerInfo = {
              bigmapMarker = {pos = ps.pos, name = "Pickup "..fac.name, icon = icon}
            }
          }
          table.insert(elements, elem)

        end

     end
]]
      -- one POI for the whole facility to display on bigmap under labourer branch.
      if not dCargoScreen.isCargoScreenOpen() then
        if dProgress.isFacilityUnlocked(fac.id) and next(fac.logisticTypesProvided) then
          local id = string.format("logisticsFacility-%s", fac.id)
          local elems = {}
          if fac.doors and next(fac.doors) then
            freeroam_facilities.walkingMarkerFormatFacility(fac, elems)
          end

          local pos = lastPsPos
          for name, ap in pairs(fac.accessPointsByName) do
            if ap.isInspectSpot then
              pos = ap.ps.pos
            end
          end

          local elem = {
            id = id,
            data = {type = "logisticsOffice", facId = fac.id},
            markerInfo = {
              walkingMarker = next(elems) and elems[1].markerInfo.walkingMarker or nil,
              bigmapMarker = {pos = pos, name = _tr(fac.name), description = core_locales.contextTranslate(totalCargoCount ~= 1 and "ui.career.delivery.general.facilityItemsAvailablePlural" or "ui.career.delivery.general.facilityItemsAvailableSingular", {description = _tr(fac.description), count = totalCargoCount}), icon="poi_delivery_round", previews = {fac.preview}, thumbnail = fac.preview,} or nil
            }
          }
          table.insert(elements, elem)
        end
      end
    end
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel



local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData) do
    if elem.type == "logisticsOffice" then
      local data = {
        icon = "poi_delivery_round",
        heading = dGenerator.getFacilityById(elem.facId).name,
        preheadings = {_tr("ui.career.delivery.general.logisticsOffice")},
        sorting = {
          type = elem.type,
          id = elem.id
        },
        props = {{
          icon = "checkmark",
          keyLabel = _tr("ui.career.delivery.general.cargoOverview")
        },{
          icon = "checkmark",
          keyLabel = _tr("ui.career.delivery.general.noCargoPickup")
        }},
        buttonLabel = _tr("ui.career.delivery.general.inspectCargo"),
        buttonFun = function() dCargoScreen.enterCargoOverviewScreen(elem.facId) end
      }
      table.insert(activityData, data)
    elseif elem.type == "logisticsParking" then

      -- cargo menu button
      local loc = {type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath}
      local poiTemplate = {
        icon = "poi_pickup_round",
        preheadings =  {dParcelManager.getLocationLabelShort({type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath})},
        props = {},
        sorting = {
          type = elem.type,
          id = elem.id
        },
      }

      -- dropoff data and props
      local psPos = dGenerator.getParkingSpotByPath(elem.psPath).pos
      local dropOffableCargoByCargoType = {
        parcel = 0,
        fluid = 0,
        dryBulk = 0
      }
      for _, container in ipairs(mostRecentCargoContainerData) do
        for _, cargo in ipairs(container.rawCargo) do
          local add = 1
          local type = cargo.type
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.destination.type == "facilityParkingspot" then
            dropOffableCargoByCargoType[cargo.type]  = dropOffableCargoByCargoType[type] + ((cargo.destination.psPath == elem.psPath and (container.position - psPos):squaredLength() < 25*25) and add or 0)
          elseif cargo.destination.type == "multi" then
            for _, dest in ipairs(cargo.destination.destinations) do
              dropOffableCargoByCargoType[type]  = dropOffableCargoByCargoType[type] + ((dest.psPath == elem.psPath and (container.position - psPos):squaredLength() < 25*25) and add or 0)
            end
          end
        end
      end

      -- Split-screen safety: fallback check directly in dParcelManager if mostRecentCargoContainerData was not refreshed yet
      if dropOffableCargoByCargoType.parcel == 0 and dParcelManager and dParcelManager.getAllCargoInVehicles then
        for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
          if cargo.location and cargo.location.type == "vehicle" and cargo.location.vehId then
            local cv = scenetree.findObjectById(cargo.location.vehId)
            if cv and (cv:getPosition() - psPos):squaredLength() < 25 * 25 then
              local matches = false
              if cargo.destination and cargo.destination.type == "facilityParkingspot" and cargo.destination.psPath == elem.psPath then
                matches = true
              elseif cargo.destination and cargo.destination.type == "multi" and cargo.destination.destinations then
                for _, dest in ipairs(cargo.destination.destinations) do
                  if dest.psPath == elem.psPath then matches = true; break end
                end
              end
              if matches then
                local t = cargo.type or "parcel"
                dropOffableCargoByCargoType[t] = (dropOffableCargoByCargoType[t] or 0) + (cargo.slots or 1)
              end
            end
          end
        end
      end

      local vehsClose, trailersClose = dVehicleTasks.canDropOffCargoAtPsPath(elem.psPath)
      local anyCargoDropOffable = (dropOffableCargoByCargoType.parcel > 0 or dropOffableCargoByCargoType.fluid > 0 or dropOffableCargoByCargoType.dryBulk > 0) or vehsClose > 0 or trailersClose > 0
      -- dropoff props
      if dropOffableCargoByCargoType.parcel > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = dropOffableCargoByCargoType.parcel > 1
            and core_locales.contextTranslate("ui.career.delivery.general.parcelsDropoff", {count = dropOffableCargoByCargoType.parcel})
            or _tr("ui.career.delivery.general.parcelDropoff")
        })
      end
      if dropOffableCargoByCargoType.fluid > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.fluidDropoff", {volume = dropOffableCargoByCargoType.fluid})
        })
      end
      if dropOffableCargoByCargoType.dryBulk > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.dryBulkDropoff", {volume = dropOffableCargoByCargoType.dryBulk})
        })
      end
      if vehsClose > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = _tr("ui.career.delivery.general.vehicleDropoff")
        })
      end
      if trailersClose > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = _tr("ui.career.delivery.general.trailerDropoff")
        })
      end


      -- pickup data and props
      local pickUpAbleCargoByCargoType = {
        parcel = 0,
        fluid = 0,
        dryBulk = 0
      }
      for _, container in ipairs(mostRecentCargoContainerData) do
        for _, cargo in ipairs(container.transientCargo) do
          local add = 1
          local type = cargo.type
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.location.type == "facilityParkingspot" then
            pickUpAbleCargoByCargoType[cargo.type]  = pickUpAbleCargoByCargoType[type] + ((cargo.location.psPath == elem.psPath and (container.position - psPos):squaredLength() < 25*25) and add or 0)
          end
        end
      end

      -- Split-screen safety: fallback check directly in dParcelManager for pickup
      if pickUpAbleCargoByCargoType.parcel == 0 and dParcelManager and dParcelManager.getTransientMoveCargo then
        for _, cargo in ipairs(dParcelManager.getTransientMoveCargo()) do
          if cargo.location and cargo.location.type == "facilityParkingspot" and cargo.location.psPath == elem.psPath then
            local t = cargo.type or "parcel"
            pickUpAbleCargoByCargoType[t] = (pickUpAbleCargoByCargoType[t] or 0) + (cargo.slots or 1)
          end
        end
      end

      local anyCargoPickUpAble = (pickUpAbleCargoByCargoType.parcel > 0 or pickUpAbleCargoByCargoType.fluid > 0 or pickUpAbleCargoByCargoType.dryBulk > 0)
      if pickUpAbleCargoByCargoType.parcel > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = pickUpAbleCargoByCargoType.parcel > 1
            and core_locales.contextTranslate("ui.career.delivery.general.parcelsPickup", {count = pickUpAbleCargoByCargoType.parcel})
            or _tr("ui.career.delivery.general.parcelPickup")
        })
      end
      if pickUpAbleCargoByCargoType.fluid > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.fluidPickup", {volume = pickUpAbleCargoByCargoType.fluid})
        })
      end
      if pickUpAbleCargoByCargoType.dryBulk > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = core_locales.contextTranslate("ui.career.delivery.general.dryBulkPickup", {volume = pickUpAbleCargoByCargoType.dryBulk})
        })
      end


      if elem.canInspectCargo then
        -- available cargo data and props
        local availableCargoCountByCargoType = {
          parcel = 0,
          fluid = 0,
          dryBulk = 0,
        }
        for _, cargo in ipairs(dParcelManager.getAllCargoForFacilityUnexpiredUndelivered(elem.facId)) do
          local add = 1
          local type = cargo.type
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          availableCargoCountByCargoType[type] = availableCargoCountByCargoType[type] + add
        end
        -- add storages
        local fac = dGenerator.getFacilityById(elem.facId)
        for materialType, storage in pairs(fac.materialStorages) do
          if storage.isProvider then
            local type = dGenerator.getMaterialsTemplatesById(materialType).type
            availableCargoCountByCargoType[type] = availableCargoCountByCargoType[type] + storage.storedVolume
          end
        end

        if availableCargoCountByCargoType.parcel > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate(availableCargoCountByCargoType.parcel ~= 1 and "ui.career.delivery.general.parcelsAvailable" or "ui.career.delivery.general.parcelAvailable", {count = availableCargoCountByCargoType.parcel})
          })
        end
        if availableCargoCountByCargoType.fluid > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate("ui.career.delivery.general.fluidAvailable", {volume = availableCargoCountByCargoType.fluid})
          })
        end
        if availableCargoCountByCargoType.dryBulk > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate("ui.career.delivery.general.dryBulkAvailable", {volume = availableCargoCountByCargoType.dryBulk})
          })
        end
        -- veh and trailer props
        local vehOffers, trailerOffers = {}, {}
        for _, offer in ipairs(dVehOfferManager.getAllOfferAtFacilityUnexpired(elem.facId)) do
          if offer.data.type == "vehicle" then
            table.insert(vehOffers, offer)
          end
          if offer.data.type == "trailer" then
            table.insert(trailerOffers, offer)
          end
        end
        if #vehOffers > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate(#vehOffers ~= 1 and "ui.career.delivery.general.vehicleTransportsAvailable" or "ui.career.delivery.general.vehicleTransportAvailable", {count = #vehOffers})
          })
        end
        if #trailerOffers > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = core_locales.contextTranslate(#trailerOffers ~= 1 and "ui.career.delivery.general.trailerTransportsAvailable" or "ui.career.delivery.general.trailerTransportAvailable", {count = #trailerOffers})
          })
        end
      end

      -- make actual poi elemens

      if anyCargoDropOffable then
        local dropOffPoi = deepcopy(poiTemplate)
        dropOffPoi.heading = _tr("ui.career.delivery.general.deliveryDropOff")
        dropOffPoi.buttonLabel = _tr("ui.career.delivery.general.dropOff")
        dropOffPoi.buttonFun = function() extensions.ui_router.navigate('career.cargoDropOff', {facilityId = elem.facId, parkingSpotPath = elem.psPath}) end
        dropOffPoi.icon = "poi_dropoff_round"
        table.insert(activityData, dropOffPoi)
      end

      if anyCargoPickUpAble then
        local pickUpPoi = deepcopy(poiTemplate)
        pickUpPoi.heading = _tr("ui.career.delivery.general.deliveryPickUp")
        pickUpPoi.buttonLabel = _tr("ui.career.delivery.general.pickUp")
        pickUpPoi.buttonFun = function()
          dParcelManager.applyTransientMoves({type="facilityParkingspot", facId = elem.facId, psPath = elem.psPath})
          M.requestUpdateContainerWeights()
          gameplay_markerInteraction.closeViewDetailPrompt(true)
          Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Info_Open')
          gameplay_rawPois.clear()
          dCargoScreen.onCargoPickedUp()
        end
        pickUpPoi.icon = "poi_dropoff_round"
        table.insert(activityData, pickUpPoi)
      end
      if elem.canInspectCargo then
        local inspectPoi = poiTemplate
        inspectPoi.heading = _tr("ui.career.delivery.general.inspectCargo")
        inspectPoi.buttonLabel = _tr("ui.career.delivery.general.inspect")
        inspectPoi.buttonFun = function() dCargoScreen.enterCargoOverviewScreen(elem.facId, elem.psPath) end
        table.insert(activityData, inspectPoi)
      end


    end
  end
end
M.onActivityAcceptGatherData = onActivityAcceptGatherData


local deliveryActivity = {
  id = "deliveryMode",
  name = _tr("ui.career.cargoOverview.deliveryMode"),

  vehicleModification = "warning",-- Slow and Fast Repairing, Changing and buying parts, tuning, painting
  vehicleSelling = "warning", --selling a vehicle
  vehicleStorage = "warning", --put vehicles into storage
  vehicleRepair = "warning",
  vehicleRetrieval = "allowed", --retrieve vehicles from storage

  vehicleShopping = "forbidden",

  interactRefuel = "allowed", --use the refueling POI to refuel vehicle
  interactMission = "warning", --use the mission POI to start a mission
  interactDelivery = "allowed", --use any delivery POI to start delivery mode

  recoveryFlipUpright = "allowed", --flip upright
  recoveryTowToRoad = "allowed", --tow to road
  recoveryTowToGarage = "warning", --tow to garage

  getLabel = function(tag)
    local penalty = -M.getDeliveryModePenalty().money
    local penaltyCtx = {penalty = string.format("%0.2f", penalty)}
    if     tag == "vehicleModification" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleModification", penaltyCtx)
    elseif tag == "vehicleSelling" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleSelling", penaltyCtx)
    elseif tag == "vehicleStorage" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleStorage", penaltyCtx)
    elseif tag == "vehicleRepair" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionVehicleRepair", penaltyCtx)
    elseif tag == "interactMission" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionInteractMission", penaltyCtx)
    elseif tag == "recoveryTowToGarage" then
      return core_locales.contextTranslate("ui.career.delivery.general.permissionRecoveryTowToGarage", penaltyCtx)
    elseif tag == "vehicleShopping" then
      return _tr("ui.career.delivery.general.permissionVehicleShopping")
    end
  end
}

local function onCheckPermission(tags, permissions)
  if not deliveryModeActive then return end
  for _, tag in ipairs(tags) do
    if deliveryActivity[tag] then
      table.insert(permissions, {permission = deliveryActivity[tag], label = deliveryActivity.getLabel(tag)})
      return
    end
  end
end

local function startDeliveryMode()
  if deliveryModeActive then return end
  log("I","","Delivery Mode Started.")
  deliveryModeActive = true
  gameplay_rawPois.clear()
  extensions.hook("onDeliveryModeStarted")
end

local function exitDeliveryMode()
  if not deliveryModeActive then return end
  log("I","","Delivery Mode Exited.")
  dParcelManager.clearTransientFlags()
  -- get all cargo currently in vehicles.
  local penalty = M.getDeliveryModePenalty()
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  if next(cargoInVehicles) then
    for _, cargo in ipairs(cargoInVehicles) do
      dParcelManager.changeCargoLocation(cargo.id, {type="deleted"})
    end
  end
  if penalty.money < 0 then
    guihooks.trigger("toastrMsg", {type="warning", title=_tr("ui.career.delivery.general.cargoAbandonedTitle"), msg=core_locales.contextTranslate("ui.career.delivery.general.cargoAbandonedDeliveryModeEnded", {penalty = string.format("%0.2f", -penalty.money)})})
    log("I","",string.format("Penalty for abandoning cargo: %0.2f$", -penalty.money))
    career_modules_playerAttributes.addAttributes(penalty, {tags={"gameplay", "delivery","fine"}, label="ui.career.delivery.general.penaltyAbandonLabel"})
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  end

  dVehicleTasks.abandonAllVehicleTasks()

  dParcelManager.clearAllTransientMoves()

  deliveryModeActive = false
  gameplay_rawPois.clear()
  freeroam_bigMapMode.setNavFocus(nil)

  M.requestUpdateContainerWeights()
  dTasklist.clearAll()
  --core_gamestate.setGameState("career", "career")
  extensions.hook("onDeliveryModeStopped")
end

local function checkExitDeliveryMode()
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  local vehicleTasks = dVehicleTasks.getVehicleTasks()
  if not next(cargoInVehicles) and not next(vehicleTasks) then
    M.exitDeliveryMode()
  end
end

local function isAutomaticRouteEnabled()
  return loadData.settings.automaticRoute
end
M.isAutomaticRouteEnabled = isAutomaticRouteEnabled

local function setAutomaticRoute(enabled)
  loadData.settings.automaticRoute = enabled
  if enabled then
    career_modules_delivery_cargoScreen.setBestRoute()
  else
    core_groundMarkers.setPath(nil)
    freeroam_bigMapMode.resetRoute()
  end
  guihooks.trigger("automaticRouteSet", enabled)
end

local function setDetailedDropOff(enabled)
  loadData.settings.detailedDropOff = enabled
  guihooks.trigger("detailedDropOffSet", enabled)
end

-- Deactivate automatic route when setting a manual waypoint
local function onSetBigmapNavFocus()
  if M.isDeliveryModeActive() then
    setAutomaticRoute(false)
  end
end

local function setSetting(key, value)
  loadData.settings[key] = value
end

local function getSettings()
  return loadData.settings
end

M.setAutomaticRoute = setAutomaticRoute
M.setDetailedDropOff = setDetailedDropOff
M.onSetBigmapNavFocus = onSetBigmapNavFocus

M.setSetting = setSetting
M.getSettings = getSettings

M.startDeliveryMode = startDeliveryMode
M.exitDeliveryMode = exitDeliveryMode
M.checkExitDeliveryMode = checkExitDeliveryMode
M.isDeliveryModeActive = function() return deliveryModeActive end

M.getDeliveryModePenalty = function(onlyVehIdsAsKeys)
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  local penalty = {money = 0}
  if not onlyVehIdsAsKeys then
    local fine = dVehicleTasks.getFineForAbandonAllVehicleTasks()
    for attKey, amount in pairs(fine) do
      penalty[attKey] = (penalty[attKey] or 0) + amount
    end
  end

  if next(cargoInVehicles) then
    for _, cargo in ipairs(cargoInVehicles) do
      if (not onlyVehIdsAsKeys) or (cargo.location.vehId and onlyVehIdsAsKeys[cargo.location.vehId]) then
        local abandonFac = M.getDeliveryAbandonPenaltyFactor()
        local modFac = 0
        if cargo.modifiers then
          for _, mod in ipairs(cargo.modifiers) do
            modFac = modFac + (mod.abandonMultiplier or 0)
          end
        end
        if not cargo._transientMove then
          penalty.money = penalty.money - cargo.rewards.money * (abandonFac + modFac)
        end
        if cargo.organization and penalty[cargo.organization.."Reputation"] then
          penalty[cargo.organization.."Reputation"] = penalty[cargo.organization.."Reputation"] or 0
          penalty[cargo.organization.."Reputation"] = penalty[cargo.organization.."Reputation"] - math.ceil(cargo.rewards[cargo.organization.."Reputation"] or 0)
        end
      end
    end
  end
  return penalty
end

M.onCheckPermission = onCheckPermission

-- actions that stop delivery mode

M.onPartShoppingStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because shopping started.")
    M.exitDeliveryMode()
  end
end

M.onCareerPaintingStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because painting started.")
    M.exitDeliveryMode()
  end
end

M.onCareerTuningStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because tuning started.")
    M.exitDeliveryMode()
  end
end

M.onTeleportedToGarage = function(garageId, veh)
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because towed to garage.")
    M.exitDeliveryMode()
  end
end

M.onAnyMissionChanged = function(change)
  if change == "started" then
    if deliveryModeActive then
      log("I","","Stopped Delivery mode because mission started.")
      M.exitDeliveryMode()
    end
  end
end

local function checkEndDeliveryModeForVehicle(vehId)
  if deliveryModeActive then
    -- TODO: this needs to check for cargo in vehicle containers, not just vehicle
    local penalty = M.getDeliveryModePenalty({[vehId] = true})
    local cargoInVehicle = dParcelManager.getAllCargoCustomFilter(function(cargo)
      if cargo.location.type == "vehicle" and cargo.location.vehId == vehId then
        return true
      end
      if cargo._transientMove and cargo.transientMove.targetLocation.vehId == vehId then
        return true
      end
    end)
    if next(cargoInVehicle) then
      for _, cargo in ipairs(cargoInVehicle) do
        dParcelManager.changeCargoLocation(cargo.id, {type="deleted"})
      end
      if penalty.money < 0 then
        guihooks.trigger("toastrMsg", {type="warning", title=_tr("ui.career.delivery.general.cargoAbandonedTitle"), msg=core_locales.contextTranslate("ui.career.delivery.general.cargoAbandonedVehicleStored", {penalty = string.format("%0.2f", -penalty.money)})})
        log("I","",string.format("Penalty for abandoning cargo: %0.2f$", -penalty.money))
        career_modules_playerAttributes.addAttributes(penalty, {tags={"gameplay", "delivery","fine"}, label="ui.career.delivery.general.penaltyAbandonLabel"})
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
      end
    end
    checkExitDeliveryMode()
  end
end

M.onRepairInGarage = function(invVehId)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(invVehId)
  checkEndDeliveryModeForVehicle(vehId)
end

M.onInventoryPreRemoveVehicleObject = function(inventoryId, vehId)
  checkEndDeliveryModeForVehicle(vehId)
end



return M
