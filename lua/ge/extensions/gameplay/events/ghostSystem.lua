local M = {}

M.dependencies = {
    'core_vehicles',
    'core_filesystem',
    'core_jsonformat'
}

local GhostSystem = {}
GhostSystem.__index = GhostSystem

local pendingSave = nil

function GhostSystem.new()
    local self = setmetatable({}, GhostSystem)
    self.ghostVehicles = {}      -- Active ghost vehicles by raceName
    self.currentRaceName = nil   -- Current race being recorded
    self.recordingVehicle = nil  -- Vehicle ID of recording vehicle
    self.savedGhosts = {}        -- Permanent saved ghost data by raceName
    self.tempGhost = nil         -- Temporary ghost data for current recording
    
    -- Load any existing ghost data on startup
    self:loadAllGhosts()
    return self
end


function GhostSystem:ensureSaveDirectory()
    local path = "saves/ghosts/"
    if not FS:directoryExists(path) then
        FS:directoryCreate(path)
    end
    return path
end

function GhostSystem:loadAllGhosts()
    local path = self:ensureSaveDirectory()
    local files = FS:findFiles(path, "*.json", -1, true, false)
    for _, file in ipairs(files) do
        local raceName = file:match("([^/]+)_ghost%.json$")
        if raceName then
            local data = jsonReadFile(file)
            if data and data.vehicle and data.scriptData then
                self.savedGhosts[raceName] = data
                print("Loaded ghost data for race: " .. raceName)
            end
        end
    end
end

function GhostSystem:stopRecording()
    if not self.currentRaceName or not self.recordingVehicle then return end
    print("Stopping Recording")

    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then 
        print('ghostSystem: No player vehicle found')
        return 
    end

    print("ghostSystem: Current recording vehicle: " .. dumps(self.recordingVehicle:getId()))
    print("ghostSystem: Current player vehicle: " .. dumps(playerVehicle:getId()))

    if playerVehicle:getId() ~= self.recordingVehicle:getId() then
        print("ghostSystem: Player vehicle is not the recording vehicle")
        return
    end

    self.tempGhost = {
        vehicle = {
            model = playerVehicle:getJBeamFilename(),
            config = playerVehicle:getField('partConfig', '')
        },
        scriptData = nil
    }

    print("ghostSystem: Current temp ghost data: " .. dumps(self.tempGhost))
    
    -- Stop recording and get script data
    playerVehicle:queueLuaCommand(string.format([[
        local scriptData = ai.stopRecording()
        if scriptData then
            -- Create ghost data on vehicle side
            local ghostData = {
                vehicle = {
                    model = v.data.jbeamFilename,  -- Use v.data instead of obj
                    config = v.data.partConfig      -- Use v.data instead of obj
                },
                scriptData = scriptData
            }
            
            -- Save directly if requested
            local pendingSave = %s
            if pendingSave then
                local path = "saves/ghosts/"
                if not FS:directoryExists(path) then
                    FS:directoryCreate(path)
                end
                jsonWriteFile(path .. "%s_ghost.json", ghostData, true)
            end
        end
    ]], tostring(pendingSave), self.currentRaceName))
    
    self.recordingVehicle = nil
end

function GhostSystem:startRecording(raceName)
    if not raceName then
        print('ghostSystem: No race name provided')
        return
    end

    local playerVehicle = be:getPlayerVehicle(0)
    if not playerVehicle then 
        print('ghostSystem: No player vehicle found')
        return 
    end

    if self.recordingVehicle then
        self:stopRecording()
    end
    
    self.currentRaceName = raceName
    self.recordingVehicle = playerVehicle

    print("ghostSystem: Starting to record: " .. dumps(self.recordingVehicle:getId()))

    -- Start recording
    playerVehicle:queueLuaCommand('ai.startRecording(true)')
end

function GhostSystem:onScriptRecorded(raceName, scriptData)
    if not scriptData then 
        print("ghostSystem: No script data found")
        return 
    end
    
    print("ghostSystem: Recording completed for race: " .. raceName)
    
    print("ghostSystem: Current saved ghost data: " .. dumps(self.tempGhost))
    print("ghostSystem: New script data: " .. dumps(scriptData))

    -- Save to local memory only
    self.tempGhost.scriptData = scriptData
    
    print("ghostSystem: Saved to local memory with " .. #scriptData .. " path points")

    if pendingSave == raceName then
        self:saveGhost(raceName)
        pendingSave = nil
    end
    
    -- Reset recording state
    self.currentRaceName = nil
end

function GhostSystem:saveGhost(raceName)
    if not self.tempGhost then
        print("ghostSystem: No local ghost data found for race: " .. raceName)
        return false
    end

    if not self.tempGhost.scriptData then
        print("ghostSystem: No script data found for race: " .. raceName)
        pendingSave = raceName
        return false
    end
    
    print("ghostSystem: Saving ghost data to disk for race: " .. raceName)

    -- Save to global memory
    self.savedGhosts[raceName] = self.tempGhost
    
    -- Save to disk
    local path = self:ensureSaveDirectory()
    local filename = path .. raceName .. "_ghost.json"
    
    if jsonWriteFile(filename, self.savedGhosts[raceName], true) then
        print("ghostSystem: Successfully saved ghost data to: " .. filename)
        return true
    else
        print("ghostSystem: Failed to save ghost data to file")
        return false
    end
end

function GhostSystem:loadGhost(raceName)
    if self.savedGhosts[raceName] then return true end
    
    local path = self:ensureSaveDirectory()
    local filename = path .. raceName .. "_ghost.json"
    
    if FS:fileExists(filename) then
        local data = jsonReadFile(filename)
        if data and data.vehicle and data.scriptData then
            self.savedGhosts[raceName] = data
            return true
        end
    end
    return false
end

function GhostSystem:spawnGhost(raceName)
    -- Remove existing ghost if any
    if self.ghostVehicles[raceName] then
        self:removeGhost(raceName)
    end

    -- Try to load ghost data from file
    local path = "saves/ghosts/" .. raceName .. "_ghost.json"
    if not FS:fileExists(path) then
        print("No ghost data found for race: " .. raceName)
        return
    end

    local ghostData = jsonReadFile(path)
    if not ghostData or not ghostData.vehicle or not ghostData.scriptData then
        print("Invalid ghost data for race: " .. raceName)
        return
    end
    
    -- Get initial position from script data
    local initialPos = vec3(ghostData.scriptData[1].pos)
    local initialRot = ghostData.scriptData[1].rot or quatFromDir(vec3(0,1,0), vec3(0,0,1))

    local options = {
        pos = initialPos,
        rot = initialRot,
        autoEnterVehicle = false,
        color = ColorF(1,1,1,0.5), -- Default ghost color
        alpha = 0.5,
        licenseText = "GHOST",
        config = ghostData.vehicle.config,
        cameraMode = 'external'
    }

    local ghostVehicle = core_vehicles.spawnNewVehicle(ghostData.vehicle.model, options)
    if ghostVehicle then
        self.ghostVehicles[raceName] = ghostVehicle:getId()
        
        ghostVehicle:queueLuaCommand([[
            obj:setGhostMode(true)
            obj:setDynDataFieldbyName("enableAI", 1)
            ai.setMode('script')
            ai.setScriptDebugMode('off')
            ai.startFollowing(]] .. serialize(ghostData.scriptData) .. [[)
        ]])
    end
end

function GhostSystem:removeGhost(raceName)
    if self.ghostVehicles[raceName] then
        local ghost = scenetree.findObjectById(self.ghostVehicles[raceName])
        if ghost then
            ghost:delete()
        end
        self.ghostVehicles[raceName] = nil
    end
end

function GhostSystem:removeAllGhosts()
    for raceName, _ in pairs(self.ghostVehicles) do
        self:removeGhost(raceName)
    end
end

function GhostSystem:onExtensionUnloaded()
    self:removeAllGhosts()
end

local ghostSystem = GhostSystem.new()

M.startRecording = function(...) return ghostSystem:startRecording(...) end
M.stopRecording = function(...) return ghostSystem:stopRecording(...) end
M.onGhostDataReceived = function(...) return ghostSystem:onScriptRecorded(...) end
M.spawnGhost = function(...) return ghostSystem:spawnGhost(...) end
M.removeGhost = function(...) return ghostSystem:removeGhost(...) end
M.removeAllGhosts = function(...) return ghostSystem:removeAllGhosts(...) end
M.onExtensionUnloaded = function(...) return ghostSystem:onExtensionUnloaded(...) end
M.saveGhost = function(...) return ghostSystem:saveGhost(...) end


print("Ghost System module loaded, hook handler installed for 'onGhostDataReceived'")
return M