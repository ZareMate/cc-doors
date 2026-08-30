local VERSION = "v2.7"

print(VERSION)

function download(name, url)
  print("Updating " .. name)
 
  request = http.get(url, { ["Cache-Control"] = "no-cache, no-store, must-revalidate" })
  data = request.readAll()
 
  if fs.exists(name) then
    fs.delete(name)
    file = fs.open(name, "w")
    file.write(data)
    file.close()
  else
    file = fs.open(name, "w")
    file.write(data)
    file.close()
  end
 
  print("Successfully downloaded " .. name .. "\n")
end

local server = os.getComputerLabel() == "Server"

local urls = {}

if server then
    urls = {
        {"startup", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/server.lua"},
        {"sha256", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/sha256.lua"},
        {"updater", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/updater.lua"},
    }
else
    urls = {
        {"startup", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/door.lua"},
        {"sha256", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/sha256.lua"},
        {"updater", "https://raw.githubusercontent.com/ZareMate/cc-doors/refs/heads/main/updater.lua"},
    }
end

for _, value in ipairs(urls) do
    download(unpack(value))
end