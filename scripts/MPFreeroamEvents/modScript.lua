if extensions.isExtensionLoaded("gameplay_events_freeroam_init") then
    extensions.unload("gameplay_events_freeroam_init")
end
extensions.load("gameplay_events_freeroam_init")
setExtensionUnloadMode("gameplay_events_freeroam_init", "manual")