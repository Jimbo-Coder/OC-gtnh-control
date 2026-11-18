-- Installer & updater for GTNH AE2 Control / Mainnet Telemetry & Mesh Hub
-- Installs /home/exporter.lua and preserves existing /home/config.lua.

local cliArgs = { ... }

local component = require("component")
local filesystem = require("filesystem")

local DEFAULT_REPO = "Jimbo-Coder/OC-gtnh-control"
local SUBDIR = "gtnh-ae2-control"
local DEFAULT_BRANCH = "main"
local EXPORTER_PATH = "/home/exporter.lua"
local CONFIG_PATH = "/home/config.lua"
local EXAMPLE_DEST = "/home/config.ae2.example.lua"
local REPO_META_PATH = "/home/.ae2_repo"
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
    local localDir, optRepo, optBranch = nil, nil, nil
    local isUpdate, optYes, optNoPrompt, optAutostart = false, false, false, nil
    local idx = 1
    while idx <= #args do
        local a = tostring(args[idx])
        if a == "--local" then idx = idx + 1; localDir = tostring(args[idx] or ""):gsub("/+$", "")
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

    if localDir and not filesystem.exists(filesystem.concat(localDir, "exporter.lua")) then
        local sub = filesystem.concat(localDir, SUBDIR)
        if filesystem.exists(filesystem.concat(sub, "exporter.lua")) then localDir = sub end
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
    local repo = (optRepo and optRepo ~= "") and optRepo or ((sRepo and sRepo ~= "") and sRepo or DEFAULT_REPO)
    local branch = (optBranch and optBranch ~= "") and optBranch or ((sBranch and sBranch ~= "") and sBranch or DEFAULT_BRANCH)
    local baseUrl = string.format("https://raw.githubusercontent.com/%s/%s/%s/", repo, branch, SUBDIR)

    print("=== GTNH AE2 CONTROL & MESH HUB INSTALLER ===")
    local function getFile(rel)
        if localDir then
            local body = readWholeFile(filesystem.concat(localDir, rel))
            return body, body and nil or ("missing " .. rel)
        end
        return fetchUrl(internet, baseUrl .. rel)
    end

    local expBody, expErr = getFile("exporter.lua")
    if not expBody then io.stderr:write("ERROR: " .. tostring(expErr) .. "\n"); return false, expErr end
    local okLoad, synErr = load(expBody, "@exporter.lua", "t")
    if not okLoad then io.stderr:write("ERROR: Invalid Lua in exporter.lua: " .. tostring(synErr) .. "\n"); return false, synErr end

    local cfgBody, cfgErr = getFile("config.example.lua")
    if not cfgBody then io.stderr:write("ERROR: " .. tostring(cfgErr) .. "\n"); return false, cfgErr end
    local okCfg, synCfg = load(cfgBody, "@config.example.lua", "t")
    if not okCfg then io.stderr:write("ERROR: Invalid Lua in config.example.lua: " .. tostring(synCfg) .. "\n"); return false, synCfg end

    writeWholeFile(EXPORTER_PATH, expBody)
    print(string.format("[OK 1/2] %s (%d bytes)", EXPORTER_PATH, #expBody))
    writeWholeFile(EXAMPLE_DEST, cfgBody)

    if filesystem.exists(CONFIG_PATH) then
        print("[KEEP]    Preserved existing " .. CONFIG_PATH .. " (reference -> " .. EXAMPLE_DEST .. ")")
    else
        writeWholeFile(CONFIG_PATH, cfgBody)
        print("[OK 2/2] Created " .. CONFIG_PATH .. " from defaults")
    end

    writeWholeFile(REPO_META_PATH, repo .. "\n" .. branch .. "\n")

    local existingShrc = readWholeFile(SHRC_PATH) or ""
    if not isUpdate and not existingShrc:find("exporter.lua", 1, true) then
        local wantAuto = optYes or optAutostart
        if not wantAuto and not optNoPrompt and optAutostart == nil and io.read then
            io.write("Auto-start /home/exporter.lua in /home/.shrc? [Y/n]: ")
            local line = io.read()
            wantAuto = (tostring(line or "y") .. "y"):match("^%s*[Yy]") ~= nil
        end
        if wantAuto then
            local pref = (existingShrc ~= "" and existingShrc:sub(-1) ~= "\n") and (existingShrc .. "\n") or existingShrc
            writeWholeFile(SHRC_PATH, pref .. "/home/exporter.lua\n")
            print("[AUTO]    Added /home/exporter.lua to /home/.shrc")
        end
    end

    print("Done! Run `/home/exporter.lua` to start AE2 Control & Telemetry.")
    return true
end

return runInstaller(cliArgs)
