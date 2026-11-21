-- Installer & updater for GTNH Mainnet Brain & OC Mesh Hub
-- Installs /home/brain/{main.lua,lib/ui.lua,install.lua,config.lua} + /usr/bin/{brain,ae2}.lua
-- and preserves/migrates existing config.lua, config_overrides.lua, and /home/.shrc.

local cliArgs = { ... }

local component = require("component")
local filesystem = require("filesystem")

local DEFAULT_REPO = "Jimbo-Coder/OC-gtnh-control"
local SUBDIR = "gtnh-ae2-control"
local DEFAULT_BRANCH = "main"
local INSTALL_DIR = "/home/brain"
local MAIN_PATH = "/home/brain/main.lua"
local UI_PATH = "/home/brain/lib/ui.lua"
local INST_DEST = "/home/brain/install.lua"
local CONFIG_PATH = "/home/brain/config.lua"
local BACKUP_CONFIG_PATH = "/home/config.brain.bak"
local OVERRIDES_PATH = "/home/brain/config_overrides.lua"
local EXAMPLE_DEST = "/home/brain/config.example.lua"
local REPO_META_PATH = "/home/brain/.repo"
local LEGACY_CONFIG_PATH = "/home/config.lua"
local LEGACY_OVERRIDES_PATH = "/home/config_overrides.lua"
local LEGACY_REPO_META_PATH = "/home/.ae2_repo"
local BIN_BRAIN = "/usr/bin/brain.lua"
local BIN_AE2 = "/usr/bin/ae2.lua"
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

    local origLocalDir = localDir
    if localDir and not filesystem.exists(filesystem.concat(localDir, "main.lua")) then
        local sub = filesystem.concat(localDir, SUBDIR)
        if filesystem.exists(filesystem.concat(sub, "main.lua")) then localDir = sub end
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

    local saved = readWholeFile(REPO_META_PATH) or readWholeFile(LEGACY_REPO_META_PATH)
    local sRepo, sBranch = saved and saved:match("^([^\r\n]+)\r?\n?([^\r\n]*)")
    local rawSrc = (optUrl and optUrl ~= "") and optUrl
        or ((optRepo and optRepo ~= "") and optRepo
        or ((sRepo and sRepo ~= "") and sRepo or DEFAULT_REPO))
    local branch = (optBranch and optBranch ~= "") and optBranch or ((sBranch and sBranch ~= "") and sBranch or DEFAULT_BRANCH)
    local baseUrl, repoRootUrl
    local repoMeta = rawSrc
    if rawSrc:match("^https?://") then
        local clean = rawSrc:gsub("/+$", "")
        repoMeta = clean
        if clean:sub(-#SUBDIR) == SUBDIR then
            baseUrl = clean .. "/"
            repoRootUrl = clean:sub(1, -(#SUBDIR + 1)):gsub("/+$", "") .. "/"
        else
            baseUrl = clean .. "/" .. SUBDIR .. "/"
            repoRootUrl = clean .. "/"
        end
    else
        baseUrl = string.format("https://raw.githubusercontent.com/%s/%s/%s/", rawSrc, branch, SUBDIR)
        repoRootUrl = string.format("https://raw.githubusercontent.com/%s/%s/", rawSrc, branch)
    end

    print("=== GTNH MAINNET BRAIN & MESH HUB INSTALLER ===")
    local function getFile(rel)
        if localDir then
            local body = readWholeFile(filesystem.concat(localDir, rel))
            return body, body and nil or ("missing " .. rel)
        end
        return fetchUrl(internet, baseUrl .. rel)
    end

    local function getCommonFile()
        if localDir then
            local cands = {
                origLocalDir and filesystem.concat(origLocalDir, "common/gtnh_common.lua") or nil,
                filesystem.concat(filesystem.path(localDir), "common/gtnh_common.lua"),
                filesystem.concat(localDir, "common/gtnh_common.lua"),
            }
            for _, cp in ipairs(cands) do
                if cp then
                    local b = readWholeFile(cp)
                    if b then return b end
                end
            end
            return nil, "missing common/gtnh_common.lua"
        end
        return fetchUrl(internet, repoRootUrl .. "common/gtnh_common.lua")
    end

    local commonBody, commonErr = getCommonFile()
    if not commonBody then io.stderr:write("ERROR: " .. tostring(commonErr) .. "\n"); return false, commonErr end
    local okCom, synCom = load(commonBody, "@common/gtnh_common.lua", "t")
    if not okCom then io.stderr:write("ERROR: Invalid Lua in gtnh_common.lua: " .. tostring(synCom) .. "\n"); return false, synCom end

    local mainBody, mainErr = getFile("main.lua")
    if not mainBody then io.stderr:write("ERROR: " .. tostring(mainErr) .. "\n"); return false, mainErr end
    local okLoad, synErr = load(mainBody, "@main.lua", "t")
    if not okLoad then io.stderr:write("ERROR: Invalid Lua in main.lua: " .. tostring(synErr) .. "\n"); return false, synErr end

    local uiBody, uiErr = getFile("lib/ui.lua")
    if not uiBody then io.stderr:write("ERROR: " .. tostring(uiErr) .. "\n"); return false, uiErr end
    local okUi, synUi = load(uiBody, "@lib/ui.lua", "t")
    if not okUi then io.stderr:write("ERROR: Invalid Lua in lib/ui.lua: " .. tostring(synUi) .. "\n"); return false, synUi end

    local cfgBody, cfgErr = getFile("config.example.lua")
    if not cfgBody then io.stderr:write("ERROR: " .. tostring(cfgErr) .. "\n"); return false, cfgErr end
    local okCfg, synCfg = load(cfgBody, "@config.example.lua", "t")
    if not okCfg then io.stderr:write("ERROR: Invalid Lua in config.example.lua: " .. tostring(synCfg) .. "\n"); return false, synCfg end

    local instBody = getFile("install.lua")
    if instBody and not load(instBody, "@install.lua", "t") then
        io.stderr:write("ERROR: Invalid Lua in install.lua\n")
        return false, "invalid install.lua"
    end

    filesystem.makeDirectory(INSTALL_DIR)
    filesystem.makeDirectory(filesystem.concat(INSTALL_DIR, "lib"))
    filesystem.makeDirectory("/usr/lib")
    filesystem.makeDirectory("/usr/bin")

    writeWholeFile("/usr/lib/gtnh_common.lua", commonBody)
    print(string.format("[OK 0/3] %s (%d bytes)", "/usr/lib/gtnh_common.lua", #commonBody))

    writeWholeFile(MAIN_PATH, mainBody)
    print(string.format("[OK 1/3] %s (%d bytes)", MAIN_PATH, #mainBody))
    writeWholeFile(UI_PATH, uiBody)
    print(string.format("[OK 2/3] %s (%d bytes)", UI_PATH, #uiBody))
    writeWholeFile(EXAMPLE_DEST, cfgBody)

    if filesystem.exists(CONFIG_PATH) then
        local curCfg = readWholeFile(CONFIG_PATH)
        if type(curCfg) == "string" and #curCfg > 0 then writeWholeFile(BACKUP_CONFIG_PATH, curCfg) end
        print("[KEEP]    Preserved existing " .. CONFIG_PATH .. " (reference -> " .. EXAMPLE_DEST .. ")")
    elseif filesystem.exists(LEGACY_CONFIG_PATH) then
        local legCfg = readWholeFile(LEGACY_CONFIG_PATH)
        if type(legCfg) == "string" and #legCfg > 0 then
            writeWholeFile(CONFIG_PATH, legCfg)
            writeWholeFile(BACKUP_CONFIG_PATH, legCfg)
            print("[MIGRATE] Copied " .. LEGACY_CONFIG_PATH .. " -> " .. CONFIG_PATH)
        else
            writeWholeFile(CONFIG_PATH, cfgBody)
            print("[OK 3/3] Created " .. CONFIG_PATH .. " from defaults")
        end
    elseif filesystem.exists(BACKUP_CONFIG_PATH) then
        local bakCfg = readWholeFile(BACKUP_CONFIG_PATH)
        if type(bakCfg) == "string" and #bakCfg > 0 then
            writeWholeFile(CONFIG_PATH, bakCfg)
            print("[RESTORE] Restored " .. CONFIG_PATH .. " from " .. BACKUP_CONFIG_PATH)
        else
            writeWholeFile(CONFIG_PATH, cfgBody)
            print("[OK 3/3] Created " .. CONFIG_PATH .. " from defaults")
        end
    else
        writeWholeFile(CONFIG_PATH, cfgBody)
        print("[OK 3/3] Created " .. CONFIG_PATH .. " from defaults")
    end

    if (not filesystem.exists(OVERRIDES_PATH)) and filesystem.exists(LEGACY_OVERRIDES_PATH) then
        local legOv = readWholeFile(LEGACY_OVERRIDES_PATH)
        if type(legOv) == "string" and #legOv > 0 then
            writeWholeFile(OVERRIDES_PATH, legOv)
            print("[MIGRATE] Copied " .. LEGACY_OVERRIDES_PATH .. " -> " .. OVERRIDES_PATH)
        end
    end

    if instBody then
        writeWholeFile(INST_DEST, instBody)
    end
    writeWholeFile(REPO_META_PATH, repoMeta .. "\n" .. branch .. "\n")
    if filesystem.exists(LEGACY_REPO_META_PATH) then pcall(filesystem.remove, LEGACY_REPO_META_PATH) end

    local binStub = "local args = { ... }\nlocal c, e = loadfile(\"/home/brain/main.lua\")\nif not c then error(e) end\nreturn c(table.unpack(args))\n"
    writeWholeFile(BIN_BRAIN, binStub)
    writeWholeFile(BIN_AE2, binStub)
    if filesystem.exists("/home/exporter.lua") then
        writeWholeFile("/home/exporter.lua", binStub)
    end
    if filesystem.exists("/home/install_ae2.lua") then
        writeWholeFile("/home/install_ae2.lua", "local args = { ... }\nlocal c, e = loadfile(\"/home/brain/install.lua\")\nif not c then error(e) end\nreturn c(table.unpack(args))\n")
    end
    if filesystem.exists("/home/ae2_ui.lua") then
        pcall(filesystem.remove, "/home/ae2_ui.lua")
    end

    local existingShrc = readWholeFile(SHRC_PATH) or ""
    local shrcLines, migratedShrc, hasBrainAuto = {}, false, false
    for line in existingShrc:gmatch("[^\r\n]+") do
        local isComment = line:match("^%s*#") ~= nil
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        local drop = false
        if (not isComment) and trimmed ~= "" then
            local cmd, rest = trimmed:match("^(%S+)(.*)$")
            rest = rest or ""
            if cmd == "/home/exporter.lua" or cmd == "exporter" or cmd == "exporter.lua" then
                line = "brain" .. rest
                migratedShrc = true
                cmd = "brain"
            elseif cmd == "/home/ae2_ui.lua" then
                drop = true
                migratedShrc = true
                cmd = ""
            end
            if cmd == "brain" or cmd == "ae2"
                or cmd == "/usr/bin/brain" or cmd == "/usr/bin/brain.lua"
                or cmd == "/usr/bin/ae2" or cmd == "/usr/bin/ae2.lua"
                or cmd == "/home/brain/main.lua" then
                hasBrainAuto = true
            end
        end
        if not drop then
            shrcLines[#shrcLines + 1] = line
        end
    end
    if migratedShrc then
        writeWholeFile(SHRC_PATH, (#shrcLines > 0) and (table.concat(shrcLines, "\n") .. "\n") or "")
        print("[MIGRATE] Updated " .. SHRC_PATH .. ": exporter.lua -> brain")
    end
    if not isUpdate and not hasBrainAuto then
        local wantAuto
        if optAutostart ~= nil then
            wantAuto = (optAutostart == true)
        elseif optYes then
            wantAuto = true
        elseif not optNoPrompt and io.read then
            io.write("Auto-start 'brain' in /home/.shrc? [Y/n]: ")
            local line = io.read()
            wantAuto = (tostring(line or "y") .. "y"):match("^%s*[Yy]") ~= nil
        end
        if wantAuto then
            shrcLines[#shrcLines + 1] = "brain"
            writeWholeFile(SHRC_PATH, table.concat(shrcLines, "\n") .. "\n")
            print("[AUTO]    Added 'brain' to /home/.shrc")
        end
    end

    print("Done! Run 'brain' (or 'ae2') from any directory to start GTNH Mainnet Brain.")
    return true
end

return runInstaller(cliArgs)
