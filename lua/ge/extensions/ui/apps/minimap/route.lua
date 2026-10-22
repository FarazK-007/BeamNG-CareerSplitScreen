-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- Career Mode Split-Screen Co-op Mod - Per-Player Navigation Route Renderer

local M = {}

local layers = require("ui/apps/minimap/layers")

local routeMaxLength = 3000 -- limit the route to 3000 points

local clrNavBg = color(255, 255, 255, 255)

local playerPalettes = {
  [0] = {
    fg = color(0, 102, 255, 255),       -- Player 1 (Host): Vibrant Royal Blue
    bg = clrNavBg,
    r = 0, g = 102, b = 255
  },
  [1] = {
    fg = color(255, 130, 20, 255),      -- Player 2: Vivid Amber / Orange
    bg = clrNavBg,
    r = 255, g = 130, b = 20
  },
  [2] = {
    fg = color(20, 215, 85, 255),       -- Player 3: Bright Emerald Green
    bg = clrNavBg,
    r = 20, g = 215, b = 85
  },
  [3] = {
    fg = color(205, 50, 255, 255),      -- Player 4: Vivid Purple
    bg = clrNavBg,
    r = 205, g = 50, b = 255
  }
}

local blendDistance = 75
local function getRouteColor(distance, playerIndex)
  playerIndex = playerIndex or 0
  local pal = playerPalettes[playerIndex] or playerPalettes[0]
  if distance > blendDistance then
    return pal.fg
  else
    -- blend between player color and white near the vehicle
    local t = (1 - distance / blendDistance) * 0.66
    return color(
      pal.r + (255 - pal.r) * t,
      pal.g + (255 - pal.g) * t,
      pal.b + (255 - pal.b) * t,
      255
    )
  end
end

local function drawRoute(route, td, dpi, camPos, cullRadius, playerIndex)
  dpi = dpi or 1
  playerIndex = playerIndex or 0
  if not route or not route[1] then
    return
  end

  local startDistance = route[1].distToTarget or 0
  local routeCurrentLength = math.min(#route, routeMaxLength)
  local worldToMapXX, worldToMapXYCoef, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset = ui_apps_minimap_utils.getWorldToMapTransform()
  local tdlineRoundEndWithBackground = td.lineRoundEndWithBackground
  local widthBg, widthFg = 4 * dpi, 2 * dpi
  local layerBG, layerFG = layers.ROUTE_BG, layers.ROUTE_FG
  local cullMinX, cullMinY, cullMaxX, cullMaxY
  if camPos and cullRadius then
    cullMinX, cullMinY = camPos.x - cullRadius, camPos.y - cullRadius
    cullMaxX, cullMaxY = camPos.x + cullRadius, camPos.y + cullRadius
  end

  for i = 1, routeCurrentLength - 1 do
    local p1, p2 = route[i].pos, route[i+1].pos
    local visible = not cullMinX
      or ((p1.x >= cullMinX or p2.x >= cullMinX)
        and (p1.x <= cullMaxX or p2.x <= cullMaxX)
        and (p1.y >= cullMinY or p2.y >= cullMinY)
        and (p1.y <= cullMaxY or p2.y <= cullMaxY))

    if visible then
      local dist1 = route[i].distToTarget or 0
      local dist2 = route[i+1].distToTarget or 0
      local segDist = ((startDistance - dist1) + (startDistance - dist2)) * 0.5
      local color = getRouteColor(segDist, playerIndex)
      tdlineRoundEndWithBackground(td, p1.x, p1.y, p2.x, p2.y, widthFg, widthBg, color, clrNavBg, worldToMapXX, worldToMapXYCoef, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset, layerFG, layerBG)
    end
  end
end

-- Navigation drawing function (per-player)
local routeOverrides = {}
local function drawNavigationRoute(td, dpi, camPos, cullRadius, playerIndex)
  dpi = dpi or 1
  playerIndex = playerIndex or 0

  table.clear(routeOverrides)
  extensions.hook("onMinimapRouteOverride", routeOverrides)
  if next(routeOverrides) then
    for _, route in ipairs(routeOverrides) do
      drawRoute(route, td, dpi, camPos, cullRadius, playerIndex)
    end
    return
  end

  local route = nil
  if core_groundMarkers and core_groundMarkers.getPathForPlayer then
    route = core_groundMarkers.getPathForPlayer(playerIndex)
  end
  if not route and playerIndex == 0 and core_groundMarkers and core_groundMarkers.routePlanner then
    route = core_groundMarkers.routePlanner.path
  end

  if route and route[1] then
    drawRoute(route, td, dpi, camPos, cullRadius, playerIndex)
  end
end

local function drawRoutePointer(td, playerIndex)
  playerIndex = playerIndex or 0
  local route = nil
  if core_groundMarkers and core_groundMarkers.getPathForPlayer then
    route = core_groundMarkers.getPathForPlayer(playerIndex)
  end
  if not route and playerIndex == 0 and core_groundMarkers and core_groundMarkers.routePlanner then
    route = core_groundMarkers.routePlanner.path
  end

  if not route or not route[1] then
    return
  end

  local pal = playerPalettes[playerIndex] or playerPalettes[0]
  ui_apps_minimap_utils.simpleCircleWithEdgePointer(route[#route].pos, pal.fg, pal.bg, 9)
end

M.drawNavigationRoute = drawNavigationRoute
M.drawRoutePointer = drawRoutePointer
M.playerPalettes = playerPalettes

return M
