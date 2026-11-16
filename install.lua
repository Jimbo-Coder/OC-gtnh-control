-- /home/dtpf/install.lua
-- One-step OpenComputers Internet Card installer & updater for GTNH DTPF Controller.
-- Fresh install:
--   wget -f https://raw.githubusercontent.com/StankCIty/gtnh-dtpf-control/main/install.lua && install
-- Local / floppy install (no Internet Card needed):
--   install --local <sourceDir> [owner/repo] [branch]
-- Update existing install (preserves & backs up config.cfg):
--   dtpf --update [owner/repo] [branch]

local cliArgs = { ... }

local component = require("component")
local filesystem = require("filesystem")

local DEFAULT_REPO = "StankCIty/gtnh-dtpf-control"
local DEFAULT_BRANCH = "main"
local INSTALL_DIR = "/home/dtpf"
local CONFIG_PATH = "/home/dtpf/config.cfg"
local BACKUP_CONFIG_PATH = "/home/config.dtpf.bak"
local REPO_META_PATH = "/home/dtpf/.repo"
local BIN_PATH = "/usr/bin/dtpf.lua"

local FILES = {
    "install.lua",
    "main.lua",
    "lib/recipes_db.lua",
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
    if not f then
        return false, err
    end
    f:write(content)
    f:close()
    return true
end

local function resolveRepoAndBranch(args)
    local repo = args[1]
    local branch = args[2]
    local saved = readWholeFile(REPO_META_PATH)
    if type(saved) == "string" and saved ~= "" then
        local savedRepo, savedBranch = saved:match("^([^\r\n]+)\r?\n?([^\r\n]*)")
        if (not repo or repo == "") and savedRepo and savedRepo ~= "" then
            repo = savedRepo
        end
        if (not branch or branch == "") and savedBranch and savedBranch ~= "" then
            branch = savedBranch
        end
    end
    if not repo or repo == "" then repo = DEFAULT_REPO end
    if not branch or branch == "" then branch = DEFAULT_BRANCH end
    repo = tostring(repo):gsub("^https?://github%.com/", ""):gsub("/+$", "")
    return repo, branch
end

local function fetchUrl(internet, url)
    local req, reqErr = internet.request(url)
    if not req then
        return nil, tostring(reqErr or "request failed")
    end

    local osLib = rawget(_G, "os")
    local function briefYield()
        if type(osLib) == "table" and osLib.sleep then
            pcall(osLib.sleep, 0.05)
        end
    end

    if req.finishConnect then
        local connected = false
        for _ = 1, MAX_EMPTY_READS do
            local ok, err = req.finishConnect()
            if ok == true then
                connected = true
                break
            elseif ok == nil then
                pcall(req.close)
                return nil, tostring(err or "connection error")
            end
            briefYield()
        end
        if not connected then
            pcall(req.close)
            return nil, "connection timed out"
        end
    end

    local chunks = {}
    local emptyCount = 0
    for _ = 1, MAX_CHUNKS do
        local chunk, readErr = req.read()
        if chunk == nil then
            if readErr then
                pcall(req.close)
                return nil, tostring(readErr)
            end
            break
        elseif chunk == "" then
            emptyCount = emptyCount + 1
            if emptyCount >= MAX_EMPTY_READS then
                pcall(req.close)
                return nil, "read timed out"
            end
            briefYield()
        else
            emptyCount = 0
            chunks[#chunks + 1] = chunk
        end
    end

    local httpCode, httpMsg
    if req.response then
        httpCode, httpMsg = req.response()
    end
    pcall(req.close)

    if type(httpCode) == "number" and httpCode >= 400 then
        return nil, string.format("HTTP %d (%s)", httpCode, tostring(httpMsg or "error"))
    end

    local body = table.concat(chunks)
    if #body == 0 then
        return nil, "empty response"
    end
    return body, nil
end

local function syncSettingsBackup()
    local existingCfg = readWholeFile(CONFIG_PATH)
    if type(existingCfg) == "string" and #existingCfg > 0 then
        local ok = writeWholeFile(BACKUP_CONFIG_PATH, existingCfg)
        if ok then
            print("[KEEP]    Preserved config.cfg (backup -> " .. BACKUP_CONFIG_PATH .. ")")
        else
            print("[KEEP]    Preserved existing " .. CONFIG_PATH)
        end
        return "preserved"
    end

    local backupCfg = readWholeFile(BACKUP_CONFIG_PATH)
    if type(backupCfg) == "string" and #backupCfg > 0 then
        local ok = writeWholeFile(CONFIG_PATH, backupCfg)
        if ok then
            print("[RESTORE] Restored saved config.cfg from " .. BACKUP_CONFIG_PATH)
            return "restored"
        end
    end

    print("[NEW]     No saved config.cfg yet (first boot will start safely in PAUSED mode)")
    return "fresh"
end

local function getInternetProxy()
    local addr = component.list("internet", true)()
    if addr then
        return component.proxy(addr)
    end
    if component.isAvailable("internet") then
        return component.internet
    end
    return nil
end

local function runInstaller(args)
    args = args or {}
    local localDir = nil
    local repoArgs = args
    if args[1] == "--local" then
        localDir = tostring(args[2] or ""):gsub("/+$", "")
        if localDir == "" then
            io.stderr:write("ERROR: Usage: install --local <sourceDir> [owner/repo] [branch]\n")
            return false, "missing local source directory"
        end
        repoArgs = { args[3], args[4] }
    end

    local internet = (not localDir) and getInternetProxy() or nil
    if (not localDir) and (not internet) then
        io.stderr:write("ERROR: Internet Card required for install/update (or use `install --local <dir>`).\n")
        return false, "no internet card"
    end
    local repo, branch = resolveRepoAndBranch(repoArgs)
    local baseUrl = string.format("https://raw.githubusercontent.com/%s/%s/", repo, branch)

    print("=== GTNH DTPF AUTOMATION INSTALLER ===")
    print(string.format("Source : %s", localDir and ("local:" .. localDir) or string.format("%s (%s)", repo, branch)))
    print(string.format("Target : %s", INSTALL_DIR))
    print("")

    filesystem.makeDirectory(INSTALL_DIR)
    filesystem.makeDirectory(filesystem.concat(INSTALL_DIR, "lib"))
    filesystem.makeDirectory("/usr/bin")

    local cfgState = syncSettingsBackup()
    local staged = {}

    local function cleanupTempFiles()
        for i = 1, #staged do
            if staged[i].tmpPath then
                pcall(filesystem.remove, staged[i].tmpPath)
            end
        end
    end

    for i = 1, #FILES do
        local rel = FILES[i]
        local body, fetchErr
        if localDir then
            local srcPath = filesystem.concat(localDir, rel)
            body = readWholeFile(srcPath)
            if not body then
                fetchErr = "file not found: " .. tostring(srcPath)
            end
        else
            body, fetchErr = fetchUrl(internet, baseUrl .. rel)
        end
        if not body then
            cleanupTempFiles()
            io.stderr:write(string.format("ERROR: Failed to %s %s (%s)\n", localDir and "read" or "download", rel, tostring(fetchErr)))
            return false, fetchErr
        end

        local chunk, synErr = load(body, "@" .. rel, "t")
        if not chunk then
            cleanupTempFiles()
            io.stderr:write(string.format("ERROR: Invalid Lua in %s (%s); existing install untouched.\n", rel, tostring(synErr)))
            return false, synErr
        end

        local destPath = filesystem.concat(INSTALL_DIR, rel)
        local tmpPath = destPath .. ".tmp"
        local okW, writeErr = writeWholeFile(tmpPath, body)
        if not okW then
            cleanupTempFiles()
            io.stderr:write(string.format("ERROR: Failed writing %s (%s)\n", tmpPath, tostring(writeErr)))
            return false, writeErr
        end
        staged[#staged + 1] = { rel = rel, destPath = destPath, tmpPath = tmpPath, bytes = #body }
        print(string.format("[OK %d/%d] %-20s (%d bytes)", i, #FILES, rel, #body))
    end

    for i = 1, #staged do
        local item = staged[i]
        pcall(filesystem.remove, item.destPath)
        local okRen, renErr = filesystem.rename(item.tmpPath, item.destPath)
        if not okRen then
            local fallbackBody = readWholeFile(item.tmpPath)
            pcall(filesystem.remove, item.tmpPath)
            if fallbackBody then
                writeWholeFile(item.destPath, fallbackBody)
            else
                io.stderr:write(string.format("ERROR: Could not finalize %s (%s)\n", item.destPath, tostring(renErr)))
                return false, renErr
            end
        end
    end

    writeWholeFile(REPO_META_PATH, repo .. "\n" .. branch .. "\n")
    writeWholeFile(
        BIN_PATH,
        "local args = { ... }\n"
            .. "local chunk, err = loadfile(\"/home/dtpf/main.lua\")\n"
            .. "if not chunk then io.stderr:write(tostring(err) .. \"\\n\") return end\n"
            .. "return chunk(table.unpack(args))\n"
    )
    if filesystem.exists("/home/install.lua") then
        pcall(filesystem.remove, "/home/install.lua")
    end

    print("")
    print(string.format("Done! Installed %d files to %s (config: %s).", #staged, INSTALL_DIR, cfgState))
    print("Next steps:")
    print("  dtpf --lock    (disable autoPull on passive ME Stocking Hatches/Buses)")
    print("  dtpf --check   (read-only hardware & schedule dry-run check)")
    print("  dtpf           (launch 160x50 Touch Control Center GUI)")
    print("  dtpf --update  (update scripts safely while preserving config.cfg)")
    return true
end

return runInstaller(cliArgs)
