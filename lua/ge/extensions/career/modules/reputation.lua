-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local minimumValue = -50
local maximumValue = 700

local reputationValues = {
  returnLoanerDamaged = -20,
  discardDeliveryVehicle = -10
}

local levelDefaults = {
  [-1] = {
    label = "ui.career.organizations.reputation.questionable",
    levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = -1}},
    requiredValue = minimumValue,
    loanerCut = {
      value = 0.5,
      icon = "boxPickUp03"
    },
    deliveryBonus = {
      value = 0.9,
    }
  },
  [0] = {
    label = "ui.career.organizations.reputation.neutral",
    levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 0}},
    requiredValue = -25, -- needs to lose 50 (from 0) to go to -1
    loanerCut = {
      value = 0.35,
      icon = "boxPickUp03"
    },
    deliveryBonus = {
      value = 1,
    }
  },
  [1] = {
    label = "ui.career.organizations.reputation.reliable",
    levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 1}},
    requiredValue = 40, -- needs 50 (from 0) to lvlup to 1
    loanerCut = {
      value = 0.25,
      icon = "boxPickUp03"
    },
    deliveryBonus = {
      value = 1.1,
    }
  },
  [2] = {
    label = "ui.career.organizations.reputation.preferred",
    levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 2}},
    requiredValue = 175, --  needs 150 to lvlup to 2
    loanerCut = {
      value = 0.15,
      icon = "boxPickUp03"
    },
    deliveryBonus = {
      value = 1.2,
    }
  },
  [3] = {
    label = "ui.career.organizations.reputation.partner",
    levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = 3}},
    requiredValue = 400, -- need 250 to lvlup to 3
    loanerCut = {
      value = 0,
      icon = "boxPickUp03"
    },
    deliveryBonus = {
      value = 1.4,
    }
  },
}

local function getValueForEvent(eventId)
  return reputationValues[eventId]
end

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

local function addReputationToOrg(organization)
  if not organization then
    return
  end

  local value = career_modules_playerAttributes.getAttributeValue(organization.id .. "Reputation")
  local level, curLvlProgress, neededForNext, prevThreshold, nextThreshold = calcLevelFromReputationValue(value, organization)
  local data = {
    value = value,
    level = level,
    curLvlProgress = curLvlProgress,
    neededForNext = neededForNext,
    prevThreshold = prevThreshold,
    nextThreshold = nextThreshold
  }

  for i, levelInfo in ipairs(organization.reputationLevels) do
    local defaults = levelDefaults[i-2] or {
      label = "ui.career.organizations.reputation.partner",
      levelLabel = {txt = "ui.career.organizations.reputation.levelLabel", context = {level = i-2}},
      requiredValue = 400 + (i - 5) * 200,
      loanerCut = { value = 0, icon = "boxPickUp03" },
      deliveryBonus = { value = 1.4 }
    }
    for attributeKey, attributeValue in pairs(defaults) do
      if levelInfo[attributeKey] then
        if type(levelInfo[attributeKey]) == "table" then
          for key, value in pairs(attributeValue) do
            levelInfo[attributeKey][key] = levelInfo[attributeKey][key] or value
          end
        end
      else
        levelInfo[attributeKey] = attributeValue
      end
    end
    if levelInfo.label then
      levelInfo.label = core_locales.translateWithOrWithoutContext(levelInfo.label)
    end
    if levelInfo.levelLabel then
      levelInfo.levelLabel = core_locales.translateWithOrWithoutContext(levelInfo.levelLabel)
    end
  end
  organization.reputation = data
end

local function getLabel(lvl)
  local defaults = levelDefaults[lvl]
  if not defaults or not defaults.label then return "" end
  return core_locales.translateWithOrWithoutContext(defaults.label)
end

local function getMinimumValue()
  return minimumValue
end

local function getMaximumValue()
  return maximumValue
end

M.addReputationToOrg = addReputationToOrg
M.getLabel = getLabel
M.getMinimumValue = getMinimumValue
M.getMaximumValue = getMaximumValue
M.getValueForEvent = getValueForEvent

return M
