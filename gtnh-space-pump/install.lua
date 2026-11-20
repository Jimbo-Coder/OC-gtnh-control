-- Installer & updater for GTNH Space Elevator Pump (`autoPump.lua`)
-- Installs /home/autoPump.lua and backs up any existing /home/autoPump.lua to /home/autoPump.lua.bak.

local cliArgs = { ... }

local component = require("component")
local filesystem = require("filesystem")

local DEFAULT_REPO = "Jimbo-Coder/OC-gtnh-control"
local SUBDIR = "gtnh-space-pump"
local DEFAULT_BRANCH = "main"
local DEST_PATH = "/home/autoPump.lua"
local BACKUP_PATH = "/home/autoPump.lua.bak"
local REPO_META_PATH = "/home/.pump_repo"
local SHRC_PATH = "/home/.shrc"

local function readWholeFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeWholeFile(path, content)
    local parent = filesystem.path(path)
    if parent and parent ~= "" and not filesystem.exists(parent) then
        filesystem.makeDirectory(parent)
    end
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(content)
    f:close()
    return true
end

local function fetchUrl(internet, url)
    local req, err = internet.request(url)
    if not req then return nil, tostring(err or "request failed") end
    local osLib = rawget(_G, "os")
    local function briefYield()
        if type(osLib) == "table" and osLib.sleep then pcall(osLib.sleep, 0.05) end
    end
    if req.finishConnect then
        local conn = false
        for _ = 1, 200 do
            local ok, ferr = req.finishConnect()
            if ok == true then conn = true; break
            elseif ok == nil then pcall(req.close); return nil, tostring(ferr or "connect failed")
            end
            briefYield()
        end
        if not conn then pcall(req.close); return nil, "connect timeout" end
    end
    local chunks, empty = {}, 0
    for _ = 1, 4096 do
        local ch, rErr = req.read()
        if ch == nil then
            if rErr then pcall(req.close); return nil, tostring(rErr) end
            break
        elseif ch == "" then
            empty = empty + 1
            if empty >= 200 then pcall(req.close); return nil, "read timeout" end
            briefYield()
        else
            empty = 0
            chunks[#chunks + 1] = ch
        end
    end
    local code = req.response and req.response() or nil
    pcall(req.close)
    if type(code) == "number" and code >= 400 then return nil, "HTTP " .. tostring(code) end
    local body = table.concat(chunks)
    if #body == 0 then return nil, "empty response" end
    return body
end

local function runInstaller(args)
    args = args or {}
    local localDir, optRepo, optBranch, optUrl = nil, nil, nil, nil
    local isUpdate, optYes, optNoPrompt, optAutostart = false, false, false, nil
    local idx = 1
    while idx <= #args do
        local a = tostring(args[idx])
        if a == "--local" then idx = idx + 1; localDir = tostring(args[idx] or ""):gsub("/+$", "")
        elseif a == "--url" then idx = idx + 1; optUrl = tostring(args[idx] or ""):gsub("/+$", "")
        elseif a == "--local-bridge" then optUrl = "http://127.0.0.1:8765/oc-raw"
        elseif a == "--repo" then idx = idx + 1; optRepo = tostring(args[idx] or "")
        elseif a == "--branch" then idx = idx + 1; optBranch = tostring(args[idx] or "")
        elseif a == "--update" then isUpdate = true
        elseif a == "--yes" or a == "-y" then optYes = true
        elseif a == "--no-prompt" then optNoPrompt = true
        elseif a == "--autostart" then optAutostart = true
        elseif a == "--no-autostart" then optAutostart = false
        end
        idx = idx + 1
    end

    if localDir and not filesystem.exists(filesystem.concat(localDir, "autoPump.lua")) then
        local sub = filesystem.concat(localDir, SUBDIR)
        if filesystem.exists(filesystem.concat(sub, "autoPump.lua")) then localDir = sub end
    end

    local internet = nil
    if not localDir then
        local addr = component.list("internet", true)()
        internet = addr and component.proxy(addr) or (component.isAvailable("internet") and component.internet or nil)
        if not internet then
            io.stderr:write("ERROR: Internet Card required (or use --local <dir>).\n")
            return false, "no internet card"
        end
    end

    local saved = readWholeFile(REPO_META_PATH)
    local sRepo, sBranch = saved and saved:match("^([^\r\n]+)\r?\n?([^\r\n]*)")
    local rawSrc = (optUrl and optUrl ~= "") and optUrl
        or ((optRepo and optRepo ~= "") and optRepo
        or ((sRepo and sRepo ~= "") and sRepo or DEFAULT_REPO))
    local branch = (optBranch and optBranch ~= "") and optBranch or ((sBranch and sBranch ~= "") and sBranch or DEFAULT_BRANCH)
    local baseUrl
    local repoMeta = rawSrc
    if rawSrc:match("^https?://") then
        local clean = rawSrc:gsub("/+$", "")
        repoMeta = clean
        baseUrl = (clean:sub(-#SUBDIR) == SUBDIR) and (clean .. "/") or (clean .. "/" .. SUBDIR .. "/")
    else
        baseUrl = string.format("https://raw.githubusercontent.com/%s/%s/%s/", rawSrc, branch, SUBDIR)
    end
    local url = baseUrl .. "autoPump.lua"

    print("=== GTNH SPACE PUMP INSTALLER ===")
    local body, err
    if localDir then
        body = readWholeFile(filesystem.concat(localDir, "autoPump.lua"))
        err = body and nil or "missing autoPump.lua"
    else
        body, err = fetchUrl(internet, url)
    end
    if not body then io.stderr:write("ERROR: " .. tostring(err) .. "\n"); return false, err end

    local chunk, synErr = load(body, "@autoPump.lua", "t")
    if not chunk then io.stderr:write("ERROR: Invalid Lua in autoPump.lua: " .. tostring(synErr) .. "\n"); return false, synErr end

    local prev = readWholeFile(DEST_PATH)
    if type(prev) == "string" and #prev > 0 then
        writeWholeFile(BACKUP_PATH, prev)
        print("[BACKUP]  Saved previous autoPump.lua -> " .. BACKUP_PATH .. " (runtime overrides live in pump_overrides.lua)")
    end

    writeWholeFile(DEST_PATH, body)
    local instBody = localDir and readWholeFile(filesystem.concat(localDir, "install.lua")) or select(1, fetchUrl(internet, baseUrl .. "install.lua"))
    if instBody and load(instBody, "@install_pump.lua", "t") then
        writeWholeFile("/home/install_pump.lua", instBody)
    end
    writeWholeFile(REPO_META_PATH, repoMeta .. "\n" .. branch .. "\n")
    print(string.format("[OK 1/1] %s (%d bytes)", DEST_PATH, #body))

    local existingShrc = readWholeFile(SHRC_PATH) or ""
    if not isUpdate and not existingShrc:find("autoPump.lua", 1, true) then
        local wantAuto = optYes or optAutostart
        if not wantAuto and not optNoPrompt and optAutostart == nil and io.read then
            io.write("Auto-start /home/autoPump.lua in /home/.shrc? [Y/n]: ")
            local line = io.read()
            wantAuto = (tostring(line or "y") .. "y"):match("^%s*[Yy]") ~= nil
        end
        if wantAuto then
            local pref = (existingShrc ~= "" and existingShrc:sub(-1) ~= "\n") and (existingShrc .. "\n") or existingShrc
            writeWholeFile(SHRC_PATH, pref .. "/home/autoPump.lua\n")
            print("[AUTO]    Added /home/autoPump.lua to /home/.shrc")
        end
    end

    print("Done! Run `/home/autoPump.lua` (set `enableMesh = false` at top for standalone).")
    return true
end

return runInstaller(cliArgs)
