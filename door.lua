local VERSION = "v2.5"

local SERVER_ID = 214

local SHA256_FILE = "/sha256"
local CONFIG_FILE = "/config"

local PASSWORD_TIMEOUT = 30
local SERVER_TIMEOUT = 10
local MENU_TIMEOUT = 60
local MAIN_TIMEOUT = 60

local urls = {
  {"startup", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/door.lua"},
  {"sha256", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/sha256.lua"},
  {"updater", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/updater.lua"},
}

local exit = false
local DRIVE_SIDE = "top"

--------------------------------------------------
-- UI
--------------------------------------------------

local function clear()
    term.clear()
    term.setCursorPos(1, 1)
end

--------------------------------------------------
-- Safe key input
--------------------------------------------------

local function waitForKey(timeout)
    local timer

    if timeout then
        timer = os.startTimer(timeout)
    end

    while not exit do
        local event, p1 = os.pullEventRaw()

        if event == "terminate" then
            -- Ignore Ctrl+T

        elseif event == "key" then
            if timer then
                os.cancelTimer(timer)
            end

            return p1

        elseif event == "timer" and p1 == timer then
            return nil
        end
    end

    return nil
end

--------------------------------------------------
-- Password input
--------------------------------------------------

local function readPassword(prompt, timeout)
    write(prompt)

    local input = ""
    local timer = os.startTimer(timeout)

    term.setCursorBlink(true)

    while not exit do
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
                os.cancelTimer(timer)

                term.setCursorBlink(false)
                print("")

                return input

            elseif p1 == keys.esc
                or p1 == keys.left
                or p1 == keys.a then

                os.cancelTimer(timer)

                term.setCursorBlink(false)
                print("")

                return nil
            end

        elseif event == "timer" and p1 == timer then
            term.setCursorBlink(false)

            print("")
            print("Input timed out.")

            sleep(1)

            return nil
        end
    end

    os.cancelTimer(timer)
    term.setCursorBlink(false)

    return nil
end

--------------------------------------------------
-- Rednet response
--------------------------------------------------

local function receiveRednet(protocol, timeout)
    local timer = os.startTimer(timeout)

    while not exit do
        local event, p1, p2, p3 = os.pullEventRaw()

        if event == "terminate" then
            -- Ignore Ctrl+T

        elseif event == "rednet_message" then
            local sender = p1
            local message = p2
            local receivedProtocol = p3

            if receivedProtocol == protocol then
                os.cancelTimer(timer)

                return sender, message
            end

        elseif event == "timer" and p1 == timer then
            return nil, nil
        end
    end

    os.cancelTimer(timer)

    return nil, nil
end

--------------------------------------------------
-- Configuration
--------------------------------------------------

local function saveConfig(doorSide)
    local file = fs.open(CONFIG_FILE, "w")

    if not file then
        error("Could not write " .. CONFIG_FILE)
    end

    file.write(textutils.serialize({
        doorSide = doorSide
    }))

    file.close()
end

local function selectDoorSide()
    local sides = {
        "top",
        "bottom",
        "left",
        "right",
        "front",
        "back"
    }

    local selected = 1

    while not exit do
        clear()

        print("================================")
        print("        Door Configuration")
        print("             " .. VERSION)
        print("================================")
        print("")
        print("Select the side connected to")
        print("the door:")
        print("")

        for i, side in ipairs(sides) do
            if i == selected then
                print("> " .. side)
            else
                print("  " .. side)
            end
        end

        print("")
        print("W/S or ↑/↓ | Enter")

        local key = waitForKey(nil)

        if key == keys.w or key == keys.up then
            selected = selected - 1

            if selected < 1 then
                selected = #sides
            end

        elseif key == keys.s or key == keys.down then
            selected = selected + 1

            if selected > #sides then
                selected = 1
            end

        elseif key == keys.enter then
            local side = sides[selected]

            saveConfig(side)

            return side

        elseif key == keys.a or key == keys.left then
            -- Cannot leave until configured
        end
    end

    return nil
end

local function loadConfig()
    if not fs.exists(CONFIG_FILE) then
        return selectDoorSide()
    end

    local file = fs.open(CONFIG_FILE, "r")

    if not file then
        return selectDoorSide()
    end

    local data = file.readAll()
    file.close()

    if data == "" then
        return selectDoorSide()
    end

    local config = textutils.unserialize(data)

    if type(config) ~= "table"
        or type(config.doorSide) ~= "string"
        or config.doorSide == "" then

        return selectDoorSide()
    end

    return config.doorSide
end

local DOOR_SIDE = loadConfig()

--------------------------------------------------
-- SHA-256
--------------------------------------------------

if not fs.exists(SHA256_FILE) then
    error("Missing " .. SHA256_FILE)
end

local sha256 = dofile(SHA256_FILE)

--------------------------------------------------
-- Modem
--------------------------------------------------

local modem

for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then
        modem = side
        break
    end
end

if not modem then
    error("No modem found")
end

rednet.open(modem)

--------------------------------------------------
-- Admin authentication
--------------------------------------------------

local function authenticateAdmin()
    clear()

    print("Admin Authentication")
    print("--------------------")
    print("             " .. VERSION)
    print("")

    local password = readPassword(
        "Password: ",
        PASSWORD_TIMEOUT
    )

    if password == nil then
        return false
    end

    local hash = sha256(password)

    rednet.send(
        SERVER_ID,
        {
            type = "admin_auth",
            hash = hash
        },
        "admin_auth"
    )

    print("")
    print("Checking...")

    local sender, response = receiveRednet(
        "admin_auth_response",
        SERVER_TIMEOUT
    )

    if sender ~= SERVER_ID then
        print("")
        print("No response from server.")

        sleep(2)

        return false
    end

    if type(response) == "table"
        and response.success == true then

        clear()

        print("Admin Authentication")
        print("--------------------")
        print("             " .. VERSION)
        print("")
        print(
            "Authenticated as " ..
            (response.username or "admin")
        )

        sleep(1)

        return true
    end

    print("")
    print("Invalid admin password.")

    sleep(2)

    return false
end

--------------------------------------------------
-- Update
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

local function update()
    clear()

    for _, value in ipairs(urls) do
        download(unpack(value))
    end

    print("")
    print("Update successful.")
    print("Rebooting...")

    sleep(1)

    os.reboot()
end

--------------------------------------------------
-- Change door side
--------------------------------------------------

local function changeDoorSide()
    local sides = {
        "top",
        "bottom",
        "left",
        "right",
        "front",
        "back"
    }

    local selected = 1

    for i, side in ipairs(sides) do
        if side == DOOR_SIDE then
            selected = i
            break
        end
    end

    while not exit do
        clear()

        print("================================")
        print("        Change Door Side")
        print("================================")
        print("")

        for i, side in ipairs(sides) do
            if i == selected then
                print("> " .. side)
            else
                print("  " .. side)
            end
        end

        print("")
        print("W/S or ↑/↓ | Enter | A/←")

        local key = waitForKey(MENU_TIMEOUT)

        if key == nil then
            return
        end

        if key == keys.w or key == keys.up then
            selected = selected - 1

            if selected < 1 then
                selected = #sides
            end

        elseif key == keys.s or key == keys.down then
            selected = selected + 1

            if selected > #sides then
                selected = 1
            end

        elseif key == keys.enter then
            DOOR_SIDE = sides[selected]

            saveConfig(DOOR_SIDE)

            clear()

            print("Door side changed.")
            print("")
            print("New side: " .. DOOR_SIDE)

            sleep(2)

            return

        elseif key == keys.a or key == keys.left then
            return
        end
    end
end

--------------------------------------------------
-- Admin menu
--------------------------------------------------

local function adminMenu()
    if not authenticateAdmin() then
        return
    end

    local options = {
        "Change door side",
        "Update",
        "Exit program"
    }

    local selected = 1

    while not exit do
        clear()

        print("================================")
        print("         Admin Menu")
        print("             " .. VERSION)
        print("================================")
        print("")

        for i, option in ipairs(options) do
            if i == selected then
                print("> " .. option)
            else
                print("  " .. option)
            end
        end

        print("")
        print("W/S or ↑/↓ | Enter | A/←")

        local key = waitForKey(MENU_TIMEOUT)

        if key == nil then
            return
        end

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
                changeDoorSide()

            elseif selected == 2 then
                update()

            elseif selected == 3 then
                clear()
                print("Exiting...")
                sleep(1)

                exit = true

                return
            end

        elseif key == keys.a or key == keys.left then
            return
        end
    end
end

--------------------------------------------------
-- Door authentication
--------------------------------------------------

local function authenticateDoor(password)
    local hash = sha256(password)

    rednet.send(
        SERVER_ID,
        {
            type = "auth",
            hash = hash
        },
        "door_auth"
    )

    print("")
    print("Checking...")

    local sender, response = receiveRednet(
        "door_auth",
        SERVER_TIMEOUT
    )

    clear()

    if sender ~= SERVER_ID then
        print("Door Access")
        print("-----------")
        print("")
        print("No response from server.")

        sleep(2)

        return
    end

    if response == true then
        print("Door Access")
        print("-----------")
        print("")
        print("Access granted!")

        redstone.setOutput(
            DOOR_SIDE,
            true
        )

        sleep(2.5)

        redstone.setOutput(
            DOOR_SIDE,
            false
        )

        print("")
        print("Door closed.")

        sleep(1)

    else
        print("Door Access")
        print("-----------")
        print("")
        print("Access denied!")

        sleep(1)
    end
end

local function authenticateDoorHash(hash)
    rednet.send(
        SERVER_ID,
        {
            type = "auth",
            hash = hash
        },
        "door_auth"
    )

    print("")
    print("Checking...")

    local sender, response = receiveRednet(
        "door_auth",
        SERVER_TIMEOUT
    )

    clear()

    if sender ~= SERVER_ID then
        print("Door Access")
        print("-----------")
        print("")
        print("No response from server.")
        sleep(2)
        return
    end

    if response == true then
        print("Door Access")
        print("-----------")
        print("")
        print("Access granted!")

        redstone.setOutput(DOOR_SIDE, true)
        sleep(2.5)
        redstone.setOutput(DOOR_SIDE, false)

        print("")
        print("Door closed.")
        sleep(1)
    else
        print("Door Access")
        print("-----------")
        print("")
        print("Access denied!")
        sleep(1)
    end
end

--------------------------------------------------
-- Disk access listener (top drive)
--------------------------------------------------

local function diskAccessListener()
    while not exit do
        local event, side = os.pullEventRaw()

        if event == "terminate" then
            -- Ignore Ctrl+T

        elseif event == "disk" and side == DRIVE_SIDE then
            local mountPath = disk.getMountPath(DRIVE_SIDE)
            local label = disk.getLabel(DRIVE_SIDE)

            -- Accept "Access" or "Access - anything"
            local validLabel = type(label) == "string"
                and (label == "Access" or label:match("^Access%s*%-%s*.+$"))

            if mountPath and validLabel then
                local hashPath = fs.combine(mountPath, "hash")

                if fs.exists(hashPath) then
                    local f = fs.open(hashPath, "r")
                    if f then
                        local hash = f.readAll()
                        f.close()

                        if type(hash) == "string" then
                            hash = hash:gsub("^%s+", ""):gsub("%s+$", "")
                            if hash ~= "" then
                                -- Always eject
                                disk.eject(DRIVE_SIDE)
                                authenticateDoorHash(hash)
                            end
                        end
                    end
                end
            end

            
        end
    end
end

--------------------------------------------------
-- Main screen
--------------------------------------------------

local function mainScreen()
    clear()

    print("================================")
    print("          Door Access")
    print("             " .. VERSION)
    print("================================")
    print("")
    print("Enter password.")
end

--------------------------------------------------
-- Main loop
--------------------------------------------------

local function mainLoop()
    while not exit do
        mainScreen()

        local password = readPassword(
            "Password: ",
            PASSWORD_TIMEOUT
        )

        if password == nil then
            -- Timeout/cancel

        elseif password:lower() == "admin" then
            adminMenu()

        else
            authenticateDoor(password)
        end
    end
end

--------------------------------------------------
-- Server update listener
--------------------------------------------------

local function updateListener()
    while not exit do
        local event, p1, p2, p3 = os.pullEventRaw()

        if event == "terminate" then
            -- Ignore Ctrl+T

        elseif event == "rednet_message" then
            local sender = p1
            local message = p2
            local protocol = p3

            if sender == SERVER_ID
                and protocol == "door_control"
                and type(message) == "table"
                and message.type == "update" then

                update()
            end
        end
    end
end

--------------------------------------------------
-- Run simultaneously
--------------------------------------------------

parallel.waitForAny(
    mainLoop,
    updateListener,
    diskAccessListener
)