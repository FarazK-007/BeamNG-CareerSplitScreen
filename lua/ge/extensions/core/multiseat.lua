-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

require("utils")
local M = {}
M._careerSplitScreenMod = true
M.allowTrafficDebug = false

M.dependencies = {
  "core_playerPersonas",
  "render_playerTags",
  "ui_multiseat_assignmentCache",
}

local multiseatActive = false

local maxPlayers = 64 -- TODO hardcoded, should be same as steering fastpath limit in t3d side
local debugMockPlatformUsers = false

local activePlayers = {0}
local lastDevices = {}
local lastAssignedPlayers = {}
local manuallyAssignedPlayers = {}
local knownManualDevices = {}
local platformDeviceGroupPlayers = {}
local knownPlatformDeviceGroups = {}
local mockPlatformDeviceGroupIds = {}
local nextMockPlatformDeviceGroupId = 1
local lastAssignmentSignature = ""
local joinedPlayers = {}

local function isCareerModeActive()
  return (career_career and career_career.isActive and career_career.isActive())
    or (overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive())
    or (core_gamestate and core_gamestate.state and (core_gamestate.state.state == "career" or core_gamestate.state.state == "overhaul"))
end
local joinedByPlayer = {}
local personaOptInMode = false
local participantRevision = 0
local taggedRevision = nil
local coloredRevision = nil
local deviceColorsApplied = false
local devicePreviewActive = false
local applyingConfiguration = false
local configurationEditActive = false
local configurationNotificationPending = false
local pendingCachedPlayerAssignments = nil
local emitParticipantsChanged
local syncJoinedPlayers
local syncAutomaticPersonas
local normalizePlayerAssignments
local isPlatformManagingPlayers
local rememberPlatformDeviceGroups

local function getPlayerMarkersEnabled()
  local enabled = settings.getValue("multiseatTags", true)
  if type(enabled) ~= "boolean" then
    enabled = enabled ~= "never"
    settings.setValue("multiseatTags", enabled)
  end
  return enabled
end

local function setPlayerMarkersEnabled(enabled)
  settings.setValue("multiseatTags", not not enabled)
end

local function getParticipantRevision()
  return participantRevision + extensions.core_playerPersonas.getRevision()
end

local function assignmentSignature(devices, assignedPlayers)
  local parts = {}
  for _, devname in ipairs(tableKeysSorted(assignedPlayers)) do
    local info = devices and devices[devname]
    parts[#parts + 1] = string.format("%s=%s@%s", devname, tostring(assignedPlayers[devname]), tostring(info and info[2] or ""))
  end
  return table.concat(parts, ";")
end

local function updateActivePlayers(devices, assignedPlayers)
  local lookup = {}
  for _, player in pairs(assignedPlayers) do
    if player ~= nil and player >= 0 then lookup[player] = true end
  end
  if multiseatActive then
    for _, entry in ipairs(joinedPlayers) do lookup[entry.playerIndex] = true end
  end
  if (extensions.isExtensionLoaded("careerSplitScreen") and (careerSplitScreen.isSplitModeActive and careerSplitScreen.isSplitModeActive() or careerSplitScreen.isActive and careerSplitScreen.isActive()))
     or (extensions.isExtensionLoaded("render_splitScreen") and render_splitScreen.isEnabled and render_splitScreen.isEnabled()) then
    lookup[0] = true
    lookup[1] = true
  end
  if not next(lookup) and not settings.getValue("multiseat") then lookup[0] = true end

  local players = tableKeys(lookup)
  table.sort(players)

  local signature = assignmentSignature(devices, assignedPlayers)

  activePlayers = players
  lastDevices = devices or (core_input_bindings and core_input_bindings.devices) or {}
  lastAssignedPlayers = shallowcopy(assignedPlayers)
  local rosterChanged = syncJoinedPlayers and syncJoinedPlayers() or false
  if syncAutomaticPersonas and not personaOptInMode then
    rosterChanged = syncAutomaticPersonas(settings.getValue("multiseat")) or rosterChanged
  end
  if signature ~= lastAssignmentSignature or rosterChanged then
    lastAssignmentSignature = signature
    participantRevision = participantRevision + 1
    taggedRevision = nil
    coloredRevision = nil
    if emitParticipantsChanged then emitParticipantsChanged() end
  end
end

-- returns a list of currently active vehicles, excluding autonomous traffic and parked vehicles
local function getActiveVehicles()
  local res = {}
  for _, veh in activeVehiclesIterator() do
    if not veh.isTraffic and not veh.isParked then
      table.insert(res, veh)
    end
  end
  return res
end

-- returns a list of which player is controlling each input device
-- e.g. { "keyboard": 0, "xinput0": 1, "mouse": 0 }
local lastMultiseat = false
isPlatformManagingPlayers = function()
  return debugMockPlatformUsers or Input.getPlatformUserCount and Input.getPlatformUserCount() ~= nil
end

local function getMockPlatformUserNumber(devname, devices)
  local platformUserNumber = tonumber(devices[devname] and devices[devname][5])
  if platformUserNumber ~= nil then return platformUserNumber end
  local mockGroupKey = (devname:startswith("keyboard") or devname:startswith("mouse"))
    and "keyboard-mouse" or devname
  if mockPlatformDeviceGroupIds[mockGroupKey] == nil then
    local usedGroupIds = {}
    for _, info in pairs(devices) do
      local groupId = tonumber(info and info[5])
      if groupId ~= nil then usedGroupIds[groupId] = true end
    end
    for _, groupId in pairs(mockPlatformDeviceGroupIds) do usedGroupIds[groupId] = true end
    while usedGroupIds[nextMockPlatformDeviceGroupId] do
      nextMockPlatformDeviceGroupId = nextMockPlatformDeviceGroupId + 1
    end
    mockPlatformDeviceGroupIds[mockGroupKey] = nextMockPlatformDeviceGroupId
    nextMockPlatformDeviceGroupId = nextMockPlatformDeviceGroupId + 1
  end
  return mockPlatformDeviceGroupIds[mockGroupKey]
end

local function getDeviceGroupId(devname, devices)
  if debugMockPlatformUsers then return getMockPlatformUserNumber(devname, devices) end
  return tonumber(devices[devname] and devices[devname][5]) or 0
end

local function deviceType(devname)
  return string.split(devname or "", "%D+")[1] or devname or ""
end

local function deviceMetadata(devname, info)
  info = info or {}
  return {
    id = devname,
    guid = info[1],
    productName = info[2],
    pidvid = info[3],
    playerNumber = info[4],
    platformUserNumber = info[5],
    deviceType = deviceType(devname),
  }
end

local function deviceInfo(metadata)
  return {
    metadata.guid,
    metadata.productName,
    metadata.pidvid,
    metadata.playerNumber,
    metadata.platformUserNumber,
  }
end

local function rememberManualDevices(devices)
  for devname, player in pairs(manuallyAssignedPlayers) do
    if player ~= nil and player >= 0 and devices and devices[devname] then
      knownManualDevices[devname] = deviceMetadata(devname, devices[devname])
    elseif player == nil or player < 0 then
      knownManualDevices[devname] = nil
    end
  end
  for devname in pairs(knownManualDevices) do
    local player = manuallyAssignedPlayers[devname]
    if player == nil or player < 0 then knownManualDevices[devname] = nil end
  end
end

local function getManualDeviceInventory()
  local devices = {}
  for devname, metadata in pairs(knownManualDevices) do
    local player = manuallyAssignedPlayers[devname]
    if player ~= nil and player >= 0 then devices[devname] = deviceInfo(metadata) end
  end
  for devname, info in pairs(lastDevices) do devices[devname] = info end
  return devices
end

local function getAssignedPlayers(devices, logEnabled, seatPlayers)
  if configurationEditActive and not applyingConfiguration then
    local stagedSafeAssignments = {}
    for devname in pairs(devices or {}) do
      local player
      if isPlatformManagingPlayers() then
        player = platformDeviceGroupPlayers[getDeviceGroupId(devname, devices)]
      else
        player = lastAssignedPlayers[devname]
        if player == nil then player = manuallyAssignedPlayers[devname] end
      end
      stagedSafeAssignments[devname] = player ~= nil and player or -1
      assignPlayerToDevice(devname, stagedSafeAssignments[devname])
    end
    if isPlatformManagingPlayers() and rememberPlatformDeviceGroups then
      rememberPlatformDeviceGroups(devices)
    end
    return stagedSafeAssignments
  end
  -- push/pop the multiseat actionmap
  local multiseat = settings.getValue("multiseat")
  local changed = multiseat ~= lastMultiseat
  if changed then
    local o = scenetree.findObject("MultiseatActionMap")
    if o then
      if multiseat then o:setEnabled(true)
      else o:setEnabled(false) end
    else
      log("E", "", "No multiseat action map found")
    end
  end
  lastMultiseat = multiseat

  -- platform groups opt in separately
  local nVehicles = #getActiveVehicles()
  local nControllers = tableSize(devices) - 1 -- assume mouse goes together with keyboard
  local players = 1
  local devnames = tableKeys(devices)
  table.sort(devnames)
  local platformManagesPlayers = isPlatformManagingPlayers()
  if multiseat and not platformManagesPlayers then
    rememberManualDevices(lastDevices)
    rememberManualDevices(devices)
  elseif multiseat and rememberPlatformDeviceGroups then
    rememberPlatformDeviceGroups(devices)
  end
  local result = {}
  for _, devname in ipairs(devnames) do
    local player = 0
    if multiseat and platformManagesPlayers then
      player = platformDeviceGroupPlayers[getDeviceGroupId(devname, devices)] or -1
    elseif multiseat then
      player = manuallyAssignedPlayers[devname] or (core_input_bindings and core_input_bindings.assignedPlayers and core_input_bindings.assignedPlayers[devname]) or -1
    end
    result[devname] = player
  end
  if multiseat and normalizePlayerAssignments then
    result = normalizePlayerAssignments(devices, result, not personaOptInMode)
  end
  for devname, player in pairs(result) do
    assignPlayerToDevice(devname, player)
  end
  local assignedPlayerLookup = {}
  for _, player in pairs(result) do
    if player >= 0 then assignedPlayerLookup[player] = true end
  end
  players = tableSize(assignedPlayerLookup)
  if logEnabled and players > 1 then log("D", "multiseat", "Settled for "..players.." players:  supported="..maxPlayers..", vehicles="..nVehicles..", devices="..nControllers.." (& mouse)") end
  updateActivePlayers(devices, result)
  if logEnabled and players > 1 then log((players>1) and "I" or "D", "", "Assigned players: "..dumps(result):gsub("\n", ""):gsub("  ", " ")) end

  -- re-seat all players in vehicles when requested
  local potentialSeatChanges = changed or multiseat -- skip re-seating players when there's no chance they'll end in a different car
  if isCareerModeActive() or (extensions.isExtensionLoaded("careerSplitScreen") and (careerSplitScreen.isSplitModeActive and careerSplitScreen.isSplitModeActive() or careerSplitScreen.isActive and careerSplitScreen.isActive())) then
    seatPlayers = false
  end
  if potentialSeatChanges and seatPlayers then
    -- locate all usable vehicles
    local usedVehicles = {}
    for _, vehicle in ipairs(getActiveVehicles()) do
      usedVehicles[vehicle:getID()] = 0
    end
    -- count amount of seats used on each vehicle
    for _, player in ipairs(activePlayers) do
      local veh = getPlayerVehicle(player)
      if veh then
        local id = veh:getId()
        if usedVehicles[id] ~= nil then
          usedVehicles[id] = usedVehicles[id] + 1
        end
      end
    end
    -- assign players on foot to vehicles (favour the least occupied vehicles)
    local activeLookup = tableValuesAsLookupDict(multiseat and activePlayers or {0})
    for player=0, maxPlayers-1 do
      if not activeLookup[player] then
        be:exitVehicle(player)
      else
        local veh = getPlayerVehicle(player)
        if not veh then -- player has no vehicle, is on foot
          -- locate least occupied vehicle
          local leastUsedId = nil
          local leastUsedN = math.huge
          for id,n in pairs(usedVehicles) do
            if n < leastUsedN then
              leastUsedId = id
              leastUsedN = n
            end
          end
          -- seat this player in the vehicle we found
          if leastUsedId then
            local vehicle = getObjectByID(leastUsedId)
            be:enterVehicle(player, vehicle)
            -- update vehicle occupation counters
            usedVehicles[leastUsedId] = usedVehicles[leastUsedId] + 1
          end
        end
      end
    end
  end
  return result
end

-- ordered list of player indices currently exposed by the input assignment layer
local function getPlayers(result)
  result = result or {}
  table.clear(result)
  for index, player in ipairs(activePlayers) do
    result[index] = player
  end
  return result
end

local function translateDeviceName(name)
  if not name or name == "" then return nil end
  if core_locales and core_locales.translate then return core_locales.translate(name, name) end
  return name
end

local function getPlatformDevicesByPlayer()
  local result = {}
  for groupId, player in pairs(platformDeviceGroupPlayers) do
    if player ~= nil and player >= 0 then
      local playerDevices = {}
      local seen = {}
      local knownGroup = knownPlatformDeviceGroups[groupId]
      for _, device in ipairs(knownGroup and knownGroup.devices or {}) do
        local info = lastDevices[device.id]
        playerDevices[#playerDevices + 1] = {
          id = device.id,
          productName = translateDeviceName(info and info[2] or device.label or device.id),
          controllerIndex = tonumber(string.match(device.id, "(%d+)$")),
          connected = info ~= nil,
          metadata = info and deviceMetadata(device.id, info)
            or (device.metadata and deepcopy(device.metadata) or nil),
        }
        seen[device.id] = true
      end
      for devname, info in pairs(lastDevices) do
        if getDeviceGroupId(devname, lastDevices) == groupId and not seen[devname] then
          playerDevices[#playerDevices + 1] = {
            id = devname,
            productName = translateDeviceName(info[2] or devname),
            controllerIndex = tonumber(string.match(devname, "(%d+)$")),
            connected = true,
            metadata = deviceMetadata(devname, info),
          }
        end
      end
      table.sort(playerDevices, function(a, b) return a.id < b.id end)
      result[player] = playerDevices
    end
  end
  return result
end

local function getDevicesByPlayer(devices, assignedPlayers)
  if devices == nil and assignedPlayers == nil and multiseatActive then
    if isPlatformManagingPlayers() then
      return getPlatformDevicesByPlayer()
    end
    devices = getManualDeviceInventory()
    assignedPlayers = manuallyAssignedPlayers
  else
    devices = devices or lastDevices
    assignedPlayers = assignedPlayers or lastAssignedPlayers
  end

  local effectiveDevices = shallowcopy(devices or {})
  if core_input_bindings and core_input_bindings.devices then
    for devname, info in pairs(core_input_bindings.devices) do
      if effectiveDevices[devname] == nil then
        effectiveDevices[devname] = info
      end
    end
  end
  devices = effectiveDevices

  local effectiveAssigned = shallowcopy(assignedPlayers or {})
  if core_input_bindings and core_input_bindings.assignedPlayers then
    for devname, plyr in pairs(core_input_bindings.assignedPlayers) do
      if effectiveAssigned[devname] == nil and plyr ~= nil and plyr >= 0 then
        effectiveAssigned[devname] = plyr
      end
    end
  end
  assignedPlayers = effectiveAssigned

  local result = {}
  for devname, player in pairs(assignedPlayers) do
    if player ~= nil and player >= 0 then
      local info = devices[devname]
      local productName = info and info[2]
      if (not productName or productName == "") and Input and Input.getProductName then
        productName = Input.getProductName(devname)
      end
      local isConnected = (devices and devices[devname] ~= nil)
        or (lastDevices and lastDevices[devname] ~= nil)
        or (core_input_bindings and core_input_bindings.devices and core_input_bindings.devices[devname] ~= nil)

      result[player] = result[player] or {}
      result[player][#result[player] + 1] = {
        id = devname,
        productName = translateDeviceName(productName or devname),
        controllerIndex = tonumber(string.match(devname, "(%d+)$")),
        connected = isConnected,
        metadata = deviceMetadata(devname, info),
      }
    end
  end
  for _, devs in pairs(result) do
    table.sort(devs, function(a, b) return a.id < b.id end)
  end
  return result
end

local function getDeviceAssignmentsFor(devices, assignedPlayers, connectedDevices)
  devices = devices or {}
  assignedPlayers = assignedPlayers or {}
  local result = {}
  local keyboardMouse
  for _, devname in ipairs(tableKeysSorted(devices)) do
    local player = assignedPlayers[devname] or -1
    if player ~= nil then
      local info = devices[devname]
      local metadata = deviceMetadata(devname, info)
      local connected = connectedDevices == nil or connectedDevices[devname] ~= nil
      local productName = info and info[2]
      if (not productName or productName == "") and Input and Input.getProductName then
        productName = Input.getProductName(devname)
      end

      if devname:startswith("keyboard") or devname:startswith("mouse") then
        if not keyboardMouse then
          keyboardMouse = {
            id = "keyboard-mouse",
            deviceIds = {},
            primaryDeviceId = devname,
            deviceLabel = _tr("ui.experiences.splitscreen.keyboardMouse"),
            inputIcon = "keyboard",
            playerIndex = player,
            connected = false,
            deviceMetadata = {},
          }
          result[#result + 1] = keyboardMouse
        end
        keyboardMouse.deviceIds[#keyboardMouse.deviceIds + 1] = devname
        keyboardMouse.deviceMetadata[#keyboardMouse.deviceMetadata + 1] = metadata
        keyboardMouse.connected = keyboardMouse.connected or connected
        if devname:startswith("keyboard") then
          keyboardMouse.primaryDeviceId = devname
          keyboardMouse.playerIndex = player
        end
      else
        result[#result + 1] = {
          id = devname,
          deviceIds = {devname},
          primaryDeviceId = devname,
          deviceLabel = translateDeviceName(productName or devname),
          inputIcon = "gamepad",
          playerIndex = player,
          connected = connected,
          deviceMetadata = {metadata},
        }
      end
    end
  end
  table.sort(result, function(a, b)
    local aIsKeyboardMouse = a.id == "keyboard-mouse"
    local bIsKeyboardMouse = b.id == "keyboard-mouse"
    if aIsKeyboardMouse ~= bIsKeyboardMouse then return aIsKeyboardMouse end
    return a.id < b.id
  end)
  return result
end

local function getDeviceAssignments()
  local devices = getManualDeviceInventory()
  local assignments = {}
  for devname in pairs(devices) do
    assignments[devname] = manuallyAssignedPlayers[devname] or -1
  end
  return getDeviceAssignmentsFor(devices, assignments, lastDevices)
end

local function getPlatformUserInfos(devices)
  if not debugMockPlatformUsers then
    return Input and Input.getPlatformUserInfos and Input.getPlatformUserInfos() or {}
  end

  local groupIds = {}
  for devname in pairs(devices) do groupIds[getDeviceGroupId(devname, devices)] = true end

  local result = {}
  for _, groupId in ipairs(tableKeysSorted(groupIds)) do
    result[#result + 1] = {
      platformUserNumber = groupId,
      userName = "Mock Platform User " .. groupId,
    }
  end
  return result
end

local function getDeviceGroupsFor(devices, groupAssignments)
  devices = devices or {}
  groupAssignments = groupAssignments or {}
  local platformUserInfos = getPlatformUserInfos(devices)
  local platformUserInfosByNumber = {}
  for _, platformUserInfo in pairs(platformUserInfos) do
    local platformUserNumber = tonumber(platformUserInfo.platformUserNumber)
    if platformUserNumber ~= nil then platformUserInfosByNumber[platformUserNumber] = platformUserInfo end
  end
  local groupsById = {}
  --print("PlatformUserInfos")
  --dump(platformUserInfos)
  for _, devname in ipairs(tableKeysSorted(devices)) do
    local info = devices[devname]
    local groupId = getDeviceGroupId(devname, devices)
    --print(string.format("groupId: %s, devname: %s", groupId, devname))
    local group = groupsById[groupId]
    local platformUserInfo = platformUserInfosByNumber[groupId]
    local userName = platformUserInfo and tostring(platformUserInfo.userName or "")
    --print(string.format("userName: %s", userName))
    if not group then
      group = {
        id = groupId,
        groupId = groupId,
        playerIndex = groupAssignments[groupId] or -1,
        label = userName and userName ~= "" and userName
          or core_locales.contextTranslate("ui.multiseat.deviceGroup", {number = groupId + 1}),
        devices = {},
        connected = true,
      }
      groupsById[groupId] = group
      --print("adding group")
    else
      group.label = userName and userName ~= "" and userName
        or core_locales.contextTranslate("ui.multiseat.deviceGroup", {number = groupId + 1})
      --print("updating group")
    end
    local productName = info and info[2]
    if (not productName or productName == "") and Input and Input.getProductName then
      productName = Input.getProductName(devname)
    end
    group.devices[#group.devices + 1] = {
      id = devname,
      label = translateDeviceName(productName or devname),
      icon = devname:startswith("mouse") and "mouse" or devname:startswith("keyboard") and "keyboard" or "gamepad",
      connected = true,
      metadata = deviceMetadata(devname, info),
    }
  end

  local result = {}
  for _, group in pairs(groupsById) do result[#result + 1] = group end
  table.sort(result, function(a, b) return a.groupId < b.groupId end)
  --dump(result)
  return result
end

rememberPlatformDeviceGroups = function(devices)
  for _, group in ipairs(getDeviceGroupsFor(devices, platformDeviceGroupPlayers)) do
    local player = platformDeviceGroupPlayers[group.groupId]
    if player ~= nil and player >= 0 then
      knownPlatformDeviceGroups[group.groupId] = deepcopy(group)
    end
  end
  for groupId in pairs(knownPlatformDeviceGroups) do
    local player = platformDeviceGroupPlayers[groupId]
    if player == nil or player < 0 then knownPlatformDeviceGroups[groupId] = nil end
  end
end

local function getDeviceGroups()
  rememberPlatformDeviceGroups(lastDevices)
  local groups = getDeviceGroupsFor(lastDevices, platformDeviceGroupPlayers)
  local liveGroupIds = {}
  for _, group in ipairs(groups) do liveGroupIds[group.groupId] = true end
  for groupId, group in pairs(knownPlatformDeviceGroups) do
    local player = platformDeviceGroupPlayers[groupId]
    if player ~= nil and player >= 0 and not liveGroupIds[groupId] then
      local missing = deepcopy(group)
      missing.playerIndex = player
      missing.connected = false
      for _, device in ipairs(missing.devices or {}) do device.connected = false end
      groups[#groups + 1] = missing
    end
  end
  table.sort(groups, function(a, b) return a.groupId < b.groupId end)
  return groups
end

local function assignDeviceGroup(groupId, player)
  groupId = tonumber(groupId)
  player = tonumber(player)
  if groupId == nil or player == nil or player < -1 or not isPlatformManagingPlayers() then return false end

  local groupExists = false
  for _, group in ipairs(getDeviceGroups()) do
    if group.groupId == groupId then groupExists = true; break end
  end
  if not groupExists then return false end

  if player >= 0 then
    for assignedGroupId, assignedPlayer in pairs(platformDeviceGroupPlayers) do
      if assignedGroupId ~= groupId and assignedPlayer == player then return false end
    end
    platformDeviceGroupPlayers[groupId] = player
  else
    platformDeviceGroupPlayers[groupId] = nil
    knownPlatformDeviceGroups[groupId] = nil
  end
  core_input_bindings.refreshAssignedPlayers(false, false)
  return true
end

local function getDeviceGroupForPlayer(player)
  player = tonumber(player)
  for groupId, assignedPlayer in pairs(platformDeviceGroupPlayers) do
    if assignedPlayer == player then return groupId end
  end
end

local function cycleDevicePlayer(deviceId)
  if isPlatformManagingPlayers() then return false end
  if type(deviceId) ~= "string" then return false end
  local assignments = getDeviceAssignments()
  local assignment
  for _, candidate in ipairs(assignments) do
    if candidate.id == deviceId or candidate.primaryDeviceId == deviceId then
      assignment = candidate
      break
    end
  end
  if not assignment or #assignments == 0 then return false end

  local currentPlayer = assignment.playerIndex or -1
  local nextPlayer
  if currentPlayer < 0 then
    local occupiedPlayers = {}
    for _, candidate in ipairs(assignments) do
      if candidate.playerIndex and candidate.playerIndex >= 0 then
        occupiedPlayers[candidate.playerIndex] = true
      end
    end
    nextPlayer = 0
    while occupiedPlayers[nextPlayer] and nextPlayer < #assignments - 1 do
      nextPlayer = nextPlayer + 1
    end
  elseif currentPlayer == 0 then
    nextPlayer = -1
  else
    nextPlayer = currentPlayer - 1
  end
  for _, assignedDeviceId in ipairs(assignment.deviceIds) do
    manuallyAssignedPlayers[assignedDeviceId] = nextPlayer
  end
  rememberManualDevices(core_input_bindings.devices)
  local assignmentsByDevice = shallowcopy(core_input_bindings.getAssignedPlayers())
  for _, assignedDeviceId in ipairs(assignment.deviceIds) do
    assignmentsByDevice[assignedDeviceId] = nextPlayer
  end
  assignmentsByDevice = normalizePlayerAssignments(core_input_bindings.devices, assignmentsByDevice, true)
  for assignedDeviceId, player in pairs(assignmentsByDevice) do
    core_input_bindings.setPlayerToDevice(assignedDeviceId, player)
  end
  updateActivePlayers(core_input_bindings.devices, assignmentsByDevice)
  return true
end

local function buildAssignment(player, devicesByPlayer)
  local devices = devicesByPlayer[player] or {}
  local deviceIds = {}
  local deviceNames = {}
  local connectedDeviceNames = {}
  local hasKeyboardMouse = false
  local connectedHasKeyboardMouse = false
  local connected = false
  for _, device in ipairs(devices) do
    deviceIds[#deviceIds + 1] = device.id
    connected = connected or device.connected == true
    if string.startswith(device.id, "keyboard") or string.startswith(device.id, "mouse") then
      hasKeyboardMouse = true
      connectedHasKeyboardMouse = connectedHasKeyboardMouse or device.connected == true
    else
      deviceNames[#deviceNames + 1] = device.productName
      if device.connected == true then connectedDeviceNames[#connectedDeviceNames + 1] = device.productName end
    end
  end
  if hasKeyboardMouse then
    table.insert(deviceNames, 1, _tr("ui.experiences.splitscreen.keyboardMouse"))
  end
  if connectedHasKeyboardMouse then
    table.insert(connectedDeviceNames, 1, _tr("ui.experiences.splitscreen.keyboardMouse"))
  end
  return {
    playerIndex = player,
    devices = devices,
    deviceIds = deviceIds,
    primaryDeviceId = deviceIds[1],
    deviceLabel = #deviceNames > 0 and table.concat(deviceNames, ", ") or nil,
    connectedDeviceLabel = #connectedDeviceNames > 0 and table.concat(connectedDeviceNames, ", ") or nil,
    connectedInputIcon = connectedHasKeyboardMouse and "keyboard" or (connected and "gamepad" or nil),
    connected = connected,
  }
end

local function assignmentIcon(assignment)
  for _, deviceId in ipairs(assignment.deviceIds) do
    if string.startswith(deviceId, "keyboard") or string.startswith(deviceId, "mouse") then
      return "keyboard"
    end
  end
  return "gamepad"
end

local function participantAssignmentSignature(assignment)
  return table.concat(assignment.deviceIds, ";") .. "@" .. tostring(assignment.deviceLabel or "")
end

local function getJoinedPlayers()
  local result = {}
  for _, entry in ipairs(joinedPlayers) do
    result[#result + 1] = entry.playerIndex
  end
  table.sort(result)
  return result
end

local function isPlayerActive(player)
  if (extensions.isExtensionLoaded("careerSplitScreen") and (careerSplitScreen.isSplitModeActive and careerSplitScreen.isSplitModeActive() or careerSplitScreen.isActive and careerSplitScreen.isActive()))
     or (extensions.isExtensionLoaded("render_splitScreen") and render_splitScreen.isEnabled and render_splitScreen.isEnabled()) then
    if player == 0 or player == 1 then return true end
  end
  for _, activePlayer in ipairs(activePlayers) do
    if activePlayer == player then return true end
  end
  return false
end

local function getFirstUnusedPersonaNumber()
  local used = {}
  for _, entry in ipairs(joinedPlayers) do used[entry.personaNumber] = true end
  for personaNumber = 1, maxPlayers do
    if not used[personaNumber] then return personaNumber end
  end
end

local function addJoinedPlayer(player, devicesByPlayer, personaNumber)
  personaNumber = personaNumber or getFirstUnusedPersonaNumber()
  if not personaNumber then return false end
  local assignment = buildAssignment(player, devicesByPlayer or getDevicesByPlayer())
  -- a fresh persona keeps the session defaults for its number, including the icon
  extensions.core_playerPersonas.set(personaNumber, {})
  joinedPlayers[#joinedPlayers + 1] = {
    playerIndex = player,
    personaNumber = personaNumber,
    assignmentSignature = participantAssignmentSignature(assignment),
  }
  joinedByPlayer[player] = personaNumber
  return true
end

normalizePlayerAssignments = function(devices, assignments, addMissingPersonas)
  local normalized = shallowcopy(assignments)
  local activeLookup = {}
  for _, player in pairs(normalized) do
    if player ~= nil and player >= 0 then activeLookup[player] = true end
  end
  if multiseatActive then
    for _, entry in ipairs(joinedPlayers) do activeLookup[entry.playerIndex] = true end
  end

  for index = #joinedPlayers, 1, -1 do
    local entry = joinedPlayers[index]
    if not activeLookup[entry.playerIndex] then
      extensions.core_playerPersonas.clear(entry.personaNumber)
      table.remove(joinedPlayers, index)
    end
  end

  table.clear(joinedByPlayer)
  for _, entry in ipairs(joinedPlayers) do joinedByPlayer[entry.playerIndex] = entry.personaNumber end

  if addMissingPersonas then
    local devicesByPlayer = getDevicesByPlayer(devices, normalized)
    local activePlayerIds = tableKeys(activeLookup)
    table.sort(activePlayerIds)
    for _, player in ipairs(activePlayerIds) do
      if not joinedByPlayer[player] then addJoinedPlayer(player, devicesByPlayer) end
    end
  end

  table.sort(joinedPlayers, function(a, b) return a.personaNumber < b.personaNumber end)
  local oldToNew = {}
  local nextPlayer = 0
  for _, entry in ipairs(joinedPlayers) do
    if activeLookup[entry.playerIndex] and oldToNew[entry.playerIndex] == nil then
      oldToNew[entry.playerIndex] = nextPlayer
      nextPlayer = nextPlayer + 1
    end
  end

  local unjoinedPlayers = {}
  for player in pairs(activeLookup) do
    if oldToNew[player] == nil then unjoinedPlayers[#unjoinedPlayers + 1] = player end
  end
  table.sort(unjoinedPlayers)
  for _, player in ipairs(unjoinedPlayers) do
    oldToNew[player] = nextPlayer
    nextPlayer = nextPlayer + 1
  end

  for devname, player in pairs(normalized) do
    if player ~= nil and player >= 0 then normalized[devname] = oldToNew[player] end
  end
  for devname, player in pairs(manuallyAssignedPlayers) do
    if player ~= nil and player >= 0 and oldToNew[player] ~= nil then
      manuallyAssignedPlayers[devname] = oldToNew[player]
    end
  end
  for groupId, player in pairs(platformDeviceGroupPlayers) do
    if player ~= nil and player >= 0 and oldToNew[player] ~= nil then
      platformDeviceGroupPlayers[groupId] = oldToNew[player]
    end
  end

  table.clear(joinedByPlayer)
  for _, entry in ipairs(joinedPlayers) do
    entry.playerIndex = oldToNew[entry.playerIndex]
    joinedByPlayer[entry.playerIndex] = entry.personaNumber
  end
  return normalized
end

local function normalizeCurrentPlayerAssignments(addMissingPersonas)
  if not core_input_bindings or not core_input_bindings.getAssignedPlayers then return end
  local devices = core_input_bindings.devices or lastDevices
  local assignments = normalizePlayerAssignments(
    devices,
    core_input_bindings.getAssignedPlayers(),
    addMissingPersonas
  )
  for devname, player in pairs(assignments) do
    core_input_bindings.setPlayerToDevice(devname, player)
  end
  updateActivePlayers(devices, assignments)
end

local function joinPlayer(player)
  player = tonumber(player)
  if player == nil or not isPlayerActive(player) then return false end
  if joinedByPlayer[player] then return true end

  if not addJoinedPlayer(player) then return false end
  normalizeCurrentPlayerAssignments(false)
  participantRevision = participantRevision + 1
  taggedRevision = nil
  coloredRevision = nil
  emitParticipantsChanged()
  return true
end

local function leavePlayer(player)
  player = tonumber(player)
  local personaNumber = player and joinedByPlayer[player]
  if not personaNumber then return false end
  local platformGroupId = isPlatformManagingPlayers() and getDeviceGroupForPlayer(player) or nil

  for index, entry in ipairs(joinedPlayers) do
    if entry.playerIndex == player then
      table.remove(joinedPlayers, index)
      break
    end
  end
  joinedByPlayer[player] = nil
  extensions.core_playerPersonas.clear(personaNumber)
  if platformGroupId ~= nil then
    platformDeviceGroupPlayers[platformGroupId] = nil
    knownPlatformDeviceGroups[platformGroupId] = nil
    core_input_bindings.refreshAssignedPlayers(false, false)
  elseif not isPlatformManagingPlayers() then
    for devname, assignedPlayer in pairs(manuallyAssignedPlayers) do
      if assignedPlayer == player then
        manuallyAssignedPlayers[devname] = nil
        knownManualDevices[devname] = nil
      end
    end
    core_input_bindings.refreshAssignedPlayers(false, false)
  end
  participantRevision = participantRevision + 1
  taggedRevision = nil
  coloredRevision = nil
  emitParticipantsChanged()
  return true
end

local function clearJoinedPlayers()
  if not next(joinedPlayers) then return false end
  table.clear(joinedPlayers)
  table.clear(joinedByPlayer)
  extensions.core_playerPersonas.clearAll()
  participantRevision = participantRevision + 1
  taggedRevision = nil
  coloredRevision = nil
  emitParticipantsChanged()
  return true
end

local function setPersonaOptInMode(enabled)
  enabled = enabled == true
  if personaOptInMode == enabled then return end
  personaOptInMode = enabled
  if enabled then clearJoinedPlayers() end
end

syncJoinedPlayers = function()
  local changed = false
  local devicesByPlayer = getDevicesByPlayer()
  for index = #joinedPlayers, 1, -1 do
    local entry = joinedPlayers[index]
    if not isPlayerActive(entry.playerIndex) then
      joinedByPlayer[entry.playerIndex] = nil
      extensions.core_playerPersonas.clear(entry.personaNumber)
      table.remove(joinedPlayers, index)
      changed = true
    else
      local assignment = buildAssignment(entry.playerIndex, devicesByPlayer)
      local signature = participantAssignmentSignature(assignment)
      if entry.assignmentSignature ~= signature then
        entry.assignmentSignature = signature
        changed = true
      end
    end
  end
  return changed
end

syncAutomaticPersonas = function(enabled)
  if not enabled then
    if #joinedPlayers == 0 then return false end
    table.clear(joinedPlayers)
    table.clear(joinedByPlayer)
    extensions.core_playerPersonas.clearAll()
    return true
  end

  local changed = false
  local devicesByPlayer = getDevicesByPlayer()
  for _, player in ipairs(activePlayers) do
    if not joinedByPlayer[player] then
      changed = addJoinedPlayer(player, devicesByPlayer) or changed
    end
  end
  return changed
end

local function buildParticipant(player, personaNumber, devicesByPlayer, preview)
  local assignment = buildAssignment(player, devicesByPlayer)
  local persona = preview and extensions.core_playerPersonas.preview(personaNumber)
    or extensions.core_playerPersonas.get(personaNumber)
  if #activePlayers <= 1 then
    extensions.core_playerPersonas.applySoloColor(persona)
  end
  return {
    id = persona.id,
    persona = persona,
    assignment = assignment,
    inputIcon = assignmentIcon(assignment),
  }
end

local function getJoinedParticipants()
  local devicesByPlayer = getDevicesByPlayer()
  local participants = {}
  for _, entry in ipairs(joinedPlayers) do
    participants[#participants + 1] = buildParticipant(entry.playerIndex, entry.personaNumber, devicesByPlayer)
  end
  table.sort(participants, function(a, b) return a.assignment.playerIndex < b.assignment.playerIndex end)
  return participants
end

local function exportConfiguration()
  return {
    enabled = settings.getValue("multiseat") == true,
    multiseatActive = multiseatActive,
    personaOptInMode = personaOptInMode,
    manuallyAssignedPlayers = deepcopy(manuallyAssignedPlayers),
    knownManualDevices = deepcopy(knownManualDevices),
    platformDeviceGroupPlayers = deepcopy(platformDeviceGroupPlayers),
    knownPlatformDeviceGroups = deepcopy(knownPlatformDeviceGroups),
    mockPlatformDeviceGroupIds = deepcopy(mockPlatformDeviceGroupIds),
    nextMockPlatformDeviceGroupId = nextMockPlatformDeviceGroupId,
    joinedPlayers = deepcopy(joinedPlayers),
    activePlayers = deepcopy(activePlayers),
    lastDevices = lastDevices,
    lastAssignedPlayers = deepcopy(lastAssignedPlayers),
    lastAssignmentSignature = lastAssignmentSignature,
    bindingsAssignments = core_input_bindings and deepcopy(core_input_bindings.getAssignedPlayers()) or {},
    personas = extensions.core_playerPersonas.snapshot(),
    cachedPlayerAssignments = ui_multiseat_assignmentCache.get("exportConfiguration"),
    pendingCachedPlayerAssignments = deepcopy(pendingCachedPlayerAssignments),
  }
end

local function buildPlayerAssignmentCache(config)
  if type(config) ~= "table" or type(config.participants) ~= "table" then return nil end
  local personaByPlayer = {}
  for _, participant in ipairs(config.participants) do
    local player = tonumber(participant.playerIndex)
    local personaNumber = tonumber(participant.personaNumber)
    if player ~= nil and personaNumber ~= nil then personaByPlayer[player] = personaNumber end
  end

  local cache = {
    platformManagesPlayers = config.platformManagesPlayers == true,
    manualOwnersByDevice = {},
    groupOwners = {},
  }
  if cache.platformManagesPlayers then
    for groupId, player in pairs(config.groupAssignments or {}) do
      local personaNumber = personaByPlayer[tonumber(player)]
      if personaNumber then cache.groupOwners[tonumber(groupId) or groupId] = personaNumber end
    end
  else
    for deviceId, player in pairs(config.manualAssignments or {}) do
      local personaNumber = personaByPlayer[tonumber(player)]
      if personaNumber then cache.manualOwnersByDevice[deviceId] = personaNumber end
    end
  end
  return cache
end

local function cachePlayerAssignments(config)
  local cache = buildPlayerAssignmentCache(config)
  if not cache then return false end
  ui_multiseat_assignmentCache.set(cache, "cachePlayerAssignments")
  return true
end

local function getCachedPlayerAssignments()
  return ui_multiseat_assignmentCache.get("getCachedPlayerAssignments")
end

local function resolveConfiguration(config, devices)
  if type(config) ~= "table" or type(config.participants) ~= "table" then
    return nil, "invalid_configuration"
  end
  if #config.participants == 0 or #config.participants > maxPlayers then return nil, "invalid_player_count" end

  local participants = deepcopy(config.participants)
  table.sort(participants, function(a, b)
    return (tonumber(a.personaNumber) or math.huge) < (tonumber(b.personaNumber) or math.huge)
  end)
  local oldToNew = {}
  local usedPersonas = {}
  local personas = {}
  for index, participant in ipairs(participants) do
    local oldPlayer = tonumber(participant.playerIndex)
    local personaNumber = tonumber(participant.personaNumber)
    if oldPlayer == nil or personaNumber == nil or personaNumber < 1 or usedPersonas[personaNumber] then
      return nil, "invalid_participant"
    end
    usedPersonas[personaNumber] = true
    oldToNew[oldPlayer] = index - 1
    participant.playerIndex = index - 1
    participant.personaNumber = personaNumber
    participant.persona = participant.persona or extensions.core_playerPersonas.preview(personaNumber)
    participant.persona.number = personaNumber
    personas[personaNumber] = participant.persona
  end

  local manualAssignments = {}
  for devname, oldPlayer in pairs(config.manualAssignments or {}) do
    oldPlayer = tonumber(oldPlayer)
    manualAssignments[devname] = oldPlayer and oldPlayer >= 0 and oldToNew[oldPlayer] or -1
  end
  local groupAssignments = {}
  for groupId, oldPlayer in pairs(config.groupAssignments or {}) do
    oldPlayer = tonumber(oldPlayer)
    if oldPlayer and oldPlayer >= 0 and oldToNew[oldPlayer] ~= nil then
      groupAssignments[tonumber(groupId) or groupId] = oldToNew[oldPlayer]
    end
  end

  local assignments = {}
  for devname in pairs(devices or {}) do
    if config.platformManagesPlayers then
      assignments[devname] = groupAssignments[getDeviceGroupId(devname, devices)] or -1
    else
      assignments[devname] = manualAssignments[devname] or -1
    end
  end
  return {
    platformManagesPlayers = config.platformManagesPlayers == true,
    personaOptInMode = config.personaOptInMode == true,
    manualAssignments = manualAssignments,
    manualDeviceMetadata = deepcopy(config.manualDeviceMetadata or {}),
    groupAssignments = groupAssignments,
    platformDeviceGroups = deepcopy(config.platformDeviceGroups or {}),
    assignments = assignments,
    participants = participants,
    personas = personas,
  }
end

local function restoreConfiguration(snapshot)
  manuallyAssignedPlayers = deepcopy(snapshot.manuallyAssignedPlayers or {})
  knownManualDevices = deepcopy(snapshot.knownManualDevices or {})
  rememberManualDevices(snapshot.lastDevices or {})
  platformDeviceGroupPlayers = deepcopy(snapshot.platformDeviceGroupPlayers or {})
  knownPlatformDeviceGroups = deepcopy(snapshot.knownPlatformDeviceGroups or {})
  mockPlatformDeviceGroupIds = deepcopy(snapshot.mockPlatformDeviceGroupIds or {})
  nextMockPlatformDeviceGroupId = tonumber(snapshot.nextMockPlatformDeviceGroupId) or 1
  joinedPlayers = deepcopy(snapshot.joinedPlayers or {})
  table.clear(joinedByPlayer)
  for _, entry in ipairs(joinedPlayers) do joinedByPlayer[entry.playerIndex] = entry.personaNumber end
  activePlayers = deepcopy(snapshot.activePlayers or {0})
  lastDevices = snapshot.lastDevices or {}
  lastAssignedPlayers = deepcopy(snapshot.lastAssignedPlayers or {})
  lastAssignmentSignature = snapshot.lastAssignmentSignature or ""
  personaOptInMode = snapshot.personaOptInMode == true
  multiseatActive = snapshot.multiseatActive == true
  configurationNotificationPending = false
  ui_multiseat_assignmentCache.set(snapshot.cachedPlayerAssignments, "restoreConfiguration")
  pendingCachedPlayerAssignments = deepcopy(snapshot.pendingCachedPlayerAssignments)
  extensions.core_playerPersonas.restoreSnapshot(snapshot.personas)
  settings.setValue("multiseat", snapshot.enabled == true)
  lastMultiseat = snapshot.enabled == true
  local actionMap = scenetree.findObject("MultiseatActionMap")
  if actionMap then actionMap:setEnabled(snapshot.enabled == true) end
  if core_input_bindings and core_input_bindings.applyPlayerAssignments then
    core_input_bindings.applyPlayerAssignments(snapshot.bindingsAssignments or {}, "multiseat configuration restored")
  end
end

local function restoreExportedConfiguration(snapshot)
  if applyingConfiguration or type(snapshot) ~= "table" then return false end
  applyingConfiguration = true
  local ok = pcall(restoreConfiguration, snapshot)
  applyingConfiguration = false
  if not ok then return false end
  participantRevision = participantRevision + 1
  taggedRevision = nil
  coloredRevision = nil
  emitParticipantsChanged()
  return true
end

local function applyConfiguration(config)
  if applyingConfiguration then return false, "configuration_commit_in_progress" end
  local devices = core_input_bindings and core_input_bindings.devices or lastDevices
  local resolved, reason = resolveConfiguration(config, devices)
  if not resolved then return false, reason end
  local snapshot = exportConfiguration()

  applyingConfiguration = true
  local ok, errorMessage = pcall(function()
    manuallyAssignedPlayers = deepcopy(resolved.manualAssignments)
    knownManualDevices = {}
    for devname, player in pairs(manuallyAssignedPlayers) do
      if player ~= nil and player >= 0 then
        local metadata = resolved.manualDeviceMetadata[devname]
        if metadata then
          knownManualDevices[devname] = deepcopy(metadata)
        elseif devices[devname] then
          knownManualDevices[devname] = deviceMetadata(devname, devices[devname])
        end
      end
    end
    platformDeviceGroupPlayers = deepcopy(resolved.groupAssignments)
    knownPlatformDeviceGroups = {}
    for _, group in ipairs(resolved.platformDeviceGroups) do
      local groupId = tonumber(group.groupId)
      if groupId ~= nil and platformDeviceGroupPlayers[groupId] ~= nil then
        knownPlatformDeviceGroups[groupId] = deepcopy(group)
      end
    end
    rememberPlatformDeviceGroups(devices)
    personaOptInMode = resolved.personaOptInMode
    extensions.core_playerPersonas.replaceAll(resolved.personas)

    joinedPlayers = {}
    table.clear(joinedByPlayer)
    activePlayers = {}
    for _, participant in ipairs(resolved.participants) do
      local player = participant.playerIndex
      local personaNumber = participant.personaNumber
      activePlayers[#activePlayers + 1] = player
      joinedByPlayer[player] = personaNumber
      joinedPlayers[#joinedPlayers + 1] = {
        playerIndex = player,
        personaNumber = personaNumber,
        assignmentSignature = "",
      }
    end

    lastDevices = devices or (core_input_bindings and core_input_bindings.devices) or {}
    lastAssignedPlayers = deepcopy(resolved.assignments)
    lastAssignmentSignature = assignmentSignature(lastDevices, lastAssignedPlayers)
    local devicesByPlayer = getDevicesByPlayer(lastDevices, lastAssignedPlayers)
    for _, entry in ipairs(joinedPlayers) do
      entry.assignmentSignature = participantAssignmentSignature(buildAssignment(entry.playerIndex, devicesByPlayer))
    end

    settings.setValue("multiseat", true)
    lastMultiseat = true
    local actionMap = scenetree.findObject("MultiseatActionMap")
    if actionMap then actionMap:setEnabled(true) end
    multiseatActive = config.multiseatActive ~= false
    if not core_input_bindings.applyPlayerAssignments(resolved.assignments, "multiseat configuration applied") then
      error("failed_to_apply_device_assignments")
    end
  end)
  if not ok then
    restoreConfiguration(snapshot)
    applyingConfiguration = false
    return false, tostring(errorMessage)
  end

  applyingConfiguration = false
  local nextAssignmentCache = buildPlayerAssignmentCache(resolved)
  if config.deferParticipantNotification then
    pendingCachedPlayerAssignments = nextAssignmentCache
  else
    ui_multiseat_assignmentCache.set(nextAssignmentCache, "applyConfiguration")
    pendingCachedPlayerAssignments = nil
  end
  participantRevision = participantRevision + 1
  taggedRevision = nil
  coloredRevision = nil
  if config.deferParticipantNotification then
    configurationNotificationPending = true
  else
    emitParticipantsChanged()
  end
  return true
end

local function finalizeConfiguration()
  if not configurationNotificationPending then return false end
  configurationNotificationPending = false
  if pendingCachedPlayerAssignments then
    ui_multiseat_assignmentCache.set(pendingCachedPlayerAssignments, "finalizeConfiguration")
    pendingCachedPlayerAssignments = nil
  end
  emitParticipantsChanged()
  return true
end

local function getAvailableParticipants()
  local devicesByPlayer = getDevicesByPlayer()
  local participants = {}
  for _, player in ipairs(activePlayers) do
    local personaNumber = joinedByPlayer[player]
    local previewPersonaNumber = extensions.core_playerPersonas.getNumberForPlayer(player)
    local assignment = buildAssignment(player, devicesByPlayer)
    participants[#participants + 1] = {
      id = "local-player:" .. player,
      assignment = assignment,
      inputIcon = assignmentIcon(assignment),
      joined = personaNumber ~= nil,
      persona = personaNumber and extensions.core_playerPersonas.get(personaNumber)
        or extensions.core_playerPersonas.preview(previewPersonaNumber),
    }
  end
  return participants
end

local function getParticipants(players)
  if players == nil and #joinedPlayers > 0 then return getJoinedParticipants() end

  players = players or activePlayers
  local devicesByPlayer = getDevicesByPlayer()
  local participants = {}
  for _, player in ipairs(players) do
    local personaNumber = joinedByPlayer[player]
    local previewPersonaNumber = extensions.core_playerPersonas.getNumberForPlayer(player)
    participants[#participants + 1] = buildParticipant(player, personaNumber or previewPersonaNumber, devicesByPlayer, personaNumber == nil)
  end
  return participants
end

local function getParticipant(player)
  for _, participant in ipairs(getParticipants({player})) do return participant end
end

emitParticipantsChanged = function()
  local revision = getParticipantRevision()
  extensions.hook("onLocalParticipantsChanged", revision)
  guihooks.trigger("LocalParticipantsChanged", getParticipants(), revision)
end

local function setPlayerPersona(player, data)
  local personaNumber = joinedByPlayer[tonumber(player)]
  if not personaNumber or not extensions.core_playerPersonas.set(personaNumber, data) then return false end
  taggedRevision = nil
  coloredRevision = nil
  emitParticipantsChanged()
  return true
end

local function clearPlayerPersona(player)
  player = tonumber(player)
  local personaNumber = joinedByPlayer[player]
  if not personaNumber then return false end
  if not extensions.core_playerPersonas.set(personaNumber, {}) then return false end
  taggedRevision = nil
  coloredRevision = nil
  emitParticipantsChanged()
  return true
end

local function rebuildTags()
  local tags = {}
  for _, participant in ipairs(getParticipants()) do
    local player = participant.assignment.playerIndex
    tags[#tags + 1] = {
      key = participant.persona.id,
      player = player,
      label = participant.persona.displayName,
      color = participant.persona.color,
      icon = participant.persona.icon,
    }
  end
  if extensions.render_playerTags.rebuild(tags, "multiseat") then
    taggedRevision = getParticipantRevision()
  end
end

-- tint assigned input devices to match each player's colour (0-255 RGB). increase saturation and brightness to make the colors more vibrant on the devices
local deviceColorSaturationBoost = 1
local deviceColorBrightnessBoost = 1

local function personaDeviceColor(color)
  local r, g, b = color[1], color[2], color[3]
  local mn = math.min(r, g, b)
  local mx = math.max(r, g, b)
  local target = mx + (1 - mx) * deviceColorBrightnessBoost
  if mx <= mn then return vec3(target * 255, target * 255, target * 255) end
  local grey = mn * deviceColorSaturationBoost
  local scale = 255 * target / (mx - grey)
  return vec3((r - grey) * scale, (g - grey) * scale, (b - grey) * scale)
end

local function applyDeviceColors()
  if not core_devices then return end
  local colors = {}
  for _, participant in ipairs(getJoinedParticipants()) do
    local player = participant.assignment.playerIndex
    local color = participant.persona.color
    colors[player] = personaDeviceColor(color)
  end
  core_devices.setPlayerColors(colors)
  coloredRevision = getParticipantRevision()
  deviceColorsApplied = true
end

-- shows the colours of a configuration that is still being edited, so the devices follow the staged assignments
local function previewDeviceColors(config)
  if not core_devices then return end
  local devices = core_input_bindings and core_input_bindings.devices or lastDevices
  local resolved = config and resolveConfiguration(config, devices) or nil
  local colors = {}
  for _, participant in ipairs(resolved and resolved.participants or {}) do
    colors[participant.playerIndex] = personaDeviceColor(participant.persona.color)
  end
  core_devices.setPlayerColors(colors, resolved and resolved.assignments or {})
  coloredRevision = nil
  devicePreviewActive = true
  deviceColorsApplied = true
end

local function clearDeviceColors()
  if not deviceColorsApplied then return end
  if core_devices then core_devices.setPlayerColors(nil) end
  coloredRevision = nil
  devicePreviewActive = false
  deviceColorsApplied = false
end

local function syncDeviceColors()
  if devicePreviewActive then return end
  if settings.getValue("multiseat") and #joinedPlayers > 0 then
    if coloredRevision ~= getParticipantRevision() then applyDeviceColors() end
  else
    clearDeviceColors()
  end
end

local function onUpdate(dtReal, dtSim)
  if not getCurrentLevelIdentifier() then return end
  syncDeviceColors()
  local tagsActive = settings.getValue("multiseat") and getPlayerMarkersEnabled()
  if extensions.isExtensionLoaded("render_splitScreen") then taggedRevision = nil; return end -- split-screen owns the tags
  if not (tagsActive and #activePlayers > 1) then
    if taggedRevision or extensions.render_playerTags.isLive() then
      extensions.render_playerTags.destroy()
      taggedRevision = nil
    end
    return
  end
  if taggedRevision ~= getParticipantRevision() or not extensions.render_playerTags.isLive() then rebuildTags() end
  extensions.render_playerTags.updatePositions(dtReal)
end

local function setMultiseatActive(active)
  multiseatActive = active
end

local function isMultiseatActive()
  return multiseatActive
end

local function reset()
  local sessionOwnedMultiseat = personaOptInMode or multiseatActive

  extensions.render_playerTags.reset()
  clearDeviceColors()
  table.clear(joinedPlayers)
  table.clear(joinedByPlayer)
  extensions.core_playerPersonas.clearAll()
  personaOptInMode = false
  multiseatActive = false
  activePlayers = {0}
  lastDevices = {} -- owned by core_input_bindings, so replace instead of clearing
  lastAssignedPlayers = {}
  manuallyAssignedPlayers = {}
  knownManualDevices = {}
  platformDeviceGroupPlayers = {}
  knownPlatformDeviceGroups = {}
  mockPlatformDeviceGroupIds = {}
  nextMockPlatformDeviceGroupId = 0
  configurationEditActive = false
  configurationNotificationPending = false
  pendingCachedPlayerAssignments = nil
  lastAssignmentSignature = ""
  participantRevision = participantRevision + 1
  taggedRevision = nil
  coloredRevision = nil

  if sessionOwnedMultiseat and settings.getValue("multiseat") then
    settings.setValue("multiseat", false)
  end
end

local function onSerialize(reason)
  extensions.render_playerTags.reset()
  taggedRevision = nil
  clearDeviceColors()
  if not multiseatActive then return end
  local snapshot = exportConfiguration()
  log("I", "multiseatReload", string.format(
    "core serialize: reason=%s players=%d assignments=%d",
    tostring(reason),
    #joinedPlayers,
    tableSize(snapshot.bindingsAssignments)
  ))
  return snapshot
end

local function onDeserialized(data)
  if type(data) ~= "table" then
    log("I", "multiseatReload", "core deserialize skipped: invalid snapshot")
    return
  end
  local restored = restoreExportedConfiguration(data)
  log("I", "multiseatReload", string.format(
    "core deserialize: restored=%s players=%d assignments=%d",
    tostring(restored),
    #joinedPlayers,
    tableSize(data.bindingsAssignments or {})
  ))
end

M.getAssignedPlayers = getAssignedPlayers
M.getPlayers = getPlayers
M.getDeviceAssignments = getDeviceAssignments
M.getDeviceAssignmentsFor = getDeviceAssignmentsFor
M.getDeviceGroups = getDeviceGroups
M.getDeviceGroupsFor = getDeviceGroupsFor
M.assignDeviceGroup = assignDeviceGroup
M.getDeviceGroupForPlayer = getDeviceGroupForPlayer
M.isPlatformManagingPlayers = isPlatformManagingPlayers
M.cycleDevicePlayer = cycleDevicePlayer
M.getParticipants = getParticipants
M.getParticipant = getParticipant
M.getAvailableParticipants = getAvailableParticipants
M.getJoinedParticipants = getJoinedParticipants
M.getJoinedPlayers = getJoinedPlayers
M.joinPlayer = joinPlayer
M.leavePlayer = leavePlayer
M.clearJoinedPlayers = clearJoinedPlayers
M.setPersonaOptInMode = setPersonaOptInMode
M.getParticipantRevision = getParticipantRevision
M.getPlayerMarkersEnabled = getPlayerMarkersEnabled
M.setPlayerMarkersEnabled = setPlayerMarkersEnabled
M.setPlayerPersona = setPlayerPersona
M.clearPlayerPersona = clearPlayerPersona
M.exportConfiguration = exportConfiguration
M.resolveConfiguration = resolveConfiguration
M.applyConfiguration = applyConfiguration
M.restoreConfiguration = restoreExportedConfiguration
M.finalizeConfiguration = finalizeConfiguration
M.cachePlayerAssignments = cachePlayerAssignments
M.getCachedPlayerAssignments = getCachedPlayerAssignments
M.isApplyingConfiguration = function() return applyingConfiguration end
M.beginConfigurationEdit = function() configurationEditActive = true end
M.endConfigurationEdit = function(devices, assignments)
  configurationEditActive = false
  if type(devices) == "table" and type(assignments) == "table" then
    lastDevices = devices
    lastAssignedPlayers = deepcopy(assignments)
    lastAssignmentSignature = assignmentSignature(lastDevices, lastAssignedPlayers)
  end
end
M.isConfigurationEditActive = function() return configurationEditActive end
M.previewDeviceColors = previewDeviceColors
M.clearDeviceColors = clearDeviceColors
M.onUpdate = onUpdate
M.setMultiseatActive = setMultiseatActive
M.isMultiseatActive = isMultiseatActive
M.onLanguageChanged = function()
  syncJoinedPlayers()
  extensions.core_playerPersonas.invalidate()
  taggedRevision = nil
  emitParticipantsChanged()
end
M.onClientEndMission = reset
M.onExtensionUnloaded = function()
  extensions.render_playerTags.reset()
  taggedRevision = nil
  clearDeviceColors()
end
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

local function setDevicePlayer(devname, player)
  manuallyAssignedPlayers[devname] = player
  if core_input_bindings and core_input_bindings.devices and core_input_bindings.devices[devname] then
    knownManualDevices[devname] = deviceMetadata(devname, core_input_bindings.devices[devname])
  end
end
M.setDevicePlayer = setDevicePlayer

return M
