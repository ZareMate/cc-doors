local VERSION = "v2.5"

local USERS_FILE = "/disk/users"
local USER_STATES_FILE = "/disk/user_states"
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
-- Reserved password
--------------------------------------------------

local function isReservedPassword(password)
    return type(password) == "string"
        and password:lower() == RESERVED_PASSWORD
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
            error(
                "Invalid user state for " ..
                tostring(username)
            )
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

local function logMessage(message)
    local date = os.date("%Y-%m-%d %H:%M:%S")

    local file = fs.open(LOG_FILE, "a")

    if file then
        file.writeLine(
            "[" .. date .. "] " .. message
        )
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

    path = path:gsub("^%s+", ""):gsub("%s+$", "")

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
-- Synchronize users and user states
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

    if changed then
        saveUserStates(userStates)
    end

    return userStates
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

    -- With FS-only approach, the path itself is the mount path.
    -- Example: /disk2
    return {
        mountPath = authDrivePath,
        drivePath = authDrivePath
        side = "left"
    }, nil
end

local function writeAuthDiskForUser(username)
    local users = loadUsers()
    local userHash = users[username]

    clear()
    print("Make Auth Disk")
    print("--------------")
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

    local hashPath = fs.combine(info.mountPath, "hash")
    local file = fs.open(hashPath, "w")

    if not file then
        print("Failed to write hash file.")
        sleep(2)
        return
    end

    file.write(userHash)
    file.close()

    local label = "Access - " .. username
    pcall(function()
        disk.setLabel(info.side, label)
    end)

    print("Auth disk written successfully.")
    print("Label: " .. label)
    print("Drive path: " .. info.drivePath)
    print("Path: " .. hashPath)

    logMessage("AUTH DISK CREATED - " .. username .. " on " .. info.mountPath)

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
    local newPath = input:gsub("^%s+", ""):gsub("%s+$", "")

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
-- Authentication listener
--------------------------------------------------

local function handleDoorAuth(sender, message)
    local users = loadUsers()
    local userStates = syncUserStates()

    if type(message) ~= "table"
        or message.type ~= "auth"
        or type(message.hash) ~= "string" then
        rednet.send(sender, false, "door_auth")
        return
    end

    local username = getUserByHash(users, message.hash)

    if username and isUserActive(userStates, username) then
        rednet.send(sender, true, "door_auth")
        logMessage("ACCESS GRANTED - " .. username .. " (" .. getUserState(userStates, username) .. ", Computer " .. sender .. ")")
    else
        rednet.send(sender, false, "door_auth")
        if username then
            logMessage("ACCESS DENIED - " .. username .. " (" .. getUserState(userStates, username) .. ", Computer " .. sender .. ")")
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
            saveUsers(users)
            saveUserStates(userStates)
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

    table.insert(options, "Make auth disk")
    table.insert(options, "Remove")
    table.insert(options, "Change password")

    return options
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
            elseif option == "Make auth disk" then
                writeAuthDiskForUser(username)
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

    clear()
    print("Add User")
    print("--------")
    print("")
    write("Username: ")

    local username = read()

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

    saveUsers(users)
    saveUserStates(userStates)

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

    local request = http.get(url)
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

    logMessage("Server updated server")

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

rednet.open("bottom")

clear()

print("================================")
print("        Door Server " .. VERSION)
print("================================")
print("")

logMessage("Door server " .. VERSION .. " started on computer " .. SERVER_ID)

syncUserStates()

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