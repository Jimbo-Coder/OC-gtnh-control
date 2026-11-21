-- /home/stock/install.lua
-- One-step OpenComputers installer & updater for GTNH Stock Maintainer (`gtnh-stock-control`).
-- Installs into /home/stock/ and /usr/bin/stock.lua while preserving config.cfg.

local cliArgs = { ... }

local component = require("component")
local filesystem = require("filesystem")

local DEFAULT_REPO = "Jimbo-Coder/OC-gtnh-control"
local SUBDIR = "gtnh-stock-control"
local DEFAULT_BRANCH = "main"
local INSTALL_DIR = "/home/stock"
local CONFIG_PATH = "/home/stock/config.cfg"
local BACKUP_CONFIG_PATH = "/home/config.stock.bak"
local REPO_META_PATH = "/home/stock/.repo"
local BIN_PATH = "/usr/bin/stock.lua"
local SHRC_PATH = "/home/.shrc"

local FILES = {
    "install.lua",
    "main.lua",
    "lib/dtpf_catalog.lua",
    "lib/hardware.lua",
    "lib/scheduler.lua",
    "lib/ui.lua",
}

local MAX_CHUNKS = 4096
local MAX_EMPTY_READS = 200

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

local function resolveRepoAndBranch(repoArg, branchArg)
    local repo, branch = repoArg, branchArg
    local saved = readWholeFile(REPO_META_PATH)
    if type(saved) == "string" and saved ~= "" then
        local savedRepo, savedBranch = saved:match("^([^\r\n]+)\r?\n?([^\r\n]*)")
        if (not repo or repo == "") and savedRepo and savedRepo ~= "" then repo = savedRepo end
        if (not branch or branch == "") and savedBranch and savedBranch ~= "" then branch = savedBranch end
    end
    if not repo or repo == "" then repo = DEFAULT_REPO end
    if not branch or branch == "" then branch = DEFAULT_BRANCH end
    repo = tostring(repo):gsub("/+$", "")
    if not repo:match("^https?://") then
        repo = repo:gsub("^https?://github%.com/", "")
    end
    return repo, branch
end

local function fetchUrl(internet, url)
    local req, reqErr = internet.request(url)
    if not req then return nil, tostring(reqErr or "request failed") end
    local osLib = rawget(_G, "os")
    local function briefYield()
        if type(osLib) == "table" and osLib.sleep then pcall(osLib.sleep, 0.05) end
    end
    if req.finishConnect then
        local connected = false
        for _ = 1, MAX_EMPTY_READS do
            local ok, err = req.finishConnect()
            if ok == true then connected = true; break
            elseif ok == nil then pcall(req.close); return nil, tostring(err or "connection error")
            end
            briefYield()
        end
        if not connected then pcall(req.close); return nil, "connection timed out" end
    end
    local chunks, emptyCount = {}, 0
    for _ = 1, MAX_CHUNKS do
        local chunk, readErr = req.read()
        if chunk == nil then
            if readErr then pcall(req.close); return nil, tostring(readErr) end
            break
        elseif chunk == "" then
            emptyCount = emptyCount + 1
            if emptyCount >= MAX_EMPTY_READS then pcall(req.close); return nil, "read timed out" end
            briefYield()
        else
            emptyCount = 0
            chunks[#chunks + 1] = chunk
        end
    end
    local httpCode, httpMsg = nil, nil
    if req.response then httpCode, httpMsg = req.response() end
    pcall(req.close)
    if type(httpCode) == "number" and httpCode >= 400 then
        return nil, string.format("HTTP %d (%s)", httpCode, tostring(httpMsg or "error"))
    end
    local body = table.concat(chunks)
    if #body == 0 then return nil, "empty response" end
    return body, nil
end

local function syncSettingsBackup()
    local existing = readWholeFile(CONFIG_PATH)
    if type(existing) == "string" and #existing > 0 then
        if writeWholeFile(BACKUP_CONFIG_PATH, existing) then
            print("[KEEP]    Preserved config.cfg (backup -> " .. BACKUP_CONFIG_PATH .. ")")
        else
            print("[KEEP]    Preserved existing " .. CONFIG_PATH)
        end
        return "preserved"
    end
    local bak = readWholeFile(BACKUP_CONFIG_PATH)
    if type(bak) == "string" and #bak > 0 and writeWholeFile(CONFIG_PATH, bak) then
        print("[RESTORE] Restored saved config.cfg from " .. BACKUP_CONFIG_PATH)
        return "restored"
    end
    print("[NEW]     No saved config.cfg yet (first boot starts safely in PAUSED mode)")
    return "fresh"
end

local function hasEntryInShrc(content)
    if type(content) ~= "string" or content == "" then return false end
    for line in content:gmatch("[^\r\n]+") do
        if not line:match("^%s*#") then
            if line:find("/home/stock/main.lua", 1, true)
                or line:find("/usr/bin/stock", 1, true)
                or line:match("^%s*stock%s*$")
                or line:match("^%s*stock%s+") then
                return true
            end
        end
    end
    return false
end

local function askYesNo(promptText, defaultVal, optYes, optNoPrompt)
    if optYes then return true end
    if optNoPrompt then return defaultVal end
    if type(io) ~= "table" or type(io.read) ~= "function" then return defaultVal end
    if type(io.write) == "function" then
        io.write(promptText)
        if type(io.flush) == "function" then pcall(io.flush) end
    else
        print(promptText)
    end
    local okR, line = pcall(io.read)
    if not okR or line == nil or line == false then return false end
    return (tostring(line) .. "y"):match("^%s*[Yy]") ~= nil
end

local _meshReqSeq = 0
local function fetchViaMesh(fullUrl, meshTarget)
    local okEv, evLib = pcall(require, "event")
    local okSer, serLib = pcall(require, "serialization")
    local okComp, compLib = pcall(require, "computer")
    if (not okEv or not evLib or not evLib.pull)
        or (not okSer or not serLib or not serLib.serialize or not serLib.unserialize) then
        return nil, "OpenOS event/serialization required for mesh relay"
    end
    local mAddr = component.list("modem", true)()
    local modem = (mAddr and component.proxy(mAddr)) or (component.isAvailable("modem") and component.modem or nil)
    local tAddr = component.list("tunnel", true)()
    local tunnel = (tAddr and component.proxy(tAddr)) or (component.isAvailable("tunnel") and component.tunnel or nil)
    if not modem and not tunnel then
        return nil, "No modem or tunnel card for mesh relay"
    end
    local MESH_PORT = 4205
    if modem and modem.open then pcall(modem.open, MESH_PORT) end

    _meshReqSeq = _meshReqSeq + 1
    local uptimeFn = (okComp and compLib and compLib.uptime) or function() return os.clock() end
    local reqId = string.format("ota_%d_%d", math.floor(uptimeFn() * 1000), _meshReqSeq)
    local payload = serLib.serialize({ id = reqId, url = fullUrl })

    local sent = false
    if type(meshTarget) == "string" and meshTarget ~= "" and meshTarget ~= "tunnel" and modem and modem.send then
        sent = pcall(modem.send, meshTarget, MESH_PORT, "MESH_HTTP_GET", payload)
    end
    if not sent then
        if modem and modem.broadcast then
            sent = pcall(modem.broadcast, MESH_PORT, "MESH_HTTP_GET", payload) or sent
        end
        if tunnel and tunnel.send then
            sent = pcall(tunnel.send, "MESH_HTTP_GET", payload) or sent
        end
    end
    if not sent then
        return nil, "Failed to transmit MESH_HTTP_GET"
    end

    local chunks, eofSeq = {}, nil
    local deadline = uptimeFn() + 25.0
    while uptimeFn() < deadline do
        local rem = math.max(0.1, math.min(2.0, deadline - uptimeFn()))
        local evName, _, _, _, _, msgType, rawBody = evLib.pull(rem, "modem_message")
        if evName == "modem_message" then
            local pkt = (type(rawBody) == "table") and rawBody or nil
            if (not pkt) and type(rawBody) == "string" then
                local okU, dec = pcall(serLib.unserialize, rawBody)
                if okU and type(dec) == "table" then pkt = dec end
            end
            if type(pkt) == "table" and tostring(pkt.id or "") == reqId then
                if msgType == "MESH_HTTP_ERR" then
                    return nil, tostring(pkt.error or "mesh relay error")
                elseif msgType == "MESH_HTTP_CHUNK" then
                    local seq = tonumber(pkt.seq) or (#chunks + 1)
                    chunks[seq] = tostring(pkt.data or "")
                    deadline = uptimeFn() + 15.0
                    if pkt.eof then
                        eofSeq = seq
                        break
                    end
                end
            end
        end
    end
    if not eofSeq then
        return nil, "mesh relay timeout"
    end
    for k = 1, eofSeq do
        if chunks[k] == nil then
            return nil, "incomplete mesh relay transfer"
        end
    end
    local body = table.concat(chunks, "", 1, eofSeq)
    if #body == 0 then return nil, "empty response" end
    return body
end

local function runInstaller(args)
    args = args or {}
    local pos = {}
    local localDir, optRepo, optBranch = nil, nil, nil
    local isUpdate, optYes, optNoPrompt = false, false, false
    local optAutostart = nil
    local optMeshRelay, meshTarget = false, nil
    local idx = 1
    while idx <= #args do
        local a = tostring(args[idx])
        if a == "--local" then
            idx = idx + 1
            localDir = tostring(args[idx] or ""):gsub("/+$", "")
            if localDir == "" then
                io.stderr:write("ERROR: Usage: install --local <sourceDir> [owner/repo] [branch]\n")
                return false, "missing local source directory"
            end
        elseif a == "--url" then idx = idx + 1; optRepo = tostring(args[idx] or ""):gsub("/+$", "")
        elseif a == "--local-bridge" then optRepo = "http://127.0.0.1:8765/oc-raw"
        elseif a == "--repo" then idx = idx + 1; optRepo = tostring(args[idx] or "")
        elseif a == "--branch" then idx = idx + 1; optBranch = tostring(args[idx] or "")
        elseif a == "--mesh-relay" then optMeshRelay = true
        elseif a == "--mesh-target" then idx = idx + 1; meshTarget = tostring(args[idx] or "")
        elseif a == "--update" then isUpdate = true
        elseif a == "--yes" or a == "-y" then optYes = true
        elseif a == "--no-prompt" then optNoPrompt = true
        elseif a == "--autostart" then optAutostart = true
        elseif a == "--no-autostart" then optAutostart = false
        else pos[#pos + 1] = a
        end
        idx = idx + 1
    end

    if localDir and not filesystem.exists(filesystem.concat(localDir, "main.lua")) then
        local monorepoSub = filesystem.concat(localDir, SUBDIR)
        if filesystem.exists(filesystem.concat(monorepoSub, "main.lua")) then
            localDir = monorepoSub
        end
    end

    local internet = nil
    local hasMesh = false
    if not localDir then
        local addr = component.list("internet", true)()
        internet = addr and component.proxy(addr) or (component.isAvailable("internet") and component.internet or nil)
        hasMesh = (component.list("modem", true)() ~= nil) or (component.list("tunnel", true)() ~= nil)
            or component.isAvailable("modem") or component.isAvailable("tunnel")
        if not internet and not (optMeshRelay or hasMesh) then
            io.stderr:write("ERROR: Internet Card or Mesh Modem required (or use `install --local <dir>`).\n")
            return false, "no internet card"
        end
    end
    local useMesh = (not localDir) and (optMeshRelay or (not internet and hasMesh))

    local repo, branch = resolveRepoAndBranch(optRepo or pos[1], optBranch or pos[2])
    local baseUrl
    if repo:match("^https?://") then
        local clean = repo:gsub("/+$", "")
        baseUrl = (clean:sub(-#SUBDIR) == SUBDIR) and (clean .. "/") or (clean .. "/" .. SUBDIR .. "/")
    else
        baseUrl = string.format("https://raw.githubusercontent.com/%s/%s/%s/", repo, branch, SUBDIR)
    end

    print("=== GTNH STOCK MAINTAINER INSTALLER ===")
    print(string.format("Source : %s", localDir and ("local:" .. localDir) or ((useMesh and "mesh:" or "") .. string.format("%s (%s/%s)", repo, branch, SUBDIR))))
    print(string.format("Target : %s", INSTALL_DIR))
    print("")

    filesystem.makeDirectory(INSTALL_DIR)
    filesystem.makeDirectory(filesystem.concat(INSTALL_DIR, "lib"))
    filesystem.makeDirectory("/usr/bin")

    local cfgState = syncSettingsBackup()
    local staged = {}

    local function cleanupTemp()
        for i = 1, #staged do
            if staged[i].tmpPath then pcall(filesystem.remove, staged[i].tmpPath) end
        end
    end

    for i = 1, #FILES do
        local rel = FILES[i]
        local body, fetchErr
        if localDir then
            local srcPath = filesystem.concat(localDir, rel)
            body = readWholeFile(srcPath)
            if not body then fetchErr = "file not found: " .. tostring(srcPath) end
        elseif useMesh then
            body, fetchErr = fetchViaMesh(baseUrl .. rel, meshTarget)
        else
            body, fetchErr = fetchUrl(internet, baseUrl .. rel)
        end
        if not body then
            cleanupTemp()
            io.stderr:write(string.format("ERROR: Failed to %s %s (%s)\n", localDir and "read" or "download", rel, tostring(fetchErr)))
            return false, fetchErr
        end
        local chunk, synErr = load(body, "@" .. rel, "t")
        if not chunk then
            cleanupTemp()
            io.stderr:write(string.format("ERROR: Invalid Lua in %s (%s); existing install untouched.\n", rel, tostring(synErr)))
            return false, synErr
        end
        local destPath = filesystem.concat(INSTALL_DIR, rel)
        local tmpPath = destPath .. ".tmp"
        local okW, writeErr = writeWholeFile(tmpPath, body)
        if not okW then
            cleanupTemp()
            io.stderr:write(string.format("ERROR: Failed writing %s (%s)\n", tmpPath, tostring(writeErr)))
            return false, writeErr
        end
        staged[#staged + 1] = { rel = rel, destPath = destPath, tmpPath = tmpPath, bytes = #body }
        print(string.format("[OK %d/%d] %-20s (%d bytes)", i, #FILES, rel, #body))
    end

    for i = 1, #staged do
        local item = staged[i]
        pcall(filesystem.remove, item.destPath)
        local okRen = filesystem.rename(item.tmpPath, item.destPath)
        if not okRen then
            local fallbackBody = readWholeFile(item.tmpPath)
            pcall(filesystem.remove, item.tmpPath)
            if fallbackBody then writeWholeFile(item.destPath, fallbackBody) end
        end
    end

    writeWholeFile(REPO_META_PATH, repo .. "\n" .. branch .. "\n")

    local binExisted = filesystem.exists(BIN_PATH)
    local wantAlias = binExisted or (not isUpdate and askYesNo("Add 'stock' shell command (/usr/bin/stock.lua)? [Y/n]: ", true, optYes, optNoPrompt))
    if wantAlias then
        writeWholeFile(BIN_PATH,
            "local args = { ... }\n"
            .. "local chunk, err = loadfile(\"/home/stock/main.lua\")\n"
            .. "if not chunk then io.stderr:write(tostring(err) .. \"\\n\") return end\n"
            .. "return chunk(table.unpack(args))\n")
        if not binExisted then print("[CMD]     Added 'stock' command (/usr/bin/stock.lua)") end
    end

    local existingShrc = readWholeFile(SHRC_PATH)
    if not isUpdate and not hasEntryInShrc(existingShrc) then
        local baseCmd = wantAlias and "stock" or "/home/stock/main.lua"
        local hasDisplay = (component.list("screen", true)() ~= nil) and (component.list("gpu", true)() ~= nil)
        local autoCmd = hasDisplay and baseCmd or (baseCmd .. " --worker")
        local wantAuto = (optAutostart ~= nil) and optAutostart or askYesNo(
            string.format("Auto-start on boot in /home/.shrc (%s)? [Y/n]: ", autoCmd), true, optYes, optNoPrompt)
        if wantAuto then
            local prefix = (type(existingShrc) == "string" and existingShrc ~= "") and existingShrc or ""
            if prefix ~= "" and prefix:sub(-1) ~= "\n" then prefix = prefix .. "\n" end
            writeWholeFile(SHRC_PATH, prefix .. autoCmd .. "\n")
            print(string.format("[AUTO]    Added '%s' to /home/.shrc", autoCmd))
        else
            print("[SKIP]    Skipped /home/.shrc auto-start")
        end
    end

    print("")
    print(string.format("Done! Installed %d files to %s (config: %s).", #FILES, INSTALL_DIR, cfgState))
    local cmdName = wantAlias and "stock" or "/home/stock/main.lua"
    print("Next steps:")
    print("  " .. cmdName .. " --check   (read-only AE2 O(1) dry-run check)")
    print("  " .. cmdName .. " --bench   (benchmark O(1) vs legacy & physical maintainers)")
    print("  " .. cmdName .. "           (launch 160x50 Touch Control Center)")
    return true
end

return runInstaller(cliArgs)
