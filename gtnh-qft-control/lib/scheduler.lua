-- /home/qft/lib/scheduler.lua
-- GTNH Quantum Force Transformer (QFT) Fleet Scheduler & Recipe-Input Maintainer:
--   - Manages 1..N QFT multiblocks (1-block Ctrl, 2-block Ctrl+Bus, 3-block Ctrl+Bus+Hatch)
--   - Auto-selects focus circuit (#1..#N) by lowest-fill recipe output and enforces
--     plasma-voiding safety (never removes Np/Fm plasma or swaps circuit while active)
--   - Dispatches recipe inputs to Mainnet Stock Maintainer when online (with origin tags),
--     falls back to built-in local O(1) AE2 maintainer if Mainnet Stock is offline/paused,
--     and auto-syncs pending rules back to Mainnet Stock on reconnect.

local okComp, computer = pcall(require, "computer")
if not okComp then computer = nil end

local Common = require("gtnh_common")
local Hardware = require("lib.hardware")
local RecipesDb = require("lib.recipes_db")

local Scheduler = {}
local MAX_LOG_EVENTS = 80

local function clockNow()
    if computer and computer.uptime then return computer.uptime()
    elseif _G.computer and _G.computer.uptime then return _G.computer.uptime()
    elseif os and os.clock then return os.clock() end
    return 0
end

Scheduler.now = clockNow

local function fmtCompact(n, isFluid)
    n = tonumber(n) or 0
    local abs = math.abs(n)
    local suf = isFluid and "L" or ""
    if abs >= 1e12 then return string.format("%.2fT%s", n / 1e12, suf)
    elseif abs >= 1e9 then return string.format("%.2fG%s", n / 1e9, suf)
    elseif abs >= 1e6 then return string.format("%.1fM%s", n / 1e6, suf)
    elseif abs >= 1e3 then return string.format("%.1fK%s", n / 1e3, suf)
    else return string.format("%d%s", math.floor(n + 0.5), suf) end
end

local function makeKey(tp, name, damage)
    local rType = (tp == "fluid") and "fluid" or "item"
    local dmg = (rType == "fluid") and 0 or math.max(0, math.floor(tonumber(damage) or 0))
    return string.format("%s:%s:%d", rType, tostring(name or ""), dmg)
end

function Scheduler.recipeOutputs(recipe)
    local outs = {}
    if type(recipe) ~= "table" then return outs end
    local idx = 0
    for _, it in ipairs(recipe.itemsOut or {}) do
        idx = idx + 1
        outs[#outs + 1] = {
            circuit = idx,
            type = "item",
            name = it.name,
            damage = tonumber(it.damage) or 0,
            amount = tonumber(it.amount) or 1,
            label = it.label or it.name,
            key = makeKey("item", it.name, it.damage),
        }
    end
    for _, fl in ipairs(recipe.fluidsOut or {}) do
        idx = idx + 1
        outs[#outs + 1] = {
            circuit = idx,
            type = "fluid",
            name = fl.name,
            damage = 0,
            amount = tonumber(fl.amount) or 1000,
            label = fl.label or fl.name,
            key = makeKey("fluid", fl.name, 0),
        }
    end
    return outs
end

function Scheduler.buildDefaultInputs(recipe, opts)
    opts = opts or {}
    local list = {}
    if type(recipe) ~= "table" then return list end
    local mult = math.max(1, math.floor(tonumber(opts.batches) or 8))
    for _, it in ipairs(recipe.itemsIn or {}) do
        local batch = math.max(1, math.floor(tonumber(it.amount) or 1))
        list[#list + 1] = {
            type = "item",
            name = it.name,
            damage = tonumber(it.damage) or 0,
            label = it.label or it.name,
            perCraft = batch,
            target = math.max(batch, batch * mult),
            batch = math.min(batch * 4, math.max(batch, 64)),
            role = "input",
            enabled = true,
        }
    end
    for _, fl in ipairs(recipe.fluidsIn or {}) do
        local batch = math.max(100, math.floor(tonumber(fl.amount) or 1000))
        list[#list + 1] = {
            type = "fluid",
            name = fl.name,
            damage = 0,
            label = fl.label or fl.name,
            perCraft = batch,
            target = math.max(batch, batch * mult),
            batch = math.max(1000, batch * 2),
            role = "input",
            enabled = true,
        }
    end
    if opts.includeCatalyst == true and type(recipe.catalyst) == "table" then
        list[#list + 1] = {
            type = "item",
            name = recipe.catalyst.name,
            damage = tonumber(recipe.catalyst.damage) or 0,
            label = recipe.catalyst.label or "QFT Catalyst",
            perCraft = 1,
            target = 4,
            batch = 1,
            role = "catalyst",
            enabled = false,
        }
    end
    if opts.includePlasmas == true then
        for _, pk in ipairs({ "neptunium", "fermium" }) do
            local pl = RecipesDb.PLASMAS[pk]
            list[#list + 1] = {
                type = "fluid",
                name = pl.name,
                damage = 0,
                label = pl.label,
                perCraft = 1000,
                target = 100000,
                batch = 10000,
                role = "boost",
                enabled = false,
            }
        end
    end
    return list
end

local function normalizeTags(raw)
    local out, seen = {}, {}
    if type(raw) ~= "table" then return out end
    for _, t in ipairs(raw) do
        local s = type(t) == "string" and t:match("^%s*(.-)%s*$") or ""
        if s ~= "" and not seen[s] and #out < 6 then
            seen[s] = true
            out[#out + 1] = s:sub(1, 48)
        end
    end
    return out
end

local function sanitizeUnit(raw, idx)
    if type(raw) ~= "table" then raw = {} end
    local id = (type(raw.id) == "string" and raw.id ~= "") and raw.id or ("qft_" .. tostring(idx or 1))
    local rcp = (type(raw.recipeId) == "string" and RecipesDb.BY_ID[raw.recipeId]) or RecipesDb.RECIPES[1]
    local catDmg = tonumber(raw.catalystDamage)
    if catDmg and RecipesDb.CATALYST_BY_DAMAGE and RecipesDb.CATALYST_BY_DAMAGE[math.floor(catDmg)] then
        catDmg = math.floor(catDmg)
        local cat = RecipesDb.CATALYST_BY_DAMAGE[catDmg]
        local inCat = false
        for _, rid in ipairs(cat.recipeIds or {}) do
            if rcp and rid == rcp.id then inCat = true; break end
        end
        if not inCat and cat.recipeIds and cat.recipeIds[1] and RecipesDb.BY_ID[cat.recipeIds[1]] then
            rcp = RecipesDb.BY_ID[cat.recipeIds[1]]
        end
    else
        catDmg = (rcp and rcp.catalyst and rcp.catalyst.damage) or 16
    end
    local recipeId = rcp and rcp.id or "pt_metallic_powder"
    local fMode = raw.focusMode
    if fMode ~= "auto" and fMode ~= "fixed" and fMode ~= "none" then fMode = "auto" end
    local npMode = raw.boostNeptunium
    if npMode ~= "on" and npMode ~= "off" and npMode ~= "auto" then npMode = "auto" end
    local fmMode = raw.boostFermium
    if fmMode ~= "on" and fmMode ~= "off" and fmMode ~= "auto" then fmMode = "off" end
    return {
        id = id,
        label = (type(raw.label) == "string" and raw.label ~= "") and raw.label or ("QFT-" .. tostring(idx or 1)),
        enabled = (raw.enabled ~= false),
        controllerAddr = (type(raw.controllerAddr) == "string") and raw.controllerAddr or "",
        busAddr = (type(raw.busAddr) == "string") and raw.busAddr or "",
        hatchAddr = (type(raw.hatchAddr) == "string") and raw.hatchAddr or "",
        tier = math.max(1, math.min(4, math.floor(tonumber(raw.tier) or 4))),
        catalystDamage = catDmg,
        recipeId = recipeId,
        mode = (raw.mode == "paused") and "paused" or "passive",
        targetStock = math.max(0, math.floor(tonumber(raw.targetStock) or 0)), -- 0 = 24/7 passive
        focusMode = fMode,
        focusCircuit = math.max(0, math.min(24, math.floor(tonumber(raw.focusCircuit) or 1))),
        boostNeptunium = npMode,
        boostFermium = fmMode,
    }
end

local function sanitizeLocalRule(raw, idx)
    if type(raw) ~= "table" or type(raw.name) ~= "string" or raw.name == "" then return nil end
    local tp = (raw.type == "fluid") and "fluid" or "item"
    local dmg = (tp == "fluid") and 0 or math.max(0, math.floor(tonumber(raw.damage) or 0))
    local tgt = math.max(1, math.floor(tonumber(raw.target) or (tp == "fluid" and 64000 or 256)))
    local bat = math.max(1, math.floor(tonumber(raw.batch) or math.max(1, math.floor(tgt / 4))))
    return {
        id = (type(raw.id) == "string" and raw.id ~= "") and raw.id or string.format("%s:%s:%d:%d", tp, raw.name, dmg, idx or 1),
        type = tp,
        name = raw.name,
        damage = dmg,
        label = tostring((type(raw.label) == "string" and raw.label ~= "") and raw.label or raw.name),
        target = tgt,
        batch = bat,
        enabled = (raw.enabled ~= false),
        tags = normalizeTags(raw.tags),
        syncedToMainnet = (raw.syncedToMainnet == true),
    }
end

function Scheduler.defaultConfig()
    return {
        armed = false,
        pollSec = 5,
        extLinkMode = "auto",
        aeAddr = "auto",
        maintFreeCpus = 2,
        maintPollSec = 10,
        maintGroup = "QFT",
        units = {},
        localRules = {},
    }
end

function Scheduler.normalizeConfig(raw)
    local d = Scheduler.defaultConfig()
    if type(raw) ~= "table" then return d end
    d.armed = (raw.armed == true)
    d.pollSec = math.max(2, math.min(120, math.floor(tonumber(raw.pollSec) or d.pollSec)))
    d.extLinkMode = (raw.extLinkMode == "off") and "off" or "auto"
    d.aeAddr = (type(raw.aeAddr) == "string" and raw.aeAddr ~= "") and raw.aeAddr or "auto"
    d.maintFreeCpus = math.max(0, math.min(32, math.floor(tonumber(raw.maintFreeCpus) or d.maintFreeCpus)))
    d.maintPollSec = math.max(4, math.min(120, math.floor(tonumber(raw.maintPollSec) or d.maintPollSec)))
    d.maintGroup = (type(raw.maintGroup) == "string" and raw.maintGroup ~= "") and raw.maintGroup or "QFT"

    local seenU = {}
    for i, u in ipairs(type(raw.units) == "table" and raw.units or {}) do
        local su = sanitizeUnit(u, i)
        while seenU[su.id] do su.id = su.id .. "_x" end
        seenU[su.id] = true
        d.units[#d.units + 1] = su
    end
    for i, r in ipairs(type(raw.localRules) == "table" and raw.localRules or {}) do
        local sr = sanitizeLocalRule(r, i)
        if sr then d.localRules[#d.localRules + 1] = sr end
    end
    return d
end

function Scheduler.newState()
    return {
        stepCount = 0,
        discovery = {},
        _proxies = {},
        _ruleTrack = {},
        _pendingJobs = {},
        _lastMaintStepAt = -1000,
        unitStatuses = {},
        localRuleStatuses = {},
        stockPeer = nil,
        maintMode = { mode = "offline", label = "OFFLINE", detail = "Mainnet Stock offline; no local AE2" },
        events = {},
    }
end

function Scheduler.pushLog(state, kind, text, stage)
    if not state or type(text) ~= "string" or text == "" then return end
    state.events = state.events or {}
    local stg = stage or ((kind == "err" and "ERR") or (kind == "warn" and "WRN") or (kind == "out" and "OUT") or "DEC")
    local top = state.events[1]
    if top and top.text == text and top.stage == stg then return end
    table.insert(state.events, 1, { step = state.stepCount or 0, uptime = clockNow(), stage = stg, kind = kind or "info", text = text })
    while #state.events > MAX_LOG_EVENTS do table.remove(state.events) end
end

function Scheduler.findUnit(cfg, id)
    for i, u in ipairs((cfg and cfg.units) or {}) do
        if u and u.id == id then return u, i end
    end
    return nil, nil
end

function Scheduler.setUnitCatalyst(unit, damage)
    if not unit then return nil, nil end
    local cat = RecipesDb.CATALYST_BY_DAMAGE and RecipesDb.CATALYST_BY_DAMAGE[math.floor(tonumber(damage) or -1)] or nil
    if not cat then return nil, nil end
    unit.catalystDamage = cat.damage
    local valid = false
    for _, rid in ipairs(cat.recipeIds or {}) do
        if rid == unit.recipeId then valid = true; break end
    end
    if not valid and cat.recipeIds and cat.recipeIds[1] then
        unit.recipeId = cat.recipeIds[1]
    end
    return cat, RecipesDb.BY_ID[unit.recipeId]
end

function Scheduler.removeUnit(cfg, unitId)
    if not (cfg and type(cfg.units) == "table") then return false end
    for i, u in ipairs(cfg.units) do
        if u and u.id == unitId then
            table.remove(cfg.units, i)
            return true
        end
    end
    return false
end

function Scheduler.addUnitFromDiscovery(cfg, ctrlAddr, busAddr, hatchAddr, label)
    cfg.units = cfg.units or {}
    if ctrlAddr and ctrlAddr ~= "" then
        for _, u in ipairs(cfg.units) do
            if u.controllerAddr == ctrlAddr then
                if busAddr and busAddr ~= "" and u.busAddr == "" then u.busAddr = busAddr end
                if hatchAddr and hatchAddr ~= "" and u.hatchAddr == "" then u.hatchAddr = hatchAddr end
                return u, false
            end
        end
    end
    local idx = #cfg.units + 1
    local seen = {}
    for _, u in ipairs(cfg.units) do seen[u.id] = true end
    local newId = "qft_" .. tostring(idx)
    while seen[newId] do idx = idx + 1; newId = "qft_" .. tostring(idx) end
    local u = sanitizeUnit({
        id = newId,
        label = label or ("QFT-" .. tostring(#cfg.units + 1)),
        controllerAddr = ctrlAddr or "",
        busAddr = busAddr or "",
        hatchAddr = hatchAddr or "",
    }, #cfg.units + 1)
    cfg.units[#cfg.units + 1] = u
    return u, true
end

function Scheduler.autoBindDiscoveredUnits(cfg, disc)
    disc = disc or {}
    cfg.units = cfg.units or {}
    local usedCtrl, usedBus, usedHatch = {}, {}, {}
    for _, u in ipairs(cfg.units) do
        if u.controllerAddr and u.controllerAddr ~= "" then usedCtrl[u.controllerAddr] = true end
        if u.busAddr and u.busAddr ~= "" then usedBus[u.busAddr] = true end
        if u.hatchAddr and u.hatchAddr ~= "" then usedHatch[u.hatchAddr] = true end
    end
    local function nextUnused(list, used)
        for _, entry in ipairs(list or {}) do
            if entry and entry.addr and entry.addr ~= "" and not used[entry.addr] then
                used[entry.addr] = true
                return entry.addr
            end
        end
        return ""
    end
    local boundExtra = 0
    for _, u in ipairs(cfg.units) do
        if u.controllerAddr and u.controllerAddr ~= "" then
            if u.busAddr == nil or u.busAddr == "" then
                local nb = nextUnused(disc.inputBuses, usedBus)
                if nb ~= "" then u.busAddr = nb; boundExtra = boundExtra + 1 end
            end
            if u.hatchAddr == nil or u.hatchAddr == "" then
                local nh = nextUnused(disc.inputHatches, usedHatch)
                if nh ~= "" then u.hatchAddr = nh; boundExtra = boundExtra + 1 end
            end
        end
    end
    local added = 0
    for _, c in ipairs(disc.controllers or {}) do
        if c and c.addr and not usedCtrl[c.addr] then
            usedCtrl[c.addr] = true
            local bus = nextUnused(disc.inputBuses, usedBus)
            local hatch = nextUnused(disc.inputHatches, usedHatch)
            Scheduler.addUnitFromDiscovery(cfg, c.addr, bus, hatch, "QFT-" .. tostring(#cfg.units + 1))
            added = added + 1
        end
    end
    return added, boundExtra
end

function Scheduler.diagnoseHardware(cfg, disc)
    disc = disc or {}
    local hasScan = (type(disc.controllers) == "table")
    local knownCtrl, knownBus, knownHatch = {}, {}, {}
    for _, c in ipairs(disc.controllers or {}) do if c.addr then knownCtrl[c.addr] = c end end
    for _, b in ipairs(disc.inputBuses or {}) do if b.addr then knownBus[b.addr] = b end end
    for _, h in ipairs(disc.inputHatches or {}) do if h.addr then knownHatch[h.addr] = h end end

    local errors, warnings, unitFlags = {}, {}, {}
    local byCtrl, byBus, byHatch = {}, {}, {}
    local boundCtrl, boundBus, boundHatch = {}, {}, {}

    local function ensureFlag(uid)
        if not unitFlags[uid] then
            unitFlags[uid] = { ctrlErr = false, busErr = false, hatchErr = false, anyErr = false, anyWarn = false }
        end
        return unitFlags[uid]
    end
    local function addErr(code, msg, uid, slot)
        errors[#errors + 1] = { sev = "err", code = code, msg = msg, unitId = uid, slot = slot }
        if uid then
            local fl = ensureFlag(uid)
            fl.anyErr = true
            if slot == "ctrl" then fl.ctrlErr = true
            elseif slot == "bus" then fl.busErr = true
            elseif slot == "hatch" then fl.hatchErr = true end
        end
    end
    local function addWarn(code, msg, uid, slot)
        warnings[#warnings + 1] = { sev = "warn", code = code, msg = msg, unitId = uid, slot = slot }
        if uid then
            local fl = ensureFlag(uid)
            fl.anyWarn = true
        end
    end

    for _, u in ipairs((cfg and cfg.units) or {}) do
        ensureFlag(u.id)
        if u.controllerAddr and u.controllerAddr ~= "" then
            byCtrl[u.controllerAddr] = byCtrl[u.controllerAddr] or {}
            byCtrl[u.controllerAddr][#byCtrl[u.controllerAddr] + 1] = u
            boundCtrl[u.controllerAddr] = true
        end
        if u.busAddr and u.busAddr ~= "" then
            byBus[u.busAddr] = byBus[u.busAddr] or {}
            byBus[u.busAddr][#byBus[u.busAddr] + 1] = u
            boundBus[u.busAddr] = true
        end
        if u.hatchAddr and u.hatchAddr ~= "" then
            byHatch[u.hatchAddr] = byHatch[u.hatchAddr] or {}
            byHatch[u.hatchAddr][#byHatch[u.hatchAddr] + 1] = u
            boundHatch[u.hatchAddr] = true
        end
    end

    local function checkDups(map, code, kindLabel, slot)
        for addr, owners in pairs(map) do
            if #owners > 1 then
                local names = {}
                for _, ou in ipairs(owners) do
                    names[#names + 1] = ou.label
                    local fl = ensureFlag(ou.id)
                    fl.anyErr = true
                    if slot == "ctrl" then fl.ctrlErr = true
                    elseif slot == "bus" then fl.busErr = true
                    elseif slot == "hatch" then fl.hatchErr = true end
                end
                errors[#errors + 1] = {
                    sev = "err",
                    code = code,
                    msg = string.format("Duplicate %s (%s) on %s (doubled MFU/adapter)", kindLabel, Hardware.shortAddr(addr), table.concat(names, " & ")),
                    slot = slot,
                }
            end
        end
    end
    checkDups(byCtrl, "DUP-CTRL", "Controller", "ctrl")
    checkDups(byBus, "DUP-BUS", "ME Input Bus", "bus")
    checkDups(byHatch, "DUP-HATCH", "ME Input Hatch", "hatch")

    for _, u in ipairs((cfg and cfg.units) or {}) do
        if not u.controllerAddr or u.controllerAddr == "" then
            addErr("NO-CTRL", string.format("%s: no QFT Controller bound", u.label), u.id, "ctrl")
        elseif hasScan and not knownCtrl[u.controllerAddr] then
            addErr("MISS-CTRL", string.format("%s: Controller %s offline/missing", u.label, Hardware.shortAddr(u.controllerAddr)), u.id, "ctrl")
        end
        if not u.busAddr or u.busAddr == "" then
            addWarn("NO-BUS", string.format("%s: no ME Stocking Bus (focus swap disabled)", u.label), u.id, "bus")
        elseif hasScan and not knownBus[u.busAddr] then
            addErr("MISS-BUS", string.format("%s: ME Bus %s offline/missing", u.label, Hardware.shortAddr(u.busAddr)), u.id, "bus")
        end
        if not u.hatchAddr or u.hatchAddr == "" then
            addWarn("NO-HATCH", string.format("%s: no ME Stocking Hatch (Np/Fm boost disabled)", u.label), u.id, "hatch")
        elseif hasScan and not knownHatch[u.hatchAddr] then
            addErr("MISS-HATCH", string.format("%s: ME Hatch %s offline/missing", u.label, Hardware.shortAddr(u.hatchAddr)), u.id, "hatch")
        end
    end

    if hasScan then
        for _, c in ipairs(disc.controllers or {}) do
            if c.addr and not boundCtrl[c.addr] then
                local eh = c.hatchLabel and (" [" .. c.hatchLabel .. "]") or ""
                addWarn("UNBOUND-CTRL", string.format("Unbound QFT Controller %s%s (click Scan & Auto-Bind)", c.short or Hardware.shortAddr(c.addr), eh), nil, "ctrl")
            end
        end
        local unBus, unHatch = 0, 0
        for _, b in ipairs(disc.inputBuses or {}) do
            if b.addr and not boundBus[b.addr] then unBus = unBus + 1 end
        end
        for _, h in ipairs(disc.inputHatches or {}) do
            if h.addr and not boundHatch[h.addr] then unHatch = unHatch + 1 end
        end
        if unBus > 0 then
            addWarn("UNBOUND-BUS", string.format("%d unbound ME Stocking Bus(es) detected", unBus), nil, "bus")
        end
        if unHatch > 0 then
            addWarn("UNBOUND-HATCH", string.format("%d unbound ME Stocking Hatch(es) detected", unHatch), nil, "hatch")
        end
        if #(disc.aeInterfaces or {}) == 0 then
            addWarn("NO-AE2", "No AE2 Interface attached (output caps & local maintainer disabled)", nil, "ae2")
        end
        for _, om in ipairs(disc.otherMachines or {}) do
            addWarn("OTHER-GT", string.format("Non-QFT machine attached: %s (%s) - check adapter", tostring(om.name or "gt_machine"), tostring(om.short or "?")), nil, "other")
        end
    end

    local items = {}
    for _, e in ipairs(errors) do items[#items + 1] = e end
    for _, w in ipairs(warnings) do items[#items + 1] = w end
    return {
        ok = (#errors == 0 and #warnings == 0),
        errors = errors,
        warnings = warnings,
        items = items,
        unitFlags = unitFlags,
    }
end

function Scheduler.getMaintainerStatus(cfg, state, nowSec, compLib)
    nowSec = nowSec or clockNow()
    local cl = compLib or rawget(_G, "component")
    local ae = Hardware.getLocalAeProxy(cfg, cl, state)
    local peer = state and state.stockPeer
    local stockOnline = (type(peer) == "table") and ((nowSec - (tonumber(peer.lastSeen) or -1000)) < 60)
    local stockArmed = stockOnline and (peer.armed == true)

    local syncedCnt, pendingCnt, enabledCnt = 0, 0, 0
    for _, lr in ipairs((cfg and cfg.localRules) or {}) do
        if lr.enabled ~= false then
            enabledCnt = enabledCnt + 1
            if lr.syncedToMainnet then syncedCnt = syncedCnt + 1 else pendingCnt = pendingCnt + 1 end
        end
    end

    local mode, label, detail
    if stockOnline and stockArmed then
        mode = "mainnet"
        label = "MAINNET STOCK"
        detail = string.format("Mainnet Stock armed (%d synced, %d pending)", syncedCnt, pendingCnt)
    elseif stockOnline then
        mode = ae and "local" or "paused"
        label = ae and "LOCAL FALLBACK" or "MAINNET PAUSED"
        detail = ae and "Mainnet Stock paused -> Local AE2 fallback active" or "Mainnet Stock online (PAUSED)"
    elseif ae then
        mode = "local"
        label = "LOCAL FALLBACK"
        detail = string.format("Mainnet offline -> Local AE2 maintaining %d rule(s)", enabledCnt)
    else
        mode = "offline"
        label = "OFFLINE"
        detail = "Mainnet Stock offline & no local AE2 interface"
    end
    return {
        mode = mode,
        label = label,
        detail = detail,
        stockOnline = stockOnline,
        stockArmed = stockArmed,
        localAeOnline = (ae ~= nil),
        localCount = enabledCnt,
        syncedCount = syncedCnt,
        pendingCount = pendingCnt,
    }
end

local function findLocalRule(cfg, tp, name, dmg)
    for i, lr in ipairs((cfg and cfg.localRules) or {}) do
        if lr and lr.type == tp and lr.name == name and (tp == "fluid" or (tonumber(lr.damage) or 0) == (tonumber(dmg) or 0)) then
            return lr, i
        end
    end
    return nil, nil
end

local function mergeTag(existing, tag)
    if type(tag) ~= "string" or tag == "" then return end
    existing.tags = existing.tags or {}
    for _, t in ipairs(existing.tags) do
        if t == tag then return end
    end
    if #existing.tags < 6 then
        existing.tags[#existing.tags + 1] = tag
    end
end

function Scheduler.pushRecipeInputs(cfg, state, req, compLib)
    if not cfg or type(req) ~= "table" then return { ok = false, error = "Invalid request" } end
    local recipe = RecipesDb.BY_ID[tostring(req.recipeId or "")]
    if not recipe then return { ok = false, error = "Unknown recipeId" } end

    local rules = type(req.rules) == "table" and req.rules
        or Scheduler.buildDefaultInputs(recipe, {
            batches = req.batches or 8,
            includeCatalyst = (req.includeCatalyst == true),
            includePlasmas = (req.includePlasmas == true),
        })
    local tag = (type(req.tag) == "string" and req.tag ~= "") and req.tag or ("QFT: " .. recipe.name)
    local activeRules = {}
    for _, r in ipairs(rules) do
        if type(r) == "table" and r.enabled ~= false and type(r.name) == "string" and r.name ~= "" then
            local tp = (r.type == "fluid") and "fluid" or "item"
            local dmg = (tp == "fluid") and 0 or math.max(0, math.floor(tonumber(r.damage) or 0))
            local tgt = math.max(1, math.floor(tonumber(r.target) or (tp == "fluid" and 64000 or 256)))
            local bat = math.max(1, math.floor(tonumber(r.batch) or math.max(1, math.floor(tgt / 4))))
            activeRules[#activeRules + 1] = {
                type = tp,
                name = r.name,
                damage = dmg,
                label = r.label or r.name,
                target = tgt,
                batch = bat,
                group = cfg.maintGroup or "QFT",
            }
        end
    end
    if #activeRules == 0 then
        return { ok = false, error = "No enabled inputs selected" }
    end

    -- Save locally first for offline/reconnect resilience
    cfg.localRules = cfg.localRules or {}
    for _, ar in ipairs(activeRules) do
        local ex = findLocalRule(cfg, ar.type, ar.name, ar.damage)
        if ex then
            ex.target = math.max(tonumber(ex.target) or 0, ar.target)
            ex.batch = math.max(tonumber(ex.batch) or 0, ar.batch)
            ex.enabled = true
            ex.syncedToMainnet = false
            mergeTag(ex, tag)
        else
            cfg.localRules[#cfg.localRules + 1] = {
                id = makeKey(ar.type, ar.name, ar.damage),
                type = ar.type,
                name = ar.name,
                damage = ar.damage,
                label = ar.label,
                target = ar.target,
                batch = ar.batch,
                enabled = true,
                tags = { tag },
                syncedToMainnet = false,
            }
        end
    end

    local ms = Scheduler.getMaintainerStatus(cfg, state, clockNow(), compLib)
    if ms.stockOnline and req.preferMainnet ~= false then
        local okTx, infoTx = Hardware.pushRulesToStock(cfg, state, {
            tag = tag,
            group = cfg.maintGroup or "QFT",
            source = "qft",
            raiseTarget = (req.raiseTarget ~= false),
            rules = activeRules,
        }, compLib)
        if okTx then
            for _, ar in ipairs(activeRules) do
                local ex = findLocalRule(cfg, ar.type, ar.name, ar.damage)
                if ex then ex.syncedToMainnet = true end
            end
            Scheduler.pushLog(state, "out", string.format("Sent %d input(s) to Mainnet Stock [%s]", #activeRules, tag), "OUT")
            return { ok = true, dispatched = "mainnet", mode = ms.mode, reqId = infoTx, tag = tag, count = #activeRules }
        end
    end

    if ms.localAeOnline then
        Scheduler.pushLog(state, "warn", string.format("Mainnet Stock unavailable -> local fallback maintaining %d input(s) [%s]", #activeRules, tag), "WRN")
        return { ok = true, dispatched = "local", mode = "local", tag = tag, count = #activeRules }
    end

    Scheduler.pushLog(state, "warn", string.format("Queued %d input(s) locally [%s] (will sync when Mainnet online)", #activeRules, tag), "WRN")
    return { ok = true, dispatched = "queued", mode = "offline", tag = tag, count = #activeRules }
end

function Scheduler.retireRecipeInputs(cfg, state, req, compLib)
    local recipe = RecipesDb.BY_ID[tostring(req and req.recipeId or "")]
    local tag = (req and type(req.tag) == "string" and req.tag ~= "") and req.tag
        or (recipe and ("QFT: " .. recipe.name) or nil)
    if not tag then return { ok = false, error = "recipeId or tag required" } end

    local untagged, removed = 0, 0
    local keptRules = {}
    for _, lr in ipairs((cfg and cfg.localRules) or {}) do
        local keptTags, hit = {}, false
        for _, t in ipairs(lr.tags or {}) do
            if t == tag then hit = true else keptTags[#keptTags + 1] = t end
        end
        if hit then untagged = untagged + 1; lr.tags = keptTags end
        if #lr.tags == 0 and (req.deleteOrphans == true or hit) then
            removed = removed + 1
        else
            keptRules[#keptRules + 1] = lr
        end
    end
    cfg.localRules = keptRules

    local ms = Scheduler.getMaintainerStatus(cfg, state, clockNow(), compLib)
    local sentMesh = false
    if ms.stockOnline then
        sentMesh = Hardware.pushRulesToStock(cfg, state, {
            op = "untag",
            tag = tag,
            pauseOrphans = (req.pauseOrphans ~= false),
            deleteOrphans = (req.deleteOrphans == true),
        }, compLib) == true
    end
    Scheduler.pushLog(state, "out", string.format("Retired [%s]: %d local untagged (%s)", tag, untagged, sentMesh and "Mainnet notified" or "local only"), "OUT")
    return { ok = true, tag = tag, untagged = untagged, removed = removed, mainnetNotified = sentMesh }
end

function Scheduler.syncHardware(cfg, state, compLib)
    local disc = Hardware.discover(cfg, compLib, state)
    if state then
        state.hwDiag = Scheduler.diagnoseHardware(cfg, disc)
    end
    return disc
end

local function stepLocalMaintainer(cfg, state, nowSec, compLib, ms, ae, counter)
    local outStatuses = {}
    local peerKeys = (ms.stockOnline and ms.stockArmed and state.stockPeer and state.stockPeer.keys) or {}

    -- Sync unsent local rules automatically once Mainnet Stock comes back online & armed
    if ms.stockOnline and ms.stockArmed and #(cfg.localRules or {}) > 0 and (nowSec - (state._lastAutoSyncAt or -1000)) >= 20 then
        local pending = {}
        for _, lr in ipairs(cfg.localRules) do
            if lr.enabled ~= false and not lr.syncedToMainnet then
                pending[#pending + 1] = {
                    type = lr.type,
                    name = lr.name,
                    damage = lr.damage,
                    label = lr.label,
                    target = lr.target,
                    batch = lr.batch,
                    group = cfg.maintGroup or "QFT",
                    tags = lr.tags,
                }
            end
        end
        if #pending > 0 then
            state._lastAutoSyncAt = nowSec
            local okTx = Hardware.pushRulesToStock(cfg, state, {
                tag = (pending[1].tags and pending[1].tags[1]) or "QFT: AutoSync",
                group = cfg.maintGroup or "QFT",
                source = "qft-sync",
                rules = pending,
            }, compLib)
            if okTx then
                for _, lr in ipairs(cfg.localRules) do
                    if lr.enabled ~= false then lr.syncedToMainnet = true end
                end
                Scheduler.pushLog(state, "out", string.format("Auto-synced %d pending rule(s) to Mainnet Stock.", #pending), "OUT")
            end
        end
    end

    local useLocalCraft = (not ms.stockArmed) and (ae ~= nil) and (cfg.armed == true)
    local cpuSnap = (ae and useLocalCraft and (nowSec - (state._lastMaintStepAt or -1000) >= (cfg.maintPollSec or 10)))
        and Hardware.inspectLocalCpus(ae, counter) or nil
    if cpuSnap then state._lastMaintStepAt = nowSec end
    local freeHeadroom = (cpuSnap and cpuSnap.ok) and math.max(0, cpuSnap.free - (cfg.maintFreeCpus or 2)) or 0
    local dispatchQueue = {}

    for i, lr in ipairs(cfg.localRules or {}) do
        local key = makeKey(lr.type, lr.name, lr.damage)
        local stock = nil
        if ae then stock = Hardware.queryStock(ae, lr.type, lr.name, lr.damage, counter) end
        local stStr = "WAIT"
        if lr.enabled == false then
            stStr = "OFF"
        elseif ms.stockArmed and (peerKeys[key] == true or lr.syncedToMainnet) then
            stStr = "MAINNET"
        elseif useLocalCraft then
            local tr = state._ruleTrack[lr.id] or {}
            local pj = state._pendingJobs[lr.id]
            local pendingBusy = false
            if pj and pj.isDone then
                local okD, done = pcall(pj.isDone)
                if okD and not done then pendingBusy = true else state._pendingJobs[lr.id] = nil end
            end
            if pendingBusy or (cpuSnap and cpuSnap.busyByKey[key]) or ((tr.inFlightUntil or 0) > nowSec) then
                stStr = "CRAFT"
            elseif stock and stock >= lr.target then
                stStr = "OK"
                tr.failCount = 0
                tr.lastError = nil
            elseif (tr.backoffUntil or 0) > nowSec then
                stStr = "BACKOFF"
            elseif stock then
                stStr = "LOW"
                dispatchQueue[#dispatchQueue + 1] = { lr = lr, tr = tr, idx = i }
            end
        elseif stock then
            stStr = (stock >= lr.target) and "OK" or "LOW"
        else
            stStr = ms.stockOnline and "MAINNET?" or "OFFLINE"
        end
        outStatuses[i] = {
            id = lr.id,
            type = lr.type,
            name = lr.name,
            damage = lr.damage,
            label = lr.label,
            target = lr.target,
            batch = lr.batch,
            enabled = lr.enabled ~= false,
            tags = lr.tags,
            stock = stock,
            state = stStr,
            synced = (lr.syncedToMainnet == true) or (peerKeys[key] == true),
        }
    end

    if useLocalCraft and cpuSnap and cpuSnap.ok and freeHeadroom > 0 and #dispatchQueue > 0 then
        local budget = math.min(freeHeadroom, 2, #dispatchQueue)
        for d = 1, budget do
            local job = dispatchQueue[d]
            local ack = Hardware.requestLocalCraft(ae, job.lr, job.lr.batch, counter)
            if ack and ack.ok then
                job.tr.inFlightUntil = nowSec + 90
                job.tr.failCount = 0
                job.tr.lastError = nil
                state._ruleTrack[job.lr.id] = job.tr
                if ack.statusObj then state._pendingJobs[job.lr.id] = ack.statusObj end
                outStatuses[job.idx].state = "CRAFT"
                Scheduler.pushLog(state, "out", string.format("Local fallback: +%s %s", fmtCompact(job.lr.batch, job.lr.type == "fluid"), job.lr.label), "OUT")
            else
                job.tr.failCount = (job.tr.failCount or 0) + 1
                job.tr.backoffUntil = nowSec + math.min(300, 30 * (2 ^ math.min(4, job.tr.failCount - 1)))
                job.tr.lastError = ack and ack.error or "craft failed"
                state._ruleTrack[job.lr.id] = job.tr
                outStatuses[job.idx].state = "ERR"
            end
        end
    end
    state.localRuleStatuses = outStatuses
end

function Scheduler.step(cfg, state, nowSec, compLib, opts)
    nowSec = nowSec or clockNow()
    opts = opts or {}
    state.stepCount = (state.stepCount or 0) + 1
    local counter = { aeCalls = 0 }
    local cl = compLib or rawget(_G, "component")
    local ae = Hardware.getLocalAeProxy(cfg, cl, state)
    local diag = Scheduler.diagnoseHardware(cfg, (state and state.discovery) or {})
    state.hwDiag = diag

    local unitStatuses = {}
    local running, reconfCount, errCount = 0, 0, 0
    for i, u in ipairs((cfg and cfg.units) or {}) do
        local recipe = RecipesDb.BY_ID[u.recipeId] or RecipesDb.RECIPES[1]
        local outs = Scheduler.recipeOutputs(recipe)
        local live = Hardware.readUnit(u, cl, state)

        -- Evaluate outputs against targetStock (0 = 24/7 passive)
        local tgt = math.max(0, tonumber(u.targetStock) or 0)
        local anyOutNeed = (tgt == 0)
        local lowestCircuit, lowestFill = nil, 1e18
        for _, o in ipairs(outs) do
            local stk = ae and Hardware.queryStock(ae, o.type, o.name, o.damage, counter) or nil
            o.stock = stk
            if tgt > 0 and stk ~= nil then
                if stk < tgt then
                    anyOutNeed = true
                    local fill = stk / tgt
                    if fill < lowestFill then
                        lowestFill = fill
                        lowestCircuit = o.circuit
                    end
                end
            elseif not lowestCircuit then
                lowestCircuit = o.circuit
            end
        end

        local chosenFocus = 0
        if u.focusMode == "none" then
            chosenFocus = 0
        elseif u.focusMode == "fixed" then
            chosenFocus = math.max(0, math.min(#outs, math.floor(tonumber(u.focusCircuit) or 1)))
        else
            chosenFocus = lowestCircuit or (#outs > 0 and 1 or 0)
        end

        local tierOk = (u.tier >= (recipe and recipe.focusTier or 1))
        local wantRun = (cfg.armed == true) and (u.enabled ~= false) and (u.mode ~= "paused") and anyOutNeed and tierOk and live.online
        local wantNp = (u.boostNeptunium == "on") or (u.boostNeptunium == "auto" and chosenFocus > 0 and wantRun)
        local wantFm = (u.boostFermium == "on") or (u.boostFermium == "auto" and wantRun)

        local ctrlRes = { ok = false, reconfiguring = false, action = "dryRun" }
        if not opts.dryRun and live.online then
            ctrlRes = Hardware.applyUnitControl(u, live, {
                workAllowed = wantRun,
                focusCircuit = chosenFocus,
                wantNeptunium = wantNp,
                wantFermium = wantFm,
            }, cl, state)
            if ctrlRes.waitingIdle then
                Scheduler.pushLog(state, "dec", string.format("%s pausing to safely reconfigure focus/plasma when idle.", u.label), "DEC")
            elseif ctrlRes.appliedReconfig then
                Scheduler.pushLog(state, "out", string.format("%s reconfigured idle: Focus #%d | Np=%s Fm=%s",
                    u.label, chosenFocus, tostring(wantNp), tostring(wantFm)), "OUT")
            end
        end

        local stTag = "IDLE"
        if not live.online then
            stTag = (u.enabled ~= false) and "OFF" or "DIS"
            if u.enabled ~= false then errCount = errCount + 1 end
        elseif ctrlRes.reconfiguring or ctrlRes.waitingIdle then
            stTag = "RECFG"
            reconfCount = reconfCount + 1
        elseif live.active then
            stTag = "RUN"
            running = running + 1
        elseif not wantRun then
            stTag = (cfg.armed ~= true or u.mode == "paused" or u.enabled == false) and "PAUSE" or (not tierOk and "TIER!" or "FULL")
        end
        if live.problems > 0 then errCount = errCount + 1 end

        local focusedOut = (chosenFocus > 0 and outs[chosenFocus]) and outs[chosenFocus] or nil
        local cat = (RecipesDb.CATALYST_BY_DAMAGE and RecipesDb.CATALYST_BY_DAMAGE[u.catalystDamage])
            or (recipe and recipe.catalyst and RecipesDb.CATALYST_BY_DAMAGE and RecipesDb.CATALYST_BY_DAMAGE[recipe.catalyst.damage])
        unitStatuses[i] = {
            id = u.id,
            label = u.label,
            enabled = (u.enabled ~= false),
            tier = u.tier,
            catalystDamage = (cat and cat.damage) or u.catalystDamage,
            catalystLabel = (cat and cat.shortLabel) or (recipe and recipe.catalyst and recipe.catalyst.label) or "None",
            catalystRecipeCount = (cat and cat.recipeIds) and #cat.recipeIds or 1,
            recipeId = recipe and recipe.id or "",
            recipeName = recipe and recipe.name or "None",
            recipeTier = recipe and recipe.focusTier or 1,
            tierOk = tierOk,
            mode = u.mode,
            targetStock = tgt,
            focusMode = u.focusMode,
            focusCircuit = live.hasBus and (live.focusCircuit or chosenFocus) or chosenFocus,
            desiredFocus = chosenFocus,
            focusLabel = focusedOut and focusedOut.label or (chosenFocus == 0 and "Balanced (All)" or ("#" .. chosenFocus)),
            boostNeptunium = u.boostNeptunium,
            boostFermium = u.boostFermium,
            hasNeptunium = live.hasNeptunium,
            hasFermium = live.hasFermium,
            wantNeptunium = wantNp,
            wantFermium = wantFm,
            online = live.online,
            hasBus = live.hasBus,
            hasHatch = live.hasHatch,
            active = live.active,
            workAllowed = live.workAllowed,
            progress = live.progress,
            maxProgress = live.maxProgress,
            maxInputEu = live.maxInputEu,
            hatchAmps = live.hatchAmps,
            hatchTier = live.hatchTier,
            hatchLabel = live.hatchLabel or "",
            liveEut = live.liveEut,
            problems = live.problems,
            reconfiguring = (ctrlRes.reconfiguring == true),
            flags = (diag.unitFlags and diag.unitFlags[u.id]) or {},
            state = stTag,
            outputs = outs,
        }
    end

    local ms = Scheduler.getMaintainerStatus(cfg, state, nowSec, cl)
    state.maintMode = ms
    state.unitStatuses = unitStatuses
    if not opts.dryRun then
        stepLocalMaintainer(cfg, state, nowSec, cl, ms, ae, counter)
    end
    return state
end

function Scheduler.buildSnapshot(cfg, state, nowSec)
    nowSec = nowSec or clockNow()
    local ms = Scheduler.getMaintainerStatus(cfg, state, nowSec)
    local unitsOut = {}
    local uById = {}
    for _, us in ipairs((state and state.unitStatuses) or {}) do
        if us and us.id then uById[us.id] = us end
    end
    for i, u in ipairs((cfg and cfg.units) or {}) do
        local us = uById[u.id] or {}
        local rcp = RecipesDb.BY_ID[u.recipeId]
        local cat = RecipesDb.CATALYST_BY_DAMAGE and RecipesDb.CATALYST_BY_DAMAGE[u.catalystDamage]
            or (rcp and rcp.catalyst and RecipesDb.CATALYST_BY_DAMAGE and RecipesDb.CATALYST_BY_DAMAGE[rcp.catalyst.damage])
        unitsOut[i] = {
            id = u.id,
            label = u.label,
            enabled = (u.enabled ~= false),
            tier = u.tier,
            controllerAddr = u.controllerAddr,
            busAddr = u.busAddr,
            hatchAddr = u.hatchAddr,
            catalystDamage = (cat and cat.damage) or u.catalystDamage,
            catalystLabel = us.catalystLabel or (cat and cat.shortLabel) or (rcp and rcp.catalyst and rcp.catalyst.label) or "",
            catalystRecipeCount = us.catalystRecipeCount or ((cat and cat.recipeIds) and #cat.recipeIds or 1),
            recipeId = u.recipeId,
            recipeName = us.recipeName or (rcp and rcp.name) or u.recipeId,
            recipeTier = us.recipeTier or (rcp and rcp.focusTier) or 1,
            mode = u.mode,
            targetStock = u.targetStock,
            focusMode = u.focusMode,
            focusCircuit = u.focusCircuit,
            desiredFocus = us.desiredFocus or u.focusCircuit,
            focusLabel = us.focusLabel or "",
            boostNeptunium = u.boostNeptunium,
            boostFermium = u.boostFermium,
            online = us.online == true,
            active = us.active == true,
            workAllowed = us.workAllowed == true,
            reconfiguring = us.reconfiguring == true,
            hasBus = us.hasBus == true,
            hasHatch = us.hasHatch == true,
            hasNeptunium = us.hasNeptunium == true,
            hasFermium = us.hasFermium == true,
            maxInputEu = us.maxInputEu,
            hatchAmps = us.hatchAmps,
            hatchTier = us.hatchTier,
            hatchLabel = us.hatchLabel or "",
            liveEut = us.liveEut,
            flags = us.flags or {},
            progress = us.progress or 0,
            maxProgress = us.maxProgress or 0,
            problems = us.problems or 0,
            state = us.state or "IDLE",
        }
    end
    local diag = (state and state.hwDiag) or Scheduler.diagnoseHardware(cfg, (state and state.discovery) or {})
    local evOut = {}
    for i = 1, math.min(20, #((state and state.events) or {})) do
        local e = state.events[i]
        evOut[i] = { step = e.step, stage = e.stage, kind = e.kind, text = e.text }
    end
    return {
        ok = true,
        liveOc = true,
        armed = (cfg and cfg.armed == true),
        stepCount = state and state.stepCount or 0,
        policy = {
            pollSec = cfg.pollSec,
            extLinkMode = cfg.extLinkMode,
            maintFreeCpus = cfg.maintFreeCpus,
            maintPollSec = cfg.maintPollSec,
            maintGroup = cfg.maintGroup,
        },
        maintStatus = ms,
        diagnostics = {
            ok = diag.ok == true,
            errors = diag.errors or {},
            warnings = diag.warnings or {},
            items = diag.items or {},
        },
        units = unitsOut,
        localRules = state and state.localRuleStatuses or cfg.localRules or {},
        events = evOut,
    }
end

function Scheduler.executeRpcTable(cfg, state, cmd, compLib, onMutate)
    if type(cmd) ~= "table" then return { ok = false, error = "Invalid command" } end
    local op, id = cmd.op, cmd.id
    local mutated = false
    if op == "ping" then
        return { id = id, ok = true, role = "qft", armed = (cfg.armed == true) }
    elseif op == "get_state" or op == "qft_state" then
        local snap = Scheduler.buildSnapshot(cfg, state)
        snap.id = id
        return snap
    elseif op == "patch_settings" or op == "qft_patch" then
        local p = type(cmd.patch) == "table" and cmd.patch or cmd
        if type(p.armed) == "boolean" then cfg.armed = p.armed; mutated = true end
        if tonumber(p.pollSec) then cfg.pollSec = math.max(2, math.min(120, math.floor(tonumber(p.pollSec)))); mutated = true end
        if tonumber(p.maintFreeCpus) then cfg.maintFreeCpus = math.max(0, math.min(32, math.floor(tonumber(p.maintFreeCpus)))); mutated = true end
        if type(p.maintGroup) == "string" and p.maintGroup ~= "" then cfg.maintGroup = p.maintGroup; mutated = true end
        if type(p.unit) == "table" and p.unit.id then
            local u = Scheduler.findUnit(cfg, p.unit.id)
            if not u then return { id = id, ok = false, error = "Unit not found" } end
            local pu = p.unit
            if type(pu.label) == "string" and pu.label ~= "" then u.label = pu.label end
            if type(pu.enabled) == "boolean" then u.enabled = pu.enabled end
            if tonumber(pu.tier) then u.tier = math.max(1, math.min(4, math.floor(tonumber(pu.tier)))) end
            if tonumber(pu.catalystDamage) then Scheduler.setUnitCatalyst(u, tonumber(pu.catalystDamage)) end
            if type(pu.recipeId) == "string" and RecipesDb.BY_ID[pu.recipeId] then
                local r = RecipesDb.BY_ID[pu.recipeId]
                u.recipeId = r.id
                if r.catalyst and r.catalyst.damage then u.catalystDamage = r.catalyst.damage end
            end
            if pu.mode == "passive" or pu.mode == "paused" then u.mode = pu.mode end
            if pu.targetStock ~= nil and tonumber(pu.targetStock) then u.targetStock = math.max(0, math.floor(tonumber(pu.targetStock))) end
            if pu.focusMode == "auto" or pu.focusMode == "fixed" or pu.focusMode == "none" then u.focusMode = pu.focusMode end
            if pu.focusCircuit ~= nil and tonumber(pu.focusCircuit) then u.focusCircuit = math.max(0, math.min(24, math.floor(tonumber(pu.focusCircuit)))) end
            if pu.boostNeptunium == "auto" or pu.boostNeptunium == "on" or pu.boostNeptunium == "off" then u.boostNeptunium = pu.boostNeptunium end
            if pu.boostFermium == "auto" or pu.boostFermium == "on" or pu.boostFermium == "off" then u.boostFermium = pu.boostFermium end
            if type(pu.controllerAddr) == "string" then u.controllerAddr = pu.controllerAddr end
            if type(pu.busAddr) == "string" then u.busAddr = pu.busAddr end
            if type(pu.hatchAddr) == "string" then u.hatchAddr = pu.hatchAddr end
            mutated = true
        end
    elseif op == "push_recipe_inputs" then
        local res = Scheduler.pushRecipeInputs(cfg, state, cmd, compLib)
        if onMutate then pcall(onMutate, cfg) end
        res.id = id
        res.maintStatus = Scheduler.getMaintainerStatus(cfg, state, clockNow(), compLib)
        return res
    elseif op == "retire_recipe_inputs" then
        local res = Scheduler.retireRecipeInputs(cfg, state, cmd, compLib)
        if onMutate then pcall(onMutate, cfg) end
        res.id = id
        res.maintStatus = Scheduler.getMaintainerStatus(cfg, state, clockNow(), compLib)
        return res
    elseif op == "action" or op == "qft_action" then
        local act = cmd.action
        if act == "arm" or act == "resume" then cfg.armed = true; mutated = true
        elseif act == "pause" then cfg.armed = false; mutated = true
        elseif act == "poll_now" or act == "poll" then
            Scheduler.step(cfg, state, clockNow(), compLib)
        elseif act == "rediscover" then
            local disc = Scheduler.syncHardware(cfg, state, compLib)
            Scheduler.autoBindDiscoveredUnits(cfg, disc)
            mutated = true
        elseif act == "sync_mainnet" then
            for _, lr in ipairs(cfg.localRules or {}) do
                if lr and lr.enabled ~= false then lr.syncedToMainnet = false end
            end
            state._lastAutoSyncAt = -1000
            Scheduler.step(cfg, state, clockNow(), compLib)
            if onMutate then pcall(onMutate, cfg) end
        elseif act == "add_unit" then
            Scheduler.addUnitFromDiscovery(cfg, "", "", "")
            mutated = true
        elseif act == "remove_unit" and type(cmd.unitId) == "string" then
            Scheduler.removeUnit(cfg, cmd.unitId)
            mutated = true
        elseif act == "update_local" then
            local cl = compLib or rawget(_G, "component")
            local tx = Common.detectOtaTransport(cl)
            if not tx.hasInternet and not tx.hasMesh then
                return { id = id, ok = false, error = "No Internet Card or OC Mesh modem/tunnel" }
            end
            local url = (type(cmd.url) == "string" and cmd.url ~= "") and cmd.url or Common.LOCAL_UPDATE_URL
            if not Common.isAllowedOtaUrl(url) then return { id = id, ok = false, error = "Invalid update URL" } end
            state._pendingUpdateUrl = url
            state._pendingReboot = true
            return { id = id, ok = true, updating = true, viaMesh = tx.viaMesh, url = url }
        elseif act == "reboot" then
            state._pendingReboot = true
            return { id = id, ok = true, rebooting = true }
        else
            return { id = id, ok = false, error = "Unknown action: " .. tostring(act) }
        end
    else
        return { id = id, ok = false, error = "Unknown op: " .. tostring(op) }
    end
    if mutated then
        Scheduler.step(cfg, state, clockNow(), compLib)
        if onMutate then pcall(onMutate, cfg) end
    end
    local snap = Scheduler.buildSnapshot(cfg, state)
    snap.id = id
    return snap
end

function Scheduler.renderDigest(cfg, state)
    local ms = (state and state.maintMode) or {}
    local running, reconf = 0, 0
    for _, u in ipairs((state and state.unitStatuses) or {}) do
        if u.active then running = running + 1 end
        if u.reconfiguring then reconf = reconf + 1 end
    end
    return string.format("%s:%d:%d:%d:%s:%d",
        tostring(cfg and cfg.armed == true), state and state.stepCount or 0,
        running, reconf, tostring(ms.mode), #((state and state.events) or {}))
end

return Scheduler
