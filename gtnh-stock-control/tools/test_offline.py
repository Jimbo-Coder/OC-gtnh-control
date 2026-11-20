#!/usr/bin/env python3
"""Offline Lua 5.3 + OpenComputers JNLua test suite for gtnh-stock-control."""

from __future__ import annotations

import ctypes
import os
import tempfile
import zipfile
from pathlib import Path

STOCK_ROOT = Path(__file__).resolve().parent.parent


def _find_gtnh_root(start: Path) -> Path:
    for parent in start.parents:
        if (parent / "tools/jdks").exists() or list(parent.glob("GT_NH_*/mods/OpenComputers-*.jar")):
            return parent
    return start.parent.parent


def _discover_jvm_dylib() -> Path:
    env = os.environ.get("JVM_DYLIB")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(STOCK_ROOT)
    cands = sorted(gtnh_root.glob("tools/jdks/**/libjvm.dylib"), reverse=True) + sorted(gtnh_root.glob("tools/jdks/**/libjvm.so"), reverse=True)
    if cands:
        return cands[0]
    return gtnh_root / "tools/jdks/jdk8/Contents/Home/jre/lib/server/libjvm.dylib"


def _discover_oc_jar() -> Path:
    env = os.environ.get("OC_JAR")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(STOCK_ROOT)
    cands = sorted(gtnh_root.glob("GT_NH_*/mods/OpenComputers-*.jar"), reverse=True)
    if cands:
        return cands[0]
    return gtnh_root / "mods/OpenComputers.jar"


JVM_DYLIB = _discover_jvm_dylib()
OC_JAR = _discover_oc_jar()


def load_font_widths() -> dict[int, int]:
    widths: dict[int, int] = {}
    with zipfile.ZipFile(OC_JAR) as zf:
        for line in zf.read("assets/opencomputers/font.hex").decode("utf-8").splitlines():
            if ":" in line:
                cp_hex, hexdata = line.split(":", 1)
                widths[int(cp_hex, 16)] = len(hexdata.strip()) // 32
    return widths


class LuaHost:
    """Embedded OpenComputers Lua 5.3 VM using libjnlua53 + OpenOS shim."""

    def __init__(self, temp_dir: Path, font_widths: dict[int, int]) -> None:
        ctypes.CDLL(str(JVM_DYLIB), ctypes.RTLD_GLOBAL)
        with zipfile.ZipFile(OC_JAR) as zf:
            dylib_path = zf.extract("assets/opencomputers/lib/libjnlua53-darwin-aarch64.dylib", str(temp_dir))
            self.serialization_lua = zf.read("assets/opencomputers/loot/openos/lib/serialization.lua").decode("utf-8")

        self.lib = ctypes.CDLL(dylib_path)
        L = self.lib
        L.luaL_newstate.restype = ctypes.c_void_p
        L.luaL_requiref.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_int]
        L.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
        L.lua_gettop.argtypes = [ctypes.c_void_p]
        L.lua_gettop.restype = ctypes.c_int
        L.luaL_loadbufferx.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_char_p]
        L.luaL_loadbufferx.restype = ctypes.c_int
        L.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_void_p]
        L.lua_pcallk.restype = ctypes.c_int
        L.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
        L.lua_tolstring.restype = ctypes.c_char_p
        L.lua_pushlstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
        L.lua_pushboolean.argtypes = [ctypes.c_void_p, ctypes.c_int]
        L.lua_pushinteger.argtypes = [ctypes.c_void_p, ctypes.c_longlong]
        L.lua_pushnil.argtypes = [ctypes.c_void_p]
        L.lua_pushcclosure.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
        L.lua_setglobal.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        L.lua_tointegerx.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        L.lua_tointegerx.restype = ctypes.c_longlong
        L.lua_close.argtypes = [ctypes.c_void_p]

        self.L = L.luaL_newstate()
        for mod_name, sym in [
            (b"_G", "luaopen_base"),
            (b"table", "luaopen_table"),
            (b"string", "luaopen_string"),
            (b"math", "luaopen_math"),
            (b"utf8", "luaopen_utf8"),
            (b"debug", "luaopen_debug"),
        ]:
            L.luaL_requiref(self.L, mod_name, ctypes.cast(getattr(L, sym), ctypes.c_void_p), 1)
            L.lua_settop(self.L, 0)

        self.vfs: dict[str, str] = {}
        self.stdout: list[str] = []
        self.font_widths = font_widths
        self._cfuncs = []
        self._register_host_callbacks()
        self._install_openos_shim()

    def close(self) -> None:
        if self.L:
            self.lib.lua_close(self.L)
            self.L = None

    def _register_cfunc(self, name: str, py_fn) -> None:
        cfunc_t = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
        cb = cfunc_t(py_fn)
        self._cfuncs.append(cb)
        self.lib.lua_pushcclosure(self.L, ctypes.cast(cb, ctypes.c_void_p), 0)
        self.lib.lua_setglobal(self.L, name.encode("utf-8"))

    def _get_str(self, idx: int) -> str:
        sz = ctypes.c_size_t()
        raw = self.lib.lua_tolstring(self.L, idx, ctypes.byref(sz))
        if not raw:
            return ""
        return ctypes.string_at(raw, sz.value).decode("utf-8")

    def _push_str(self, s: str) -> None:
        b = s.encode("utf-8")
        self.lib.lua_pushlstring(self.L, b, len(b))

    def _register_host_callbacks(self) -> None:
        def py_read_file(L_ptr) -> int:
            path = self._get_str(1)
            if path in self.vfs:
                self._push_str(self.vfs[path])
                return 1
            if path == "/__openos__/serialization.lua":
                self._push_str(self.serialization_lua)
                return 1
            p = Path(path)
            if p.is_file():
                self._push_str(p.read_text(encoding="utf-8"))
                return 1
            self.lib.lua_pushnil(L_ptr)
            return 1

        def py_write_file(L_ptr) -> int:
            self.vfs[self._get_str(1)] = self._get_str(2)
            self.lib.lua_pushboolean(L_ptr, 1)
            return 1

        def py_exists(L_ptr) -> int:
            path = self._get_str(1)
            ok = (path in self.vfs) or Path(path).is_file()
            self.lib.lua_pushboolean(L_ptr, 1 if ok else 0)
            return 1

        def py_remove_vfs(L_ptr) -> int:
            path = self._get_str(1)
            existed = path in self.vfs
            self.vfs.pop(path, None)
            self.lib.lua_pushboolean(L_ptr, 1 if existed else 0)
            return 1

        def py_rename_vfs(L_ptr) -> int:
            src, dst = self._get_str(1), self._get_str(2)
            if src in self.vfs:
                self.vfs[dst] = self.vfs.pop(src)
                self.lib.lua_pushboolean(L_ptr, 1)
                return 1
            self.lib.lua_pushboolean(L_ptr, 0)
            return 1

        def py_print(L_ptr) -> int:
            self.stdout.append(self._get_str(1))
            return 0

        def py_char_width(L_ptr) -> int:
            cp = int(self.lib.lua_tointegerx(L_ptr, 1, None))
            self.lib.lua_pushinteger(L_ptr, self.font_widths.get(cp, 1))
            return 1

        for name, fn in (
            ("__py_read_file", py_read_file),
            ("__py_write_file", py_write_file),
            ("__py_exists", py_exists),
            ("__py_remove_vfs", py_remove_vfs),
            ("__py_rename_vfs", py_rename_vfs),
            ("__py_print", py_print),
            ("__py_char_width", py_char_width),
        ):
            self._register_cfunc(name, fn)

    def _install_openos_shim(self) -> None:
        shim = f"""
local rootDir = "{STOCK_ROOT}"
__STOCK_ROOT = rootDir
__MONOREPO_ROOT = "{STOCK_ROOT.parent}"
__RENDERED_CELL_CPS = {{}}
collectgarbage = nil

function checkArg(n, have, ...)
    local t = type(have)
    for i = 1, select("#", ...) do
        if t == select(i, ...) then return end
    end
    error(string.format("bad argument #%d (%s expected, got %s)", n, table.concat({{ ... }}, " or "), t), 3)
end

function print(...)
    local parts = {{}}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    __py_print(table.concat(parts, "\t"))
end

io = {{
    stderr = {{ write = function(_, s) __py_print("[STDERR] " .. tostring(s)) end }},
    open = function(path, mode)
        mode = mode or "r"
        if mode:sub(1, 1) == "w" then
            local buf = {{}}
            return {{
                write = function(_, s) buf[#buf + 1] = tostring(s) end,
                close = function() __py_write_file(path, table.concat(buf)) end,
            }}
        end
        local content = __py_read_file(path)
        if not content then return nil, "not found: " .. tostring(path) end
        return {{
            read = function() return content end,
            close = function() end,
        }}
    end,
}}

function loadfile(path, mode, env)
    local src = __py_read_file(path)
    if not src then return nil, "not found: " .. tostring(path) end
    return load(src, "=" .. tostring(path), mode or "t", env or _G)
end

package = {{ path = rootDir .. "/?.lua", loaded = {{ io = io }}, preload = {{}} }}
function require(name)
    if package.loaded[name] ~= nil then return package.loaded[name] end
    local rel = name:gsub("%.", "/")
    for pat in package.path:gmatch("[^;]+") do
        local cand = pat:gsub("%?", rel)
        if __py_exists(cand) then
            local src = __py_read_file(cand)
            local chunk, err = load(src, "@" .. cand)
            if not chunk then error("load error in " .. cand .. ": " .. tostring(err)) end
            local res = chunk(cand)
            package.loaded[name] = (res == nil) and true or res
            return package.loaded[name]
        end
    end
    error("module '" .. tostring(name) .. "' not found")
end

local filesystem = {{}}
function filesystem.path(p) return p:match("^(.*)/[^/]+$") or "/" end
function filesystem.concat(a, b) return (a:sub(-1) == "/") and (a .. b) or (a .. "/" .. b) end
function filesystem.exists(p) return __py_exists(p) end
function filesystem.makeDirectory(_) return true end
function filesystem.remove(p) return __py_remove_vfs(p) end
function filesystem.rename(a, b) return __py_rename_vfs(a, b) end
package.loaded["filesystem"] = filesystem

local uptimeVal = 100.0
os = {{
    clock = function() uptimeVal = uptimeVal + 0.0005; return uptimeVal end,
    sleep = function(sec) uptimeVal = uptimeVal + (tonumber(sec) or 0) end,
    remove = function(p) return __py_remove_vfs(p) end,
    rename = function(a, b) return __py_rename_vfs(a, b) end,
}}
package.loaded["os"] = os

local serChunk, serErr = load(__py_read_file("/__openos__/serialization.lua"), "@serialization.lua")
assert(serChunk, serErr)
package.loaded["serialization"] = serChunk()

local unicode = {{}}
function unicode.charWidth(ch)
    if not ch or ch == "" then return 0 end
    return __py_char_width(utf8.codepoint(ch, 1))
end
function unicode.wlen(s)
    s = tostring(s or "")
    local w = 0
    for _, cp in utf8.codes(s) do w = w + __py_char_width(cp) end
    return w
end
function unicode.sub(s, i, j)
    s = tostring(s or "")
    local len = utf8.len(s) or #s
    if i < 0 then i = len + i + 1 end
    if i < 1 then i = 1 end
    local sb = utf8.offset(s, i)
    if not sb then return "" end
    if not j then return s:sub(sb) end
    if j < 0 then j = len + j + 1 end
    if j < i then return "" end
    local eb = utf8.offset(s, j + 1)
    return eb and s:sub(sb, eb - 1) or s:sub(sb)
end
package.loaded["unicode"] = unicode

package.loaded["computer"] = {{
    uptime = function() return uptimeVal end,
    _setUptime = function(v) uptimeVal = v end,
    freeMemory = function() return 3100 * 1024 end,
    totalMemory = function() return 3686 * 1024 end,
    shutdown = function() end,
}}
package.loaded["shell"] = {{ getRunningProgram = function() return rootDir .. "/main.lua" end }}
package.loaded["term"] = {{ clear = function() end }}
package.loaded["event"] = {{ pull = function() return "interrupted" end }}

local registry = {{}}
local component = {{}}
function component._reset()
    for k in pairs(registry) do registry[k] = nil end
    component.gpu = nil
end
function component._register(addr, ctype, proxy)
    registry[addr] = {{ type = ctype, proxy = proxy }}
end
function component.list(filter, exact)
    local out = {{}}
    for addr, rec in pairs(registry) do
        if (not filter) or (exact and rec.type == filter) or (not exact and rec.type:find(filter, 1, true)) then
            out[#out + 1] = {{ addr, rec.type }}
        end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    local i = 0
    return function()
        i = i + 1
        if out[i] then return out[i][1], out[i][2] end
    end
end
function component.proxy(addr)
    local rec = registry[addr]
    return rec and rec.proxy or nil
end
function component.isAvailable(ctype)
    if ctype == "gpu" and component.gpu then return true end
    for _, rec in pairs(registry) do if rec.type == ctype then return true end end
    return false
end
function component._newMockGPU(w, h)
    w, h = w or 160, h or 50
    local cells = {{}}
    for y = 1, h do cells[y] = {{}}; for x = 1, w do cells[y][x] = " " end end
    return {{
        _cells = cells,
        _row = function(y) return table.concat(cells[y] or {{}}) end,
        _all = function()
            local r = {{}}
            for y = 1, h do r[y] = table.concat(cells[y]) end
            return table.concat(r, "\\n")
        end,
        maxResolution = function() return w, h end,
        setResolution = function() return true end,
        setForeground = function() end,
        setBackground = function() end,
        set = function(x, y, s)
            local col = x
            for _, cp in utf8.codes(tostring(s)) do
                if col >= 1 and col <= w and y >= 1 and y <= h then
                    cells[y][col] = utf8.char(cp)
                    __RENDERED_CELL_CPS[cp] = true
                end
                col = col + 1
            end
        end,
    }}
end
package.loaded["component"] = component
"""
        self.exec_lua(shim, "openos_shim")

    def exec_lua(self, code: str, chunk_name: str = "test_chunk") -> str | None:
        b = code.encode("utf-8")
        cname = ("@" + chunk_name).encode("utf-8")
        rc = self.lib.luaL_loadbufferx(self.L, b, len(b), cname, None)
        if rc != 0:
            err = self._get_str(-1)
            self.lib.lua_settop(self.L, 0)
            raise RuntimeError(f"Lua compile error in {chunk_name}: {err}")
        rc = self.lib.lua_pcallk(self.L, 0, 1, 0, 0, None)
        if rc != 0:
            err = self._get_str(-1)
            self.lib.lua_settop(self.L, 0)
            raise RuntimeError(f"Lua runtime error in {chunk_name}: {err}")
        top = self.lib.lua_gettop(self.L)
        res = self._get_str(-1) if top > 0 else None
        self.lib.lua_settop(self.L, 0)
        return res


def run_all_tests() -> None:
    font_widths = load_font_widths()
    with tempfile.TemporaryDirectory() as td:
        host = LuaHost(Path(td), font_widths)
        try:
            lua_suite = r"""
local component = require("component")
local computer = require("computer")
local serialization = require("serialization")
local DtpfCatalog = require("lib.dtpf_catalog")
local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")
local UI = require("lib.ui")

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAIL [%s]: expected=%s actual=%s", tostring(msg), tostring(expected), tostring(actual)))
    end
end

-- TEST 1: Syntax & Module Compile Check
for _, rel in ipairs({
    "lib/dtpf_catalog.lua",
    "lib/hardware.lua",
    "lib/scheduler.lua",
    "lib/ui.lua",
    "main.lua",
    "install.lua",
}) do
    local src = __py_read_file(__STOCK_ROOT .. "/" .. rel)
    assert(src and #src > 0, "Missing file: " .. rel)
    local chunk, err = load(src, "@" .. rel, "t")
    assert(chunk, "Syntax error in " .. rel .. ": " .. tostring(err))
end

-- TEST 2: DTPF Catalog Lookup
assert(DtpfCatalog.lookup("fluid", "molten.neutronium", 0) ~= nil, "Catalog finds Molten Neutronium")
assert(DtpfCatalog.lookup("item", "gregtech:gt.metaitem.01", 32415) ~= nil, "Catalog finds Raw Tesseract")
assert(DtpfCatalog.lookup("item", "minecraft:iron_ingot", 0) == nil, "Catalog returns nil for non-DTPF item")

-- TEST 3: O(1) Lookups, Hysteresis, Deficit Mode, Priority, CPU Filter & Reserve
local calls = { o1Item = 0, o1Fluid = 0, o1Craft = 0, fullItems = 0, fullFluids = 0 }
local crafted = {}
local failMode = false
local itemStocks = {
    ["custom:hyst"] = 450,    -- target 500, lowThreshold 400 -> must NOT trigger
    ["custom:p2"] = 10,       -- target 200, prio 2, fixed batch 50
    ["custom:p1"] = 20,       -- target 100, prio 1, deficit mode maxBatch 60 -> amt=60
    ["custom:cpu_only"] = 0,  -- cpuFilter = "Maint" -> routes to Maint-1
    ["custom:busy"] = 0,      -- already crafting on CPU-Busy
}
local fluidStocks = {
    ["molten.steel"] = 1000,
    ["molten.neutronium"] = 500, -- DTPF passive capable
}
local cpus = {
    { name = "CPU-General", busy = false, storage = 1048576, coprocessors = 4 },
    { name = "Maint-1", busy = false, storage = 65536, coprocessors = 1 },
    { name = "CPU-Free3", busy = false, storage = 262144, coprocessors = 2 },
    { name = "CPU-Busy", busy = true, storage = 65536, coprocessors = 1, cpu = {
        finalOutput = function() return { name = "custom:busy", damage = 0, maxSize = 64, label = "Busy" } end
    } },
}
component._register("ae-main", "me_controller", {
    getItemInNetwork = function(filter)
        calls.o1Item = calls.o1Item + 1
        assert(type(filter) == "table", "Must pass table-form to getItemInNetwork")
        local sz = itemStocks[filter.name]
        if sz == nil then return nil end
        return { name = filter.name, damage = filter.damage or 0, size = sz, label = filter.name }
    end,
    getFluidInNetwork = function(fname)
        calls.o1Fluid = calls.o1Fluid + 1
        local amt = fluidStocks[fname]
        if amt == nil then return nil end
        return { name = fname, amount = amt, label = fname }
    end,
    getItemsInNetwork = function() calls.fullItems = calls.fullItems + 1; return {} end,
    getFluidsInNetwork = function() calls.fullFluids = calls.fullFluids + 1; return {} end,
    getCpus = function() return cpus end,
    getCraftable = function(filter, cType)
        calls.o1Craft = calls.o1Craft + 1
        return {
            request = function(amt, prioPwr, cpuName)
                if failMode then return nil, "missing resources" end
                crafted[#crafted + 1] = { name = filter.name, amount = amt, cpu = cpuName, cType = cType }
                return {
                    isComputing = function() return false end,
                    hasFailed = function() return false end,
                    isCanceled = function() return false end,
                    isDone = function() return false end,
                }
            end,
        }
    end,
})

local cfg = Scheduler.defaultConfig()
cfg.armed = true
cfg.freeCpusReserve = 1 -- 3 free CPUs -> headroom 2
cfg.maxConcurrentCrafts = 6
cfg.maxDispatchPerCycle = 3
Scheduler.upsertRule(cfg, { id = "r_hyst", type = "item", name = "custom:hyst", damage = 0, label = "Hyst", target = 500, lowThreshold = 400, batch = 100, priority = 1 })
Scheduler.upsertRule(cfg, { id = "r_p2", type = "item", name = "custom:p2", damage = 0, label = "P2", target = 200, batch = 50, priority = 2 })
Scheduler.upsertRule(cfg, { id = "r_p1", type = "item", name = "custom:p1", damage = 0, label = "P1", target = 100, batch = 25, batchMode = "deficit", maxBatch = 60, priority = 1 })
Scheduler.upsertRule(cfg, { id = "r_cpu", type = "item", name = "custom:cpu_only", damage = 0, label = "CpuOnly", target = 64, batch = 32, priority = 3, cpuFilter = "Maint" })
Scheduler.upsertRule(cfg, { id = "r_busy", type = "item", name = "custom:busy", damage = 0, label = "Busy", target = 64, batch = 32, priority = 1 })
Scheduler.upsertRule(cfg, { id = "r_dtpf", type = "fluid", name = "molten.neutronium", damage = 0, label = "Molten Neutronium", target = 10000, batch = 1000, priority = 5 })

local state = Scheduler.newState()
Scheduler.syncHardware(cfg, state)
Scheduler.step(cfg, state, 200.0, nil, { forceFull = true })

assert(calls.o1Item >= 4 and calls.o1Fluid >= 1, "Used O(1) AE2 stock queries")
assertEq(calls.fullItems, 0, "Zero full getItemsInNetwork scans")
assertEq(calls.fullFluids, 0, "Zero full getFluidsInNetwork scans")
assertEq(#crafted, 2, "Dispatched 2 crafts respecting freeCpusReserve (3 - 1 = 2)")
assertEq(crafted[1].name, "custom:p1", "Priority 1 crafted first")
assertEq(crafted[1].amount, 60, "Deficit mode clamped by maxBatch=60")
assertEq(crafted[2].name, "custom:p2", "Priority 2 crafted second")
assertEq(crafted[2].amount, 50, "Fixed batch crafted 50")

-- Verify busy CPU dedup & hysteresis skip & DTPF warning
local byId = {}
for _, rs in ipairs(state.ruleStatuses) do byId[rs.id] = rs end
assertEq(byId["r_hyst"].state, "OK", "Hysteresis rule holds OK at 450 >= 400")
assertEq(byId["r_busy"].state, "CRAFT", "Busy CPU item detected as CRAFT")
assertEq(byId["r_dtpf"].warnKind, "dtpf_passive_capable", "DTPF passive warning flagged on Molten Neutronium")

-- Verify CPU filter routing when budget allows r_cpu
crafted = {}
state._ruleTrack = {}
cfg.freeCpusReserve = 0
cfg.maxDispatchPerCycle = 5
itemStocks["custom:p1"] = 100
itemStocks["custom:p2"] = 200
Scheduler.step(cfg, state, 210.0, nil, { forceFull = true })
local cpuHit = false
for _, c in ipairs(crafted) do
    if c.name == "custom:cpu_only" then
        assertEq(c.cpu, "Maint-1", "cpuFilter='Maint' routed to Maint-1")
        cpuHit = true
    end
end
assert(cpuHit, "CPU-filtered rule dispatched")

-- TEST 4: Exponential Backoff & Clear Backoffs
crafted = {}
state._ruleTrack = {}
state._pendingJobs = {}
state._craftableCache = {}
failMode = true
Scheduler.step(cfg, state, 300.0, nil, { forceFull = true })
assertEq(state._ruleTrack["r_cpu"].failCount, 1, "Fail 1 recorded")
assertEq(state._ruleTrack["r_cpu"].backoffUntil, 330.0, "Fail 1 -> 30s backoff")
Scheduler.step(cfg, state, 331.0, nil, { forceFull = true })
assertEq(state._ruleTrack["r_cpu"].failCount, 2, "Fail 2 recorded")
assertEq(state._ruleTrack["r_cpu"].backoffUntil, 391.0, "Fail 2 -> 60s backoff")
failMode = false
assert(Scheduler.clearBackoffs(state) >= 1, "clearBackoffs clears error backoffs")
Scheduler.step(cfg, state, 332.0, nil, { forceFull = true })
assertEq(state._ruleTrack["r_cpu"].failCount, 0, "Craft succeeds immediately after clearBackoffs")

-- TEST 5: DTPF_CLAIMS Overlap Block & Allow Opt-Out
component._register("modem-s", "modem", {
    isWireless = function() return true end,
    setStrength = function() return 400 end,
    open = function() return true end,
    send = function() return true end,
    broadcast = function() return true end,
})
local claimsPayload = serialization.serialize({
    armed = true,
    maintEnabled = true,
    maintKeys = { "item:custom:cpu_only:0" },
    passiveKeys = { "fluid:molten.neutronium:0" },
    maintInfo = {
        ["item:custom:cpu_only:0"] = { t = "item", n = "custom:cpu_only", d = 0, l = "Custom CPU", tgt = 500, bat = 64, stk = 120, m = "auto", st = "OK" },
    },
    passiveInfo = {
        ["fluid:molten.neutronium:0"] = { fid = "molten_neutronium", t = "fluid", n = "molten.neutronium", d = 0, l = "Molten Neutronium", tgt = 5000000, stk = 2000000, fv = false },
    },
})
assert(Hardware.handleMeshMessage(cfg, state, "modem-s", "dtpf-m", 4205, "DTPF_CLAIMS", claimsPayload), "Handled DTPF_CLAIMS")
cfg.dtpfWarnMode = "block_overlap"
crafted = {}
state._ruleTrack = {}
state._pendingJobs = {}
itemStocks["custom:cpu_only"] = 0
Scheduler.step(cfg, state, computer.uptime() + 1, nil, { forceFull = true })
local blockedRes = nil
for _, rs in ipairs(state.ruleStatuses) do if rs.id == "r_cpu" then blockedRes = rs end end
assertEq(blockedRes.warnKind, "dtpf_maint_overlap", "DTPF maint overlap flagged")
assert(tostring(blockedRes.warn or ""):find("500", 1, true), "dtpf_maint_overlap warning includes live DTPF target: " .. tostring(blockedRes.warn))
assert(blockedRes.dtpfInfo ~= nil and blockedRes.dtpfInfo.role == "input" and blockedRes.dtpfInfo.target == 500, "Rule status carries live dtpfInfo levels")
local snapDtpf = Scheduler.buildSnapshot(cfg, state, computer.uptime() + 1)
assert(snapDtpf.dtpfPeerOnline == true and type(snapDtpf.dtpfLevels["fluid:molten.neutronium:0"]) == "table", "Snapshot exposes live dtpfLevels map")
assertEq(blockedRes.state, "WARN", "block_overlap prevented duplicate craft")
cfg.rules[4].allowDtpfOverlap = true
Scheduler.step(cfg, state, computer.uptime() + 2, nil, { forceFull = true })
local optOutRes = nil
for _, rs in ipairs(state.ruleStatuses) do if rs.id == "r_cpu" then optOutRes = rs end end
assert(optOutRes.warn == nil, "allowDtpfOverlap silenced advisory warning")

-- TEST 6: Drop-In Transposer (Item + AE2FC Fluid Drop) & Physical Level Maintainer Importer
local dropStack = { name = "ae2fc:fluid_drop", damage = 0, label = "drop of Molten Steel", fluid = { name = "molten.steel", label = "Molten Steel" } }
component._register("tp-1", "transposer", {
    getInventorySize = function(side) return side == 1 and 9 or 0 end,
    getStackInSlot = function(side, slot) return (side == 1 and slot == 1) and dropStack or nil end,
    getFluidInTank = function() return nil end,
})
local drop = Hardware.readDropSlot(cfg, nil, state)
assert(drop.found == true and drop.type == "fluid" and drop.name == "molten.steel", "Drop-in resolved ae2fc:fluid_drop to fluid")
assertEq(drop.stock, 1000, "Drop-in queried live AE2 fluid stock")
assert(drop.craftable == true, "Drop-in verified AE2 craftability")

local disabledCalls = {}
component._register("lm-1", "level_maintainer", {
    getSlot = function(slot)
        if slot == 1 then
            return { name = "minecraft:gold_ingot", damage = 0, label = "Gold Ingot", quantity = 4096, batch = 512, isFluid = false, isEnable = true, isDone = true }
        elseif slot == 2 then
            return { name = "ae2fc:fluid_drop", damage = 0, label = "drop of Oxygen", isFluid = true, fluid = { name = "oxygen", label = "Oxygen" }, quantity = 500000, batch = 100000, isEnable = true, isDone = false }
        elseif slot == 3 then
            return { name = "minecraft:dirt", damage = 0, label = "Dirt", quantity = 64, batch = 16, isFluid = false, isEnable = false, isDone = true }
        end
        return nil
    end,
    setEnable = function(slot, en) disabledCalls[#disabledCalls + 1] = { slot, en }; return true end,
})
local pSlots, nBlocks = Hardware.scanPhysicalMaintainers(nil, state)
assertEq(nBlocks, 1, "Found 1 physical level_maintainer")
assertEq(#pSlots, 3, "Scanned 3 populated slots")
cfg.disablePhysicalAfterImport = true
local impRes = Scheduler.importPhysicalSlots(cfg, pSlots, {
    includeDisabled = false,
    disablePhysical = true,
    disableFn = function(a, s) return Hardware.disablePhysicalMaintainerSlot(a, s, nil, state) end,
})
assertEq(impRes.added, 2, "Imported 2 enabled slots (skipped disabled slot)")
assertEq(impRes.disabled, 2, "Disabled 2 physical slots after import")
assertEq(#disabledCalls, 2, "setEnable(slot, false) invoked twice")

-- TEST 7: Mesh STOCK_CMD Chunked STOCK_REPLY Reassembly & STOCK_METRICS
local sentPkts = {}
component._register("modem-s", "modem", {
    isWireless = function() return true end,
    setStrength = function() return 400 end,
    open = function() return true end,
    send = function(_, port, ...) sentPkts[#sentPkts + 1] = { port = port, args = { ... } }; return true end,
    broadcast = function(port, ...) sentPkts[#sentPkts + 1] = { port = port, args = { ... } }; return true end,
})
-- Populate 120 rules to force multi-chunk STOCK_REPLY (> 5500 bytes)
for idx = 1, 120 do
    Scheduler.upsertRule(cfg, {
        id = "bulk_" .. idx,
        type = (idx % 4 == 0) and "fluid" or "item",
        name = "mod:bulk_item_" .. idx,
        damage = idx,
        label = "Bulk Maintainer Entry #" .. idx,
        target = 1000 * idx,
        batch = 100,
    })
end
Scheduler.step(cfg, state, computer.uptime() + 1, nil, { forceFull = true })
sentPkts = {}
local rpcFn = function(cmdTbl) return Scheduler.executeRpcTable(cfg, state, cmdTbl) end
local handledCmd = Hardware.handleMeshMessage(cfg, state, "modem-s", "ae2-hub", 4205, "STOCK_CMD", "req-99", serialization.serialize({ op = "stock_state" }), nil, rpcFn)
assert(handledCmd, "Handled STOCK_CMD")
local replies = {}
for _, p in ipairs(sentPkts) do
    if p.args[1] == "STOCK_REPLY" then replies[#replies + 1] = p.args end
end
assert(#replies >= 2, "Large STOCK_REPLY split into >= 2 chunks")
local parts = {}
for i, r in ipairs(replies) do
    assertEq(r[2], "req-99", "STOCK_REPLY reqId matches")
    assertEq(r[3], i, "STOCK_REPLY chunk idx monotonic")
    assert(#r[5] <= 5500, "STOCK_REPLY chunk <= 5500 bytes")
    parts[i] = r[5]
end
local decoded = serialization.unserialize(table.concat(parts))
assert(type(decoded) == "table" and decoded.ok == true and #decoded.rules >= 120, "Reassembled STOCK_REPLY contains >= 120 rules")

-- TEST 8: Staggered 300-Rule Scale, Benchmark, & 4-Tab + Modal Width-1 UI Render
for idx = 121, 300 do
    Scheduler.upsertRule(cfg, { id = "bulk_" .. idx, type = "item", name = "mod:bulk_item_" .. idx, damage = idx, label = "Bulk #" .. idx, target = 5000, batch = 100 })
end
cfg.staggerBatch = 25
calls.o1Item, calls.o1Fluid = 0, 0
Scheduler.step(cfg, state, computer.uptime() + 1)
assert(calls.o1Item + calls.o1Fluid <= 30, "Staggered slice bounded AE2 calls (<= 30 for 300 rules)")

local bench = Hardware.runBenchmark(cfg, state)
assert(bench.o1AvgMs >= 0 and bench.equivPhysicalBlocks >= 60, "Benchmark computed physical blocks saved")

local gpu = component._newMockGPU(160, 50)
component.gpu = gpu
local ui = UI.new(cfg, state, function() end)
for t = 1, 4 do
    ui.tab = t
    ui:render()
end
assert(gpu._all():find("GTNH STOCK MAINTAINER", 1, true), "Tab 1 renders header")
assert(gpu._all():find("PERFORMANCE PROFILER", 1, true), "Tab 4 renders benchmark card")
ui.editRuleId = cfg.rules[1].id
ui:render()
assert(gpu._all():find("EDIT RULE:", 1, true), "Rule edit modal renders")
ui.editRuleId = nil
ui.logModalActive = true
ui:render()
assert(gpu._all():find("ACTIVITY LOG", 1, true), "Log modal renders")
ui.logModalActive = false

-- TEST 8b: 1-Tick Bulk Fluid Cache (>= 3 due fluids), Lazy finalOutput(), Live Link Skip,
--           Cached Craftable Reuse, Adaptive Idle Cadence & Fair Round-Robin
do
    local mCalls = { getItem = 0, getFluid = 0, getFluids = 0, getCpus = 0, finalOut = 0, getCraft = 0, req = 0 }
    local mStocks = { ["custom:i1"] = 100, ["custom:i2"] = 100, ["custom:i3"] = 100, ["custom:i4"] = 100 }
    local mFluids = {
        { name = "f1", amount = 500 },
        { name = "f2", amount = 500 },
        { name = "f3", amount = 500 },
    }
    local linkDone = false
    local dispatchedNames = {}
    component._reset()
    component._register("ae-perf", "me_controller", {
        getItemInNetwork = function(f)
            mCalls.getItem = mCalls.getItem + 1
            local v = mStocks[f.name]
            return v and { name = f.name, damage = 0, size = v } or nil
        end,
        getFluidInNetwork = function(fn)
            mCalls.getFluid = mCalls.getFluid + 1
            return { name = fn, amount = 500 }
        end,
        getFluidsInNetwork = function()
            mCalls.getFluids = mCalls.getFluids + 1
            return mFluids
        end,
        getCpus = function()
            mCalls.getCpus = mCalls.getCpus + 1
            return {
                { name = "C1", busy = false, storage = 10000, coprocessors = 2 },
                { name = "C2", busy = false, storage = 10000, coprocessors = 2 },
                { name = "C3", busy = false, storage = 10000, coprocessors = 2 },
                { name = "C4", busy = false, storage = 10000, coprocessors = 2 },
                { name = "C-ExtBusy", busy = true, storage = 10000, coprocessors = 2, cpu = {
                    finalOutput = function() mCalls.finalOut = mCalls.finalOut + 1; return { name = "other:x", damage = 0, maxSize = 64 } end
                } },
            }
        end,
        getCraftable = function(det)
            mCalls.getCraft = mCalls.getCraft + 1
            return {
                request = function(amt)
                    mCalls.req = mCalls.req + 1
                    dispatchedNames[#dispatchedNames + 1] = det.name
                    return {
                        isComputing = function() return false end,
                        hasFailed = function() return false end,
                        isCanceled = function() return false end,
                        isDone = function() return linkDone end,
                    }
                end,
            }
        end,
    })

    local pCfg = Scheduler.normalizeConfig({
        armed = true,
        pollSec = 10,
        idlePollSec = 25,
        freeCpusReserve = 0,
        maxConcurrentCrafts = 16,
        maxDispatchPerCycle = 2,
    })
    for idx = 1, 3 do
        Scheduler.upsertRule(pCfg, { id = "fl" .. idx, type = "fluid", name = "f" .. idx, target = 100, batch = 10, priority = 3 })
    end
    for idx = 1, 4 do
        Scheduler.upsertRule(pCfg, { id = "it" .. idx, type = "item", name = "custom:i" .. idx, target = 100, batch = 10, priority = 3 })
    end

    local pSt = Scheduler.newState()
    Scheduler.syncHardware(pCfg, pSt)
    -- Cycle 1 (all OK): 1 bulk getFluidsInNetwork, 0 getFluidInNetwork, 0 finalOutput!
    Scheduler.step(pCfg, pSt, 1000.0)
    assertEq(mCalls.getFluids, 1, "Bulk fluid sweep used once for >= 3 due fluids")
    assertEq(mCalls.getFluid, 0, "Zero individual getFluidInNetwork calls during bulk sweep")
    assertEq(mCalls.finalOut, 0, "Zero finalOutput() calls on idle cycle")
    assertEq(Scheduler.nextWakeupDelay(pCfg, pSt, 1000.0), 25, "Adaptive idlePollSec=25s active after idle sweep")

    -- Drop all 4 equal-priority items low -> verifies fair round-robin + link skip + craftable cache
    mStocks["custom:i1"] = 0; mStocks["custom:i2"] = 0; mStocks["custom:i3"] = 0; mStocks["custom:i4"] = 0
    Scheduler.step(pCfg, pSt, 1025.0)
    assertEq(mCalls.finalOut, 1, "Lazy finalOutput() runs once when rules need craft")
    assertEq(#dispatchedNames, 2, "Cycle dispatches 2 items (it1, it2)")
    assert(Scheduler.nextWakeupDelay(pCfg, pSt, 1025.0) <= 10.0, "Wakeup returns to pollSec=10s when crafting")

    mCalls.getItem = 0
    -- Next cycle: it1 & it2 have live links (isDone=false -> skipped from stock query!), it3 & it4 dispatch fairly!
    Scheduler.step(pCfg, pSt, 1035.0)
    assertEq(mCalls.getItem, 2, "Live ICraftingLink skipped it1 & it2 stock queries (only queried it3 & it4)")
    assertEq(#dispatchedNames, 4, "Round-robin dispatched remaining it3 & it4 on cycle 2")
    assertEq(dispatchedNames[3], "custom:i3", "Fair round-robin picked it3")
    assertEq(dispatchedNames[4], "custom:i4", "Fair round-robin picked it4")

    -- Complete links & re-trigger it1 -> Craftable handle cache reuses resolved handle without extra getCraftable()
    local prevGetCraft = mCalls.getCraft
    linkDone = true
    Scheduler.step(pCfg, pSt, 1045.0)
    mStocks["custom:i3"] = 100; mStocks["custom:i4"] = 100
    mStocks["custom:i2"] = 100
    Scheduler.step(pCfg, pSt, 1055.0) -- re-dispatches custom:i1 from cache
    assertEq(mCalls.getCraft, prevGetCraft, "Craftable handle reused from _craftableCache (0 extra getCraftable)")

    -- UI QoL test: search '/', sort, OFF filter, keep-config toggle
    local uiGpu = component._newMockGPU(160, 50)
    component.gpu = uiGpu
    local ui2 = UI.new(pCfg, pSt, function() end)
    ui2:handleKeyDown(47, 53) -- '/' opens Search prompt on Tab 2
    assert(ui2.tab == 2 and ui2.numPrompt ~= nil, "'/' jumped to Tab 2 and opened search prompt")
    ui2.numPrompt.buf = "custom:i2"
    ui2:handleKeyDown(13, 28) -- Enter applies search
    assertEq(ui2.searchQuery, "custom:i2", "Search query applied")
    ui2:handleTouch(6, 11, 0) -- Click [ON ] toggle on first visible filtered row
    local toggled = Scheduler.findRule(pCfg, "item", "custom:i2", 0)
    assertEq(toggled.enabled, false, "Row toggle paused rule it2")
    assertEq(toggled.target, 100, "Toggling rule OFF preserved target")
    assertEq(toggled.batch, 10, "Toggling rule OFF preserved batch")
    ui2.filterKind = "OFF"
    ui2.searchQuery = ""
    ui2:render()
    assert(uiGpu._all():find("custom:i2", 1, true), "OFF filter renders paused rule custom:i2 while keeping config")
    component.gpu = gpu
end

-- TEST 8h: Import Non-DTPF passives filter + DTPF_HANDOFF -> DTPF_HANDOFF_ACK + Tab 3 UI & glyph audit
do
    local cfgH = Scheduler.defaultConfig()
    local stH = Scheduler.newState()
    local disabledNonDtpf = {}
    local slotsH = {
        { addr = "lm-nd", slot = 1, type = "item", name = "minecraft:diamond", damage = 0, label = "Diamond", target = 2048, batch = 128, enabled = true },
        { addr = "lm-nd", slot = 2, type = "fluid", name = "molten.neutronium", damage = 0, label = "Molten Neutronium", target = 500000, batch = 14400, enabled = true },
    }
    local impNon = Scheduler.importPhysicalSlots(cfgH, slotsH, {
        includeDisabled = false,
        skipDtpfPassives = true,
        disablePhysical = true,
        disableFn = function(a, s) disabledNonDtpf[#disabledNonDtpf + 1] = a .. ":" .. s; return true end,
    })
    assertEq(impNon.added, 1, "import_non_dtpf added only the non-DTPF rule")
    assertEq(impNon.skippedDtpf, 1, "import_non_dtpf skipped molten.neutronium DTPF passive")
    assertEq(#disabledNonDtpf, 1, "import_non_dtpf only disabled non-DTPF slot")
    assert(disabledNonDtpf[1] == "lm-nd:1", "DTPF passive physical slot left untouched")

    -- Add DTPF passive rule and verify DTPF_HANDOFF dispatch + DTPF_HANDOFF_ACK pauses locally while preserving config
    local rtRule, _, isNewRt = Scheduler.upsertRule(cfgH, {
        type = "fluid", name = "molten.neutronium", damage = 0, label = "Molten Neutronium", target = 750000, batch = 14400,
    })
    assert(rtRule ~= nil and isNewRt == true, "Added DTPF passive rule before handoff")
    local hItems = Scheduler.buildDtpfHandoffItems(cfgH, stH, nil)
    assertEq(#hItems, 1, "buildDtpfHandoffItems selects only DTPF-capable rule")
    assertEq(hItems[1].familyId, "molten_neutronium", "buildDtpfHandoffItems maps molten.neutronium -> molten_neutronium")

    local hSent = {}
    component._register("modem-h", "modem", {
        isOpen = function() return true end,
        open = function() return true end,
        setStrength = function() return 400 end,
        getStrength = function() return 400 end,
        broadcast = function(port, ...)
            hSent[#hSent + 1] = { port = port, args = { ... } }
            return true
        end,
    })
    local okSend, errSend = Hardware.sendDtpfHandoff(cfgH, stH, hItems, component, { remove = false })
    assert(okSend == true, "sendDtpfHandoff succeeded: " .. tostring(errSend))
    assert(#hSent >= 1 and hSent[#hSent].args[1] == "DTPF_HANDOFF", "Broadcasted DTPF_HANDOFF mesh packet")
    local reqId = hSent[#hSent].args[2]

    local rpcQueue = {}
    Hardware.handleMeshMessage(cfgH, stH, "modem-h", "ae2-relay", 4205, "DTPF_HANDOFF_ACK", reqId, serialization.serialize({
        ok = true,
        acceptedIds = { rtRule.id },
        remove = false,
        passiveCount = 1,
        maintCount = 0,
    }), component, function(rpc) rpcQueue[#rpcQueue + 1] = rpc end)
    assertEq(#rpcQueue, 1, "DTPF_HANDOFF_ACK queued _dtpf_handoff_ack RPC")
    local ackRes = Scheduler.executeRpcTable(cfgH, stH, rpcQueue[1], component, function() return 100 end, nil)
    assert(ackRes.ok == true, "_dtpf_handoff_ack RPC succeeded")
    local pausedRt = Scheduler.findRule(cfgH, nil, nil, nil, rtRule.id)
    assert(pausedRt ~= nil and pausedRt.enabled == false and pausedRt.mode == "off", "Handed-off rule paused locally")
    assertEq(pausedRt.target, 750000, "Handed-off rule preserves target while paused")

    -- Inspect Tab 2 [DTPF] view + Tab 3 Drop-in live DTPF input banner & physical [DTPF] marker
    stH.dtpfPeer = {
        addr = "dtpf-m",
        lastSeen = computer.uptime(),
        armed = true,
        maintEnabled = true,
        maintKeys = { ["item:minecraft:diamond:0"] = true },
        passiveKeys = { ["fluid:molten.neutronium:0"] = true },
        maintInfo = { ["item:minecraft:diamond:0"] = { t = "item", n = "minecraft:diamond", d = 0, l = "Diamond", tgt = 4096, bat = 256, stk = 1024, m = "always", st = "OK" } },
        passiveInfo = { ["fluid:molten.neutronium:0"] = { fid = "molten_neutronium", t = "fluid", n = "molten.neutronium", d = 0, l = "Molten Neutronium", tgt = 25000000, stk = 5000000, fv = false } },
    }
    stH.dropPreview = { hasTransposer = true, transposerAddr = "tp-h", found = true, type = "item", name = "minecraft:diamond", damage = 0, label = "Diamond", stock = 1024, craftable = true }
    local tab3Gpu = component._newMockGPU(160, 50)
    component.gpu = tab3Gpu
    stH.physicalMaintainers = slotsH
    local uiH = UI.new(cfgH, stH, function() end)
    uiH.tab = 2
    uiH.filterKind = "DTPF"
    uiH:render()
    local screenDtpf = tab3Gpu._all()
    assert(screenDtpf:find("◈IN", 1, true) and screenDtpf:find("◈OUT", 1, true), "Tab 2 DTPF filter renders ◈IN and ◈OUT rows")
    assert(screenDtpf:find("Diamond", 1, true) and screenDtpf:find("Molten Neutronium", 1, true), "Tab 2 DTPF filter lists DTPF items & passives")

    pausedRt.enabled = true
    pausedRt.mode = "auto"
    uiH.tab = 3
    uiH:render()
    local screen3 = tab3Gpu._all()
    assert(screen3:find("DTPF Input", 1, true), "Tab 3 Drop-in renders live DTPF Input level banner (nowSec fix)")
    assert(screen3:find("Import Non-DTPF", 1, true), "Tab 3 renders [+ Import Non-DTPF] button")
    assert(screen3:find("Send DTPF to DTPF", 1, true), "Tab 3 renders [-> Send DTPF to DTPF] button")
    assert(screen3:find("[DTPF]", 1, true), "Tab 3 marks DTPF passive import slots with [DTPF]")
    component.gpu = gpu

    -- Test GTNH_WAKE hardware setup, wake response, and stale Mainnet heartbeat wake
    local stWake = Scheduler.newState()
    local wakeMsgS, wakeSetS, wakeSentS = nil, 0, {}
    local wakeComp = {
        list = function(ctype)
            local done = false
            return function()
                if ctype == "modem" and not done then done = true; return "modem-sw" end
                return nil
            end
        end,
        proxy = function(addr)
            if addr ~= "modem-sw" then return nil end
            return {
                isOpen = function() return true end,
                open = function() return true end,
                isWireless = function() return true end,
                getStrength = function() return 400 end,
                setStrength = function() return 400 end,
                getWakeMessage = function() return wakeMsgS end,
                setWakeMessage = function(m) wakeSetS = wakeSetS + 1; wakeMsgS = m; return wakeMsgS end,
                send = function(t, port, ...) wakeSentS[#wakeSentS + 1] = { t = t, port = port, args = { ... } }; return true end,
                broadcast = function(port, ...) wakeSentS[#wakeSentS + 1] = { port = port, args = { ... } }; return true end,
            }
        end,
    }
    Hardware.openMeshPort(cfgH, wakeComp, stWake)
    Hardware.openMeshPort(cfgH, wakeComp, stWake)
    assertEq(wakeMsgS, "GTNH_WAKE", "Stock openMeshPort configures GTNH_WAKE wake message")
    assertEq(wakeSetS, 1, "Stock openMeshPort skips redundant setWakeMessage calls")
    assert(Hardware.handleMeshMessage(cfgH, stWake, "modem-sw", "ae2-sw", Hardware.MESH_PORT, "GTNH_WAKE", "stock", nil, wakeComp), "Stock handled GTNH_WAKE")
    local sawStockWakeMetrics = false
    for _, pkt in ipairs(wakeSentS) do if pkt.args[1] == "STOCK_METRICS" then sawStockWakeMetrics = true end end
    assert(sawStockWakeMetrics == true, "Stock GTNH_WAKE pushed STOCK_METRICS")
    stWake._lastMainnetSeen = 10
    stWake._lastMainnetWakeAt = -1000
    wakeSentS = {}
    Hardware.pushMeshMetrics(cfgH, stWake, 120, wakeComp, true)
    local sw1, sw2 = 0, 0
    for _, pkt in ipairs(wakeSentS) do if pkt.args[1] == "GTNH_WAKE" then sw1 = sw1 + 1 end end
    assertEq(sw1, 1, "Stock stale Mainnet emitted 1 GTNH_WAKE")
    wakeSentS = {}
    Hardware.pushMeshMetrics(cfgH, stWake, 130, wakeComp, true)
    for _, pkt in ipairs(wakeSentS) do if pkt.args[1] == "GTNH_WAKE" then sw2 = sw2 + 1 end end
    assertEq(sw2, 0, "Stock stale Mainnet wake rate-limited within 60s")
end

-- TEST 9: CLI (--check, --bench, --off)
local mainSrc = __py_read_file(__STOCK_ROOT .. "/main.lua")
local function runCli(arg)
    local fn = assert(load(mainSrc, "@main.lua"))
    fn(arg)
end
runCli("--check")
runCli("--bench")
runCli("--off")
return "OK"
"""
            res = host.exec_lua(lua_suite, "stock_test_suite")
            assert res == "OK", f"Unexpected test result: {res}"

            # Audit every rendered glyph width == 1
            bad_cps = host.exec_lua(
                """
                local bad = {}
                for cp in pairs(__RENDERED_CELL_CPS) do
                    if __py_char_width(cp) ~= 1 then
                        bad[#bad + 1] = string.format("U+%04X(%s)", cp, utf8.char(cp))
                    end
                end
                return table.concat(bad, ",")
                """,
                "glyph_audit",
            )
            assert not bad_cps, f"Non-width-1 glyphs rendered in UI: {bad_cps}"

            # Check live JNLua memory footprint for 300 rules + UI under Tier 3 ceiling (< 3686 KB)
            L = host.lib
            L.lua_gc.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
            L.lua_gc.restype = ctypes.c_int
            L.lua_gc(host.L, 2, 0)
            live_kb = L.lua_gc(host.L, 3, 0)
            assert live_kb < 3686, f"300-rule JNLua heap exceeded Tier 3 3686 KB ceiling: {live_kb} KB"

            # Verify CLI outputs
            out = "\n".join(host.stdout)
            assert "=== GTNH STOCK MAINTAINER READ-ONLY CHECK ===" in out
            assert "=== GTNH STOCK MAINTAINER BENCHMARK ===" in out
            assert "Stock Maintainer disarmed." in out

            # TEST 10: Standalone & Root Monorepo install.lua (`stock`)
            inst_host = LuaHost(Path(td), font_widths)
            try:
                inst_host.exec_lua(
                    """
                    local inst = assert(loadfile(__STOCK_ROOT .. "/install.lua"))
                    assert(inst("--local", __STOCK_ROOT, "--yes", "--no-autostart"), "Standalone stock install failed")
                    for _, p in ipairs({
                        "/home/stock/main.lua",
                        "/home/stock/lib/dtpf_catalog.lua",
                        "/home/stock/lib/hardware.lua",
                        "/home/stock/lib/scheduler.lua",
                        "/home/stock/lib/ui.lua",
                        "/usr/bin/stock.lua",
                    }) do
                        assert(__py_exists(p), "Missing installed file: " .. p)
                    end
                    local f = io.open("/home/stock/config.cfg", "w")
                    f:write("{armed=false,customTag=991}")
                    f:close()
                    assert(inst("--local", __STOCK_ROOT, "--update", "--yes"), "stock --update failed")
                    local f2 = io.open("/home/stock/config.cfg", "r")
                    local body = f2:read("*a")
                    f2:close()
                    assert(body:find("customTag=991", 1, true), "Update overwrote config.cfg!")
                    assert(__py_exists("/home/config.stock.bak"), "Missing /home/config.stock.bak")

                    local rootInst = assert(loadfile(__MONOREPO_ROOT .. "/install.lua"))
                    rootInst("--list")
                    assert(rootInst("--local", __MONOREPO_ROOT, "stock", "--yes", "--no-autostart"), "Root monorepo install stock failed")
                    assert(__py_exists("/home/.oc-gtnh.manifest"), "Missing monorepo manifest")
                    """,
                    "install_test",
                )
                assert "stock" in "\n".join(inst_host.stdout), "Root --list missing stock"
            finally:
                inst_host.close()

            print(
                f"ALL GTNH STOCK CONTROL OFFLINE SUITES PASSED "
                f"(0 bad-width glyphs, {live_kb} KB 300-rule JNLua heap < 3686 KB Tier 3 limit, Lua 5.3 + OpenOS verified)."
            )
        finally:
            host.close()


if __name__ == "__main__":
    run_all_tests()
