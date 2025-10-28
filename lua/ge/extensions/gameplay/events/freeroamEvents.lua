-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {}

local processRoad = require('gameplay/events/freeroam/processRoad')
local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
local activeAssets = require('gameplay/events/freeroam/activeAssets')
local checkpointManager = require('gameplay/events/freeroam/checkpointManager')
local utils = require('gameplay/events/freeroam/utils')
local pits = require('gameplay/events/freeroam/pits')
local Assets = activeAssets.ActiveAssets.new()

local loadedExtensions = {}

local timerActive = false
local mActiveRace
local staged = nil
local in_race_time = 0

local speedUnit = 2.2369362921
local lapCount = 0
local mCurrentLayoutIndex = nil
local mCurrentLayoutLap = nil
local currCheckpoint = nil
local mHotlap = nil
local mAltRoute = nil
local mSplitTimes = {}
local isLoop = false
local checkpointsHit = 0
local totalCheckpoints = 0
local currentExpectedCheckpoint = 1
local invalidLap = false


local rollingStartArmed = false
local inPaceZone = false


local mCurrentFork = nil

local initialVehicleDamage = 0

local mInventoryId = nil
local newBestSession = false

local maxSpeed = 0

local races = nil
local isReplay = false

local previousGameState = nil
local saveGameState = false

local function rewardLabel(raceName, newBestTime)
    local raceLabel = races[raceName].label
    local timeLabel = utils.formatTime(in_race_time)
    local performanceLabel = newBestTime and "New Best Time!" or "Completion"

    local label = string.format("%s - %s: %s", raceLabel, performanceLabel, timeLabel)

    if mAltRoute then
        label = label .. " (Alternative Route)"
    end

    if mHotlap == raceName then
        label = label .. " (Hotlap)"
    end

    return label
end

local function getDriftScore()
    local finalScore = 0
    if gameplay_drift_scoring then
        local scoreData = gameplay_drift_scoring.getScore()
        if scoreData then
            finalScore = scoreData.score or 0
            if scoreData.cachedScore then
                finalScore = finalScore + math.floor(scoreData.cachedScore * scoreData.combo)
            end
            gameplay_drift_general.reset()
        end
    end
    return finalScore
end

local function getRaceLabel()
    local race = races[mActiveRace]
    local raceLabel = race.label

    if mAltRoute then
        raceLabel = race.altRoute.label
    end
    if mHotlap == mActiveRace then
        raceLabel = raceLabel .. " (Hotlap)"
    end
    return raceLabel
end

local function payoutRace()
    if not mActiveRace then
        return 0
    end

    local race = races[mActiveRace]
    local time = race.bestTime
    local reward = race.reward
    local raceLabel = race.label
    local damageFactor = race.damageFactor or 0

    -- Get appropriate time and reward values based on route type
    if mHotlap == mActiveRace then
        time = race.hotlap
    end
    if mAltRoute then
        time = race.altRoute.bestTime
        reward = race.altRoute.reward
        raceLabel = race.altRoute.label
        if mHotlap == mActiveRace then
            time = race.altRoute.hotlap
        end
    end
    if mHotlap == mActiveRace then
        raceLabel = raceLabel .. " (Hotlap)"
    end

    -- Calculate damage percentage if damage factor is used
    local damagePercentage = 0
    if damageFactor > 0 then
        local currentDamage = utils.getVehicleDamage()
        local damageTaken = math.max(0, currentDamage - initialVehicleDamage)
        local maxDamage = 100000 -- Default max damage
        
        -- Try to get vehicle value as max damage if in career mode
        if career_career and career_career.isActive() and career_modules_valueCalculator then
            maxDamage = career_modules_valueCalculator.getInventoryVehicleValue(mInventoryId, true)
        end
        
        -- Calculate percentage of damage taken (0 = no damage, 1 = maximum damage)
        damagePercentage = math.min(1, damageTaken / maxDamage)
    end

    -- Calculate scores and rewards
    local driftScore = 0
    if race.topSpeed then
        reward = utils.topSpeedReward(race.topSpeedGoal, reward, maxSpeed, race.type)
    elseif race.driftGoal then
        driftScore = getDriftScore()
        reward = utils.driftReward(races[mActiveRace], time, driftScore)
    elseif damageFactor > 0 then
        reward = utils.hybridRaceReward(time, reward, in_race_time, damageFactor, damagePercentage, race.type)
    else
        reward = utils.raceReward(time, reward, in_race_time, race.type)
    end
    print("Adjusted reward: " .. reward)

    -- Handle leaderboard
    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel)

    local oldTime = leaderboardEntry and leaderboardEntry.time or 0
    local oldScore = leaderboardEntry and leaderboardEntry.driftScore or 0

    local newEntry = {
        raceName = mActiveRace,
        raceLabel = raceLabel,
        isAltRoute = mAltRoute,
        isHotlap = mHotlap == mActiveRace,
        time = in_race_time,
        splitTimes = mSplitTimes,
        driftScore = driftScore,
        inventoryId = mInventoryId,
        damagePercentage = damagePercentage,
        damageFactor = damageFactor,
        topSpeed = maxSpeed
    }

    local newBest = leaderboardManager.addLeaderboardEntry(newEntry)

    -- Build the base message that's shown regardless of career mode
    local message = invalidLap and "Lap Invalidated\n" or ""

    if race.topSpeed then
        message = message ..
                      string.format("%s\nTop Speed: %.2f mph\nTime: %s", raceLabel, maxSpeed, utils.formatTime(in_race_time))
        if oldTime then
            local oldSpeed = leaderboardEntry and leaderboardEntry.topSpeed or 0
            message = message ..
                          string.format("\nPrevious Best Speed: %.2f mph\nPrevious Best Time: %s", oldSpeed,
                    utils.formatTime(oldTime))
        end
    elseif race.driftGoal then
        message = message ..
                      string.format("%s\nDrift Score: %d\nTime: %s", raceLabel, driftScore,
                utils.formatTime(in_race_time))
        if oldScore and oldTime then
            message = message ..
                          string.format("\nPrevious Best Score: %d\nPrevious Best Time: %s", oldScore,
                    utils.formatTime(oldTime))
        end
    else
        if newBest and not invalidLap then
            if damageFactor > 0 then
                message = message .. "New Best Score!\n"
            else
                message = message .. "New Best Time!\n"
            end
        end
        
        -- Build basic time information
        if race.hotlap then
            message = message ..
                          string.format("%s\nTime: %s\nLap: %d", raceLabel, utils.formatTime(in_race_time), lapCount)
        else
            message = message .. string.format("%s\nTime: %s", raceLabel, utils.formatTime(in_race_time))
        end
        
        -- Add damage information for damage-based races
        if damageFactor > 0 then
            message = message .. string.format("\nDamage Taken: %.1f%% | Damage Factor: %.0f%%", 
                damagePercentage * 100, damageFactor * 100)
        end
        
        -- Show previous best information
        if newBest and not invalidLap and oldTime ~= math.huge then
            if damageFactor > 0 then
                local oldDamagePercentage = leaderboardEntry and leaderboardEntry.damagePercentage or 0
                message = message .. string.format("\nPrevious Best Time: %s | Previous Best Damage: %.1f%%", 
                    utils.formatTime(oldTime), oldDamagePercentage * 100)
            else
                message = message .. string.format("\nPrevious Best: %s", utils.formatTime(oldTime))
            end
        end
    end

    local hotlapMessage = ""
    -- Handle career mode specific rewards
    if career_career.isActive() then
        if not newBest or mHotlap then
            reward = reward / 2
        end
        reward = invalidLap and 0 or reward
        lapCount = invalidLap and 1 or lapCount
        if race.hotlap then
            -- Hotlap Multiplier
            reward = reward * utils.hotlapMultiplier(lapCount)
            hotlapMessage = string.format("\nHotlap Multiplier: %.2f", utils.hotlapMultiplier(lapCount))
        end

        if newBest and not newBestSession then
            -- New Best Bonus
            newBestSession = true
        end

        if newBestSession then
            -- New Best Bonus
            reward = reward * 1.2
            hotlapMessage = hotlapMessage .. "\nNew Best Session Bonus: 20%"
        end

        if oldTime and (newEntry.time - (oldTime * 0.025) < oldTime) then
            -- In Range Bonus
            reward = reward * 1.05
            hotlapMessage = hotlapMessage .. "\nIn Range Bonus: 5%"
        end

        reward = reward / (career_modules_hardcore.isHardcoreMode() and 2 or 1)

        if reward > 0 then
            local xp = math.floor(reward / 20)
            local totalReward = {
                money = {
                    amount = reward
                },
                beamXP = {
                    amount = math.floor(xp / 10)
                }
            }
            for _, type in ipairs(race.type) do
                totalReward[type] = {
                    amount = xp
                }
            end

            career_modules_payment.reward(totalReward, {
                label = rewardLabel(mActiveRace, newBest),
                tags = {"gameplay", "reward", "mission"}
            }, true)

            message = message .. string.format("\nXP: %d | Reward: $%.2f", xp, reward)
            if career_modules_hardcore.isHardcoreMode() then
                message = message .. "\nHardcore mode is enabled, all rewards are halved."
            end
            career_saveSystem.saveCurrent()
        end
    end

    mActiveRace = nil
    utils.displayMessage(message, 20, "Reward")
    if hotlapMessage ~= "" then
        ui_message(hotlapMessage, 5, "Hotlap Multiplier")
    end
    return reward
end

-- Simplified payoutRace function for drag races
local function payoutDragRace(raceName, finishTime, finishSpeed, vehId)
    -- Load the leaderboard
    if career_career.isActive() then
        vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
    end

    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(vehId, races["drag"].label)
    local oldTime = leaderboardEntry and leaderboardEntry.time or 0

    local newEntry = {
        raceLabel = races["drag"].label,
        raceName = raceName,
        time = finishTime,
        splitTimes = mSplitTimes,
        inventoryId = vehId
    }

    local newBestTime = leaderboardManager.addLeaderboardEntry(newEntry)

    if not career_career.isActive() then
        local message = string.format("%s\nTime: %s\nSpeed: %.2f mph", races[raceName].label, utils.formatTime(finishTime),
            finishSpeed)
        utils.displayMessage(message, 10)
        return 0
    end

    -- Get race data
    local raceData = races[raceName]
    local targetTime = raceData.bestTime
    local baseReward = raceData.reward

    -- Calculate reward based on performance
    local reward = utils.raceReward(targetTime, baseReward, finishTime, raceData.type)
    if reward <= 0 then
        reward = baseReward / 2 -- Minimum reward for completion
    end

    print("Adjusted drag reward: " .. reward)

    reward = reward / (career_modules_hardcore.isHardcoreMode() and 2 or 1)

    reward = newBestTime and reward or reward / 2

    -- Calculate experience points
    local xp = math.floor(reward / 20)

    -- Prepare total reward
    local totalReward = {
        money = {
            amount = reward
        },
        beamXP = {
            amount = math.floor(xp / 10)
        }
    }

    -- Create reason for reward
    local reason = {
        label = raceData.label .. (newBestTime and " - New Best Time!" or " - Completion"),
        tags = {"gameplay", "reward", "drag"}
    }

    -- Process the reward
    career_modules_payment.reward(totalReward, reason, true)

    -- Prepare the completion message
    local message = string.format("%s\n%s\nTime: %s\nSpeed: %.2f mph\nXP: %d | Reward: $%.2f",
        newBestTime and "Congratulations! New Best Time!" or "", raceData.label, utils.formatTime(finishTime), finishSpeed,
        xp, reward)

    if career_modules_hardcore.isHardcoreMode() then
        message = message .. "\nHardcore mode is enabled, all rewards are halved."
    end

    -- Display the message
    ui_message(message, 20, "Reward")

    -- Save the leaderboard and game state
    career_saveSystem.saveCurrent()

    return reward
end

local function getDifference(raceName, currentCheckpointIndex)
    local raceLabel = getRaceLabel()
    local leaderboardEntry = leaderboardManager.getLeaderboardEntry(mInventoryId, raceLabel)
    if not leaderboardEntry then
        return nil
    end

    local splitTimes = leaderboardEntry.splitTimes

    if not splitTimes or not splitTimes[currentCheckpointIndex] then
        return nil
    end

    -- Calculate the time difference for this split
    local currentSplitDiff
    if not mSplitTimes[currentCheckpointIndex] or not splitTimes[currentCheckpointIndex] then
        return nil
    end

    if currentCheckpointIndex == 1 then
        -- For first checkpoint, compare directly
        currentSplitDiff = mSplitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex]
    else
        -- Check if we have the previous checkpoint times before calculating
        if not mSplitTimes[currentCheckpointIndex - 1] or not splitTimes[currentCheckpointIndex - 1] then
            return nil
        end

        -- For subsequent checkpoints, compare the differences between splits
        local previousBestSplit = splitTimes[currentCheckpointIndex] - splitTimes[currentCheckpointIndex - 1]
        local currentSplit = mSplitTimes[currentCheckpointIndex] - mSplitTimes[currentCheckpointIndex - 1]
        currentSplitDiff = currentSplit - previousBestSplit
    end

    return currentSplitDiff
end

local function formatSplitDifference(diff)
    local sign = diff >= 0 and "+" or "-"
    return string.format("%s%s", sign, utils.formatTime(math.abs(diff)))
end

local function startLayout(raceName, layoutIndex)
    local raceData = races[raceName]
    if not raceData or not raceData.layouts[layoutIndex] then
        print("Error: Invalid layout index " .. layoutIndex .. " for race " .. raceName)
        exitRace(false, "Race configuration error.")
        return
    end

    local layoutData = raceData.layouts[layoutIndex]
    utils.displayMessage("Starting: " .. layoutData.name, 5)

    -- Use the existing road processing logic for the current layout's roads
    processRoad.reset()
    processRoad.setStationaryTimeout(raceData.timeout)
    
    -- Temporarily create a race-like table for getCheckpoints
    local tempRaceConfig = {
        checkpointRoad = layoutData.checkpointRoad,
        minCheckpointDistance = raceData.minCheckpointDistance
    }
    
    local checkpoints, altCheckpoints = processRoad.getCheckpoints(tempRaceConfig)

    checkpointManager.createCheckpoints(checkpoints, altCheckpoints)

    isLoop = processRoad.isLoop()
    currCheckpoint = 0
    checkpointsHit = 0
    totalCheckpoints = checkpointManager.calculateTotalCheckpoints()
    currentExpectedCheckpoint = 1
    mAltRoute = false
    checkpointManager.setAltRoute(mAltRoute)

    currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0)
end

local function exitRace(isCompletion, customMessage, raceData, subjectID)
    if mActiveRace then
        local raceName = mActiveRace
        if isCompletion then
            -- Race completion logic
            payoutRace()

            -- Race-specific completion handling
            if raceName == "drag" and raceData and subjectID then
                local side = "l"
                utils.updateDisplay(side, in_race_time, math.abs(be:getObjectVelocityXYZ(subjectID)) * speedUnit)
            end

            if raceData and utils.tableContains(raceData.type, "drift") then
                local finalScore = getDriftScore()
                if gameplay_drift_general.getContext() == "inChallenge" then
                    gameplay_drift_general.setContext("inFreeRoam")
                end
            end

            if customMessage then
                utils.displayMessage(customMessage, 10, "Reward")
            end
        else
            -- Race cancellation logic
            local message = customMessage or "You exited the race zone, Race cancelled"
            utils.displayMessage(message, 3)
            staged = nil
        end

        utils.setActiveLight(raceName, "red")
        lapCount = 0
        mCurrentLayoutIndex = nil
        mCurrentLayoutLap = nil
        mActiveRace = nil
        timerActive = false
        mHotlap = nil
        currCheckpoint = nil
        mSplitTimes = {}
        mAltRoute = false
        invalidLap = false

        -- after rolling start change
        rollingStartArmed = false
        inPaceZone = false
        mCurrentFork = nil


        mInventoryId = nil
        maxSpeed = 0
        Assets:hideAllAssets()
        checkpointManager.removeCheckpoints()

        -- Common cleanup tasks
        core_jobsystem.create(function(job)
            job.sleep(10)
            utils.restoreTrafficAmount()
        end)
        pits.clearSpeedLimit()
        newBestSession = false
        if gameplay_drift_general.getContext() == "inChallenge" then
            gameplay_drift_general.setContext("inFreeRoam")
            gameplay_drift_general.reset()
        end
        if career_career.isActive() then
            career_modules_pauseTime.enablePauseCounter()
        end
        core_gamestate.setGameState(previousGameState.state, previousGameState.appLayout, previousGameState.menuItems, previousGameState.options)
        previousGameState = nil
        saveGameState = false
    end
end

local function onBeamNGTrigger(data)
    if be:getPlayerVehicleID(0) ~= data.subjectID or isReplay then
        return
    end
    if gameplay_walk.isWalking() then return end
    if career_career.isActive() then
        if not career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID) then
            return
        end
        local vehicle = career_modules_inventory.getVehicles()[career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID)]
        if vehicle.loanType then
            return
        end
    end

    local triggerName = data.triggerName
    local event = data.event

    if not triggerName:match("^fre_") then
        -- Not a free roam event trigger, ignore
        return
    end

    -- Remove the 'fre_' prefix for processing
    triggerName = triggerName:sub(5)

    -- Extract trigger information
    local triggerType, raceName, rest = triggerName:match("^([^_]+)_([^_]+)(.*)$")

    if not triggerType or not raceName then
        print("Trigger name doesn't match expected pattern.")
        return
    end

    -- Initialize altFlag and index
    local altFlag = nil
    local index = nil

    -- Process the rest of the trigger name
    if rest ~= "" then
        -- Remove leading underscores
        rest = rest:gsub("^_+", "")

        -- Check if rest starts with 'alt'
        if rest:sub(1, 3) == "alt" then
            altFlag = "alt"
            rest = rest:sub(4) -- Remove 'alt' and move forward
            rest = rest:gsub("^_+", "") -- Remove any additional underscores
        end

        -- If there's still something left, it's the index
        if rest ~= "" then
            index = rest
        end
    end

    -- Convert index to number if it exists
    local checkpointIndex = index and tonumber(index) or nil

    local isAlt = altFlag == "alt" -- TEMP must change to acount for alt routes that intersect with the main route multiple times

    if triggerType == "staging" then
        if event == "enter" and mActiveRace == nil then
            if utils.isPlayerInPursuit() then
                utils.displayMessage("You cannot stage for an event while in a pursuit.", 2)
                return
            end

            saveGameState = true
            core_gamestate.requestGameState()

            local vehicleSpeed = math.abs(be:getObjectVelocityXYZ(data.subjectID)) * speedUnit
            if vehicleSpeed > 5 and mActiveRace then
                return
            end
            mHotlap = nil
            if vehicleSpeed > 5 then
                if races[raceName].runningStart then
                    utils.displayMessage("Hotlap Staged", 2)
                    if races[raceName].hotlap then
                        mHotlap = raceName
                    end
                else
                    utils.displayMessage("You are too fast to stage.\nPlease back up and slow down to stage.", 2)
                    staged = nil
                    return
                end
            end
            Assets:hideAllAssets()
            lapCount = 0

            -- Check if ALL race types are disabled (only disable if every type is 0)
            local allTypesDisabled = false
            local disabledTypes = {}
            if career_economyAdjuster and races[raceName].type then
                local totalTypes = 0
                local disabledCount = 0

                for _, raceType in ipairs(races[raceName].type) do
                    totalTypes = totalTypes + 1
                    local multiplier = career_economyAdjuster.getEffectiveSectionMultiplier({raceType})
                    if multiplier == 0 then
                        disabledCount = disabledCount + 1
                        table.insert(disabledTypes, raceType)
                    end
                end

                -- Only disable if ALL types are disabled
                allTypesDisabled = totalTypes > 0 and disabledCount == totalTypes
            end

            if allTypesDisabled then
                -- Don't allow staging for disabled races
                local typesString = table.concat(disabledTypes, ", ")
                utils.displayMessage(string.format("%s is disabled due to %s multiplier(s) being set to 0.", races[raceName].label, typesString), 5)
                return
            end

            -- Initialize displays if drag race
            if raceName == "drag" then
                utils.initDisplays()
                utils.resetDisplays()
            end

            -- Set staged race
            staged = raceName
            print("Staged race: " .. raceName)
            local vehId = data.subjectID
            if career_career.isActive() then
                vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
            end
            --utils.displayStagedMessage(vehId, raceName) -- before rolling start change 

            -- rolling start one ----- start

            if races[raceName].rollingStart then
                utils.displayMessage(string.format("Staged for %s (Rolling Start).\nProceed to the Pace Zone.", races[raceName].label), 10)
            else
                utils.displayStagedMessage(vehId, raceName)
            end

            --------------------------end

            utils.setActiveLight(raceName, "yellow")
        elseif event == "exit" then
            -- Only cancel staging if it's NOT a rolling start race
            if staged and races[staged] and not races[staged].rollingStart then
                staged = nil

                if not mActiveRace then
                    utils.displayMessage("You exited the staging zone", 4)
                    utils.setActiveLight(raceName, "red")
                end
            end
        end
    elseif triggerType == "start" then
        if event == "enter" and mActiveRace == raceName and not utils.hasFinishTrigger(raceName) then
            -- This is the logic for completing a lap in a hotlap/multi-lap race
            if not currCheckpoint or checkpointsHit ~= totalCheckpoints then
                if not invalidLap then
                    utils.displayMessage("You have not completed all checkpoints!", 5)
                    return
                end
            end
            lapCount = lapCount + 1
            utils.playCheckpointSound()
            initialVehicleDamage = utils.getVehicleDamage()
            processRoad.setStationaryTimeout(races[raceName].timeout)
            checkpointManager.setRace(races[raceName], raceName)
            Assets:displayAssets(data)
            timerActive = false
            local reward = payoutRace()
            currCheckpoint = nil
            mSplitTimes = {}
            mActiveRace = raceName
            checkpointManager.setAltRoute(false)
            mAltRoute = false
            in_race_time = 0
            maxSpeed = 0
            timerActive = true
            checkpointsHit = 0
            totalCheckpoints = checkpointManager.calculateTotalCheckpoints(races[raceName])
            currentExpectedCheckpoint = 0
            if races[raceName].hotlap then
                mHotlap = raceName
                currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0)
            end
            invalidLap = false

        elseif event == "enter" and staged == raceName then
            local isRollingStartRace = races[raceName] and races[raceName].rollingStart ~= nil

            local condition1 = not isRollingStartRace
            local condition2 = rollingStartArmed

            local finalResult = condition1 or condition2

            if finalResult then
                if races[raceName] and races[raceName].rollingStart then
                    rollingStartArmed = false
                end
                
                -- This is the original logic that starts the race
                if career_career.isActive() then
                    career_modules_pauseTime.enablePauseCounter(true)
                end
                initialVehicleDamage = utils.getVehicleDamage()
                utils.saveAndSetTrafficAmount(0)
                checkpointManager.setRace(races[raceName], raceName)
                Assets:displayAssets(data)
                timerActive = true
                in_race_time = 0
                maxSpeed = 0
                mActiveRace = raceName
                lapCount = 0
                mInventoryId = career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId(data.subjectID) or data.subjectID
                invalidLap = false
                utils.displayStartMessage(raceName)
                utils.setActiveLight(raceName, "green")
                
                if utils.tableContains(races[raceName].type, "drift") then
                    gameplay_drift_general.setContext("inChallenge")
                    gameplay_drift_general.reset()
                    if gameplay_drift_drift then
                        gameplay_drift_drift.setVehId(data.subjectID)
                    end
                end

                if races[raceName].checkpointRoad then
                    processRoad.reset()
                    processRoad.setStationaryTimeout(races[raceName].timeout)
                    local checkpoints, altCheckpoints = processRoad.getCheckpoints(races[raceName])
                    checkpointManager.createCheckpoints(checkpoints, altCheckpoints)
                    isLoop = processRoad.isLoop()
                    currCheckpoint = 0
                    checkpointsHit = 0
                    totalCheckpoints = checkpointManager.calculateTotalCheckpoints(races[raceName])
                    currentExpectedCheckpoint = 1
                    mAltRoute = false
                    checkpointManager.setAltRoute(mAltRoute)
                    currentExpectedCheckpoint = checkpointManager.enableCheckpoint(0)
                end
            end
        else
            utils.setActiveLight(raceName, "red")
        end
    elseif triggerType == "checkpoint" and checkpointIndex then
        if event == "enter" and mActiveRace == raceName then
            local raceData = races[raceName]
            local isValidHit = false
            
            -- Check if we just made a choice at a fork "NEW SYSTEM"
            if mCurrentFork then
                if checkpointIndex == mCurrentFork.main and not isAlt then
                    -- Player chose the MAIN route from a fork
                    isValidHit = true
                    mAltRoute = false
                    checkpointManager.setAltRoute(false)
                    currentExpectedCheckpoint = mCurrentFork.main
                elseif checkpointIndex == mCurrentFork.alt and isAlt then
                    -- Player chose the ALT route from a fork
                    isValidHit = true
                    mAltRoute = true
                    checkpointManager.setAltRoute(true)
                    totalCheckpoints = checkpointManager.calculateTotalCheckpoints(raceData)
                    currentExpectedCheckpoint = mCurrentFork.alt
                end
                mCurrentFork = nil -- Choice has been made, clear the fork state

            -- Check for the classic alt route start "OLD SYSTEM"
            elseif not mAltRoute and isAlt and checkpointIndex == 1 then
                isValidHit = true
                mAltRoute = true
                checkpointManager.setAltRoute(true)
                totalCheckpoints = checkpointManager.calculateTotalCheckpoints(raceData) 
                currCheckpoint = 0

            -- Check for the classic alt route MERGE POINT (OLD SYSTEM)
            elseif mAltRoute and not isAlt and not raceData.forks then
                isValidHit = true
                mAltRoute = false -- We are now back on the main route
                checkpointManager.setAltRoute(false)
            
            -- Standard linear checkpoint hit (WORKS FOR ALL SYSTEMS)
            elseif (checkpointIndex == currentExpectedCheckpoint and isAlt == mAltRoute) then
                isValidHit = true
            end

            if isValidHit then
                checkpointsHit = checkpointsHit + 1
                currCheckpoint = checkpointIndex
                mSplitTimes[checkpointsHit] = in_race_time
                utils.playCheckpointSound()
                
                -- After hitting a valid checkpoint, check if the NEXT one is a fork
                local nextFork = nil
                if raceData.forks then
                    for _, forkData in ipairs(raceData.forks) do
                        if forkData.atMainIndex == currCheckpoint and not mAltRoute then
                            nextFork = { main = forkData.mainChoiceIndex, alt = forkData.altChoiceIndex }
                            break
                        end
                    end
                end

                if nextFork then
                    -- We are at a fork, enable both choices
                    mCurrentFork = checkpointManager.enableForkCheckpoints(nextFork.main, nextFork.alt, raceData)
                    ui_message("Choose your route!", 3)
                else
                    print("--- Calling enableCheckpoint from freeroamEvents ---")
                    print("Sending currCheckpoint: " .. tostring(currCheckpoint))
                    print("Sending mAltRoute: " .. tostring(mAltRoute))
                    -- Not a fork, proceed normally
                    print("--- [Brain] Calling enableCheckpoint ---")
                    print("[Brain] Sending mAltRoute: " .. tostring(mAltRoute))
                    currentExpectedCheckpoint = checkpointManager.enableCheckpoint(currCheckpoint, mAltRoute)
                end
                
                -- Display checkpoint message (simplified for brevity)
                local checkpointMessage = string.format("Checkpoint %d/%d - Time: %s", checkpointsHit, totalCheckpoints, utils.formatTime(in_race_time))
                utils.displayMessage(checkpointMessage, 7)

                -- THIS IS THE MODIFIED LINE
                Assets:displayAssets(data, mAltRoute)
            else
                -- Logic for hitting the wrong checkpoint can go here
                -- For now, we'll just ignore it to avoid complexity
            end
        end

    elseif triggerType == "finish" then
        if event == "enter" and mActiveRace == raceName then
            exitRace(true, nil, races[raceName], data.subjectID)
            staged = nil
        end

        -- rolling start change ---- start

        elseif triggerType == "pacezone" then
        if event == "enter" and staged == raceName and not inPaceZone then
            inPaceZone = true
            local rsData = races[raceName].rollingStart
            pits.setGovernorLimit(rsData.paceSpeed, rsData.speedUnit)
            if rsData.paceSpeed and rsData.paceSpeed > 0 then
                utils.displayMessage(string.format("Pace Zone: Maintain %.0f %s", rsData.paceSpeed, rsData.speedUnit), 10)
            else
                utils.displayMessage("Pace Zone: Form up for rolling start!", 10)
            end
        elseif event == "exit" and inPaceZone then
            inPaceZone = false
            rollingStartArmed = true
            pits.clearSpeedLimit()
            utils.displayMessage("GO! GO! GO!", 3)
        end

        --------------------------end


    elseif triggerType == "pits" then
        if event == "enter" and mActiveRace == raceName then
            -- Handle pit entry
            local obj = be:getPlayerVehicle(0)
            if obj then
                obj:queueLuaCommand("obj:setGhostEnabled(true)")
            end
            if races[raceName].pitSpeedLimit then
                pits.stopThenLimit(races[raceName].pitSpeedLimit, races[raceName].pitSpeedLimitUnit)
            else
                pits.stopThenLimit(37, "MPH")
            end
        elseif event == "exit" and mActiveRace == raceName then
            -- Handle pit exit
            pits.toggleSpeedLimit()
            local obj = be:getPlayerVehicle(0)
            if obj then
                obj:queueLuaCommand("obj:setGhostEnabled(false)")
            end
        end    
    else
        print("Unknown trigger type: " .. triggerType)
    end
end

local function onWorldReadyState(state)
    if state == 2 then
        races = utils.loadRaceData()
    end
end

local function loadExtensions()
    print("Initializing Freeroam Events Modules")

    local freeroamPath = "/lua/ge/extensions/gameplay/events/freeroam/"
    local files = FS:findFiles(freeroamPath, "*.lua", -1, true, false)
    
    if files then
        for _, filePath in ipairs(files) do
            local filename = string.match(filePath, "([^/]+)%.lua$")

            if filename then
                local extensionName = "gameplay_events_freeroam_" .. filename
                setExtensionUnloadMode(extensionName, "manual")
                extensions.unload(extensionName)
                table.insert(loadedExtensions, extensionName)
                print("Loaded extension: " .. extensionName)
            end
        end
    end
    loadManualUnloadExtensions()
end

local function unloadExtensions()
    for _, extensionName in ipairs(loadedExtensions) do
        extensions.unload(extensionName)
    end
end

local function onExtensionLoaded()
    print("Initializing Freeroam Events Main")
    loadExtensions()
    if getCurrentLevelIdentifier() then
        races = utils.loadRaceData()
        if races ~= {} then
            print("Race data loaded for level: " .. getCurrentLevelIdentifier())
        else
            print("No race data found for level: " .. getCurrentLevelIdentifier())
        end
    end
end

local function onExtensionUnloaded()
    unloadExtensions()
end

local function onUpdate(dtReal, dtSim, dtRaw)
    if mActiveRace and races[mActiveRace].checkpointRoad then -- before rolling start change
        if processRoad.checkPlayerOnRoad() == false then
            exitRace(false)
        end
    end
    if timerActive == true then
        in_race_time = in_race_time + dtSim
        local playerVehicleId = be:getPlayerVehicleID(0)
        if playerVehicleId then
            local currentSpeed = math.abs(be:getObjectVelocityXYZ(playerVehicleId)) * speedUnit
            if currentSpeed > maxSpeed then
                maxSpeed = currentSpeed
            end
        end
    else
        in_race_time = 0
    end
end

local function formatEventPoi(raceName, race)
    local startObj = scenetree.findObject("fre_start_" .. raceName)
    local pos = startObj and startObj:getPosition() or nil
    
    if not pos then return nil end

    local levelIdentifier = getCurrentLevelIdentifier()
    local preview = "/levels/" .. levelIdentifier .. "/facilities/freeroamEvents/" .. raceName .. ".jpg"

    local vehId = be:getPlayerVehicleID(0) or 0
    if career_career.isActive() then
        vehId = career_modules_inventory.getInventoryIdFromVehicleId(vehId) or vehId
    end

    return {
        id = raceName,
        data = {
            type = "events",
            facility = {}
        },
        markerInfo = {
            bigmapMarker = {
                pos = pos,
                icon = "mission_cup_triangle",
                name = race.label,
                description = utils.displayStagedMessage(vehId, raceName, true),
                previews = {preview},
                thumbnail = preview
            }
        }
    }
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
    if not races then
        return
    end
    for raceName, race in pairs(races) do
        local poi = formatEventPoi(raceName, race)
        if poi then
            table.insert(elements, poi)
        end
    end
end

local function onReplayStateChanged(state)
    if not isReplay and state.state == "playback" then
        isReplay = true
    elseif isReplay and state.state == "inactive" then
        isReplay = false
    end
end

local function onGameStateUpdate(state)
    if saveGameState then
        saveGameState = false
        previousGameState = state
    end
end

M.onGameStateUpdate = onGameStateUpdate

M.onReplayStateChanged = onReplayStateChanged
M.onBeamNGTrigger = onBeamNGTrigger
M.onUpdate = onUpdate

M.payoutRace = payoutRace
M.payoutDragRace = payoutDragRace
M.onWorldReadyState = onWorldReadyState
M.getRace = function(raceName) return races[raceName] end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M