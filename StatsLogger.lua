--[[
    StatsLogger.lua
    Version: 1.0.0

    Purpose:
    To log Air-to-Air (A2A) and Air-to-Ground (A2G) combat statistics for each pilot
    and each formation/group within a DCS World mission. This includes tracking shots,
    hits, kills, and deaths.

    Usage:
    Intended to be loaded as a server-side script in a DCS World mission.
    Typically, this is done by adding the following line to your mission's
    `MissionScripting.lua` file (if using MIST or a similar framework that loads it),
    or an `Export.lua` setup for more direct integration with DCS's export environment:
    
    dofile(lfs.writedir() .. [[Scripts\StatsLogger.lua]])

    Ensure that this StatsLogger.lua file is placed in the %USERPROFILE%\Saved Games\DCS\Scripts\
    directory (or the equivalent for your DCS installation, like DCS.openbeta).

    Dependencies:
    Relies heavily on MIST (Mission Scripting Tools), ideally version 4.3.74 or later.
    This is due to the use of functions like `mist.utils.log`, `mist.scheduleFunction`,
    `mist.addEventHandler`, and assumptions about the structure of `mist.DBs` (e.g.,
    `mist.DBs.Players`, `mist.DBs.unitsById`, `mist.DBs.playersByUnitName`).
    MIST (e.g., mist.lua or a versioned file like mist-4_5_110.lua) should be placed in:
    - %USERPROFILE%\Saved Games\DCS\Scripts\mist.lua
    - %USERPROFILE%\Saved Games\DCS\Scripts\MIST\mist.lua (if organized in a MIST subfolder)

    Output:
    - Debug Log: Creates a detailed operational log at `Logs\StatsLogger.txt` within
      the `lfs.writedir()` path (typically %USERPROFILE%\Saved Games\DCS\). This log
      tracks script initialization, event processing, errors, and other diagnostic info.
    - Statistics Summary: Generates a human-readable summary of all collected statistics
      at `Logs\CombatStats_Summary.txt` (also in `lfs.writedir()\Logs\`). This file is
      overwritten periodically and upon mission end.

    Key Features:
    - Tracks individual pilot statistics (keyed by UCID if available, otherwise by pilot name).
    - Tracks aggregate statistics for formations/groups.
    - Records weapon-specific statistics for pilots (shots, hits, kills per weapon type).
    - Distinguishes between A2A and A2G engagements.
    - Includes basic friendly fire detection (based on coalition allegiance).
    - Handles various combat events: SHOT, HIT, KILL, UNIT_LOST, PLAYER_DEAD.
    - Data persistence: Saves statistics periodically and at the end of the mission.
    - Centralized logging with fallback to file if MIST logger is unavailable.
--]]

-- Attempt to load MIST.
-- lfs.writedir() typically points to %USERPROFILE%\Saved Games\DCS (or DCS.openbeta)
local mist_search_paths = {
    lfs.writedir() .. [[Scripts\mist.lua]],
    lfs.writedir() .. [[Scripts\MIST\mist.lua]], -- Common alternative path
    lfs.writedir() .. [[Scripts\mist-4.5.110.lua]], -- Example specific version
    lfs.writedir() .. [[Scripts\mist-4.3.74.lua]]  -- Example specific version
}
local mist_loaded_successfully = false
local mist_load_err = "MIST not found in any specified path."

for _, path in ipairs(mist_search_paths) do
    local success, err = pcall(function() dofile(path) end)
    if success then
        mist_loaded_successfully = true
        mist_load_err = nil -- Clear error as MIST loaded
        break -- Exit loop once MIST is loaded
    else
        mist_load_err = err -- Store the last error
    end
end

-- Centralized Log function
-- This function handles all logging for the script. If MIST and its logging utility are available,
-- it uses mist.utils.log. Otherwise, it falls back to writing log messages to a local file.
local currentLogPath = lfs.writedir() .. [[Logs\StatsLogger.txt]]
local function Log(message, level)
    local logLevel = level or "INFO" 
    if mist and mist.utils and mist.utils.log then
        mist.utils.log("StatsLogger: " .. message, logLevel) 
    else
        local file, err_io = io.open(currentLogPath, "a")
        if file then
            file:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. logLevel .. ": " .. message .. "\n")
            file:close()
        else
            print(os.date("[%Y-%m-%d %H:%M:%S] ") .. "StatsLogger Fallback Log Error: Failed to open log file: " .. tostring(err_io) .. " | Original Message (" .. logLevel .. "): " .. message)
        end
    end
end

if mist_loaded_successfully and mist and mist.utils and mist.utils.log then
    Log("MIST loaded successfully. Version (if available via mist.version): " .. (mist.version or "Unknown/Older"), "INFO")
else
    local error_message = "CRITICAL ERROR: StatsLogger.lua could not load MIST or the MIST version is too old (missing mist.utils.log or other key functions). " ..
                          "Ensure a compatible MIST version (e.g., v4.3.74 or later) is correctly placed in " ..
                          "Saved Games\\DCS\\Scripts\\ (e.g., mist.lua) or Saved Games\\DCS\\Scripts\\MIST\\mist.lua. " ..
                          "Last MIST load attempt error: " .. tostring(mist_load_err)
    Log(error_message, "ERROR") 
    print(error_message) 
end

-- Initialize main statistics tables
pilotStats = pilotStats or {}       -- Keyed by pilot UCID (preferred) or name. Stores A2A/A2G kills, hits, shots, deaths, weapon stats.
formationStats = formationStats or {} -- Keyed by group/formation name. Stores aggregate A2A/A2G kills, hits, shots, deaths.

Log("StatsLogger.lua initialized. pilotStats and formationStats tables prepared.", "INFO")


--[[
    Data Access Helper Functions
    These functions are responsible for extracting detailed information from DCS World objects
    (Units, Weapons) passed within event data. They include robust checks for object existence
    and attempt to use MIST database information for more accurate player details where possible.
]]
function getUnitDetails(unitObject)
    if not unitObject or not unitObject:isExist() then
        Log("getUnitDetails: called with invalid or non-existent unitObject.", "WARNING")
        return nil -- Return nil to indicate failure to retrieve details
    end

    local unitId = unitObject:getID()
    -- Initialize detail structure with defaults. These are populated sequentially.
    local details = {
        name = "UnknownName_ID_" .. tostring(unitId), 
        typeName = "UnknownType",
        groupName = "UnknownGroup",
        category = "UnknownCategory", -- e.g., "Air", "Ground", "Naval"
        isPlayer = false,
        coalition = "UnknownCoalition",
        ucid = "N/A_UCID", -- Unique Client ID, "N/A_UCID" signifies not found or not applicable
        id = unitId -- DCS Unit ID
    }

    details.typeName = unitObject:getTypeName() or details.typeName
    
    local coalitionId = unitObject:getCoalition()
    if coalitionId == 0 then details.coalition = "Neutral"
    elseif coalitionId == 1 then details.coalition = "Red"
    elseif coalitionId == 2 then details.coalition = "Blue"
    else details.coalition = "OtherCoalition-" .. tostring(coalitionId) -- Handle non-standard coalition IDs
    end

    local controller = unitObject:getController()
    if controller then
        if controller:isPlayer() then
            details.isPlayer = true
            local unitNameInME = unitObject:getName() or ("PlayerUnitME_ID_" .. tostring(unitId)) 
            local playerNameByUnit = unitObject:getPlayerName() 

            if playerNameByUnit and playerNameByUnit ~= "" then
                details.name = playerNameByUnit
                Log("getUnitDetails: Player detected. Initial name from unitObject:getPlayerName(): '" .. playerNameByUnit .. "'. ME Name: '" .. unitNameInME .. "'.", "DEBUG")
            else
                details.name = unitNameInME
                Log("getUnitDetails: Player detected. Initial name from unitObject:getName() (ME Name): '" .. unitNameInME .. "' (getPlayerName was empty).", "DEBUG")
            end
            
            -- Attempt to get UCID and refine name using MIST if available and MIST DBs are populated
            if mist and mist.DBs then
                local foundUcidViaMist = false
                local mistPlayerName = nil
                
                -- 1. Try mist.DBs.unitsById (preferred MIST structure for linking unitId to player data)
                if mist.DBs.unitsById and mist.DBs.unitsById[unitId] and mist.DBs.unitsById[unitId].player then
                    local mistUnitPlayerData = mist.DBs.unitsById[unitId].player
                    if mistUnitPlayerData.ucid and mistUnitPlayerData.ucid ~= "" then
                        details.ucid = mistUnitPlayerData.ucid
                        mistPlayerName = mistUnitPlayerData.name
                        foundUcidViaMist = true
                        Log("getUnitDetails: UCID '" .. details.ucid .. "' and MIST name '" .. (mistPlayerName or "N/A") .. "' found for unit ID " .. unitId .. " via mist.DBs.unitsById.", "DEBUG")
                    end
                end

                -- 2. Fallback to playersByUnitName (using ME name as key, less reliable if ME names are not unique for players)
                if not foundUcidViaMist and mist.DBs.playersByUnitName and mist.DBs.playersByUnitName[unitNameInME] then
                    local mistPBUData = mist.DBs.playersByUnitName[unitNameInME]
                    if mistPBUData.ucid and mistPBUData.ucid ~= "" then
                        details.ucid = mistPBUData.ucid
                        mistPlayerName = mistPBUData.name
                        foundUcidViaMist = true
                        Log("getUnitDetails: UCID '" .. details.ucid .. "' and MIST name '" .. (mistPlayerName or "N/A") .. "' found for ME name '"..unitNameInME.."' via mist.DBs.playersByUnitName.", "DEBUG")
                    end
                end
                
                -- 3. Fallback: Iterate MIST.DBs.Players (most comprehensive search if other methods fail)
                if not foundUcidViaMist and mist.DBs.Players then
                    Log("getUnitDetails: Searching for UCID in mist.DBs.Players for unit ID "..unitId..", current name '"..details.name.."', ME name '"..unitNameInME.."'...", "DEBUG")
                    for ucid_key, playerData in pairs(mist.DBs.Players) do
                        local matchReason = nil
                        if playerData.unitId and playerData.unitId == unitId then matchReason = "unitId match"
                        elseif playerData.name and playerData.name == details.name then matchReason = "current details.name match"
                        elseif unitNameInME and playerData.unitname and playerData.unitname == unitNameInME then matchReason = "ME name match"
                        end
                        
                        if matchReason then
                            details.ucid = ucid_key
                            mistPlayerName = playerData.name
                            foundUcidViaMist = true
                            Log("getUnitDetails: UCID '" .. details.ucid .. "' and MIST name '" .. (mistPlayerName or "N/A") .. "' found by iterating mist.DBs.Players. Match reason: " .. matchReason, "DEBUG")
                            break
                        end
                    end
                end

                if foundUcidViaMist then
                    if mistPlayerName and mistPlayerName ~= "" and mistPlayerName ~= details.name then
                        Log("getUnitDetails: Updating player name from '"..details.name.."' to MIST-provided name '"..mistPlayerName.."'.", "DEBUG")
                        details.name = mistPlayerName
                    end
                else
                    Log("getUnitDetails: MIST Player DB structures (unitsById, playersByUnitName, Players) did not yield a UCID for unit ID " .. unitId .. ", Player Name: " .. details.name, "DEBUG")
                end
            else
                Log("getUnitDetails: MIST or mist.DBs not available for UCID retrieval for player: " .. details.name .. " (Unit ID: " .. unitId .. ").", "DEBUG")
            end
            
            if details.ucid == "N/A_UCID" then
                 Log("getUnitDetails: UCID remains N/A for player: " .. details.name .. " (Unit ID: " .. unitId .. "). Will use name as key if this pilot is involved in stats.", "WARNING")
            end
            Log("getUnitDetails: Player unit processed: Name='" .. details.name .. "', UCID='" .. details.ucid .. "', Type='" .. details.typeName .. "', Coalition='" .. details.coalition .. "'.", "INFO")
        else
            details.name = unitObject:getName() or ("AI_UnitID_" .. tostring(unitId)) 
            Log("getUnitDetails: AI unit processed: Name='" .. details.name .. "', Type='" .. details.typeName .. "', Coalition='" .. details.coalition .. "'.", "INFO")
        end
    else
        details.name = unitObject:getName() or ("NoController_UnitID_" .. tostring(unitId)) 
        Log("getUnitDetails: Unit with no controller (e.g., static object): Name='" .. details.name .. "', Type='" .. details.typeName .. "', Coalition='" .. details.coalition .. "'.", "DEBUG")
    end

    local group = unitObject:getGroup()
    if group and group:isExist() then
        details.groupName = group:getName() or "UnnamedGroup_ID_"..tostring(group:getID())
        local groupCatId = group:getCategory()
        if groupCatId == Group.Category.AIRPLANE or groupCatId == Group.Category.HELICOPTER then
            details.category = "Air"
        elseif groupCatId == Group.Category.GROUND then
            details.category = "Ground"
        elseif groupCatId == Group.Category.SHIP then
            details.category = "Naval"
        else
            details.category = "Static/Other" -- Includes fortifications, etc.
            Log("getUnitDetails: Unit '" .. details.name .. "' in group '" .. details.groupName .. "' has unhandled/Static group category ID: " .. tostring(groupCatId), "DEBUG")
        end
    else
        Log("getUnitDetails: Unit '" .. details.name .. "' (ID: " .. details.id .. ") has no group or group does not exist. GroupName set to default for ungrouped units.", "DEBUG")
        details.groupName = "Ungrouped_UnitID_" .. tostring(details.id) 
    end
    
    Log("getUnitDetails: Final details for unit ID " .. details.id .. ": Name=" .. details.name .. ", UCID=" .. details.ucid .. ", Group=" .. details.groupName .. ", Category=" .. details.category .. ", Coalition=" .. details.coalition, "DEBUG")
    return details
end

function getWeaponDetails(weaponObject)
    if not weaponObject or not weaponObject:isExist() then
        Log("getWeaponDetails: called with invalid or non-existent weaponObject.", "WARNING")
        return { name = "UnknownWeapon_InvalidObj", typeName = "UnknownWeaponType_InvalidObj" } 
    end
    local details = {
        name = weaponObject:getName() or "DefaultWeaponName", 
        typeName = weaponObject:getTypeName() or "DefaultWeaponTypeName"
    }
    -- Ensure names are not empty strings, providing a placeholder if they are.
    if details.name == "" then details.name = "EmptyWeaponName_Resolved" end
    if details.typeName == "" then details.typeName = "EmptyWeaponTypeName_Resolved" end

    Log("getWeaponDetails: Weapon: Name='" .. details.name .. "', TypeName='" .. details.typeName .. "'.", "DEBUG")
    return details
end

Log("Data Access Helper Functions (getUnitDetails, getWeaponDetails) defined/refined.", "INFO")

--[[
    Statistic Recording Logic
    Core functions for initializing and updating pilot and formation statistics tables.
]]
-- Ensures a pilot entry exists in pilotStats, using UCID as preferred key.
-- If UCID is invalid, falls back to pilot name. If both are invalid, logs error and creates a temporary key.
function ensurePilotStats(ucid_param, pilotName_param)
    local keyToUse = nil
    local currentPilotName = pilotName_param or "UnknownPilotName_Ensure" 
    local currentPilotUCID = ucid_param

    -- Sanitize inputs slightly: empty strings to nil for UCID for easier checking
    if currentPilotName == "" or currentPilotName:match("UnknownName_ID_") then 
        currentPilotName = "InvalidNameInEnsure_" .. (currentPilotUCID or "NoUCID")
    end
    if currentPilotUCID == "" then currentPilotUCID = nil end -- Treat empty UCID as nil for logic

    -- 1. Prioritize UCID if it's valid (not nil, not "N/A_UCID", not "Unknown")
    if currentPilotUCID and currentPilotUCID ~= "N/A_UCID" and currentPilotUCID ~= "Unknown" then
        keyToUse = currentPilotUCID
    -- 2. Fallback to name if UCID is invalid/missing AND name is somewhat valid
    elseif currentPilotName and currentPilotName ~= "UnknownPilotName_Ensure" and not currentPilotName:match("InvalidNameInEnsure_") then
        keyToUse = currentPilotName 
        Log("ensurePilotStats: Using pilotName '" .. currentPilotName .. "' as key due to invalid or missing UCID ('" .. tostring(currentPilotUCID) .. "').", "WARNING")
    else
        -- 3. If both UCID and Name are problematic, create a temporary unique key to prevent data loss/collision.
        local tempKeySuffix = (currentPilotUCID or "NoUCIDProvided") .. "_" .. (currentPilotName or "NoNameProvided")
        -- Remove problematic characters for a clean key
        local tempKey = "ErrorStatsKey_" .. string.gsub(tempKeySuffix, "[^%w_]", "") .. "_" .. os.time() .. "_" .. math.random(1000)
        Log("ensurePilotStats: Critical: Cannot determine valid key from UCID ('" .. tostring(currentPilotUCID) .. "') and pilotName ('" .. tostring(currentPilotName) .. "'). Using temporary key: " .. tempKey, "ERROR")
        keyToUse = tempKey
        -- For display purposes, the stats entry will reflect the problematic inputs
        currentPilotName = "ErrDisplay_Name_" .. (pilotName_param or "Nil") 
        currentPilotUCID = "ErrDisplay_UCID_" .. (ucid_param or "Nil")
    end

    if not pilotStats[keyToUse] then
        pilotStats[keyToUse] = {
            ucid = (currentPilotUCID and currentPilotUCID ~= "N/A_UCID" and not currentPilotUCID:match("ErrDisplay_")) and currentPilotUCID or "N/A_StoredAtInit",
            name = currentPilotName, 
            A2A_kills = 0, A2G_kills = 0,
            A2A_hits = 0, A2G_hits = 0,
            A2A_shots = 0, A2G_shots = 0,
            deaths = 0,
            friendly_fire_kills = 0, 
            friendly_fire_hits = 0,  
            weaponStats = {} -- Keyed by weapon type name
        }
        Log("Initialized stats for pilot key: '" .. keyToUse .. "' (Stored Name: '" .. pilotStats[keyToUse].name .. "', Stored UCID: '" .. pilotStats[keyToUse].ucid .. "')", "INFO")
    else
        -- Entry exists. Attempt to update name/UCID if new info is more accurate or complete.
        local statsEntry = pilotStats[keyToUse]
        if (statsEntry.ucid == "N/A_StoredAtInit" or statsEntry.ucid:match("ErrDisplay_")) and 
           (currentPilotUCID and currentPilotUCID ~= "N/A_UCID" and not currentPilotUCID:match("ErrDisplay_")) then
            Log("ensurePilotStats: Updating UCID for key '" .. keyToUse .. "' from '"..statsEntry.ucid.."' to '" .. currentPilotUCID .. "'.", "INFO")
            statsEntry.ucid = currentPilotUCID
        end
        if (statsEntry.name:match("UnknownPilotName_Ensure") or statsEntry.name:match("InvalidNameInEnsure_") or statsEntry.name:match("ErrDisplay_")) and 
           (currentPilotName and not currentPilotName:match("UnknownPilotName_Ensure") and not currentPilotName:match("InvalidNameInEnsure_") and not currentPilotName:match("ErrDisplay_")) then
            if statsEntry.name ~= currentPilotName then
                 Log("ensurePilotStats: Updating display name for key '" .. keyToUse .. "' from '" .. statsEntry.name .. "' to '" .. currentPilotName .. "'.", "INFO")
                statsEntry.name = currentPilotName
            end
        end
    end
    return keyToUse -- Return the key used (ucid, name, or temp error key)
end

-- Ensures a formation entry exists in formationStats.
-- If formationName is invalid or placeholder, assigns to a default "Ungrouped_Units" category.
local function ensureFormationStats(formationName_param)
    local formationName = formationName_param
    -- Check for nil, empty, or specific placeholder names that indicate an invalid/unknown group
    if not formationName or formationName == "" or formationName == "UnknownGroup" or 
       formationName:match("Ungrouped_UnitID_") or formationName:match("UnnamedGroup_ID_") then
        Log("ensureFormationStats: Invalid or placeholder formationName ('" .. tostring(formationName) .. "'). Assigning to default 'Ungrouped_Units' category.", "DEBUG")
        formationName = "Ungrouped_Units" 
    end

    if not formationStats[formationName] then
        formationStats[formationName] = {
            A2A_kills = 0, A2G_kills = 0,
            A2A_hits = 0, A2G_hits = 0,
            A2A_shots = 0, A2G_shots = 0,
            deaths = 0, -- Total deaths of units belonging to this formation
            friendly_fire_kills = 0, -- Total FF kills by members of this formation
            friendly_fire_hits = 0   -- Total FF hits by members of this formation
        }
        Log("Initialized stats for formation: '" .. formationName .. "'", "INFO")
    end
    return formationName
end

-- Updates weapon-specific statistics for a given pilot.
local function updatePilotWeaponStats(pilotKey, weaponTypeName_param, statType) -- statType: "shots", "hits", or "kills"
    local weaponTypeName = weaponTypeName_param
    if not pilotKey or not pilotStats[pilotKey] then
        Log("updatePilotWeaponStats: Invalid pilotKey '" .. tostring(pilotKey) .. "'. Cannot update weapon stats.", "WARNING")
        return
    end
    -- Handle invalid, default, or empty weapon type names by categorizing them under a specific "TrackedUnknownWeapon"
    if not weaponTypeName or weaponTypeName == "" or weaponTypeName == "UnknownWeaponType" or 
       weaponTypeName:match("UnknownWeaponType_InvalidObj") or weaponTypeName:match("DefaultWeaponTypeName") or 
       weaponTypeName:match("EmptyWeaponTypeName_Resolved") or weaponTypeName:match("UnknownWeapon_NotAvailable") then
        Log("updatePilotWeaponStats: Invalid or default weaponTypeName ('"..tostring(weaponTypeName).."') for pilotKey '" .. pilotKey .. "'. Using 'TrackedUnknownWeapon'.", "DEBUG")
        weaponTypeName = "TrackedUnknownWeapon"
    end

    if not pilotStats[pilotKey].weaponStats[weaponTypeName] then
        pilotStats[pilotKey].weaponStats[weaponTypeName] = { shots = 0, hits = 0, kills = 0 }
    end
    pilotStats[pilotKey].weaponStats[weaponTypeName][statType] = (pilotStats[pilotKey].weaponStats[weaponTypeName][statType] or 0) + 1
    Log("Updated weapon stats for " .. pilotStats[pilotKey].name .. " (Key: "..pilotKey..") - Weapon: " .. weaponTypeName .. ", Stat: " .. statType .. " = " .. pilotStats[pilotKey].weaponStats[weaponTypeName][statType], "DEBUG")
end

Log("Statistic Recording Helper Functions (ensurePilotStats, ensureFormationStats, updatePilotWeaponStats) defined/refined.", "INFO")

--[[
    Main Event Handler: StatsEventHandler
    This function is the central processor for all DCS events relevant to statistics tracking.
    It is registered with MIST (or the native world event system) to be called for every event.
--]]
function StatsEventHandler(event)
    if not event or not event.id then
        Log("StatsEventHandler: Received an invalid event object (nil or no ID).", "WARNING")
        return
    end

    Log("StatsEventHandler: Event received: ID = " .. tostring(event.id) .. ", Time = " .. string.format("%.2f", event.time), "DEBUG")

    -- Event Object Assumptions:
    -- The script assumes that event.initiator, event.target, and event.weapon (where applicable)
    -- will contain DCS World objects (Unit, Weapon, StaticObject, SceneryObject etc.).
    -- Properties like `.object_` (for MIST-wrapped objects) or direct method calls (e.g., `unit:getName()`)
    -- are accessed based on common usage patterns observed in DCS scripting and MIST examples.
    -- A definitive list of all event parameters for all event types across all DCS versions
    -- was not available during development. Logic is based on best effort for common combat events.
    -- If MIST wraps objects, `.object_` is typically the way to get the raw DCS object.
    -- If events provide direct DCS objects, they are used as is.
    -- Robust `isExist()` checks are used before accessing methods on these objects.

    local initiatorDetails = nil
    local targetDetails = nil
    local weaponDetails = nil -- Will hold {name, typeName} from getWeaponDetails
    local eventType = "UnknownEvent" -- Type of event (SHOT, HIT, KILL, etc.)
    local interactionType = "N/A" -- A2A, A2G, G2A, Other
    local isFriendlyFire = false

    -- Process Initiator: Extract details if the initiator object exists
    if event.initiator then
        local objToDetail = event.initiator.object_ or event.initiator -- Handle MIST-wrapped or direct objects
        if objToDetail and objToDetail.isExist and objToDetail:isExist() then
            initiatorDetails = getUnitDetails(objToDetail)
        else
            Log("StatsEventHandler: Event " .. event.id .. ": Initiator object ("..tostring(event.initiator)..") does not exist or is invalid.", "DEBUG")
        end
    end

    -- Process Target: Extract details if the target object exists
    if event.target then
        local objToDetail = event.target.object_ or event.target
        if objToDetail and objToDetail.isExist and objToDetail:isExist() then
            targetDetails = getUnitDetails(objToDetail)
        else
             Log("StatsEventHandler: Event " .. event.id .. ": Target object ("..tostring(event.target)..") does not exist or is invalid.", "DEBUG")
        end
    end
    
    -- Process Weapon: Extract details if the weapon object exists
    if event.weapon then
        local objToDetail = event.weapon.object_ or event.weapon
        if objToDetail and objToDetail.isExist and objToDetail:isExist() then
            weaponDetails = getWeaponDetails(objToDetail)
        else
             Log("StatsEventHandler: Event " .. event.id .. ": Weapon object ("..tostring(event.weapon)..") does not exist or is invalid.", "DEBUG")
        end
    end
    -- Ensure weaponDetails is always a table, even if weapon processing failed, for safe access later
    weaponDetails = weaponDetails or { name = "UnknownWeapon_NotAvailableInEvent", typeName = "UnknownWeaponType_NotAvailableInEvent" }


    -- Determine Interaction Type (A2A, A2G, etc.) and check for Friendly Fire
    if initiatorDetails and targetDetails then
        -- Determine category of interaction based on initiator and target categories
        if initiatorDetails.category == "Air" and targetDetails.category == "Air" then
            interactionType = "A2A"
        elseif initiatorDetails.category == "Air" and (targetDetails.category == "Ground" or targetDetails.category == "Naval") then
            interactionType = "A2G"
        elseif (initiatorDetails.category == "Ground" or initiatorDetails.category == "Naval") and targetDetails.category == "Air" then
            interactionType = "G2A" -- Ground-to-Air
        else
            interactionType = "Other" -- e.g., Ground-to-Ground, Naval-to-Naval, etc.
        end
        
        -- Basic friendly fire check: same coalition, not neutral, and not self-harm
        if initiatorDetails.coalition ~= "UnknownCoalition" and targetDetails.coalition ~= "UnknownCoalition" and 
           initiatorDetails.coalition == targetDetails.coalition and 
           initiatorDetails.coalition ~= "Neutral" and -- Exclude neutral-on-neutral as FF
           initiatorDetails.id ~= targetDetails.id then -- Ensure initiator is not the target (self-harm is not FF)
                 isFriendlyFire = true
                 Log("StatsEventHandler: Friendly fire detected: Initiator " .. initiatorDetails.name .. " (Coal: " .. initiatorDetails.coalition .. ") vs Target " .. targetDetails.name .. " (Coal: " .. targetDetails.coalition .. ")", "INFO")
        end
    end
    
    -- Log the extracted details for debugging purposes (can be set to higher log level like TRACE if too verbose)
    if initiatorDetails then
        Log("StatsEventHandler: Initiator: " .. initiatorDetails.name .. " (UCID: " .. initiatorDetails.ucid .. ", Cat: " .. initiatorDetails.category .. ", Group: " .. initiatorDetails.groupName .. ", Player: " .. tostring(initiatorDetails.isPlayer) .. ", Coal: " .. initiatorDetails.coalition .. ")", "DEBUG")
    end
    if targetDetails then
        Log("StatsEventHandler: Target: " .. targetDetails.name .. " (UCID: " .. targetDetails.ucid .. ", Cat: " .. targetDetails.category .. ", Group: " .. targetDetails.groupName .. ", Player: " .. tostring(targetDetails.isPlayer) .. ", Coal: " .. targetDetails.coalition .. ")", "DEBUG")
    end
    Log("StatsEventHandler: Weapon: " .. weaponDetails.name .. " (Type: " .. weaponDetails.typeName .. ")", "DEBUG")
    Log("StatsEventHandler: Interaction Type: " .. interactionType .. ", Friendly Fire: " .. tostring(isFriendlyFire), "DEBUG")

    -- Event-specific statistic recording logic
    if event.id == world.event.S_EVENT_SHOT then
        eventType = "SHOT"
        if initiatorDetails then
            local pilotKey = ensurePilotStats(initiatorDetails.ucid, initiatorDetails.name)
            local formationKey = ensureFormationStats(initiatorDetails.groupName)
            if pilotKey and formationKey then -- Check if valid keys were obtained
                if interactionType == "A2A" then
                    pilotStats[pilotKey].A2A_shots = (pilotStats[pilotKey].A2A_shots or 0) + 1
                    formationStats[formationKey].A2A_shots = (formationStats[formationKey].A2A_shots or 0) + 1
                elseif interactionType == "A2G" then
                    pilotStats[pilotKey].A2G_shots = (pilotStats[pilotKey].A2G_shots or 0) + 1
                    formationStats[formationKey].A2G_shots = (formationStats[formationKey].A2G_shots or 0) + 1
                end
                updatePilotWeaponStats(pilotKey, weaponDetails.typeName, "shots")
                Log(eventType .. ": " .. pilotStats[pilotKey].name .. " (" .. interactionType .. ") Weapon: "..weaponDetails.typeName, "INFO")
            else Log(eventType .. ": Failed to get valid pilot/formation key for initiator: " .. (initiatorDetails.name or "Name N/A"), "WARNING")
            end
        else Log(eventType .. ": Event missing initiator details or initiator could not be resolved.", "WARNING")
        end
        
    elseif event.id == world.event.S_EVENT_HIT then
        eventType = "HIT"
        if initiatorDetails and targetDetails then
            local initiatorPilotKey = ensurePilotStats(initiatorDetails.ucid, initiatorDetails.name)
            local initiatorFormationKey = ensureFormationStats(initiatorDetails.groupName)
            
            if initiatorPilotKey and initiatorFormationKey then
                if isFriendlyFire then
                    pilotStats[initiatorPilotKey].friendly_fire_hits = (pilotStats[initiatorPilotKey].friendly_fire_hits or 0) + 1
                    formationStats[initiatorFormationKey].friendly_fire_hits = (formationStats[initiatorFormationKey].friendly_fire_hits or 0) + 1
                    Log("Friendly HIT logged for " .. pilotStats[initiatorPilotKey].name .. " on " .. targetDetails.name, "INFO")
                else -- Not friendly fire, record as A2A or A2G hit
                    if interactionType == "A2A" then
                        pilotStats[initiatorPilotKey].A2A_hits = (pilotStats[initiatorPilotKey].A2A_hits or 0) + 1
                        formationStats[initiatorFormationKey].A2A_hits = (formationStats[initiatorFormationKey].A2A_hits or 0) + 1
                    elseif interactionType == "A2G" then
                        pilotStats[initiatorPilotKey].A2G_hits = (pilotStats[initiatorPilotKey].A2G_hits or 0) + 1
                        formationStats[initiatorFormationKey].A2G_hits = (formationStats[initiatorFormationKey].A2G_hits or 0) + 1
                    end
                end
                updatePilotWeaponStats(initiatorPilotKey, weaponDetails.typeName, "hits")
                Log(eventType .. ": " .. pilotStats[initiatorPilotKey].name .. " on " .. targetDetails.name .. " (" .. interactionType .. ") FF: " .. tostring(isFriendlyFire) .. " Weapon: "..weaponDetails.typeName, "INFO")
            else Log(eventType .. ": Failed to get valid pilot/formation key for initiator: " .. (initiatorDetails.name or "Name N/A"), "WARNING")
            end
        else Log(eventType .. ": Event missing initiator or target details, or they could not be resolved.", "WARNING")
        end

    elseif event.id == world.event.S_EVENT_KILL then
        eventType = "KILL"
        if initiatorDetails and targetDetails then -- Kill with known initiator and target
            local initiatorPilotKey = ensurePilotStats(initiatorDetails.ucid, initiatorDetails.name)
            local initiatorFormationKey = ensureFormationStats(initiatorDetails.groupName)
            local targetPilotKey = ensurePilotStats(targetDetails.ucid, targetDetails.name) 
            local targetFormationKey = ensureFormationStats(targetDetails.groupName)
            
            -- Update initiator's kill stats
            if initiatorPilotKey and initiatorFormationKey then 
                if isFriendlyFire then
                    pilotStats[initiatorPilotKey].friendly_fire_kills = (pilotStats[initiatorPilotKey].friendly_fire_kills or 0) + 1
                    formationStats[initiatorFormationKey].friendly_fire_kills = (formationStats[initiatorFormationKey].friendly_fire_kills or 0) + 1
                    Log("Friendly KILL logged by " .. pilotStats[initiatorPilotKey].name .. " on " .. targetDetails.name, "INFO")
                else
                    if interactionType == "A2A" then
                        pilotStats[initiatorPilotKey].A2A_kills = (pilotStats[initiatorPilotKey].A2A_kills or 0) + 1
                        formationStats[initiatorFormationKey].A2A_kills = (formationStats[initiatorFormationKey].A2A_kills or 0) + 1
                    elseif interactionType == "A2G" then
                        pilotStats[initiatorPilotKey].A2G_kills = (pilotStats[initiatorPilotKey].A2G_kills or 0) + 1
                        formationStats[initiatorFormationKey].A2G_kills = (formationStats[initiatorFormationKey].A2G_kills or 0) + 1
                    end
                end
                updatePilotWeaponStats(initiatorPilotKey, weaponDetails.typeName, "kills")
            else Log(eventType .. ": Failed to get valid pilot/formation key for KILL initiator: " .. (initiatorDetails.name or "Name N/A"), "WARNING")
            end
            
            -- Update target's death stats
            if targetPilotKey and targetFormationKey then 
                pilotStats[targetPilotKey].deaths = (pilotStats[targetPilotKey].deaths or 0) + 1
                formationStats[targetFormationKey].deaths = (formationStats[targetFormationKey].deaths or 0) + 1
            else Log(eventType .. ": Failed to get valid pilot/formation key for KILLED target: " .. (targetDetails.name or "Name N/A"), "WARNING")
            end

            Log(eventType .. ": " .. (initiatorDetails.name or "Unknown Initiator") .. " killed " .. targetDetails.name .. " (" .. interactionType .. ") FF: " .. tostring(isFriendlyFire) .. " Weapon: "..weaponDetails.typeName, "INFO")
        
        elseif not initiatorDetails and targetDetails then -- Kill by environment/world (no specific unit initiator)
            local targetPilotKey = ensurePilotStats(targetDetails.ucid, targetDetails.name)
            local targetFormationKey = ensureFormationStats(targetDetails.groupName)
            if targetPilotKey and targetFormationKey then
                pilotStats[targetPilotKey].deaths = (pilotStats[targetPilotKey].deaths or 0) + 1
                formationStats[targetFormationKey].deaths = (formationStats[targetFormationKey].deaths or 0) + 1
                Log(eventType .. ": " .. targetDetails.name .. " died (no specific unit initiator - e.g. crash, terrain impact, world object)", "INFO")
            else Log(eventType .. ": Failed to get valid pilot/formation key for KILLED (by environment) target: " .. (targetDetails.name or "Name N/A"), "WARNING")
            end
        else -- Other kill scenarios (e.g. initiator known but target not, or vice-versa beyond simple environment kill)
             Log(eventType .. ": Received with insufficient initiator/target details for full processing. Initiator: " .. tostring(initiatorDetails) .. ", Target: " .. tostring(targetDetails), "WARNING")
        end

    elseif event.id == world.event.S_EVENT_UNIT_LOST or event.id == world.event.S_EVENT_PLAYER_DEAD then
        -- These events indicate a unit is lost or a player is considered dead.
        -- The 'initiator' field for these events usually refers to the unit that was lost/died.
        local unitLostDetails = nil
        if event.initiator then 
             local objToDetail = event.initiator.object_ or event.initiator
             if objToDetail and objToDetail.isExist and objToDetail:isExist() then
                unitLostDetails = getUnitDetails(objToDetail)
            end
        end
        
        if unitLostDetails then
            eventType = (event.id == world.event.S_EVENT_UNIT_LOST) and "UNIT_LOST" or "PLAYER_DEAD"
            local pilotKey = ensurePilotStats(unitLostDetails.ucid, unitLostDetails.name)
            local formationKey = ensureFormationStats(unitLostDetails.groupName)
            
            if pilotKey and formationKey then
                -- This is a general catch-all for deaths. S_EVENT_KILL is more specific for combat kills.
                -- To avoid double-counting deaths if S_EVENT_KILL already handled it for this unit,
                -- a more sophisticated de-duplication (e.g., based on unit ID and recent timestamp) might be needed.
                -- For now, this will increment deaths. If S_EVENT_KILL also fires, it might lead to overcounting
                -- if not carefully managed or if event order is unexpected.
                -- However, this is crucial for capturing non-combat deaths (crashes, suicides).
                pilotStats[pilotKey].deaths = (pilotStats[pilotKey].deaths or 0) + 1 
                formationStats[formationKey].deaths = (formationStats[formationKey].deaths or 0) + 1
                Log(eventType .. ": " .. pilotStats[pilotKey].name .. " recorded as lost/dead. (This might be a crash, suicide, or an uncredited/environmental kill. Check S_EVENT_KILL for combat details.)", "INFO")
            else Log(eventType .. ": Failed to get pilot/formation key for lost/dead unit: " .. (unitLostDetails.name or "Name N/A"), "WARNING")
            end
        else
            eventType = (event.id == world.event.S_EVENT_UNIT_LOST) and "UNIT_LOST" or "PLAYER_DEAD"
            Log(eventType .. ": Event for unknown unit, or unit already destroyed/invalid.", "DEBUG")
        end
        
    else
        -- Log other events if needed for debugging, then ignore for stats
        Log("StatsEventHandler: Ignoring event ID: " .. tostring(event.id) .. " (Time: " .. string.format("%.2f", event.time) .. ") for detailed stat processing.", "DEBUG")
        return -- Not an event we are tracking for stats
    end
    
    Log("StatsEventHandler: Finished processing Event Type: " .. eventType .. " for stats. (Time: " .. string.format("%.2f", event.time) .. ")", "DEBUG")
end

Log("StatsEventHandler function defined and statistic recording logic integrated.", "INFO")

-- Attempt to register the main StatsEventHandler with MIST or the native world event system.
if mist and mist.addEventHandler then
   mist.addEventHandler(StatsEventHandler)
   Log("StatsEventHandler registered with MIST.", "INFO")
elseif world and world.addEventHandler then -- Fallback if MIST's handler is not used/available
   world.addEventHandler(StatsEventHandler)
   Log("StatsEventHandler registered with world.addEventHandler (native DCS).", "INFO")
else
   Log("Neither MIST nor world.addEventHandler available for StatsEventHandler registration. Statistics will NOT be recorded.", "ERROR")
end

--[[
    Data Persistence
    This section implements saving the collected statistics to a file, both periodically
    and at the end of the mission.
]]

local periodicSaveScheduleId = nil -- Stores the ID for the MIST scheduled function, for potential removal.

-- Saves the current pilotStats and formationStats tables to a human-readable text file.
function SaveStatsToFile()
    Log("Attempting to save statistics to CombatStats_Summary.txt...", "INFO")
    local statsData = "-- Combat Statistics Summary --
-- Timestamp: " .. os.date("[%Y-%m-%d %H:%M:%S]") .. "
-- Script: StatsLogger.lua
-- Format: Lua-like text, human-readable.

-- Pilot Statistics --
"
    
    for pilotKey, stats in pairs(pilotStats) do
        statsData = statsData .. "Pilot: " .. tostring(stats.name) .. " (ID: " .. tostring(pilotKey) .. ", UCID: " .. tostring(stats.ucid) .. ")
"
        statsData = statsData .. string.format("  A2A Kills: %d, A2G Kills: %d
", stats.A2A_kills or 0, stats.A2G_kills or 0)
        statsData = statsData .. string.format("  A2A Hits:  %d, A2G Hits:  %d
", stats.A2A_hits or 0, stats.A2G_hits or 0)
        statsData = statsData .. string.format("  A2A Shots: %d, A2G Shots: %d
", stats.A2A_shots or 0, stats.A2G_shots or 0)
        statsData = statsData .. string.format("  Deaths: %d
", stats.deaths or 0)
        statsData = statsData .. string.format("  Friendly Fire Kills: %d, Friendly Fire Hits: %d
", stats.friendly_fire_kills or 0, stats.friendly_fire_hits or 0)
        
        if stats.weaponStats and next(stats.weaponStats) then -- Check if weaponStats table exists and is not empty
            statsData = statsData .. "  Weapon Stats:
"
            for weapon, wStats in pairs(stats.weaponStats) do
                statsData = statsData .. string.format("    %s: Shots=%d, Hits=%d, Kills=%d
", tostring(weapon), wStats.shots or 0, wStats.hits or 0, wStats.kills or 0)
            end
        else
            statsData = statsData .. "  Weapon Stats: None recorded.
"
        end
        statsData = statsData .. "
" -- Extra newline for readability between pilots
    end

    statsData = statsData .. "
-- Formation Statistics --
"
    if not next(formationStats) then -- Check if formationStats is empty
        statsData = statsData .. "No formation statistics recorded.
"
    else
        for formationName, stats in pairs(formationStats) do
            statsData = statsData .. "Formation: " .. tostring(formationName) .. "
"
            statsData = statsData .. string.format("  A2A Kills: %d, A2G Kills: %d
", stats.A2A_kills or 0, stats.A2G_kills or 0)
            statsData = statsData .. string.format("  A2A Hits:  %d, A2G Hits:  %d
", stats.A2A_hits or 0, stats.A2G_hits or 0)
            statsData = statsData .. string.format("  A2A Shots: %d, A2G Shots: %d
", stats.A2A_shots or 0, stats.A2G_shots or 0)
            statsData = statsData .. string.format("  Deaths (members): %d
", stats.deaths or 0)
            statsData = statsData .. string.format("  Friendly Fire Kills (by members): %d, Friendly Fire Hits (by members): %d
", stats.friendly_fire_kills or 0, stats.friendly_fire_hits or 0)
            statsData = statsData .. "
" -- Extra newline for readability between formations
        end
    end
    statsData = statsData .. "
-- End of Statistics --"

    local filePath = lfs.writedir() .. [[Logs\CombatStats_Summary.txt]]
    local file, err = io.open(filePath, "w") -- Open in "w" mode to overwrite with the latest stats
    if file then
        file:write(statsData)
        file:close()
        Log("Statistics saved successfully to " .. filePath, "INFO")
    else
        Log("Error saving statistics to file '" .. filePath .. "': " .. tostring(err), "ERROR")
    end
end

-- Schedule periodic saving if MIST and its scheduleFunction are available.
if mist and mist.scheduleFunction then
    local argsToPass = {} -- No arguments needed for SaveStatsToFile
    local initialDelay = 300 -- seconds (5 minutes)
    local repeatInterval = 300 -- seconds (5 minutes)

    -- Using pcall for safety, though mist.scheduleFunction itself is usually robust.
    local success_schedule, returned_scheduleId_or_err = pcall(mist.scheduleFunction, nil, {SaveStatsToFile}, argsToPass, initialDelay, repeatInterval)
    if success_schedule and returned_scheduleId_or_err then
        periodicSaveScheduleId = returned_scheduleId_or_err
        Log("Scheduled periodic saving of statistics every " .. repeatInterval .. " seconds. Schedule ID: " .. tostring(periodicSaveScheduleId), "INFO")
    else
        Log("Failed to schedule periodic saving of statistics. Error or nil scheduleId: " .. tostring(returned_scheduleId_or_err) .. ". Stats may only save on mission end.", "ERROR")
    end
else
    Log("MIST or mist.scheduleFunction not available. Statistics will not be saved periodically by this script. Will attempt save on mission end.", "WARNING")
end

-- Handles the S_EVENT_MISSION_END to save stats one last time.
local function MissionEndSaveHandler(event)
    -- Defensive check for event and event.id, though MIST usually provides valid event objects.
    if event and event.id and event.id == world.event.S_EVENT_MISSION_END then
        Log("S_EVENT_MISSION_END received. Saving final statistics before mission exit.", "INFO")
        SaveStatsToFile() -- Perform the final save.
        
        -- Attempt to unschedule the periodic save to clean up, if it was scheduled.
        if periodicSaveScheduleId and mist and mist.removeFunction then
            local unscheduleSuccess, err_remove = pcall(mist.removeFunction, periodicSaveScheduleId)
            if unscheduleSuccess then
                Log("Unscheduled periodic stats saving (ID: " .. tostring(periodicSaveScheduleId) .. ") due to mission end.", "INFO")
            else
                Log("Failed to unschedule periodic stats saving (ID: " .. tostring(periodicSaveScheduleId) .. ") on mission end. Error: " .. tostring(err_remove), "ERROR")
            end
        elseif periodicSaveScheduleId then
             Log("Could not unschedule periodic stats saving (ID: " .. tostring(periodicSaveScheduleId) .. ") because MIST or mist.removeFunction is not available at mission end.", "WARNING")
        end
    end
end

-- Register the mission end handler.
-- Check if world.event and the specific event S_EVENT_MISSION_END are available.
if world and world.event and world.event.S_EVENT_MISSION_END then 
    if mist and mist.addEventHandler then
       mist.addEventHandler(MissionEndSaveHandler)
       Log("MissionEndSaveHandler registered with MIST to save stats on mission end.", "INFO")
    elseif world and world.addEventHandler then -- Fallback to native DCS event handling if MIST is not used for this
       world.addEventHandler(MissionEndSaveHandler)
       Log("MissionEndSaveHandler registered with world.addEventHandler (native DCS).", "INFO")
    else
       Log("Cannot register MissionEndSaveHandler (no suitable event handler found). Final stats save on mission end might not occur automatically via this handler.", "WARNING")
    end
else
    Log("world.event.S_EVENT_MISSION_END constant is not available in this DCS environment. Cannot register MissionEndSaveHandler.", "ERROR")
end

Log("StatsLogger.lua processing complete. Event handlers registered if possible. Monitoring for combat events.", "INFO")
-- End of StatsLogger.lua script
