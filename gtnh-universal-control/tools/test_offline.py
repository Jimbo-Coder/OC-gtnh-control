#!/usr/bin/env python3
"""Offline Lua 5.3 + OpenComputers JNLua test suite for gtnh-universal-control."""

from __future__ import annotations

import ctypes
import os
import sys
import tempfile
import zipfile
from pathlib import Path

UNIV_ROOT = Path(__file__).resolve().parent.parent


def _find_gtnh_root(start: Path) -> Path:
    for parent in start.parents:
        if (parent / "tools/jdks").exists() or list(parent.glob("GT_NH_*/mods/OpenComputers-*.jar")):
            return parent
    return start.parent.parent


def _discover_jvm_dylib() -> Path:
    env = os.environ.get("JVM_DYLIB")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(UNIV_ROOT)
    cands = sorted(gtnh_root.glob("tools/jdks/**/libjvm.dylib"), reverse=True) + sorted(gtnh_root.glob("tools/jdks/**/libjvm.so"), reverse=True)
    if cands:
        return cands[0]
    return gtnh_root / "tools/jdks/jdk8/Contents/Home/jre/lib/server/libjvm.dylib"


def _discover_oc_jar() -> Path:
    env = os.environ.get("OC_JAR")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(UNIV_ROOT)
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
            existed = self._get_str(1) in self.vfs
            self.vfs.pop(self._get_str(1), None)
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
local rootDir = "{UNIV_ROOT}"
__UNIV_ROOT = rootDir
__MONOREPO_ROOT = "{UNIV_ROOT.parent}"
__RENDERED_CELL_CPS = {{}}
-- OpenComputers enforces no collectgarbage() in guest sandbox
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
    clock = function() return uptimeVal end,
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
    local cp = utf8.codepoint(ch, 1)
    return __py_char_width(cp)
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
    shutdown = function() end,
}}
package.loaded["shell"] = {{
    getRunningProgram = function() return rootDir .. "/main.lua" end,
}}
package.loaded["term"] = {{ clear = function() end }}
package.loaded["event"] = {{
    pull = function() return "interrupted" end,
}}

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
local Hardware = require("lib.hardware")
local Policy = require("lib.policy")
local Scheduler = require("lib.scheduler")
local UI = require("lib.ui")

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAIL [%s]: expected=%s actual=%s", tostring(msg), tostring(expected), tostring(actual)))
    end
end

local function makeBundledRS()
    local sides = {}
    for s = 0, 5 do
        sides[s] = {}
        for c = 0, 15 do sides[s][c] = 0 end
    end
    local writes = {}
    local proxy = {
        getBundledOutput = function(side, color)
            if color ~= nil then return sides[side][color] end
            local cp = {}
            for c = 0, 15 do cp[c] = sides[side][c] end
            return cp
        end,
        setBundledOutput = function(side, a, b)
            if type(a) == "table" then
                for c = 0, 15 do sides[side][c] = tonumber(a[c]) or 0 end
            else
                sides[side][a] = tonumber(b) or 0
            end
            -- Strict Mutual Exclusion invariant on every single write!
            local active = {}
            for c = 0, 15 do
                if sides[side][c] > 0 then active[#active + 1] = c end
            end
            assert(#active <= 1, "MUTUAL EXCLUSION VIOLATED on side " .. tostring(side))
            writes[#writes + 1] = { side = side, active = active[1] }
            return true
        end,
    }
    return proxy, sides, writes
end

local function makeSubnetIF(initialItems, initialFluids, opts)
    opts = opts or {}
    local items = initialItems or {}
    local fluids = initialFluids or {}
    local proxy = {}
    if not opts.flatPart then
        proxy.getItemsInNetwork = function() return items end
        proxy.getFluidsInNetwork = function() return fluids end
    end
    if opts.coords then
        local cx, cy, cz = opts.coords[1], opts.coords[2], opts.coords[3]
        proxy.getCoordinates = function() return cx, cy, cz end
    end
    return proxy, items, fluids
end

-- =========================================================================
-- TEST 1: Syntax & Module Load Verification (collectgarbage == nil)
-- =========================================================================
for _, rel in ipairs({ "install.lua", "main.lua", "lib/hardware.lua", "lib/policy.lua", "lib/scheduler.lua", "lib/ui.lua" }) do
    local ch, err = loadfile(__UNIV_ROOT .. "/" .. rel)
    assert(ch, "Syntax error in " .. rel .. ": " .. tostring(err))
end

-- =========================================================================
-- TEST 2: Arbitrary-NC & Built-in NC Filtering + [Calibrate Idle NCs]
-- =========================================================================
component._reset()
local ifDual, itemsDual = makeSubnetIF({
    { name = "gregtech:gt.integrated_circuit", damage = 1, size = 1, label = "Programmed Circuit" },
    { name = "gregtech:gt.metaitem.01", damage = 32301, size = 1, label = "Mold (Plate)" },
    { name = "gregtech:gt.metaitem.01", damage = 24500, size = 1, label = "Emerald Lens" },
    { name = "gregtech:gt.metaitem.01", damage = 99999, size = 4, label = "Lens Housing" }, -- NOT a Lens suffix!
}, {})
component._register("if-dual-001", "me_interface", ifDual)

local scan1 = Hardware.scanSubnet("if-dual-001", { baselineItems = {}, baselineFluids = {} }, { ignoreBuiltinNC = true })
assertEq(scan1.itemUnits, 4, "Built-in GT circuit/mold/lens ignored while Lens Housing counted")
assertEq(scan1.topLabel, "Lens Housing", "topLabel picks real ingredient")

-- Non-registered NC (Pink Catalyst + GT++ Extruder Shape): counted until calibrated!
local ifCat, itemsCat = makeSubnetIF({
    { name = "miscutils:MU-metaitem.01", damage = 32040, size = 1, label = "Extruder Shape (Shaft)" },
    { name = "gregtech:gt.metaitem.01", damage = 2999, size = 1, label = "Pink Catalyst" },
}, { { name = "molten.spacereserve", amount = 5000, label = "Molten NC Fluid" } })
component._register("if-cat-001", "me_interface", ifCat)

local preCal = Hardware.scanSubnet("if-cat-001", { baselineItems = {}, baselineFluids = {} }, { ignoreBuiltinNC = true })
assertEq(preCal.itemUnits, 2, "Uncalibrated GT++ shape and Catalyst are detected")
assertEq(preCal.fluidUnits, 5000, "Uncalibrated permanent fluid NC is detected")

local calSlice = { ifaceAddr = "if-cat-001", baselineItems = {}, baselineFluids = {} }
local okCal, nBI, nBF = Hardware.calibrateBaseline(calSlice, { ignoreBuiltinNC = true })
assertEq(okCal, true, "calibrateBaseline succeeds")
assertEq(nBI, 2, "2 custom NC items recorded in baseline")
assertEq(nBF, 1, "1 custom NC fluid recorded in baseline")

local atIdle = Hardware.scanSubnet("if-cat-001", calSlice, { ignoreBuiltinNC = true })
assertEq(atIdle.workScore, 0, "Calibrated idle NCs yield workScore == 0")

itemsCat[#itemsCat + 1] = { name = "minecraft:iron_ingot", damage = 0, size = 32, label = "Iron Ingot" }
local withBatch = Hardware.scanSubnet("if-cat-001", calSlice, { ignoreBuiltinNC = true })
assertEq(withBatch.itemUnits, 32, "Calibrated slice detects only active batch items (32)")

-- =========================================================================
-- TEST 3 & 4: Strict Mutual Exclusion, Settle Guard, & SRTF 15h Preemption
-- =========================================================================
component._reset()
local rs1, sides1 = makeBundledRS()
local ifScrew, itScrew = makeSubnetIF({ { name = "gt:universium_screw_mat", damage = 0, size = 54000, label = "Universium" } })
local ifQuick, itQuick = makeSubnetIF({})
component._register("rs-main-001", "redstone", rs1)
component._register("if-screw-000", "me_interface", ifScrew)
component._register("if-quick-003", "me_interface", ifQuick)

local cfg = Scheduler.defaultConfig()
cfg.armed = true
cfg.minHoldSec = 15.0
cfg.settleSec = 1.0
cfg.emptyConfirmPolls = 2
cfg.preemptRatio = 0.35
cfg.pools[1].mode = "srtf"
cfg.pools[1].rsAddr = "rs-main-001"
cfg.pools[1].side = 2
cfg.pools[1].slices[0].ifaceAddr = "if-screw-000"
cfg.pools[1].slices[0].label = "Universium Screws"
cfg.pools[1].slices[3].ifaceAddr = "if-quick-003"
cfg.pools[1].slices[3].label = "Plate Bender"

local state = Scheduler.newState()
Scheduler.syncHardware(cfg, state)

-- t=0.0: Color 0 starts
Scheduler.step(cfg, state, 0.0)
assertEq(state.poolStates[1].phase, "ACTIVE", "t=0 Color 0 active")
assertEq(sides1[2][0], 255, "Color 0 is ON")
assertEq(sides1[2][3], 0, "Color 3 is OFF")

-- t=5.0: Screws drained 5 units in 5s -> 1.0 u/s (53995s ETA!), Quick batch (16 -> 2s) arrives
itScrew[1].size = 53995
itQuick[1] = { name = "minecraft:gold_ingot", damage = 0, size = 16, label = "Gold Ingot" }
Scheduler.step(cfg, state, 5.0)
assertEq(state.poolStates[1].activeColor, 0, "t=5 No thrash preempt before minHoldSec")
assertEq(sides1[2][0], 255, "Color 0 still holds during minHold")

-- t=15.0: Screws drained to 53985 (1.0/s), heldSec=15 >= minHoldSec -> PREEMPT -> SETTLING (ALL OFF!)
itScrew[1].size = 53985
Scheduler.step(cfg, state, 15.0)
assertEq(state.poolStates[1].phase, "SETTLING", "t=15 Enters anti-contamination SETTLING")
assertEq(state.kpis.preemptions, 1, "1 preemption recorded")
for c = 0, 15 do assertEq(sides1[2][c], 0, "All colors 0 during SETTLING @t=15 C" .. c) end

-- t=15.5: Still settling (< 1.0s settleSec)
Scheduler.step(cfg, state, 15.5)
assertEq(state.poolStates[1].phase, "SETTLING", "t=15.5 Still SETTLING")
for c = 0, 15 do assertEq(sides1[2][c], 0, "All colors still 0 @t=15.5") end

-- t=16.0: Settle complete -> Color 3 activates!
Scheduler.step(cfg, state, 16.0)
assertEq(state.poolStates[1].phase, "ACTIVE", "t=16 Quick slice activates")
assertEq(state.poolStates[1].activeColor, 3, "Active color is 3")
assertEq(sides1[2][3], 255, "Color 3 is ON")
assertEq(sides1[2][0], 0, "Color 0 is OFF")

-- t=17.5 & 18.0: Quick slice empties (emptyConfirmPolls = 2) -> completes -> SETTLING -> Color 0 resumes!
itQuick[1] = nil
Scheduler.step(cfg, state, 17.5)
assertEq(state.poolStates[1].activeColor, 3, "emptyConfirm 1/2 waits one poll")
Scheduler.step(cfg, state, 18.0)
assertEq(state.kpis.completedBatches, 1, "Quick slice completed")
assertEq(state.poolStates[1].phase, "SETTLING", "Enters SETTLING before resuming Color 0")
for c = 0, 15 do assertEq(sides1[2][c], 0, "All colors 0 before resuming Color 0") end

Scheduler.step(cfg, state, 19.0)
assertEq(state.poolStates[1].phase, "ACTIVE", "Color 0 resumed after quick slice")
assertEq(state.poolStates[1].activeColor, 0, "Color 0 active again")
assertEq(sides1[2][0], 255, "Color 0 back ON")

-- =========================================================================
-- TEST 5: Stall Isolation & Automatic Yield + Recovery
-- =========================================================================
cfg.pools[1].slices[0].enabled = false
cfg.stallTimeoutSec = 120.0
cfg.retryStalledSec = 60.0
local ifStall, itStall = makeSubnetIF({ { name = "gt:stuck_item", damage = 0, size = 10, label = "Stuck Item" } })
local ifGood, itGood   = makeSubnetIF({ { name = "gt:good_item", damage = 0, size = 50, label = "Good Item" } })
component._register("if-stall-002", "me_interface", ifStall)
component._register("if-good-004", "me_interface", ifGood)
cfg.pools[1].slices[2].ifaceAddr = "if-stall-002"
cfg.pools[1].slices[4].ifaceAddr = "if-good-004"

Scheduler.step(cfg, state, 30.0) -- Color 2 activates (smaller work 10 vs 50)
Scheduler.step(cfg, state, 31.0)
assertEq(state.poolStates[1].activeColor, 2, "Stall candidate starts")
Scheduler.step(cfg, state, 152.0) -- >= 120s with 0 progress!
assertEq(state.kpis.stalledCount, 1, "Color 2 marked stalled")
assertEq(state.poolStates[1].phase, "SETTLING", "Yielded pool into SETTLING")
Scheduler.step(cfg, state, 153.5)
assertEq(state.poolStates[1].activeColor, 4, "Color 4 took over after stall")
assertEq(sides1[2][4], 255, "Color 4 ON")
-- Changing stock on Color 2 un-stalls it immediately
itStall[1].size = 20
Scheduler.step(cfg, state, 154.0)
assertEq(state.kpis.stalledCount, 0, "Stock change un-stalls Color 2 immediately")

-- =========================================================================
-- TEST 6: Multi-Pool Independence (side 2 and side 3 simultaneously)
-- =========================================================================
local pool2 = Scheduler.newPool(2, "EBF Pool", "rs-main-001", 3)
local ifP2 = makeSubnetIF({ { name = "gt:ebf_dust", damage = 0, size = 64, label = "Titanium Dust" } })
component._register("if-p2-001", "me_interface", ifP2)
pool2.slices[5].ifaceAddr = "if-p2-001"
cfg.pools[2] = pool2
Scheduler.step(cfg, state, 155.0)
assertEq(sides1[2][4], 255, "Pool 1 still active on side 2 Color 4")
assertEq(sides1[3][5], 255, "Pool 2 independently active on side 3 Color 5")

-- =========================================================================
-- TEST 7: [Auto-Scan Trunk] Auto-Pairing & Flat Part Interface Warning
-- =========================================================================
component._reset()
local rsAuto, sidesAuto = makeBundledRS()
-- Override setBundledOutput to simulate Toggle Bus connecting trunk marker item!
local trunkMap = { [0] = "if-scan-b", [1] = "if-scan-d", [2] = "if-scan-a", [3] = "if-scan-c" }
local scanItems = { ["if-scan-a"] = {}, ["if-scan-b"] = {}, ["if-scan-c"] = {}, ["if-scan-d"] = {} }
local baseSetBundled = rsAuto.setBundledOutput
rsAuto.setBundledOutput = function(side, a, b)
    baseSetBundled(side, a, b)
    for _, addr in pairs(trunkMap) do scanItems[addr][1] = nil end
    for c = 0, 15 do
        if sidesAuto[side][c] > 0 and trunkMap[c] then
            scanItems[trunkMap[c]][1] = { name = "minecraft:cobblestone", damage = 0, size = 1, label = "Cobble" }
        end
    end
end
component._register("rs-auto-001", "redstone", rsAuto)
for addr, tbl in pairs(scanItems) do
    local p = makeSubnetIF(tbl)
    component._register(addr, "me_interface", p)
end
component._register("if-flat-part", "me_interface", makeSubnetIF(nil, nil, { flatPart = true }))

local disc = Hardware.discover()
assertEq(#disc.interfaces, 4, "4 full-block interfaces discovered")
assertEq(#disc.partWarnings, 1, "1 flat cable-part warning flagged")

local scanPool = Scheduler.newPool(1, "ScanPool", "rs-auto-001", 2)
local scanRes = Hardware.autoScanTrunkPool(scanPool, { "if-scan-a", "if-scan-b", "if-scan-c", "if-scan-d" }, { pulseSec = 0.05 })
assertEq(scanRes.ok, true, "autoScanTrunkPool succeeded")
assertEq(scanRes.boundCount, 4, "Auto-bound exact 4 slices")
for c, expectedAddr in pairs(trunkMap) do
    assertEq(scanPool.slices[c].ifaceAddr, expectedAddr, "Exact permutation C" .. c)
    assertEq(sidesAuto[2][c], 0, "All colors returned OFF after Auto-Scan")
end

-- =========================================================================
-- TEST 8: Mesh UNIV_CMD (pause/resume/force_slice) & Standalone Mode Guard
-- =========================================================================
local modemReplies = {}
component._register("modem-w", "modem", {
    open = function() end,
    isWireless = function() return true end,
    setStrength = function() end,
    send = function(target, port, msgType, reqId, pay) modemReplies[#modemReplies + 1] = { target, port, msgType, reqId, pay } end,
    broadcast = function(port, msgType, pay) modemReplies[#modemReplies + 1] = { "bcast", port, msgType, pay } end,
})
local mCfg = Scheduler.defaultConfig()
mCfg.armed = true
mCfg.pools[1].rsAddr = "rs-auto-001"
local mState = Scheduler.newState()
mCfg.extLinkMode = "off"
assertEq(Hardware.pushMeshMetrics(mCfg, mState, 200.0, component, true), false, "Standalone mode blocks pushMeshMetrics")
assertEq(Hardware.handleMeshMessage(mCfg, mState, "m1", "peer1", 4205, "UNIV_CMD", "r1", serialization.serialize({ action = "pause" })), false, "Standalone ignores UNIV_CMD")

mCfg.extLinkMode = "auto"
assertEq(Hardware.pushMeshMetrics(mCfg, mState, 201.0, component, true), true, "Mesh mode sends UNIV_METRICS")
assertEq(Hardware.handleMeshMessage(mCfg, mState, "m1", "peer1", 4205, "UNIV_CMD", "r2", serialization.serialize({ action = "pause" })), true, "UNIV_CMD pause handled")
assertEq(mCfg.armed, false, "UNIV_CMD pause disarms")
assertEq(Hardware.handleMeshMessage(mCfg, mState, "m1", "peer1", 4205, "UNIV_CMD", "r3", serialization.serialize({ action = "resume" })), true, "UNIV_CMD resume handled")
assertEq(mCfg.armed, true, "UNIV_CMD resume arms")
assertEq(Hardware.handleMeshMessage(mCfg, mState, "m1", "peer1", 4205, "UNIV_CMD", "r4", serialization.serialize({ action = "force_slice", poolId = 1, color = 2 })), true, "UNIV_CMD force_slice handled")
assertEq(mState.forceColorByPool[1], 2, "forceColorByPool set to 2")

-- =========================================================================
-- TEST 9: UI Render All 4 Tabs + Modals, Touch Interactions, --check & --off
-- =========================================================================
component.gpu = component._newMockGPU(160, 50)
component._register("scr-1", "screen", {})
local ui = UI.new(cfg, state, function() end)
for t = 1, 4 do ui.tab = t; ui:render() end
ui.logModalActive = true; ui.logModalTab = 1; ui:render()
ui.logModalTab = 2; ui:render()
ui.logModalActive = false
ui:openTextPrompt("Test Prompt", "Circuit 1", function() end)
ui:render()
ui:handleKeyDown(0, 1) -- Esc closes prompt
ui:render()

-- Touch click on [ARMED ] button (x=29, y=1) toggles armed -> false
assertEq(cfg.armed, true, "armed true before touch")
ui:handleTouch(30, 1, 0)
assertEq(cfg.armed, false, "touching [ARMED ] disarms cleanly")
ui:render()

-- Render Multi-Channel & 32-NC Bank view too so every glyph renders into __RENDERED_CELL_CPS
cfg.pools[1].numSlices = 32
Scheduler.normalizeConfig(cfg)
cfg.pools[1].channels[2] = Scheduler.newChannel(2, "rs-main-001", 3)
ui.sliceBank = 1
for t = 1, 4 do ui.tab = t; ui:render() end
ui.sliceBank = 0

-- CLI --check and --off test
package.loaded["lib.hardware"] = Hardware
package.loaded["lib.policy"] = Policy
local mainChunk = assert(loadfile(__UNIV_ROOT .. "/main.lua"))
mainChunk("--check")
mainChunk("--off")

-- =========================================================================
-- TEST 11: GTNH 2.9 Push Subscriptions, 0-Scan Idle & Multi-Stack Delta Varargs
-- =========================================================================
component._reset()
local evScans = { a = 0, b = 0 }
local evItemsA, evFluidsA = {}, {}
local evItemsB, evFluidsB = {}, {}
local function makeSubIF(key, itemsTbl, fluidsTbl)
    local subI, subF = false, false
    return {
        getItemsInNetwork = function()
            evScans[key] = evScans[key] + 1
            return itemsTbl
        end,
        getFluidsInNetwork = function() return fluidsTbl end,
        setItemEventSubscription = function(v) subI = (v == true) return nil end,
        setFluidEventSubscription = function(v) subF = (v == true) return nil end,
        isItemEventSubscription = function() return subI end,
        isFluidEventSubscription = function() return subF end,
    }
end
local rsEv, sidesEv = makeBundledRS()
component._register("rs-ev", "redstone", rsEv)
component._register("if-ev-a", "me_interface", makeSubIF("a", evItemsA, evFluidsA))
component._register("if-ev-b", "me_interface", makeSubIF("b", evItemsB, evFluidsB))

local evCfg = Scheduler.defaultConfig()
evCfg.armed = true
evCfg.idlePollSec = 30.0
evCfg.pools[1].rsAddr = "rs-ev"
evCfg.pools[1].side = 2
evCfg.pools[1].slices[0].ifaceAddr = "if-ev-a"
evCfg.pools[1].slices[1].ifaceAddr = "if-ev-b"

local evState = Scheduler.newState()
Scheduler.syncHardware(evCfg, evState)
assertEq(evState._allSubscribed, true, "All bound interfaces subscribed via GTNH 2.9 EventSubscription")

-- Initial seed scan at t=0.0
Scheduler.step(evCfg, evState, 0.0)
assertEq(evScans.a, 1, "Initial seed scan A = 1")
assertEq(evScans.b, 1, "Initial seed scan B = 1")
assertEq(Scheduler.nextWakeupDelay(evCfg, evState, 0.0), 30.0, "Idle subscribed sleeps idlePollSec (30s)")

-- Idle ticks t=1..10 must execute ZERO getItemsInNetwork scans!
for t = 1, 10 do
    Scheduler.step(evCfg, evState, t * 1.0)
end
assertEq(evScans.a, 1, "0 scans on idle subscribed slice A")
assertEq(evScans.b, 1, "0 scans on idle subscribed slice B")

-- Push 6 distinct item stacks + 2 fluids via incremental delta events!
local batch6 = {
    { name = "gt:item1", damage = 0, size = 4, label = "Item 1" },
    { name = "gt:item2", damage = 1, size = 8, label = "Item 2" },
    { name = "gt:item3", damage = 2, size = 12, label = "Item 3" },
    { name = "gt:item4", damage = 3, size = 16, label = "Item 4" },
    { name = "gt:item5", damage = 4, size = 20, label = "Item 5" },
    { name = "gt:item6", damage = 5, size = 40, label = "Item 6" },
}
for i = 1, #batch6 do evItemsA[i] = { name = batch6[i].name, damage = batch6[i].damage, size = batch6[i].size, label = batch6[i].label } end
evFluidsA[1] = { name = "oxygen", amount = 4000, label = "Oxygen" }
evFluidsA[2] = { name = "nitrogen", amount = 2000, label = "Nitrogen" }

assert(Scheduler.handleNetworkEvent(evCfg, evState, "network_item_changed", "if-ev-a", batch6, 10.2), "Handled 6-stack item delta")
assert(Scheduler.handleNetworkEvent(evCfg, evState, "network_fluid_changed", "if-ev-a", evFluidsA, 10.2), "Handled 2-fluid delta")
assertEq(evState._forcePollNow, true, "Event sets _forcePollNow for 0ms wakeup")

Scheduler.step(evCfg, evState, 10.5)
assertEq(evState.poolStates[1].activeColor, 0, "NC 0 activated via push event")
assertEq(evScans.a, 1, "Still 0 extra scans after arrival event")
assertEq(sidesEv[2][0], 255, "Redstone ON from event delta alone")

-- Partial drain delta while > 0 (must NOT scan A or idle B)
evItemsA[6].size = 20
Scheduler.handleNetworkEvent(evCfg, evState, "network_item_changed", "if-ev-a", {
    { name = "gt:item6", damage = 5, size = -20, label = "Item 6" },
}, 11.0)
Scheduler.step(evCfg, evState, 11.5)
assertEq(evScans.a, 1, "Still 0 scans during live positive drain delta")
assertEq(evScans.b, 1, "Idle B still untouched")

-- Full drain to 0 triggers 1 ground-truth confirm scan -> batch complete -> back to 30s sleep!
for i = 1, 6 do evItemsA[i] = nil end
evFluidsA[1], evFluidsA[2] = nil, nil
Scheduler.handleNetworkEvent(evCfg, evState, "network_item_changed", "if-ev-a", {
    { name = "gt:item1", damage = 0, size = -4 },
    { name = "gt:item2", damage = 1, size = -8 },
    { name = "gt:item3", damage = 2, size = -12 },
    { name = "gt:item4", damage = 3, size = -16 },
    { name = "gt:item5", damage = 4, size = -20 },
    { name = "gt:item6", damage = 5, size = -20 },
}, 12.0)
Scheduler.handleNetworkEvent(evCfg, evState, "network_fluid_changed", "if-ev-a", {
    { name = "oxygen", amount = -4000 },
    { name = "nitrogen", amount = -2000 },
}, 12.0)
Scheduler.step(evCfg, evState, 12.2)
assertEq(evScans.a, 2, "Exact 1 ground-truth confirm scan on reaching 0")
assertEq(evScans.b, 1, "Idle B remained at 0 extra scans")
assertEq(evState.kpis.completedBatches, 1, "1 event-driven batch completed cleanly")
assertEq(Scheduler.nextWakeupDelay(evCfg, evState, 12.2), 30.0, "Returns to 30s deep sleep once idle")

-- =========================================================================
-- TEST 12: MLFQ Probe When Amount != Duration + Recipe Speed Cache
-- =========================================================================
component._reset()
local rsM, sidesM = makeBundledRS()
local ifSlow, itSlow, flSlow = makeSubnetIF({ { name = "gt:xenoxene_ore", damage = 0, size = 10, label = "Xenoxene" } }, {})
local ifFast, itFast, flFast = makeSubnetIF({}, {})
component._register("rs-mlfq", "redstone", rsM)
component._register("if-slow-0", "me_interface", ifSlow)
component._register("if-fast-1", "me_interface", ifFast)

local mCfg2 = Scheduler.defaultConfig()
mCfg2.armed = true
mCfg2.probeWindowSec = 1.5
mCfg2.probePreemptHoldSec = 1.5
mCfg2.fastThresholdSec = 3.0
mCfg2.minHoldSec = 15.0
mCfg2.settleSec = 0.5
mCfg2.emptyConfirmPolls = 1
mCfg2.pools[1].mode = "mlfq"
mCfg2.pools[1].rsAddr = "rs-mlfq"
mCfg2.pools[1].side = 2
mCfg2.pools[1].slices[0].ifaceAddr = "if-slow-0"
mCfg2.pools[1].slices[1].ifaceAddr = "if-fast-1"

local mSt2 = Scheduler.newState()
Scheduler.syncHardware(mCfg2, mSt2)

-- t=0.0: Slow Xenoxene (10 items) starts in PROBE
Scheduler.step(mCfg2, mSt2, 0.0)
assertEq(mSt2.poolStates[1].activeColor, 0, "Slow NC0 starts in PROBE")

-- t=1.5: Xenoxene only drained 0.375 -> 9.625 (0.25/s -> 38.5s ETA), graduates to BULK & caches slow rate!
itSlow[1].size = 9.625
Scheduler.step(mCfg2, mSt2, 1.5)
assertEq(mSt2.sliceStates["1:0"].tier, "BULK", "Xenoxene graduates to BULK at probeWindowSec=1.5s")

-- t=2.0: 250,000 L Hydrogen (workScore = 250.0 >> 9.625!) arrives in NC1 -> enters PROBE & preempts BULK Xenoxene!
flFast[1] = { name = "hydrogen", amount = 250000, label = "Hydrogen" }
Scheduler.step(mCfg2, mSt2, 2.0)
assertEq(mSt2.sliceStates["1:1"].tier, "PROBE", "Huge fast fluid enters PROBE tier despite 250 > 9.625 workScore")
assertEq(mSt2.poolStates[1].phase, "SETTLING", "Preempts BULK Xenoxene after probePreemptHoldSec")
Scheduler.step(mCfg2, mSt2, 2.5)
assertEq(mSt2.poolStates[1].activeColor, 1, "Hydrogen NC1 active on trunk")

-- Hydrogen finishes 250,000 L in 0.5s -> caches 500 u/s speed!
flFast[1] = nil
Scheduler.step(mCfg2, mSt2, 3.0)
assert(next(mSt2.recipeRates) ~= nil, "Recipe speed cache populated for Xenoxene + Hydrogen")

-- Both clear -> Repeat arrival simultaneously: Xenoxene (10) AND Hydrogen (250,000 L) at t=5.0!
itSlow[1] = nil
Scheduler.step(mCfg2, mSt2, 4.0)
Scheduler.step(mCfg2, mSt2, 4.5) -- settled & idle
itSlow[1] = { name = "gt:xenoxene_ore", damage = 0, size = 10, label = "Xenoxene" }
flFast[1] = { name = "hydrogen", amount = 250000, label = "Hydrogen" }
Scheduler.step(mCfg2, mSt2, 5.0)
assertEq(mSt2.sliceStates["1:0"].tier, "BULK", "Repeat Xenoxene immediately classified BULK from recipe cache")
assertEq(mSt2.sliceStates["1:1"].tier, "PROBE", "Repeat Hydrogen immediately classified PROBE from recipe cache")
assertEq(mSt2.poolStates[1].activeColor, 1, "Fast 250kL Hydrogen beats 10 slow Xenoxene IMMEDIATELY on repeat!")

-- =========================================================================
-- TEST 13: Multi-Channel Ch1 High->Ch2 Low BULK Demotion & 0s Fast Preempt
-- =========================================================================
component._reset()
local rsMC, sidesMC = makeBundledRS()
local ifA, itA = makeSubnetIF({ { name = "gt:long_recipe", damage = 0, size = 5000, label = "Long Recipe" } })
local ifB, itB = makeSubnetIF({})
component._register("rs-mc", "redstone", rsMC)
component._register("if-mc-a", "me_interface", ifA)
component._register("if-mc-b", "me_interface", ifB)

local mcCfg = Scheduler.defaultConfig()
mcCfg.armed = true
mcCfg.settleSec = 1.0
mcCfg.probeWindowSec = 1.5
mcCfg.pools[1].mode = "mlfq"
mcCfg.pools[1].channels = {
    [1] = Scheduler.newChannel(1, "rs-mc", 2), -- North (Ch1 High Prio Black)
    [2] = Scheduler.newChannel(2, "rs-mc", 3), -- South (Ch2 Low Prio Blue)
}
mcCfg.pools[1].rsAddr = "rs-mc"
mcCfg.pools[1].side = 2
mcCfg.pools[1].slices[0].ifaceAddr = "if-mc-a"
mcCfg.pools[1].slices[4].ifaceAddr = "if-mc-b"

local mcSt = Scheduler.newState()
Scheduler.syncHardware(mcCfg, mcSt)

-- t=0.0: Single job starts on Ch1 (PROBE)
Scheduler.step(mcCfg, mcSt, 0.0)
assertEq(sidesMC[2][0], 255, "t=0.0 New job starts on Ch1 High Prio")
assertEq(sidesMC[3][0], 0, "Ch2 stays OFF")

-- t=1.5: Graduates to BULK -> immediately demotes Ch1 -> Ch2, leaving Ch1 IDLE & OFF!
itA[1].size = 4990
Scheduler.step(mcCfg, mcSt, 1.5)
assertEq(sidesMC[2][0], 0, "t=1.5 Ch1 turns OFF on demotion")
assertEq(sidesMC[3][0], 255, "t=1.5 Ch2 takes over Long Recipe NC0 seamlessly")

-- t=3.0: Fast craft arrives in NC4 -> Ch1 already settled -> starts with 0s delay while Ch2 stays on NC0!
itB[1] = { name = "gt:fast_chip", damage = 0, size = 8, label = "Fast Chip" }
Scheduler.step(mcCfg, mcSt, 3.0)
assertEq(sidesMC[2][4], 255, "t=3.0 Ch1 activates NC4 with ZERO settle delay")
assertEq(sidesMC[3][0], 255, "t=3.0 Ch2 continues NC0 uninterrupted in true parallel")

-- Verify miswired duplicate (rsAddr, side) guard refuses 2 active colors on same wire!
mcCfg.pools[1].channels[2].banks[1].side = 2
Scheduler.step(mcCfg, mcSt, 3.2)
local onSide2 = 0
for c = 0, 15 do if sidesMC[2][c] > 0 then onSide2 = onSide2 + 1 end end
assert(onSide2 <= 1, "Miswired duplicate wire never asserts 2 colors simultaneously")

-- =========================================================================
-- TEST 14: 32-NC Dual-Bank Wiring + Round-Robin / FIFO / Priority Policies
-- =========================================================================
component._reset()
local rs32, sides32 = makeBundledRS()
local ifB22 = makeSubnetIF({ { name = "gt:extruder_bar", damage = 0, size = 32, label = "Alloy Bar" } })
component._register("rs-32", "redstone", rs32)
component._register("if-32-22", "me_interface", ifB22)

local cfg32 = Scheduler.defaultConfig()
cfg32.armed = true
cfg32.pools[1].numSlices = 32
cfg32.pools[1].rsAddr = "rs-32"
cfg32.pools[1].side = 2
cfg32.pools[1].channels[1].banks[2] = { rsAddr = "rs-32", side = 4 } -- West Bank B (16..31)
cfg32.pools[1].slices = {}
for idx = 0, 31 do cfg32.pools[1].slices[idx] = { color = idx, label = "NC" .. idx, priority = "normal", enabled = true } end
cfg32.pools[1].slices[22].ifaceAddr = "if-32-22"

local st32 = Scheduler.newState()
Scheduler.syncHardware(cfg32, st32)
Scheduler.step(cfg32, st32, 0.0)
assertEq(sides32[4][6], 255, "NC 22 routes to Bank B (side 4) Color 6 (22 % 16)")
assertEq(sides32[2][6], 0, "Bank A (side 2) stays OFF")

-- Policy unit verification: FIFO & Priority modes
local polPool = Scheduler.newPool(1, "Pol", "rs-32", 2)
local pCands = {
    { ncIdx = 0, color = 0, slice = polPool.slices[0], priWeight = 2, tier = "BULK", tierRank = 0, rawEta = 5, effectiveEta = 5, busySince = 20, workScore = 40 },
    { ncIdx = 1, color = 1, slice = polPool.slices[1], priWeight = 2, tier = "BULK", tierRank = 0, rawEta = 50, effectiveEta = 50, busySince = 10, workScore = 400 },
}
polPool.mode = "fifo"
local dFifo = Policy.decide(polPool, nil, pCands, {}, cfg32, 30)
assertEq(dFifo[1], 1, "FIFO picks earlier busySince (10 < 20) regardless of ETA")
polPool.mode = "priority"
pCands[1].priWeight = 3
local dPri = Policy.decide(polPool, nil, pCands, {}, cfg32, 30)
assertEq(dPri[1], 0, "Priority picks higher priWeight (3 > 2)")

-- =========================================================================
-- TEST 15: Native GT Hatch Spray-Color Priority Mapping & Color Validation
-- =========================================================================
component._reset()
local rsDye, sidesDye = makeBundledRS()
local ifDyeA, itDyeA = makeSubnetIF({ { name = "gt:heavy_polymer", damage = 0, size = 5000, label = "Heavy Polymer" } })
local ifDyeB, itDyeB = makeSubnetIF({})
component._register("rs-dye", "redstone", rsDye)
component._register("if-dye-a", "me_interface", ifDyeA)
component._register("if-dye-b", "me_interface", ifDyeB)

-- Configure Ch1 (North, side=2) = Orange (gtDye=14, GT #15 LOW) and
--           Ch2 (South, side=3) = Red    (gtDye=1,  GT #2  HIGH)!
-- Array order Ch1..Ch2 is reversed relative to native GT priority!
local dyeCfg = Scheduler.defaultConfig()
dyeCfg.armed = true
dyeCfg.settleSec = 1.0
dyeCfg.probeWindowSec = 1.5
dyeCfg.pools[1].mode = "mlfq"
dyeCfg.pools[1].channels = {
    [1] = Scheduler.newChannel(1, "rs-dye", 2, 14), -- North = Orange (Low prio #15)
    [2] = Scheduler.newChannel(2, "rs-dye", 3, 1),  -- South = Red (High prio #2)
}
dyeCfg.pools[1].rsAddr = "rs-dye"
dyeCfg.pools[1].side = 2
dyeCfg.pools[1].slices[0].ifaceAddr = "if-dye-a"
dyeCfg.pools[1].slices[4].ifaceAddr = "if-dye-b"

local dyeSt = Scheduler.newState()
Scheduler.syncHardware(dyeCfg, dyeSt)
assertEq(Scheduler.validateChannelColors(dyeCfg.pools[1]), nil, "Distinct Orange & Red colors valid")

-- t=0.0: New job starts on Ch2 (South, Red = native HIGH priority wire!)
Scheduler.step(dyeCfg, dyeSt, 0.0)
assertEq(sidesDye[3][0], 255, "t=0.0 PROBE uses Ch2 South (Red #2 HIGH) over Ch1 North (Orange #15 LOW)")
assertEq(sidesDye[2][0], 0, "Ch1 Orange stays OFF initially")

-- t=1.5: Graduates to BULK -> demotes from Ch2 (Red) to Ch1 (Orange), freeing Ch2 (Red) pre-settled!
itDyeA[1].size = 4990
Scheduler.step(dyeCfg, dyeSt, 1.5)
assertEq(sidesDye[3][0], 0, "t=1.5 Ch2 Red turns OFF on demotion")
assertEq(sidesDye[2][0], 255, "t=1.5 Ch1 Orange takes over BULK NC0")

-- t=3.0: Fast craft arrives in NC4 -> Ch2 Red is already pre-settled and starts with 0s delay!
itDyeB[1] = { name = "gt:fast_wafer", damage = 0, size = 8, label = "Fast Wafer" }
Scheduler.step(dyeCfg, dyeSt, 3.0)
assertEq(sidesDye[3][4], 255, "t=3.0 Ch2 Red activates NC4 immediately (0s delay)")
assertEq(sidesDye[2][0], 255, "t=3.0 Ch1 Orange continues BULK NC0 uninterrupted")

-- Validation catches duplicate GT dye colors and unpainted (-1) on multi-channel pools
local origD = dyeCfg.pools[1].channels[2].gtDye
dyeCfg.pools[1].channels[2].gtDye = 14
assert(Scheduler.validateChannelColors(dyeCfg.pools[1]) ~= nil, "Duplicate Orange dye triggers validation warning")
dyeCfg.pools[1].channels[2].gtDye = -1
assert(Scheduler.validateChannelColors(dyeCfg.pools[1]) ~= nil, "Unpainted (-1) on 2-channel pool triggers warning")
dyeCfg.pools[1].channels[2].gtDye = origD

-- Keep objects alive so Python checks true live heap usage
rawset(_G, "__HELD_OBJECTS", { cfg, state, ui, scanPool, evState, mSt2, mcSt, st32, dyeSt })
"""
            host.exec_lua(lua_suite, "universal_test_suite")

            # Verify zero bad-width glyphs rendered onto 160x50 GPU screen!
            host.exec_lua(
                """
                local out = {}
                for cp in pairs(__RENDERED_CELL_CPS) do out[#out + 1] = tostring(cp) end
                return table.concat(out, ",")
                """,
                "collect_glyphs",
            )
            cp_raw = host.exec_lua(
                """
                local out = {}
                for cp in pairs(__RENDERED_CELL_CPS) do out[#out + 1] = tostring(cp) end
                return table.concat(out, ",")
                """,
                "collect_glyphs2",
            ) or ""
            bad_glyphs = []
            for s in cp_raw.split(","):
                if s:
                    cp = int(s)
                    w = font_widths.get(cp, -1)
                    if w != 1:
                        bad_glyphs.append((chr(cp), hex(cp), w))
            assert not bad_glyphs, f"Non-width-1 glyphs found in universal UI: {bad_glyphs}"

            # Check live JNLua memory footprint (< 3072 KB)
            L = host.lib
            L.lua_gc.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
            L.lua_gc.restype = ctypes.c_int
            L.lua_gc(host.L, 2, 0)
            live_kb = L.lua_gc(host.L, 3, 0)
            assert live_kb < 3072, f"Live JNLua heap exceeded budget: {live_kb} KB"

            # Verify --check & --off output
            cli_out = "\n".join(host.stdout)
            assert "=== GTNH UNIVERSAL CONTROL READ-ONLY CHECK ===" in cli_out
            assert "CHECK COMPLETE (NO REDSTONE MODIFIED)" in cli_out
            assert "Forced all bundled redstone outputs OFF" in cli_out

            # =====================================================================
            # TEST 10: Standalone & Root Monorepo Installer Tests (if root exists)
            # =====================================================================
            monorepo_root = UNIV_ROOT.parent
            root_install = monorepo_root / "install.lua"
            inst_host = LuaHost(Path(td), font_widths)
            try:
                inst_host.exec_lua(
                    """
                    local component = require("component")
                    component._register("rs-1", "redstone", { setBundledOutput = function() return true end })
                    local inst = assert(loadfile(__UNIV_ROOT .. "/install.lua"))
                    local ok = inst("--local", __UNIV_ROOT, "--yes", "--no-autostart")
                    assert(ok, "Standalone install failed")
                    local f = io.open("/home/universal/config.cfg", "w")
                    f:write("{armed=false,customTag=999}")
                    f:close()
                    local okUp = inst("--local", __UNIV_ROOT, "--update", "--yes")
                    assert(okUp, "Standalone update failed")
                    local f2 = io.open("/home/universal/config.cfg", "r")
                    local body = f2:read("*a")
                    f2:close()
                    assert(body:find("customTag=999", 1, true), "Update overwrote config.cfg!")
                    assert(__py_exists("/home/universal/main.lua"), "Missing installed main.lua")
                    assert(__py_exists("/home/universal/lib/policy.lua"), "Missing installed lib/policy.lua")
                    assert(__py_exists("/usr/bin/universal.lua"), "Missing /usr/bin/universal.lua")
                    """,
                    "standalone_install_test",
                )
                if root_install.is_file():
                    inst_host.stdout.clear()
                    inst_host.exec_lua(
                        """
                        local rootInst = assert(loadfile(__MONOREPO_ROOT .. "/install.lua"))
                        rootInst("--list")
                        assert(rootInst("--local", __MONOREPO_ROOT, "universal", "--yes", "--no-autostart"), "Monorepo install universal failed")
                        assert(rootInst("--local", __MONOREPO_ROOT, "ae2", "--yes", "--no-autostart"), "Monorepo install ae2 failed")
                        assert(rootInst("--local", __MONOREPO_ROOT, "pump", "--yes", "--no-autostart"), "Monorepo install pump failed")
                        assert(rootInst("--local", __MONOREPO_ROOT, "gorge", "--yes", "--no-autostart"), "Monorepo install gorge failed")
                        assert(__py_exists("/home/exporter.lua"), "Missing installed /home/exporter.lua")
                        assert(__py_exists("/home/config.lua"), "Missing installed /home/config.lua")
                        assert(__py_exists("/home/autoPump.lua"), "Missing installed /home/autoPump.lua")
                        local fae = io.open("/home/config.lua", "w"); fae:write("return { customAe = 42 }"); fae:close()
                        local okU = rootInst("--local", __MONOREPO_ROOT, "--update", "--yes")
                        assert(okU, "Root monorepo --update failed")
                        local fae2 = io.open("/home/config.lua", "r"); local aeBody = fae2:read("*a"); fae2:close()
                        assert(aeBody:find("customAe = 42", 1, true), "Monorepo --update overwrote /home/config.lua!")
                        local fu = io.open("/home/universal/config.cfg", "r"); local uBody = fu:read("*a"); fu:close()
                        assert(uBody:find("customTag=999", 1, true), "Monorepo --update overwrote /home/universal/config.cfg!")
                        assert(__py_exists("/home/.oc-gtnh.manifest"), "Missing monorepo manifest")
                        """,
                        "monorepo_install_test",
                    )
                    m_out = "\n".join(inst_host.stdout)
                    assert "universal" in m_out and "dtpf" in m_out, "Missing modules in root --list output"
            finally:
                inst_host.close()

            print(
                f"ALL UNIVERSAL CONTROL OFFLINE SUITES PASSED "
                f"(0 bad-width glyphs, {live_kb} KB live JNLua heap, Lua 5.3 + OpenOS verified)."
            )
        finally:
            host.close()


if __name__ == "__main__":
    run_all_tests()
