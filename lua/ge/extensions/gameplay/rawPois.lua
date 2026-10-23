-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M._careerSplitScreenMod = true

local rawPoiGeneration = 0
local rawPoiListByLevel = {}
local rawPoiMultiseatActive

local function clear()
  rawPoiListByLevel = {}
  rawPoiGeneration = rawPoiGeneration + 1
  log("D","","Raw Poi Lists Cleared. New Generation: " .. rawPoiGeneration)
end

local function isCareerModeActive()
  return (career_career and career_career.isActive and career_career.isActive())
    or (overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive())
    or (core_gamestate and core_gamestate.state and (core_gamestate.state.state == "career" or core_gamestate.state.state == "overhaul"))
end

local function isMultiseatActive()
  -- Never filter out POIs or markers in split screen; all garages, missions, and POIs remain visible
  return false
end

local function syncMultiseatState()
  local active = isMultiseatActive()
  if rawPoiMultiseatActive == nil then
    rawPoiMultiseatActive = active
  elseif rawPoiMultiseatActive ~= active then
    rawPoiMultiseatActive = active
    clear()
  end
  return active
end

local function filterMultiseatPois(elementsUnchecked)
  local elements = {}
  for _, element in ipairs(elementsUnchecked) do
    local markerInfo
    for markerType, markerData in pairs(element.markerInfo or {}) do
      if type(markerData) == "table" and markerData.multiseat == true then
        markerInfo = markerInfo or {}
        markerInfo[markerType] = markerData
      end
    end
    if markerInfo then
      local filteredElement = shallowcopy(element)
      filteredElement.markerInfo = markerInfo
      table.insert(elements, filteredElement)
    end
  end
  return elements
end

local function validateRawPoiElement(element)
  local valid = true
  if not element.data then
    log("E","","Element does not contain a data field! Not keeping it in the element list.")
    dumpz(element,2)
    valid = false
  end
  if element.data and not (element.data.id or element.data.missionId) then
    log("E","","Element.data does not contain neither id nor missionId! Not keeping it in the element list.")
    dumpz(element,2)
    valid = false
  end
  if not element.clusterType then
    log("E","","Element has no clusterType! Not keeping it in the element list.")
    dumpz(element,2)
  end
  return valid
end

local whiteListIds = {}

local function getRawPoiListByLevel(levelIdentifier)
  if not levelIdentifier then
    return {}, rawPoiGeneration
  end
  local multiseatActive = syncMultiseatState()

  if multiseatActive then
    if not rawPoiListByLevel[levelIdentifier] then
      local elementsUnchecked = {}
      extensions.hook("onGetRawPoiListForLevel", levelIdentifier, elementsUnchecked)
      rawPoiListByLevel[levelIdentifier] = filterMultiseatPois(elementsUnchecked)
    end
    return rawPoiListByLevel[levelIdentifier], rawPoiGeneration
  end

  -- when in the tutorial, only add the desired elements
  if career_career and career_career.isActive and career_career.isActive() and levelIdentifier == "west_coast_usa" then


    if career_modules_tutorial.isActive() then
      local elements = {}
      extensions.hook("onGetRawPoiListForTutorial", elements)
      rawPoiListByLevel[levelIdentifier] = elements
      return rawPoiListByLevel[levelIdentifier], rawPoiGeneration
    end

    -- only show dealership when car not bought
    if not career_career.hasBoughtStarterVehicle() then
      local elementsUnchecked, elements = {}, {}
      -- call all extensions to add their POIs
      extensions.hook("onGetRawPoiListForLevel",levelIdentifier, elementsUnchecked)

      -- filter only the POIS that are dealerships, inspect vehicle or computers
      local allowedDataTypes = {
        dealership = true,
        inspectVehicle = true,
        computer = true,
      }
      for _, e in ipairs(elementsUnchecked) do
        if e.data and allowedDataTypes[e.data.type] then
          table.insert(elements, e)
        end
      end

      return elements, rawPoiGeneration
    end
  end

  -- otherwise create poi list as usual
  if not rawPoiListByLevel[levelIdentifier] then
    local elementsUnchecked, elements = {}, {}
    -- call all extensions to add their POIs
    extensions.hook("onGetRawPoiListForLevel",levelIdentifier, elementsUnchecked)

    local testDriveActive = career_modules_testDrive and career_modules_testDrive.isActive()
    local deliveryActive = gameplay_freeformDelivery_freeformDelivery and gameplay_freeformDelivery_freeformDelivery.isLoaded()
    local allowedDataTypes = {}
    local keepEmptyAllowedDataTypes = false
    if testDriveActive then
      allowedDataTypes.testDriveEnd = true
    end
    if deliveryActive then
      allowedDataTypes.deliveryTargetArea = true
      allowedDataTypes.deliveryVehicle = true
    end
    table.clear(whiteListIds)
    if gameplay_discover_freeroamTutorial_tutorial then
      allowedDataTypes.tutorialLesson = true
      if gameplay_discover_freeroamTutorial_tutorial.getActivePhase() == 'missions' then
        whiteListIds['industrial/timeTrial/008-Sprint'] = true
      end
    end
    if gameplay_discover_firstDrive_experience and gameplay_discover_firstDrive_experience.hidesWorldPois and gameplay_discover_firstDrive_experience.hidesWorldPois() then
      if gameplay_discover_firstDrive_experience.isGuidedDriveActive() then
        table.clear(allowedDataTypes)
        table.clear(whiteListIds)
        keepEmptyAllowedDataTypes = false
        allowedDataTypes.firstDriveDestination = true
      else
        local missionLessonActive = gameplay_discover_firstDrive_learningFlow
          and gameplay_discover_firstDrive_learningFlow.isLessonActive("missions")
        if missionLessonActive then
          keepEmptyAllowedDataTypes = true
          local missionId = gameplay_discover_firstDrive_learningFlow.getLessonMissionId("missions")
          if missionId then whiteListIds[missionId] = true end
        else
          allowedDataTypes.firstDriveLearningLesson = true
          allowedDataTypes.spawnPoint = true
          allowedDataTypes.gasStation = true
        end
      end
    end
    if not next(allowedDataTypes) and not keepEmptyAllowedDataTypes then allowedDataTypes = nil end
    for _, e in ipairs(elementsUnchecked) do
      -- sanity check

      -- make clustering true by default
      if e.markerInfo.bigmapMarker and e.markerInfo.bigmapMarker.cluster == nil then
        e.markerInfo.bigmapMarker.cluster = true
      end

      -- Only include POIs if a test drive is not active, or if this POI is the testDriveEnd type
      local dataType = e.data and e.data.type
      local whitelisted = whiteListIds and (whiteListIds[e.id] or whiteListIds[e.data and e.data.missionId])
      if not allowedDataTypes or (allowedDataTypes and allowedDataTypes[dataType]) or whitelisted then
        table.insert(elements, e)
      end
    end
    rawPoiListByLevel[levelIdentifier] = elements
  end
  return rawPoiListByLevel[levelIdentifier], rawPoiGeneration
end

M.getRawPoiGeneration = function()
  syncMultiseatState()
  return rawPoiGeneration
end
M.getRawPoiListByLevel = getRawPoiListByLevel
M.clear = clear
M.showMissionMarkersToggled = M.clear
M.onModManagerReady = M.clear
return M
