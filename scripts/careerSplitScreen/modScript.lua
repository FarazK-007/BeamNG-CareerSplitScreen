-- Career Mode Split-Screen Entry Point
-- Automatically executed by BeamNG modmanager upon mounting

log("I", "careerSplitScreen", "Mounting Career Split-Screen mod...")

-- 1. If multiseat was left enabled from an earlier crash or older mod version, sanitize it immediately
if settings and settings.getValue and settings.getValue("multiseat") then
  settings.setValue("multiseat", false)
end

-- 2. Load careerSplitScreen extension
extensions.load("careerSplitScreen")
setExtensionUnloadMode("careerSplitScreen", "manual")

-- 3. Ensure all connected devices are bound to Player 0 immediately
if careerSplitScreen and careerSplitScreen.ensureSinglePlayerInputState then
  careerSplitScreen.ensureSinglePlayerInputState()
end

-- 4. Fix multi-level reputation crash if reputation module is present
if careerSplitScreen and careerSplitScreen.patchReputationModule then
  careerSplitScreen.patchReputationModule()
end

log("I", "careerSplitScreen", "Career Split-Screen extension mounted and input state verified.")
