-- /tmp/install.lua (root monorepo selector & updater for OC-gtnh-control)
-- One-line install:
--   wget -f https://raw.githubusercontent.com/Jimbo-Coder/OC-gtnh-control/main/install.lua /tmp/install.lua && /tmp/install.lua
-- Direct module install:
--   /tmp/install.lua <dtpf|universal|ae2|pump|gorge> [--yes] [--no-autostart]
-- Update all modules installed on this computer:
--   /tmp/install.lua --update

local cliArgs = { ... }

local component = require("component")
local filesystem = require("filesystem")
local serialization = require("serialization")

local DEFAULT_REPO = "Jimbo-Coder/OC-gtnh-control"
local DEFAULT_BRANCH = "main"
local MANIFEST_PATH = "/home/.oc-gtnh.manifest"

local MODULES = {
    { key = "dtpf",      subdir = "gtnh-dtpf-control",      desc = "DTPF Control Center (Passive/OD/Catalyst Scheduler + 160x50 GUI)", detect = "/home/dtpf/main.lua" },
    { key = "universal", subdir = "gtnh-universal-control", desc = "Universal Automation (Toggle Bus + Bundled Redstone + SRTF Preempt)", detect = "/home/universal/main.lua" },
    { key = "ae2",       subdir = "gtnh-ae2-control",       desc = "AE2 Control & Hub (Influx Exporter, Craft Requester & Mesh Gateway)", detect = "/home/exporter.lua" },
    { key = "pump",      subdir = "gtnh-space-pump",        desc = "Space Elevator Pump (Target Fluid Pumping + Optional Mesh)",         detect = "/home/autoPump.lua" },
    { key = "gorge",     subdir = "gtnh-gorge-control",     desc = "Forge of the Gods & Exoticizer Control [Scaffolded / Design Only]",  detect = "/home/gorge/main.lua" },
}

local BY_KEY = {}
for i, m in ipairs(MODULES) do
    BY_KEY[m.key] = m
    BY_KEY[m.subdir] = m
    BY_KEY[tostring(i)] = m
end

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

local function loadManifest()
    local raw = readWholeFile(MANIFEST_PATH)
    local m = { repo = DEFAULT_REPO, branch = DEFAULT_BRANCH, modules = {} }
    if type(raw) == "string" and #raw > 0 then
        local ok, tbl = pcall(serialization.unserialize, raw)
        if ok and type(tbl) == "table" then
            m.repo = (type(tbl.repo) == "string" and tbl.repo ~= "") and tbl.repo or DEFAULT_REPO
            m.branch = (type(tbl.branch) == "string" and tbl.branch ~= "") and tbl.branch or DEFAULT_BRANCH
            if type(tbl.modules) == "table" then
                for k, v in pairs(tbl.modules) do
                    if v then m.modules[k] = true end
                end
            end
        end
    end
    -- Also detect any pre-existing modules installed prior to monorepo manifest
    for _, spec in ipairs(MODULES) do
        if spec.detect and filesystem.exists(spec.detect) then
            m.modules[spec.key] = true
        end
    end
    return m
end

local function saveManifest(m)
    return writeWholeFile(MANIFEST_PATH, serialization.serialize(m))
end

local function runSubInstaller(spec, manifest, localDir, extraFlags)
    local subBody, err
    local passArgs = {}
    if localDir then
        local subDir = filesystem.concat(localDir, spec.subdir)
        local subPath = filesystem.concat(subDir, "install.lua")
        subBody = readWholeFile(subPath)
        err = subBody and nil or ("Not found: " .. subPath)
        passArgs[#passArgs + 1] = "--local"
        passArgs[#passArgs + 1] = subDir
    else
        local addr = component.list("internet", true)()
        local internet = addr and component.proxy(addr) or (component.isAvailable("internet") and component.internet or nil)
        if not internet then
            return false, "Internet Card required (or use --local <dir>)"
        end
        local url = string.format("https://raw.githubusercontent.com/%s/%s/%s/install.lua",
            manifest.repo, manifest.branch, spec.subdir)
        subBody, err = fetchUrl(internet, url)
    end
    if not subBody then
        io.stderr:write(string.format("ERROR: Could not load %s/install.lua (%s)\n", spec.subdir, tostring(err)))
        return false, err
    end
    local chunk, synErr = load(subBody, "@" .. spec.subdir .. "/install.lua", "t")
    if not chunk then
        io.stderr:write(string.format("ERROR: Invalid Lua in %s/install.lua: %s\n", spec.subdir, tostring(synErr)))
        return false, synErr
    end

    passArgs[#passArgs + 1] = "--repo"
    passArgs[#passArgs + 1] = manifest.repo
    passArgs[#passArgs + 1] = "--branch"
    passArgs[#passArgs + 1] = manifest.branch
    for _, f in ipairs(extraFlags) do
        passArgs[#passArgs + 1] = f
    end

    local ok = chunk(table.unpack(passArgs))
    if ok ~= false and spec.key ~= "gorge" then
        manifest.modules[spec.key] = true
        saveManifest(manifest)
    end
    return ok ~= false
end

local function main(args)
    args = args or {}
    local manifest = loadManifest()
    local localDir = nil
    local isList, isUpdate = false, false
    local chosen = {}
    local forwardFlags = {}
    local idx = 1

    while idx <= #args do
        local a = tostring(args[idx])
        if a == "--list" or a == "-l" then
            isList = true
        elseif a == "--local" then
            idx = idx + 1
            localDir = tostring(args[idx] or ""):gsub("/+$", "")
        elseif a == "--repo" then
            idx = idx + 1
            if args[idx] then manifest.repo = tostring(args[idx]) end
        elseif a == "--branch" then
            idx = idx + 1
            if args[idx] then manifest.branch = tostring(args[idx]) end
        elseif a == "--update" then
            isUpdate = true
            forwardFlags[#forwardFlags + 1] = "--update"
        elseif a == "--yes" or a == "-y" or a == "--no-prompt" or a == "--autostart" or a == "--no-autostart" then
            forwardFlags[#forwardFlags + 1] = a
        elseif BY_KEY[a] then
            chosen[#chosen + 1] = BY_KEY[a]
        else
            io.stderr:write("Unknown option or module: " .. a .. "\n")
            return false
        end
        idx = idx + 1
    end

    if isList then
        print("=== OC-GTNH-CONTROL MODULES ===")
        for i, m in ipairs(MODULES) do
            local tag = manifest.modules[m.key] and "[INSTALLED]" or "[         ]"
            print(string.format("  [%d] %-10s %s %s", i, m.key, tag, m.desc))
        end
        return true
    end

    if isUpdate then
        local targets = (#chosen > 0) and chosen or {}
        if #targets == 0 then
            for _, m in ipairs(MODULES) do
                if manifest.modules[m.key] and m.key ~= "gorge" then
                    targets[#targets + 1] = m
                end
            end
        end
        if #targets == 0 then
            print("No installed OC-gtnh-control modules found on this computer.")
            return true
        end
        local allOk = true
        for _, m in ipairs(targets) do
            print("")
            local ok = runSubInstaller(m, manifest, localDir, forwardFlags)
            if not ok then allOk = false end
        end
        return allOk
    end

    if #chosen == 0 then
        print("=== OC-GTNH-CONTROL INSTALLER ===")
        for i, m in ipairs(MODULES) do
            local tag = manifest.modules[m.key] and "[INSTALLED]" or "[         ]"
            print(string.format("  [%d] %-10s %s %s", i, m.key, tag, m.desc))
        end
        print("  [u] update     Update all installed modules on this computer")
        io.write("Select module (1-5 / name / u): ")
        if io.flush then pcall(io.flush) end
        local line = io.read and io.read() or ""
        line = tostring(line or ""):match("^%s*(.-)%s*$")
        if line == "u" or line == "update" then
            return main({ "--update" })
        elseif BY_KEY[line] then
            chosen[1] = BY_KEY[line]
        else
            io.stderr:write("No valid module selected.\n")
            return false
        end
    end

    local allOk = true
    for _, spec in ipairs(chosen) do
        local ok = runSubInstaller(spec, manifest, localDir, forwardFlags)
        if not ok then allOk = false end
    end
    return allOk
end

return main(cliArgs)
