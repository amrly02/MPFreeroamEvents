local leaderboards = {}

function loadPlayerLeaderboard(playerID)
    print("[LeaderboardManager-Load] Loading leaderboard for player: " .. tostring(playerID))
    
    local filePath = "ServerLeaderboards/player_" .. tostring(playerID) .. ".json"
    if FS.Exists(filePath) then
        local content = FS.ReadFile(filePath)
        if content then
            local success, data = pcall(json.decode, content)
            if success then
                print("[LeaderboardManager-Load] Successfully loaded leaderboard")
                return data
            end
            print("[LeaderboardManager-Load] Failed to parse leaderboard JSON")
        end
    end
    print("[LeaderboardManager-Load] No existing leaderboard found")
    return {}
end

function savePlayerLeaderboard(playerID, data)
    print("[LeaderboardManager-Save] Saving leaderboard for player: " .. tostring(playerID))
    
    if not FS.Exists("ServerLeaderboards") then
        print("[LeaderboardManager-Save] Creating ServerLeaderboards directory")
        FS.CreateDirectory("ServerLeaderboards")
    end
    
    local filePath = "ServerLeaderboards/player_" .. tostring(playerID) .. ".json"
    local success, encodedData = pcall(json.encode, data)
    if not success then
        print("[LeaderboardManager-Save] Failed to encode leaderboard data")
        return false
    end
    
    if FS.WriteFile(filePath, encodedData) then
        print("[LeaderboardManager-Save] Successfully saved leaderboard")
        return true
    end
    
    print("[LeaderboardManager-Save] Failed to save leaderboard")
    return false
end

function requestLeaderboard(playerID)
    print("[LeaderboardManager-Event] Received leaderboard request from player: " .. tostring(playerID))
    local data = loadPlayerLeaderboard(playerID)
    MP.TriggerClientEvent(playerID, "receiveLeaderboard", data)
end

function saveLeaderboard(playerID, data)
    print("[LeaderboardManager-Event] Received save request from player: " .. tostring(playerID))
    if data and type(data) == "table" then
        if savePlayerLeaderboard(playerID, data.data) then
            MP.SendChatMessage(playerID, "Leaderboard saved successfully")
        else
            MP.SendChatMessage(playerID, "Failed to save leaderboard")
        end
    else
        print("[LeaderboardManager-Event] Invalid data received")
        MP.SendChatMessage(playerID, "Invalid leaderboard data received")
    end
end

print("Leaderboard system loaded")

MP.RegisterEvent("requestLeaderboard", "requestLeaderboard")
MP.RegisterEvent("saveLeaderboard", "saveLeaderboard")