-- /home/stock/lib/scheduler.lua
-- Staggered O(1) AE2 Stock Maintainer Scheduler, Hysteresis, Exponential Backoff,
-- CPU Headroom / Filter Routing, DTPF Overlap Advisories & Activity Logger.

local okComp, computer = pcall(require, "computer")
if not okComp then computer = nil end

local Hardware = require("lib.hardware")
local DtpfCatalog = require("lib.dtpf_catalog")

local Scheduler = {}

local MAX_LOG_EVENTS = 120

Scheduler.DEFAULT_GROUPS = { "General", "DTPF", "Gorge", "Power", "Chems", "Circuits", "Fluids" }

local function clockNow()
    if computer and computer.uptime then
        return computer.uptime()
    elseif os and os.clock then
        return os.clock()
    end
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
    else return string.format("%d%s", math.floor(n + 0.5), suf)
    end
end

function Scheduler.defaultConfig()
    return {
        armed = false,
        pollSec = 10,
        idlePollSec = 25,
        staggerBatch = 25,
        freeCpusReserve = 2,
        maxConcurrentCrafts = 16,
        maxDispatchPerCycle = 8,
        prioritizePower = true,
        defaultCpuFilter = "",
        backoffBaseSec = 30,
        backoffMaxSec = 600,
        dtpfWarnMode = "warn", -- "warn" | "block_overlap" | "off"
        extLinkMode = "auto", -- "auto" | "off"
        aeAddr = "auto",
        dropTransposerAddr = "auto",
        dropSide = -1,
        disablePhysicalAfterImport = false,
        groups = { "General", "DTPF", "Gorge", "Power", "Chems", "Circuits", "Fluids" },
        rules = {},
    }
end

function Scheduler.ruleKey(r)
    if type(r) ~= "table" then return "" end
    return DtpfCatalog.makeKey(r.type, r.name, r.damage)
end

local function sanitizeRule(r, idx)
    if type(r) ~= "table" or type(r.name) ~= "string" or r.name == "" then
        return nil
    end
    local tp = (r.type == "fluid") and "fluid" or "item"
    local dmg = (tp == "fluid") and 0 or math.max(0, math.floor(tonumber(r.damage) or 0))
    local tgt = math.max(1, math.floor(tonumber(r.target) or 64))
    local lowThr = tonumber(r.lowThreshold)
    if lowThr then
        lowThr = math.max(1, math.min(tgt, math.floor(lowThr)))
    end
    local bat = math.max(1, math.floor(tonumber(r.batch) or math.min(tgt, 64)))
    local bMode = (r.batchMode == "deficit") and "deficit" or "fixed"
    local maxBat = tonumber(r.maxBatch)
    if maxBat then maxBat = math.max(1, math.floor(maxBat)) end
    local rMode = r.mode
    if rMode ~= "always" and rMode ~= "auto-demand" and rMode ~= "off" then
        rMode = "always"
    end
    local prio = math.max(1, math.min(5, math.floor(tonumber(r.priority) or 3)))
    local grp = (type(r.group) == "string" and r.group ~= "") and r.group or "General"
    local id = (type(r.id) == "string" and r.id ~= "") and r.id
        or string.format("%s:%s:%d:%d", tp, r.name, dmg, idx or 1)
    return {
        id = id,
        type = tp,
        name = r.name,
        damage = dmg,
        label = tostring((type(r.label) == "string" and r.label ~= "") and r.label or r.name),
        hasTag = (r.hasTag == true),
        snbt = (type(r.snbt) == "string" and r.snbt ~= "") and r.snbt or nil,
        group = grp,
        priority = prio,
        target = tgt,
        lowThreshold = lowThr,
        batch = bat,
        batchMode = bMode,
        maxBatch = maxBat,
        cpuFilter = (type(r.cpuFilter) == "string") and r.cpuFilter or "",
        mode = rMode,
        enabled = (r.enabled ~= false) and (rMode ~= "off"),
        allowDtpfOverlap = (r.allowDtpfOverlap == true),
    }
end

function Scheduler.normalizeConfig(raw)
    local d = Scheduler.defaultConfig()
    if type(raw) ~= "table" then return d end

    d.armed = (raw.armed == true)
    d.pollSec = math.max(2, math.min(300, math.floor(tonumber(raw.pollSec) or d.pollSec)))
    d.idlePollSec = math.max(d.pollSec, math.min(300, math.floor(tonumber(raw.idlePollSec) or d.idlePollSec)))
    d.staggerBatch = math.max(5, math.min(500, math.floor(tonumber(raw.staggerBatch) or d.staggerBatch)))
    d.freeCpusReserve = math.max(0, math.min(32, math.floor(tonumber(raw.freeCpusReserve) or d.freeCpusReserve)))
    d.maxConcurrentCrafts = math.max(1, math.min(64, math.floor(tonumber(raw.maxConcurrentCrafts) or d.maxConcurrentCrafts)))
    d.maxDispatchPerCycle = math.max(1, math.min(32, math.floor(tonumber(raw.maxDispatchPerCycle) or d.maxDispatchPerCycle)))
    d.prioritizePower = (raw.prioritizePower ~= false)
    d.defaultCpuFilter = (type(raw.defaultCpuFilter) == "string") and raw.defaultCpuFilter or ""
    d.backoffBaseSec = math.max(5, math.min(300, math.floor(tonumber(raw.backoffBaseSec) or d.backoffBaseSec)))
    d.backoffMaxSec = math.max(d.backoffBaseSec, math.min(3600, math.floor(tonumber(raw.backoffMaxSec) or d.backoffMaxSec)))
    if raw.dtpfWarnMode == "warn" or raw.dtpfWarnMode == "block_overlap" or raw.dtpfWarnMode == "off" then
        d.dtpfWarnMode = raw.dtpfWarnMode
    end
    d.extLinkMode = (raw.extLinkMode == "off") and "off" or "auto"
    d.aeAddr = (type(raw.aeAddr) == "string" and raw.aeAddr ~= "") and raw.aeAddr or "auto"
    d.dropTransposerAddr = (type(raw.dropTransposerAddr) == "string" and raw.dropTransposerAddr ~= "") and raw.dropTransposerAddr or "auto"
    d.dropSide = math.max(-1, math.min(5, math.floor(tonumber(raw.dropSide) or -1)))
    d.disablePhysicalAfterImport = (raw.disablePhysicalAfterImport == true)

    if type(raw.groups) == "table" and #raw.groups > 0 then
        local gs, seenG = {}, {}
        for _, g in ipairs(raw.groups) do
            if type(g) == "string" and g ~= "" and not seenG[g] then
                seenG[g] = true
                gs[#gs + 1] = g
            end
        end
        if #gs > 0 then d.groups = gs end
    end

    local seenId = {}
    local cleanRules = {}
    if type(raw.rules) == "table" then
        for i = 1, #raw.rules do
            local cr = sanitizeRule(raw.rules[i], i)
            if cr then
                while seenId[cr.id] do
                    cr.id = cr.id .. "_" .. tostring(#cleanRules + 1)
                end
                seenId[cr.id] = true
                cleanRules[#cleanRules + 1] = cr
            end
        end
    end
    d.rules = cleanRules
    return d
end

function Scheduler.newState()
    return {
        stepCount = 0,
        scanCursor = 1,
        _idleSweeps = 0,
        discovery = {},
        _proxies = {},
        _craftableCache = {},
        _pendingJobs = {},
        _ruleTrack = {},
        _ruleCache = {},
        _cpuSnap = nil,
        dtpfPeer = nil,
        dropPreview = nil,
        physicalMaintainers = {},
        lastBenchmark = nil,
        ruleStatuses = {},
        kpis = {
            total = 0,
            enabled = 0,
            ok = 0,
            low = 0,
            crafting = 0,
            errors = 0,
            warnings = 0,
            freeCpus = 0,
            totalCpus = 0,
            activeMaintCrafts = 0,
            aeLink = "none",
        },
        perf = {
            lastCycleMs = 0,
            avgCycleMs = 0,
            aeCallsLast = 0,
            aeCallsPerSec = 0,
            o1Mode = false,
            idleMode = false,
            craftableCacheSize = 0,
            freeMemKB = 0,
            totalMemKB = 0,
            luaHeapKB = 0,
            equivBlocksSaved = 0,
            equivChannelsSaved = 0,
        },
        events = {},
    }
end

function Scheduler.pushLog(state, kind, text, stage)
    if not state or type(text) ~= "string" or text == "" then return end
    state.events = state.events or {}
    local top = state.events[1]
    local stg = stage or ((kind == "err" and "ERR") or (kind == "warn" and "WRN") or (kind == "out" and "OUT") or "DEC")
    if top and top.text == text and top.stage == stg then return end
    table.insert(state.events, 1, {
        step = state.stepCount or 0,
        uptime = clockNow(),
        stage = stg,
        kind = kind or "info",
        text = text,
    })
    for _ = 1, 8 do
        if #state.events <= MAX_LOG_EVENTS then break end
        table.remove(state.events)
    end
end

function Scheduler.findRule(cfg, rType, name, damage, id)
    local rules = (cfg and cfg.rules) or {}
    if type(id) == "string" and id ~= "" then
        for i = 1, #rules do
            if rules[i] and rules[i].id == id then
                return rules[i], i
            end
        end
    end
    if type(name) == "string" and name ~= "" then
        local tp = (rType == "fluid") and "fluid" or "item"
        local dmg = (tp == "fluid") and 0 or math.max(0, math.floor(tonumber(damage) or 0))
        for i = 1, #rules do
            local r = rules[i]
            if r and ((r.type == "fluid") and "fluid" or "item") == tp and r.name == name then
                if tp == "fluid" or math.max(0, math.floor(tonumber(r.damage) or 0)) == dmg then
                    return r, i
                end
            end
        end
    end
    return nil, nil
end

function Scheduler.upsertRule(cfg, spec)
    if not cfg or type(spec) ~= "table" then return nil, nil, false, "invalid rule spec" end
    cfg.rules = cfg.rules or {}
    local existing, idx = Scheduler.findRule(cfg, spec.type, spec.name, spec.damage, spec.id)
    if existing then
        if type(spec.label) == "string" and spec.label ~= "" then existing.label = spec.label end
        if type(spec.group) == "string" and spec.group ~= "" then existing.group = spec.group end
        if spec.priority ~= nil and tonumber(spec.priority) then
            existing.priority = math.max(1, math.min(5, math.floor(tonumber(spec.priority))))
        end
        if spec.target ~= nil and tonumber(spec.target) then
            existing.target = math.max(1, math.floor(tonumber(spec.target)))
        end
        if spec.lowThreshold ~= nil then
            if spec.lowThreshold == false or spec.lowThreshold == "" then
                existing.lowThreshold = nil
            elseif tonumber(spec.lowThreshold) then
                existing.lowThreshold = math.max(1, math.min(existing.target, math.floor(tonumber(spec.lowThreshold))))
            end
        elseif existing.lowThreshold and existing.lowThreshold > existing.target then
            existing.lowThreshold = existing.target
        end
        if spec.batch ~= nil and tonumber(spec.batch) then
            existing.batch = math.max(1, math.floor(tonumber(spec.batch)))
        end
        if spec.batchMode == "fixed" or spec.batchMode == "deficit" then
            existing.batchMode = spec.batchMode
        end
        if spec.maxBatch ~= nil then
            existing.maxBatch = tonumber(spec.maxBatch) and math.max(1, math.floor(tonumber(spec.maxBatch))) or nil
        end
        if type(spec.cpuFilter) == "string" then
            existing.cpuFilter = spec.cpuFilter
        end
        if spec.mode == "always" or spec.mode == "auto-demand" or spec.mode == "off" then
            existing.mode = spec.mode
            existing.enabled = (spec.mode ~= "off")
        end
        if type(spec.enabled) == "boolean" then
            existing.enabled = spec.enabled
            if existing.enabled and existing.mode == "off" then
                existing.mode = "always"
            end
        end
        if type(spec.allowDtpfOverlap) == "boolean" then
            existing.allowDtpfOverlap = spec.allowDtpfOverlap
        end
        if type(spec.hasTag) == "boolean" then existing.hasTag = spec.hasTag end
        if type(spec.snbt) == "string" then existing.snbt = spec.snbt ~= "" and spec.snbt or nil end
        return existing, idx, false
    end

    local nextIdx = #cfg.rules + 1
    local cr = sanitizeRule(spec, nextIdx)
    if not cr then
        return nil, nil, false, "rule.name required"
    end
    local seen = {}
    for i = 1, #cfg.rules do
        if cfg.rules[i] then seen[cfg.rules[i].id] = true end
    end
    while seen[cr.id] do
        nextIdx = nextIdx + 1
        cr.id = string.format("%s:%s:%d:%d", cr.type, cr.name, cr.damage, nextIdx)
    end
    cfg.rules[#cfg.rules + 1] = cr
    return cr, #cfg.rules, true
end

function Scheduler.deleteRule(cfg, id, state)
    if not cfg or type(cfg.rules) ~= "table" then return false end
    for i = 1, #cfg.rules do
        if cfg.rules[i] and cfg.rules[i].id == id then
            table.remove(cfg.rules, i)
            if state then
                if state._ruleTrack then state._ruleTrack[id] = nil end
                if state._ruleCache then state._ruleCache[id] = nil end
                if state._pendingJobs then state._pendingJobs[id] = nil end
            end
            return true
        end
    end
    return false
end

function Scheduler.toggleRule(cfg, id)
    local r = Scheduler.findRule(cfg, nil, nil, nil, id)
    if not r then return nil end
    r.enabled = not (r.enabled ~= false)
    if r.enabled and r.mode == "off" then r.mode = "always" end
    return r
end

function Scheduler.setGroupEnabled(cfg, group, enabled)
    local count = 0
    for _, r in ipairs((cfg and cfg.rules) or {}) do
        if r and r.group == group then
            r.enabled = (enabled == true)
            if r.enabled and r.mode == "off" then r.mode = "always" end
            count = count + 1
        end
    end
    return count
end

function Scheduler.importPhysicalSlots(cfg, slots, opts)
    opts = opts or {}
    local added, updated, skipped, skippedDtpf, disabled = 0, 0, 0, 0, 0
    for i = 1, #(slots or {}) do
        local s = slots[i]
        if type(s) == "table" and type(s.name) == "string" and s.name ~= "" then
            if (not s.enabled) and not opts.includeDisabled then
                skipped = skipped + 1
            elseif opts.skipDtpfPassives == true and DtpfCatalog.lookup(s.type, s.name, s.damage) ~= nil then
                skippedDtpf = skippedDtpf + 1
            else
                local existing = Scheduler.findRule(cfg, s.type, s.name, s.damage)
                if existing and not opts.overwrite then
                    skipped = skipped + 1
                else
                    local _, _, isNew = Scheduler.upsertRule(cfg, {
                        type = s.type,
                        name = s.name,
                        damage = s.damage or 0,
                        label = s.label,
                        hasTag = s.hasTag == true,
                        target = s.target,
                        batch = s.batch,
                        group = opts.group or ((s.type == "fluid") and "Fluids" or "General"),
                        enabled = (s.enabled ~= false),
                        mode = (s.enabled ~= false) and "always" or "off",
                    })
                    if isNew then added = added + 1 else updated = updated + 1 end
                    if opts.disablePhysical and opts.disableFn and s.addr and s.slot then
                        if opts.disableFn(s.addr, s.slot) then
                            disabled = disabled + 1
                        end
                    end
                end
            end
        end
    end
    return { added = added, updated = updated, skipped = skipped, skippedDtpf = skippedDtpf, disabled = disabled }
end

function Scheduler.buildDtpfHandoffItems(cfg, state, ruleIds)
    local rules = (cfg and cfg.rules) or {}
    local idSet = nil
    if type(ruleIds) == "table" and #ruleIds > 0 then
        idSet = {}
        for _, rid in ipairs(ruleIds) do
            idSet[tostring(rid)] = true
        end
    end
    local warnById = {}
    for _, rs in ipairs((state and state.ruleStatuses) or {}) do
        if rs and rs.id and rs.warnKind then
            warnById[rs.id] = rs.warnKind
        end
    end

    local items = {}
    for _, r in ipairs(rules) do
        if type(r) == "table" and type(r.name) == "string" and r.name ~= "" then
            local cat = DtpfCatalog.lookup(r.type, r.name, r.damage)
            local wk = warnById[r.id]
            local selected = idSet and (idSet[r.id] == true)
                or ((not idSet) and (r.enabled ~= false) and (r.mode ~= "off")
                    and (cat ~= nil or wk == "dtpf_maint_overlap" or wk == "dtpf_passive_active"))
            if selected then
                items[#items + 1] = {
                    ruleId = r.id,
                    kind = cat and "passive" or "maint",
                    familyId = cat and cat.familyId or nil,
                    type = r.type,
                    name = r.name,
                    damage = math.max(0, math.floor(tonumber(r.damage) or 0)),
                    label = r.label or r.name,
                    target = math.max(1, math.floor(tonumber(r.target) or 1)),
                    lowThreshold = r.lowThreshold,
                    batch = math.max(1, math.floor(tonumber(r.batch) or 1)),
                    mode = "auto",
                }
            end
        end
    end
    return items
end

function Scheduler.applyDtpfHandoffAck(cfg, state, ackTbl)
    if type(ackTbl) ~= "table" then return 0 end
    local ids = ackTbl.acceptedIds
    if type(ids) ~= "table" or #ids == 0 then return 0 end
    local changed = 0
    local remove = (ackTbl.remove == true)
    for _, rid in ipairs(ids) do
        if remove then
            if Scheduler.deleteRule(cfg, rid, state) then
                changed = changed + 1
            end
        else
            local r = Scheduler.findRule(cfg, nil, nil, nil, rid)
            if r then
                r.enabled = false
                r.mode = "off"
                changed = changed + 1
            end
        end
    end
    if changed > 0 then
        Scheduler.pushLog(state, "out", string.format("Handed off %d rule(s) to DTPF (%d passive, %d maint); %s locally.",
            changed, tonumber(ackTbl.passiveCount) or 0, tonumber(ackTbl.maintCount) or 0, remove and "deleted" or "paused"), "OUT")
    end
    return changed
end

function Scheduler.getDtpfInfo(rule, dtpfPeer, nowSec)
    if not rule or type(dtpfPeer) ~= "table" then return nil end
    local peerFresh = ((nowSec - (tonumber(dtpfPeer.lastSeen) or -1000)) < 60)
    if not peerFresh then return nil end
    local key = Scheduler.ruleKey(rule)
    local mTbl = (dtpfPeer.maintEnabled == true and type(dtpfPeer.maintInfo) == "table") and dtpfPeer.maintInfo[key] or nil
    if type(mTbl) == "table" then
        return {
            role = "input",
            label = mTbl.l or rule.label or mTbl.n or rule.name,
            target = tonumber(mTbl.tgt) or 0,
            batch = tonumber(mTbl.bat) or 0,
            stock = tonumber(mTbl.stk) or 0,
            mode = mTbl.m,
            state = mTbl.st,
        }
    end
    local pTbl = (type(dtpfPeer.passiveInfo) == "table") and dtpfPeer.passiveInfo[key] or nil
    if type(pTbl) == "table" then
        return {
            role = "passive",
            familyId = pTbl.fid,
            label = pTbl.l or rule.label or pTbl.n or rule.name,
            target = tonumber(pTbl.tgt) or 0,
            stock = tonumber(pTbl.stk) or 0,
            forever = (pTbl.fv == true),
        }
    end
    return nil
end

function Scheduler.classifyDtpfWarning(cfg, rule, dtpfPeer, nowSec)
    if not cfg or cfg.dtpfWarnMode == "off" or not rule or rule.allowDtpfOverlap == true then
        return nil, nil
    end
    local key = Scheduler.ruleKey(rule)
    local isFl = (rule.type == "fluid")
    local peerFresh = (type(dtpfPeer) == "table") and ((nowSec - (tonumber(dtpfPeer.lastSeen) or -1000)) < 60)
    if peerFresh then
        local info = Scheduler.getDtpfInfo(rule, dtpfPeer, nowSec)
        if dtpfPeer.maintEnabled == true and type(dtpfPeer.maintKeys) == "table" and dtpfPeer.maintKeys[key] == true then
            if info and info.role == "input" then
                return "dtpf_maint_overlap", string.format("◈ DTPF Input @ %s/%s",
                    fmtCompact(info.stock, isFl), fmtCompact(info.target, isFl))
            end
            return "dtpf_maint_overlap", "! Overlap: DTPF Maint also tracks this"
        end
        if type(dtpfPeer.passiveKeys) == "table" and dtpfPeer.passiveKeys[key] == true then
            if info and info.role == "passive" then
                if info.forever and (tonumber(info.target) or 0) <= 0 then
                    return "dtpf_passive_active", string.format("◈ DTPF Passive (%s · 24/7)", fmtCompact(info.stock, isFl))
                end
                return "dtpf_passive_active", string.format("◈ DTPF Passive @ %s/%s",
                    fmtCompact(info.stock, isFl), fmtCompact(info.target, isFl))
            end
            return "dtpf_passive_active", "! DTPF Passive Queue actively produces this"
        end
    end
    local cat = DtpfCatalog.lookup(rule.type, rule.name, rule.damage)
    if cat then
        return "dtpf_passive_capable", "! DTPF Passive recipe exists (" .. tostring(cat.name) .. ")"
    end
    return nil, nil
end

function Scheduler.syncHardware(cfg, state, compLib)
    return Hardware.discover(cfg, compLib, state)
end

function Scheduler.clearBackoffs(state)
    local cleared = 0
    for _, tr in pairs((state and state._ruleTrack) or {}) do
        if type(tr) == "table" and ((tr.backoffUntil or 0) > 0 or tr.lastError) then
            tr.backoffUntil = 0
            tr.failCount = 0
            tr.lastError = nil
            cleared = cleared + 1
        end
    end
    return cleared
end

function Scheduler.nextWakeupDelay(cfg, state, nowSec)
    local pollSec = math.max(2, tonumber(cfg and cfg.pollSec) or 10)
    local enabledN = 0
    for _, r in ipairs((cfg and cfg.rules) or {}) do
        if r and r.enabled ~= false and r.mode ~= "off" then
            enabledN = enabledN + 1
        end
    end
    local totalRules = (enabledN > 0) and enabledN or #((cfg and cfg.rules) or {})
    local batch = math.max(5, tonumber(cfg and cfg.staggerBatch) or 25)
    local slices = math.max(1, math.ceil(totalRules / batch))
    local effPoll = pollSec
    if state and (state._idleSweeps or 0) >= slices then
        effPoll = math.max(pollSec, tonumber(cfg and cfg.idlePollSec) or 25)
    end
    local sliceDelay = (slices > 1) and math.max(1.0, effPoll / slices) or effPoll
    if state and state._lastStepAt then
        local nextAt = state._lastStepAt + sliceDelay
        return math.max(0.25, nextAt - (nowSec or clockNow()))
    end
    return sliceDelay
end

function Scheduler.step(cfg, state, nowSec, compLib, opts)
    opts = opts or {}
    nowSec = nowSec or clockNow()
    state = state or Scheduler.newState()
    state.stepCount = (state.stepCount or 0) + 1
    state._ruleTrack = state._ruleTrack or {}
    state._ruleCache = state._ruleCache or {}
    state._pendingJobs = state._pendingJobs or {}

    local tStart = clockNow()
    local counter = { aeCalls = 0 }

    local ae, aeAddr = Hardware.getAeProxy(cfg, compLib, state)
    local aeLink = ae and "adapter" or "none"

    -- 1. Poll pending async craft computations & live ICraftingLinks
    local pendingRes = Hardware.pollPendingStatuses(state._pendingJobs, counter)
    local dueRefreshIds = {}
    local baseBackoff = math.max(5, tonumber(cfg and cfg.backoffBaseSec) or 30)
    local maxBackoff = math.max(baseBackoff, tonumber(cfg and cfg.backoffMaxSec) or 600)
    for rid, failWhy in pairs(pendingRes.failed) do
        local tr = state._ruleTrack[rid] or {}
        tr.inFlightUntil = 0
        tr.failCount = (tr.failCount or 0) + 1
        local waitSec = math.min(maxBackoff, baseBackoff * (2 ^ math.min(5, tr.failCount - 1)))
        tr.backoffUntil = nowSec + waitSec
        tr.lastError = failWhy
        state._ruleTrack[rid] = tr
        Scheduler.pushLog(state, "err", string.format("Craft failed (%s): %s", tostring(rid), tostring(failWhy)), "ERR")
    end
    for rid in pairs(pendingRes.done) do
        local tr = state._ruleTrack[rid] or {}
        tr.inFlightUntil = 0
        tr.failCount = 0
        tr.lastError = nil
        state._ruleTrack[rid] = tr
        dueRefreshIds[rid] = true
        state._idleSweeps = 0
    end

    -- 2. Inspect CPUs once per cycle (lazy busy finalOutput inspection)
    local cpuSnap = ae and Hardware.inspectCpus(ae, counter, { fetchOutputs = false })
        or { ok = false, totalCpus = 0, freeCpus = 0, busyByKey = {}, busyByLabel = {}, freeList = {}, _outputsFetched = true }
    if cpuSnap.ok then
        state._cpuSnap = cpuSnap
    elseif state._cpuSnap then
        cpuSnap = state._cpuSnap
    end

    local rules = (cfg and cfg.rules) or {}
    local nRules = #rules

    -- 3. Decide which slice of enabled rules to refresh this cycle (staggered O(1) polling)
    local enabledIdx = {}
    for i = 1, nRules do
        local r = rules[i]
        if r and r.enabled ~= false and r.mode ~= "off" then
            enabledIdx[#enabledIdx + 1] = i
        end
    end

    local refreshSet = {}
    local batchLimit = math.max(5, tonumber(cfg and cfg.staggerBatch) or 25)
    if opts.forceFull or #enabledIdx <= batchLimit then
        for _, idx in ipairs(enabledIdx) do refreshSet[idx] = true end
        state.scanCursor = 1
    elseif #enabledIdx > 0 then
        local cur = math.max(1, math.min(#enabledIdx, state.scanCursor or 1))
        for _ = 1, batchLimit do
            refreshSet[enabledIdx[cur]] = true
            cur = (cur % #enabledIdx) + 1
        end
        state.scanCursor = cur
    end

    local dueFluids = 0
    for i = 1, nRules do
        local r = rules[i]
        if r and r.enabled ~= false and r.mode ~= "off" and r.type == "fluid"
            and (refreshSet[i] or dueRefreshIds[r.id])
            and not (pendingRes.computing[r.id] or pendingRes.running[r.id]) then
            dueFluids = dueFluids + 1
        end
    end

    local hasO1Fluid = (ae ~= nil and type(ae.getFluidInNetwork) == "function")
    local bulkFluidThreshold = hasO1Fluid and 25 or 1
    local fluidFallbackRef = {}
    if ae and not opts.dryRun and not opts.cachedOnly and dueFluids >= bulkFluidThreshold and type(ae.getFluidsInNetwork) == "function" then
        fluidFallbackRef = Hardware.fetchFluidStockMap(ae, counter) or fluidFallbackRef
    end
    local busyByKey = cpuSnap.busyByKey or {}
    local busyByLabel = cpuSnap.busyByLabel or {}
    local freeCpus = tonumber(cpuSnap.freeCpus) or 0
    local totalCpus = tonumber(cpuSnap.totalCpus) or 0
    local freeReserve = math.max(0, tonumber(cfg and cfg.freeCpusReserve) or 2)
    local maxConcurrent = math.max(1, tonumber(cfg and cfg.maxConcurrentCrafts) or 16)
    local maxDispatch = math.max(1, tonumber(cfg and cfg.maxDispatchPerCycle) or 8)

    local okCnt, lowCnt, craftCnt, errCnt, warnCnt, activeMaintCrafts = 0, 0, 0, 0, 0, 0
    local statusesOut = {}
    local dispatchQueue = {}

    for i = 1, nRules do
        local r = rules[i]
        local k = Scheduler.ruleKey(r)
        local tr = state._ruleTrack[r.id] or {}
        if tr.inFlightUntil and nowSec >= tr.inFlightUntil then tr.inFlightUntil = 0 end
        if tr.backoffUntil and nowSec >= tr.backoffUntil then tr.backoffUntil = 0 end

        local isPendingLink = (pendingRes.computing[r.id] == true) or (pendingRes.running[r.id] == true)
        local cached = state._ruleCache[r.id] or { stock = 0, stockKnown = false }
        if ae and (refreshSet[i] or dueRefreshIds[r.id]) and (not isPendingLink) and not opts.dryRun and not opts.cachedOnly then
            local qty, known = Hardware.queryRuleStock(ae, r, fluidFallbackRef, counter)
            cached = { stock = qty, stockKnown = known, at = nowSec }
            state._ruleCache[r.id] = cached
        end

        local curStock = cached.stock or 0
        local stockKnown = (cached.stockKnown == true)
        local tgt = math.max(1, tonumber(r.target) or 1)
        local lowThr = math.min(tgt, math.max(1, tonumber(r.lowThreshold) or tgt))
        local pct = math.min(999.9, (curStock / tgt) * 100.0)

        local dtpfInfo = Scheduler.getDtpfInfo(r, state.dtpfPeer, nowSec)
        local warnKind, warnText = Scheduler.classifyDtpfWarning(cfg, r, state.dtpfPeer, nowSec)
        if warnText then
            warnCnt = warnCnt + 1
            if tr._lastWarnKind ~= warnKind then
                tr._lastWarnKind = warnKind
                state._ruleTrack[r.id] = tr
                Scheduler.pushLog(state, "warn", string.format("%s: %s", r.label, warnText), "WRN")
            end
        else
            tr._lastWarnKind = nil
        end

        local busyCpu = busyByKey[k] or busyByLabel[r.label]
        local inFlight = (not busyCpu) and ((tr.inFlightUntil or 0) > nowSec)
        local inBackoff = ((tr.backoffUntil or 0) > nowSec)
        local stTag = "OK"
        local stDetail = "OK"

        if r.enabled == false or r.mode == "off" then
            stTag = "OFF"
            stDetail = "Disabled"
        elseif isPendingLink then
            craftCnt = craftCnt + 1
            activeMaintCrafts = activeMaintCrafts + 1
            tr.failCount = 0
            tr.lastError = nil
            stTag = "CRAFT"
            stDetail = pendingRes.computing[r.id] and "Computing..." or "Crafting (Link)"
        elseif busyCpu then
            craftCnt = craftCnt + 1
            activeMaintCrafts = activeMaintCrafts + 1
            tr.inFlightUntil = 0
            tr.failCount = 0
            tr.lastError = nil
            stTag = "CRAFT"
            stDetail = "Crafting (" .. tostring(busyCpu) .. ")"
        elseif inFlight then
            craftCnt = craftCnt + 1
            activeMaintCrafts = activeMaintCrafts + 1
            stTag = "CRAFT"
            stDetail = "Starting..."
        elseif warnKind == "dtpf_maint_overlap" and cfg.dtpfWarnMode == "block_overlap" then
            stTag = "WARN"
            stDetail = "Blocked (DTPF Overlap)"
        elseif not ae or not cpuSnap.ok then
            stTag = "ERR"
            stDetail = cpuSnap.error or "No AE2 Connection"
            errCnt = errCnt + 1
        elseif stockKnown and curStock < lowThr then
            lowCnt = lowCnt + 1
            if inBackoff then
                errCnt = errCnt + 1
                stTag = "ERR"
                stDetail = string.format("Backoff %ds (%s)", math.max(1, math.ceil(tr.backoffUntil - nowSec)), tostring(tr.lastError or "error"))
            elseif activeMaintCrafts >= maxConcurrent then
                stTag = "LOW"
                stDetail = string.format("Max Crafts (%d/%d)", activeMaintCrafts, maxConcurrent)
            elseif freeCpus <= freeReserve then
                stTag = "LOW"
                stDetail = string.format("CPU Reserve (%d/%d free)", freeCpus, freeReserve)
            else
                stTag = "LOW"
                stDetail = (cfg.armed == true) and "Queued" or "Low (Paused)"
                local deficit = (tgt - curStock) / tgt
                dispatchQueue[#dispatchQueue + 1] = {
                    rule = r,
                    key = k,
                    stock = curStock,
                    deficit = deficit,
                    track = tr,
                    outIdx = i,
                }
            end
        elseif stockKnown then
            okCnt = okCnt + 1
            tr.failCount = 0
            tr.lastError = nil
            stTag = "OK"
            stDetail = (curStock < tgt) and "Hysteresis Hold" or "OK"
        else
            stTag = "LOW"
            stDetail = "Pending Scan"
        end

        statusesOut[i] = {
            id = r.id,
            type = r.type,
            name = r.name,
            damage = r.damage,
            label = r.label,
            group = r.group,
            priority = r.priority,
            target = tgt,
            lowThreshold = lowThr,
            batch = r.batch,
            batchMode = r.batchMode,
            enabled = (r.enabled ~= false) and (r.mode ~= "off"),
            stock = curStock,
            stockKnown = stockKnown,
            pct = pct,
            state = stTag,
            stateDetail = stDetail,
            cpu = busyCpu,
            warnKind = warnKind,
            warn = warnText,
            dtpfInfo = dtpfInfo,
            error = tr.lastError,
            backoffRemSec = inBackoff and math.max(0, math.ceil(tr.backoffUntil - nowSec)) or 0,
        }
    end

    -- 4. Lazy busy-CPU output inspection & deduplication before dispatching
    if #dispatchQueue > 0 and (cfg.armed == true or opts.forceFull) and ae and cpuSnap.ok and not opts.dryRun and not opts.cachedOnly then
        if not cpuSnap._outputsFetched then
            Hardware.fetchBusyCpuOutputs(cpuSnap, counter)
            busyByKey = cpuSnap.busyByKey or busyByKey
            busyByLabel = cpuSnap.busyByLabel or busyByLabel
        end
        local kept = {}
        for _, job in ipairs(dispatchQueue) do
            local r = job.rule
            local busyCpu = busyByKey[job.key] or busyByLabel[r.label]
            if busyCpu then
                local tr = job.track
                tr.inFlightUntil = 0
                tr.failCount = 0
                tr.lastError = nil
                craftCnt = craftCnt + 1
                lowCnt = math.max(0, lowCnt - 1)
                activeMaintCrafts = activeMaintCrafts + 1
                statusesOut[job.outIdx].state = "CRAFT"
                statusesOut[job.outIdx].cpu = busyCpu
                statusesOut[job.outIdx].stateDetail = "Crafting (" .. tostring(busyCpu) .. ")"
            else
                kept[#kept + 1] = job
            end
        end
        dispatchQueue = kept
    end

    -- 5. Dispatch prioritized crafts with fair equal-priority round-robin when armed
    if (cfg and cfg.armed == true) and ae and cpuSnap.ok and not opts.dryRun and not opts.cachedOnly and #dispatchQueue > 0 then
        table.sort(dispatchQueue, function(a, b)
            local pa = tonumber(a.rule.priority) or 3
            local pb = tonumber(b.rule.priority) or 3
            if pa ~= pb then return pa < pb end
            local da = tonumber(a.track and a.track.lastDispatchedAt) or 0
            local db = tonumber(b.track and b.track.lastDispatchedAt) or 0
            if da ~= db then return da < db end
            if math.abs(a.deficit - b.deficit) > 0.001 then return a.deficit > b.deficit end
            return tostring(a.rule.id) < tostring(b.rule.id)
        end)

        local availCpus = {}
        for _, c in ipairs(cpuSnap.freeList or {}) do availCpus[#availCpus + 1] = c end
        local headRoom = math.max(0, freeCpus - freeReserve)
        local concRoom = math.max(0, maxConcurrent - activeMaintCrafts)
        local budget = math.min(maxDispatch, headRoom, concRoom, #dispatchQueue)

        for dIdx = 1, budget do
            local job = dispatchQueue[dIdx]
            local r = job.rule
            local tr = job.track

            local filterStr = (r.cpuFilter and r.cpuFilter ~= "") and r.cpuFilter or (cfg.defaultCpuFilter or "")
            local chosenCpu, cpuErr = Hardware.selectCpuName(availCpus, filterStr)
            if filterStr ~= "" and filterStr ~= "auto" and not chosenCpu then
                statusesOut[job.outIdx].stateDetail = tostring(cpuErr or "CPU busy")
            else
                local amt
                if r.batchMode == "deficit" then
                    amt = math.max(1, r.target - job.stock)
                    if r.maxBatch then amt = math.min(amt, r.maxBatch) end
                else
                    amt = math.max(1, r.batch)
                end

                local ack = Hardware.requestCraft(ae, r, amt, cfg.prioritizePower ~= false, chosenCpu, counter, state)
                if ack and ack.ok then
                    tr.inFlightUntil = nowSec + 90
                    tr.lastDispatchedAt = nowSec
                    tr.lastError = nil
                    tr.failCount = 0
                    state._ruleTrack[r.id] = tr
                    if ack.statusObj then
                        state._pendingJobs[r.id] = ack.statusObj
                    end
                    if chosenCpu then
                        for ci = 1, #availCpus do
                            if availCpus[ci].name == chosenCpu then
                                table.remove(availCpus, ci)
                                break
                            end
                        end
                    end
                    craftCnt = craftCnt + 1
                    lowCnt = math.max(0, lowCnt - 1)
                    statusesOut[job.outIdx].state = "CRAFT"
                    statusesOut[job.outIdx].stateDetail = (ack.status == "computing") and "Computing..." or "Dispatched"
                    Scheduler.pushLog(state, "out", string.format("+%s %s%s",
                        fmtCompact(amt, r.type == "fluid"), r.label,
                        chosenCpu and (" [" .. chosenCpu .. "]") or ""), "OUT")
                else
                    tr.failCount = (tr.failCount or 0) + 1
                    local waitSec = math.min(maxBackoff, baseBackoff * (2 ^ math.min(5, tr.failCount - 1)))
                    tr.backoffUntil = nowSec + waitSec
                    tr.lastError = (ack and ack.error) or "Request failed"
                    state._ruleTrack[r.id] = tr
                    errCnt = errCnt + 1
                    statusesOut[job.outIdx].state = "ERR"
                    statusesOut[job.outIdx].error = tr.lastError
                    statusesOut[job.outIdx].stateDetail = string.format("Wait %ds (%s)", waitSec, tostring(tr.lastError))
                    Scheduler.pushLog(state, "err", string.format("%s failed (%ds backoff): %s", r.label, waitSec, tostring(tr.lastError)), "ERR")
                end
            end
        end
    end

    if lowCnt == 0 and craftCnt == 0 and errCnt == 0 then
        state._idleSweeps = (state._idleSweeps or 0) + 1
    else
        state._idleSweeps = 0
    end

    local cacheSz = 0
    for _ in pairs(state._craftableCache or {}) do cacheSz = cacheSz + 1 end
    local dtMs = math.max(0, (clockNow() - tStart) * 1000.0)
    local prevAvg = (state.perf and state.perf.avgCycleMs) or dtMs
    local avgMs = (state.stepCount == 1) and dtMs or (prevAvg * 0.8 + dtMs * 0.2)
    local freeKB = (computer and computer.freeMemory and (computer.freeMemory() / 1024)) or 0
    local totalKB = (computer and computer.totalMemory and (computer.totalMemory() / 1024)) or 0
    local gcFn = rawget(_G, "collectgarbage")
    local luaKB = (type(gcFn) == "function") and gcFn("count") or math.max(0, totalKB - freeKB)
    local equivBlocks = math.ceil(math.max(0, #enabledIdx) / 5)
    local slices = math.max(1, math.ceil(math.max(1, #enabledIdx) / batchLimit))
    local pollSec = math.max(2, tonumber(cfg and cfg.pollSec) or 10)

    state._lastStepAt = nowSec
    state.ruleStatuses = statusesOut
    state.kpis = {
        total = nRules,
        enabled = #enabledIdx,
        ok = okCnt,
        low = lowCnt,
        crafting = craftCnt,
        errors = errCnt,
        warnings = warnCnt,
        freeCpus = freeCpus,
        totalCpus = totalCpus,
        activeMaintCrafts = activeMaintCrafts,
        aeLink = aeLink,
        aeAddr = aeAddr,
    }
    state.perf = {
        lastCycleMs = math.floor(dtMs * 100 + 0.5) / 100,
        avgCycleMs = math.floor(avgMs * 100 + 0.5) / 100,
        aeCallsLast = counter.aeCalls,
        aeCallsPerSec = math.floor((counter.aeCalls / pollSec) * 100 + 0.5) / 100,
        o1Mode = (state.discovery and state.discovery.hasO1Item and state.discovery.hasO1Fluid) == true,
        idleMode = ((state._idleSweeps or 0) >= slices),
        craftableCacheSize = cacheSz,
        freeMemKB = math.floor(freeKB),
        totalMemKB = math.floor(totalKB),
        luaHeapKB = math.floor(luaKB),
        equivBlocksSaved = equivBlocks,
        equivChannelsSaved = equivBlocks,
    }
    return state
end

function Scheduler.buildSnapshot(cfg, state, nowSec)
    nowSec = nowSec or clockNow()
    local kpis = (state and state.kpis) or {}
    local perf = (state and state.perf) or {}
    local dtpfPeer = state and state.dtpfPeer
    local dtpfOnline = (type(dtpfPeer) == "table") and ((nowSec - (tonumber(dtpfPeer.lastSeen) or -1000)) < 60)

    local rulesOut = {}
    local stById = {}
    for _, rs in ipairs((state and state.ruleStatuses) or {}) do
        if rs and rs.id then stById[rs.id] = rs end
    end
    for i, r in ipairs((cfg and cfg.rules) or {}) do
        local sr = stById[r.id] or {}
        rulesOut[i] = {
            id = r.id,
            type = r.type,
            name = r.name,
            damage = r.damage,
            label = r.label,
            hasTag = r.hasTag == true,
            group = r.group,
            priority = r.priority,
            target = r.target,
            lowThreshold = r.lowThreshold,
            batch = r.batch,
            batchMode = r.batchMode,
            maxBatch = r.maxBatch,
            cpuFilter = r.cpuFilter,
            mode = r.mode,
            enabled = r.enabled ~= false,
            allowDtpfOverlap = r.allowDtpfOverlap == true,
            stock = sr.stock or 0,
            stockKnown = sr.stockKnown == true,
            pct = sr.pct or 0,
            state = sr.state or ((r.enabled == false) and "OFF" or "LOW"),
            stateDetail = sr.stateDetail or ((r.enabled == false) and "Disabled" or "Pending"),
            cpu = sr.cpu,
            warnKind = sr.warnKind,
            warn = sr.warn,
            dtpfInfo = sr.dtpfInfo,
            error = sr.error,
        }
    end

    local evOut = {}
    for i = 1, math.min(25, #((state and state.events) or {})) do
        local e = state.events[i]
        evOut[i] = { step = e.step, stage = e.stage, kind = e.kind, text = e.text }
    end

    local dtpfLevels = {}
    if dtpfOnline and type(dtpfPeer) == "table" then
        if dtpfPeer.maintEnabled == true and type(dtpfPeer.maintInfo) == "table" then
            for k, v in pairs(dtpfPeer.maintInfo) do
                if type(v) == "table" then
                    dtpfLevels[k] = {
                        role = "input",
                        type = v.t or "item",
                        name = v.n,
                        damage = tonumber(v.d) or 0,
                        label = v.l or v.n,
                        target = tonumber(v.tgt) or 0,
                        batch = tonumber(v.bat) or 0,
                        stock = tonumber(v.stk) or 0,
                        mode = v.m,
                        state = v.st,
                    }
                end
            end
        end
        if type(dtpfPeer.passiveInfo) == "table" then
            for k, v in pairs(dtpfPeer.passiveInfo) do
                if type(v) == "table" and not dtpfLevels[k] then
                    dtpfLevels[k] = {
                        role = "passive",
                        familyId = v.fid,
                        type = v.t or "fluid",
                        name = v.n,
                        damage = tonumber(v.d) or 0,
                        label = v.l or v.n,
                        target = tonumber(v.tgt) or 0,
                        stock = tonumber(v.stk) or 0,
                        forever = (v.fv == true),
                    }
                end
            end
        end
    end

    return {
        ok = true,
        liveOc = true,
        armed = (cfg and cfg.armed == true),
        stepCount = state and state.stepCount or 0,
        policy = {
            pollSec = cfg.pollSec,
            idlePollSec = cfg.idlePollSec,
            staggerBatch = cfg.staggerBatch,
            freeCpusReserve = cfg.freeCpusReserve,
            maxConcurrentCrafts = cfg.maxConcurrentCrafts,
            maxDispatchPerCycle = cfg.maxDispatchPerCycle,
            prioritizePower = cfg.prioritizePower ~= false,
            defaultCpuFilter = cfg.defaultCpuFilter or "",
            backoffBaseSec = cfg.backoffBaseSec,
            backoffMaxSec = cfg.backoffMaxSec,
            dtpfWarnMode = cfg.dtpfWarnMode or "warn",
            extLinkMode = cfg.extLinkMode or "auto",
            disablePhysicalAfterImport = cfg.disablePhysicalAfterImport == true,
        },
        kpis = kpis,
        perf = perf,
        dtpfPeerOnline = dtpfOnline,
        dtpfLevels = dtpfLevels,
        groups = cfg.groups or Scheduler.DEFAULT_GROUPS,
        physicalConnected = state and state.discovery and #(state.discovery.maintainers or {}) or 0,
        rules = rulesOut,
        events = evOut,
        lastBenchmark = state and state.lastBenchmark or nil,
    }
end

function Scheduler.executeRpcTable(cfg, state, cmd, compLib, onMutate)
    if type(cmd) ~= "table" then
        return { ok = false, error = "Invalid command" }
    end
    local op = cmd.op
    local id = cmd.id
    local mutated = false

    if op == "ping" then
        return { id = id, ok = true, role = "stock", armed = (cfg.armed == true) }
    elseif op == "get_state" or op == "stock_state" then
        local snap = Scheduler.buildSnapshot(cfg, state)
        snap.id = id
        return snap
    elseif op == "patch_settings" or op == "stock_patch" then
        local p = type(cmd.patch) == "table" and cmd.patch or cmd
        if type(p.armed) == "boolean" then cfg.armed = p.armed; mutated = true end
        if tonumber(p.pollSec) then
            cfg.pollSec = math.max(2, math.min(300, math.floor(tonumber(p.pollSec))))
            if (tonumber(cfg.idlePollSec) or 25) < cfg.pollSec then
                cfg.idlePollSec = cfg.pollSec
            end
            mutated = true
        end
        if tonumber(p.idlePollSec) then
            cfg.idlePollSec = math.max(cfg.pollSec or 2, math.min(300, math.floor(tonumber(p.idlePollSec))))
            mutated = true
        end
        if tonumber(p.staggerBatch) then cfg.staggerBatch = math.max(5, math.min(500, math.floor(tonumber(p.staggerBatch)))); mutated = true end
        if tonumber(p.freeCpusReserve) then cfg.freeCpusReserve = math.max(0, math.min(32, math.floor(tonumber(p.freeCpusReserve)))); mutated = true end
        if tonumber(p.maxConcurrentCrafts) then cfg.maxConcurrentCrafts = math.max(1, math.min(64, math.floor(tonumber(p.maxConcurrentCrafts)))); mutated = true end
        if tonumber(p.maxDispatchPerCycle) then cfg.maxDispatchPerCycle = math.max(1, math.min(32, math.floor(tonumber(p.maxDispatchPerCycle)))); mutated = true end
        if type(p.prioritizePower) == "boolean" then cfg.prioritizePower = p.prioritizePower; mutated = true end
        if type(p.defaultCpuFilter) == "string" then cfg.defaultCpuFilter = p.defaultCpuFilter; mutated = true end
        if tonumber(p.backoffBaseSec) then cfg.backoffBaseSec = math.max(5, math.min(300, math.floor(tonumber(p.backoffBaseSec)))); mutated = true end
        if tonumber(p.backoffMaxSec) then cfg.backoffMaxSec = math.max(cfg.backoffBaseSec, math.min(3600, math.floor(tonumber(p.backoffMaxSec)))); mutated = true end
        if p.dtpfWarnMode == "warn" or p.dtpfWarnMode == "block_overlap" or p.dtpfWarnMode == "off" then
            cfg.dtpfWarnMode = p.dtpfWarnMode; mutated = true
        end
        if type(p.disablePhysicalAfterImport) == "boolean" then
            cfg.disablePhysicalAfterImport = p.disablePhysicalAfterImport; mutated = true
        end
        if type(p.rule) == "table" then
            local _, _, _, err = Scheduler.upsertRule(cfg, p.rule)
            if err then return { id = id, ok = false, error = err } end
            mutated = true
        end
        if type(p.deleteRuleId) == "string" and p.deleteRuleId ~= "" then
            Scheduler.deleteRule(cfg, p.deleteRuleId, state)
            mutated = true
        end
        if type(p.toggleRuleId) == "string" and p.toggleRuleId ~= "" then
            Scheduler.toggleRule(cfg, p.toggleRuleId)
            mutated = true
        end
        if type(p.groupToggle) == "table" and p.groupToggle.group then
            Scheduler.setGroupEnabled(cfg, p.groupToggle.group, p.groupToggle.enabled == true)
            mutated = true
        end
    elseif op == "upsert_rule" then
        local _, _, _, err = Scheduler.upsertRule(cfg, cmd.rule or cmd)
        if err then return { id = id, ok = false, error = err } end
        mutated = true
    elseif op == "delete_rule" then
        if not Scheduler.deleteRule(cfg, cmd.ruleId or cmd.id, state) then
            return { id = id, ok = false, error = "Rule not found" }
        end
        mutated = true
    elseif op == "toggle_rule" then
        local r = Scheduler.toggleRule(cfg, cmd.ruleId or cmd.id)
        if not r then return { id = id, ok = false, error = "Rule not found" } end
        mutated = true
    elseif op == "set_group_enabled" then
        Scheduler.setGroupEnabled(cfg, cmd.group, cmd.enabled == true)
        mutated = true
    elseif op == "action" or op == "stock_action" then
        local act = cmd.action
        if act == "arm" or act == "resume" then
            cfg.armed = true; mutated = true
        elseif act == "pause" then
            cfg.armed = false; mutated = true
        elseif act == "poll_now" or act == "poll" then
            state._forcePollNow = true
            Scheduler.step(cfg, state, clockNow(), compLib, { forceFull = true })
        elseif act == "retry_errors" then
            Scheduler.clearBackoffs(state)
            state._forcePollNow = true
        elseif act == "import_maintainers" then
            local slots = Hardware.scanPhysicalMaintainers(compLib, state, cfg)
            state.physicalMaintainers = slots
            local imp = Scheduler.importPhysicalSlots(cfg, slots, {
                includeDisabled = false,
                disablePhysical = (cfg.disablePhysicalAfterImport == true),
                disableFn = function(a, s) return Hardware.disablePhysicalMaintainerSlot(a, s, compLib, state) end,
            })
            mutated = (imp.added > 0 or imp.updated > 0)
            Scheduler.pushLog(state, "out", string.format("Imported %d new (%d upd, %d skip) from physical maintainers.", imp.added, imp.updated, imp.skipped), "OUT")
        elseif act == "import_non_dtpf" then
            local slots = Hardware.scanPhysicalMaintainers(compLib, state, cfg)
            state.physicalMaintainers = slots
            local imp = Scheduler.importPhysicalSlots(cfg, slots, {
                includeDisabled = false,
                skipDtpfPassives = true,
                disablePhysical = (cfg.disablePhysicalAfterImport == true),
                disableFn = function(a, s) return Hardware.disablePhysicalMaintainerSlot(a, s, compLib, state) end,
            })
            mutated = (imp.added > 0 or imp.updated > 0)
            Scheduler.pushLog(state, "out", string.format("Imported %d non-DTPF (%d DTPF passive skipped, %d upd).", imp.added, imp.skippedDtpf or 0, imp.updated), "OUT")
        elseif act == "distribute_dtpf" then
            local items = Scheduler.buildDtpfHandoffItems(cfg, state, cmd.ruleIds)
            if #items == 0 then
                return { id = id, ok = false, error = "No active DTPF rules found to distribute" }
            end
            local okH, errH = Hardware.sendDtpfHandoff(cfg, state, items, compLib, { remove = (cmd.remove == true) })
            if not okH then
                return { id = id, ok = false, error = tostring(errH or "Failed to send DTPF_HANDOFF") }
            end
            Scheduler.pushLog(state, "out", string.format("Dispatched %d rule(s) to DTPF over OC Mesh.", #items), "OUT")
        elseif act == "run_bench" then
            Hardware.runBenchmark(cfg, state, compLib)
        elseif act == "update_local" then
            local cl = compLib or rawget(_G, "component")
            if not cl then
                local okC, cMod = pcall(require, "component")
                if okC then cl = cMod end
            end
            local hasInet = cl and ((cl.isAvailable and cl.isAvailable("internet")) or (cl.list and cl.list("internet", true)() ~= nil))
            if not hasInet then
                return { id = id, ok = false, error = "No Internet Card on Stock Maintainer OC" }
            end
            local url = (type(cmd.url) == "string" and cmd.url ~= "") and cmd.url or "http://127.0.0.1:8765/oc-raw"
            if not url:match("^https?://[%w%.%-_:]+") then
                return { id = id, ok = false, error = "Invalid update URL" }
            end
            state._pendingUpdateUrl = url
            state._pendingReboot = true
            return { id = id, ok = true, updating = true, url = url }
        elseif act == "reboot" then
            state._pendingReboot = true
            return { id = id, ok = true, rebooting = true }
        else
            return { id = id, ok = false, error = "Unknown action: " .. tostring(act) }
        end
    elseif op == "_dtpf_handoff_ack" then
        if Scheduler.applyDtpfHandoffAck(cfg, state, cmd.ack) > 0 then
            mutated = true
        end
    else
        return { id = id, ok = false, error = "Unknown op: " .. tostring(op) }
    end

    if mutated then
        state._forcePollNow = true
        Scheduler.step(cfg, state, clockNow(), compLib, { cachedOnly = true })
        if onMutate then pcall(onMutate, cfg) end
    end
    local snap = Scheduler.buildSnapshot(cfg, state)
    snap.id = id
    return snap
end

function Scheduler.renderDigest(cfg, state)
    local k = (state and state.kpis) or {}
    local p = (state and state.perf) or {}
    return string.format("%s:%d:%d:%d:%d:%d:%d:%d:%.1f:%s",
        tostring(cfg and cfg.armed == true),
        state and state.stepCount or 0,
        k.total or 0, k.low or 0, k.crafting or 0, k.errors or 0, k.warnings or 0,
        k.freeCpus or 0, p.lastCycleMs or 0, tostring(#((state and state.events) or {})))
end

return Scheduler
