-- /home/qft/install.lua
-- One-step OpenComputers installer & updater for GTNH QFT Control (`gtnh-qft-control`).
-- Installs into /home/qft/ and /usr/bin/qft.lua while preserving config.cfg.

local cliArgs = { ... }

local component = require("component")
local filesystem = require("filesystem")

local DEFAULT_REPO = "Jimbo-Coder/OC-gtnh-control"
local SUBDIR = "gtnh-qft-control"
local DEFAULT_BRANCH = "main"
local INSTALL_DIR = "/home/qft"
local CONFIG_PATH = "/home/qft/config.cfg"
local BACKUP_CONFIG_PATH = "/home/config.qft.bak"
local REPO_META_PATH = "/home/qft/.repo"
local BIN_PATH = "/usr/bin/qft.lua"
local SHRC_PATH = "/home/.shrc"

local FILES = {
    "install.lua",
    "main.lua",
    "lib/recipes_db.lua",
    "lib/hardware.lua",
    "lib/scheduler.lua",
    "lib/ui.lua",
}

local function readWholeFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local d = f:read("*a"); f:close(); return d
end

local function writeWholeFile(path, content)
    local parent = filesystem.path(path)
    if parent and parent ~= "" and not filesystem.exists(parent) then filesystem.makeDirectory(parent) end
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(content); f:close(); return true
end

local function fetchUrl(internet, url)
    local req, err = internet.request(url)
    if not req then return nil, tostring(err or "request failed") end
    local osLib = rawget(_G, "os")
    local function briefYield() if type(osLib) == "table" and osLib.sleep then pcall(osLib.sleep, 0.05) end end
    if req.finishConnect then
        local ok = false
        for _ = 1, 200 do
            local done, ferr = req.finishConnect()
            if done == true then ok = true; break elseif done == nil then pcall(req.close); return nil, tostring(ferr) end
            briefYield()
        end
        if not ok then pcall(req.close); return nil, "connect timeout" end
    end
    local chunks, empty = {}, 0
    for _ = 1, 4096 do
        local ch, rErr = req.read()
        if ch == nil then if rErr then pcall(req.close); return nil, tostring(rErr) end break
        elseif ch == "" then empty = empty + 1; if empty >= 200 then pcall(req.close); return nil, "read timeout" end briefYield()
        else empty = 0; chunks[#chunks + 1] = ch end
    end
    local code = req.response and req.response() or nil
    pcall(req.close)
    if type(code) == "number" and code >= 400 then return nil, "HTTP " .. tostring(code) end
    local body = table.concat(chunks)
    if #body == 0 then return nil, "empty response" end
    return body
end

local function syncSettingsBackup()
    local existing = readWholeFile(CONFIG_PATH)
    if type(existing) == "string" and #existing > 0 then
        writeWholeFile(BACKUP_CONFIG_PATH, existing)
        return "preserved"
    end
    local bak = readWholeFile(BACKUP_CONFIG_PATH)
    if type(bak) == "string" and #bak > 0 and writeWholeFile(CONFIG_PATH, bak) then return "restored" end
    return "fresh"
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
    local localDir, optRepo, optBranch = nil, nil, nil
    local isUpdate, optYes, optNoPrompt, optAutostart = false, false, false, nil
    local optMeshRelay, meshTarget = false, nil
    local i = 1
    while i <= #(args or {}) do
        local a = tostring(args[i])
        if a == "--local" then i = i + 1; localDir = tostring(args[i] or ""):gsub("/+$", "")
        elseif a == "--url" then i = i + 1; optRepo = tostring(args[i] or ""):gsub("/+$", "")
        elseif a == "--local-bridge" then optRepo = "http://127.0.0.1:8765/oc-raw"
        elseif a == "--repo" then i = i + 1; optRepo = tostring(args[i] or "")
        elseif a == "--branch" then i = i + 1; optBranch = tostring(args[i] or "")
        elseif a == "--mesh-relay" then optMeshRelay = true
        elseif a == "--mesh-target" then i = i + 1; meshTarget = tostring(args[i] or "")
        elseif a == "--update" then isUpdate = true
        elseif a == "--yes" or a == "-y" then optYes = true
        elseif a == "--no-prompt" then optNoPrompt = true
        elseif a == "--autostart" then optAutostart = true
        elseif a == "--no-autostart" then optAutostart = false end
        i = i + 1
    end
    local origLocalDir = localDir
    if localDir and not filesystem.exists(filesystem.concat(localDir, "main.lua")) then
        local sub = filesystem.concat(localDir, SUBDIR)
        if filesystem.exists(filesystem.concat(sub, "main.lua")) then localDir = sub end
    end
    local internet = nil
    local hasMesh = false
    if not localDir then
        local addr = component.list("internet", true)()
        internet = addr and component.proxy(addr) or (component.isAvailable("internet") and component.internet or nil)
        hasMesh = (component.list("modem", true)() ~= nil) or (component.list("tunnel", true)() ~= nil)
            or component.isAvailable("modem") or component.isAvailable("tunnel")
        if not internet and not (optMeshRelay or hasMesh) then
            io.stderr:write("ERROR: Internet Card or Mesh Modem required.\n")
            return false, "no internet"
        end
    end
    local useMesh = (not localDir) and (optMeshRelay or (not internet and hasMesh))
    local saved = readWholeFile(REPO_META_PATH)
    if (not optRepo or optRepo == "") and type(saved) == "string" then
        optRepo, optBranch = saved:match("^([^\r\n]+)\r?\n?([^\r\n]*)")
    end
    local repo = (optRepo and optRepo ~= "") and optRepo or DEFAULT_REPO
    local branch = (optBranch and optBranch ~= "") and optBranch or DEFAULT_BRANCH
    local baseUrl, repoRootUrl
    if repo:match("^https?://") then
        local clean = repo:gsub("/+$", "")
        if clean:sub(-#SUBDIR) == SUBDIR then
            baseUrl = clean .. "/"
            repoRootUrl = clean:sub(1, -(#SUBDIR + 1)):gsub("/+$", "") .. "/"
        else
            baseUrl = clean .. "/" .. SUBDIR .. "/"
            repoRootUrl = clean .. "/"
        end
    else
        baseUrl = string.format("https://raw.githubusercontent.com/%s/%s/%s/", repo, branch, SUBDIR)
        repoRootUrl = string.format("https://raw.githubusercontent.com/%s/%s/", repo, branch)
    end

    filesystem.makeDirectory(INSTALL_DIR)
    filesystem.makeDirectory(filesystem.concat(INSTALL_DIR, "lib"))
    filesystem.makeDirectory("/usr/lib")
    filesystem.makeDirectory("/usr/bin")
    local cfgState = syncSettingsBackup()
    local staged = {}
    do
        local commonBody, err
        if localDir then
            for _, cp in ipairs({
                origLocalDir and filesystem.concat(origLocalDir, "common/gtnh_common.lua") or nil,
                filesystem.concat(filesystem.path(localDir), "common/gtnh_common.lua"),
                filesystem.concat(localDir, "common/gtnh_common.lua"),
            }) do
                if cp then
                    local b = readWholeFile(cp)
                    if b then commonBody = b; break end
                end
            end
            if not commonBody then err = "missing common/gtnh_common.lua" end
        elseif useMesh then
            commonBody, err = fetchViaMesh(repoRootUrl .. "common/gtnh_common.lua", meshTarget)
        else
            commonBody, err = fetchUrl(internet, repoRootUrl .. "common/gtnh_common.lua")
        end
        if not commonBody or not load(commonBody, "@common/gtnh_common.lua", "t") then
            io.stderr:write("ERROR: QFT install failed at common/gtnh_common.lua: " .. tostring(err or "syntax") .. "\n")
            return false, err or "syntax"
        end
        local dst = "/usr/lib/gtnh_common.lua"
        local tmp = dst .. ".tmp"
        writeWholeFile(tmp, commonBody)
        staged[#staged + 1] = { dst = dst, tmp = tmp }
    end
    for _, rel in ipairs(FILES) do
        local body, err
        if localDir then
            body = readWholeFile(filesystem.concat(localDir, rel))
            if not body then err = "missing " .. rel end
        elseif useMesh then
            body, err = fetchViaMesh(baseUrl .. rel, meshTarget)
        else
            body, err = fetchUrl(internet, baseUrl .. rel)
        end
        if not body or not load(body, "@" .. rel, "t") then
            for _, s in ipairs(staged) do pcall(filesystem.remove, s.tmp) end
            io.stderr:write("ERROR: QFT install failed at " .. rel .. ": " .. tostring(err or "syntax") .. "\n")
            return false, err or "syntax"
        end
        local dst = filesystem.concat(INSTALL_DIR, rel)
        local tmp = dst .. ".tmp"
        writeWholeFile(tmp, body)
        staged[#staged + 1] = { dst = dst, tmp = tmp }
    end
    for _, s in ipairs(staged) do
        pcall(filesystem.remove, s.dst)
        if not filesystem.rename(s.tmp, s.dst) then
            local b = readWholeFile(s.tmp); pcall(filesystem.remove, s.tmp)
            if b then writeWholeFile(s.dst, b) end
        end
    end
    writeWholeFile(REPO_META_PATH, repo .. "\n" .. branch .. "\n")
    writeWholeFile(BIN_PATH, "local args = { ... }\nlocal c, e = loadfile(\"/home/qft/main.lua\")\nif not c then error(e) end\nreturn c(table.unpack(args))\n")
    if (not isUpdate) and optAutostart == true then
        local sh = readWholeFile(SHRC_PATH) or ""
        if not sh:find("qft", 1, true) then
            writeWholeFile(SHRC_PATH, ((sh ~= "" and sh:sub(-1) ~= "\n") and (sh .. "\n") or sh) .. "qft\n")
        end
    end
    print(string.format("Installed %d files to %s (config: %s).", #FILES, INSTALL_DIR, cfgState))
    return true
end

return runInstaller(cliArgs)
