-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career', "career_modules_log", "gameplay_tutorial_setup"}

local dateUtils = require('utils/dateUtils')

local minimumVersion = 42
local sellAllVehiclesCutoffVersion = 64

local xVec, yVec, zVec = vec3(1,0,0), vec3(0,1,0), vec3(0,0,1)

local saveAnyVehiclePosDEBUG = true

local slotAmount = 20

local vehicles = {}
local dirtiedVehicles = {}
local vehIdToInventoryId = {}
local inventoryIdToVehId = {}
local currentVehicle
local lastVehicle
local favoriteVehicle
local sellAllVehicles

local loadedVehiclesLocations
local unicycleSavedPosition

local vehicleToEnterId
local vehiclesMovedToStorage
local loanedVehicleReturned

local function getClosestGarage(pos)
  local facilities = freeroam_facilities.getFacilities(getCurrentLevelIdentifier())
  local playerVeh = getPlayerVehicle(0)
  local playerPos = pos or (playerVeh and playerVeh.getPosition and playerVeh:getPosition()) or vec3(0, 0, 0)
  local closestGarage
  local minDist = math.huge
  for _, garage in ipairs(facilities.garages) do
    local zones = freeroam_facilities.getZonesForFacility(garage)
    if zones and not tableIsEmpty(zones) then
      local dist = zones[1].center:distance(playerPos)
      if dist < minDist then
        closestGarage = garage
        minDist = dist
      end
    end
  end
  return closestGarage
end

local function onExtensionLoaded()
  if not career_career.isActive() then return false end

  -- load from saveslot
  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  if not saveSlot or not savePath then return end

  table.clear(vehicles)

  local saveInfo = jsonReadFile(savePath .. "/info.json")
  if not saveInfo or saveInfo.version < minimumVersion then return end

  -- load the vehicles
  local files = FS:findFiles(savePath .. "/career/vehicles/", '*.json', 0, false, false)
  for i = 1, tableSize(files) do
    local vehicleData = jsonReadFile(files[i])
    vehicleData.partConditions = deserialize(vehicleData.partConditions)
    if vehicleData.timeToAccess then
      vehicleData.timeToAccess = vehicleData.timeToAccess - dateUtils.timeSince(saveInfo.date)
      if vehicleData.timeToAccess <= 0 then
        vehicleData.timeToAccess = nil
        vehicleData.delayReason = nil
      end
    end

    vehicles[vehicleData.id] = vehicleData
    if tableIsEmpty(core_vehicles.getModel(vehicleData.model)) or not FS:fileExists(vehicleData.config.partConfigFilename) then
      vehicleData.missingFile = true
    else
      vehicleData.missingFile = nil
    end
  end

  local inventoryData = jsonReadFile(savePath .. "/career/inventory.json")

  -- Sell all vehicles when the save version is not the newest one
  if saveInfo.version < sellAllVehiclesCutoffVersion then
    sellAllVehicles = true
    if inventoryData then
      inventoryData.currentVehicle = nil
      inventoryData.lastVehicle = nil
      inventoryData.spawnedPlayerVehicles = nil
    end
  end

  if inventoryData then
    vehicleToEnterId = tonumber(inventoryData.currentVehicle)
    lastVehicle = tonumber(inventoryData.lastVehicle)
    favoriteVehicle = tonumber(inventoryData.favoriteVehicle)

    if inventoryData.spawnedPlayerVehicles then
      loadedVehiclesLocations = {}

      for inventoryId, transform in pairs(inventoryData.spawnedPlayerVehicles) do
        inventoryId = tonumber(inventoryId)
        if not saveAnyVehiclePosDEBUG then
          transform.option = "garage"
        end
        loadedVehiclesLocations[inventoryId] = transform
      end
    else
      loadedVehiclesLocations = nil -- will force spawning at garage
    end

    -- if the last currentVehicle is not spawned, then dont enter it
    if not (loadedVehiclesLocations and loadedVehiclesLocations[vehicleToEnterId]) then
      vehicleToEnterId = nil
    end

    unicycleSavedPosition = inventoryData.unicyclePos
  end
end

local function updateVehicleThumbnail(inventoryId, filename, callback)
  local vehId = M.getVehicleIdFromInventoryId(inventoryId)
  if not vehId then return end
  local vehObj = getObjectByID(vehId)

  local resolution = vec3(500, 281, 0)
  local fov = 50
  local nearPlane = 0.1
  local camPos, camRot = extensions.util_screenshotCreator.frameVehicle(vehObj, fov, nearPlane, resolution.x / resolution.y, {resolution.x, resolution.y})

  extensions.util_screenshotCreator.takeThumbnailScreenshot(filename, {
    pos = camPos,
    rot = camRot,
    fov = fov,
    nearPlane = nearPlane,
    screenshotDelay = 0.5
  }, callback, vehId)
end

local function setVehicleDirty(inventoryId)
  dirtiedVehicles[inventoryId] = true
end

local function updatePartConditionsOfSpawnedVehicles(callback)
  local callbackCounter = 0
  for vehId, inventoryId in pairs(vehIdToInventoryId) do
    setVehicleDirty(inventoryId)

    -- update part conditions and call the callback when all vehicles have been processed
    M.updatePartConditions(vehId, inventoryId, callback and
    function()
      callbackCounter = callbackCounter + 1
      if callbackCounter >= tableSize(vehIdToInventoryId) then
        callback()
      end
    end)
  end
  if callback and tableIsEmpty(vehIdToInventoryId) then
    callback()
  end
end

local extensionName = "inventory"
local function inventorySaveFinished(currentSavePath)
  -- if there are more async saving steps waiting for the vehicle save to finish, we need to call registerAsyncSaveExtension inside their onVehicleSaveFinished function first
  extensions.hook("onVehicleSaveFinished", currentSavePath)
  career_saveSystem.asyncSaveExtensionFinished(extensionName)
  guihooks.trigger("saveFinished")
end

local function onSaveCurrentProfileAsyncStart()
  career_saveSystem.registerAsyncSaveExtension(extensionName)
end

local finishedSaveTasks = {}
local function checkSaveFinished(currentSavePath)
  for _, fin in pairs(finishedSaveTasks) do
    if not fin then
      return --not finished
    end
  end
  inventorySaveFinished(currentSavePath)
end

local function saveVehiclesData(currentSavePath, vehiclesThumbnailUpdate)
  local vehiclesCopy = deepcopy(vehicles)
  local currentDate = os.date("!%Y-%m-%dT%H:%M:%SZ")

  for id, vehicle in pairs(vehiclesCopy) do
    if dirtiedVehicles[id] or not vehicle.dirtyDate then
      vehicles[id].dirtyDate = currentDate
      vehicle.dirtyDate = currentDate
      dirtiedVehicles[id] = nil
    end
    vehicle.partConditions = serialize(vehicle.partConditions)

    -- Save parts as a flat pc-style map
    if vehicle.config then
      if vehicle.config.partsTree then
        vehicle.config.parts = core_vehicle_partmgmt.partsTreeToPartsMap(vehicle.config.partsTree)
      end
      vehicle.config.partsTree = nil
    end

    local thumbnailFilename = currentSavePath .. "/career/vehicles/" .. id .. ".jpg"
    if vehiclesThumbnailUpdate and tableContains(vehiclesThumbnailUpdate, id) and inventoryIdToVehId[id] then
      finishedSaveTasks["thumbnail" .. id] = false
      updateVehicleThumbnail(id, thumbnailFilename, function()
        finishedSaveTasks["thumbnail" .. id] = true
        checkSaveFinished(currentSavePath)
      end)
      vehicle.defaultThumbnail = nil
      vehicles[id].defaultThumbnail = nil

    elseif not vehicle.defaultThumbnail then
      local _, oldSavePath = career_saveSystem.getCurrentProfile()
      FS:copyFile(oldSavePath .. "/career/vehicles/" .. id .. ".jpg", thumbnailFilename)
    end

    career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/vehicles/" .. id .. ".json", vehicle, true)
  end

  if currentVehicle then
    dirtiedVehicles[currentVehicle] = true
  end

  -- Remove vehicle files for vehicles that have been deleted
  local files = FS:findFiles(currentSavePath .. "/career/vehicles/", '*.json', 0, false, false)
  for i = 1, tableSize(files) do
    local dir, filename, ext = path.split(files[i])
    local fileNameNoExt = string.sub(filename, 1, -6)
    local inventoryId = tonumber(fileNameNoExt)
    if not vehicles[inventoryId] then
      FS:removeFile(dir .. filename)
      FS:removeFile(dir .. inventoryId .. ".jpg")
    end
  end
end

-- TODO update a vehicles part conditions in the table when you exit a vehicle
local function onSaveCurrentProfile(currentSavePath, vehiclesThumbnailUpdate)
  local data = {}
  data.currentVehicle = currentVehicle
  data.lastVehicle = lastVehicle
  data.favoriteVehicle = favoriteVehicle

  data.spawnedPlayerVehicles = {}
  for inventoryId, vehId in pairs(inventoryIdToVehId) do
    local veh = getObjectByID(vehId)
    if veh then
      data.spawnedPlayerVehicles[inventoryId] = {pos = veh:getPosition(), rot = quat(0,0,1,0) * quat(veh:getRefNodeRotation())}
    end
  end

  if gameplay_walk.isWalking() then
    local playerVeh = getPlayerVehicle(0)
    if playerVeh and playerVeh.getPosition then
      data.unicyclePos = playerVeh:getPosition()
    end
  end

  table.clear(finishedSaveTasks)

  finishedSaveTasks.updatePartConditions = false
  updatePartConditionsOfSpawnedVehicles(function()
    saveVehiclesData(currentSavePath, vehiclesThumbnailUpdate)
    finishedSaveTasks.updatePartConditions = true
    checkSaveFinished(currentSavePath)
  end)

  career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/inventory.json", data, true)
end

local function assignInventoryIdToVehId(inventoryId, vehId)
  if vehIdToInventoryId[vehId] then
    inventoryIdToVehId[vehIdToInventoryId[vehId]] = nil
  end
  vehIdToInventoryId[vehId] = inventoryId
  inventoryIdToVehId[inventoryId] = vehId
end

local function getNumberOfFreeSlots()
  local ownedVehiclesAmount = 0
  for inventoryId, vehicle in pairs(vehicles) do
    if vehicle.owned and not vehicle.takesNoInventorySpace then ownedVehiclesAmount = ownedVehiclesAmount + 1 end
  end
  return slotAmount - ownedVehiclesAmount
end

local function hasFreeSlot()
  return getNumberOfFreeSlots() > 0
end

local inventoryIdAfterUpdatingPartConditions
local function addVehicle(vehId, inventoryId, options)
  options = options or {}
  if options.owned == nil then options.owned = true end

  local vehicle = scenetree.findObjectById(vehId)
  local vehicleData = core_vehicle_manager.getVehicleData(vehId)

  if vehicle and vehicleData then
    if not inventoryId then
      inventoryId = 1
      while vehicles[inventoryId] do
        inventoryId = inventoryId + 1
      end
    end
    local niceName
    if vehicleData.vdata and vehicleData.vdata.information then
      niceName = vehicleData.vdata.information.name
    end

    vehicles[inventoryId] = vehicles[inventoryId] or {}
    vehicles[inventoryId].model = vehicle.JBeam or ""
    vehicles[inventoryId].config = vehicleData.config
    vehicles[inventoryId].id = inventoryId
    vehicles[inventoryId].niceName = niceName
    vehicles[inventoryId].config.licenseName = core_vehicles.getVehicleLicenseText(vehicle)
    vehicles[inventoryId].owned = options.owned
    vehicles[inventoryId].defaultThumbnail = true
    vehicles[inventoryId].finalBuyingPrice = options.finalPrice

    if vehicle.JBeam and vehicleData.config and vehicleData.config.partConfigFilename then
      local dir, configName, ext = path.splitWithoutExt(vehicleData.config.partConfigFilename)
      local baseConfig = core_vehicles.getConfig(vehicle.JBeam, configName)
      vehicles[inventoryId].configBaseValue = baseConfig.Value
      vehicles[inventoryId].takesNoInventorySpace = baseConfig.takesNoInventorySpace
    else
      log("D", "", "Couldnt find base value for added vehicle, so using default value")
      vehicles[inventoryId].configBaseValue = 1000
    end

    assignInventoryIdToVehId(inventoryId, vehId)

    inventoryIdAfterUpdatingPartConditions = inventoryId
    vehicle:queueLuaCommand(string.format("if not partCondition.getConditions() then partCondition.initConditions() end obj:queueGameEngineLua('career_modules_inventory.updatePartConditions(%d, %d)')", vehId, inventoryId))
    local amountOfVehicles = tableSize(vehicles)
    if amountOfVehicles == 1 then
      M.setFavoriteVehicle(inventoryId)
    end
    local amountOfOwnedVehicles = 0
    for _, inventoryVehicle in pairs(vehicles) do
      if inventoryVehicle.owned then
        amountOfOwnedVehicles = amountOfOwnedVehicles + 1
      end
    end
    if amountOfOwnedVehicles >= 3 then
      gameplay_achievement.unlockAchievement("GARAGE_STARTER")
    end
    return inventoryId
  end
end

local skipPartConditionsBeforeWalking
local function removeVehicleObject(inventoryId, skipPartConditions)
  if currentVehicle == inventoryId then
    skipPartConditionsBeforeWalking = true
    gameplay_walk.setWalkingMode(true, nil, nil, true)
  end
  extensions.hook("onInventoryPreRemoveVehicleObject", inventoryId, M.getVehicleIdFromInventoryId(inventoryId))
  -- TODO save part conditions
  local vehId = inventoryIdToVehId[inventoryId]
  if vehId then
    local obj = getObjectByID(vehId)
    if obj then
      obj:delete()
    end
    vehIdToInventoryId[vehId] = nil
  end
  inventoryIdToVehId[inventoryId] = nil
end

local function removeVehicle(inventoryId)
  removeVehicleObject(inventoryId)
  vehicles[inventoryId] = nil
  extensions.hook("onVehicleRemoved", inventoryId)

  if favoriteVehicle == inventoryId then
    M.setFavoriteVehicle(next(vehicles))
  end
end

local function onPartConditionsUpdateFinished()
  if inventoryIdAfterUpdatingPartConditions then
    extensions.hook("onVehicleAdded", inventoryIdAfterUpdatingPartConditions)
    inventoryIdAfterUpdatingPartConditions = nil
  end
end

local function getPartConditionsCallback(partConditions, inventoryId)
  vehicles[inventoryId].partConditions = partConditions
  onPartConditionsUpdateFinished()
  career_modules_partInventory.updatePartConditionsInInventory()
end

local function updatePartConditions(vehId, inventoryId, callback)
  local veh
  if vehId then
    veh = getObjectByID(vehId)
  else
    veh = getObjectByID(inventoryIdToVehId[inventoryId])
  end
  if not veh then
    log("E", "", "Couldnt find vehicle object to get part conditions")
    return
  end

  core_vehicleBridge.requestValue(
    veh,
    function(res)
      getPartConditionsCallback(res.result, inventoryId)
      if callback then callback() end
    end,
    'getPartConditions'
  )
end

local function applyPartConditions(inventoryId, vehId)
  local veh = scenetree.findObjectById(vehId or inventoryIdToVehId[inventoryId])
  if not veh then return end
  core_vehicleBridge.executeAction(veh, 'initPartConditions', vehicles[inventoryId].partConditions)
end

-- replaceOption 1: replace the current vehicle object
-- replaceOption 2: replace the vehicle object with the same inventoryId
local function spawnVehicle(inventoryId, replaceOption, callback)
  local vehInfo = vehicles[inventoryId]

  local carConfigToLoad = vehInfo.config
  local carModelToLoad = vehInfo.model

  if carConfigToLoad then
    -- if the vehicle doesnt exist (deleted mod) then dont spawn
    if tableIsEmpty(core_vehicles.getModel(carModelToLoad)) or not FS:fileExists(vehInfo.config.partConfigFilename) then
      return
    end

    local vehObj
    local vehicleData = {}
    -- Spawn from a flat pc-style parts map so the parts tree cant break stuff with outdated parts. this flattening might not be needed here, but it's there so a spawn from a previously spawned vehicle behaves the same as a not-previously spawned vehicle.
    local spawnConfig = carConfigToLoad
    if spawnConfig.partsTree then
      spawnConfig = deepcopy(spawnConfig)
      spawnConfig.parts = core_vehicle_partmgmt.partsTreeToPartsMap(spawnConfig.partsTree)
      spawnConfig.partsTree = nil
    end
    vehicleData.config = spawnConfig
    vehicleData.keepOtherVehRotation = true

    core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = false})
    if replaceOption == 1 then
      vehObj = core_vehicles.replaceVehicle(carModelToLoad, vehicleData)
    elseif replaceOption == 2 then
      -- check if the vehicle object with the same inventoryId exists and then replace it specifically
      local oldVehId = inventoryIdToVehId[inventoryId]
      local oldVehObj
      if oldVehId then
        oldVehObj = getObjectByID(oldVehId)
      end
      vehObj = core_vehicles.replaceVehicle(carModelToLoad, vehicleData, oldVehObj)
    else
      vehicleData.autoEnterVehicle = false
      vehObj = core_vehicles.spawnNewVehicle(carModelToLoad, vehicleData)
    end

    if not vehObj then
      log("E", "", "Couldnt spawn vehicle")
      return
    end

    assignInventoryIdToVehId(inventoryId, vehObj:getID())
    local numberOfBrokenParts = career_modules_valueCalculator.getNumberOfBrokenParts(vehInfo.partConditions)
    if numberOfBrokenParts > 0 and numberOfBrokenParts < career_modules_valueCalculator.getBrokenPartsThreshold() then
      career_modules_insurance_insurance.repairPartConditions({partConditions = vehInfo.partConditions})
    end

    if vehInfo.partConditions then
      core_vehicleBridge.executeAction(vehObj, 'initPartConditions', vehInfo.partConditions, 0, 1, 1)
      core_vehicleBridge.requestValue(vehObj, function()
        -- Adopt the freshly resolved parts tree from the spawned vehicle and reconcile our data.
        career_modules_partInventory.updatePartsToMatchSpawnedVehicle(inventoryId)
        if callback then callback() end
      end, 'ping')
    else
      core_vehicleBridge.executeAction(vehObj, 'initPartConditions', {}, 0, 1, 1)
      core_vehicleBridge.requestValue(vehObj, function(res) career_modules_inventory.updatePartConditions(nil, inventoryId, callback) end, 'ping')
    end

    gameplay_walk.removeVehicleFromBlacklist(vehObj:getId())
    return vehObj
  end
end

-- loadOption 1: dont reload the vehicle
-- loadOption 2: force reload the vehicle
local enterCallbackFunction
local function enterVehicleActual(id, loadOption)
  if not id or loadOption == 1 then
    currentVehicle = id
  elseif inventoryIdToVehId[id] and loadOption ~= 2 then
    -- vehicle is already spawned. enter it
    gameplay_walk.setWalkingMode(false, nil, nil, true)
    be:enterVehicle(0, getObjectByID(inventoryIdToVehId[id]))
    currentVehicle = id
  else
    if spawnVehicle(id, 1, enterCallbackFunction) then
      currentVehicle = id
    end
    enterCallbackFunction = nil
  end
  if currentVehicle then
    dirtiedVehicles[currentVehicle] = true
  end
  extensions.hook("onEnterVehicleFinished", currentVehicle)

  if enterCallbackFunction then enterCallbackFunction() end
end

-- loadOption 1: dont reload the vehicle
-- loadOption 2: force reload the vehicle
local function enterVehicle(newInventoryId, loadOption, callback)
  local vehInfo = vehicles[newInventoryId]
  if vehInfo and vehInfo.timeToAccess then return end
  career_modules_log.addLog(string.format("Enter vehicle %s", newInventoryId or "no vehicle"), "inventory")

  enterCallbackFunction = callback
  if loadOption == 1 then
    enterVehicleActual(newInventoryId, loadOption)
    return
  end
  if currentVehicle then
    updatePartConditionsOfSpawnedVehicles(function() enterVehicleActual(newInventoryId, loadOption) end)
  else
    enterVehicleActual(newInventoryId, loadOption)
  end
end

local saveCareer
local function setupInventory()
  local tutorialActive = career_career.tutorialEnabled
  if not tutorialActive then
    if loadedVehiclesLocations then
      local vehiclesToTeleportToGarage = {}
      for inventoryId, location in pairs(loadedVehiclesLocations) do
        local vehInfo = vehicles[inventoryId]
        if vehInfo.loanType == "work" then
          career_modules_loanerVehicles.returnVehicle(inventoryId)
          loanedVehicleReturned = true
        else
          if career_modules_insurance_insurance.inventoryVehNeedsRepair(inventoryId) then
            vehiclesMovedToStorage = true
          else
            local veh = spawnVehicle(inventoryId)
            if veh then
              if location.option == "garage" then
                location.vehId = veh:getID()
                vehiclesToTeleportToGarage[inventoryId] = location
              end
              spawn.safeTeleport(veh, location.pos, location.rot)
            end
          end
        end
      end
      loadedVehiclesLocations = nil

      -- The teleport to garage needs to happen with one frame delay because that's when the OOBBs get updated
      extensions.core_jobsystem.create(
        function (job)
          for inventoryId, location in pairs(vehiclesToTeleportToGarage) do
            local veh = getObjectByID(location.vehId)
            local garage = getClosestGarage(location.pos)
            freeroam_facilities.teleportToGarage(garage.id, veh)
            job.sleep(0.1)
          end
        end
      )
    end

    if vehicleToEnterId and inventoryIdToVehId[vehicleToEnterId] then
      enterVehicle(vehicleToEnterId)
    else
      gameplay_walk.setWalkingMode(true)
    end
  else
    gameplay_walk.setWalkingMode(true)
  end

  local saveSlot, savePath = career_saveSystem.getCurrentProfile()
  local data = jsonReadFile(savePath .. "/info.json")
  local newCareerSave = not data

  -- this means this is a new career save
  if newCareerSave and not career_career.tutorialEnabled then
    saveCareer = 0
  end

  if newCareerSave or career_career.tutorialEnabled then
    local modeData = career_career.getCurrentStartingModeData and career_career.getCurrentStartingModeData()
    local setupInventoryFn = modeData and modeData.setupInventory
    if type(setupInventoryFn) == "function" then
      setupInventoryFn(M)
    else
      log("W", "career.inventory", "No setupInventory hook found for starting mode. Falling back to tutorial setup.")
      gameplay_tutorial_setup.setupVehicles()
    end
  else
    if gameplay_walk.isWalking() then
      if unicycleSavedPosition then
        spawn.safeTeleport(getPlayerVehicle(0), unicycleSavedPosition)
      else
        freeroam_facilities.teleportToGarage("servicestationGarage", getPlayerVehicle(0))
      end
    end
  end

  commands.setGameCamera()
end

local function onCareerActive(active)
  if not active then return end
  if sellAllVehicles then
    for inventoryId, vehicle in pairs(vehicles) do
      if vehicle.owned then
        M.sellVehicle(inventoryId)
      elseif vehicle.loanType == "work" then
        career_modules_loanerVehicles.returnVehicle(inventoryId)
        loanedVehicleReturned = true
      else
        M.removeVehicle(inventoryId)
      end
    end
    sellAllVehicles = nil
  end
  setupInventory()
end

local function setPartConditionResetSnapshot(veh, callback)
  core_vehicleBridge.executeAction(veh, 'createPartConditionSnapshot', "beforeReset")
  core_vehicleBridge.executeAction(veh, 'setPartConditionResetSnapshotKey', "beforeReset")
  if callback then
    core_vehicleBridge.requestValue(veh, callback, "ping")
  end
end

local function onBigMapActivated()
  if currentVehicle then
    local playerVeh = getPlayerVehicle(0)
    if playerVeh then
      setPartConditionResetSnapshot(playerVeh)
    end
  end
end

local function teleportedFromBigmap()
  if currentVehicle and career_career.isAutosaveEnabled() then
    career_saveSystem.saveCurrent()
  end
end

local function getCurrentVehicle()
  return currentVehicle
end

local function getLastVehicle()
  return lastVehicle
end

local function getVehicleIdFromInventoryId(inventoryId)
  if inventoryId then
    return inventoryIdToVehId[inventoryId]
  end
end

local function getInventoryIdFromVehicleId(vehId)
  if vehId then
    return vehIdToInventoryId[vehId]
  end
end

local function getMapInventoryIdToVehId()
  return inventoryIdToVehId
end

local function getCurrentVehicleId()
  return getVehicleIdFromInventoryId(currentVehicle)
end

local function isSeatedInsideOwnedVehicle()
  return currentVehicle and true or false
end

local function getVehiclesInGarage(garage, intersecting)
  local zones = freeroam_facilities.getZonesForFacility(garage)
  local spawnedVehicles = {}
  local res = {}
  for inventoryId, vehId in pairs(inventoryIdToVehId) do
    spawnedVehicles[inventoryId] = getObjectByID(vehId)
  end
  for _, zone in ipairs(zones) do
    for inventoryId, veh in pairs(spawnedVehicles) do
      if intersecting then
        local vehBB = veh:getWorldBox()
        local vehBBExtents = vehBB:getExtents() * 0.5
        local vehPos = veh:getPosition()
        local zoneExtents = vec3(zone.aabb.xMax - zone.aabb.xMin, zone.aabb.yMax - zone.aabb.yMin, zone.aabb.zMax - zone.aabb.zMin)
        zoneExtents.z = math.min(zoneExtents.z, 10000)
        if overlapsOBB_OBB(vehBB:getCenter(), xVec * vehBBExtents.x, yVec * vehBBExtents.y, zVec * vehBBExtents.z,
                           zone.center, xVec * zoneExtents.x/2, yVec * zoneExtents.y/2, zVec * zoneExtents.z/2) then
          for nodeId = 0, veh:getNodeCount() - 1 do
            if zone:containsPoint2D(veh:getNodePosition(nodeId) + vehPos) then
              res[inventoryId] = true
              break
            end
          end
        end
      elseif zone:containsVehicle(veh) then
        res[inventoryId] = true
      end
    end
  end
  return res
end

local function removeVehiclesFromGarageExcept(inventoryId)
  local garage = getClosestGarage()
  local inventoryIdsInGarage = getVehiclesInGarage(garage, true)
  for otherInventoryId, _ in pairs(inventoryIdsInGarage) do
    if otherInventoryId ~= inventoryId then
      local vehInfo = vehicles[otherInventoryId]
      if vehInfo.owned then
        M.removeVehicleObject(otherInventoryId)
      end
    end
  end
end

local function getDefaultVehicleThumb(vehInfo)
  local model = core_vehicles.getModel(vehInfo.model)
  if not model or not model.configs then return nil end
  local _, configKey = path.splitWithoutExt(vehInfo.config.partConfigFilename)
  local config = model.configs[configKey]
  if not config then return nil end
  return config.preview
end

local function getVehicleThumbnail(inventoryId)
  if not inventoryId then return end
  local vehicle = vehicles[inventoryId]
  if not vehicle then return end
  local _, savePath = career_saveSystem.getCurrentProfile()
  local thumbnailPath = savePath .. "/career/vehicles/" .. inventoryId .. ".jpg"
  if not vehicle.defaultThumbnail and FS:fileExists(thumbnailPath) then
    return thumbnailPath
  else
    return getDefaultVehicleThumb(vehicle)
  end
end

local originComputerId
local menuIsOpen
local buttonsActive = {}
local chooseButtonsData = {}
local menuHeader
local menuBackTarget

local function processPerformanceData(performanceData)
  if not performanceData then return end

  -- Process drivetrain information
  if performanceData.powertrainLayout then
    local frontWheelDrive = performanceData.powertrainLayout.poweredWheelsFront > 0
    local rearWheelDrive = performanceData.powertrainLayout.poweredWheelsRear > 0
    performanceData.drivetrain = frontWheelDrive and rearWheelDrive and "AWD" or frontWheelDrive and "FWD" or rearWheelDrive and "RWD" or "Unknown"
  end

  -- Process fuel type information
  if performanceData.fuelType then
    if performanceData.fuelType["fuelTank:gasoline"] then
      performanceData.fuelType = "Gasoline"
    elseif performanceData.fuelType["fuelTank:diesel"] then
      performanceData.fuelType = "Diesel"
    elseif performanceData.fuelType["fuelTank:electric"] then
      performanceData.fuelType = "Electric"
    elseif next(performanceData.fuelType) then
      performanceData.fuelType = next(performanceData.fuelType)
    else
      performanceData.fuelType = "Unknown"
    end
  end

  -- Process induction type information
  if performanceData.inductionType then
    if performanceData.inductionType.naturalAspiration then
      performanceData.inductionType = "NA"
    elseif performanceData.inductionType.turbocharger then
      performanceData.inductionType = "Turbocharger"
    elseif next(performanceData.inductionType) then
      performanceData.inductionType = next(performanceData.inductionType)
    else
      performanceData.inductionType = "Unknown"
    end
  end

  if performanceData.lateralAcceleration then
    performanceData.lateralGForce = performanceData.lateralAcceleration.maxAcceleration / 9.81
  end

  career_modules_vehiclePerformance.addScoresToPerformanceData(performanceData)

  if type(performanceData.power) == "table" and performanceData.power.propulsionPowerCombined and performanceData.weight then
    local powerInHP = performanceData.power.propulsionPowerCombined / 735.5
    performanceData.powerPerTon = powerInHP * 1000 / performanceData.weight
    performanceData.power = powerInHP
  end

  career_modules_vehiclePerformance.translatePerformanceDataForUi(performanceData)
end

local function getVehicleNiceNameTranslated(inventoryId)
  local vehicleData = vehicles[inventoryId]
  if not vehicleData then return end
  return core_locales.translateWithOrWithoutContext(vehicleData.niceName)
end

local function getVehicleUiData(inventoryId, inventoryIdsInGarage)
  local vehicleData = deepcopy(vehicles[inventoryId])
  if not vehicleData then return end
  if not inventoryIdsInGarage then
    inventoryIdsInGarage = getVehiclesInGarage(getClosestGarage())
  end

  vehicleData.niceName = getVehicleNiceNameTranslated(inventoryId)
  vehicleData.value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId)
  vehicleData.valueRepaired = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId, true)
  vehicleData.quickRepairExtraPrice = career_modules_insurance_insurance.getQuickRepairExtraPrice()
  vehicleData.initialRepairTime = career_modules_insurance_insurance.getInvVehRepairTime(inventoryId)

  if inventoryIdToVehId[inventoryId] then
    local vehObj = getObjectByID(inventoryIdToVehId[inventoryId])
    if vehObj then
      local playerVeh = getPlayerVehicle(0)
      if playerVeh and playerVeh.getPosition and vehObj.getPosition then
        vehicleData.distance = vehObj:getPosition():distance(playerVeh:getPosition())
      else
        vehicleData.distance = 0
      end
      vehicleData.inGarage = inventoryIdsInGarage[inventoryId]
    end
    vehicleData.inStorage = false
  else
    vehicleData.inStorage = true
  end

  for otherInventoryId, _ in pairs(inventoryIdsInGarage) do
    if otherInventoryId ~= inventoryId then
      vehicleData.otherVehicleInGarage = true
      break
    end
  end

  vehicleData.needsRepair = career_modules_insurance_insurance.inventoryVehNeedsRepair(vehicleData.id)
  if inventoryId == favoriteVehicle then
    vehicleData.favorite = true
  end

  local vehInsuranceInfo = career_modules_insurance_insurance.getVehInsuranceInfo(inventoryId)
  if vehInsuranceInfo then
    vehicleData.insuranceInfo = vehInsuranceInfo.insuranceInfo
    vehicleData.isInsured = vehInsuranceInfo.isInsured
    vehicleData.insuranceClass = vehInsuranceInfo.insuranceClass
    vehicleData.thumbnail = getVehicleThumbnail(inventoryId)
  end

  vehicleData.repairPermission = career_modules_permissions.getStatusForTag("vehicleRepair", {inventoryId = inventoryId})
  vehicleData.sellPermission = career_modules_permissions.getStatusForTag("vehicleSelling", {inventoryId = inventoryId})
  vehicleData.favoritePermission = career_modules_permissions.getStatusForTag("vehicleFavorite", {inventoryId = inventoryId})
  vehicleData.storePermission = career_modules_permissions.getStatusForTag("vehicleStoring", {inventoryId = inventoryId})
  vehicleData.licensePlateChangePermission = career_modules_permissions.getStatusForTag({"vehicleLicensePlate", "vehicleModification"}, {inventoryId = inventoryId})
  vehicleData.returnLoanerPermission = career_modules_permissions.getStatusForTag("returnLoanedVehicle", {inventoryId = inventoryId})

  vehicleData.listedForSale = career_modules_marketplace.findVehicleListing(inventoryId) ~= nil

  for _, performanceData in ipairs(vehicleData.performanceHistory or {}) do
    processPerformanceData(performanceData)
  end

  if vehicleData.certificationData then
    processPerformanceData(vehicleData.certificationData)
  end

  return vehicleData
end

local function sendDataToUi()
  menuIsOpen = true
  local data = {vehicles = {}}
  data.menuHeader = menuHeader
  data.chooseButtonsData = chooseButtonsData
  data.buttonsActive = buttonsActive

  local inventoryIdsInGarage = getVehiclesInGarage(getClosestGarage())

  for inventoryId, vehicle in pairs(vehicles) do
    data.vehicles[tostring(inventoryId)] = getVehicleUiData(inventoryId, inventoryIdsInGarage)
  end

  data.numberOfFreeSlots = getNumberOfFreeSlots()
  data.originComputerId = originComputerId

  data.playerMoney = career_modules_playerAttributes.getAttributeValue("money")
  guihooks.trigger("vehicleInventoryData", data)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if saveCareer then
    -- we delay the save here so that the part condition initialization is definitely finished beforehand
    if saveCareer >= 10 then
      career_saveSystem.saveCurrent() -- this is the save just after starting a new career
      saveCareer = nil
    else
      saveCareer = saveCareer + 1
    end
  end

  if vehiclesMovedToStorage then
    guihooks.trigger("toastrMsg", {type="warning", label = "vehStored", title = _tr("ui.career.inventory.toast.vehicleStored.title"), msg = _tr("ui.career.inventory.toast.vehicleStored.msg")})
    vehiclesMovedToStorage = nil
  end

  if loanedVehicleReturned then
    guihooks.trigger("toastrMsg", {type="warning", label = "loanReturned", title = _tr("ui.career.inventory.toast.loanReturned.title"), msg = _tr("ui.career.inventory.toast.loanReturned.msg")})
    loanedVehicleReturned = nil
  end

  for inventoryId, vehInfo in pairs(vehicles) do
    if vehInfo.timeToAccess then
      vehInfo.timeToAccess = vehInfo.timeToAccess - dtReal
      setVehicleDirty(inventoryId)
      if vehInfo.timeToAccess < 0 then
        if vehInfo.delayReason == "bought" then
          ui_message(core_locales.contextTranslate("ui.career.inventory.message.vehicleDeliveredToStorage", {vehicleName = vehInfo.niceName}), nil, "vehicleInventory")
        elseif vehInfo.delayReason == "repair" then
          ui_message(core_locales.contextTranslate("ui.career.inventory.message.vehicleRepairedReturnedToStorage", {vehicleName = vehInfo.niceName}), nil, "vehicleInventory")
        end
        vehInfo.timeToAccess = nil
        vehInfo.delayReason = nil
        if menuIsOpen then
          sendDataToUi()
        end
      end
    end
  end
end

local function onBeforeWalkingModeToggled(enabled, vehicleInFrontVehId)
  if enabled then
    enterVehicle(nil, skipPartConditionsBeforeWalking and 1 or nil)
  elseif vehIdToInventoryId[vehicleInFrontVehId] then
    enterVehicle(vehIdToInventoryId[vehicleInFrontVehId], 1)
  end
  skipPartConditionsBeforeWalking = nil
end

local function getInventoryIdsInClosestGarage(onlyFirst)
  -- get closest garage
  local closestGarage = getClosestGarage()

  -- check if a vehicle is in the zone of the closest garage
  local inventoryIdsInGarage = getVehiclesInGarage(closestGarage, true)
  local inventoryIdsList = {}
  for inventoryId, _ in pairs(inventoryIdsInGarage) do
    table.insert(inventoryIdsList, inventoryId)
  end

  if getPlayerVehicle(0) then
    local playerPos = getPlayerVehicle(0):getPosition()
    table.sort(inventoryIdsList, function(id1, id2)
      local veh1 = getObjectByID(inventoryIdToVehId[id1])
      local veh2 = getObjectByID(inventoryIdToVehId[id2])
      return veh1:getPosition():distance(playerPos) < veh2:getPosition():distance(playerPos)
    end)
  end

  if onlyFirst then
    return next(inventoryIdsInGarage)
  else
    return inventoryIdsList
  end
end

local callbackAfterFade
local function onScreenFadeState(state)
  if callbackAfterFade and state == 1 then
    career_modules_vehicleDeletionService.deleteFlaggedVehicles()
    callbackAfterFade()
    callbackAfterFade = nil
  end
end

local function openMenu(_chooseButtonsData, header, _buttonsActive, _backTarget)
  menuBackTarget = _backTarget
  buttonsActive = _buttonsActive or {}
  if buttonsActive.repairEnabled == nil then buttonsActive.repairEnabled = true end
  if buttonsActive.sellEnabled == nil then buttonsActive.sellEnabled = true end
  if buttonsActive.favoriteEnabled == nil then buttonsActive.favoriteEnabled = true end
  if buttonsActive.storingEnabled == nil then buttonsActive.storingEnabled = true end
  if buttonsActive.returnLoanerEnabled == nil then buttonsActive.returnLoanerEnabled = true end
  menuHeader = header or _tr("ui.career.computer.functions.vehicleInventory")

  chooseButtonsData = _chooseButtonsData or {{}}
  for _, buttonData in ipairs(chooseButtonsData) do
    buttonData.buttonText = buttonData.buttonText or _tr("ui.career.inventory.button.chooseVehicle")
    if buttonData.repairRequired == nil then buttonData.repairRequired = true end
    if buttonData.insuranceRequired == nil then buttonData.insuranceRequired = false end
    if buttonData.ownedRequired == nil then buttonData.ownedRequired = false end
    buttonData.callback = buttonData.callback or function() end
  end

  extensions.ui_router.navigate("career.computer.vehicleInventory")
  updatePartConditionsOfSpawnedVehicles()
end

local function closeMenu()
  career_career.closeAllMenus()
end

local function requestPickerExit()
  return extensions.ui_router.navigate(menuBackTarget or "career.computer")
end

local function spawnVehicleAfterFade(enterAfterSpawn, inventoryId, callback)
  ui_fadeScreen.start(0.5)
  callbackAfterFade = function()
    if enterAfterSpawn then
      enterVehicle(inventoryId, nil, callback)
    else
      -- if the vehicle is already spawned, call the callback directly
      if inventoryIdToVehId[inventoryId] then
        callback()
      elseif not spawnVehicle(inventoryId, nil, callback) then
        ui_fadeScreen.stop(0.5)
        guihooks.trigger("toastrMsg", {type="error", label = "vehSpawnFailed", title = _tr("ui.career.inventory.toast.vehicleSpawnFailed.title"), msg = _tr("ui.career.inventory.toast.vehicleSpawnFailed.msg")})
      end
    end
  end
end

local function spawnVehicleAndTeleportToGarage(enterAfterSpawn, inventoryId, replaceOthers)
  if inventoryId == currentVehicle then return end
  spawnVehicleAfterFade(enterAfterSpawn, inventoryId,
  function()
    if replaceOthers then
      removeVehiclesFromGarageExcept(inventoryId)
    end
    local vehObj = getObjectByID(inventoryIdToVehId[inventoryId])
    setPartConditionResetSnapshot(vehObj,
      function()
        local closestGarage = getClosestGarage()
        freeroam_facilities.teleportToGarage(closestGarage.id, vehObj, false)
        career_modules_fuel.minimumRefuelingCheck(vehObj:getId())
        setVehicleDirty(inventoryId)
        extensions.ui_router.navigate('play')
        ui_fadeScreen.stop(0.5)

        local pos, _ = freeroam_facilities.getGaragePosRot(closestGarage, vehObj)
        career_modules_playerDriving.showPosition(pos)

        career_modules_log.addLog(string.format("Spawned vehicle %d in garage %s. replaceOthers == %s", inventoryId, closestGarage.id, replaceOthers), "inventory")
      end)
  end)
end

local function openMenuFromComputer(_originComputerId)
  originComputerId = _originComputerId
  openMenu(
    {
      {
        callback = function(inventoryId) spawnVehicleAndTeleportToGarage(false, inventoryId) end,
        buttonText = _tr("ui.career.inventory.button.retrieve"),
        insuranceRequired = true,
        requiredVehicleNotInGarage = true
      },
      {
        callback = function(inventoryId) spawnVehicleAndTeleportToGarage(false, inventoryId, true) end,
        buttonText = _tr("ui.career.inventory.button.replaceCurrentVehicle"),
        insuranceRequired = true,
        requiredOtherVehicleInGarage = true
      },
      {
        callback = function(inventoryId)
          career_modules_vehiclePerformance.openMenu({inventoryId = inventoryId, computerId = originComputerId})
        end,
        buttonText = _tr("ui.career.shared.pathPerformanceIndex"),
        repairRequired = false
      }
    },
    _tr("ui.career.inventory.menu.spawnVehicle")
  )
  career_modules_log.addLog(string.format("Opened vehicle inventory from computer %s", originComputerId), "inventory")
end

local function chooseVehicleFromMenu(inventoryId, buttonIndex, repairPrevVeh)
  chooseButtonsData[buttonIndex].callback(inventoryId, repairPrevVeh)
end

local function openInventoryMenuForChoosingListing()
  openMenu(
    {{
      callback = function(inventoryId)
        guihooks.trigger('addListing', {inventoryId = inventoryId})
      end,
      buttonText = _tr("ui.career.inventory.button.listForSale"),
      repairRequired = true,
      ownedRequired = true,
      notForSaleRequired = true,
    }}, _tr("ui.career.inventory.menu.listForSale"),
    {
      repairEnabled = false,
      sellEnabled = false,
      favoriteEnabled = false,
      storingEnabled = false,
      returnLoanerEnabled = false
    },
    "career.computer.vehicleShopping"
  )
end

local function onExitVehicleInventory()
  menuIsOpen = false
  menuHeader = nil
end

local function onEnterVehicleFinished(inventoryId)
  if inventoryId then
    lastVehicle = inventoryId
  end
end

local function getVehicles()
  return vehicles
end

local function getVehicle(inventoryId)
  return vehicles[inventoryId]
end

local function sellVehicle(inventoryId, price)
  local vehicle = vehicles[inventoryId]
  if not vehicle then return end
  local value = price or career_modules_valueCalculator.getInventoryVehicleValue(inventoryId)
  extensions.hook("onBeforeVehicleSell", {inventoryId = inventoryId, price = value})
  career_modules_playerAttributes.addAttributes({money=value}, {tags={"vehicleSold","selling"}, label = {txt = "ui.career.inventory.log.soldVehicle", context = {vehicleName = vehicle.niceName or "ui.career.inventory.unnamedVehicle"}}})
  removeVehicle(inventoryId)
  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')

  if vehicle.finalBuyingPrice and value > vehicle.finalBuyingPrice then
    gameplay_achievement.unlockAchievement("FLIP_PROFIT")
  end

  career_modules_log.addLog(string.format("Sold vehicle %d for %f", inventoryId, value), "inventory")
  return true
end

local function sellVehicleFromInventory(inventoryId)
  if sellVehicle(inventoryId) then
    career_saveSystem.saveCurrent()
    sendDataToUi()
  end
end

local function returnLoanedVehicleFromInventory(inventoryId)
  career_modules_loanerVehicles.returnVehicle(inventoryId, function()
    career_saveSystem.saveCurrent()
    sendDataToUi()
  end)
end

local function expediteRepairFromInventory(inventoryId, price)
  career_modules_insurance_insurance.expediteRepair(inventoryId, price)
  career_saveSystem.saveCurrent()
  sendDataToUi()
end

local function delayVehicleAccess(inventoryId, delay, reason)
  local vehInfo = vehicles[inventoryId]
  if not vehInfo or delay <= 0 then return end
  vehInfo.timeToAccess = delay
  vehInfo.delayReason = reason
end

local function onAvailableMissionsSentToUi()
  if not currentVehicle then return end
  updatePartConditions(inventoryIdToVehId[currentVehicle], currentVehicle,
  function()
    guihooks.trigger('gameContextPlayerVehicleDamageInfo', {needsRepair = career_modules_insurance_insurance.inventoryVehNeedsRepair(currentVehicle)})
  end)
end

local function setFavoriteVehicle(inventoryId)
  if vehicles[inventoryId] then
    favoriteVehicle = inventoryId
  end
end

local function getFavoriteVehicle()
  return favoriteVehicle
end

local function onComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["vehicleInventory"] then return end

  local computerFunctionData = {
    id = "vehicleInventory",
    routeTarget = "career.computer.vehicleInventory",
    label = _tr("ui.career.shared.myVehicles"),
    callback = function() openMenuFromComputer(menuData.computerFacility.id) end,
    order = 1
  }
  if not menuData.hasBoughtStarterVehicle then
    computerFunctionData.disabled = true
    computerFunctionData.reason = career_modules_computer.reasons.hasBoughtStarterVehicle
  end
  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

local function setLicensePlateText(inventoryId, text)
  local vehId = getVehicleIdFromInventoryId(inventoryId)
  if inventoryId then
    core_vehicles.setPlateText(text, vehId)
  end
  vehicles[inventoryId].config.licenseName = text
end

local function purchaseLicensePlateText(inventoryId, text, money)
  local price = {money = {amount = money}}
  if not career_modules_payment.canPay(price) then return end
  career_modules_payment.pay(price, {label = _tr("ui.career.inventory.payment.changeLicensePlateText"), tags = {"licensePlate", "buying"}})
  setLicensePlateText(inventoryId, text)
  gameplay_achievement.unlockAchievement("NOW_ITS_MINE")
  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  setVehicleDirty(inventoryId)
end

local permissionTags = {
  notOwned = {
    vehicleSelling = "forbidden", --selling a vehicle
    vehicleRepair = "forbidden",
    interactMission = "forbidden", --use the mission POI to start a mission
    painting = "forbidden",
    partBuying = "forbidden",
    vehicleLicensePlate = "forbidden",
    tuning = "forbidden",
    vehicleStoring = "forbidden",
    partSwapping = "forbidden",
    recoveryTowToGarage = "forbidden",
    returnLoanedVehicle = "allowed",
    vehicleFavorite = "forbidden"
  }
}

local function onCheckPermission(tags, permissions, additionalData)
  if not additionalData or not additionalData.inventoryId then return end
  local vehData = vehicles[additionalData.inventoryId]
  if not vehData then return end

  for _, tag in ipairs(tags) do
    if not vehData.owned then
      if permissionTags.notOwned[tag] then
        table.insert(permissions, {permission = permissionTags.notOwned[tag]})
      end
    elseif tag == "returnLoanedVehicle" then
      table.insert(permissions, {permission = "hidden"})
    end

    if tag == "vehicleRepair" and (vehData.timeToAccess or vehData.missingFile) then
      table.insert(permissions, {permission = "forbidden"})
    end
    if tag == "vehicleSelling" and vehData.timeToAccess then
      table.insert(permissions, {permission = "forbidden"})
    end
    if tag == "vehicleFavorite" and (vehData.favorite or vehData.missingFile) then
      table.insert(permissions, {permission = "forbidden"})
    end
    if tag == "vehicleStoring" and not inventoryIdToVehId[additionalData.inventoryId] then
      table.insert(permissions, {permission = "forbidden"})
    end
  end
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if next(inventoryIdToVehId) then
    local p0Veh = getPlayerVehicle(0)
    local p0Pos = p0Veh and p0Veh.getPosition and p0Veh:getPosition()

    for invId, vehId in pairs(inventoryIdToVehId) do
      -- In Career Split-Screen, check if this vehicle is currently driven by any local player
      local isDrivenByPlayer = (be:getPlayerVehicleID(0) == vehId)
      if not isDrivenByPlayer and be.getPlayerVehicleID then
        for p = 1, 3 do
          if be:getPlayerVehicleID(p) == vehId then
            isDrivenByPlayer = true
            break
          end
        end
      end

      if not isDrivenByPlayer then -- don't display vehicles currently driven by players
        if map.objects[vehId] and map.objects[vehId].pos and vehicles[invId] then
          local desc = _tr("ui.career.inventory.bigmap.playerVehicle")
          if vehicles[invId].loanType then
            desc = _tr("ui.career.inventory.bigmap.loanedVehicle")
          end

          local id = "plVeh"..vehId
          local dist, distUnit = "", ""
          if p0Pos then
            dist, distUnit = translateDistance(map.objects[vehId].pos:distance(p0Pos), true)
          end
          local plate = vehicles[invId].config and vehicles[invId].config.licenseName or ""
          local odometer, odoUnit = translateDistance(career_modules_valueCalculator.getVehicleMileageById(invId), true)

          desc = core_locales.contextTranslate("ui.career.inventory.bigmap.description", {
            desc = desc,
            dist = dist,
            distUnit = distUnit,
            plate = plate,
            odometer = odometer,
            odoUnit = odoUnit
          })
          table.insert(elements, {
            id = id,
            data = {type = "playerVehicle", id = id},
            markerInfo = {
              bigmapMarker = {
                pos = map.objects[vehId].pos,
                icon = "vehicle_marker_outlined",
                name = core_locales.translateWithOrWithoutContext(vehicles[invId].niceName),
                description = desc,
                thumbnail = getVehicleThumbnail(invId),
                previews = {getVehicleThumbnail(invId)},
                cluster = false
              }
            }
          })
        end
      end
    end
  end
end

local function getDirtiedVehicles()
  return dirtiedVehicles
end

local function isEmpty()
  return tableIsEmpty(vehicles)
end

local function isLicensePlateValid(text)
  return core_vehicles.isLicensePlateValid(text)
end

local function isVehicleNameValid(text)
  if not text or text == "" then return false end
  return not text:find('["\\\b\f\n\r\t]')
end

local function renameVehicle(inventoryId, name)
  if not isVehicleNameValid(name) then
    log("E", "inventory", "Invalid characters in vehicle name: " .. name)
    return false
  end
  vehicles[inventoryId].niceName = name
  setVehicleDirty(inventoryId)
  return true
end

local function debugRespawnCurrentVehicle()
  local inventoryId = getCurrentVehicle()
  if not inventoryId then return end

  career_modules_inventory.updatePartConditions(nil, inventoryId, function()
    spawnVehicle(inventoryId, 2)
  end)
end

M.addVehicle = addVehicle
M.removeVehicle = removeVehicle
M.enterVehicle = enterVehicle
M.sellVehicle = sellVehicle
M.sellVehicleFromInventory = sellVehicleFromInventory
M.returnLoanedVehicleFromInventory = returnLoanedVehicleFromInventory
M.expediteRepairFromInventory = expediteRepairFromInventory
M.updatePartConditions = updatePartConditions
M.updatePartConditionsOfSpawnedVehicles = updatePartConditionsOfSpawnedVehicles
M.removeVehicleObject = removeVehicleObject
M.openMenu = openMenu
M.closeMenu = closeMenu
M.requestPickerExit = requestPickerExit
M.openMenuFromComputer = openMenuFromComputer
M.chooseVehicleFromMenu = chooseVehicleFromMenu
M.delayVehicleAccess = delayVehicleAccess
M.hasFreeSlot = hasFreeSlot
M.getNumberOfFreeSlots = getNumberOfFreeSlots
M.setFavoriteVehicle = setFavoriteVehicle
M.getFavoriteVehicle = getFavoriteVehicle
M.sendDataToUi = sendDataToUi
M.setLicensePlateText = setLicensePlateText
M.purchaseLicensePlateText = purchaseLicensePlateText
M.getVehicleThumbnail = getVehicleThumbnail
M.renameVehicle = renameVehicle
M.isLicensePlateValid = isLicensePlateValid
M.isVehicleNameValid = isVehicleNameValid
M.onExtensionLoaded = onExtensionLoaded
M.onSaveCurrentProfile = onSaveCurrentProfile
M.onBigMapActivated = onBigMapActivated
M.onUpdate = onUpdate
M.onBeforeWalkingModeToggled = onBeforeWalkingModeToggled
M.onCareerActive = onCareerActive
M.onEnterVehicleFinished = onEnterVehicleFinished
M.onExitVehicleInventory = onExitVehicleInventory
M.onScreenFadeState = onScreenFadeState
M.onAvailableMissionsSentToUi = onAvailableMissionsSentToUi
M.onComputerAddFunctions = onComputerAddFunctions
M.onSaveCurrentProfileAsyncStart = onSaveCurrentProfileAsyncStart
M.onCheckPermission = onCheckPermission
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.openInventoryMenuForChoosingListing = openInventoryMenuForChoosingListing
M.getVehicleNiceNameTranslated = getVehicleNiceNameTranslated

M.getPartConditionsCallback = getPartConditionsCallback
M.applyPartConditions = applyPartConditions
M.teleportedFromBigmap = teleportedFromBigmap
M.setVehicleDirty = setVehicleDirty
M.getDirtiedVehicles = getDirtiedVehicles
M.getVehicles = getVehicles
M.getVehicle = getVehicle
M.isEmpty = isEmpty
M.spawnVehicle = spawnVehicle
M.getInventoryIdsInClosestGarage = getInventoryIdsInClosestGarage
M.getClosestGarage = getClosestGarage
M.isSeatedInsideOwnedVehicle = isSeatedInsideOwnedVehicle

-- Debug
M.getCurrentVehicle = getCurrentVehicle
M.getCurrentVehicleId = getCurrentVehicleId
M.getLastVehicle = getLastVehicle
M.getVehicleIdFromInventoryId = getVehicleIdFromInventoryId
M.getInventoryIdFromVehicleId = getInventoryIdFromVehicleId
M.getMapInventoryIdToVehId = getMapInventoryIdToVehId
M.debugRespawnCurrentVehicle = debugRespawnCurrentVehicle

M.getVehicleUiData = getVehicleUiData

return M
