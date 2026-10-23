-- Career Mode Split-Screen Entry Point
-- Automatically executed by BeamNG modmanager upon mounting

log("I", "careerSplitScreen", "Loading Career Split-Screen extension...")
extensions.load("careerSplitScreen")
setExtensionUnloadMode("careerSplitScreen", "manual")
if careerSplitScreen and careerSplitScreen.ensureModExtensionsLoaded then
  careerSplitScreen.ensureModExtensionsLoaded()
end
if careerSplitScreen and careerSplitScreen.patchReputationModule then
  careerSplitScreen.patchReputationModule()
end
log("I", "careerSplitScreen", "Career Split-Screen extension loaded successfully.")
