if extensions.isExtensionLoaded("gameplay_events_freeroam_init") then
    extensions.unload("gameplay_events_freeroam_init")
end
extensions.load("gameplay_events_freeroam_init")
setExtensionUnloadMode("gameplay_events_freeroam_init", "manual")

if extensions.isExtensionLoaded("editor_freeroamEventEditor") then
    extensions.unload("editor_freeroamEventEditor")
end
extensions.load("editor_freeroamEventEditor")
setExtensionUnloadMode("editor_freeroamEventEditor", "manual")