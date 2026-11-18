#!/usr/bin/env python3
"""Offline Lua 5.3 + OpenComputers JNLua test suite for gtnh-gorge-control."""

from __future__ import annotations

import ctypes
import os
import sys
import tempfile
import zipfile
from pathlib import Path

GORGE_ROOT = Path(__file__).resolve().parent.parent


def _find_gtnh_root(start: Path) -> Path:
    for parent in start.parents:
        if (parent / "tools/jdks").exists() or list(parent.glob("GT_NH_*/mods/OpenComputers-*.jar")):
            return parent
    return start.parent.parent


def _discover_jvm_dylib() -> Path:
    env = os.environ.get("JVM_DYLIB")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(GORGE_ROOT)
    cands = sorted(gtnh_root.glob("tools/jdks/**/libjvm.dylib"), reverse=True) + sorted(gtnh_root.glob("tools/jdks/**/libjvm.so"), reverse=True)
    if cands:
        return cands[0]
    return gtnh_root / "tools/jdks/jdk8/Contents/Home/jre/lib/server/libjvm.dylib"


def _discover_oc_jar() -> Path:
    env = os.environ.get("OC_JAR")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(GORGE_ROOT)
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
local rootDir = "{GORGE_ROOT}"
__GORGE_ROOT = rootDir
__MONOREPO_ROOT = "{GORGE_ROOT.parent}"
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
local Plasmas = require("lib.plasmas")
local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")
local UI = require("lib.ui")

assert(collectgarbage == nil, "OpenComputers sandbox must omit collectgarbage")

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAIL [%s]: expected=%s actual=%s", tostring(msg), tostring(expected), tostring(actual)))
    end
end

-- =====================================================================
-- TEST 1: Syntax / Load Check of All 6 Lua Files
-- =====================================================================
for _, rel in ipairs({
    "lib/plasmas.lua",
    "lib/hardware.lua",
    "lib/scheduler.lua",
    "lib/ui.lua",
    "main.lua",
    "install.lua",
    "config.example.lua",
}) do
    local src = __py_read_file(__GORGE_ROOT .. "/" .. rel)
    assert(src and #src > 0, "Missing file: " .. rel)
    local chunk, err = load(src, "@" .. rel, "t")
    assert(chunk, "Syntax error in " .. rel .. ": " .. tostring(err))
end

-- =====================================================================
-- TEST 2: GTNH 2.9 Plasmas & Exoticizer Batch Math
-- =====================================================================
assertEq(Plasmas.resolve("gluon", "Chrome"), "plasma.chrome", "Chrome in GLUON")
assertEq(Plasmas.resolve("gluon", "Bismuth"), "plasma.bismuth", "Bismuth in GLUON")
assertEq(Plasmas.resolve("gluon", "Mercury"), "plasma.mercury", "Mercury in GLUON")
assertEq(Plasmas.resolve("gluon", "Raw Silicon"), "plasma.silicon", "Raw Silicon in GLUON")
assertEq(Plasmas.resolve("gluon", "Silicon"), "plasma.silicon", "Silicon in GLUON")
assertEq(Plasmas.resolve("magmatter", "Cosmic Neutronium"), "plasma.cosmicneutronium", "Magmatter plasma")

-- Tiny Pile / Tiny Dust (coeff=1) vs Dust (coeff=9), Gas stripping, fluid_drop filtering
local gItems = {
    { label = "Chrome Dust", size = 2 },                     -- 18 ingots = 2592 L
    { label = "Tiny Pile of Bismuth Dust", size = 5 },       -- 5 nuggets = 720 L
    { label = "Tiny Antimony Dust", size = 3 },              -- 3 nuggets = 432 L
    { label = "Iron Dust", size = 1 },                       -- 9 ingots = 1296 L
    { label = "Ignore Fluid Drop", name = "ae2fc:fluid_drop", size = 999 },
}
local gFluids = {
    { label = "Mercury", amount = 1 },                       -- 1000 L
    { label = "Argon Gas", amount = 3 },                     -- 3000 L, Gas stripped
    { label = "Deuterium Gas", amount = 2 },                 -- 2000 L, Gas stripped
}
local gOut, gCnt = Plasmas.parseOutputNetwork(gItems, gFluids)
assertEq(gCnt, 7, "Gluon parsed 7 outputs")
assertEq(gOut["Chrome"].count, 18, "Chrome Dust coeff=9")
assertEq(gOut["Bismuth"].count, 5, "Tiny Pile coeff=1")
assertEq(gOut["Antimony"].count, 3, "Tiny Dust coeff=1")
assert(gOut["Argon"] and gOut["Argon"].isLiquid == true, "Argon Gas stripped & marked fluid")
assert(not gOut["Ignore Fluid Drop"], "ae2fc:fluid_drop filtered out")

local gBatch, gErr = Plasmas.computeBatchInputs("gluon", gOut)
assert(gBatch and not gErr, "Gluon batch compute ok: " .. tostring(gErr))
assertEq(#gBatch, 7, "Gluon batch has 7 inputs")
local gByFluid = {}
for _, inp in ipairs(gBatch) do gByFluid[inp.fluid] = inp.amount end
assertEq(gByFluid["plasma.chrome"], 18 * 144, "Chrome plasma mb")
assertEq(gByFluid["plasma.bismuth"], 5 * 144, "Bismuth plasma mb")
assertEq(gByFluid["plasma.mercury"], 1 * 1000, "Mercury fluid bucket -> 1000 mb")
assertEq(gByFluid["plasma.argon"], 3 * 1000, "Argon Gas -> 3000 mb")

-- Magmatter diff math & equal spatial/temporal guard
local mOut, mCnt = Plasmas.parseOutputNetwork(
    { { label = "Cosmic Neutronium Dust", size = 1 } },
    {
        { label = "Spatially Enlarged Fluid", amount = 12000 },
        { label = "Tachyon Rich Temporal Fluid", amount = 5000 },
    }
)
assertEq(mCnt, 3, "Magmatter parsed 3 outputs")
local mBatch, mErr = Plasmas.computeBatchInputs("magmatter", mOut)
assert(mBatch and not mErr, "Magmatter batch ok: " .. tostring(mErr))
assertEq(#mBatch, 3, "Magmatter batch has 3 inputs")
local mByFluid = {}
for _, inp in ipairs(mBatch) do mByFluid[inp.fluid] = inp.amount end
assertEq(mByFluid["spatialfluid"], 12000, "Spatial amount")
assertEq(mByFluid["temporalfluid"], 5000, "Temporal amount")
assertEq(mByFluid["plasma.cosmicneutronium"], 7000 * 144, "Diff(12000-5000) * 144")

local badMOut = Plasmas.parseOutputNetwork(
    { { label = "Draconium Dust", size = 1 } },
    {
        { label = "Spatially Enlarged Fluid", amount = 4000 },
        { label = "Tachyon Rich Temporal Fluid", amount = 4000 },
    }
)
local nilBatch, eqErr = Plasmas.computeBatchInputs("magmatter", badMOut)
assert(nilBatch == nil and eqErr:find("difference is 0", 1, true), "Zero diff guarded")

-- =====================================================================
-- TEST 3: Dual Exoticizer Sharing 1 Database + Full FSM + Dynamic Drain
-- =====================================================================
local function makeExoticizerRig(opts)
    opts = opts or {}
    local outItems, outFluids = opts.outItems or {}, opts.outFluids or {}
    local outIf = {
        getItemsInNetwork = function() return outItems end,
        getFluidsInNetwork = function() return outFluids end,
    }
    local pattern = { outputs = { { size = 1 } }, inputs = { { size = 1 } } }
    local cpus = { { cpu = { isBusy = function() return false end, finalOutput = function() return nil end, cancel = function() return true end } } }
    local activeFake = nil
    local encodedSets = {}
    local craftReqCount = 0
    local inIf = {
        getInterfacePattern = function(slot) return (slot == 1) and pattern or nil end,
        clearInterfacePatternOutput = function(slot, idx) pattern.outputs[idx] = nil return true end,
        clearInterfacePatternInput = function(slot, idx) pattern.inputs[idx] = nil return true end,
        setInterfacePatternOutput = function(slot, dbAddr, dbSlot, amt, outIdx)
            pattern.outputs[outIdx] = { dbAddr = dbAddr, dbSlot = dbSlot, amt = amt }
            encodedSets[#encodedSets + 1] = { kind = "out", dbSlot = dbSlot, amt = amt }
            return true
        end,
        setInterfacePatternInput = function(slot, dbAddr, dbSlot, amt, inIdx)
            pattern.inputs[inIdx] = { dbAddr = dbAddr, dbSlot = dbSlot, amt = amt }
            encodedSets[#encodedSets + 1] = { kind = "in", dbSlot = dbSlot, amt = amt }
            return true
        end,
        getCpus = function()
            cpus[1].cpu.isBusy = function() return activeFake ~= nil end
            cpus[1].cpu.finalOutput = function() return activeFake and { label = activeFake } or nil end
            cpus[1].cpu.cancel = function()
                activeFake = nil
                return true
            end
            return cpus
        end,
        getCraftables = function(filter)
            if opts.failCraft then return {} end
            return { {
                request = function(_)
                    craftReqCount = craftReqCount + 1
                    activeFake = filter and filter.label
                    return { isComputing = function() return false end }
                end
            } }
        end,
    }

    local driveCount = opts.cellCount or 3
    local ioOutCount = 0
    local tp = {
        getInventorySize = function(_) return 10 end,
        getSlotStackSize = function(side, slot)
            if side == 4 then
                return (slot <= driveCount) and 1 or 0
            elseif side == 5 then
                if slot >= 7 and slot <= 12 then
                    return (slot - 6 <= ioOutCount) and 1 or 0
                end
            end
            return 0
        end,
        transferItem = function(fromS, toS, cnt, fromSlot)
            if fromS == 4 and toS == 5 and driveCount > 0 then
                driveCount = driveCount - 1
                ioOutCount = ioOutCount + 1
                -- Moving cells out clears the output subnet!
                if driveCount == 0 then
                    for k in pairs(outItems) do outItems[k] = nil end
                    for k in pairs(outFluids) do outFluids[k] = nil end
                end
                return 1
            elseif fromS == 5 and toS == 4 and ioOutCount > 0 then
                ioOutCount = ioOutCount - 1
                driveCount = driveCount + 1
                return 1
            end
            return 0
        end,
    }
    return {
        outIf = outIf, inIf = inIf, tp = tp,
        outItems = outItems, outFluids = outFluids,
        pattern = pattern, encodedSets = encodedSets,
        getCraftReqCount = function() return craftReqCount end,
        getDriveCount = function() return driveCount end,
    }
end

component._reset()
local dbSlots = {}
local dbProxy = {
    get = function(slot) return dbSlots[slot] end,
    set = function(slot, name, dmg, nbt)
        dbSlots[slot] = { name = name, dmg = dmg, nbt = nbt }
        return true
    end,
}
component._register("db-11111111", "database", dbProxy)

local rig1 = makeExoticizerRig({
    cellCount = 1,
    outItems = { { label = "Draconium Dust", size = 1 } },
    outFluids = {
        { label = "Spatially Enlarged Fluid", amount = 9000 },
        { label = "Tachyon Rich Temporal Fluid", amount = 2000 },
    },
})
local rig2 = makeExoticizerRig({
    cellCount = 3,
    outItems = {
        { label = "Chrome Dust", size = 1 },
        { label = "Bismuth Dust", size = 1 },
        { label = "Mercury", size = 1 },
        { label = "Tin Dust", size = 1 },
    },
    outFluids = {
        { label = "Argon Gas", amount = 1 },
        { label = "Helium Gas", amount = 1 },
        { label = "Nitrogen Gas", amount = 1 },
    },
})

local rsSignal1, rsSignal2 = 15, 15
component._register("if-out-1", "me_interface", rig1.outIf)
component._register("if-in-1", "me_interface", rig1.inIf)
component._register("tp-1", "transposer", rig1.tp)
component._register("rs-1", "redstone", { getInput = function() return rsSignal1 end })

component._register("if-out-2", "me_interface", rig2.outIf)
component._register("if-in-2", "me_interface", rig2.inIf)
component._register("tp-2", "transposer", rig2.tp)
component._register("rs-2", "redstone", { getInput = function() return rsSignal2 end })

local cfg3 = Scheduler.defaultConfig()
cfg3.armed = true
cfg3.exoticizers[1].mode = "auto"
cfg3.exoticizers[1].outputMeInterfaceAddress = "if-out-1"
cfg3.exoticizers[1].inputMeInterfaceAddress = "if-in-1"
cfg3.exoticizers[1].transposerAddress = "tp-1"
cfg3.exoticizers[1].redstoneIoAddress = "rs-1"
cfg3.exoticizers[2].mode = "auto"
cfg3.exoticizers[2].outputMeInterfaceAddress = "if-out-2"
cfg3.exoticizers[2].inputMeInterfaceAddress = "if-in-2"
cfg3.exoticizers[2].transposerAddress = "tp-2"
cfg3.exoticizers[2].redstoneIoAddress = "rs-2"

local st3 = Scheduler.newState()
Scheduler.syncHardware(cfg3, st3)

-- Step 1: both detect outputs -> encode -> clear AE -> request -> WAIT_END!
Scheduler.step(cfg3, st3, 10.0, { craftWaitSec = 0, sleepFn = function() end })
assertEq(st3.exStates[1].activeMode, "magmatter", "Auto mode picked magmatter for Ex#1")
assertEq(st3.exStates[2].activeMode, "gluon", "Auto mode picked gluon for Ex#2")
assertEq(st3.exStates[1].phase, "WAIT_END", "Ex#1 reached WAIT_END")
assertEq(st3.exStates[2].phase, "WAIT_END", "Ex#2 reached WAIT_END")
assertEq(rig1.getDriveCount(), 1, "Ex#1 returned its 1 storage cell")
assertEq(rig2.getDriveCount(), 3, "Ex#2 returned all 3 storage cells")

-- Verify disjoint DB slice partitioning: Ex#1 uses slots 1..4, Ex#2 uses slots 11..18!
assert(dbSlots[1] and dbSlots[1].nbt:find("Fake recipe G1 db-11111", 1, true), "Ex#1 marker in slot 1")
assert(dbSlots[2] and dbSlots[4] and not dbSlots[5], "Ex#1 used 3 input slots (2..4)")
assert(dbSlots[11] and dbSlots[11].nbt:find("Fake recipe G2 db-11111", 1, true), "Ex#2 marker in slot 11")
assert(dbSlots[12] and dbSlots[18] and not dbSlots[19], "Ex#2 used 7 input slots (12..18)")

-- Step 2: idle while waiting for next Godforge output
Scheduler.step(cfg3, st3, 12.0)
assertEq(st3.exStates[1].phase, "WAIT_END", "Ex#1 stays WAIT_END while subnet empty")

-- Step 3: new output arrives on both subnets -> cancel fake crafts & complete cycles!
rig1.outItems[1] = { label = "Iron Dust", size = 1 }
rig2.outFluids[1] = { label = "Chlorine", amount = 1 }
Scheduler.step(cfg3, st3, 14.0, { cancelWaitSec = 0, sleepFn = function() end })
assertEq(st3.exStates[1].phase, "IDLE", "Ex#1 completed cycle -> IDLE")
assertEq(st3.exStates[2].phase, "IDLE", "Ex#2 completed cycle -> IDLE")
assertEq(st3.kpis.completedCycles, 2, "2 total completed cycles")

-- =====================================================================
-- TEST 4: Self-Healing Proxy + Bounded RETRY_WAIT Auto-Recovery
-- =====================================================================
local flakyCalls = 0
local rigF = makeExoticizerRig({
    failCraft = true,
    outItems = { { label = "Draconium Dust", size = 1 } },
    outFluids = {
        { label = "Spatially Enlarged Fluid", amount = 6000 },
        { label = "Tachyon Rich Temporal Fluid", amount = 2000 },
    },
})
-- First getItemsInNetwork call simulates stale proxy crash ("no such component")
local origGetItems = rigF.outIf.getItemsInNetwork
rigF.outIf.getItemsInNetwork = function(...)
    flakyCalls = flakyCalls + 1
    if flakyCalls == 1 then
        error("no such component")
    end
    return origGetItems(...)
end
component._reset()
component._register("db-22222222", "database", dbProxy)
component._register("if-out-f", "me_interface", rigF.outIf)
component._register("if-in-f", "me_interface", rigF.inIf)
component._register("tp-f", "transposer", rigF.tp)
component._register("rs-f", "redstone", { getInput = function() return 15 end })

local cfg4 = Scheduler.defaultConfig()
cfg4.armed = true
cfg4.retryBackoffSec = 10.0
cfg4.exoticizers = { cfg4.exoticizers[1] }
cfg4.exoticizers[1].mode = "magmatter"
cfg4.exoticizers[1].outputMeInterfaceAddress = "if-out-f"
cfg4.exoticizers[1].inputMeInterfaceAddress = "if-in-f"
cfg4.exoticizers[1].transposerAddress = "tp-f"
cfg4.exoticizers[1].redstoneIoAddress = "rs-f"
local st4 = Scheduler.newState()
Scheduler.syncHardware(cfg4, st4)

-- Self-healing: step 1 survives flaky call #1, fails craft #1 (stay in REQUEST)
Scheduler.step(cfg4, st4, 1.0, { craftWaitSec = 0, sleepFn = function() end })
assertEq(st4.exStates[1].phase, "REQUEST", "Self-healed proxy & failed craft 1/3")
Scheduler.step(cfg4, st4, 2.0, { craftWaitSec = 0, sleepFn = function() end })
assertEq(st4.exStates[1].phase, "REQUEST", "Failed craft 2/3")
Scheduler.step(cfg4, st4, 3.0, { craftWaitSec = 0, sleepFn = function() end })
assertEq(st4.exStates[1].phase, "RETRY_WAIT", "Entered RETRY_WAIT on 3rd failure (no modal hang!)")

-- After backoff, auto-recovers!
rigF.outItems[1] = nil
for k in pairs(rigF.outFluids) do rigF.outFluids[k] = nil end
Scheduler.step(cfg4, st4, 15.0)
assertEq(st4.exStates[1].phase, "IDLE", "Auto-recovered from RETRY_WAIT after backoff")

-- =====================================================================
-- TEST 5: Godforge Controller + LSC Hysteresis + Mesh + Standalone Guard
-- =====================================================================
component._reset()
local gfWorkAllowed = true
local gfProxy = {
    getName = function() return "gt_machine_fog" end,
    getSensorInformation = function()
        return {
            "Number of Rings: §e3",
            "tt.infodata.fog.connected\\4",
            "tt.infodata.fog.upgrades.unlocked\\12",
        }
    end,
    isMachineActive = function() return gfWorkAllowed end,
    hasWork = function() return true end,
    isWorkAllowed = function() return gfWorkAllowed end,
    setWorkAllowed = function(v) gfWorkAllowed = v; return true end,
    getWorkProgress = function() return 150 end,
    getWorkMaxProgress = function() return 600 end,
}
local lscPctVal = 15
local lscProxy = {
    getSensorInformation = function()
        return { "Used Capacity: " .. tostring(lscPctVal) .. "%" }
    end,
}
local meshSent = {}
local modemProxy = {
    isOpen = function() return true end,
    isWireless = function() return true end,
    getStrength = function() return 400 end,
    setStrength = function() end,
    open = function() end,
    broadcast = function(port, msgType, payload) meshSent[#meshSent + 1] = { port = port, t = msgType, p = payload } end,
    send = function(addr, port, msgType, p1, p2) meshSent[#meshSent + 1] = { addr = addr, port = port, t = msgType, p1 = p1, p2 = p2 } end,
}
component._register("gt-gf-1", "gt_machine", gfProxy)
component._register("lsc-1", "LSC", lscProxy)
component._register("mod-1", "modem", modemProxy)

local cfg5 = Scheduler.defaultConfig()
cfg5.armed = true
cfg5.godforge.onDemandEnable = true
cfg5.godforge.minLscPct = 20
cfg5.godforge.resumeLscPct = 35
cfg5.exoticizers = { cfg5.exoticizers[1] }
cfg5.exoticizers[1].outputMeInterfaceAddress = "missing-if"
local st5 = Scheduler.newState()
Scheduler.syncHardware(cfg5, st5)
assertEq(cfg5.godforge.controllerAddr, "gt-gf-1", "Discovered Godforge controller")

-- LSC 15% < 20% -> PAUSE Godforge
Scheduler.step(cfg5, st5, 10.0)
assertEq(gfWorkAllowed, false, "LSC < min pauses Godforge")
assertEq(st5.godforge.rings, 3, "Parsed Rings")
assertEq(st5.godforge.connected, 4, "Parsed Connected Modules")
assertEq(st5.godforge.upgrades, 12, "Parsed Upgrades")

-- LSC 28% (between 20% and 35%) -> hysteresis HOLD
lscPctVal = 28
Scheduler.step(cfg5, st5, 11.0)
assertEq(gfWorkAllowed, false, "Hysteresis holds Godforge paused at 28%")

-- LSC 36% >= 35% -> RESUME Godforge
lscPctVal = 36
Scheduler.step(cfg5, st5, 12.0)
assertEq(gfWorkAllowed, true, "LSC >= resume unpauses Godforge")

-- Mesh push & GORGE_CMD dispatch
Hardware.pushMeshMetrics(cfg5, st5, 12.0, nil, true)
assert(#meshSent >= 1 and meshSent[1].t == "GORGE_METRICS", "Sent GORGE_METRICS over port 4205")
Hardware.handleMeshMessage(cfg5, st5, "mod-1", "ae2-host", 4205, "GORGE_CMD", "req-9", serialization.serialize({ action = "pause" }))
assertEq(cfg5.armed, false, "GORGE_CMD pause disarmed Gorge")
assertEq(meshSent[#meshSent].t, "GORGE_REPLY", "Sent GORGE_REPLY")

-- Standalone guard (`extLinkMode == "off"`): ignores incoming Mesh & suppresses push
local beforeCnt = #meshSent
cfg5.extLinkMode = "off"
Hardware.pushMeshMetrics(cfg5, st5, 30.0, nil, true)
assertEq(#meshSent, beforeCnt, "Standalone mode suppressed pushMeshMetrics")
local hOff = Hardware.handleMeshMessage(cfg5, st5, "mod-1", "ae2-host", 4205, "GORGE_CMD", "req-10", serialization.serialize({ action = "resume" }))
assertEq(hOff, false, "Standalone mode ignored GORGE_CMD")
assertEq(cfg5.armed, false, "Standalone did not resume")

-- =====================================================================
-- TEST 6: UI 3 Tabs + Log Modal + Glyph Check + Touch Interactions
-- =====================================================================
component.gpu = component._newMockGPU(160, 50)
local savedCount = 0
local ui6 = UI.new(cfg3, st3, function() savedCount = savedCount + 1 end)
for t = 1, 3 do
    ui6.tab = t
    ui6:render()
end
ui6.logModalActive = true
ui6:render()
assert(#ui6.hitboxes > 0, "Log modal rendered close hitbox")
ui6.logModalActive = false
ui6.tab = 1
ui6:render()
-- Switch via keyboard key '2' (50) and '3' (51)
ui6:handleKeyDown(50, 3)
assertEq(ui6.tab, 2, "Key '2' switched to Exoticizer Inspector")
ui6:handleKeyDown(51, 4)
assertEq(ui6.tab, 3, "Key '3' switched to Setup & Wiring")
-- Click "[ARMED ]" or "[PAUSED]" button in header (x=38, y=1)
local prevArmed = cfg3.armed
ui6:handleTouch(38, 1, 0)
assertEq(cfg3.armed, not prevArmed, "Touch toggled Armed button")

-- =====================================================================
-- TEST 7: CLI --check & --off Entrypoint Tests
-- =====================================================================
do
    local mainChunk = assert(loadfile(__GORGE_ROOT .. "/main.lua"))
    mainChunk("--check")
    mainChunk("--off")
    local cfgAfterOff = serialization.unserialize(__py_read_file(__GORGE_ROOT .. "/config.cfg"))
    assertEq(cfgAfterOff.armed, false, "--off disarmed config")
end

rawset(_G, "__HELD_OBJECTS", { cfg3, st3, cfg4, st4, cfg5, st5, ui6 })
"""
            host.exec_lua(lua_suite, "gorge_test_suite")

            # Glyph check across all rendered screen cells
            cp_raw = host.exec_lua(
                """
                local out = {}
                for cp in pairs(__RENDERED_CELL_CPS) do out[#out + 1] = tostring(cp) end
                return table.concat(out, ",")
                """,
                "collect_glyphs",
            ) or ""
            bad_glyphs = []
            for s in cp_raw.split(","):
                if s:
                    cp = int(s)
                    w = font_widths.get(cp, -1)
                    if w != 1:
                        bad_glyphs.append((chr(cp), hex(cp), w))
            assert not bad_glyphs, f"Non-width-1 glyphs found in gorge UI: {bad_glyphs}"

            # Suite memory footprint (< 2400 KB)
            L = host.lib
            L.lua_gc.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
            L.lua_gc.restype = ctypes.c_int
            L.lua_gc(host.L, 2, 0)
            live_kb = L.lua_gc(host.L, 3, 0)
            assert live_kb < 2400, f"Live JNLua heap exceeded suite budget: {live_kb} KB"

            # Dedicated single-instance production footprint (< 800 KB)
            prod_host = LuaHost(Path(td), font_widths)
            try:
                prod_host.exec_lua(
                    """
                    local component = require("component")
                    local Scheduler = require("lib.scheduler")
                    local UI = require("lib.ui")
                    component._reset()
                    component.gpu = {
                        maxResolution = function() return 160, 50 end,
                        setResolution = function() return true end,
                        setForeground = function() end,
                        setBackground = function() end,
                        set = function() end,
                    }
                    component._register("scr-p", "screen", {})
                    component._register("if-1", "me_interface", {
                        getItemsInNetwork = function() return {} end,
                        getFluidsInNetwork = function() return {} end,
                        getCpus = function() return {} end,
                    })
                    local c = Scheduler.defaultConfig()
                    local st = Scheduler.newState()
                    Scheduler.syncHardware(c, st)
                    Scheduler.step(c, st, 0.0)
                    local u = UI.new(c, st, function() end)
                    for t = 1, 3 do u.tab = t; u:render() end
                    rawset(_G, "__PROD_HOLD", { c, st, u })
                    """,
                    "prod_footprint_test",
                )
                Lp = prod_host.lib
                Lp.lua_gc.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
                Lp.lua_gc.restype = ctypes.c_int
                Lp.lua_gc(prod_host.L, 2, 0)
                prod_kb = Lp.lua_gc(prod_host.L, 3, 0)
                assert prod_kb < 800, f"Single-instance JNLua production footprint exceeded 800 KB: {prod_kb} KB"
            finally:
                prod_host.close()

            # Verify --check & --off CLI output
            cli_out = "\n".join(host.stdout)
            assert "=== GTNH GORGE & EXOTICIZER READ-ONLY CHECK ===" in cli_out, "Missing --check header"
            assert "CHECK COMPLETE" in cli_out, "Missing CHECK COMPLETE"
            assert "Gorge Control disarmed" in cli_out, "Missing --off confirmation"

            # =====================================================================
            # TEST 8: Standalone install.lua & Root Monorepo install.lua (`gorge`)
            # =====================================================================
            monorepo_root = GORGE_ROOT.parent
            inst_host = LuaHost(Path(td), font_widths)
            try:
                inst_host.exec_lua(
                    """
                    local inst = assert(loadfile(__GORGE_ROOT .. "/install.lua"))
                    assert(inst("--local", __GORGE_ROOT, "--yes", "--no-autostart"), "Standalone gorge install failed")
                    assert(__py_exists("/home/gorge/main.lua"), "Missing /home/gorge/main.lua")
                    assert(__py_exists("/home/gorge/lib/plasmas.lua"), "Missing /home/gorge/lib/plasmas.lua")
                    assert(__py_exists("/home/gorge/lib/hardware.lua"), "Missing /home/gorge/lib/hardware.lua")
                    assert(__py_exists("/home/gorge/lib/scheduler.lua"), "Missing /home/gorge/lib/scheduler.lua")
                    assert(__py_exists("/home/gorge/lib/ui.lua"), "Missing /home/gorge/lib/ui.lua")
                    assert(__py_exists("/usr/bin/gorge.lua"), "Missing /usr/bin/gorge.lua")
                    local f = io.open("/home/gorge/config.cfg", "w")
                    f:write("{armed=false,customGorge=777}")
                    f:close()
                    assert(inst("--local", __GORGE_ROOT, "--update", "--yes"), "Standalone gorge --update failed")
                    local f2 = io.open("/home/gorge/config.cfg", "r")
                    local body = f2:read("*a")
                    f2:close()
                    assert(body:find("customGorge=777", 1, true), "Update overwrote /home/gorge/config.cfg!")
                    assert(__py_exists("/home/config.gorge.bak"), "Missing /home/config.gorge.bak")

                    local rootInst = assert(loadfile(__MONOREPO_ROOT .. "/install.lua"))
                    rootInst("--list")
                    assert(rootInst("--local", __MONOREPO_ROOT, "gorge", "--yes", "--no-autostart"), "Root monorepo install gorge failed")
                    assert(__py_exists("/home/.oc-gtnh.manifest"), "Missing monorepo manifest")
                    """,
                    "install_test",
                )
                assert "gorge" in "\n".join(inst_host.stdout), "Root --list missing gorge"
            finally:
                inst_host.close()

            print(
                f"ALL GORGE CONTROL OFFLINE SUITES PASSED "
                f"(0 bad-width glyphs, {prod_kb} KB single-instance / {live_kb} KB suite live JNLua heap, Lua 5.3 + OpenOS verified)."
            )
        finally:
            host.close()


if __name__ == "__main__":
    run_all_tests()
