-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.

-- If a copy of the bCDDL was not distributed with this

-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt



local Common = require("ge/extensions/ui/pause/providers/routeData/common")



local M = {}



local function pushRoute(routeName)

  local result = extensions.ui_router.navigate(routeName)

  return result ~= false

end



-- "Exit scenario" only clears scenario_scenarios' bookkeeping and leaves the

-- player exactly where they were and doesn't unload the level. For quickrace/

-- lightRunner/busRoute (one-shot wizard flows) that looks like the button's broken.

local function isWizardScenario(activeScenario)

  if not activeScenario then return false end

  -- Bus routes are started via scenario_scenariosLoader and always tag

  -- themselves with a busdriver config (see busrouteConfigurator.lua).

  if activeScenario.busdriver then return true end

  -- quickrace/lightRunner both go through scenario_quickRaceLoader, which

  -- tags every race isQuickRace = true (see quickRaceLoader.lua's

  -- loadQuickrace()).

  return activeScenario.isQuickRace == true

end



local function getCurrentPlayerVehicle()

  if not getPlayerVehicle then return nil end

  return getPlayerVehicle(0)

end



local function buildRecoveryTarget(targetType, targetVehId)

  if targetType == "none" then

    return {type = "none"}

  end

  if targetType == "walk" then

    return {type = "walk"}

  end

  if targetType == "vehicle" and targetVehId then

    return {type = "vehicle", vehId = targetVehId}

  end



  local veh = getCurrentPlayerVehicle()

  if veh then

    return {type = "vehicle", vehId = veh:getId()}

  end

  return {type = "none"}

end



local function executeRecoveryButton(buttonId, targetType, targetVehId)

  if not core_recoveryPrompt or not core_recoveryPrompt.buttonPressed or not buttonId then

    return false

  end

  core_recoveryPrompt.buttonPressed(buttonId, buildRecoveryTarget(targetType, targetVehId))

  return true

end



local function toActionLabel(value, fallback)

  if type(value) == "string" and value ~= "" then return value end

  if type(value) ~= "table" then return fallback end



  if type(value.label) == "string" and value.label ~= "" then

    return value.label

  end



  if type(value.context) == "table" and type(value.context.label) == "string" and value.context.label ~= "" then

    if value.context.count ~= nil then

      return string.format("%s (%s)", value.context.label, tostring(value.context.count))

    end

    return value.context.label

  end



  if type(value.txt) == "string" and value.txt ~= "" then

    return value.txt

  end



  return fallback

end



local function addFreeroamStyleRecoveryActions(context, actions, registerButton)

  if not context.isMultiseatActive then

    table.insert(actions, registerButton({

      id = "home.repairHere",

      label = _tr("ui.radialmenu2.repairVehicle"),

      icon = "wrench",

      rail = "home",

      visible = true,

      enabled = true,

    }, function()

      local veh = getCurrentPlayerVehicle()

      if not veh or not spawn or not spawn.safeTeleport then return false end

      spawn.safeTeleport(veh, veh:getPosition(), quatFromDir(veh:getDirectionVector()), nil, nil, nil, nil, true)

      extensions.hook("onPauseMenuRightRailButtonPressed", "repairHere")

      return true

    end))

  end

end



local function addCareerRecoveryActions(actions, registerButton)

  local dynamicButtons = core_recoveryPrompt and core_recoveryPrompt.getPauseCareerRightRailButtons and core_recoveryPrompt.getPauseCareerRightRailButtons() or {}

  for _, button in ipairs(dynamicButtons) do

    local recoveryButtonId = tostring(button.id or "unknown")

    local recoveryTargetType = button.targetType

    local recoveryTargetVehId = button.targetVehId

    table.insert(actions, registerButton({

      id = "home.career." .. recoveryButtonId,

      label = toActionLabel(button.title, recoveryButtonId),

      icon = button.icon or "recover",

      rail = "home",

      visible = true,

      enabled = button.enabled ~= false,

      disabledReason = button.disableReason,

      confirmText = button.holdToClick,

    }, function()

      return executeRecoveryButton(recoveryButtonId, recoveryTargetType, recoveryTargetVehId)

    end))

  end

end



local function addMissionRecoveryActions(actions, registerButton)

  local dynamicButtons = core_recoveryPrompt and core_recoveryPrompt.getPauseMissionRightRailButtons and core_recoveryPrompt.getPauseMissionRightRailButtons() or {}

  if #dynamicButtons > 0 then

    for _, button in ipairs(dynamicButtons) do

      local recoveryButtonId = tostring(button.id or "unknown")

      local recoveryTargetType = button.targetType

      local recoveryTargetVehId = button.targetVehId

      table.insert(actions, registerButton({

        id = "home.mission." .. recoveryButtonId,

        label = toActionLabel(button.title, recoveryButtonId),

        icon = button.icon or "recover",

        rail = "home",

        visible = true,

        enabled = button.enabled ~= false,

        disabledReason = button.disableReason,

        confirmText = button.holdToClick,

      }, function()

        return executeRecoveryButton(recoveryButtonId, recoveryTargetType, recoveryTargetVehId)

      end))

    end

    return

  end



  table.insert(actions, registerButton({

    id = "home.missionRestart",

    label = _tr("missions.missions.general.panel.restart"),

    icon = "restart",

    rail = "home",

    visible = true,

    enabled = true,

  }, function()

    return executeRecoveryButton("restartMission", "none")

  end))



  table.insert(actions, registerButton({

    id = "home.missionFlip",

    label = _tr("ui.radialmenu2.flipVehicleUpright"),

    icon = "carToWheels",

    rail = "home",

    visible = true,

    enabled = true,

  }, function()

    return executeRecoveryButton("flipMission", "vehicle")

  end))



  table.insert(actions, registerButton({

    id = "home.missionRecover",

    label = _tr("ui.radialmenu2.recoverToLastRoad"),

    icon = "car",

    rail = "home",

    visible = true,

    enabled = true,

  }, function()

    return executeRecoveryButton("recoverMission", "vehicle")

  end))



  table.insert(actions, registerButton({

    id = "home.missionTowToRoad",

    label = _tr("ui.career.towToRoad"),

    icon = "road",

    rail = "home",

    visible = true,

    enabled = true,

  }, function()

    return executeRecoveryButton("towToRoad", "vehicle")

  end))

end



local function isCareerPathsAndMilestonesAvailable()

  local tutorialActive = career_modules_tutorial and career_modules_tutorial.isActive and career_modules_tutorial.isActive()

  if tutorialActive then return false end

  return career_career and career_career.hasBoughtStarterVehicle and career_career.hasBoughtStarterVehicle()

end



local function getUnclaimedMilestonesCount()

  if not career_modules_milestones_milestones or not career_modules_milestones_milestones.unclaimedMilestonesCount then

    return 0

  end

  return career_modules_milestones_milestones.unclaimedMilestonesCount() or 0

end



local function addCareerPathsAction(actions, registerButton)

  if not isCareerPathsAndMilestonesAvailable() then return end

  local unclaimedMilestones = getUnclaimedMilestonesCount()

  table.insert(actions, registerButton({

    id = "home.careerPaths",

    label = _tr("ui.career.landingPage.name"),

    icon = "cup",

    rail = "home",

    routeTarget = "career.domainSelection",

    showIndicator = unclaimedMilestones > 0,

    visible = true,

    enabled = true,

  }, function()

    return pushRoute("career.domainSelection")

  end))

end



local function addCareerMilestonesAction(actions, registerButton)

  if not isCareerPathsAndMilestonesAvailable() then return end

  local unclaimedMilestones = getUnclaimedMilestonesCount()

  table.insert(actions, registerButton({

    id = "home.careerMilestones",

    label = _tr("ui.career.milestones.title"),

    icon = "catalog03",

    rail = "home",

    routeTarget = "career.milestones",

    showIndicator = unclaimedMilestones > 0,

    visible = true,

    enabled = true,

  }, function()

    return pushRoute("pause.milestones")

  end))

end



local function buildRecoveryActions(context, registerButton)

  local actions = {}



  local isSplitOrMulti = (careerSplitScreen and careerSplitScreen.isActive and careerSplitScreen.isActive()) or (context and context.isMultiseatActive)
  local resumeRoute = isSplitOrMulti and "multiseat" or "play"

  table.insert(actions, registerButton({
    id = "home.resume",
    label = _tr("ui.common.action.resume"),
    icon = "play",
    rail = "home",
    routeTarget = resumeRoute,
    visible = true,
    enabled = true,
  }, function()
    if ui_menuManager and ui_menuManager.toggleMenu then
      ui_menuManager.toggleMenu()
      return true
    end
    local target = (ui_menuManager and ui_menuManager.getGameplayRoute and ui_menuManager.getGameplayRoute()) or resumeRoute
    return pushRoute(target)
  end))



  if context.mode == "garage" then

    return actions

  end



  if context.mode == "career" then

    addCareerRecoveryActions(actions, registerButton)

    return actions

  end



  if context.mode == "mission" then

    addMissionRecoveryActions(actions, registerButton)

    return actions

  end



  if context.mode == "multiplayer" or context.mode == "freeroam" or context.mode == "freeroamTutorial" then

    addFreeroamStyleRecoveryActions(context, actions, registerButton)

  end



  return actions

end



local function buildTutorialLessonActions(context, registerButton)

  if context.mode ~= "freeroamTutorial" then return {} end

  if not gameplay_discover_freeroamTutorial_tutorial or not gameplay_discover_freeroamTutorial_tutorial.getActivePhase then return {} end



  local activePhase = gameplay_discover_freeroamTutorial_tutorial.getActivePhase()

  if activePhase == nil or activePhase == "" then return {} end

  if gameplay_discover_freeroamTutorial_lessonRegistry

    and gameplay_discover_freeroamTutorial_lessonRegistry.isIntroMandatoryPhase

    and gameplay_discover_freeroamTutorial_lessonRegistry.isIntroMandatoryPhase(activePhase) then

    return {}

  end



  local actions = {}

  table.insert(actions, registerButton({

    id = "home.freeroamTutorial.stopCurrentLesson",

    label = _tr("ui.experiences.freeroamTutorial.common.button.stopCurrentLesson"),

    icon = "abandon",

    rail = "home",

    routeTarget = "play",

    visible = true,

    enabled = true,

  }, function()

    gameplay_discover_freeroamTutorial_tutorial.setActivePhase("")

    return pushRoute("play")

  end))



  return actions

end



local function buildGuidedFirstDriveResumeActions(registerButton)

  local exp = gameplay_discover_firstDrive_experience

  if not exp or not exp.isGuidedDriveActive or not exp.isGuidedDriveActive() then return {} end



  return {

    registerButton({

      id = "home.firstDrive.continue",

      label = _tr("ui.experiences.firstDrive.pause.continue"),

      icon = "play",

      rail = "home",

      visible = true,

      enabled = true,

    }, function()

      if ui_menuManager and ui_menuManager.toggleMenu then

        ui_menuManager.toggleMenu()

        return true

      end

      return false

    end),

  }

end



local function buildGuidedFirstDriveExitActions(registerButton)

  local exp = gameplay_discover_firstDrive_experience

  if not exp or not exp.isGuidedDriveActive or not exp.isGuidedDriveActive() then return {} end



  return {

    registerButton({

      id = "home.firstDrive.exit",

      label = _tr("ui.experiences.firstDrive.pause.exit"),

      icon = "catalog02",

      rail = "home",

      flavor = "danger",

      confirmText = _tr("ui.experiences.firstDrive.pause.confirmExit"),

      cancelLabel = _tr("ui.pause.common.keepPlaying"),

      visible = true,

      enabled = true,

    }, function()

      exp.onFirstDrivePauseExit()

      return true

    end),

  }

end



local function buildFirstDriveLearningActions(registerButton)

  local exp = gameplay_discover_firstDrive_experience

  if not exp or not exp.isActive or not exp.isActive() then return {} end



  local learning = gameplay_discover_firstDrive_learningFlow

  local hasActiveLesson = learning and learning.hasActiveLesson and learning.hasActiveLesson()

  local actions = {}



  if hasActiveLesson then

    local drivingAssistsLesson = gameplay_discover_firstDrive_lessons_drivingAssists_drivingAssists

    if learning.isLessonActive and learning.isLessonActive("drivingAssists")

      and drivingAssistsLesson and drivingAssistsLesson.canConfirm and drivingAssistsLesson.canConfirm() then

      table.insert(actions, registerButton({

        id = "home.firstDrive.confirmDrivingAssists",

        label = _tr("ui.experiences.freeroamTutorial.drivemode.button.confirm"),

        icon = "checkmark",

        rail = "home",

        routeTarget = "play",

        visible = true,

        enabled = true,

      }, function()

        if not pushRoute("play") then return false end

        return learning.completeLesson("drivingAssists")

      end))

    end

    table.insert(actions, registerButton({

      id = "home.firstDrive.stopLearningLesson",

      label = _tr("ui.experiences.firstDrive.learning.stopLesson"),

      icon = "abandon",

      rail = "home",

      routeTarget = "play",

      visible = true,

      enabled = true,

    }, function()

      learning.cancelActiveLesson("pauseMenu")

      return pushRoute("play")

    end))

  elseif learning and learning.hasPendingAreaLesson and learning.hasPendingAreaLesson() then

    table.insert(actions, registerButton({

      id = "home.firstDrive.skipToTargetArea",

      label = _tr("ui.experiences.firstDrive.learning.skipToTargetArea"),

      icon = "fastTravel",

      rail = "home",

      routeTarget = "play",

      visible = true,

      enabled = true,

    }, function()

      local skipped = learning.skipToTargetArea()

      if skipped then pushRoute("play") end

      return skipped

    end))

  elseif learning and learning.isAvailable and learning.isAvailable() then

    local progress = gameplay_discover_firstDrive_learningProgress

    if progress and progress.areAllLessonsCompleted and progress.areAllLessonsCompleted() then

      table.insert(actions, registerButton({

        id = "home.firstDrive.finishOnboarding",

        label = _tr("ui.experiences.firstDrive.learning.finishOnboarding"),

        icon = "cup",

        rail = "home",

        routeTarget = "firstDrive.completion",

        visible = true,

        enabled = true,

      }, function()

        return exp.openOnboardingCompletion()

      end))

    end

    table.insert(actions, registerButton({

      id = "home.firstDrive.learningAreas",

      label = _tr("ui.experiences.firstDrive.learning.pauseAction"),

      icon = "bookOpened",

      rail = "home",

      routeTarget = "firstDrive.learning",

      visible = true,

      enabled = true,

    }, function()

      return exp.openLearningAreas()

    end))

  end



  return actions

end



local function buildAuxiliaryActions(context, registerButton)

  local actions = {}

  local vehicleSelectorAllowed = context.mode == "freeroam"

    or context.mode == "multiplayer"

    or context.mode == "garage"

    or context.mode == "freeroamTutorial"



  if vehicleSelectorAllowed and not context.isMultiseatActive then

    local permission = { enabled = true }

    local capabilities = gameplay_discover_firstDrive_capabilities

    if capabilities and capabilities.isSessionActive and capabilities.isSessionActive() then

      capabilities.applyUiPermission(permission, "vehicleManagement")

    end

    table.insert(actions, registerButton({

      id = "home.vehicleSelector",

      label = _tr("ui.menu.vehicleSelector.title"),

      icon = "vehicleFeatures01",

      routeTarget = "pause.vehicleSelector",

      visible = true,

      enabled = permission.enabled,

      disabledReason = permission.disabledReason,

    }, function()

      if permission.enabled == false then return false end

      if ui_vehicleSelector_general and ui_vehicleSelector_general.openFromPause then

        ui_vehicleSelector_general.openFromPause()

        return true

      end

      return false

    end))

  end





  if not context.isMultiseatActive then

    if not context.isScenarioActive then

      local mapPermission = {

        enabled = context.isBigMapAllowed,

        disabledReason = context.isBigMapAllowed and nil or "Disabled in current context",

      }

      local mapCapabilities = gameplay_discover_firstDrive_capabilities

      if mapCapabilities and mapCapabilities.isSessionActive and mapCapabilities.isSessionActive() then

        mapCapabilities.applyUiPermission(mapPermission, "bigMap")

      end

      table.insert(actions, registerButton({

        id = "home.map",

        label = _tr("ui.dashboard.bigmap"),

        icon = "mapWithEmitter",

        visible = true,

        enabled = mapPermission.enabled,

        disabledReason = mapPermission.disabledReason,

        routeTarget = "pause.bigmap",

      }, function()

        --if ui_pause_camera then

        --  ui_pause_camera.endPauseSession()

        --end

        if mapPermission.enabled and freeroam_bigMapMode and freeroam_bigMapMode.enterBigMap then

          freeroam_bigMapMode.enterBigMap({instant = true, routeTarget = "pause.bigmap"})

          return true

        end

        return false

      end))

    end

  end



  local photoPermission = { enabled = true }

  local capabilities = gameplay_discover_firstDrive_capabilities

  if capabilities and capabilities.isSessionActive and capabilities.isSessionActive() then

    capabilities.applyUiPermission(photoPermission, "advancedSandbox")

  end

  table.insert(actions, registerButton({

    id = "home.photomode",

    label = _tr("ui.dashboard.photomode"),

    icon = "photo",

    routeTarget = "pause.photomode",

    visible = true,

    enabled = photoPermission.enabled,

    disabledReason = photoPermission.disabledReason,

  }, function()

    if photoPermission.enabled == false then return false end

    return pushRoute("pause.photomode")

  end))



  if not context.isMultiseatActive and not context.isFirstDriveActive then

    table.insert(actions, registerButton({

      id = "home.replay",

      label = _tr("ui.menu.replay"),

      icon = "movieCamera",

      routeTarget = "pause.replay",

      visible = context.mode ~= "career",

      enabled = context.mode ~= "career",

    }, function()

      return pushRoute("pause.replay")

    end))

  end



  return actions

end



local function buildMainMenuActions(context, registerButton)

  local actions = {}



  if context.mode == "freeroam" and not context.isFirstDriveActive then



    table.insert(actions, registerButton({

      id = "home.changeLevel",

      label = _tr("ui.pause.home.changeLevel"),

      icon = "terrain",

      flavor = "system",

      routeTarget = "pause.freeroamLevels",

      visible = true,

      enabled = true,

      hideInSimpleMenu = true,

    }, function()

      if ui_freeroamSelector_general and ui_freeroamSelector_general.openFromPause then

        ui_freeroamSelector_general.openFromPause()

        return true

      end

      return pushRoute("pause.freeroamselector")

    end))

  end



  local hideExitActivityForWizardScenario = context.isScenarioActive

    and scenario_scenarios

    and scenario_scenarios.getScenario

    and isWizardScenario(scenario_scenarios.getScenario())



  if (context.isMissionActive or context.isScenarioActive) and not hideExitActivityForWizardScenario then

    table.insert(actions, registerButton({

      id = "home.exitActivity",

      label = context.isMissionActive and _tr("ui.radialmenu2.missionAbandon") or _tr("ui.pause.home.exitScenario"),

      icon = "abandon",

      flavor = "danger",

      confirmText = context.isMissionActive and _tr("ui.pause.home.confirmExitChallenge") or _tr("ui.pause.home.confirmExitScenario"),

      visible = true,

      enabled = true,

    }, function()

      if context.isMissionActive

        and gameplay_missions_missionScreen

        and gameplay_missions_missionScreen.stopMissionById then

        gameplay_missions_missionScreen.stopMissionById(nil, false, true)

        return true

      end



      if context.isScenarioActive then

        extensions.hook("onGameplayActivityAborted")

      end



      if context.isScenarioActive

        and campaign_campaigns

        and campaign_campaigns.getCampaignActive

        and campaign_campaigns.getCampaignActive() then

        returnToMainMenu()

        return true

      end



      if context.isScenarioActive and scenario_scenarios and scenario_scenarios.stop then

        scenario_scenarios.stop()

        return true

      end



      return pushRoute("play")

    end))

  end



  table.insert(actions, registerButton(Common.withExitConfirm({

    id = "home.exitToMainMenu",

    label = _tr("ui.pause.system.exitLevel"),

    icon = "catalog02",

    flavor = "danger",

    visible = true,

    enabled = true,

  }, context, Common.ExitLevelTexts), function(payload)

    Common.runExit(returnToMainMenu, payload)

    return true

  end))



  return actions

end



local function buildCareerActions(context, registerButton)

  if context.mode ~= "career" then return {} end



  local actions = {}



  table.insert(actions, registerButton({

    id = "home.careerQuicksave",

    label = _tr("ui.career.quicksave"),

    icon = "floppyDisk",

    visible = true,

    enabled = career_career.isAutosaveEnabled(),

  }, function()

    if career_saveSystem and career_saveSystem.saveCurrent then

      career_saveSystem.saveCurrent(nil, true)

      return true

    end

    return false

  end))



  table.insert(actions, registerButton({

    id = "home.careerSaveAs",

    label = _tr("ui.common.save"),

    icon = "saveAs1",

    routeTarget = "career.profiles.saveAs",

    visible = true,

    enabled = career_career.isAutosaveEnabled(),

  }, function()

    return pushRoute("career.profiles.saveAs")

  end))



  table.insert(actions, registerButton({

    id = "home.careerLoad",

    label = _tr("ui.common.load"),

    icon = "folder",

    routeTarget = "career.profiles",

    confirmText = _tr("ui.career.pause.loadProfileMessage"),

    visible = true,

    enabled = career_career.isAutosaveEnabled(),

  }, function()

    return pushRoute("career.profiles")

  end))



  return actions

end



local function buildMultiseatActions(context, registerButton)
  if context.isFirstDriveActive then return {} end

  local isCareer = (career_career and career_career.isActive and career_career.isActive())
    or (overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive())
    or (core_gamestate and core_gamestate.state and (core_gamestate.state.state == "career" or core_gamestate.state.state == "overhaul"))
    or (context.mode == "career" or context.mode == "overhaul")

  local isSplitRunning = false
  if isCareer then
    if careerSplitScreen and careerSplitScreen.isActive and careerSplitScreen.isActive() then
      isSplitRunning = true
    end
  else
    if (careerSplitScreen and careerSplitScreen.isActive and careerSplitScreen.isActive()) or (context and context.isMultiseatActive) then
      isSplitRunning = true
    end
  end

  if (context.mode == "freeroam" or context.mode == "career" or context.mode == "overhaul") and not isSplitRunning then
    local actions = {}
    table.insert(actions, registerButton({
      id = "home.splitScreen",
      label = isCareer and "Start Split-Screen" or _tr("ui.multiseat.title"),
      icon = "splitScreen",
      visible = true,
      enabled = true,
    }, function()
      if isCareer then
        if careerSplitScreen then
          careerSplitScreen.startSplitScreen()
          return pushRoute("multiseat")
        end
      end
      extensions.load("ui_multiseat_freeroam")
      return ui_multiseat_freeroam and ui_multiseat_freeroam.openSettings() or false
    end))
    return actions
  end

  if context.mode ~= "multiseatGamemode" and context.mode ~= "freeroam" and context.mode ~= "career" and context.mode ~= "overhaul" then return {} end
  local actions = {}
  extensions.hook("onPauseHomeRailBuildMultiseatActions", actions, context, registerButton)
  return actions
end




function M.build(context, registerButton)

  if context.isFirstDriveGuided then

    local groups = {}

    local resumeGroup = Common.asRailGroup("recovery", buildGuidedFirstDriveResumeActions(registerButton))

    local exitGroup = Common.asRailGroup("mainMenu", buildGuidedFirstDriveExitActions(registerButton))

    if resumeGroup then table.insert(groups, resumeGroup) end

    if exitGroup then table.insert(groups, exitGroup) end

    return groups

  end



  local groups = {}

  local recoveryGroup = Common.asRailGroup("recovery", buildRecoveryActions(context, registerButton))

  local firstDriveLearningGroup = Common.asRailGroup("firstDriveLearning", buildFirstDriveLearningActions(registerButton))

  local tutorialLessonGroup = Common.asRailGroup("tutorialLesson", buildTutorialLessonActions(context, registerButton))

  local careerGroup = Common.asRailGroup("career", buildCareerActions(context, registerButton))

  local auxiliaryGroup = Common.asRailGroup("auxiliary", buildAuxiliaryActions(context, registerButton))

  local mainMenuGroup = Common.asRailGroup("mainMenu", buildMainMenuActions(context, registerButton))

  local multiseatGroup = Common.asRailGroup("multiseat", buildMultiseatActions(context, registerButton))



  if recoveryGroup then table.insert(groups, recoveryGroup) end

  if firstDriveLearningGroup then table.insert(groups, firstDriveLearningGroup) end

  if tutorialLessonGroup then table.insert(groups, tutorialLessonGroup) end

  if careerGroup then table.insert(groups, careerGroup) end

  if context.isMultiseatActive and multiseatGroup then table.insert(groups, multiseatGroup) end

  if auxiliaryGroup then table.insert(groups, auxiliaryGroup) end

  if not context.isMultiseatActive and multiseatGroup then table.insert(groups, multiseatGroup) end

  if mainMenuGroup then table.insert(groups, mainMenuGroup) end



  local multiseatActionCount = multiseatGroup and #(multiseatGroup.actions or {}) or 0

  log('I', 'pause.homeRail', string.format('build: groups=%d multiseatActions=%d isMultiseatActive=%s',

    #groups, multiseatActionCount, tostring(context.isMultiseatActive)))



  return groups

end



return M

