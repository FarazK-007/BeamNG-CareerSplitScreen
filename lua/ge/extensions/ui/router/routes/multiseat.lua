-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "multiseat"

M.Root = {
  screenId = "multiseat",
  title = "ui.multiseat.title",
  back = { mode = "rootExit" },
  ui = {
    uiNav = true,
    uiTypes = {"vue", "angular"},
    uiTypesFilter = Constants.UiTypesFilter.any,
    infoBar = Constants.InfoBarDefaultsHidden,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = {
      shown = true,
    },
  },
}

M.Children = {}

return M
