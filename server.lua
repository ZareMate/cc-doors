local VERSION = "v2.7"

local USERS_FILE = "/disk/users"
local USER_STATES_FILE = "/disk/user_states"
local USER_DISKS_FILE = "/disk/user_disks"
local LOG_FILE = "/disk/log"
local SHA256_FILE = "/sha256"

local AUTH_DRIVE_CONFIG_FILE = "/disk/auth_drive_path"
local DEFAULT_AUTH_DISK_DRIVE_PATH = "/disk2"

local urls = {
  {"startup", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/server.lua"},
  {"sha256", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/sha256.lua"},
  {"updater", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/updater.lua"},
}

local LISTENER_ARG = "listener"

local SERVER_ID = os.getComputerID()

--------------------------------------------------
-- Radar / Door Zones
--------------------------------------------------

-- Computer ID of the radar computer.
local RADAR_ID = 214

-- Protocol used by the radar computer.
local RADAR_PROTOCOL = "radar"

-- Protocol used to communicate with door opener computers.
local DOOR_PROTOCOL = "door_control"

-- Door detection zones.
--
-- [Door opener computer ID] = {
--     x1, y1, z1,
--     x2, y2, z2
-- }
--
-- The two corners can be in any order.
local doors = {
    [216] = {-1544, 64, 388, -1548, 62, 384},
    [213] = {-1604, 65, 463, -1601, 63, 467},

    -- [103] = {-1400, 60, 300, -1390, 70, 310},
}


local RESERVED_PASSWORD = "admin"

--------------------------------------------------
-- User states
--------------------------------------------------

local USER_STATE_ACTIVE = "active"
local USER_STATE_ADMIN = "admin"
local USER_STATE_INACTIVE = "inactive"
local exit = false

local VALID_USER_STATES = {
    [USER_STATE_ACTIVE] = true,
    [USER_STATE_ADMIN] = true,
    [USER_STATE_INACTIVE] = true
}

local sha256 = dofile(SHA256_FILE)

--------------------------------------------------
-- Disk states
--------------------------------------------------

local DISK_STATE_ACTIVE = "active"
local DISK_STATE_REVOKED = "revoked"

local VALID_DISK_STATES = {
    [DISK_STATE_ACTIVE] = true,
    [DISK_STATE_REVOKED] = true
}

--------------------------------------------------
-- Reserved password
--------------------------------------------------

local function isReservedPassword(password)
    return type(password) == "string"
        and password:lower() == RESERVED_PASSWORD
end

--------------------------------------------------
-- Utility
--------------------------------------------------

local function trim(s)
    if type(s) ~= "string" then
        return ""
    end

    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

local function nowString()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function randomHex(len)
    local chars = "0123456789abcdef"
    local out = {}

    for i = 1, len do
        local idx = math.random(1, #chars)
        out[i] = chars:sub(idx, idx)
    end

    return table.concat(out)
end

local function makeRawDiskId(username)
    local seed = tostring(SERVER_ID)
        .. "|"
        .. tostring(os.epoch and os.epoch("utc") or os.time())
        .. "|"
        .. tostring(math.random(100000, 999999))
        .. "|"
        .. tostring(username or "")
        .. "|"
        .. randomHex(16)

    -- raw ID written to disk
    return sha256(seed) .. randomHex(16)
end

local function ensureTable(value)
    if type(value) == "table" then
        return value
    end

    return {}
end

--------------------------------------------------
-- File functions
--------------------------------------------------

local function loadUsers()
    if not fs.exists(USERS_FILE) then
        return {}
    end

    local file = fs.open(USERS_FILE, "r")

    if not file then
        return {}
    end

    local data = file.readAll()
    file.close()

    if data == "" then
        return {}
    end

    local loaded = textutils.unserialize(data)

    if type(loaded) ~= "table" then
        error("Invalid users file")
    end

    return loaded
end

local function saveUsers(users)
    local file = fs.open(USERS_FILE, "w")

    if not file then
        error("Could not open " .. USERS_FILE)
    end

    file.write(textutils.serialize(users))
    file.close()
end

local function loadUserStates()
    if not fs.exists(USER_STATES_FILE) then
        return {}
    end

    local file = fs.open(USER_STATES_FILE, "r")

    if not file then
        return {}
    end

    local data = file.readAll()
    file.close()

    if data == "" then
        return {}
    end

    local loaded = textutils.unserialize(data)

    if type(loaded) ~= "table" then
        error("Invalid user states file")
    end

    for username, state in pairs(loaded) do
        if type(username) ~= "string"
            or not VALID_USER_STATES[state] then
            error("Invalid user state for " .. tostring(username))
        end
    end

    return loaded
end

local function saveUserStates(states)
    local file = fs.open(USER_STATES_FILE, "w")

    if not file then
        error("Could not open " .. USER_STATES_FILE)
    end

    file.write(textutils.serialize(states))
    file.close()
end

local function loadUserDisks()
    if not fs.exists(USER_DISKS_FILE) then
        return {}
    end

    local file = fs.open(USER_DISKS_FILE, "r")
    if not file then
        return {}
    end

    local data = file.readAll()
    file.close()

    if data == "" then
        return {}
    end

    local loaded = textutils.unserialize(data)
    if type(loaded) ~= "table" then
        error("Invalid user disks file")
    end

    -- normalize
    for username, disks in pairs(loaded) do
        if type(username) ~= "string" then
            loaded[username] = nil
        else
            loaded[username] = ensureTable(disks)

            for i = #loaded[username], 1, -1 do
                local d = loaded[username][i]

                if type(d) ~= "table" then
                    table.remove(loaded[username], i)
                else
                    d.idHash = trim(d.idHash or "")
                    d.label = trim(d.label or "")
                    d.createdAt = trim(d.createdAt or "")
                    d.state = trim(d.state or "")

                    if d.idHash == "" or not VALID_DISK_STATES[d.state] then
                        table.remove(loaded[username], i)
                    end
                end
            end
        end
    end

    return loaded
end

local function saveUserDisks(userDisks)
    local file = fs.open(USER_DISKS_FILE, "w")

    if not file then
        error("Could not open " .. USER_DISKS_FILE)
    end

    file.write(textutils.serialize(userDisks))
    file.close()
end

local function logMessage(message)
    local date = nowString()

    local file = fs.open(LOG_FILE, "a")

    if file then
        file.writeLine("[" .. date .. "] " .. message)
        file.close()
    end

    print("[" .. date .. "] " .. message)
end

local function loadAuthDiskDrivePath()
    if not fs.exists(AUTH_DRIVE_CONFIG_FILE) then
        return DEFAULT_AUTH_DISK_DRIVE_PATH
    end

    local file = fs.open(AUTH_DRIVE_CONFIG_FILE, "r")
    if not file then
        return DEFAULT_AUTH_DISK_DRIVE_PATH
    end

    local path = file.readAll() or ""
    file.close()

    path = trim(path)

    if path == "" then
        return DEFAULT_AUTH_DISK_DRIVE_PATH
    end

    return path
end

local function saveAuthDiskDrivePath(path)
    local file = fs.open(AUTH_DRIVE_CONFIG_FILE, "w")
    if not file then
        return false
    end

    file.write(path)
    file.close()
    return true
end

--------------------------------------------------
-- Synchronize users, states, disks
--------------------------------------------------

local function syncUserStates()
    local users = loadUsers()
    local userStates = loadUserStates()
    local changed = false

    for username in pairs(users) do
        if userStates[username] == nil then
            userStates[username] = USER_STATE_INACTIVE
            changed = true
            logMessage("User state initialized: " .. username .. " -> inactive")
        end
    end

    for username in pairs(userStates) do
        if users[username] == nil then
            userStates[username] = nil
            changed = true
        end
    end

    if changed then
        saveUserStates(userStates)
    end

    return userStates
end

local function syncUserDisks()
    local users = loadUsers()
    local userDisks = loadUserDisks()
    local changed = false

    for username in pairs(users) do
        if type(userDisks[username]) ~= "table" then
            userDisks[username] = {}
            changed = true
        end
    end

    for username in pairs(userDisks) do
        if users[username] == nil then
            userDisks[username] = nil
            changed = true
        end
    end

    if changed then
        saveUserDisks(userDisks)
    end

    return userDisks
end

--------------------------------------------------
-- User state helpers
--------------------------------------------------

local function getUserState(userStates, username)
    local state = userStates[username]

    if VALID_USER_STATES[state] then
        return state
    end

    return USER_STATE_INACTIVE
end

local function isUserActive(userStates, username)
    local state = getUserState(userStates, username)
    return state == USER_STATE_ACTIVE or state == USER_STATE_ADMIN
end

local function isUserAdmin(userStates, username)
    return getUserState(userStates, username) == USER_STATE_ADMIN
end

--------------------------------------------------
-- Disk helpers
--------------------------------------------------

local function getUserDiskList(userDisks, username)
    local list = userDisks[username]

    if type(list) ~= "table" then
        return {}
    end

    return list
end

local function findDiskIndexByHash(userDisks, username, idHash)
    local list = getUserDiskList(userDisks, username)

    for i, d in ipairs(list) do
        if d.idHash == idHash then
            return i
        end
    end

    return nil
end

local function addDiskRecord(username, idHash, label)
    local userDisks = syncUserDisks()

    if type(userDisks[username]) ~= "table" then
        userDisks[username] = {}
    end

    table.insert(userDisks[username], {
        idHash = idHash,
        label = label or ("Access - " .. username),
        createdAt = nowString(),
        state = DISK_STATE_ACTIVE
    })

    saveUserDisks(userDisks)
end

local function setDiskState(username, idHash, state)
    if not VALID_DISK_STATES[state] then
        return false
    end

    local userDisks = syncUserDisks()
    local idx = findDiskIndexByHash(userDisks, username, idHash)

    if not idx then
        return false
    end

    userDisks[username][idx].state = state
    saveUserDisks(userDisks)

    return true
end

local function removeDiskRecord(username, idHash)
    local userDisks = syncUserDisks()
    local idx = findDiskIndexByHash(userDisks, username, idHash)

    if not idx then
        return false
    end

    table.remove(userDisks[username], idx)
    saveUserDisks(userDisks)

    return true
end

local function isDiskAuthorizedForUser(username, diskIdHash)
    local userDisks = syncUserDisks()
    local list = getUserDiskList(userDisks, username)

    for _, d in ipairs(list) do
        if d.idHash == diskIdHash and d.state == DISK_STATE_ACTIVE then
            return true
        end
    end

    return false
end

local function shortHash(h)
    if type(h) ~= "string" then
        return ""
    end

    if #h <= 16 then
        return h
    end

    return h:sub(1, 8) .. "..." .. h:sub(-8)
end

--------------------------------------------------
-- UI
--------------------------------------------------

local function clear()
    term.clear()
    term.setCursorPos(1, 1)
end

--------------------------------------------------
-- Safe keyboard input
--------------------------------------------------

local function waitForKey()
    while true do
        local event, key = os.pullEventRaw()

        if event == "terminate" then
            -- Ignore Ctrl+T
        elseif event == "key" then
            return key
        end
    end
end

--------------------------------------------------
-- User helpers
--------------------------------------------------

local function getUserList(users)
    local list = {}

    for username in pairs(users) do
        table.insert(list, username)
    end

    table.sort(list)

    return list
end

local function getUserByHash(users, hash)
    for username, passwordHash in pairs(users) do
        if passwordHash ~= ""
            and passwordHash == hash then
            return username
        end
    end

    return nil
end

local function hasAdminPassword(users, userStates)
    for username, state in pairs(userStates) do
        if state == USER_STATE_ADMIN
            and users[username]
            and users[username] ~= "" then
            return true
        end
    end

    return false
end

--------------------------------------------------
-- User state display
--------------------------------------------------

local function setUserStateColor(state)
    if state == USER_STATE_ADMIN then
        term.setTextColor(colors.yellow)
    elseif state == USER_STATE_ACTIVE then
        term.setTextColor(colors.green)
    elseif state == USER_STATE_INACTIVE then
        term.setTextColor(colors.red)
    else
        term.setTextColor(colors.white)
    end
end

local function printUserState(username, state, selected)
    if selected then
        term.setTextColor(colors.white)
        write("> ")
    else
        term.setTextColor(colors.white)
        write("  ")
    end

    setUserStateColor(state)
    print(username .. " - " .. string.upper(state))
    term.setTextColor(colors.white)
end

--------------------------------------------------
-- Auth disk helpers
--------------------------------------------------

local function getAuthDiskInfo()
    local authDrivePath = loadAuthDiskDrivePath()

    if not fs.exists(authDrivePath) then
        return nil, "Auth drive path not found: " .. authDrivePath
    end

    return {
        mountPath = authDrivePath,
        drivePath = authDrivePath
    }, nil
end

local function writeAuthDiskForUser(username)
    local users = loadUsers()
    local userHash = users[username]

    clear()
    print("Add Disk")
    print("--------")
    print("")
    print("User: " .. username)
    print("")

    if not userHash or userHash == "" then
        print("User has no password hash.")
        print("Cannot create auth disk.")
        sleep(2)
        return
    end

    local info, err = getAuthDiskInfo()
    if not info then
        print(err)
        sleep(2)
        return
    end

    local diskLogPath = fs.combine(info.mountPath, "log")
    if fs.exists(diskLogPath) then
        print("ABORTED: Selected disk looks like main data disk.")
        print("Found log file: " .. diskLogPath)
        print("Auth disk was not modified.")
        logMessage("AUTH DISK ABORTED - log file detected on " .. info.mountPath)
        sleep(3)
        return
    end

    local rawDiskId = makeRawDiskId(username)
    local diskIdHash = sha256(rawDiskId)

    local hashPath = fs.combine(info.mountPath, "hash")
    local idPath = fs.combine(info.mountPath, "disk_id")

    local fHash = fs.open(hashPath, "w")
    if not fHash then
        print("Failed to write hash file.")
        sleep(2)
        return
    end
    fHash.write(userHash)
    fHash.close()

    local fId = fs.open(idPath, "w")
    if not fId then
        print("Failed to write disk ID file.")
        sleep(2)
        return
    end
    fId.write(rawDiskId)
    fId.close()

    local label = "Access - " .. username
    pcall(function()
        disk.setLabel("left", label)
    end)

    addDiskRecord(username, diskIdHash, label)

    print("Auth disk written successfully.")
    print("Label: " .. label)
    print("Drive path: " .. info.drivePath)
    print("Path hash: " .. hashPath)
    print("Path id: " .. idPath)
    print("Disk ID hash: " .. shortHash(diskIdHash))

    logMessage("AUTH DISK CREATED - " .. username .. " id=" .. shortHash(diskIdHash) .. " on " .. info.mountPath)

    sleep(2)
end

local function setAuthDrivePathMenu()
    clear()

    local current = loadAuthDiskDrivePath()

    print("Set Auth Drive Path")
    print("-------------------")
    print("")
    print("Current: " .. current)
    print("Default: " .. DEFAULT_AUTH_DISK_DRIVE_PATH)
    print("")
    print("Example: /disk2")
    print("Leave empty to reset to default.")
    print("")
    write("New path: ")

    local input = read()
    local newPath = trim(input)

    if newPath == "" then
        newPath = DEFAULT_AUTH_DISK_DRIVE_PATH
    end

    if newPath:sub(1, 1) ~= "/" then
        print("")
        print("Path must start with '/'.")
        sleep(2)
        return
    end

    if saveAuthDiskDrivePath(newPath) then
        logMessage("AUTH DRIVE PATH SET - " .. newPath)

        print("")
        print("Auth drive path saved.")
        print("Now using: " .. newPath)
        sleep(2)
    else
        print("")
        print("Failed to save auth drive path.")
        sleep(2)
    end
end

--------------------------------------------------
-- Radar / Door handling
--------------------------------------------------

-- Tracks whether a player is currently inside each door zone.
-- radarDoorStates[username][doorID] = true/false
local radarDoorStates = {}

local function isInsideDoorZone(x, y, z, zone)
    local minX = math.min(zone[1], zone[4])
    local minY = math.min(zone[2], zone[5])
    local minZ = math.min(zone[3], zone[6])

    local maxX = math.max(zone[1], zone[4])
    local maxY = math.max(zone[2], zone[5])
    local maxZ = math.max(zone[3], zone[6])

    return x >= minX and x <= maxX
        and y >= minY and y <= maxY
        and z >= minZ and z <= maxZ
end

local function sendRadarDoorRequest(doorID, username, position, timestamp)
    local message = {
        type = "radar_open",
        username = username,

        position = {
            x = position.x,
            y = position.y,
            z = position.z
        },

        timestamp = timestamp
    }

    local sent = rednet.send(
        doorID,
        message,
        DOOR_PROTOCOL
    )

    if sent then
        logMessage(
            "RADAR DOOR REQUEST - "
            .. username
            .. " -> Door Computer "
            .. doorID
            .. " @ "
            .. string.format(
                "%.2f, %.2f, %.2f",
                position.x,
                position.y,
                position.z
            )
        )
    else
        logMessage(
            "RADAR DOOR REQUEST FAILED - "
            .. username
            .. " -> Door Computer "
            .. doorID
        )
    end
end

local function handleRadarData(sender, message)
    -- Only accept radar data from the configured radar computer.
    if sender ~= RADAR_ID then
        logMessage(
            "RADAR DATA REJECTED - Computer "
            .. tostring(sender)
            .. " is not the configured radar computer"
        )
        return
    end

    if type(message) ~= "table"
        or type(message.data) ~= "table" then
        logMessage("RADAR DATA REJECTED - Invalid packet")
        return
    end

    local timestamp = message.timestamp
        or os.epoch("utc")

    -- Keep track of which players were present in this radar update.
    local presentPlayers = {}

    for username, position in pairs(message.data) do
        if type(username) == "string"
            and type(position) == "table"
            and type(position.x) == "number"
            and type(position.y) == "number"
            and type(position.z) == "number" then

            presentPlayers[username] = true

            if type(radarDoorStates[username]) ~= "table" then
                radarDoorStates[username] = {}
            end

            for doorID, zone in pairs(doors) do
                local inside = isInsideDoorZone(
                    position.x,
                    position.y,
                    position.z,
                    zone
                )

                local wasInside =
                    radarDoorStates[username][doorID] == true

                if inside and not wasInside then
                    -- Player has just entered this door's zone.
                    sendRadarDoorRequest(
                        doorID,
                        username,
                        position,
                        timestamp
                    )
                end

                radarDoorStates[username][doorID] = inside
            end
        end
    end

    -- Players no longer reported by the radar are considered
    -- outside all door zones. This allows a new request when
    -- they are detected again and enter a zone.
    for username, states in pairs(radarDoorStates) do
        if not presentPlayers[username] then
            for doorID in pairs(states) do
                states[doorID] = false
            end
        end
    end
end

--------------------------------------------------
-- Authentication listener
--------------------------------------------------

local function handleDoorAuth(sender, message)
    local users = loadUsers()
    local userStates = syncUserStates()

    if type(message) ~= "table"
        or message.type ~= "auth"
        or type(message.hash) ~= "string"
        or (message.disk_id_hash ~= nil and type(message.disk_id_hash) ~= "string") then
        rednet.send(sender, false, "door_auth")
        return
    end

    local username = getUserByHash(users, trim(message.hash))
    local diskIdHash = trim(message.disk_id_hash or "")
    local hasDisk = diskIdHash ~= ""
    local isAuthorized = false

    if username and isUserActive(userStates, username) then
        if hasDisk then
            isAuthorized = isDiskAuthorizedForUser(username, diskIdHash)
        else
            isAuthorized = true
        end
    end

    if isAuthorized then
        rednet.send(sender, true, "door_auth")

        if hasDisk then
            logMessage("ACCESS GRANTED - " .. username .. " (" .. getUserState(userStates, username) .. ", disk=" .. shortHash(diskIdHash) .. ", Computer " .. sender .. ")")
        else
            logMessage("ACCESS GRANTED - " .. username .. " (" .. getUserState(userStates, username) .. ", password, Computer " .. sender .. ")")
        end
    else
        rednet.send(sender, false, "door_auth")

        if username then
            if hasDisk then
                logMessage("ACCESS DENIED - " .. username .. " (" .. getUserState(userStates, username) .. ", disk=" .. shortHash(diskIdHash) .. ", Computer " .. sender .. ")")
            else
                logMessage("ACCESS DENIED - " .. username .. " (" .. getUserState(userStates, username) .. ", password, Computer " .. sender .. ")")
            end
        else
            logMessage("ACCESS DENIED - Computer " .. sender)
        end
    end
end

local function handleAdminAuth(sender, message)
    local users = loadUsers()
    local userStates = syncUserStates()

    if type(message) ~= "table"
        or message.type ~= "admin_auth"
        or type(message.hash) ~= "string" then
        rednet.send(sender, { success = false }, "admin_auth_response")
        return
    end

    local username = getUserByHash(users, message.hash)

    if username and isUserAdmin(userStates, username) then
        rednet.send(sender, { success = true, username = username }, "admin_auth_response")
        logMessage("ADMIN AUTH - " .. username .. " (Computer " .. sender .. ")")
        return
    end

    rednet.send(sender, { success = false }, "admin_auth_response")

    if username then
        logMessage("ADMIN AUTH FAILED - " .. username .. " is " .. getUserState(userStates, username) .. " (Computer " .. sender .. ")")
    else
        logMessage("ADMIN AUTH FAILED - Computer " .. sender)
    end
end

local function authenticationListener()
    rednet.open("bottom")

    while true do
        local event, sender, message, protocol = os.pullEventRaw()

        if event == "terminate" then
            -- Ignore Ctrl+T
        elseif event == "rednet_message" then
            if protocol == "door_auth" then
                handleDoorAuth(sender, message)

            elseif protocol == "admin_auth" then
                handleAdminAuth(sender, message)

            elseif protocol == RADAR_PROTOCOL then
                handleRadarData(sender, message)
            end
        end
    end
end

--------------------------------------------------
-- Admin authentication
--------------------------------------------------

local function readAdminPassword(firstChar)
    local input = firstChar or ""

    clear()
    print("Admin Authentication")
    print("--------------------")
    print("             " .. VERSION)
    print("")
    write("Password: ")

    if firstChar then
        write("*")
    end

    term.setCursorBlink(true)

    while true do
        local event, p1 = os.pullEventRaw()

        if event == "terminate" then
            -- Ignore Ctrl+T
        elseif event == "char" then
            input = input .. p1
            write("*")
        elseif event == "key" then
            if p1 == keys.backspace then
                if #input > 0 then
                    input = input:sub(1, -2)
                    local x, y = term.getCursorPos()
                    term.setCursorPos(x - 1, y)
                    write(" ")
                    term.setCursorPos(x - 1, y)
                end
            elseif p1 == keys.enter then
                term.setCursorBlink(false)
                print("")
                return input
            elseif p1 == keys.esc or p1 == keys.left or p1 == keys.a then
                term.setCursorBlink(false)
                print("")
                return nil
            end
        end
    end
end

local function authenticateAdmin(firstChar)
    local users = loadUsers()
    local userStates = loadUserStates()

    if not hasAdminPassword(users, userStates) then
        clear()
        print("Admin Authentication")
        print("--------------------")
        print("             " .. VERSION)
        print("")
        print("No admin passwords configured.")
        print("Menu unlocked.")
        sleep(1)
        return true
    end

    local password = readAdminPassword(firstChar)
    if password == nil then
        return false
    end

    local hash = sha256(password)

    rednet.send(SERVER_ID, { type = "admin_auth", hash = hash }, "admin_auth")

    print("")
    print("Checking...")

    local timer = os.startTimer(10)

    while true do
        local event, p1, p2, p3 = os.pullEventRaw()

        if event == "terminate" then
            -- Ignore Ctrl+T
        elseif event == "rednet_message" and p1 == SERVER_ID and p3 == "admin_auth_response" then
            os.cancelTimer(timer)

            local response = p2
            if type(response) == "table" and response.success == true then
                print("")
                print("Authenticated as " .. (response.username or "admin"))
                sleep(1)
                return true
            end

            print("")
            print("Invalid admin password.")
            sleep(2)
            return false
        elseif event == "timer" and p1 == timer then
            print("")
            print("Authentication timed out.")
            sleep(2)
            return false
        end
    end
end

--------------------------------------------------
-- User management
--------------------------------------------------

local addUser

local function changeUserPassword(username)
    local users = loadUsers()

    clear()
    print("Change Password")
    print("---------------")
    print("")
    print("User: " .. username)
    print("")
    print("Leave empty to remove password.")
    print("")
    write("New password: ")

    local password = read("*")

    if isReservedPassword(password) then
        print("")
        print("The password 'admin' is reserved.")
        print("Choose another password.")
        sleep(2)
        return
    end

    if password == "" then
        users[username] = ""
    else
        users[username] = sha256(password)
    end

    saveUsers(users)
    logMessage("Password changed: " .. username)

    print("")
    print("Password updated.")
    sleep(2)
end

local function removeSelectedUser(username)
    local users = loadUsers()
    local userStates = loadUserStates()
    local userDisks = loadUserDisks()

    clear()
    print("Remove User")
    print("-----------")
    print("")
    print("User: " .. username)
    print("")
    print("Are you sure?")
    print("")
    print("Enter = Yes")
    print("A/left = No")

    while true do
        local key = waitForKey()

        if key == keys.enter then
            users[username] = nil
            userStates[username] = nil
            userDisks[username] = nil

            saveUsers(users)
            saveUserStates(userStates)
            saveUserDisks(userDisks)

            logMessage("User removed: " .. username)

            print("")
            print("User removed.")
            sleep(2)
            return
        elseif key == keys.a or key == keys.left then
            return
        end
    end
end

local function changeSelectedUserState(username, newState)
    local userStates = loadUserStates()
    userStates[username] = newState
    saveUserStates(userStates)
    logMessage("User state changed: " .. username .. " -> " .. newState)
end

local function getUserActionOptions(state)
    local options = {}

    if state == USER_STATE_ACTIVE then
        table.insert(options, "Deactivate")
    elseif state == USER_STATE_INACTIVE then
        table.insert(options, "Activate")
    end

    if state == USER_STATE_ADMIN then
        table.insert(options, "Admin")
    elseif state == USER_STATE_ACTIVE then
        table.insert(options, "Admin")
    end

    table.insert(options, "Disks")
    table.insert(options, "Remove")
    table.insert(options, "Change password")

    return options
end

local function listUserDisksScreen(username)
    local userDisks = syncUserDisks()
    local list = getUserDiskList(userDisks, username)

    clear()
    print("User Disks")
    print("----------")
    print("")
    print("User: " .. username)
    print("")

    if #list == 0 then
        print("No disks registered.")
        print("")
        print("Press any key...")
        waitForKey()
        return
    end

    for i, d in ipairs(list) do
        local stateColor = colors.white
        if d.state == DISK_STATE_ACTIVE then
            stateColor = colors.green
        elseif d.state == DISK_STATE_REVOKED then
            stateColor = colors.red
        end

        term.setTextColor(colors.white)
        print(i .. ". " .. (d.label or ("Access - " .. username)))

        term.setTextColor(stateColor)
        print("   State: " .. string.upper(d.state))
        term.setTextColor(colors.white)

        print("   ID: " .. shortHash(d.idHash))
        print("   Created: " .. (d.createdAt or "unknown"))
        print("")
    end

    print("Press any key...")
    waitForKey()
end

local function chooseUserDisk(username, title, onlyState)
    local selected = 1

    while true do
        local userDisks = syncUserDisks()
        local all = getUserDiskList(userDisks, username)
        local filtered = {}

        for _, d in ipairs(all) do
            if onlyState == nil or d.state == onlyState then
                table.insert(filtered, d)
            end
        end

        clear()
        print(title)
        print(string.rep("-", #title))
        print("")
        print("User: " .. username)
        print("")

        if #filtered == 0 then
            print("No matching disks.")
            print("")
            print("A/left = Back")
            local k = waitForKey()
            if k == keys.a or k == keys.left or k == keys.enter then
                return nil
            end
        else
            if selected > #filtered then
                selected = #filtered
            end
            if selected < 1 then
                selected = 1
            end

            for i, d in ipairs(filtered) do
                if i == selected then
                    write("> ")
                else
                    write("  ")
                end

                if d.state == DISK_STATE_ACTIVE then
                    term.setTextColor(colors.green)
                else
                    term.setTextColor(colors.red)
                end

                print(shortHash(d.idHash) .. " - " .. string.upper(d.state))
                term.setTextColor(colors.white)
            end

            print("")
            print("W/S or up/down | Enter | A/left")

            local key = waitForKey()

            if key == keys.w or key == keys.up then
                selected = selected - 1
                if selected < 1 then
                    selected = #filtered
                end
            elseif key == keys.s or key == keys.down then
                selected = selected + 1
                if selected > #filtered then
                    selected = 1
                end
            elseif key == keys.enter then
                return filtered[selected]
            elseif key == keys.a or key == keys.left then
                return nil
            end
        end
    end
end

local function revokeDiskMenu(username)
    local diskEntry = chooseUserDisk(username, "Revoke Disk", DISK_STATE_ACTIVE)
    if not diskEntry then
        return
    end

    if setDiskState(username, diskEntry.idHash, DISK_STATE_REVOKED) then
        logMessage("DISK REVOKED - " .. username .. " id=" .. shortHash(diskEntry.idHash))
        clear()
        print("Disk revoked.")
        print("")
        print("ID: " .. shortHash(diskEntry.idHash))
        sleep(2)
    end
end

local function unrevokeDiskMenu(username)
    local diskEntry = chooseUserDisk(username, "Unrevoke Disk", DISK_STATE_REVOKED)
    if not diskEntry then
        return
    end

    if setDiskState(username, diskEntry.idHash, DISK_STATE_ACTIVE) then
        logMessage("DISK UNREVOKED - " .. username .. " id=" .. shortHash(diskEntry.idHash))
        clear()
        print("Disk activated.")
        print("")
        print("ID: " .. shortHash(diskEntry.idHash))
        sleep(2)
    end
end

local function removeDiskMenu(username)
    local diskEntry = chooseUserDisk(username, "Remove Disk Record", nil)
    if not diskEntry then
        return
    end

    clear()
    print("Remove Disk Record")
    print("------------------")
    print("")
    print("User: " .. username)
    print("ID: " .. shortHash(diskEntry.idHash))
    print("")
    print("Enter = Yes")
    print("A/left = No")

    while true do
        local k = waitForKey()
        if k == keys.enter then
            if removeDiskRecord(username, diskEntry.idHash) then
                logMessage("DISK REMOVED - " .. username .. " id=" .. shortHash(diskEntry.idHash))
                print("")
                print("Disk record removed.")
                sleep(2)
            end
            return
        elseif k == keys.a or k == keys.left then
            return
        end
    end
end

local function userDisksMenu(username)
    local options = {
        "Add disk",
        "List disks",
        "Revoke disk",
        "Unrevoke disk",
        "Remove disk record",
        "Back"
    }

    local selected = 1

    while true do
        clear()
        print("================================")
        print("            Disks")
        print("================================")
        print("")
        print("User: " .. username)
        print("")

        for i, option in ipairs(options) do
            if i == selected then
                print("> " .. option)
            else
                print("  " .. option)
            end
        end

        print("")
        print("W/S or up/down | Enter | A/left")

        local key = waitForKey()

        if key == keys.w or key == keys.up then
            selected = selected - 1
            if selected < 1 then
                selected = #options
            end
        elseif key == keys.s or key == keys.down then
            selected = selected + 1
            if selected > #options then
                selected = 1
            end
        elseif key == keys.enter then
            local option = options[selected]

            if option == "Add disk" then
                writeAuthDiskForUser(username)
            elseif option == "List disks" then
                listUserDisksScreen(username)
            elseif option == "Revoke disk" then
                revokeDiskMenu(username)
            elseif option == "Unrevoke disk" then
                unrevokeDiskMenu(username)
            elseif option == "Remove disk record" then
                removeDiskMenu(username)
            elseif option == "Back" then
                return
            end
        elseif key == keys.a or key == keys.left then
            return
        end
    end
end

local function userActionMenu(username)
    local selected = 1

    while true do
        local userStates = loadUserStates()
        local state = getUserState(userStates, username)
        local options = getUserActionOptions(state)

        if #options == 0 then
            return
        end

        if selected > #options then
            selected = #options
        end

        clear()
        print("================================")
        print("          User Actions")
        print("================================")
        print("")
        print("User: " .. username)
        print("")

        setUserStateColor(state)
        print("State: " .. string.upper(state))
        term.setTextColor(colors.white)
        print("")

        for i, option in ipairs(options) do
            if i == selected then
                print("> " .. option)
            else
                print("  " .. option)
            end
        end

        print("")
        print("W/S or up/down | Enter | A/left")

        local key = waitForKey()

        if key == keys.w or key == keys.up then
            selected = selected - 1
            if selected < 1 then
                selected = #options
            end
        elseif key == keys.s or key == keys.down then
            selected = selected + 1
            if selected > #options then
                selected = 1
            end
        elseif key == keys.enter then
            local option = options[selected]

            if option == "Deactivate" then
                changeSelectedUserState(username, USER_STATE_INACTIVE)
                return
            elseif option == "Activate" then
                changeSelectedUserState(username, USER_STATE_ACTIVE)
                return
            elseif option == "Admin" then
                if state == USER_STATE_ADMIN then
                    changeSelectedUserState(username, USER_STATE_ACTIVE)
                elseif state == USER_STATE_ACTIVE then
                    changeSelectedUserState(username, USER_STATE_ADMIN)
                end
                return
            elseif option == "Disks" then
                userDisksMenu(username)
            elseif option == "Remove" then
                removeSelectedUser(username)
                return
            elseif option == "Change password" then
                changeUserPassword(username)
            end
        elseif key == keys.a or key == keys.left then
            return
        end
    end
end

local function usersMenu()
    local selected = 1

    while true do
        local users = loadUsers()
        local userStates = syncUserStates()
        syncUserDisks()
        local userList = getUserList(users)

        local options = #userList + 1
        local addUserIndex = options

        if selected > options then
            selected = options
        end

        clear()
        print("================================")
        print("             Users")
        print("================================")
        print("")

        for i, username in ipairs(userList) do
            printUserState(username, getUserState(userStates, username), i == selected)
        end

        if selected == addUserIndex then
            term.setTextColor(colors.white)
            print("> + Add user")
        else
            term.setTextColor(colors.white)
            print("  + Add user")
        end

        term.setTextColor(colors.white)

        print("")
        print("Admin    = yellow")
        print("Active   = green")
        print("Inactive = red")
        print("")
        print("W/S or up/down | Enter | A/left")

        local key = waitForKey()

        if key == keys.w or key == keys.up then
            selected = selected - 1
            if selected < 1 then
                selected = options
            end
        elseif key == keys.s or key == keys.down then
            selected = selected + 1
            if selected > options then
                selected = 1
            end
        elseif key == keys.enter then
            if selected == addUserIndex then
                addUser()
            else
                userActionMenu(userList[selected])
            end
        elseif key == keys.a or key == keys.left then
            return
        end
    end
end

--------------------------------------------------
-- Add user
--------------------------------------------------

addUser = function()
    local users = loadUsers()
    local userStates = loadUserStates()
    local userDisks = loadUserDisks()

    clear()
    print("Add User")
    print("--------")
    print("")
    write("Username: ")

    local username = read()
    username = trim(username)

    if username == "" then
        print("")
        print("Username cannot be empty.")
        sleep(2)
        return
    end

    if users[username] then
        print("")
        print("User already exists.")
        sleep(2)
        return
    end

    print("")
    print("Password is required.")
    print("")
    write("Password: ")

    local password = read("*")

    if password == "" then
        print("")
        print("Password cannot be empty.")
        sleep(2)
        return
    end

    if isReservedPassword(password) then
        print("")
        print("The password 'admin' is reserved.")
        print("Choose another password.")
        sleep(2)
        return
    end

    local passwordHash = sha256(password)

    for oldUsername, oldPasswordHash in pairs(users) do
        if oldUsername ~= username
            and oldPasswordHash ~= ""
            and oldPasswordHash == passwordHash then

            local conflictFile = "/disk/conflict_" .. oldUsername .. "_" .. username
            local file = fs.open(conflictFile, "w")

            if file then
                file.writeLine("Password conflict detected.")
                file.writeLine("Existing user: " .. oldUsername)
                file.writeLine("New user: " .. username)
                file.writeLine("The new account was NOT created.")
                file.close()
            end

            logMessage("PASSWORD CONFLICT - existing user: " .. oldUsername .. ", new user: " .. username)

            print("")
            print("Password already in use.")
            print("")
            print("Conflict user: " .. oldUsername)
            print("New user: " .. username)
            print("")
            print("Account NOT created.")

            sleep(3)
            return
        end
    end

    users[username] = passwordHash
    userStates[username] = USER_STATE_ACTIVE
    userDisks[username] = {}

    saveUsers(users)
    saveUserStates(userStates)
    saveUserDisks(userDisks)

    logMessage("User added: " .. username .. " (active)")

    print("")
    print("User added.")
    sleep(2)
end

--------------------------------------------------
-- Request client updates
--------------------------------------------------

local function requestClientUpdate()
    clear()
    print("Request Client Update")
    print("---------------------")
    print("")
    print("Broadcasting update request...")

    rednet.broadcast({ type = "update" }, "door_control")
    logMessage("UPDATE REQUEST - Broadcast")

    print("")
    print("Update request broadcast.")
    sleep(2)
end

--------------------------------------------------
-- Update server
--------------------------------------------------

function download(name, url)
    print("Updating " .. name)

    local request = http.get(url, { ["Cache-Control"] = "no-cache, no-store, must-revalidate" })
    if not request then
        print("Failed to download " .. name)
        return
    end

    local data = request.readAll()
    request.close()

    local file = fs.open(name, "w")
    if not file then
        print("Failed to write " .. name)
        return
    end

    file.write(data)
    file.close()

    print("Successfully downloaded " .. name .. "\n")
end

local function updateServer()
    clear()

    for _, value in ipairs(urls) do
        download(unpack(value))
    end

    logMessage("Server updated")

    print("")
    print("Update successful.")
    print("Rebooting...")

    sleep(2)
    os.reboot()
end

--------------------------------------------------
-- Admin menu
--------------------------------------------------

local function adminMenu(firstChar)
    if not authenticateAdmin(firstChar) then
        return
    end

    local options = {
        "Users",
        "Set auth drive path",
        "Request client update",
        "Update server",
        "Exit Menu",
        "Exit Program"
    }

    local selected = 1

    while true do
        clear()

        print("================================")
        print("        Door Server " .. VERSION)
        print("================================")
        print("")
        print("Auth drive path: " .. loadAuthDiskDrivePath())
        print("")

        for i, option in ipairs(options) do
            if i == selected then
                print("> " .. option)
            else
                print("  " .. option)
            end
        end

        print("")
        print("W/S or up/down | Enter | A/left")

        local key = waitForKey()

        if key == keys.w or key == keys.up then
            selected = selected - 1
            if selected < 1 then
                selected = #options
            end
        elseif key == keys.s or key == keys.down then
            selected = selected + 1
            if selected > #options then
                selected = 1
            end
        elseif key == keys.enter then
            if selected == 1 then
                usersMenu()
            elseif selected == 2 then
                setAuthDrivePathMenu()
            elseif selected == 3 then
                requestClientUpdate()
            elseif selected == 4 then
                updateServer()
            elseif selected == 5 then
                clear()
                return
            elseif selected == 6 then
                clear()
                exit = true
                return
            end
        elseif key == keys.a or key == keys.left then
            clear()
            return
        end
    end
end

--------------------------------------------------
-- Start authentication listener
--------------------------------------------------

local function startListener()
    if not multishell then
        error("Multishell is required")
    end

    local processID = multishell.launch({}, "/startup", LISTENER_ARG)
    multishell.setTitle(processID, "Door Auth")
end

--------------------------------------------------
-- Listener process
--------------------------------------------------

if ... == LISTENER_ARG then
    authenticationListener()
    return
end

--------------------------------------------------
-- Main process
--------------------------------------------------

math.randomseed((os.epoch and os.epoch("utc") or os.time()) + SERVER_ID)

rednet.open("bottom")

clear()

print("================================")
print("        Door Server " .. VERSION)
print("================================")
print("")

logMessage("Door server " .. VERSION .. " started on computer " .. SERVER_ID)

syncUserStates()
syncUserDisks()

if not fs.exists(AUTH_DRIVE_CONFIG_FILE) then
    saveAuthDiskDrivePath(DEFAULT_AUTH_DISK_DRIVE_PATH)
end

startListener()

--------------------------------------------------
-- Main loop
--------------------------------------------------

while not exit do
    local event, p1 = os.pullEventRaw()

    if event == "terminate" then
        -- Ignore Ctrl+T
    elseif event == "char" then
        adminMenu(p1)

        if not exit then
            clear()
            print("================================")
            print("        Door Server " .. VERSION)
            print("================================")
            print("")
            print("Door server running...")
            print("Start typing to enter admin password.")
        end
    end
end