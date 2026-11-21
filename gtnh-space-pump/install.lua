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
local BIN_PATH = "/usr/bin/pump.lua"
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
    local localDir, optRepo, optBranch, optUrl = nil, nil, nil, nil
    local isUpdate, optYes, optNoPrompt, optAutostart = false, false, false, nil
    local optMeshRelay, meshTarget = false, nil
    local idx = 1
    while idx <= #args do
        local a = tostring(args[idx])
        if a == "--local" then idx = idx + 1; localDir = tostring(args[idx] or ""):gsub("/+$", "")
        elseif a == "--url" then idx = idx + 1; optUrl = tostring(args[idx] or ""):gsub("/+$", "")
        elseif a == "--local-bridge" then optUrl = "http://127.0.0.1:8765/oc-raw"
        elseif a == "--repo" then idx = idx + 1; optRepo = tostring(args[idx] or "")
        elseif a == "--branch" then idx = idx + 1; optBranch = tostring(args[idx] or "")
        elseif a == "--mesh-relay" then optMeshRelay = true
        elseif a == "--mesh-target" then idx = idx + 1; meshTarget = tostring(args[idx] or "")
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
    local hasMesh = false
    if not localDir then
        local addr = component.list("internet", true)()
        internet = addr and component.proxy(addr) or (component.isAvailable("internet") and component.internet or nil)
        hasMesh = (component.list("modem", true)() ~= nil) or (component.list("tunnel", true)() ~= nil)
            or component.isAvailable("modem") or component.isAvailable("tunnel")
        if not internet and not (optMeshRelay or hasMesh) then
            io.stderr:write("ERROR: Internet Card or Mesh Modem required (or use --local <dir>).\n")
            return false, "no internet card"
        end
    end
    local useMesh = (not localDir) and (optMeshRelay or (not internet and hasMesh))

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
    local function getRemoteFile(rel)
        if useMesh then return fetchViaMesh(baseUrl .. rel, meshTarget) end
        return fetchUrl(internet, baseUrl .. rel)
    end
    local body, err
    if localDir then
        body = readWholeFile(filesystem.concat(localDir, "autoPump.lua"))
        err = body and nil or "missing autoPump.lua"
    else
        body, err = getRemoteFile("autoPump.lua")
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
    filesystem.makeDirectory("/usr/bin")
    writeWholeFile(BIN_PATH, "local args = { ... }\nlocal c, e = loadfile(\"/home/autoPump.lua\")\nif not c then error(e) end\nreturn c(table.unpack(args))\n")
    local instBody = localDir and readWholeFile(filesystem.concat(localDir, "install.lua")) or select(1, getRemoteFile("install.lua"))
    if instBody and load(instBody, "@install_pump.lua", "t") then
        writeWholeFile("/home/install_pump.lua", instBody)
    end
    writeWholeFile(REPO_META_PATH, repoMeta .. "\n" .. branch .. "\n")
    print(string.format("[OK 1/1] %s (%d bytes)", DEST_PATH, #body))

    local existingShrc = readWholeFile(SHRC_PATH) or ""
    local shrcLines, migratedShrc, hasPumpAuto = {}, false, false
    for line in existingShrc:gmatch("[^\r\n]+") do
        local isComment = line:match("^%s*#") ~= nil
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        if (not isComment) and trimmed ~= "" then
            local cmd, rest = trimmed:match("^(%S+)(.*)$")
            rest = rest or ""
            if cmd == "/home/autoPump.lua" or cmd == "autoPump" or cmd == "autoPump.lua" then
                line = "pump" .. rest
                migratedShrc = true
                cmd = "pump"
            end
            if cmd == "pump" or cmd == "/usr/bin/pump" or cmd == "/usr/bin/pump.lua" then
                hasPumpAuto = true
            end
        end
        shrcLines[#shrcLines + 1] = line
    end
    if migratedShrc then
        writeWholeFile(SHRC_PATH, table.concat(shrcLines, "\n") .. "\n")
        print("[MIGRATE] Updated " .. SHRC_PATH .. ": autoPump.lua -> pump")
    end
    if not isUpdate and not hasPumpAuto then
        local wantAuto
        if optAutostart ~= nil then
            wantAuto = (optAutostart == true)
        elseif optYes then
            wantAuto = true
        elseif not optNoPrompt and io.read then
            io.write("Auto-start 'pump' in /home/.shrc? [Y/n]: ")
            local line = io.read()
            wantAuto = (tostring(line or "y") .. "y"):match("^%s*[Yy]") ~= nil
        end
        if wantAuto then
            shrcLines[#shrcLines + 1] = "pump"
            writeWholeFile(SHRC_PATH, table.concat(shrcLines, "\n") .. "\n")
            print("[AUTO]    Added 'pump' to /home/.shrc")
        end
    end

    print("Done! Run 'pump' from any directory (set `enableMesh = false` in /home/autoPump.lua for standalone).")
    return true
end

return runInstaller(cliArgs)
