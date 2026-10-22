-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local Constants = require("ge/extensions/ui/router/constants")
local TransitionManager = require("ge/extensions/ui/router/managers/transitionManager")
local FrameworkManager = require("ge/extensions/ui/router/managers/frameworkManager")
local GuardManager = require("ge/extensions/ui/router/managers/guardManager")
local NavigationState = require("ge/extensions/ui/router/navigationState")
local NavigationContextService = require("ge/extensions/ui/router/services/navigationContext")
local RouteHandlers = require("ge/extensions/ui/router/routeHandlers")
local BreadcrumbManager = require("ge/extensions/ui/router/managers/breadcrumbManager")
local ScopeManager = require("ge/extensions/ui/router/managers/scopeManager")
local ResolvedRoute = require("ge/extensions/ui/router/models/ResolvedRoute")
local LifecycleExecutor = require("ge/extensions/ui/router/lifecycleExecutor")
local RouteReference = require("ge/extensions/ui/router/routeReference")

-- Non-shipping diagnostics only. Required (and invoked) solely when not a shipping build so no
-- observer work happens in shipping.
local NavigationObserver = shipping_build ~= true and require("ge/extensions/ui/router/navigationObserver") or nil

local navigationEpoch = 0
local activeRouteData = {}

-- Protected navigation lock. A navigation requested with options.cancellable == false acquires an
-- identity-safe token that blocks every newer navigate/back/reload until that navigation reaches a
-- terminal state (completion, cancellation, failure, timeout, reset, deserialization). The token is
-- a unique value (not a boolean) so cleanup can release only the exact navigation that acquired it,
-- never a newer protected navigation that replaced it.
local activeProtectionToken = nil
local protectionCounter = 0

local function acquireNavigationProtection()
  protectionCounter = protectionCounter + 1
  activeProtectionToken = "navProtect_" .. protectionCounter
  return activeProtectionToken
end

-- Release only when the supplied token still owns the lock. A nil token or a token that no longer
-- matches (already replaced/released) is a no-op, so terminal cleanup of an older transition can
-- never clear the token of a newer protected navigation.
local function releaseNavigationProtection(token)
  if token ~= nil and activeProtectionToken == token then
    activeProtectionToken = nil
  end
end

local activeScopeState = {
  activeScopeId = nil,
  previousActiveScopeId = nil,
  routeName = nil,
}

local function beginNavigationEpoch()
  navigationEpoch = navigationEpoch + 1
  return navigationEpoch
end

local function isEpochCurrent(epoch)
  return epoch == navigationEpoch
end

local function routeSummary(route)
  if not route then
    return nil
  end

  return {
    name = route.name,
    screenId = route.screenId or route.name,
    params = route.params or {},
    query = route.query or {},
    meta = route.meta or {},
  }
end

local function containsValue(list, value)
  if type(list) ~= "table" then
    return false
  end
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

local function routeExpectsHandoff(resolved)
  local ui = resolved and resolved.ui
  if type(ui) ~= "table" then
    return false
  end
  if ui.uiTypesFilter ~= Constants.UiTypesFilter.only then
    return false
  end
  return containsValue(ui.uiTypes, "vue")
end

local function routeExpectsMountAck(resolved)
  local ui = resolved and resolved.ui
  if type(ui) ~= "table" then
    return false
  end
  return containsValue(ui.uiTypes, "vue")
end

local function asNonEmptyString(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

-- Vue acknowledgements must echo back a non-empty transition id so Lua validates against the exact
-- active transition. Angular/legacy callers keep the route-name fallback (id optional). The check
-- only applies while a transition is active, so an idle router still reports no_active_transition.
local function missingVueTransitionId(frameworkId, transitionId)
  if frameworkId ~= "vue" then
    return false
  end
  if not TransitionManager.isTransitioning() then
    return false
  end
  return asNonEmptyString(transitionId) == nil
end

local function getCommittedRouteName()
  local currentEntry = NavigationState.getCurrentEntry()
  local request = currentEntry and currentEntry.request
  local name = request and request.name
  if type(name) == "string" and name ~= "" then
    return name
  end
  return nil
end

local function buildEffectiveOptions(options, routeScopeId)
  local effectiveOptions = {}
  if type(options) == "table" then
    for key, value in pairs(options) do
      effectiveOptions[key] = value
    end
  end

  if routeScopeId then
    effectiveOptions.routeScopeId = routeScopeId
  end

  return effectiveOptions
end

local function getNamespace(route)
  local routeMeta = route and route.meta or {}
  if type(routeMeta.routeDataNamespace) == "string" and routeMeta.routeDataNamespace ~= "" then
    return routeMeta.routeDataNamespace
  end

  local routeName = route and route.name or ""
  if type(routeName) == "string" and routeName ~= "" then
    local tokens = string.split(routeName, "[^%.]+")
    return tokens[1] or "route"
  end

  return "route"
end

local function emitRouteData(route, fromRoute, data, status, err, extras)
  extras = extras or {}
  guihooks.trigger("ui_router_routeData", {
    namespace = getNamespace(route),
    route = routeSummary(route),
    fromRoute = routeSummary(fromRoute),
    scopeTree = route and route.scopeTree or nil,
    scopeParentMap = route and ScopeManager.buildScopeParentMap(route.scopeTree) or nil,
    targetScope = extras.targetScope or nil,
    breadcrumbs = extras.breadcrumbs or nil,
    data = data,
    status = status,
    error = err or nil,
  })
end

local function buildNavigationContext(toRoute, fromRoute, kind, extras)
  return NavigationContextService.buildNavigationContext(toRoute, fromRoute, kind, extras)
end

local function runOnLeave(toRoute, fromRoute, options)
  local currentRoute = NavigationState.getCurrentRouteNode()
  if not currentRoute then
    return true
  end

  local leaveData = type(activeRouteData) == "table" and activeRouteData or {}
  local leaveContext = buildNavigationContext(toRoute, fromRoute, "leave", options)
  local ok, _ = LifecycleExecutor.runLifecycleHook(currentRoute, "onLeave", leaveContext, toRoute, fromRoute, leaveData)
  return ok
end

local function executeExitGuards(route, params, context)
  local data = {
    result = true
  }
  local currentNode = NavigationState.getCurrentEntry()
  if not currentNode then
    return data
  end
  local exitGuards = currentNode.resolved.exitGuards
  if not exitGuards or #exitGuards == 0 then
    return data
  end
  return GuardManager.executeGuards(exitGuards, route, params, context)
end

local function executeEnterGuards(route, params)
  local data = {
    result = true
  }
  local enterGuards = route.enterGuards
  if not enterGuards or #enterGuards == 0 then
    return data
  end
  return GuardManager.executeGuards(enterGuards, route, params)
end

local function updateDecorator(routename, options)
  local moduleName = string.split(routename, "[^%.]+")[1]
  if type(options) ~= "table" then
    if NavigationState.getDecoratorModule() ~= moduleName then
      NavigationState.clearDecorator()
    end
    return
  end
  if options.decorator then
    NavigationState.setDecorator(options.decorator, moduleName)
  elseif NavigationState.getDecoratorModule() ~= moduleName then
    NavigationState.clearDecorator()
  end
  if options.showDecorator ~= nil then
    NavigationState.setDecoratorVisible(options.showDecorator)
  end
end

local function navigationFailure(reason, extras)
  local result = {
    result = false,
    success = false,
    reason = reason,
  }

  if type(extras) == "table" then
    for key, value in pairs(extras) do
      result[key] = value
    end
  end

  return result
end

local function navigationPreemptedFailure()
  return navigationFailure("navigation_preempted", {
    message = "Navigation preempted",
  })
end

local function resolveNavigationTarget(routename, params, options)
  -- Split off any inline query (?a=1) and scope (:scope) decoration, then resolve
  -- a possibly-relative route name against the currently committed route.
  local parsed = RouteReference.parse(routename)
  local routeScopeId = asNonEmptyString(parsed.scope)

  local baseRouteName, resolveErr = extensions.ui_router_routeManager.resolveRouteName(parsed.route, getCommittedRouteName())
  if resolveErr then
    log("W", "", "Failed to resolve route reference: " .. tostring(routename) .. " (" .. resolveErr .. ")")
    return nil, navigationFailure(resolveErr)
  end

  local route = extensions.ui_router_routeManager.getRoute(baseRouteName)
  if not route then
    log("W", "", "Route not found: " .. tostring(baseRouteName))
    return nil, navigationFailure("route_not_found")
  end

  local effectiveOptions = buildEffectiveOptions(options, routeScopeId)
  -- Explicit params win over inline query params on collision.
  local effectiveParams = RouteReference.mergeParams(parsed.params, params)

  -- Canonical, query-free full route reference: base[:scope]. The inline query
  -- is intentionally dropped so a reload replays effective params from
  -- request.params instead of re-parsing the query string.
  local fullRouteName = baseRouteName
  if routeScopeId then
    fullRouteName = baseRouteName .. ":" .. routeScopeId
  end

  return {
    route = route,
    baseRouteName = baseRouteName,
    fullRouteName = fullRouteName,
    params = effectiveParams,
    options = effectiveOptions,
  }
end

local function guardFailure(reason, guardResult)
  return navigationFailure(reason, {
    failedGuard = guardResult.failedGuard,
  })
end

local function getActiveTransitionRoutes()
  local transitionContext = TransitionManager.getTransitionContext()
  local toRoute = transitionContext and transitionContext.toRoute or NavigationState.getCurrentRouteNode()
  local fromRoute = transitionContext and transitionContext.fromRoute or nil
  return toRoute, fromRoute
end

--[[
  How long a navigation took, for whoever wants to report on it.

  Stamped with os.clockhp() and not the transition's accumulated dtReal, because a frame that
  stalls while a screen loads is exactly the wait a player sits through, and dtReal only moves
  while the gui update runs.

  The clock starts when navigate() is called and not when the transition starts, because the
  guards and onEnter run in between and a route that loads its data there would otherwise
  have that time missing from its own measurement.

  Three numbers come out of it:
    total  navigate() until the navigation finished
    enter  the part before the transition even started: exit guards, onLeave, enter guards
           and onEnter. Lua side work
    ready  the part after the route was committed, which is where a screen waits on its own
           data and on its animations
  Whatever is left over is the handoff to the UI framework and its own router.

  mountAcked tells the two kinds of route apart. One that never acknowledges a mount finishes
  at the commit, so its total stops earlier and does not compare against one that does.

  Where the end is: routeMounted is acked one Vue tick after the component tree updated, which
  is after the DOM is right but, in a production build, before the browser has painted it. So
  this is a close floor for the first usable frame rather than the frame itself.
]]
local navigateCalledAt = nil

local function stampNavigationMilestone(milestone)
  local session = TransitionManager.getSession()
  if not session then return end
  session.milestoneAt = session.milestoneAt or {}
  session.milestoneAt[milestone] = os.clockhp()
end

local function navigationTimings()
  local session = TransitionManager.getSession()
  local at = session and session.milestoneAt
  if not at or not at.started then return nil end

  local finished = at.mounted or at.committed
  if not finished then return nil end

  local function ms(from, to)
    return math.floor((to - from) * 1000 + 0.5)
  end

  return {
    total = ms(at.started, finished),
    enter = at.transition and ms(at.started, at.transition) or nil,
    ready = at.mounted and at.committed and ms(at.committed, at.mounted) or nil,
    mountAcked = at.mounted ~= nil,
  }
end

local function completeActiveTransition(routeName, routeData, transitionId)
  activeRouteData = routeData
  -- read before completing, which drops the session the stamps (and protection token) live on
  local session = TransitionManager.getSession()
  local protectionToken = session and session.protectionToken or nil
  local timings = navigationTimings()
  local success, reason = TransitionManager.complete(routeName, transitionId)
  -- Only release once the transition actually completed; a rejected (e.g. id mismatch) completion
  -- leaves the protected transition active and must keep its lock.
  if success then
    releaseNavigationProtection(protectionToken)
  end
  if timings then
    extensions.hook(Constants.RouterExtensionHooks.ROUTE_TIMING, routeName, timings)
  end
  return success, reason
end

local function cancelActiveTransition(reason, extras)
  extras = extras or {}
  -- Capture the cancelled session's token before TransitionManager drops the session. Releasing by
  -- the session token (not the live global) keeps a replacement cancel from clearing a newer
  -- protected navigation's lock: an older, unprotected session simply carries no token.
  local session = TransitionManager.getSession()
  local protectionToken = session and session.protectionToken or nil
  local toRoute, fromRoute = getActiveTransitionRoutes()
  local wasCancelled, cancelledId = TransitionManager.cancel(reason)

  if wasCancelled then
    releaseNavigationProtection(protectionToken)
  end

  -- Drop any uncommitted pending entry so a superseded/aborted navigation leaves no stale state.
  NavigationState.clearPendingEntry()

  if extras.notify == false then
    return wasCancelled
  end

  -- Preserve the cancelled transition id in the notification so the UI can clear only the
  -- handoff that matches the cancelled transition.
  FrameworkManager.sendRouteChangeCancelled(toRoute, { transitionId = cancelledId, reason = reason })

  -- Internal replacements (a newer navigation superseding this one) still notify the UI so it can
  -- drop the matching handoff, but suppress the public cancel hook; the incoming navigation owns it.
  if extras.suppressPublic then
    return wasCancelled
  end

  local hookPayload = {
    toRoute = toRoute,
    fromRoute = fromRoute,
    reason = reason,
    transitionId = cancelledId,
  }
  if type(extras.hook) == "table" then
    for key, value in pairs(extras.hook) do
      hookPayload[key] = value
    end
  end
  extensions.hook(Constants.RouterHooks.ROUTE_CHANGE_CANCELLED, hookPayload)

  return wasCancelled
end

local function timeoutActiveTransition(reason, classification)
  reason = reason or "timeout_reached"

  local session = TransitionManager.getSession()
  local timeoutInfo = TransitionManager.getTimeoutInfo(classification)
  local timeoutClassification = timeoutInfo.classification
  local phase = timeoutInfo.phase
  local phaseElapsed = timeoutInfo.phaseElapsed
  local totalElapsed = timeoutInfo.totalElapsed
  local handoffAttempts = timeoutInfo.handoffAttempts

  local toRoute, fromRoute = getActiveTransitionRoutes()

  log("W", "Router", string.format(
      "Transition timeout for route: %s reason: %s classification: %s phase: %s phaseElapsed: %.2fs totalElapsed: %.2fs handoffAttempts: %s",
      tostring(toRoute and toRoute.name), tostring(reason), tostring(timeoutClassification),
      tostring(phase), phaseElapsed, totalElapsed, tostring(handoffAttempts)))

  local timeoutRouteData = session and session.routeData or {}
  local timeoutTargetScope = toRoute and toRoute.scope and toRoute.scope.targetScope or nil
  local timeoutBreadcrumbs = toRoute and toRoute.breadcrumbs or nil
  emitRouteData(toRoute, fromRoute, timeoutRouteData, "error", "transition timeout: " .. timeoutClassification, {
    targetScope = timeoutTargetScope,
    breadcrumbs = timeoutBreadcrumbs,
  })
  activeRouteData = timeoutRouteData

  cancelActiveTransition(reason, {
    hook = {
      timeoutClassification = timeoutClassification,
      phase = phase,
      phaseElapsed = phaseElapsed,
      totalElapsed = totalElapsed,
      handoffAttempts = handoffAttempts,
    },
  })
end

local function cancelActiveTransitionIfNeeded(replacementAttempt)
  if not TransitionManager.isTransitioning() then
    return
  end

  -- The active transition being replaced is a proven preemption: report it before cancelling,
  -- reading the preempted attempt off the active transition session.
  if NavigationObserver and replacementAttempt then
    local session = TransitionManager.getSession()
    if session then
      NavigationObserver.reportPreemption(session.observerAttempt, replacementAttempt, "active_transition")
    end
  end

  -- log("D", "", "Transition is currently in progress, cancelling the current transition")
  -- Preempted navigation: emit a transition-scoped cancelled event so the UI drops the superseded
  -- handoff, but suppress the public hook; the incoming navigation owns it.
  cancelActiveTransition("navigation_replaced", { suppressPublic = true })
end

local function runEnterLifecycle(entry, fromRoute, options)
  local routeData = {}
  local resolved = entry.resolved
  -- onEnter receives entry.resolved (with merged effective params) so it observes
  -- the same params as onMount, which is handed the transition context's toRoute
  -- (also entry.resolved). Hook lookup still uses the route node config, which
  -- carries the onEnter/onMount/onLeave function references.
  local navigationContext = buildNavigationContext(resolved, fromRoute, "navigate", options)
  local enterOk, enterErr, enterIsHard = LifecycleExecutor.runLifecycleHook(entry.routeNode, "onEnter", navigationContext, resolved, fromRoute, routeData)

  if enterIsHard then
    return nil, navigationFailure("lifecycle_hook_error")
  end

  return {
    routeData = routeData,
    navigationContext = navigationContext,
    enterOk = enterOk,
    enterErr = enterErr,
  }
end

local function buildNavigationEntry(target, previousEntry)
  local params = target.params
  local targetScopeInfo = ScopeManager.getTargetScope(target.route, target.options)
  local targetScope = targetScopeInfo.targetScope

  updateDecorator(target.baseRouteName, target.options)
  local decorator = NavigationState.isDecoratorVisible() and NavigationState.getDecorator() or nil
  local breadcrumbs = BreadcrumbManager.buildBreadcrumbs(target.baseRouteName, target.route, params, decorator)

  local request = ResolvedRoute.createRequest(target.baseRouteName, params, nil, target.options, target.fullRouteName)
  local entry = ResolvedRoute.createEntry(target.route, request, {
    breadcrumbs = breadcrumbs,
    scope = targetScopeInfo,
  }, previousEntry)

  return {
    entry = entry,
    breadcrumbs = breadcrumbs,
    targetScope = targetScope,
  }
end

local function emitInitialRouteData(entryInfo, enterState)
  emitRouteData(entryInfo.entry.resolved, entryInfo.entry.fromRoute, enterState.routeData, enterState.enterOk and "enter-ready" or "error", enterState.enterErr, {
    targetScope = entryInfo.targetScope,
    breadcrumbs = entryInfo.breadcrumbs,
  })
end

local function createTransitionMeta(entry, routeName, enterState, attempt, protectionToken)
  local expectsHandoff = routeExpectsHandoff(entry.resolved)

  return {
    routeName = routeName,
    routeData = enterState.routeData,
    -- Identity-safe protected-navigation token (nil for cancellable navigations). Carried on the
    -- session so terminal cleanup releases exactly this navigation's lock.
    protectionToken = protectionToken,
    -- Non-shipping diagnostics only: lets a later replacing navigation attribute this transition
    -- back to the navigate() that started it. nil in shipping builds.
    observerAttempt = attempt,
    skipOnMount = not enterState.enterOk,
    mounted = false,
    routeChangeCommitted = false,
    navigationContext = enterState.navigationContext,
    -- Kept for handoff resends: the exact pending entry to re-emit without re-running setup.
    pendingEntry = entry,
    -- Phase state. `phase` is nil for non-phased (Angular/legacy) transitions, which keep
    -- the flat TransitionManager timeout. Phased framework transitions start in the indefinite
    -- `startup` phase and own their own budget.
    phase = expectsHandoff and "startup" or nil,
    phaseElapsed = 0,
    totalElapsed = 0,
    timeSinceLastEmit = 0,
    handoffAttempts = 1, -- the initial sendRouteChange below counts as attempt 1
    -- Only consulted for phased (handoff) transitions, where routeExpectsMountAck is
    -- already implied by expectsHandoff, so this matches the previous expectsHandoff-based value.
    expectsMountAck = routeExpectsMountAck(entry.resolved) and enterState.enterOk or false,
    progress = {
      routeChangeReceived = false,
      routeNavigationStarted = false,
      routeChangeCommitted = false,
      routeMounted = false,
    },
  }
end

--[[
  Transition acknowledgement protocol.

  A navigation is a handshake between Lua (this router) and the UI frameworks. Lua owns the
  navigation orchestration and decides what to do at each step; the framework reports progress
  back through the M.route* entry points below. The happy-path sequence is:

    1. Lua emits the route change      -> startNavigationTransition() -> FrameworkManager.sendRouteChange()
    2. UI framework acknowledges it     -> M.routeChangeReceived()      (progress.routeChangeReceived)
    3. Vue Router reports it started    -> M.routeNavigationStarted()   (progress.routeNavigationStarted)
    4. Framework commits the route      -> M.routeChangeComplete()      (promotes pending entry)
    5. Vue routes that need readiness   -> M.routeMounted()             (runs onMount, completes)

  Module boundaries:
    - TransitionManager owns the active transition session: progress milestones, phase,
      phase/total elapsed time, handoff resend timing, and timeout classification. It exposes
      the session via getSession()/markProgress()/markCommitted()/markMounted()/getTimeoutInfo()
      and returns resend/timeout events from update(); it performs no side effects itself.
    - router.lua (this file) owns navigation orchestration and side effects: it decides when to
      start a transition, promotes pending entries, runs lifecycle hooks (onMount), emits route
      data, and reacts to TransitionManager events by calling FrameworkManager.
    - FrameworkManager owns the outbound guihooks to the UI frameworks (sendRouteChange/*Complete/*Cancelled).

  Completion depends on the mount-ack predicate: routes that expect a Vue mount ack finish at
  step 5 (M.routeMounted), everything else finishes at step 4 (M.routeChangeComplete).
]]
local function startNavigationTransition(entry, routeName, enterState, attempt, protectionToken)
  NavigationState.setPendingEntry(entry)

  local session = createTransitionMeta(entry, routeName, enterState, attempt, protectionToken)
  -- the guards and onEnter already ran, so the session inherits the time navigate() started
  session.milestoneAt = {started = navigateCalledAt or os.clockhp(), transition = os.clockhp()}
  local started, transitionId = TransitionManager.start({ toRoute = entry.resolved, fromRoute = entry.fromRoute, session = session })

  FrameworkManager.sendRouteChange(entry, started and transitionId or nil)
  extensions.hook(Constants.RouterHooks.BEFORE_ROUTE_CHANGE, entry)
end

M.navigate = function(routename, params, options)
  if routename == "play" then
    if ui_menuManager and ui_menuManager.getGameplayRoute then
      local gpRoute = ui_menuManager.getGameplayRoute()
      if gpRoute and gpRoute ~= "play" then
        routename = gpRoute
      end
    end
  end
  -- Admission gate: while a protected (cancellable=false) navigation is active, reject every newer
  -- request up front, before observer registration, route resolution, guards, or lifecycle hooks.
  -- Blocked requests are not queued and identical requests are not special-cased.
  if activeProtectionToken ~= nil then
    log("D", "Router", "navigate blocked: a protected navigation is active for " .. tostring(routename))
    return navigationFailure("active_navigation_not_cancellable")
  end

  navigateCalledAt = os.clockhp()

  -- Begin the attempt before any router wrapper obscures the external caller. Non-shipping only.
  local attempt = NavigationObserver and NavigationObserver.beginAttempt() or nil

  local target, resolveFailure = resolveNavigationTarget(routename, params, options)
  if resolveFailure then
    return resolveFailure
  end

  if NavigationObserver then
    NavigationObserver.attachResolvedTarget(attempt, target)
  end

  -- Acquire protection once the request has resolved, before exit guards run, so a cancellable=false
  -- navigation is protected across its entire flow. nil/true keep the last-navigation-wins behavior.
  local protectionToken = nil
  if target.options and target.options.cancellable == false then
    protectionToken = acquireNavigationProtection()
  end

  local canExit = executeExitGuards(target.route, target.params, {
    routeName = target.fullRouteName,
    options = target.options,
  })
  if canExit.result == false then
    releaseNavigationProtection(protectionToken)
    return guardFailure("guard_blocked_exit", canExit)
  end

  local epoch = beginNavigationEpoch()
  local previousEntry = NavigationState.getCurrentEntry()
  local fromRoute = previousEntry and ResolvedRoute.toCompatRoute(previousEntry.resolved) or nil

  cancelActiveTransitionIfNeeded(attempt)
  runOnLeave(target.route, fromRoute, target.options)

  local canEnter = executeEnterGuards(target.route, target.params)
  if canEnter.result == false then
    releaseNavigationProtection(protectionToken)
    return guardFailure("guard_blocked_enter", canEnter)
  end

  if not isEpochCurrent(epoch) then
    -- A re-entrant navigate() (during exit guards / onLeave / enter guards) bumped the epoch.
    releaseNavigationProtection(protectionToken)
    if NavigationObserver then
      NavigationObserver.reportPreemption(attempt, NavigationObserver.getCurrentAttempt(), "post_guard")
    end
    return navigationPreemptedFailure()
  end

  -- Build the entry (and entry.resolved) before onEnter so both lifecycle sites
  -- observe the same effective params through entry.resolved.
  local entryInfo = buildNavigationEntry(target, previousEntry)

  local enterState, enterFailure = runEnterLifecycle(entryInfo.entry, fromRoute, target.options)
  if enterFailure then
    releaseNavigationProtection(protectionToken)
    return enterFailure
  end

  emitInitialRouteData(entryInfo, enterState)

  if not isEpochCurrent(epoch) then
    -- A re-entrant navigate() during onEnter bumped the epoch.
    releaseNavigationProtection(protectionToken)
    if NavigationObserver then
      NavigationObserver.reportPreemption(attempt, NavigationObserver.getCurrentAttempt(), "post_enter")
    end
    return navigationPreemptedFailure()
  end

  startNavigationTransition(entryInfo.entry, target.baseRouteName, enterState, attempt, protectionToken)

  return {
    result = true,
    success = true,
    data = entryInfo.entry
  }
end

M.back = function(options)
  -- dump("ui_router.back: ", { options = options })
  local currentEntry = NavigationState.getCurrentEntry()
  if not currentEntry then
    log("W", "", "back: no current route, doing nothing")
    return {
      result = false,
      reason = "no_current_route"
    }
  end

  local backTarget = currentEntry.resolved.backTarget
  if backTarget then
    -- Prefer the previous stack entry's params when it matches backTarget (e.g. child -> implicit parent back);
    -- otherwise fall back to the current entry's params (explicit backTarget or deep-linked child with no match).
    local backParams
    local prevEntry = NavigationState.getPreviousEntry()
    if prevEntry and prevEntry.request and prevEntry.request.name == backTarget then
      backParams = prevEntry.request.params or {}
    else
      backParams = (currentEntry.request and currentEntry.request.params) or {}
    end
    local backOptions = buildEffectiveOptions(options)
    backOptions.restoreLastScope = true
    return M.navigate(backTarget, backParams, backOptions)
  end

  local currentRouteNode = currentEntry.routeNode
  if currentRouteNode and currentRouteNode.back and currentRouteNode.back.mode == "handler" then
    local handler = RouteHandlers.getHandler(currentRouteNode.back.handler)
    if handler then
      return handler()
    end
  end
end

M.cancel = function(options)
  -- dump("ui_router.cancel")
  if not TransitionManager.isTransitioning() then
    log("W", "", "No transition in progress, cannot cancel")
    return {
      success = false,
      message = "No transition in progress, cannot cancel"
    }
  end

  cancelActiveTransition("cancelled")

  return {
    success = true
  }
end

M.getCurrent = function()
  local entry = NavigationState.getCurrentEntry()
  if entry and entry.resolved and entry.resolved.name == "multiseat" then
    if career_career and career_career.isActive and career_career.isActive() then
      local copy = shallowcopy(entry)
      copy.resolved = shallowcopy(entry.resolved)
      copy.resolved.name = "play"
      return copy
    end
  end
  return entry
end

M.reload = function(routeName, params, options)
  -- dump("reload: " .. (routeName or ""))
  local currentEntry = NavigationState.getCurrentEntry()
  local targetRouteName = routeName
  local targetParams = params
  local targetOptions = options

  if currentEntry then
    if not targetRouteName then
      targetRouteName = currentEntry.request.name
    end
    if not targetParams then
      targetParams = currentEntry.request.params
    end
    if not targetOptions then
      targetOptions = currentEntry.request.options
    end
  end

  if not targetRouteName then
    log("W", "Router", "reload failed: no target route available")
    return {
      success = false,
      message = "No route available to reload"
    }
  end

  return M.navigate(targetRouteName, targetParams, targetOptions)
end

M.routeChangeReceived = function(frameworkId, routeName, transitionId)
  -- log("I", "", "routeChangeReceived: " .. routeName)
  return TransitionManager.markProgress(routeName, "routeChangeReceived", transitionId)
end

M.routeNavigationStarted = function(frameworkId, routeName, transitionId)
  -- log("I", "", "routeNavigationStarted: " .. routeName)
  if missingVueTransitionId(frameworkId, transitionId) then
    log("W", "Router", "routeNavigationStarted from vue requires a transition id for route: " .. tostring(routeName))
    return { success = false, reason = "missing_transition_id" }
  end
  return TransitionManager.markProgress(routeName, "routeNavigationStarted", transitionId)
end

--[[
  Definitive UI rejection of an in-flight route change.

  This is only for structurally impossible / malformed requests that can never resolve on the
  UI side. Missing routes are NOT rejected here: runtime/mod routes may register later, so those
  requests stay retryable via the startup resends. When the rejection matches the active
  transition, cancel it (clearing the pending entry) and notify with the transition id.

  @param frameworkId - Framework reporting the rejection (e.g. "vue")
  @param routeName - Route the UI rejected
  @param transitionId - Active transition id being echoed back (validated when provided)
  @param reason - Optional rejection reason for diagnostics
  @return { success, reason? }
]]
M.routeChangeRejected = function(frameworkId, routeName, transitionId, reason)
  if not TransitionManager.isTransitioning() then
    log("W", "Router", "routeChangeRejected received without active transition: " .. tostring(routeName))
    return { success = false, reason = "no_active_transition" }
  end

  -- Validate the transition id (when provided) so a stale rejection can't cancel a newer
  -- transition. Missing ids fall back to accepting the rejection for the active transition.
  local activeTransitionId = TransitionManager.getTransitionId()
  if transitionId ~= nil and activeTransitionId ~= nil and transitionId ~= activeTransitionId then
    log("W", "Router", "routeChangeRejected transition id mismatch. Expected: " ..
        tostring(activeTransitionId) .. ", Got: " .. tostring(transitionId))
    return { success = false, reason = "transition_id_mismatch" }
  end

  log("W", "Router", "Route change rejected by " .. tostring(frameworkId) .. " for route: " ..
      tostring(routeName) .. " reason: " .. tostring(reason))
  cancelActiveTransition("route_change_rejected", {
    hook = { rejectedReason = reason },
  })
  return { success = true }
end

M.routeChangeComplete = function(frameworkId, routeName, transitionId)
  -- log("I", "", "routeChangeComplete: " .. routeName)
  if not TransitionManager.isTransitioning() then
    log("W", "Router", "routeChangeComplete received without active transition: " .. tostring(routeName))
    return { success = false, reason = "no_active_transition" }
  end

  if missingVueTransitionId(frameworkId, transitionId) then
    log("W", "Router", "routeChangeComplete from vue requires a transition id for route: " .. tostring(routeName))
    return { success = false, reason = "missing_transition_id" }
  end

  local session = TransitionManager.getSession()
  if not session then
    log("W", "Router", "routeChangeComplete missing transition metadata for route: " .. tostring(routeName))
    return { success = false, reason = "missing_transition_meta" }
  end

  if session.routeChangeCommitted then
    return { success = true, alreadyCommitted = true }
  end

  local pendingEntry = NavigationState.getPendingEntry()
  if not pendingEntry then
    log("W", "Router", "routeChangeComplete missing pending entry for route: " .. tostring(routeName))
    return { success = false, reason = "missing_pending_entry" }
  end

  local pendingRouteName = pendingEntry.resolved and pendingEntry.resolved.name or nil
  if routeName ~= pendingRouteName then
    log("W", "Router", "routeChangeComplete route mismatch. Expected: " .. tostring(pendingRouteName) .. ", Got: " .. tostring(routeName))
    return { success = false, reason = "route_mismatch" }
  end

  -- Validate the transition id (when provided) before promoting, so a stale
  -- acknowledgement can't commit the wrong entry. Missing ids fall back to route-name validation.
  local activeTransitionId = TransitionManager.getTransitionId()
  if transitionId ~= nil and activeTransitionId ~= nil and transitionId ~= activeTransitionId then
    log("W", "Router", "routeChangeComplete transition id mismatch. Expected: " .. tostring(activeTransitionId) .. ", Got: " .. tostring(transitionId))
    return { success = false, reason = "transition_id_mismatch" }
  end

  NavigationState.promotePendingEntry()
  TransitionManager.markCommitted(routeName, transitionId)
  stampNavigationMilestone("committed")

  local currentEntry = NavigationState.getCurrentEntry()
  if not currentEntry then
    log("W", "Router", "routeChangeComplete failed to promote route: " .. tostring(routeName))
    return { success = false, reason = "missing_current_entry" }
  end

  FrameworkManager.sendRouteChangeComplete(currentEntry)
  extensions.hook(Constants.RouterExtensionHooks.AFTER_ROUTE_CHANGE, currentEntry)
  extensions.hook("onUiChangedState", currentEntry.request.name,
      currentEntry.origin and currentEntry.origin.route or "")

  local needsVueMountAck = routeExpectsMountAck(currentEntry.resolved)

  if session.skipOnMount or not needsVueMountAck then
    completeActiveTransition(routeName, session.routeData, transitionId)
  end

  return { success = true }
end

--[[
  Framework-reported navigation failure (e.g. the Vue push rejected because a component
  chunk failed to load). Rolls back the in-flight navigation without disturbing the
  committed route:
    - validates the failure against the active transition (route + transition id),
    - rejects a failure that arrives after commit (too late to roll back safely),
    - runs the pending destination's onLeave to reverse its onEnter side effects,
    - cancels the matching transition (which clears the pending entry), leaving the
      committed route untouched.

  @param frameworkId - Reporting framework (kept for API symmetry)
  @param routeName - Canonical route name that failed to hand off
  @param transitionId - Active transition id being echoed back (optional)
  @return { success, reason? }
]]
M.routeChangeFailed = function(frameworkId, routeName, transitionId)
  if not TransitionManager.isTransitioning() then
    log("W", "Router", "routeChangeFailed received without active transition: " .. tostring(routeName))
    return { success = false, reason = "no_active_transition" }
  end

  if missingVueTransitionId(frameworkId, transitionId) then
    log("W", "Router", "routeChangeFailed from vue requires a transition id for route: " .. tostring(routeName))
    return { success = false, reason = "missing_transition_id" }
  end

  -- Validate against the active transition so a stale failure cannot roll back a newer navigation.
  local validation = TransitionManager.validateAcknowledgement(routeName, transitionId)
  if not validation.success then
    log("W", "Router", "routeChangeFailed ignored (" .. tostring(validation.reason) .. ") for route: " .. tostring(routeName))
    return { success = false, reason = validation.reason }
  end

  local session = TransitionManager.getSession()
  if session and session.routeChangeCommitted then
    -- The route already committed; the failure arrived too late to roll back safely.
    return { success = false, reason = "already_committed" }
  end

  local pendingEntry = NavigationState.getPendingEntry()
  if pendingEntry and pendingEntry.routeNode then
    -- Reverse the destination's onEnter side effects by running its onLeave, framed as
    -- leaving the pending route back to the committed one.
    local currentEntry = NavigationState.getCurrentEntry()
    local backToRoute = currentEntry and ResolvedRoute.toCompatRoute(currentEntry.resolved) or nil
    local leaveData = (session and session.routeData) or {}
    local pendingOptions = pendingEntry.request and pendingEntry.request.options or nil
    local leaveContext = buildNavigationContext(backToRoute, pendingEntry.resolved, "leave", pendingOptions)
    LifecycleExecutor.runLifecycleHook(pendingEntry.routeNode, "onLeave", leaveContext, backToRoute, pendingEntry.resolved, leaveData)
  end

  -- Cancel the matching transition; cancelActiveTransition clears the pending entry and the
  -- committed route is never promoted or altered.
  cancelActiveTransition("route_change_failed")

  return { success = true }
end

M.routeMounted = function(routeName, transitionId)
  -- log("I", "Router", "routeMounted: " .. routeName)
  if not TransitionManager.isTransitioning() then
    local currentEntry = NavigationState.getCurrentEntry()
    if currentEntry and currentEntry.resolved and currentEntry.resolved.name == routeName then
      -- Late/duplicate mount acknowledgement for an already-committed route.
      return { success = true, stale = true }
    end
    log("W", "Router", "routeMounted received without active transition: " .. tostring(routeName))
    return { success = false, reason = "no_active_transition" }
  end

  -- routeMounted is a Vue-only acknowledgement, so it must echo a non-empty transition id.
  if asNonEmptyString(transitionId) == nil then
    log("W", "Router", "routeMounted requires a transition id for route: " .. tostring(routeName))
    return { success = false, reason = "missing_transition_id" }
  end

  local context = TransitionManager.getTransitionContext()
  if not context or not context.toRoute then
    log("W", "Router", "routeMounted missing transition context")
    return { success = false, reason = "missing_transition_context" }
  end

  if routeName ~= context.toRoute.name then
    log("W", "Router", "routeMounted route mismatch. Expected: " .. tostring(context.toRoute.name) .. ", Got: " .. tostring(routeName))
    return { success = false, reason = "route_mismatch" }
  end

  -- Validate the transition id when provided; missing ids fall back to route-name validation.
  if transitionId ~= nil and context.transitionId ~= nil and transitionId ~= context.transitionId then
    log("W", "Router", "routeMounted transition id mismatch. Expected: " .. tostring(context.transitionId) .. ", Got: " .. tostring(transitionId))
    return { success = false, reason = "transition_id_mismatch" }
  end

  local session = TransitionManager.getSession()
  if not session then
    return { success = false, reason = "missing_transition_meta" }
  end

  -- A mount ack cannot finish a route that has not been promoted yet. Reject until the
  -- matching routeChangeComplete commits, so an early mount ack can never complete an
  -- unpromoted route.
  if not session.routeChangeCommitted then
    log("W", "Router", "routeMounted received before commit for route: " .. tostring(routeName))
    return { success = false, reason = "not_committed" }
  end

  if session.skipOnMount then
    return { success = true, skipped = true }
  end

  if session.mounted then
    return { success = true, alreadyMounted = true }
  end

  local currentEntry = NavigationState.getCurrentEntry()
  local routeNode = currentEntry and currentEntry.routeNode
  local targetScope = currentEntry and currentEntry.resolved and currentEntry.resolved.scope and currentEntry.resolved.scope.targetScope or nil
  local mountOk, mountErr, mountIsHard = LifecycleExecutor.runLifecycleHook(routeNode or context.toRoute, "onMount", session.navigationContext, context.toRoute, context.fromRoute, session.routeData)
  if mountIsHard then
    return { success = false, reason = "lifecycle_hook_error" }
  end
  local breadcrumbs = currentEntry and currentEntry.resolved and currentEntry.resolved.breadcrumbs or nil
  emitRouteData(context.toRoute, context.fromRoute, session.routeData, mountOk and "mounted-ready" or "error", mountErr, { targetScope = targetScope, breadcrumbs = breadcrumbs })
  TransitionManager.markMounted(routeName, transitionId)
  stampNavigationMilestone("mounted")
  completeActiveTransition(routeName, session.routeData, transitionId)

  return { success = true }
end

M.getBreadcrumbs = function()
  return NavigationState.getBreadcrumbs()
end

M.onGuiUpdate = function(dtReal, dtSim, dtRaw)
  local event = TransitionManager.update(dtReal)
  if event then
    if event.type == "resendRouteChange" then
      FrameworkManager.sendRouteChange(event.entry, TransitionManager.getTransitionId())
    elseif event.type == "timeout" then
      timeoutActiveTransition(event.reason, event.classification)
      return
    end
  end
end

M.onSerialize = function()
  return {
    navigation = NavigationState.serialize()
    -- Add other managers if they have state to persist
  }
end

M.onDeserialize = function(data)
  -- A deserialized router starts with no in-flight transition, so any protection lock from before
  -- the reload is stale and must not survive into the restored session.
  activeProtectionToken = nil
  if not data then
    return
  end
  NavigationState.deserialize(data.navigation)
  -- Restore other managers if needed
end

M.onExtensionLoaded = function()
  setExtensionUnloadMode(M, "manual")
  GuardManager.reloadGuards()
  -- extensions.load("ui_router_debug")
end

M.reportActiveScope = function(payload)
  -- dump("reportActiveScope: " .. json.encode(payload))
  if type(payload) ~= "table" then
    return { success = false, reason = "invalid_payload" }
  end

  local currentEntry = NavigationState.getCurrentEntry()
  local currentRouteName = currentEntry and currentEntry.request and currentEntry.request.name or nil
  local currentScopeTree = currentEntry and currentEntry.resolved and currentEntry.resolved.scopeTree or nil
  local payloadRouteName = asNonEmptyString(payload.routeName)
  local activeScopeId = asNonEmptyString(payload.activeScopeId)

  if payloadRouteName and currentRouteName and payloadRouteName ~= currentRouteName then
    return { success = false, reason = "stale_route", stale = true }
  end

  activeScopeState.previousActiveScopeId = activeScopeState.activeScopeId
  activeScopeState.activeScopeId = payload.activeScopeId
  activeScopeState.routeName = payloadRouteName or currentRouteName

  local shouldRememberRouteScope = payloadRouteName and currentRouteName and payloadRouteName == currentRouteName and
                                     activeScopeId and payload.isPopup ~= true and
                                     ScopeManager.isScopeDeclaredInTree(currentScopeTree, activeScopeId)

  if shouldRememberRouteScope then
    NavigationState.setLastActiveScope(currentRouteName, activeScopeId)
  end

  extensions.hook("onUiActiveScopeChanged", payload)

  return { success = true }
end

M.getState = function()
  return {
    currentRoute = NavigationState.getCurrentEntry(),
    activeScope = activeScopeState,
  }
end

M.resetStates = function()
  NavigationState.reset()
  TransitionManager.reset()
  if NavigationObserver then
    NavigationObserver.reset()
  end
  activeProtectionToken = nil
  activeRouteData = {}
  activeScopeState.activeScopeId = nil
  activeScopeState.previousActiveScopeId = nil
  activeScopeState.routeName = nil
end

-- Test-only seams for the protected-navigation lock. Not part of the public router API; they let
-- the co-located navigationProtection tests seed and inspect the identity-safe token directly.
M.__test_getProtectionToken = function()
  return activeProtectionToken
end

M.__test_setProtectionToken = function(token)
  activeProtectionToken = token
end

-- Deprecated methods
M.push = function(routename, params, options)
  log("W", "", "push is deprecated, use navigate instead")
  return M.navigate(routename, params, options)
end

M.replace = function(routename, params, options)
  log("W", "", "replace is deprecated, use navigate instead")
  return M.navigate(routename, params, options)
end

M.forward = function(options)
  log("W", "", "forward is deprecated, use navigate instead")
  return {
    result = false,
    reason = "deprecated_method"
  }
end

return M
