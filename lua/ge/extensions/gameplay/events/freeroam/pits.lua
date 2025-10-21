local M = {}

local activeSpeedLimit = nil
local limitActive = false
local applyingLimit = false
local lastThrottleState = 0 -- Store the last known throttle state
local forcingStop = false -- Flag to indicate if we're in "stop first" mode
local limiterMode = "cruise" -- New variable to track which mode we're in

-- Function to get throttle input from vehicle
local function requestThrottleInput()
  local veh = be:getPlayerVehicle(0)
  if not veh then return end
  
  veh:queueLuaCommand([[
    local throttleInput = input.lastInputs["local"].throttle or 0
    obj:queueGameEngineLua('gameplay_events_freeroam_pits.receiveThrottleInput(' .. throttleInput .. ')')
  ]])
end

-- Function to receive throttle input from vehicle
local function receiveThrottleInput(value)
  lastThrottleState = value
end

-- Function to apply speed limit to the vehicle
local function applySpeedLimit(dt)
  if not activeSpeedLimit or not limitActive then return end
  
  -- Get the current player vehicle
  local veh = be:getPlayerVehicle(0)
  if not veh then return end
  
  -- Get current speed in m/s
  local vel = veh:getVelocity():length()
  
  -- Check if we're in "force stop" mode
  if forcingStop then
    -- Apply full brakes until vehicle is almost stopped
    veh:queueLuaCommand("input.event('throttle', 0, 1, nil, nil, nil, 'code')")
    veh:queueLuaCommand("input.event('brake', 0.85, 1, nil, nil, nil, 'code')")
    
    -- Check if we've reached near-stop condition
    if vel < 1.0 then
      -- Vehicle is almost stopped, switch to regular limit mode
      forcingStop = false
      applyingLimit = false
      log('I', 'pits', 'Vehicle stopped and repaired, now applying regular speed limit of ' .. 
          math.floor(activeSpeedLimit * 3.6) .. ' km/h')
      if not career_career then
        veh:queueLuaCommand([[
          recovery.startRecovering()
          recovery.stopRecovering()
        ]])
      end
      veh:queueLuaCommand([[
        input.event('brake', 0.5, 1, nil, nil, nil, 'code')
        input.event('throttle', 0.5, 1, nil, nil, nil, 'code')
        input.event('brake', 0, 1, nil, nil, nil, 'code')
        input.event('throttle', 0, 1, nil, nil, nil, 'code')
      ]])
    end
    
    return
  end
  
  -- Regular speed limiting logic (unchanged)
  
  -- Request the throttle input (will be available on next frame)
  requestThrottleInput()
  
  -- Check if we're currently applying a limit
  local wasLimiting = applyingLimit
  
  -- Calculate how close we are to the speed limit (0.0 = at limit, 1.0 = far below)
  local speedRatio = 1.0 - (vel / activeSpeedLimit)
  
  -- Speed limit behavior
  if vel >= activeSpeedLimit then
    -- We're at or above the speed limit - always apply brakes
    
    -- Calculate how much we're over the limit for proportional braking
    local overSpeed = vel - activeSpeedLimit
    local brakeAmount = math.min(1.0, overSpeed * 0.5)
    
    -- Always cut throttle and apply brakes when over the limit
    veh:queueLuaCommand("input.event('throttle', 0, 1, nil, nil, nil, 'code')")
    veh:queueLuaCommand("input.event('brake', " .. brakeAmount .. ", 1, nil, nil, nil, 'code')")
    
    applyingLimit = true
  else
    -- We're below the speed limit
    
    -- If the user is holding throttle, help them maintain the speed limit
    if lastThrottleState > 0.01 then
      -- Calculate how much we're under the limit
      local underSpeed = activeSpeedLimit - vel
      
      -- Calculate proximity factor (becomes smaller as we approach the limit)
      local proximityFactor = math.min(1.0, speedRatio * 2.0)
      
      -- Apply throttle more conservatively as we approach the limit
      local throttleAmount
      
      if speedRatio < 0.05 then
        -- Within 5% of the limit, be very conservative
        throttleAmount = math.min(lastThrottleState, 0.20)
      elseif speedRatio < 0.15 then
        -- Within 15% of the limit, be somewhat conservative
        throttleAmount = math.min(lastThrottleState, lastThrottleState * proximityFactor + 0.1 * underSpeed)
      else
        -- Far from the limit, apply more throttle but still avoid overshooting
        throttleAmount = math.min(1.0, lastThrottleState + (underSpeed * 0.1 * proximityFactor))
      end
      
      -- Apply the calculated throttle to maintain speed
      veh:queueLuaCommand("input.event('throttle', " .. throttleAmount .. ", 1, nil, nil, nil, 'code')")
      
      -- Make sure we're not braking
      veh:queueLuaCommand("input.event('brake', 0, 1)")
      
      applyingLimit = true
    else
      -- User isn't applying throttle, let them control the vehicle
      if wasLimiting then
        applyingLimit = false
      end
    end
  end
end

local function applyGovernorLimit(dt)
  if not activeSpeedLimit or not limitActive then return end
  local veh = be:getPlayerVehicle(0)
  if not veh then return end
  local vel = veh:getVelocity():length()
  if forcingStop then
    veh:queueLuaCommand("input.event('throttle', 0, 1, nil, nil, nil, 'code')")
    veh:queueLuaCommand("input.event('brake', 0.85, 1, nil, nil, nil, 'code')")
    if vel < 1.0 then
      forcingStop = false
      applyingLimit = false
      if not career_career then
        veh:queueLuaCommand([[ recovery.startRecovering() recovery.stopRecovering() ]])
      end
      veh:queueLuaCommand([[ input.event('brake', 0.5, 1) input.event('throttle', 0.5, 1) input.event('brake', 0, 1) input.event('throttle', 0, 1) ]])
    end
    return
  end
  requestThrottleInput()
  local maxAllowedThrottle = 1.0
  local governorStartSpeed = activeSpeedLimit * 0.9
  if vel > governorStartSpeed then
    local progress = (vel - governorStartSpeed) / (activeSpeedLimit - governorStartSpeed)
    progress = math.max(0, math.min(1, progress))
    maxAllowedThrottle = 1.0 - progress
  end
  local finalThrottle = math.min(lastThrottleState, maxAllowedThrottle)
  veh:queueLuaCommand("input.event('throttle', " .. finalThrottle .. ", 1, nil, nil, nil, 'code')")
end

local function _baseSetLimit(limit, unit)
  if type(limit) ~= "number" or limit <= 0 then
    activeSpeedLimit, limitActive, applyingLimit, forcingStop = nil, false, false, false
    return false
  end
  local limitInMPS = limit
  if unit then
    unit = string.upper(unit)
    if unit == "MPH" then limitInMPS = limit * 0.44704 end
    if unit == "KPH" then limitInMPS = limit * 0.27778 end
  end
  activeSpeedLimit = limitInMPS
  limitActive = true
  return true
end

local function setSpeedLimit(limit, unit)
  if _baseSetLimit(limit, unit) then
    limiterMode = "cruise"
    log('I', 'pits', 'Cruise Control speed limit set.')
  end
end

-- Function to first stop the vehicle completely, then apply speed limit
local function stopThenLimit(limit, unit)
  if setSpeedLimit(limit, unit) then
    forcingStop = true
    log('I', 'pits', 'Stopping vehicle before applying cruise control limit...')
  end
end

local function setGovernorLimit(limit, unit)
  if _baseSetLimit(limit, unit) then
    limiterMode = "governor"
    log('I', 'pits', 'Throttle Governor speed limit set.')
  end
end

local function stopThenGovernor(limit, unit)
  if setGovernorLimit(limit, unit) then
    forcingStop = true
    log('I', 'pits', 'Stopping vehicle before applying governor limit...')
  end
end

-- Function to toggle the speed limit on/off without changing the value
local function toggleSpeedLimit()
  limitActive = not limitActive
  if not limitActive then
    be:getPlayerVehicle(0):queueLuaCommand([[ input.event('throttle', 1, 1) input.event('brake', 0, 1) ]])
    forcingStop = false
  end
  return limitActive
end

local function clearSpeedLimit()
  activeSpeedLimit, limitActive, applyingLimit, forcingStop, limiterMode = nil, false, false, false, "cruise"
end

-- Update function to be called in the vehicle update loop
local function onUpdate(dt)
  if activeSpeedLimit and limitActive then
    if limiterMode == "governor" then
      applyGovernorLimit(dt)
    else -- Default to cruise control
      applySpeedLimit(dt)
    end
  end
end

-- Register this module to receive updates
M.onUpdate = onUpdate
M.setSpeedLimit = setSpeedLimit
M.toggleSpeedLimit = toggleSpeedLimit
M.stopThenLimit = stopThenLimit
M.receiveThrottleInput = receiveThrottleInput
M.clearSpeedLimit = clearSpeedLimit

M.setGovernorLimit = setGovernorLimit
M.stopThenGovernor = stopThenGovernor
return M