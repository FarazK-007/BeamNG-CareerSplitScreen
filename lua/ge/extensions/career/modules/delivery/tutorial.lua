-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
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


-- Tutorial status cache
local tutorialStatusCache = {}
M.isCargoDeliveryTutorialActive = function()
  if tutorialStatusCache['logistics-delivery'] == nil then
    tutorialStatusCache['logistics-delivery'] = career_branches.getBranchXP("logistics-delivery") == 0
  end
  return tutorialStatusCache['logistics-delivery']
end

M.isVehicleDeliveryTutorialActive = function()
  if tutorialStatusCache['logistics-vehicleDelivery'] == nil then
    tutorialStatusCache['logistics-vehicleDelivery'] = career_branches.getBranchXP("logistics-vehicleDelivery") == 0
  end
  return tutorialStatusCache['logistics-vehicleDelivery']
end

M.isMaterialsDeliveryTutorialActive = function()
  if tutorialStatusCache['logistics-materials'] == nil then
    tutorialStatusCache['logistics-materials'] = career_branches.getBranchXP("logistics-materials") == 0
  end
  return tutorialStatusCache['logistics-materials']
end

M.onPlayerAttributesChanged = function(change, reason)
  -- Clear tutorial status cache when delivery branch XP changes
  if change["logistics-delivery"] then
    tutorialStatusCache['logistics-delivery'] = nil
    gameplay_achievement.unlockAchievement("DELIVERY_TUTORIAL_COMPLETED")
  end
  if change["logistics-vehicleDelivery"] then
    tutorialStatusCache['logistics-vehicleDelivery'] = nil
    gameplay_achievement.unlockAchievement("VEHICLE_DELIVERY_COMPLETED")
  end
  if change["logistics-materials"] then
    tutorialStatusCache['logistics-materials'] = nil
    gameplay_achievement.unlockAchievement("MATERIALS_DELIVERY_COMPLETED")
  end
end


local maxDistance = 20
local function currentOrNearbyVehicleHasContainer(type)
  local playerVehId = be:getPlayerVehicleID(0)
  local playerPosition = getPlayerVehicle(0) and getPlayerVehicle(0):getPosition() or core_camera.getPosition()

  local p2Veh = (careerSplitScreen and careerSplitScreen.getP2Vehicle and careerSplitScreen.getP2Vehicle()) or getPlayerVehicle(1)
  local p2VehId = p2Veh and p2Veh:getId()
  local p2Position = p2Veh and p2Veh:getPosition()

  local containers = dGeneral.getMostRecentCargoContainerData()
  for _, container in ipairs(containers) do
    local dist0 = (container.position - playerPosition):length()
    local dist1 = p2Position and (container.position - p2Position):length() or 999999
    local isAttached = container.attachmentStatus == "attached"
    local typeMatch = (type == nil or container.cargoTypesLookup[type])
    if ((container.vehId == playerVehId or dist0 <= maxDistance) or (p2VehId and (container.vehId == p2VehId or dist1 <= maxDistance))) and isAttached and typeMatch then
      return true
    end
  end

  return false
end

local function currentVehicleHasTutorialCargo()
  local playerVehId = be:getPlayerVehicleID(0)
  local p2Veh = (careerSplitScreen and careerSplitScreen.getP2Vehicle and careerSplitScreen.getP2Vehicle()) or getPlayerVehicle(1)
  local p2VehId = p2Veh and p2Veh:getId()

  local playerCargo = dParcelManager.getAllCargoInVehicles(true)
  for _, cargo in ipairs(playerCargo) do
    if cargo.location.vehId == playerVehId or (p2VehId and cargo.location.vehId == p2VehId) then
      local template = dGenerator.getParcelTemplateById(cargo.templateId)
      if template and template.isTutorialParcel then
        return true
      end
    end
  end

  return false
end

local function tutorialVehicleTakenOutOfFacility()
  local playerVehId = be:getPlayerVehicleID(0)
  local p2Veh = (careerSplitScreen and careerSplitScreen.getP2Vehicle and careerSplitScreen.getP2Vehicle()) or getPlayerVehicle(1)
  local p2VehId = p2Veh and p2Veh:getId()
  if not playerVehId and not p2VehId then return false end

  -- Check if current vehicle is a tutorial vehicle
  local vehicleTasks = dVehicleTasks.getVehicleTasks()
  for _, task in ipairs(vehicleTasks) do
    if task.offer and task.offer.data and task.offer.data.isTutorialVehicle then
      return true
    end
  end

  return false
end

local function currentVehicleHasDryBulkContainer() return false end
local function currentVehicleHasTutorialMaterials() return false end

M.getTutorialInfo = function()
  local tutorialInfo = {
    parcel = {
      unlocked = true,
      isActive = M.isCargoDeliveryTutorialActive(),
      tasks = {},
    },
    vehicle = {
      unlocked = career_branches.getBranchByPath("logistics-vehicleDelivery").unlocked,
      isActive = M.isVehicleDeliveryTutorialActive(),
      tasks = {},
    },
  }
  M.onCareerProgressPageGetTasklistData(tutorialInfo.parcel, "delivery-introduction")
  M.onCareerProgressPageGetTasklistData(tutorialInfo.vehicle, "vehicle-delivery-introduction")
  return tutorialInfo
end

M.onCareerProgressPageGetTasklistData = function(tasklistData, tasklistId)
  if tasklistId == "delivery-introduction" then
    local allFinished = not M.isCargoDeliveryTutorialActive()
    tasklistData.headerLabel = "Delivery Introduction"
    if allFinished then
      tasklistData.tasks = {
        {
          label = _tr("ui.career.delivery.tutorial.cargo.completedLabel"),
          description = _tr("ui.career.delivery.tutorial.cargo.completedDescription"),
          done = true
        },
      }
    else
      tasklistData.tasks = {
        {
          label = _tr("ui.career.delivery.tutorial.cargo.installContainerLabel"),
          description = _tr("ui.career.delivery.tutorial.installContainerDescription"),
          done = allFinished or currentOrNearbyVehicleHasContainer("parcel")
        },
        {
          label = _tr("ui.career.delivery.tutorial.cargo.loadPackageLabel"),
          description = _tr("ui.career.delivery.tutorial.cargo.loadPackageDescription"),
          done = allFinished or currentVehicleHasTutorialCargo(),
        },
        {
          label = _tr("ui.career.delivery.tutorial.cargo.deliverLabel"),
          description = _tr("ui.career.delivery.tutorial.cargo.deliverDescription"),
          done = allFinished,
        },
      }
    end
  end
  if tasklistId == "vehicle-delivery-introduction" then
    local allFinished = not M.isVehicleDeliveryTutorialActive()
    tasklistData.headerLabel = "Vehicle Delivery Introduction"
    if allFinished then
      tasklistData.tasks = {
        {
          label = _tr("ui.career.delivery.tutorial.vehicle.completedLabel"),
          description = _tr("ui.career.delivery.tutorial.vehicle.completedDescription"),
          done = true
        },
      }
    else
      tasklistData.tasks = {
        {
          label = _tr("ui.career.delivery.tutorial.vehicle.retrieveVehicleLabel"),
          description = _tr("ui.career.delivery.tutorial.vehicle.retrieveVehicleDescription"),
          done = allFinished or tutorialVehicleTakenOutOfFacility(),
        },
        {
          label = _tr("ui.career.delivery.tutorial.vehicle.deliverLabel"),
          description = _tr("ui.career.delivery.tutorial.vehicle.deliverDescription"),
          done = allFinished,
        },
      }
    end
  end
  if tasklistId == "materials-introduction" then
    local allFinished = not M.isMaterialsDeliveryTutorialActive()
    tasklistData.headerLabel = "Materials Introduction"
    if allFinished then
      tasklistData.tasks = {
        {
          label = _tr("ui.career.delivery.tutorial.materials.completedLabel"),
          description = _tr("ui.career.delivery.tutorial.materials.completedDescription"),
          done = true
        },
      }
    else
      tasklistData.tasks = {
        {
          label = _tr("ui.career.delivery.tutorial.materials.installContainerLabel"),
          description = _tr("ui.career.delivery.tutorial.installContainerDescription"),
          done = allFinished or currentOrNearbyVehicleHasContainer("dryBulk"),
        },
        {
          label = _tr("ui.career.delivery.tutorial.materials.loadMaterialsLabel"),
          description = _tr("ui.career.delivery.tutorial.materials.loadMaterialsDescription"),
          done = allFinished or currentVehicleHasTutorialMaterials(),
        },
        {
          label = _tr("ui.career.delivery.tutorial.materials.deliverLabel"),
          description = _tr("ui.career.delivery.tutorial.materials.deliverDescription"),
          done = allFinished,
        },
      }
    end
  end
end



return M