--[[
    StatsLogger.lua
    Version: 1.2.0 (XML Statistics Summary Output)

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
    - Debug Log: Creates a detailed operational log. If MIST is unavailable, this log
      is at `Logs\StatsLogger_Debug.xml` within the `lfs.writedir()` path 
      (typically %USERPROFILE%\Saved Games\DCS\). This log tracks script initialization, 
      event processing, errors, etc., with each entry as an XML fragment.
      If MIST is available, logging uses `mist.utils.log` which has its own format and destination.
    - Statistics Summary: Generates an XML summary of all collected statistics
      at `Logs\CombatStats_Summary.xml` (also in `lfs.writedir()\Logs\`). This file is
      overwritten periodically and upon mission end.

    Key Features:
    - Tracks individual pilot statistics (keyed by UCID if available, otherwise by pilot name).
    - Tracks aggregate statistics for formations/groups.
    - Records weapon-specific statistics for pilots (shots, hits, kills per weapon type).
    - Distinguishes between A2A and A2G engagements.
    - Includes basic friendly fire detection (based on coalition allegiance).
    - Handles various combat events: SHOT, HIT, KILL, UNIT_LOST, PLAYER_DEAD.
    - Data persistence: Saves statistics periodically and at the end of the mission to an XML file.
    - Centralized logging. Fallback log (if MIST is not used) is in XML fragment format.
--]]

-- Attempt to load MIST.
-- lfs.writedir() typically points to %USERPROFILE%\Saved Games\DCS (or DCS.openbeta)
local mist_search_paths = {
    lfs.writedir() .. [[Scripts\mist.lua]],
    lfs.writedir() .. [[Scripts\MIST\mist.lua]], 
    lfs.writedir() .. [[Scripts\mist-4.5.110.lua]], 
    lfs.writedir() .. [[Scripts\mist-4.3.74.lua]] 
}
local mist_loaded_successfully = false
local mist_load_err = "MIST not found in any specified path."

for _, path in ipairs(mist_search_paths) do
    local success, err = pcall(function() dofile(path) end)
    if success then
        mist_loaded_successfully = true
        mist_load_err = nil 
        break 
    else
        mist_load_err = err 
    end
end

-- Helper function to escape special XML characters
local function escapeXmlChars(str)
    if type(str) ~= "string" then
        str = tostring(str or "") -- Ensure it's a string, handle nil
    end
    str = string.gsub(str, "&", "&amp;")
    str = string.gsub(str, "<", "&lt;")
    str = string.gsub(str, ">", "&gt;")
    str = string.gsub(str, "\"", "&quot;")
    str = string.gsub(str, "'", "&apos;")
    return str
end

-- Centralized Log function
local debugLogPath = lfs.writedir() .. [[Logs\StatsLogger_Debug.xml]] 

local function Log(message, level)
    local logLevel = level or "INFO" 
    
    if mist and mist.utils and mist.utils.log then
        mist.utils.log("StatsLogger: " .. message, logLevel) 
    else
        local escapedMessage = escapeXmlChars(message) 
        local escapedLevel = escapeXmlChars(logLevel)   
        local isoTimestamp = os.date("!%Y-%m-%dT%H:%M:%SZ") 
        
        local xmlEntry = string.format("<logEntry timestamp=\"%s\" level=\"%s\" message=\"%s\" />\n", 
                                       isoTimestamp, 
                                       escapedLevel, 
                                       escapedMessage)
        
        local file, err_io = io.open(debugLogPath, "a")
        if file then
            file:write(xmlEntry)
            file:close()
        else
            print(os.date("[%Y-%m-%d %H:%M:%S]") .. " StatsLogger XML Fallback Log Error: Failed to open log file '" .. debugLogPath .. "': " .. tostring(err_io) .. 
                  " | Original Message (" .. logLevel .. "): " .. message)
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
    print(os.date("[%Y-%m-%d %H:%M:%S]") .. " " .. error_message) 
end

-- Initialize main statistics tables
pilotStats = pilotStats or {}       
formationStats = formationStats or {} 

Log("StatsLogger.lua initialized. pilotStats and formationStats tables prepared.", "INFO")


--[[
    Data Access Helper Functions
]]
function getUnitDetails(unitObject)
    if not unitObject or not unitObject:isExist() then
        Log("getUnitDetails: called with invalid or non-existent unitObject.", "WARNING")
        return nil 
    end

    local unitId = unitObject:getID()
    local details = {
        name = "UnknownName_ID_" .. tostring(unitId), 
        typeName = "UnknownType",
        groupName = "UnknownGroup",
        category = "UnknownCategory", 
        isPlayer = false,
        coalition = "UnknownCoalition",
        ucid = "N/A_UCID", 
        id = unitId 
    }

    details.typeName = unitObject:getTypeName() or details.typeName
    
    local coalitionId = unitObject:getCoalition()
    if coalitionId == 0 then details.coalition = "Neutral"
    elseif coalitionId == 1 then details.coalition = "Red"
    elseif coalitionId == 2 then details.coalition = "Blue"
    else details.coalition = "OtherCoalition-" .. tostring(coalitionId) 
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
            
            if mist and mist.DBs then
                local foundUcidViaMist = false
                local mistPlayerName = nil
                
                if mist.DBs.unitsById and mist.DBs.unitsById[unitId] and mist.DBs.unitsById[unitId].player then
                    local mistUnitPlayerData = mist.DBs.unitsById[unitId].player
                    if mistUnitPlayerData.ucid and mistUnitPlayerData.ucid ~= "" then
                        details.ucid = mistUnitPlayerData.ucid
                        mistPlayerName = mistUnitPlayerData.name
                        foundUcidViaMist = true
                        Log("getUnitDetails: UCID '" .. details.ucid .. "' and MIST name '" .. (mistPlayerName or "N/A") .. "' found for unit ID " .. unitId .. " via mist.DBs.unitsById.", "DEBUG")
                    end
                end

                if not foundUcidViaMist and mist.DBs.playersByUnitName and mist.DBs.playersByUnitName[unitNameInME] then
                    local mistPBUData = mist.DBs.playersByUnitName[unitNameInME]
                    if mistPBUData.ucid and mistPBUData.ucid ~= "" then
                        details.ucid = mistPBUData.ucid
                        mistPlayerName = mistPBUData.name
                        foundUcidViaMist = true
                        Log("getUnitDetails: UCID '" .. details.ucid .. "' and MIST name '" .. (mistPlayerName or "N/A") .. "' found for ME name '"..unitNameInME.."' via mist.DBs.playersByUnitName.", "DEBUG")
                    end
                end
                
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
            details.category = "Static/Other" 
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
    if details.name == "" then details.name = "EmptyWeaponName_Resolved" end
    if details.typeName == "" then details.typeName = "EmptyWeaponTypeName_Resolved" end

    Log("getWeaponDetails: Weapon: Name='" .. details.name .. "', TypeName='" .. details.typeName .. "'.", "DEBUG")
    return details
end

Log("Data Access Helper Functions (getUnitDetails, getWeaponDetails) defined/refined.", "INFO")

--[[
    Statistic Recording Logic
]]
function ensurePilotStats(ucid_param, pilotName_param)
    local keyToUse = nil
    local currentPilotName = pilotName_param or "UnknownPilotName_Ensure" 
    local currentPilotUCID = ucid_param

    if currentPilotName == "" or currentPilotName:match("UnknownName_ID_") then 
        currentPilotName = "InvalidNameInEnsure_" .. (currentPilotUCID or "NoUCID")
    end
    if currentPilotUCID == "" then currentPilotUCID = nil end 

    if currentPilotUCID and currentPilotUCID ~= "N/A_UCID" and currentPilotUCID ~= "Unknown" then
        keyToUse = currentPilotUCID
    elseif currentPilotName and currentPilotName ~= "UnknownPilotName_Ensure" and not currentPilotName:match("InvalidNameInEnsure_") then
        keyToUse = currentPilotName 
        Log("ensurePilotStats: Using pilotName '" .. currentPilotName .. "' as key due to invalid or missing UCID ('" .. tostring(currentPilotUCID) .. "').", "WARNING")
    else
        local tempKeySuffix = (currentPilotUCID or "NoUCIDProvided") .. "_" .. (currentPilotName or "NoNameProvided")
        local tempKey = "ErrorStatsKey_" .. string.gsub(tempKeySuffix, "[^%w_]", "") .. "_" .. os.time() .. "_" .. math.random(1000)
        Log("ensurePilotStats: Critical: Cannot determine valid key from UCID ('" .. tostring(currentPilotUCID) .. "') and pilotName ('" .. tostring(currentPilotName) .. "'). Using temporary key: " .. tempKey, "ERROR")
        keyToUse = tempKey
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
            weaponStats = {} 
        }
        Log("Initialized stats for pilot key: '" .. keyToUse .. "' (Stored Name: '" .. pilotStats[keyToUse].name .. "', Stored UCID: '" .. pilotStats[keyToUse].ucid .. "')", "INFO")
    else
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
    return keyToUse 
end

local function ensureFormationStats(formationName_param)
    local formationName = formationName_param
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
            deaths = 0, 
            friendly_fire_kills = 0, 
            friendly_fire_hits = 0   
        }
        Log("Initialized stats for formation: '" .. formationName .. "'", "INFO")
    end
    return formationName
end

local function updatePilotWeaponStats(pilotKey, weaponTypeName_param, statType) 
    local weaponTypeName = weaponTypeName_param
    if not pilotKey or not pilotStats[pilotKey] then
        Log("updatePilotWeaponStats: Invalid pilotKey '" .. tostring(pilotKey) .. "'. Cannot update weapon stats.", "WARNING")
        return
    end
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
]]
function StatsEventHandler(event)
    if not event or not event.id then
        Log("StatsEventHandler: Received an invalid event object (nil or no ID).", "WARNING")
        return
    end

    Log("StatsEventHandler: Event received: ID = " .. tostring(event.id) .. ", Time = " .. string.format("%.2f", event.time), "DEBUG")

    local initiatorDetails = nil
    local targetDetails = nil
    local weaponDetails = nil 
    local eventType = "UnknownEvent" 
    local interactionType = "N/A" 
    local isFriendlyFire = false

    if event.initiator then
        local objToDetail = event.initiator.object_ or event.initiator 
        if objToDetail and objToDetail.isExist and objToDetail:isExist() then
            initiatorDetails = getUnitDetails(objToDetail)
        else
            Log("StatsEventHandler: Event " .. event.id .. ": Initiator object ("..tostring(event.initiator)..") does not exist or is invalid.", "DEBUG")
        end
    end

    if event.target then
        local objToDetail = event.target.object_ or event.target
        if objToDetail and objToDetail.isExist and objToDetail:isExist() then
            targetDetails = getUnitDetails(objToDetail)
        else
             Log("StatsEventHandler: Event " .. event.id .. ": Target object ("..tostring(event.target)..") does not exist or is invalid.", "DEBUG")
        end
    end
    
    if event.weapon then
        local objToDetail = event.weapon.object_ or event.weapon
        if objToDetail and objToDetail.isExist and objToDetail:isExist() then
            weaponDetails = getWeaponDetails(objToDetail)
        else
             Log("StatsEventHandler: Event " .. event.id .. ": Weapon object ("..tostring(event.weapon)..") does not exist or is invalid.", "DEBUG")
        end
    end
    weaponDetails = weaponDetails or { name = "UnknownWeapon_NotAvailableInEvent", typeName = "UnknownWeaponType_NotAvailableInEvent" }

    if initiatorDetails and targetDetails then
        if initiatorDetails.category == "Air" and targetDetails.category == "Air" then
            interactionType = "A2A"
        elseif initiatorDetails.category == "Air" and (targetDetails.category == "Ground" or targetDetails.category == "Naval") then
            interactionType = "A2G"
        elseif (initiatorDetails.category == "Ground" or initiatorDetails.category == "Naval") and targetDetails.category == "Air" then
            interactionType = "G2A" 
        else
            interactionType = "Other" 
        end
        
        if initiatorDetails.coalition ~= "UnknownCoalition" and targetDetails.coalition ~= "UnknownCoalition" and 
           initiatorDetails.coalition == targetDetails.coalition and 
           initiatorDetails.coalition ~= "Neutral" and 
           initiatorDetails.id ~= targetDetails.id then 
                 isFriendlyFire = true
                 Log("StatsEventHandler: Friendly fire detected: Initiator " .. initiatorDetails.name .. " (Coal: " .. initiatorDetails.coalition .. ") vs Target " .. targetDetails.name .. " (Coal: " .. targetDetails.coalition .. ")", "INFO")
        end
    end
    
    if initiatorDetails then
        Log("StatsEventHandler: Initiator: " .. initiatorDetails.name .. " (UCID: " .. initiatorDetails.ucid .. ", Cat: " .. initiatorDetails.category .. ", Group: " .. initiatorDetails.groupName .. ", Player: " .. tostring(initiatorDetails.isPlayer) .. ", Coal: " .. initiatorDetails.coalition .. ")", "DEBUG")
    end
    if targetDetails then
        Log("StatsEventHandler: Target: " .. targetDetails.name .. " (UCID: " .. targetDetails.ucid .. ", Cat: " .. targetDetails.category .. ", Group: " .. targetDetails.groupName .. ", Player: " .. tostring(targetDetails.isPlayer) .. ", Coal: " .. targetDetails.coalition .. ")", "DEBUG")
    end
    Log("StatsEventHandler: Weapon: " .. weaponDetails.name .. " (Type: " .. weaponDetails.typeName .. ")", "DEBUG")
    Log("StatsEventHandler: Interaction Type: " .. interactionType .. ", Friendly Fire: " .. tostring(isFriendlyFire), "DEBUG")

    if event.id == world.event.S_EVENT_SHOT then
        eventType = "SHOT"
        if initiatorDetails then
            local pilotKey = ensurePilotStats(initiatorDetails.ucid, initiatorDetails.name)
            local formationKey = ensureFormationStats(initiatorDetails.groupName)
            if pilotKey and formationKey then 
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
                else 
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
        if initiatorDetails and targetDetails then 
            local initiatorPilotKey = ensurePilotStats(initiatorDetails.ucid, initiatorDetails.name)
            local initiatorFormationKey = ensureFormationStats(initiatorDetails.groupName)
            local targetPilotKey = ensurePilotStats(targetDetails.ucid, targetDetails.name) 
            local targetFormationKey = ensureFormationStats(targetDetails.groupName)
            
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
            
            if targetPilotKey and targetFormationKey then 
                pilotStats[targetPilotKey].deaths = (pilotStats[targetPilotKey].deaths or 0) + 1
                formationStats[targetFormationKey].deaths = (formationStats[targetFormationKey].deaths or 0) + 1
            else Log(eventType .. ": Failed to get valid pilot/formation key for KILLED target: " .. (targetDetails.name or "Name N/A"), "WARNING")
            end

            Log(eventType .. ": " .. (initiatorDetails.name or "Unknown Initiator") .. " killed " .. targetDetails.name .. " (" .. interactionType .. ") FF: " .. tostring(isFriendlyFire) .. " Weapon: "..weaponDetails.typeName, "INFO")
        
        elseif not initiatorDetails and targetDetails then 
            local targetPilotKey = ensurePilotStats(targetDetails.ucid, targetDetails.name)
            local targetFormationKey = ensureFormationStats(targetDetails.groupName)
            if targetPilotKey and targetFormationKey then
                pilotStats[targetPilotKey].deaths = (pilotStats[targetPilotKey].deaths or 0) + 1
                formationStats[targetFormationKey].deaths = (formationStats[targetFormationKey].deaths or 0) + 1
                Log(eventType .. ": " .. targetDetails.name .. " died (no specific unit initiator - e.g. crash, terrain impact, world object)", "INFO")
            else Log(eventType .. ": Failed to get valid pilot/formation key for KILLED (by environment) target: " .. (targetDetails.name or "Name N/A"), "WARNING")
            end
        else 
             Log(eventType .. ": Received with insufficient initiator/target details for full processing. Initiator: " .. tostring(initiatorDetails) .. ", Target: " .. tostring(targetDetails), "WARNING")
        end

    elseif event.id == world.event.S_EVENT_UNIT_LOST or event.id == world.event.S_EVENT_PLAYER_DEAD then
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
        Log("StatsEventHandler: Ignoring event ID: " .. tostring(event.id) .. " (Time: " .. string.format("%.2f", event.time) .. ") for detailed stat processing.", "DEBUG")
        return 
    end
    
    Log("StatsEventHandler: Finished processing Event Type: " .. eventType .. " for stats. (Time: " .. string.format("%.2f", event.time) .. ")", "DEBUG")
end

Log("StatsEventHandler function defined and statistic recording logic integrated.", "INFO")

if mist and mist.addEventHandler then
   mist.addEventHandler(StatsEventHandler)
   Log("StatsEventHandler registered with MIST.", "INFO")
elseif world and world.addEventHandler then 
   world.addEventHandler(StatsEventHandler)
   Log("StatsEventHandler registered with world.addEventHandler (native DCS).", "INFO")
else
   Log("Neither MIST nor world.addEventHandler available for StatsEventHandler registration. Statistics will NOT be recorded.", "ERROR")
end

--[[
    Data Persistence
    This section implements saving the collected statistics to a file.
]]

local periodicSaveScheduleId = nil 

-- Saves the current pilotStats and formationStats tables to an XML formatted file.
function SaveStatsToFile()
    Log("Attempting to save statistics to CombatStats_Summary.xml...", "INFO")
    
    local isoTimestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local statsData = {} -- Use a table to build lines for better performance and readability
    
    table.insert(statsData, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
    table.insert(statsData, string.format("<CombatStatistics timestamp=\"%s\">\n", isoTimestamp))

    -- Pilot Statistics
    table.insert(statsData, "  <PilotStats>\n")
    if not next(pilotStats) then
        table.insert(statsData, "    <!-- No pilot statistics recorded -->\n")
    else
        for pilotKey, stats in pairs(pilotStats) do
            local pilotNameEscaped = escapeXmlChars(stats.name or "Unknown Name")
            local pilotUcidEscaped = escapeXmlChars(stats.ucid or "N/A")
            local pilotKeyEscaped = escapeXmlChars(pilotKey)

            table.insert(statsData, string.format("    <Pilot id=\"%s\" name=\"%s\" ucid=\"%s\">\n", pilotKeyEscaped, pilotNameEscaped, pilotUcidEscaped))
            table.insert(statsData, string.format("      <A2AKills>%d</A2AKills>\n", stats.A2A_kills or 0))
            table.insert(statsData, string.format("      <A2GKills>%d</A2GKills>\n", stats.A2G_kills or 0))
            table.insert(statsData, string.format("      <A2AHits>%d</A2AHits>\n", stats.A2A_hits or 0))
            table.insert(statsData, string.format("      <A2GHits>%d</A2GHits>\n", stats.A2G_hits or 0))
            table.insert(statsData, string.format("      <A2AShots>%d</A2AShots>\n", stats.A2A_shots or 0))
            table.insert(statsData, string.format("      <A2GShots>%d</A2GShots>\n", stats.A2G_shots or 0))
            table.insert(statsData, string.format("      <Deaths>%d</Deaths>\n", stats.deaths or 0))
            table.insert(statsData, string.format("      <FriendlyKills>%d</FriendlyKills>\n", stats.friendly_fire_kills or 0))
            table.insert(statsData, string.format("      <FriendlyHits>%d</FriendlyHits>\n", stats.friendly_fire_hits or 0))
            
            if stats.weaponStats and next(stats.weaponStats) then
                table.insert(statsData, "      <WeaponStats>\n")
                for weaponTypeName, wStats in pairs(stats.weaponStats) do
                    local weaponTypeEscaped = escapeXmlChars(weaponTypeName)
                    table.insert(statsData, string.format("        <Weapon type=\"%s\">\n", weaponTypeEscaped))
                    table.insert(statsData, string.format("          <Shots>%d</Shots>\n", wStats.shots or 0))
                    table.insert(statsData, string.format("          <Hits>%d</Hits>\n", wStats.hits or 0))
                    table.insert(statsData, string.format("          <Kills>%d</Kills>\n", wStats.kills or 0))
                    table.insert(statsData, "        </Weapon>\n")
                end
                table.insert(statsData, "      </WeaponStats>\n")
            else
                table.insert(statsData, "      <WeaponStats />\n") -- Empty element if no weapon stats
            end
            table.insert(statsData, "    </Pilot>\n")
        end
    end
    table.insert(statsData, "  </PilotStats>\n")

    -- Formation Statistics
    table.insert(statsData, "  <FormationStats>\n")
    if not next(formationStats) then
        table.insert(statsData, "    <!-- No formation statistics recorded -->\n")
    else
        for formationName, stats in pairs(formationStats) do
            local formationNameEscaped = escapeXmlChars(formationName)
            table.insert(statsData, string.format("    <Formation name=\"%s\">\n", formationNameEscaped))
            table.insert(statsData, string.format("      <A2AKills>%d</A2AKills>\n", stats.A2A_kills or 0))
            table.insert(statsData, string.format("      <A2GKills>%d</A2GKills>\n", stats.A2G_kills or 0))
            table.insert(statsData, string.format("      <A2AHits>%d</A2AHits>\n", stats.A2A_hits or 0))
            table.insert(statsData, string.format("      <A2GHits>%d</A2GHits>\n", stats.A2G_hits or 0))
            table.insert(statsData, string.format("      <A2AShots>%d</A2AShots>\n", stats.A2A_shots or 0))
            table.insert(statsData, string.format("      <A2GShots>%d</A2GShots>\n", stats.A2G_shots or 0))
            table.insert(statsData, string.format("      <MemberDeaths>%d</MemberDeaths>\n", stats.deaths or 0)) -- Renamed for clarity
            table.insert(statsData, string.format("      <FriendlyKillsByMembers>%d</FriendlyKillsByMembers>\n", stats.friendly_fire_kills or 0))
            table.insert(statsData, string.format("      <FriendlyHitsByMembers>%d</FriendlyHitsByMembers>\n", stats.friendly_fire_hits or 0))
            table.insert(statsData, "    </Formation>\n")
        end
    end
    table.insert(statsData, "  </FormationStats>\n")
    
    table.insert(statsData, "</CombatStatistics>\n")

    local finalXmlData = table.concat(statsData)
    local filePath = lfs.writedir() .. [[Logs\CombatStats_Summary.xml]] -- Changed file extension
    
    local file, err = io.open(filePath, "w") 
    if file then
        file:write(finalXmlData)
        file:close()
        Log("Statistics XML summary saved successfully to " .. filePath, "INFO")
    else
        Log("Error saving statistics XML summary to file '" .. filePath .. "': " .. tostring(err), "ERROR")
    end
end

Log("Data persistence logic (SaveStatsToFile) updated for XML output.", "INFO")


if mist and mist.scheduleFunction then
    local argsToPass = {} 
    local initialDelay = 300 
    local repeatInterval = 300 

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

local function MissionEndSaveHandler(event)
    if event and event.id and event.id == world.event.S_EVENT_MISSION_END then
        Log("S_EVENT_MISSION_END received. Saving final statistics before mission exit.", "INFO")
        SaveStatsToFile() 
        
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

if world and world.event and world.event.S_EVENT_MISSION_END then 
    if mist and mist.addEventHandler then
       mist.addEventHandler(MissionEndSaveHandler)
       Log("MissionEndSaveHandler registered with MIST to save stats on mission end.", "INFO")
    elseif world and world.addEventHandler then 
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
