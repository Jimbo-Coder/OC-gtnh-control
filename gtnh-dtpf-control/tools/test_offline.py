#!/usr/bin/env python3
"""Offline Lua 5.3 + OpenComputers JNLua test suite for gtnh-dtpf-control."""

from __future__ import annotations

import ctypes
import json
import os
import sys
import tempfile
import zipfile
from pathlib import Path

DTPF_ROOT = Path(__file__).resolve().parent.parent


def _find_gtnh_root(start: Path) -> Path:
    for parent in start.parents:
        if (parent / "tools/jdks").exists() or list(parent.glob("GT_NH_*/mods/OpenComputers-*.jar")):
            return parent
    return start.parent.parent


def _discover_jvm_dylib() -> Path:
    env = os.environ.get("JVM_DYLIB")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(DTPF_ROOT)
    cands = sorted(gtnh_root.glob("tools/jdks/**/libjvm.dylib"), reverse=True) + sorted(gtnh_root.glob("tools/jdks/**/libjvm.so"), reverse=True)
    if cands:
        return cands[0]
    java_home = os.environ.get("JAVA_HOME")
    if java_home:
        for rel in ("jre/lib/server/libjvm.dylib", "lib/server/libjvm.dylib", "lib/server/libjvm.so"):
            p = Path(java_home) / rel
            if p.is_file():
                return p
    return gtnh_root / "tools/jdks/jdk8/Contents/Home/jre/lib/server/libjvm.dylib"


def _discover_oc_jar() -> Path:
    env = os.environ.get("OC_JAR")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(DTPF_ROOT)
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
    """Embedded OpenComputers Lua 5.3 VM using libjnlua53 + virtual OpenOS shim."""

    def __init__(self, temp_dir: Path) -> None:
        ctypes.CDLL(str(JVM_DYLIB), ctypes.RTLD_GLOBAL)
        with zipfile.ZipFile(OC_JAR) as zf:
            dylib_path = zf.extract(
                "assets/opencomputers/lib/libjnlua53-darwin-aarch64.dylib", str(temp_dir)
            )
            self.serialization_lua = zf.read(
                "assets/opencomputers/loot/openos/lib/serialization.lua"
            ).decode("utf-8")

        self.lib = ctypes.CDLL(dylib_path)
        L = self.lib
        L.luaL_newstate.restype = ctypes.c_void_p
        L.luaL_requiref.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_int]
        L.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
        L.lua_gettop.argtypes = [ctypes.c_void_p]
        L.lua_gettop.restype = ctypes.c_int
        L.luaL_loadbufferx.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
            ctypes.c_char_p,
            ctypes.c_char_p,
        ]
        L.luaL_loadbufferx.restype = ctypes.c_int
        L.lua_pcallk.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_long,
            ctypes.c_void_p,
        ]
        L.lua_pcallk.restype = ctypes.c_int
        L.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
        L.lua_tolstring.restype = ctypes.c_char_p
        L.lua_pushlstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
        L.lua_pushboolean.argtypes = [ctypes.c_void_p, ctypes.c_int]
        L.lua_pushnil.argtypes = [ctypes.c_void_p]
        L.lua_pushcclosure.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
        L.lua_setglobal.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
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
        self._cfuncs = []  # keep CFUNCTYPE references alive

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
            path = self._get_str(1)
            content = self._get_str(2)
            self.vfs[path] = content
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
            src = self._get_str(1)
            dst = self._get_str(2)
            if src in self.vfs:
                self.vfs[dst] = self.vfs.pop(src)
                self.lib.lua_pushboolean(L_ptr, 1)
                return 1
            self.lib.lua_pushboolean(L_ptr, 0)
            return 1

        def py_print(L_ptr) -> int:
            self.stdout.append(self._get_str(1))
            return 0

        self._register_cfunc("__py_read_file", py_read_file)
        self._register_cfunc("__py_write_file", py_write_file)
        self._register_cfunc("__py_exists", py_exists)
        self._register_cfunc("__py_remove_vfs", py_remove_vfs)
        self._register_cfunc("__py_rename_vfs", py_rename_vfs)
        self._register_cfunc("__py_print", py_print)

    def _install_openos_shim(self) -> None:
        shim = f"""
local rootDir = "{DTPF_ROOT}"
__DTPF_ROOT = rootDir
__RENDERED_GPU_CALLS = {{}}
-- OpenComputers' sandbox exposes no collectgarbage() to guest OpenOS scripts (host machine.lua runs GC automatically)
collectgarbage = nil
function checkArg(n, have, ...)
    local t = type(have)
    for i = 1, select("#", ...) do
        if t == select(i, ...) then return end
    end
    error(string.format("bad argument #%d (%s expected, got %s)", n, table.concat({{ ... }}, " or "), t), 3)
end

local _oldPrint = print
function print(...)
    local parts = {{}}
    local n = select("#", ...)
    for i = 1, n do parts[i] = tostring(select(i, ...)) end
    __py_print(table.concat(parts, "\t"))
end

io = {{
    stderr = {{
        write = function(_, s) __py_print("[STDERR] " .. tostring(s)) end
    }},
    open = function(path, mode)
        mode = mode or "r"
        if mode:sub(1, 1) == "w" then
            local buf = {{}}
            return {{
                write = function(_, s) buf[#buf + 1] = tostring(s) end,
                close = function() __py_write_file(path, table.concat(buf)) end,
            }}
        else
            local content = __py_read_file(path)
            if not content then return nil, "not found: " .. tostring(path) end
            return {{
                read = function(_, fmt) return content end,
                close = function() end,
            }}
        end
    end,
}}

function loadfile(path, mode, env)
    local src = __py_read_file(path)
    if not src then return nil, "not found: " .. tostring(path) end
    return load(src, "=" .. tostring(path), mode or "t", env or _G)
end

package = {{
    path = rootDir .. "/?.lua",
    loaded = {{}},
    preload = {{}},
}}

function require(name)
    if package.loaded[name] ~= nil then return package.loaded[name] end
    if package.preload[name] then
        local mod = package.preload[name](name)
        package.loaded[name] = (mod == nil) and true or mod
        return package.loaded[name]
    end
    local rel = name:gsub("%.", "/")
    for pat in package.path:gmatch("[^;]+") do
        local candidate = pat:gsub("%?", rel)
        if __py_exists(candidate) then
            local src = __py_read_file(candidate)
            local chunk, err = load(src, "@" .. candidate)
            if not chunk then error("load error in " .. candidate .. ": " .. tostring(err)) end
            local res = chunk(candidate)
            package.loaded[name] = (res == nil) and true or res
            return package.loaded[name]
        end
    end
    error("module '" .. tostring(name) .. "' not found")
end

-- OpenOS modules
local filesystem = {{}}
function filesystem.path(p)
    return p:match("^(.*)/[^/]+$") or "/"
end
function filesystem.canonical(p)
    return p
end
function filesystem.concat(a, b)
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
end
function filesystem.exists(p)
    return __py_exists(p)
end
function filesystem.makeDirectory(_)
    return true
end
function filesystem.remove(p)
    return __py_remove_vfs(p)
end
function filesystem.rename(a, b)
    return __py_rename_vfs(a, b)
end
package.loaded["filesystem"] = filesystem

local uptimeVal = 100.0
os = {{
    clock = function() return uptimeVal end,
    getenv = function(_) return nil end,
    remove = function(p) return __py_remove_vfs(p) end,
    rename = function(a, b) return __py_rename_vfs(a, b) end,
    sleep = function() end,
}}
package.loaded["os"] = os

local serChunk, serErr = load(__py_read_file("/__openos__/serialization.lua"), "@serialization.lua")
assert(serChunk, serErr)
local serialization = serChunk()
package.loaded["serialization"] = serialization

local unicode = {{}}
function unicode.wlen(s)
    local n = utf8.len(tostring(s or ""))
    return n or #tostring(s or "")
end
function unicode.sub(s, i, j)
    s = tostring(s or "")
    local len = unicode.wlen(s)
    if i < 0 then i = len + i + 1 end
    if i < 1 then i = 1 end
    local startByte = utf8.offset(s, i)
    if not startByte then return "" end
    if not j then return s:sub(startByte) end
    if j < 0 then j = len + j + 1 end
    if j < i then return "" end
    local endByte = utf8.offset(s, j + 1)
    if endByte then return s:sub(startByte, endByte - 1) end
    return s:sub(startByte)
end
package.loaded["unicode"] = unicode

local uptimeVal = 100.0
package.loaded["computer"] = {{
    uptime = function()
        uptimeVal = uptimeVal + 0.5
        return uptimeVal
    end,
}}

package.loaded["term"] = {{
    clear = function() end,
}}

local queuedEvents = {{}}
package.loaded["event"] = {{
    _queue = queuedEvents,
    pull = function(_, filter)
        if filter ~= nil then
            for idx = 1, #queuedEvents do
                if queuedEvents[idx][1] == filter then
                    local ev = table.remove(queuedEvents, idx)
                    return table.unpack(ev)
                end
            end
            return nil
        end
        if #queuedEvents > 0 then
            local ev = table.remove(queuedEvents, 1)
            return table.unpack(ev)
        end
        return "interrupted"
    end,
}}

-- Configurable mock component registry + 160x50 GPU framebuffer
local registry = {{}} -- addr -> {{ type = ..., proxy = ... }}
local component = {{}}
function component._reset()
    for k in pairs(registry) do registry[k] = nil end
end
function component._register(addr, ctype, proxy)
    registry[addr] = {{ type = ctype, proxy = proxy }}
end
function component.list(filter, exact)
    local matches = {{}}
    for addr, rec in pairs(registry) do
        if (not filter)
            or (exact and rec.type == filter)
            or (not exact and rec.type:find(filter, 1, true)) then
            matches[#matches + 1] = {{ addr, rec.type }}
        end
    end
    table.sort(matches, function(a, b) return a[1] < b[1] end)
    local idx = 0
    return function()
        idx = idx + 1
        if matches[idx] then return matches[idx][1], matches[idx][2] end
    end
end
function component.proxy(addr)
    local rec = registry[addr]
    return rec and rec.proxy or nil
end
function component.isAvailable(ctype)
    if ctype == "gpu" and component.gpu then return true end
    for _, rec in pairs(registry) do
        if rec.type == ctype then return true end
    end
    return false
end

function component._newMockGPU(w, h)
    w, h = w or 160, h or 50
    local cells = {{}}
    for y = 1, h do
        cells[y] = {{}}
        for x = 1, w do cells[y][x] = " " end
    end
    local fg, bg = 0xFFFFFF, 0x000000
    local calls = {{}}
    local gpu = {{
        _w = w,
        _h = h,
        _cells = cells,
        _calls = calls,
        maxResolution = function() return w, h end,
        setResolution = function(nw, nh)
            assert(nw >= 1 and nw <= w and nh >= 1 and nh <= h, "invalid resolution")
            return true
        end,
        setForeground = function(c) fg = c end,
        setBackground = function(c) bg = c end,
        fill = function(x, y, fw, fh, ch)
            assert(x >= 1 and y >= 1 and x + fw - 1 <= w and y + fh - 1 <= h,
                string.format("gpu.fill out of bounds: (%d,%d,%d,%d)", x, y, fw, fh))
            ch = ch or " "
            for ry = y, y + fh - 1 do
                for rx = x, x + fw - 1 do
                    cells[ry][rx] = ch
                end
            end
        end,
        set = function(x, y, txt)
            txt = tostring(txt or "")
            local tw = unicode.wlen(txt)
            assert(x >= 1 and y >= 1 and y <= h and x + tw - 1 <= w,
                string.format("gpu.set out of bounds: (%d,%d) len=%d txt=%s", x, y, tw, txt))
            calls[#calls + 1] = txt
            local pos = 0
            for _, cp in utf8.codes(txt) do
                local ch = utf8.char(cp)
                if x + pos <= w then
                    cells[y][x + pos] = ch
                end
                pos = pos + 1
            end
        end,
        _rowText = function(y)
            return table.concat(cells[y])
        end,
        _allText = function()
            local lines = {{}}
            for y = 1, h do lines[y] = table.concat(cells[y]) end
            return table.concat(lines, "\\n")
        end,
    }}
    component.gpu = gpu
    return gpu
end

component._newMockGPU(160, 50)
package.loaded["component"] = component

-- Strict _G guard (NASA P10): catch any undeclared global read/write in any module or UI path
setmetatable(_G, {{
    __index = function(_, k)
        error("Undeclared global read: " .. tostring(k), 2)
    end,
    __newindex = function(_, k, _)
        error("Undeclared global write: " .. tostring(k), 2)
    end,
}})
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
        host = LuaHost(Path(td))
        try:
            test_suite = r"""
local component = require("component")
local serialization = require("serialization")
local unicode = require("unicode")
local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")
local UI = require("lib.ui")

local function assertEq(actual, expected, label)
    if actual ~= expected then
        error(string.format("ASSERT FAIL [%s]: expected=%s actual=%s",
            tostring(label), tostring(expected), tostring(actual)))
    end
end

-- Helper to build realistic DTPF mock component
local function makeDTPF(addr, x, y, z, opts)
    opts = opts or {}
    local state = {
        x = x, y = y, z = z,
        workAllowed = (opts.workAllowed ~= false),
        active = (opts.active == true),
        hasWork = (opts.hasWork == true),
        progress = opts.progress or 0,
        maxProgress = opts.maxProgress or 0,
        conv = (opts.conv == true),
        catTier = opts.catTier or 4,
        coilHeat = opts.coilHeat or 13500,
        discountPct = opts.discountPct or 50,
        ticks = opts.ticks or 44697577,
        coverBlocksWork = (opts.coverBlocksWork == true),
        calls = {},
    }
    local function fmtInt(n)
        local s = tostring(math.floor(n))
        return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
    end
    local proxy = {
        getCoordinates = function() return state.x, state.y, state.z end,
        getName = function() return "plasmaforge" end,
        isWorkAllowed = function() return state.workAllowed end,
        setWorkAllowed = function(v)
            state.calls[#state.calls + 1] = { "setWorkAllowed", v }
            if not state.coverBlocksWork then state.workAllowed = v end
        end,
        isMachineActive = function() return state.active end,
        hasWork = function() return state.hasWork end,
        getWorkProgress = function() return state.progress end,
        getWorkMaxProgress = function() return state.maxProgress end,
        isConvergenceEnabled = function() return state.conv end,
        setConvergenceEnabled = function(v)
            state.calls[#state.calls + 1] = { "setConvergenceEnabled", v }
            state.conv = v
        end,
        getConvergenceCatalystType = function() return state.catTier end,
        setConvergenceCatalystType = function(t)
            state.calls[#state.calls + 1] = { "setConvergenceCatalystType", t }
            state.catTier = t
        end,
        getSensorInformation = function()
            return {
                "GT5U.EBF.heat.s\\" .. fmtInt(state.coilHeat),
                string.format("GT5U.infodata.plasma_forge.ticks_run_fuel_discount\\§a%s§r\\§c%d§r%%\\0",
                    fmtInt(state.ticks), state.discountPct),
                "GT5U.infodata.plasma_forge.convergence\\" ..
                    (state.conv and "§aActive§r, perfect convergence achieved" or "§cInactive§r"),
            }
        end,
    }
    return proxy, state
end

local function makeStorageBus(addr, validSide, isFluid)
    local slots = {}
    local calls = {}
    local proxy = {
        getStorageSlotSize = function(side)
            return (side == validSide) and 63 or 0
        end,
        setStorageConfiguration = function(side, slot, detail)
            calls[#calls + 1] = { side = side, slot = slot, detail = detail }
            slots[slot] = detail
            return true
        end,
        getStorageConfiguration = function(side, slot)
            return slots[slot]
        end,
    }
    return proxy, slots, calls
end

local function makeAENet(fluidsMap, itemsMap)
    local proxy = {
        getFluidsInNetwork = function()
            local out = {}
            for k, v in pairs(fluidsMap) do
                if v > 0 then
                    out[#out + 1] = { name = k, amount = v, size = v, label = k }
                end
            end
            return out
        end,
        getItemsInNetwork = function()
            local out = {}
            for k, v in pairs(itemsMap) do
                if v > 0 then
                    local name, dmg = k:match("^(.-):(%d+)$")
                    out[#out + 1] = { name = name, damage = tonumber(dmg) or 0, size = v, amount = v, label = name }
                end
            end
            return out
        end,
    }
    return proxy
end

-- ============================================================================
-- TEST 1: GTNH 2.9.0 Encoded & Decoded Sensor Parsing
-- ============================================================================
do
    local parsed = Hardware.parseDTPFSensor({
        "GT5U.EBF.heat.s\\13,500",
        "GT5U.infodata.plasma_forge.ticks_run_fuel_discount\\§a44,697,577§r\\§c50§r%\\0",
        "GT5U.infodata.plasma_forge.convergence\\§aActive§r, perfect convergence achieved",
    })
    assertEq(parsed.coilHeat, 13500, "T1 encoded coilHeat")
    assertEq(parsed.runningTicks, 44697577, "T1 encoded runningTicks")
    assertEq(parsed.discountPct, 50, "T1 encoded discountPct")
    assertEq(parsed.extraCatalystNeeded, 0, "T1 encoded extraCatalystNeeded")
    assertEq(parsed.convergenceActive, true, "T1 encoded convergenceActive")
    assertEq(parsed.convergenceAchieved, true, "T1 encoded convergenceAchieved")

    local inactiveParsed = Hardware.parseDTPFSensor({
        "Heat Capacity: 10,800 K",
        "Ticks run: 1,234 Fuel Discount: 25.0%",
        "Convergence: Inactive",
    })
    assertEq(inactiveParsed.coilHeat, 10800, "T1 english coilHeat")
    assertEq(inactiveParsed.runningTicks, 1234, "T1 english ticks")
    assertEq(inactiveParsed.discountPct, 25.0, "T1 english discount")
    assertEq(inactiveParsed.convergenceActive, false, "T1 english convergence Inactive")

    local lcParsed = Hardware.parseDTPFSensor({
        "Heat capacity: \194\167a13,500 \194\167rK",
    })
    assertEq(lcParsed.coilHeat, 13500, "T1 lowercase Heat capacity with § codes")

    local nbspParsed = Hardware.parseDTPFSensor({
        "GT5U.EBF.heat.s\\13\194\160500",
    })
    assertEq(nbspParsed.coilHeat, 13500, "T1 encoded coilHeat with NBSP separator")

    local zeroParsed = Hardware.parseDTPFSensor({
        "GT5U.EBF.heat.s\\0",
    })
    assertEq(zeroParsed.coilHeat, nil, "T1 unformed 0K coilHeat treated as nil")

    local markerParsed = Hardware.parseDTPFSensor({
        [0] = "\1GTPP.EBF.heat.s\\12,600",
        [1] = "\1GT5U.infodata.plasma_forge.convergence\\Active, achieved",
    })
    assertEq(markerParsed.coilHeat, 12600, "T1 handles TRANSLATABLE_MARKER \\1 + 0-indexed GTPP heat line")
    assertEq(markerParsed.convergenceActive, true, "T1 0-indexed table parsed convergence")

    local dblSlashParsed = Hardware.parseDTPFSensor({
        "Owned by: StankCIty",
        "Meta-ID: 1004 valid",
        "GT5U.EBF.heat.s\\\\13,500",
        "GT5U.infodata.plasma_forge.ticks_run_fuel_discount\\\\§a44,697,577§r\\\\§c50§r%\\\\0",
        "GT5U.infodata.plasma_forge.convergence\\\\§aActive§r, perfect convergence achieved",
    })
    assertEq(dblSlashParsed.coilHeat, 13500, "T1 GTNH 2.9 double-backslash coilHeat")
    assertEq(dblSlashParsed.discountPct, 50, "T1 GTNH 2.9 double-backslash discountPct")
    assertEq(dblSlashParsed.extraCatalystNeeded, 0, "T1 GTNH 2.9 double-backslash extraCatalystNeeded")
    assertEq(dblSlashParsed.convergenceActive, true, "T1 GTNH 2.9 double-backslash convergenceActive")
end

-- ============================================================================
-- TEST 2: Multi-return getCoordinates & In-World 2x3 Spatial Grid Mapping
-- ============================================================================
do
    component._reset()
    -- Intentionally register out of order with non-alphabetical UUIDs to test (z, x) sorting
    local roomCoords = {
        { addr = "ffff-5", x = 25, y = 67, z = 138 },
        { addr = "eeee-2", x = 53, y = 67, z = 82  },
        { addr = "aaaa-4", x = 53, y = 67, z = 110 },
        { addr = "dddd-1", x = 25, y = 67, z = 82  },
        { addr = "cccc-3", x = 25, y = 67, z = 110 },
    }
    for _, rc in ipairs(roomCoords) do
        local p = makeDTPF(rc.addr, rc.x, rc.y, rc.z)
        component._register(rc.addr, "dtpf", p)
    end
    local discovered = Hardware.discoverDTPFs()
    assertEq(#discovered, 5, "T2 discovered count")
    assertEq(discovered[1].x .. "," .. discovered[1].z, "25,82", "T2 slot 1 sorted")
    assertEq(discovered[2].x .. "," .. discovered[2].z, "53,82", "T2 slot 2 sorted")
    assertEq(discovered[3].x .. "," .. discovered[3].z, "25,110", "T2 slot 3 sorted")
    assertEq(discovered[4].x .. "," .. discovered[4].z, "53,110", "T2 slot 4 sorted")
    assertEq(discovered[5].x .. "," .. discovered[5].z, "25,138", "T2 slot 5 sorted")

    local grid = UI.computeSpatialGrid(discovered)
    assertEq(grid.usedSpatial, true, "T2 usedSpatial")
    assertEq(grid.cols, 2, "T2 cols")
    assertEq(grid.rows, 3, "T2 rows")
    assertEq(grid.slots[1].col .. "," .. grid.slots[1].row, "1,1", "T2 pos1")
    assertEq(grid.slots[2].col .. "," .. grid.slots[2].row, "2,1", "T2 pos2")
    assertEq(grid.slots[3].col .. "," .. grid.slots[3].row, "1,2", "T2 pos3")
    assertEq(grid.slots[4].col .. "," .. grid.slots[4].row, "2,2", "T2 pos4")
    assertEq(grid.slots[5].col .. "," .. grid.slots[5].row, "1,3", "T2 pos5")
end

-- ============================================================================
-- Helper to stand up a clean full base environment for Scheduler/UI tests
-- ============================================================================
local function setupStandardEnv(opts)
    opts = opts or {}
    component._reset()

    local fluids = {
        exciteddtcc = opts.dtcc or 500000,
        exciteddtpc = opts.dtpc or 500000,
        exciteddtrc = opts.dtrc or 500000,
        exciteddtec = opts.dtec or 500000,
        exciteddtsc = opts.dtsc or 500000,
        dimensionallytranscendentresidue = opts.dtr or 20000000,
        ["molten.spacetime"] = 5000000,
        ["molten.metastable oganesson"] = 1000000,
        ["molten.precious metals alloy"] = 1000000,
        ["molten.iron"] = 10000000,
        ["molten.neutronium"] = opts.neutronium or 1000000000,
        ["molten.shirabon"] = opts.shirabon or 100000,
        ["molten.infinity"] = 1000000000,
        water = 10000000,
        lava = 500000,
    }
    local items = {
        ["minecraft:cobblestone:0"] = 100000,
        -- Intentionally 0 GoodGenerator:huiCircuit:4 and 0 gregtech:gt.integrated_circuit!
    }
    local odFluids = opts.odFluids or {}
    local odItems = opts.odItems or {}

    component._register("net-stock-1", "me_controller", makeAENet(fluids, items))
    component._register("net-od-1", "me_interface", makeAENet(odFluids, odItems))

    local fsb, fsbSlots, fsbCalls = makeStorageBus("sb-fluid-1", 3, true)
    local isb, isbSlots, isbCalls = makeStorageBus("sb-item-1", 3, false)
    component._register("sb-fluid-1", "fluid_storagebus", fsb)
    component._register("sb-item-1", "me_storagebus", isb)

    local dtpfStates = {}
    local room = {
        { "dtpf-1", 25, 67, 82 },
        { "dtpf-2", 53, 67, 82 },
        { "dtpf-3", 25, 67, 110 },
        { "dtpf-4", 53, 67, 110 },
        { "dtpf-5", 25, 67, 138 },
    }
    for idx, rc in ipairs(room) do
        local dOpts = (idx == 1 and opts.dtpf1Opts) or {}
        local p, st = makeDTPF(rc[1], rc[2], rc[3], rc[4], dOpts)
        component._register(rc[1], "dtpf", p)
        dtpfStates[idx] = st
    end

    local cfg = Scheduler.ensureConfig({})
    Scheduler.syncHardware(cfg)
    return cfg, fluids, items, odFluids, odItems, fsbSlots, fsbCalls, isbSlots, isbCalls, dtpfStates
end

-- ============================================================================
-- TEST 3: PAUSED Read-Only Guarantee on Fresh Config
-- ============================================================================
do
    local cfg, _, _, _, _, _, fsbCalls, _, isbCalls, dtpfStates = setupStandardEnv()
    assertEq(cfg.armed, false, "T3 fresh config defaults to PAUSED")
    local st = {}
    Scheduler.step(cfg, st)
    assertEq(#fsbCalls, 0, "T3 zero fluid StorageBus writes while PAUSED")
    assertEq(#isbCalls, 0, "T3 zero item StorageBus writes while PAUSED")
    for i = 1, #dtpfStates do
        assertEq(#dtpfStates[i].calls, 0, "T3 zero DTPF writes while PAUSED #" .. i)
    end
    assert(st.channelStatus["ch1"] ~= nil and st.channelStatus["ch1"].mode ~= nil,
        "T3 preview populated while PAUSED")
    assertEq(cfg.recipes["raw_tesseract"].enabled, true, "T3 preset raw_tesseract enabled")
    assertEq(cfg.recipes["raw_tesseract"].target, 4000000, "T3 preset raw_tesseract target = 4M")
    assertEq(cfg.recipes["quantum_anomaly"].enabled, true, "T3 preset quantum_anomaly enabled")
    assertEq(cfg.recipes["quantum_anomaly"].target, 50000, "T3 preset quantum_anomaly target = 50K")
    local qaFam = require("lib.recipes_db").BY_ID["quantum_anomaly"]
    assertEq(qaFam.primaryOutput.damage, 32105, "T3 quantum_anomaly primaryOutput damage == 32105")
end

-- ============================================================================
-- TEST 4: Catalyst-Free (NONE) Convergence + Uniform NC Subnet (`molten_shirabon`)
-- ============================================================================
do
    local cfg, fluids, _, _, _, fsbSlots, _, isbSlots, _, dtpfStates = setupStandardEnv()
    for id, rc in pairs(cfg.recipes) do
        rc.enabled = (id == "molten_shirabon")
    end
    cfg.armed = true
    local st = {}
    Scheduler.step(cfg, st)

    assertEq(st.recipeStatus["molten_shirabon"].runnable, true, "T4 shirabon runnable with 0 circuits in Main Net")
    assertEq(st.channelStatus["ch1"].familyId, "molten_shirabon", "T4 ch1 assigned molten_shirabon")

    local foundDtec = false
    for _, slot in pairs(fsbSlots) do
        if slot and slot.name == "exciteddtec" then foundDtec = true end
    end
    assert(foundDtec, "T4 exciteddtec Convergence catalyst injected into fluid channel")

    for _, slot in pairs(isbSlots) do
        if slot and slot.name and slot.name:find("huiCircuit", 1, true) then
            error("T4 nonConsumed huiCircuit must NOT be pushed onto Passive bus")
        end
    end
    assertEq(cfg.channels[1].itemSentinel, "minecraft:fire", "T4 0-stock item sentinel applied for NC-only recipe")
    assertEq(dtpfStates[1].catTier, 4, "T4 DTPF setConvergenceCatalystType(4)")
    assertEq(dtpfStates[1].conv, true, "T4 DTPF setConvergenceEnabled(true)")

    -- Drop ALL catalyst stocks to 0 -> must safely fall back to 2x OC with no catalyst!
    fluids.exciteddtcc = 0
    fluids.exciteddtpc = 0
    fluids.exciteddtrc = 0
    fluids.exciteddtec = 0
    fluids.exciteddtsc = 0
    Scheduler.step(cfg, st)

    assertEq(st.recipeStatus["molten_shirabon"].runnable, true, "T4 shirabon still runnable without catalysts")
    for _, slot in pairs(fsbSlots) do
        if slot and slot.name and slot.name:sub(1, 7) == "excited" then
            error("T4 no catalyst fluid must be pushed when no catalyst meets reserve floor")
        end
    end
    assertEq(dtpfStates[1].conv, false, "T4 DTPF Convergence auto-disabled so Shirabon runs safely at 2x OC")
end

-- ============================================================================
-- TEST 5: Global DTR Reserve Floor & Catalyst Auto-Fallback
-- ============================================================================
do
    local cfg, fluids, _, _, _, fsbSlots = setupStandardEnv({ dtr = 5000000, dtec = 50000, dtrc = 500000 })
    for id, rc in pairs(cfg.recipes) do
        rc.enabled = (id == "molten_shirabon" or id == "molten_neutronium")
    end
    cfg.recipes["molten_shirabon"].priority = 1
    cfg.recipes["molten_neutronium"].priority = 2
    cfg.armed = true

    local st = {}
    Scheduler.step(cfg, st)
    assertEq(st.recipeStatus["molten_shirabon"].runnable, false, "T5 DTR 5M < 10M Floor blocks shirabon")
    assertEq(st.recipeStatus["molten_shirabon"].reason, "DTR < Floor", "T5 exact DTR floor reason")
    assertEq(st.recipeStatus["molten_neutronium"].runnable, true, "T5 neutronium DTR-producer remains runnable")
    assertEq(st.recipeStatus["molten_neutronium"].tierCode, "DTRC", "T5 DTEC below floor auto-fell back to DTRC")
    assertEq(st.channelStatus["ch1"].familyId, "molten_neutronium", "T5 ch1 switched to neutronium")
    local hasDtrc = false
    for _, slot in pairs(fsbSlots) do
        if slot and slot.name == "exciteddtrc" then hasDtrc = true end
    end
    assert(hasDtrc, "T5 ch1 fluid StorageBus configured with fallback exciteddtrc")
end

-- ============================================================================
-- TEST 5B: Layered Convergence Policy (Global Scope, Loop, Recipe Policy)
-- ============================================================================
do
    -- (a) globalConvMode = "passive_od": converges Priority Passive, keeps Forever Loop at 2x
    local cfg, fluids, items, _, _, _, _, _, _, dtpfStates = setupStandardEnv({ neutronium = 0 })
    items["Avaritia:Resource:5"] = 10000
    for _, rc in pairs(cfg.recipes) do rc.enabled = false end
    cfg.recipes["molten_neutronium"].enabled = true
    cfg.recipes["molten_neutronium"].target = 1000000000
    cfg.recipes["molten_infinity"].modifierIndex = 1 -- dust_64x (requires Infinity Catalyst only)
    cfg.fallbackEnabled = true
    cfg.fallbackFamilyId = "molten_infinity"
    cfg.globalConvMode = "passive_od"
    cfg.fallbackConvMode = "global"
    cfg.armed = true

    local st = {}
    Scheduler.step(cfg, st)
    assertEq(st.channelStatus["ch1"].mode, "PASSIVE", "T5B passive_od runs PASSIVE when neutronium < target")
    assertEq(st.channelStatus["ch1"].familyId, "molten_neutronium", "T5B passive_od selected molten_neutronium")
    assertEq(dtpfStates[1].conv, true, "T5B passive_od converges Priority Passive at 50% discount")

    -- Satisfy neutronium target so scheduler transitions to Forever Loop (molten_infinity)
    fluids["molten.neutronium"] = 2000000000
    Scheduler.step(cfg, st)
    assertEq(st.channelStatus["ch1"].mode, "FALLBACK", "T5B falls back to Forever Loop once targets met")
    assertEq(st.channelStatus["ch1"].familyId, "molten_infinity", "T5B Forever Loop running molten_infinity")
    assertEq(dtpfStates[1].conv, false, "T5B passive_od keeps Forever Loop at 2x")

    -- Forever Loop explicit override (fallbackConvMode = "on") overrides passive_od
    cfg.fallbackConvMode = "on"
    Scheduler.step(cfg, st)
    assertEq(dtpfStates[1].conv, true, "T5B fallbackConvMode=on converges Forever Loop even under passive_od")

    -- (b) Per-recipe convMode = "off" overrides globalConvMode = "auto", and "force" overrides low discount
    local cfg2, _, _, _, _, fsbSlots2, _, _, _, dtpfStates2 = setupStandardEnv({
        shirabon = 0,
        dtpf1Opts = { discountPct = 50 },
    })
    for id, rc in pairs(cfg2.recipes) do rc.enabled = (id == "molten_shirabon") end
    cfg2.recipes["molten_shirabon"].target = 100000000
    cfg2.recipes["molten_shirabon"].convMode = "off"
    cfg2.globalConvMode = "auto"
    cfg2.armed = true

    local st2 = {}
    Scheduler.step(cfg2, st2)
    assertEq(st2.channelStatus["ch1"].familyId, "molten_shirabon", "T5B shirabon scheduled")
    assertEq(dtpfStates2[1].conv, false, "T5B recipe convMode=off forces catalyst-free 2x under global auto")
    for _, slot in pairs(fsbSlots2) do
        if slot and slot.name and slot.name:sub(1, 7) == "excited" then
            error("T5B recipe convMode=off must not inject excited catalyst fluid")
        end
    end

    -- Test "force" even at 0% discount
    dtpfStates2[1].discountPct = 0
    cfg2.recipes["molten_shirabon"].convMode = "force"
    Scheduler.step(cfg2, st2)
    assertEq(dtpfStates2[1].conv, true, "T5B recipe convMode=force converges even below 50% discount")
    local pushedDtec = false
    for _, slot in pairs(fsbSlots2) do
        if slot and slot.name == "exciteddtec" then pushedDtec = true end
    end
    assert(pushedDtec, "T5B recipe convMode=force injects exciteddtec catalyst")
end

-- ============================================================================
-- TEST 6: StorageBus Shadowing Warning, 0-Stock Sentinels & On-Demand auto_safe
-- ============================================================================
do
    -- Shadowing warning + AE2FC ME Dual Interface (`fluid_interface`) discovery check
    component._reset()
    local fsbOnly = makeStorageBus("sb-f-only", 3, true)
    component._register("sb-f-only", "fluid_storagebus", fsbOnly)
    component._register("dual-if-1", "fluid_interface", makeAENet({ water = 5000 }, { ["minecraft:cobblestone:0"] = 128 }))
    -- Hypothetical proxy lacking NetworkControl must be skipped safely without crashing
    component._register("fluid-only-1", "fluid_interface", { getFluidInterfaceConfiguration = function() return nil end })
    local ep = Hardware.discoverPassiveEndpoints()
    assert(#ep.warnings >= 1, "T6 emits StorageBus shadowing warning when count mismatches")
    local aeNets = Hardware.discoverAENetworks()
    assertEq(#aeNets, 1, "T6 discovers adapted ME Dual Interface (`fluid_interface`) with NetworkControl and skips non-network proxy")
    assertEq(aeNets[1].address, "dual-if-1", "T6 exact address of discovered ME Dual Interface")

    -- Filtered-stock-subnet sanity warning: stockNetAddr pointed at <=6-type subnet while Main Net has >=15 types
    local warnCfg = setupStandardEnv({ odFluids = { water = 1000 } })
    warnCfg.stockNetAddr = "net-od-1"
    local _, warnEp = Scheduler.syncHardware(warnCfg)
    local foundSubnetWarn = false
    for _, w in ipairs(warnEp.warnings or {}) do
        if w:find("<=6 items/fluids", 1, true) then
            foundSubnetWarn = true
            break
        end
    end
    assert(foundSubnetWarn, "T6 warns when Stock AE2 Interface points at <=6-type filtered subnet")

    -- On-Demand auto_safe check (no catalyst in Color 1 -> clears channel & disables OD convergence)
    local cfg, _, _, odFluids, odItems, fsbSlots, _, isbSlots, _, dtpfStates = setupStandardEnv({
        odFluids = { ["molten.copper"] = 73728 },
    })
    cfg.fallbackEnabled = false
    for _, rc in pairs(cfg.recipes) do rc.enabled = false end
    cfg.armed = true
    local st = {}
    Scheduler.step(cfg, st)
    assertEq(st.onDemand.hasWork, true, "T6 OD detected copper")
    assertEq(st.onDemand.hasPatternedCatalyst, false, "T6 OD has no patterned catalyst")
    assertEq(st.channelStatus["ch1"].mode, "ON-DEMAND", "T6 ch1 preempted for OD")
    assertEq(cfg.channels[1].fluidSentinel, "ic2pahoehoelava", "T6 picked 0-stock fluid sentinel (not water/lava)")
    assertEq(cfg.channels[1].itemSentinel, "minecraft:fire", "T6 picked 0-stock item sentinel (not cobblestone)")
    assertEq(dtpfStates[1].conv, false, "T6 OD auto_safe keeps convergence OFF when Color 1 lacks catalyst")

    -- Add patterned catalyst into Color 1 -> auto_safe turns Convergence ON!
    odFluids.exciteddtec = 10000
    Scheduler.step(cfg, st)
    assertEq(st.onDemand.hasPatternedCatalyst, true, "T6 OD detects patterned catalyst")
    assertEq(dtpfStates[1].conv, true, "T6 OD auto_safe turns convergence ON when Color 1 has catalyst")
end

-- ============================================================================
-- TEST 7: Cover Conflict Detection across 2 Armed Steps
-- ============================================================================
do
    local cfg, _, _, _, _, _, _, _, _, dtpfStates = setupStandardEnv({
        dtpf1Opts = { workAllowed = false, coverBlocksWork = true },
    })
    cfg.armed = true
    local st = {}
    Scheduler.step(cfg, st)
    assertEq(st.dtpfStatus[1].coverConflict, false, "T7 step 1 attempts setWorkAllowed first")
    Scheduler.step(cfg, st)
    assertEq(st.dtpfStatus[1].coverConflict, true, "T7 step 2 detects persistent Machine Controller Cover override")
end

-- ============================================================================
-- TEST 8: Full 160x50 Render Across 3 Views, Width-1 Glyphs, Touch Clicks, Save & --check
-- ============================================================================
do
    local gpu = component._newMockGPU(160, 50)
    local cfg = setupStandardEnv()
    for id, rc in pairs(cfg.recipes) do
        rc.enabled = (id == "molten_neutronium" or id == "molten_shirabon" or id == "molten_hypogen")
    end
    local st = {}
    Scheduler.step(cfg, st)

    local savedRaw = nil
    local ui = UI.new(cfg, st, function(c)
        savedRaw = serialization.serialize({
            armed = (c.armed == true),
            globalConvMode = c.globalConvMode,
            defaultCatalystTier = c.defaultCatalystTier,
            dtpfs = { { address = c.dtpfs[1].address, name = c.dtpfs[1].name, convOverride = c.dtpfs[1].convOverride } },
            recipes = c.recipes,
        })
    end)

    for view = 1, 4 do
        ui.tab = view
        ui:render()
    end
    ui.tab = 2
    ui:render()
    local screen1 = gpu._rowText(1) .. "\n" .. gpu._allText()
    assert(screen1:find("PAUSED", 1, true), "T8 Control Center displays PAUSED banner")
    assert(screen1:find("DTPF #1", 1, true) and screen1:find("(25,82)", 1, true) and screen1:find("Empty Grid (53,138)", 1, true),
        "T8 spatial grid renders DTPF #1 (25,82) and Empty Grid (53,138)")
    assert(screen1:find("╭≡─▄─≡╮", 1, true) and screen1:find("╰═─■─═╯", 1, true),
        "T8 renders miniature 7x4 DTPF multiblock coil icon on Control Center cards")
    assert(screen1:find("GLOBAL SETTINGS", 1, true), "T8 displays Global Settings panel")

    -- Click a hitbox helper (optionally constrained to xMin..xMax, yMin..yMax, and mouse button)
    local function clickButtonText(needle, xMin, xMax, yMin, yMax, button)
        for i = #ui.hitboxes, 1, -1 do
            local hb = ui.hitboxes[i]
            if hb.y1 == hb.y2
                and (not xMin or hb.x1 >= xMin) and (not xMax or hb.x2 <= xMax)
                and (not yMin or hb.y1 >= yMin) and (not yMax or hb.y2 <= yMax) then
                local row = gpu._rowText(hb.y1)
                local slice = unicode.sub(row, hb.x1, hb.x2)
                if slice:find(needle, 1, true) then
                    ui:handleTouch(hb.x1, hb.y1, button)
                    ui:render()
                    return true
                end
            end
        end
        return false
    end

    assert(clickButtonText("PAUSED"), "T8 clicked PAUSED -> ARMED button")
    assertEq(cfg.armed, true, "T8 armed toggled ON and persisted")
    assert(savedRaw ~= nil, "T8 auto-save callback fired on click")

    -- Click Right-Pane Global Convergence cycle pill + Global Catalyst cycle pill
    assert(clickButtonText("[⚡Auto @50%]", 84, 158, 6, 6), "T8 clicked Global Convergence [⚡Auto @50%] pill")
    assertEq(cfg.globalConvMode, "always", "T8 globalConvMode -> always")
    assert(clickButtonText("[⚡Always ON]", 84, 158, 6, 6), "T8 clicked Global Convergence [⚡Always ON] pill")
    assertEq(cfg.globalConvMode, "off", "T8 globalConvMode -> off")
    assert(clickButtonText("[◇OFF]", 84, 158, 6, 6), "T8 clicked Global Convergence [◇OFF] pill back to auto")
    assertEq(cfg.globalConvMode, "auto", "T8 globalConvMode -> auto")
    assert(clickButtonText("[DTEC]", 134, 158, 6, 6), "T8 clicked Global Catalyst [DTEC] cycle pill")
    assertEq(cfg.defaultCatalystTier, 5, "T8 defaultCatalystTier stepped 4 -> 5")
    assert(clickButtonText("[DTSC]", 134, 158, 6, 6, 1), "T8 R-clicked Global Catalyst [DTSC] back to 4")
    assertEq(cfg.defaultCatalystTier, 4, "T8 defaultCatalystTier restored -> 4")

    -- Direct on-card DTPF #1 Conv pill left-click (forward) and right-click (backward)
    Scheduler.step(cfg, st)
    ui:render()
    assert(clickButtonText("[Auto]", 2, 20, 13, 13), "T8 left-clicked DTPF #1 direct Conv pill on card")
    assertEq(cfg.dtpfs[1].convOverride, "auto", "T8 DTPF #1 convOverride stepped forward to auto")
    assert(clickButtonText("[⚡50%]", 2, 20, 13, 13, 1), "T8 right-clicked DTPF #1 Conv pill")
    assertEq(cfg.dtpfs[1].convOverride, "global", "T8 right-click stepped DTPF #1 convOverride back to global")
    assert(clickButtonText("[Auto]", 2, 20, 13, 13, 1), "T8 right-clicked DTPF #1 Conv pill from global")
    assertEq(cfg.dtpfs[1].convOverride, "off", "T8 right-click wrapped DTPF #1 convOverride to off")

    -- Re-run Scheduler.step and verify [↺] appears directly on DTPF #1's card, then reset it
    Scheduler.step(cfg, st)
    ui:render()
    assert(clickButtonText("[↺]", 2, 39, 12, 12), "T8 clicked direct on-card [↺] on DTPF #1")
    assertEq(cfg.dtpfs[1].convOverride, "global", "T8 DTPF #1 reset back to global")

    -- Confirm 7x4 coil sprite has NO hidden hitbox, then test header [Reset All] via Conv pill
    ui:handleTouch(6, 8, 0)
    ui:render()
    assertEq(cfg.dtpfs[1].convOverride, "global", "T8 clicking DTPF #1 coil sprite does not mutate hidden state")
    assert(clickButtonText("[Auto]", 2, 20, 13, 13), "T8 set DTPF #1 convOverride via Conv pill")
    assert(cfg.dtpfs[1].convOverride ~= "global", "T8 DTPF #1 convOverride changed")
    assert(clickButtonText("[Reset All]", 2, 60, 4, 4), "T8 clicked header [Reset All] button")
    assertEq(cfg.dtpfs[1].convOverride, "global", "T8 [Reset All] restored DTPF #1 convOverride to global")

    -- Test Priority Queue: per-recipe CONV [Auto], [<Tgt] <-> [24/7] toggle, [Target] click, OD Conv, On AE2 Craft, Queue Split, [All:27]
    assert(clickButtonText("[Auto]", 117, 123, 12, 47), "T8 clicked inline Priority Queue per-recipe CONV [Auto] toggle")
    local anyRecConvSet = false
    for _, rc in pairs(cfg.recipes) do
        if rc.convMode == "on" then anyRecConvSet = true break end
    end
    assertEq(anyRecConvSet, true, "T8 inline [Auto] cycled recipe convMode -> on")
    assert(clickButtonText("[⚡50%]", 117, 123, 12, 47, 1), "T8 right-clicked [⚡50%] back to [Auto]")

    assert(clickButtonText("[<Tgt]", 123, 130, 12, 47), "T8 clicked inline [<Tgt] -> [24/7] toggle")
    local anyForever = false
    for _, rc in pairs(cfg.recipes) do
        if rc.forever then anyForever = true break end
    end
    assertEq(anyForever, true, "T8 inline [<Tgt] enabled 24/7 loop on recipe")
    assert(clickButtonText("[24/7]", 123, 130, 12, 47), "T8 clicked [24/7] back to [<Tgt]")

    assert(clickButtonText("[", 138, 146, 12, 47), "T8 clicked explicit bracketed [Target] chip in Priority Queue")
    assertEq(ui.promptActive, true, "T8 [Target] chip opened target modal")
    assertEq(ui.promptIsNumeric, true, "T8 [Target] chip opened numeric picker")
    assert(clickButtonText("[ CANCEL ]"), "T8 closed [Target] picker via [ CANCEL ]")
    assertEq(ui.promptActive, false, "T8 [Target] picker closed cleanly")

    assert(clickButtonText("[⚡Auto-Safe]", 115, 140, 6, 6), "T8 clicked Global OD Conv [⚡Auto-Safe] pill")
    assertEq(cfg.onDemandConvMode, "on", "T8 onDemandConvMode stepped -> on")
    assert(clickButtonText("[⚡Always ON]", 115, 140, 6, 6, 1), "T8 right-clicked [⚡Always ON] back to auto_safe")
    assertEq(cfg.onDemandConvMode, "auto_safe", "T8 onDemandConvMode restored -> auto_safe")

    assert(clickButtonText("[Pause Queue]", 95, 115, 7, 7), "T8 clicked On AE2 Craft [Pause Queue] toggle")
    assertEq(cfg.pausePassivesOnOD, false, "T8 pausePassivesOnOD -> false")
    assert(clickButtonText("[Keep Queue ]", 95, 115, 7, 7), "T8 restored [Pause Queue]")
    assertEq(cfg.pausePassivesOnOD, true, "T8 pausePassivesOnOD -> true")

    assert(clickButtonText("[1 DTPF / Recipe]", 120, 158, 7, 7), "T8 clicked Queue Split [1 DTPF / Recipe] toggle")
    assertEq(cfg.allowParallelSameRecipe, true, "T8 allowParallelSameRecipe -> true")
    assert(clickButtonText("[Parallel DTPFs]", 120, 158, 7, 7), "T8 restored [1 DTPF / Recipe]")
    assertEq(cfg.allowParallelSameRecipe, false, "T8 allowParallelSameRecipe -> false")

    assert(clickButtonText("[All:", 81, 160, 10, 10), "T8 toggled Priority Queue [All:...] filter")
    assertEq(ui.queueShowAll, true, "T8 queueShowAll toggled true")
    assert(clickButtonText("[Enabled:", 81, 160, 10, 10), "T8 toggled back to [Enabled:...]")
    assertEq(ui.queueShowAll, false, "T8 queueShowAll restored false")

    -- Direct on-card power toggle [● ON ] -> [○ OFF] -> [● ON ]
    assert(clickButtonText("[● ON ]", 2, 39, 6, 6), "T8 clicked DTPF #1 on-card [● ON ] toggle")
    assertEq(cfg.dtpfs[1].enabled, false, "T8 DTPF #1 enabled toggled OFF")
    assert(clickButtonText("[○ OFF]", 2, 39, 6, 6), "T8 clicked DTPF #1 on-card [○ OFF] toggle")
    assertEq(cfg.dtpfs[1].enabled, true, "T8 DTPF #1 enabled restored ON")

    -- Priority swap test: move molten_shirabon (2nd+ enabled) up in priority
    local origNeutPrio = cfg.recipes["molten_neutronium"].priority
    local origShirPrio = cfg.recipes["molten_shirabon"].priority
    Scheduler.moveRecipePriority(cfg, "molten_shirabon", -1, true)
    assert(cfg.recipes["molten_shirabon"].priority < origShirPrio, "T8 priority moved up cleanly")
    Scheduler.moveRecipePriority(cfg, "molten_shirabon", 1, true)
    assertEq(cfg.recipes["molten_neutronium"].priority, origNeutPrio, "T8 priority restored cleanly")

    -- Direct on-card Rename chip [DTPF #1…] + touch [ APPLY ] button test
    assert(clickButtonText("DTPF #1", 2, 39, 5, 5), "T8 clicked [DTPF #1…] top border chip to open Rename prompt")
    assertEq(ui.promptActive, true, "T8 rename prompt active")
    ui.promptBuffer = "Forge North"
    ui:render() -- populates modal-only hitboxes ([ CLEAR ], [ APPLY ], [ CANCEL ])
    assert(clickButtonText("[ APPLY ]"), "T8 clicked touch [ APPLY ] in Rename modal")
    assertEq(ui.promptActive, false, "T8 rename prompt closed after [ APPLY ]")
    assertEq(cfg.dtpfs[1].name, "Forge North", "T8 DTPF #1 renamed")

    -- Verify round-trip via OpenOS serialization
    local decoded = serialization.unserialize(savedRaw)
    assertEq(decoded.armed, true, "T8 saved config armed round-trips cleanly")

    -- Render Views 3 (Recipes) & 4 (Setup), test multi-modifier radio selector (molten_infinity) + Raw Tesseract unified tier selector + Shirabon
    ui.selectedFamilyId = "molten_infinity"
    ui.tab = 3
    ui:render()
    assert(gpu._allText():find("RECIPE INSPECTOR", 1, true), "T8 View 2 displays Recipe Inspector")
    assert(gpu._allText():find("RECIPE VARIANT", 1, true), "T8 View 2 displays prominent RECIPE VARIANT radio selector")
    assert(clickButtonText("[ ] 2.", 85, 159, 12, 22), "T8 clicked radio [ ] 2. variant on Molten Infinity")
    assertEq(cfg.recipes["molten_infinity"].modifierIndex, 2, "T8 Molten Infinity modifierIndex -> 2")
    assert(clickButtonText("[ ] 1.", 85, 159, 12, 22), "T8 clicked radio [ ] 1. variant on Molten Infinity")
    assertEq(cfg.recipes["molten_infinity"].modifierIndex, 1, "T8 Molten Infinity modifierIndex -> 1")

    ui.selectedFamilyId = "raw_tesseract"
    ui:render()
    assert(gpu._allText():find("RECIPE VARIANT BY TIER", 1, true), "T8 Raw Tesseract shows RECIPE VARIANT BY TIER radio selector")
    assert(not gpu._allText():find("[Default (DTEC)]", 1, true), "T8 Raw Tesseract omits duplicate Catalyst Tier selector when unified in RECIPE VARIANT BY TIER")
    assert(gpu._allText():find("Resolved Tier Catalyst:", 1, true), "T8 Raw Tesseract shows single Resolved Tier Catalyst summary")
    assert(clickButtonText("[ ] DTSC", 85, 159, 12, 24), "T8 selected DTSC tier variant on Raw Tesseract")
    assertEq(cfg.recipes["raw_tesseract"].catalystTier, 5, "T8 Raw Tesseract catalystTier -> DTSC (5)")
    assert(clickButtonText("[ ] Auto", 85, 159, 12, 24), "T8 restored Raw Tesseract catalystTier -> Auto (0)")
    assertEq(cfg.recipes["raw_tesseract"].catalystTier, 0, "T8 Raw Tesseract catalystTier -> Auto (0)")

    ui.selectedFamilyId = "molten_shirabon"
    ui:render()
    assert(gpu._allText():find("Convergence:", 1, true), "T8 View 2 displays Recipe Convergence")
    assert(clickButtonText("[⚡Always ON]"), "T8 clicked [⚡Always ON] recipe convergence override for Shirabon")
    assertEq(cfg.recipes["molten_shirabon"].convMode, "force", "T8 Shirabon convMode -> force")
    assert(clickButtonText("[Default (Auto)]"), "T8 restored Shirabon convMode -> global")
    assertEq(cfg.recipes["molten_shirabon"].convMode, "global", "T8 Shirabon convMode -> global")
    assert(gpu._allText():find("Conv Cat:", 1, true), "T8 Shirabon displays Conv Cat selector")
    assert(clickButtonText("[DTPC]"), "T8 clicked [DTPC] catalyst override for Shirabon")
    assertEq(cfg.recipes["molten_shirabon"].catalystTier, 2, "T8 Shirabon catalystTier -> DTPC (2)")

    -- Verify Tab 2 Up/Down arrow key navigation moves selection along filtered list (Shirabon is last entry)
    local beforeSel = ui.selectedFamilyId
    ui:handleKeyDown(0, 200) -- Up arrow
    ui:render()
    assert(ui.selectedFamilyId ~= beforeSel, "T8 View 2 Up arrow moved selected recipe")
    ui:handleKeyDown(0, 208) -- Down arrow back
    ui:render()
    assertEq(ui.selectedFamilyId, beforeSel, "T8 View 2 Down arrow returned to previous recipe")

    ui.tab = 4
    ui:render()
    assert(gpu._allText():find("RESERVE FLOORS & POLICY", 1, true), "T8 View 4 displays RESERVE FLOORS & POLICY card")
    assert(gpu._allText():find("SUBNETS & BRIDGE", 1, true), "T8 View 4 displays SUBNETS & BRIDGE card")

    -- Stress-check Control Center card geometry for 9 DTPFs (3x3) and 16 DTPFs (4x4, boxH=10, boxW=18)
    for _, count in ipairs({ 9, 16 }) do
        component._reset()
        local manyCfg = Scheduler.ensureConfig({})
        local manySt = { dtpfStatus = {}, recipeStatus = {}, channelStatus = {}, onDemand = {}, stock = { fluids = {}, items = {} } }
        local side = (count == 9) and 3 or 4
        for idx = 1, count do
            local r = math.floor((idx - 1) / side) + 1
            local c = ((idx - 1) % side) + 1
            local addr = string.format("many-%02d", idx)
            local p = makeDTPF(addr, c * 20, 67, r * 20)
            component._register(addr, "dtpf", p)
            manySt.dtpfStatus[idx] = { online = true, active = true, progress = 100, maxProgress = 200, discountPct = 50, coilHeat = 13500, jobMode = "PASSIVE", jobLabel = "Molten Neutronium" }
        end
        local manyUI = UI.new(manyCfg, manySt)
        assertEq(#manyCfg.dtpfs, count, "T8 stress test discovered all " .. count .. " DTPFs")
        manyUI.tab = 2
        manyUI:render()
        assert(gpu._allText():find("DTPF #" .. count, 1, true), "T8 stress test rendered DTPF #" .. count)
    end

    -- Export all rendered GPU strings so Python checks exact font.hex glyph widths!
    _G.__RENDERED_GPU_CALLS = gpu._calls
end

-- ============================================================================
-- TEST 9: 12-DTPF Scalability, 1:1 Multi-Channel Auto-Pairing, Pinned Passives & Modal
-- ============================================================================
do
    component._reset()
    local fluids = {
        exciteddtcc = 500000, exciteddtpc = 500000, exciteddtrc = 500000, exciteddtec = 500000, exciteddtsc = 500000,
        dimensionallytranscendentresidue = 20000000,
        ["molten.spacetime"] = 5000000,
        ["molten.metastable oganesson"] = 1000000,
        ["molten.precious metals alloy"] = 1000000,
        ["molten.iron"] = 10000000,
        ["molten.steel"] = 10000000,
        ["molten.copper"] = 10000000,
        ["molten.neutronium"] = 0,
        ["molten.cosmic neutronium"] = 0,
        ["molten.bedrockium"] = 0,
        ["molten.shirabon"] = 0,
        ["molten.infinity"] = 100000000000, -- 100B > 50B default target
        water = 10000000, lava = 500000,
    }
    local items = {
        ["Avaritia:Resource:5"] = 10000,
        ["minecraft:cobblestone:0"] = 100000,
    }
    local odFluids, odItems = {}, {}
    component._register("t9-stock", "me_controller", makeAENet(fluids, items))
    component._register("t9-od", "me_interface", makeAENet(odFluids, odItems))

    local fsbSlots, isbSlots, dtpfStates = {}, {}, {}
    for i = 1, 12 do
        local fsb, fs = makeStorageBus(string.format("t9-fsb-%02d", i), 3, true)
        local isb, is = makeStorageBus(string.format("t9-isb-%02d", i), 3, false)
        component._register(string.format("t9-fsb-%02d", i), "fluid_storagebus", fsb)
        component._register(string.format("t9-isb-%02d", i), "me_storagebus", isb)
        fsbSlots[i], isbSlots[i] = fs, is

        local row = math.floor((i - 1) / 2) + 1
        local col = ((i - 1) % 2) + 1
        local x = (col == 1) and 25 or 53
        local z = 82 + (row - 1) * 28
        local p, st = makeDTPF(string.format("t9-dtpf-%02d", i), x, 67, z)
        component._register(string.format("t9-dtpf-%02d", i), "dtpf", p)
        dtpfStates[i] = st
    end

    local cfg = Scheduler.ensureConfig({})
    Scheduler.syncHardware(cfg)
    assertEq(#cfg.channels, 12, "T9 auto-created 12 passive channels for 12 StorageBus pairs")
    assertEq(#cfg.dtpfs, 12, "T9 discovered all 12 DTPFs")
    for i = 1, 12 do
        assertEq(cfg.dtpfs[i].channelId, "ch" .. i, "T9 auto-paired DTPF #" .. i .. " -> ch" .. i)
    end

    for id, rc in pairs(cfg.recipes) do
        rc.enabled = (id == "molten_neutronium" or id == "molten_cosmic_neutronium" or id == "molten_bedrockium" or id == "molten_shirabon")
    end
    cfg.recipes["molten_cosmic_neutronium"].modifierIndex = 1 -- standard Molten Copper variant
    cfg.recipes["molten_infinity"].modifierIndex = 1 -- dust_64x
    cfg.dtpfs[1].roleOverride = "pinned"
    cfg.dtpfs[1].pinnedFamilyId = "molten_shirabon"
    cfg.dtpfs[2].roleOverride = "pinned_loop"
    cfg.dtpfs[2].pinnedFamilyId = "molten_infinity"
    cfg.dtpfs[3].roleOverride = "od_only"
    cfg.armed = true

    local st = {}
    Scheduler.step(cfg, st)
    assertEq(st.channelStatus["ch1"].familyId, "molten_shirabon", "T9 ch1 running pinned molten_shirabon")
    assertEq(st.channelStatus["ch1"].pinned, true, "T9 ch1 marked pinned")
    assertEq(st.channelStatus["ch2"].familyId, "molten_infinity", "T9 ch2 running pinned_loop molten_infinity even above target")
    assertEq(st.channelStatus["ch2"].mode, "FALLBACK", "T9 ch2 pinned_loop mode is FALLBACK")
    assertEq(dtpfStates[2].workAllowed, true, "T9 DTPF #2 enabled for 24/7 loop")
    assertEq(st.channelStatus["ch3"].mode, "IDLE", "T9 ch3 od_only idle while OD empty")
    assertEq(dtpfStates[3].workAllowed, false, "T9 DTPF #3 work disabled while od_only waits for OD")
    assertEq(st.channelStatus["ch4"].familyId, "molten_neutronium", "T9 ch4 auto took #1 queue recipe")
    assertEq(st.channelStatus["ch5"].familyId, "molten_cosmic_neutronium", "T9 ch5 auto took #2 queue recipe")
    assertEq(st.channelStatus["ch6"].familyId, "molten_bedrockium", "T9 ch6 auto took #3 queue recipe")
    for k = 4, 12 do
        assert(st.channelStatus["ch" .. k].familyId ~= "molten_shirabon", "T9 AUTO ch" .. k .. " must not steal pinned shirabon from ch1")
    end

    -- When OD craft enters Color 1, od_only DTPF #3 wakes up automatically!
    odFluids["molten.copper"] = 73728
    Scheduler.step(cfg, st)
    assertEq(dtpfStates[3].workAllowed, true, "T9 DTPF #3 wakes up when OD work arrives")
    assertEq(st.dtpfStatus[3].jobMode, "ON-DEMAND", "T9 DTPF #3 switches to ON-DEMAND mode")
    odFluids["molten.copper"] = nil
    Scheduler.step(cfg, st)
    assertEq(dtpfStates[3].workAllowed, false, "T9 DTPF #3 returns to sleep after OD finishes")

    -- Render UI across 12 DTPFs: paging, [Compact], Passive Modal, Tab 3 1:1 pairing & glyph audit
    local gpu = component._newMockGPU(160, 50)
    local ui = UI.new(cfg, st)
    local function clickT9(needle, xMin, xMax, yMin, yMax)
        for i = #ui.hitboxes, 1, -1 do
            local hb = ui.hitboxes[i]
            if hb.y1 == hb.y2
                and (not xMin or hb.x1 >= xMin) and (not xMax or hb.x2 <= xMax)
                and (not yMin or hb.y1 >= yMin) and (not yMax or hb.y2 <= yMax) then
                local row = gpu._rowText(hb.y1)
                if unicode.sub(row, hb.x1, hb.x2):find(needle, 1, true) then
                    ui:handleTouch(hb.x1, hb.y1)
                    ui:render()
                    return true
                end
            end
        end
        return false
    end

    ui.tab = 2
    ui:render()
    local page1Txt = gpu._allText()
    assert(not page1Txt:find("[CH1]", 1, true), "T9 Card #1 hides redundant [CH1] channel badge on 1:1 channels")
    assert(page1Txt:find("◆ Molten Shirabon", 1, true), "T9 Card #1 shows pinned recipe on Mode pill")
    assert(clickT9("[▼ Next]", 2, 78, 48, 48), "T9 clicked [▼ Next] row paging button")
    assert(gpu._allText():find("DTPF #12", 1, true), "T9 paged down to DTPF #12")

    assert(clickT9("[Compact]", 2, 78, 4, 4), "T9 switched to [Compact] 14-DTPF view")
    local compactTxt = gpu._allText()
    assert(compactTxt:find("DTPF #1", 1, true) and compactTxt:find("DTPF #12", 1, true),
        "T9 Compact view displays DTPF #1 and DTPF #12 simultaneously")
    assert(clickT9("[Cards  ]", 2, 78, 4, 4), "T9 switched back to [Cards  ] view")
    assert(clickT9("[▲ Prev]", 2, 78, 48, 48), "T9 paged back up to Row 1")

    -- Open Passive Assignment Modal from DTPF #1 card & verify quick mode + recipe pin
    assert(clickT9("◆ Molten Shirabon", 2, 39, 12, 12), "T9 clicked Mode pill on DTPF #1")
    assertEq(ui.passiveModalActive, true, "T9 Passive Assignment Modal opened")
    assert(gpu._allText():find("PASSIVE ASSIGNMENT:", 1, true), "T9 Modal renders title")
    assert(clickT9("[ FOREVER LOOP ]"), "T9 Modal clicked Quick Mode [ FOREVER LOOP ]")
    assertEq(ui.passiveModalActive, false, "T9 Modal closed on quick mode selection")
    assertEq(cfg.dtpfs[1].roleOverride, "fallback_only", "T9 DTPF #1 set to fallback_only")
    assertEq(cfg.dtpfs[1].pinnedFamilyId, nil, "T9 DTPF #1 cleared pinnedFamilyId")

    ui:openPassiveModal(1)
    ui:render()
    assert(clickT9("[◆ Pin <Target]"), "T9 Modal clicked recipe [◆ Pin <Target]")
    assertEq(ui.passiveModalActive, false, "T9 Modal closed after recipe pin")
    assertEq(cfg.dtpfs[1].roleOverride, "pinned", "T9 DTPF #1 roleOverride -> pinned")
    assert(cfg.dtpfs[1].pinnedFamilyId ~= nil, "T9 DTPF #1 pinnedFamilyId populated")

    ui.tab = 4
    ui:render()
    local tab3Txt = gpu._allText()
    assert(tab3Txt:find("PASSIVE CHANNELS (12)", 1, true), "T9 Tab 4 displays 12 channels")
    assert(tab3Txt:find("DISCOVERED DTPF CONTROLLERS (12)", 1, true), "T9 Tab 4 displays 12 DTPFs")
    assert(clickT9("1:1 PAIR DTPFS"), "T9 Tab 4 clicked 1:1 PAIR DTPFS big button")

    for _, s in ipairs(gpu._calls) do
        _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s
    end
end

-- ============================================================================
-- TEST 10: Zero-Subnet Direct Wireless MFU (me_inputhatch + me_inputbus) + 3D Nearest Pairing
-- ============================================================================
do
    local function makeStockingEndpoint(x, y, z)
        local state = { autoPull = true, slots = {}, calls = {} }
        local proxy = {
            getCoordinates = function() return x, y, z end,
            getSlotSize = function() return 16 end,
            getAutoPull = function() return state.autoPull end,
            setAutoPull = function(v)
                state.autoPull = v
                state.calls[#state.calls + 1] = { "setAutoPull", v }
                return true
            end,
            getConfiguration = function(slot)
                return state.slots[slot]
            end,
            setConfiguration = function(slot, detail)
                state.slots[slot] = detail
                state.calls[#state.calls + 1] = { "setConfiguration", slot, detail }
                return true
            end,
        }
        return proxy, state
    end

    component._reset()
    local fluids = {
        exciteddtcc = 500000, exciteddtpc = 500000, exciteddtrc = 500000, exciteddtec = 500000, exciteddtsc = 500000,
        dimensionallytranscendentresidue = 20000000,
        ["molten.iron"] = 10000000,
        ["molten.copper"] = 10000000,
        ["molten.steel"] = 10000000,
        ["molten.neutronium"] = 0,
        ["molten.infinity"] = 0,
    }
    local items = { ["Avaritia:Resource:5"] = 10000, ["minecraft:cobblestone:0"] = 100000 }
    component._register("t10-stock", "me_controller", makeAENet(fluids, items))
    component._register("t10-od", "me_interface", makeAENet({}, {}))

    local room = {
        { 25, 67, 82, "zzzz-01" },
        { 53, 67, 82, "mmmm-02" },
        { 25, 67, 110, "yyyy-03" },
        { 53, 67, 110, "bbbb-04" },
        { 25, 67, 138, "aaaa-05" },
    }
    local dtpfStates, hatchStates, busStates = {}, {}, {}
    local expectedH, expectedB = {}, {}
    for i, rc in ipairs(room) do
        local p, ds = makeDTPF("dtpf-" .. i, rc[1], rc[2], rc[3])
        component._register("dtpf-" .. i, "dtpf", p)
        dtpfStates[i] = ds
    end

    -- First test placeholder conversion: syncHardware before hatches/buses -> 1 empty storage_bus placeholder,
    -- then add scrambled-UUID hatches+buses and resync -> converts to 5 nearest-3D hatch_pair channels!
    local cfg = Scheduler.ensureConfig({})
    Scheduler.syncHardware(cfg)
    assertEq(#cfg.channels, 1, "T10 placeholder channel created before endpoints added")
    assertEq(cfg.channels[1].mode, "storage_bus", "T10 initial placeholder is storage_bus")

    for i, rc in ipairs(room) do
        local hAddr = rc[4] .. "-hatch"
        local bAddr = rc[4] .. "-bus"
        expectedH[i], expectedB[i] = hAddr, bAddr
        local hp, hs = makeStockingEndpoint(rc[1] + 2, rc[2] - 1, rc[3] + 1)
        local bp, bs = makeStockingEndpoint(rc[1] - 2, rc[2] - 1, rc[3] + 1)
        component._register(hAddr, "me_inputhatch", hp)
        component._register(bAddr, "me_inputbus", bp)
        hatchStates[i], busStates[i] = hs, bs
    end

    Scheduler.syncHardware(cfg)
    assertEq(#cfg.channels, 5, "T10 auto-converted placeholder and created 5 hatch_pair channels")
    for i = 1, 5 do
        assertEq(cfg.channels[i].mode, "hatch_pair", "T10 ch" .. i .. " mode -> hatch_pair")
        assertEq(cfg.channels[i].hatchAddr, expectedH[i], "T10 ch" .. i .. " paired nearest hatch despite scrambled UUIDs")
        assertEq(cfg.channels[i].busAddr, expectedB[i], "T10 ch" .. i .. " paired nearest bus despite scrambled UUIDs")
    end

    -- Verify discoverPassiveEndpoints warns while any Hatch/Bus has autoPull=ON,
    -- and clicking [ LOCK AUTOPULL OFF ] on Tab 3 clears all 10 endpoints + warning before arming
    local epBefore = Hardware.discoverPassiveEndpoints()
    assertEq(epBefore.autoPullOnCount, 10, "T10 discoverPassiveEndpoints detects 10 autoPull=ON endpoints before arming")
    assert(#epBefore.warnings > 0 and epBefore.warnings[1]:find("autoPull=ON", 1, true),
        "T10 discoverPassiveEndpoints emits autoPull=ON safety warning")

    local gpu = component._newMockGPU(160, 50)
    local ui = UI.new(cfg, { dtpfStatus = {}, recipeStatus = {}, channelStatus = {}, onDemand = {}, stock = { fluids = {}, items = {} } })
    ui.tab = 4
    ui:render()
    local tab3Warn = gpu._allText()
    assert(tab3Warn:find("LOCK AUTOPULL OFF", 1, true), "T10 Tab 4 renders LOCK AUTOPULL OFF big action button")
    assert(tab3Warn:find("autoPull=ON", 1, true), "T10 Tab 4 displays autoPull=ON warning banner")
    for _, s in ipairs(gpu._calls) do
        _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s
    end

    local clickedLock = false
    for i = #ui.hitboxes, 1, -1 do
        local hb = ui.hitboxes[i]
        local row = gpu._rowText(hb.y1)
        if unicode.sub(row, hb.x1, hb.x2):find("LOCK AUTOPULL OFF", 1, true) then
            ui:handleTouch(hb.x1, hb.y1, 0)
            ui:render()
            clickedLock = true
            break
        end
    end
    assert(clickedLock, "T10 clicked LOCK AUTOPULL OFF big button on Tab 4")
    for k = 1, 5 do
        assertEq(hatchStates[k].autoPull, false, "T10 hatch #" .. k .. " autoPull locked OFF")
        assertEq(busStates[k].autoPull, false, "T10 bus #" .. k .. " autoPull locked OFF")
    end
    local epAfter = Hardware.discoverPassiveEndpoints()
    assertEq(epAfter.autoPullOnCount, 0, "T10 autoPullOnCount cleared to 0 after lock")
    assertEq(#epAfter.warnings, 0, "T10 warnings cleared after autoPull lock")

    -- Arm and apply recipes: verify setAutoPull(false), amount+size populated, and nil clearing on od_only
    for id, rc in pairs(cfg.recipes) do rc.enabled = (id == "molten_neutronium") end
    cfg.dtpfs[1].channelId = "ch1"
    cfg.armed = true
    local st = {}
    Scheduler.step(cfg, st)
    assertEq(hatchStates[1].autoPull, false, "T10 me_inputhatch autoPull disabled before slot writes")
    assert(hatchStates[1].slots[1] ~= nil and hatchStates[1].slots[1].amount >= 144000, "T10 fluid hatch slot 1 sets amount")
    assertEq(hatchStates[1].slots[1].size, hatchStates[1].slots[1].amount, "T10 fluid hatch slot 1 sets size matching amount for AEStackFactory")

    cfg.dtpfs[1].roleOverride = "od_only"
    Scheduler.step(cfg, st)
    assertEq(hatchStates[1].slots[1], nil, "T10 clearing hatch_pair clears slots directly to nil without sentinels")
    assertEq(dtpfStates[1].workAllowed, false, "T10 od_only sleeps until OD work arrives")

    -- Verify Unified 3x MFU Auto-Pairing panel text, 3D distance badges & big action buttons
    ui.state = st
    ui.tab = 4
    ui:render()
    local tab3 = gpu._allText()
    assert(tab3:find("RESCAN HARDWARE", 1, true), "T10 Tab 4 displays big RESCAN HARDWARE action button")
    assert(tab3:find("5H + 5B MFU", 1, true), "T10 Tab 4 displays 5H + 5B MFU badge")
    assert(tab3:find("DISCOVERED DTPF CONTROLLERS", 1, true), "T10 Tab 4 displays unified DTPF MFU pairing table")
    assert(tab3:find("2m", 1, true), "T10 Tab 4 displays 3D distance badge on paired MFU endpoints")
    for _, s in ipairs(gpu._calls) do
        _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s
    end
end

-- ============================================================================
-- TEST 11: Multi-Server OC Rack Cluster (Master + `--worker` over Network Card)
-- ============================================================================
do
    local event = require("event")
    Hardware.resetClusterState()
    component._reset()
    while #event._queue > 0 do table.remove(event._queue) end

    local function makeEP(x, y, z)
        local s = { autoPull = true, slots = {}, calls = {} }
        local p = {
            getCoordinates = function() return x, y, z end,
            getSlotSize = function() return 16 end,
            getAutoPull = function() return s.autoPull end,
            setAutoPull = function(v) s.autoPull = v; s.calls[#s.calls + 1] = { "setAutoPull", v }; return true end,
            getConfiguration = function(slot) return s.slots[slot] end,
            setConfiguration = function(slot, d) s.slots[slot] = d; s.calls[#s.calls + 1] = { "setConfiguration", slot, d }; return true end,
        }
        return p, s
    end

    local fluids = {
        exciteddtcc = 500000, exciteddtpc = 500000, exciteddtrc = 500000, exciteddtec = 500000, exciteddtsc = 500000,
        dimensionallytranscendentresidue = 20000000,
        ["molten.spacetime"] = 5000000,
        ["molten.metastable oganesson"] = 1000000,
        ["molten.precious metals alloy"] = 1000000,
        ["molten.iron"] = 10000000,
        ["molten.steel"] = 10000000,
        ["molten.neutronium"] = 0,
        ["molten.bedrockium"] = 0,
        ["molten.shirabon"] = 0,
        ["molten.infinity"] = 0,
    }
    local items = { ["Avaritia:Resource:5"] = 10000, ["minecraft:cobblestone:0"] = 100000 }
    component._register("t11-stock", "me_controller", makeAENet(fluids, items))
    component._register("t11-od", "me_interface", makeAENet({}, {}))

    -- Master Server 1 owns DTPFs #1..#5 (`z = 82..138`) + 5 local Hatch/Bus pairs
    local masterStates, mHatchSt, mBusSt = {}, {}, {}
    for i = 1, 5 do
        local r, c = math.floor((i - 1) / 2) + 1, ((i - 1) % 2) + 1
        local x, z = (c == 1 and 25 or 53), 82 + (r - 1) * 28
        local dp, ds = makeDTPF(string.format("t11-m-dtpf-%02d", i), x, 67, z)
        local hp, hs = makeEP(x + 2, 66, z + 1)
        local bp, bs = makeEP(x - 2, 66, z + 1)
        component._register(string.format("t11-m-dtpf-%02d", i), "dtpf", dp)
        component._register(string.format("t11-m-h-%02d", i), "me_inputhatch", hp)
        component._register(string.format("t11-m-b-%02d", i), "me_inputbus", bp)
        masterStates[i], mHatchSt[i], mBusSt[i] = ds, hs, bs
    end

    -- Worker Server 2 has its own isolated OC component table owning DTPFs #6..#10 (`z = 166..222`) + 5 Hatch/Bus pairs
    local workerRegistry = {}
    local workerComp = {
        list = function(filter, exact)
            local m = {}
            for a, rec in pairs(workerRegistry) do
                if (not filter) or (exact and rec.type == filter) or (not exact and rec.type:find(filter, 1, true)) then
                    m[#m + 1] = { a, rec.type }
                end
            end
            table.sort(m, function(a, b) return a[1] < b[1] end)
            local idx = 0
            return function()
                idx = idx + 1
                if m[idx] then return m[idx][1], m[idx][2] end
            end
        end,
        proxy = function(a) return workerRegistry[a] and workerRegistry[a].proxy or nil end,
        isAvailable = function(t)
            for _, rec in pairs(workerRegistry) do
                if rec.type == t then return true end
            end
            return false
        end,
    }
    local workerStates, wHatchSt, wBusSt = {}, {}, {}
    local expectedWH, expectedWB = {}, {}
    for i = 1, 5 do
        local g = i + 5
        local r, c = math.floor((g - 1) / 2) + 1, ((g - 1) % 2) + 1
        local x, z = (c == 1 and 25 or 53), 82 + (r - 1) * 28
        local da = string.format("t11-w-dtpf-%02d", i)
        local ha = string.format("t11-w-h-%02d", i)
        local ba = string.format("t11-w-b-%02d", i)
        expectedWH[i], expectedWB[i] = ha, ba
        local dp, ds = makeDTPF(da, x, 67, z)
        local hp, hs = makeEP(x + 2, 66, z + 1)
        local bp, bs = makeEP(x - 2, 66, z + 1)
        workerRegistry[da] = { type = "dtpf", proxy = dp }
        workerRegistry[ha] = { type = "me_inputhatch", proxy = hp }
        workerRegistry[ba] = { type = "me_inputbus", proxy = bp }
        workerStates[i], wHatchSt[i], wBusSt[i] = ds, hs, bs
    end

    local responder = Hardware.createWorkerResponder(workerComp)
    local openPorts = {}
    local function verifyPacket(...)
        local n = select("#", ...)
        assert(n <= 8, "T11 OC packet parts <= 8 (got " .. tostring(n) .. ")")
        local sz = 0
        for k = 1, n do sz = sz + #tostring(select(k, ...)) end
        assert(sz <= 8192, "T11 OC packet bytes <= 8192 (got " .. tostring(sz) .. ")")
    end
    local workerModem = {
        send = function(target, port, ...)
            verifyPacket(...)
            assertEq(target, "master-modem", "T11 worker replies to master-modem")
            event._queue[#event._queue + 1] = { "modem_message", "master-modem", "worker-modem-1", port, 0, ... }
            return true
        end,
    }
    local masterModem = {
        open = function(p) openPorts[p] = true; return true end,
        close = function(p) openPorts[p] = nil; return true end,
        broadcast = function(port, ...)
            verifyPacket(...)
            responder.handleMessage(workerModem, "master-modem", port, ...)
            return true
        end,
        send = function(target, port, ...)
            verifyPacket(...)
            if target == "worker-modem-1" then
                responder.handleMessage(workerModem, "master-modem", port, ...)
            end
            return true
        end,
    }
    component._register("master-modem", "modem", masterModem)

    local cfg = Scheduler.ensureConfig({})
    Scheduler.syncHardware(cfg)
    assertEq(Hardware.getWorkerCount(), 1, "T11 discovered 1 Rack Worker Server")
    assertEq(#cfg.dtpfs, 10, "T11 combined 5 Master + 5 Worker DTPFs")
    assertEq(#cfg.channels, 10, "T11 combined 10 Hatch/Bus channels")
    for i = 1, 5 do
        assertEq(cfg.dtpfs[5 + i].isRemote, true, "T11 DTPF #" .. (5 + i) .. " flagged remote")
        assertEq(cfg.channels[5 + i].hatchAddr, expectedWH[i], "T11 Worker DTPF #" .. (5 + i) .. " paired nearest Worker hatch")
        assertEq(cfg.channels[5 + i].busAddr, expectedWB[i], "T11 Worker DTPF #" .. (5 + i) .. " paired nearest Worker bus")
    end

    -- Arm Master, pin remote DTPF #6 (Worker #1) to molten_shirabon, set remote DTPF #7 (Worker #2) to od_only
    for id, rc in pairs(cfg.recipes) do
        rc.enabled = (id == "molten_neutronium" or id == "molten_bedrockium" or id == "molten_shirabon")
    end
    cfg.dtpfs[6].roleOverride = "pinned"
    cfg.dtpfs[6].pinnedFamilyId = "molten_shirabon"
    cfg.dtpfs[7].roleOverride = "od_only"
    cfg.armed = true

    local st = {}
    Scheduler.step(cfg, st)
    assertEq(st.workerCount, 1, "T11 state records 1 worker server")
    assertEq(wHatchSt[1].autoPull, false, "T11 RPC setAutoPull(false) on Worker Hatch #1")
    local sawDtec = false
    for _, slot in pairs(wHatchSt[1].slots) do
        if slot and slot.name == "exciteddtec" then
            sawDtec = true
            assertEq(slot.size, slot.amount, "T11 Worker fluid slot sets amount == size")
        end
    end
    assert(sawDtec, "T11 Worker Hatch #1 received exciteddtec for remote pinned Shirabon")
    assertEq(workerStates[1].conv, true, "T11 RPC enabled Convergence on Worker DTPF #1")
    assertEq(workerStates[2].workAllowed, false, "T11 RPC disabled workAllowed on Worker DTPF #2 (od_only)")

    -- Mutate remote DTPF progress and verify next step's DTPF_POLL -> DTPF_SNAP updates Master telemetry
    workerStates[1].progress = 150
    workerStates[1].maxProgress = 200
    Scheduler.step(cfg, st)
    assertEq(st.dtpfStatus[6].progress, 150, "T11 DTPF_POLL synced live progress from Worker Server 2")

    local gpu = component._newMockGPU(160, 50)
    local ui = UI.new(cfg, st)
    ui.tab = 4
    ui:render()
    local tab3 = gpu._allText()
    assert(tab3:find("Master + 1 Worker Srv", 1, true), "T11 Tab 4 displays Master + 1 Worker Srv")
    assert(tab3:find("W:t11-w-", 1, true), "T11 Tab 4 displays W: prefix for Worker DTPFs")
    for _, s in ipairs(gpu._calls) do
        _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s
    end

    Hardware.resetClusterState()
end

-- ============================================================================
-- TEST 12: Cross-Screen Navigation, Fleet Presets, Coil Filters & Touch Picker
-- ============================================================================
do
    Hardware.resetClusterState()
    component._reset()

    local function makeEP(x, y, z)
        local s = { autoPull = true, slots = {}, calls = {} }
        local p = {
            getCoordinates = function() return x, y, z end,
            getSlotSize = function() return 16 end,
            getAutoPull = function() return s.autoPull end,
            setAutoPull = function(v) s.autoPull = v; return true end,
            getConfiguration = function(slot) return s.slots[slot] end,
            setConfiguration = function(slot, d) s.slots[slot] = d; return true end,
        }
        return p, s
    end

    local fluids = {
        exciteddtcc = 500000, exciteddtpc = 500000, exciteddtrc = 500000, exciteddtec = 500000, exciteddtsc = 500000,
        dimensionallytranscendentresidue = 20000000,
        ["molten.spacetime"] = 5000000,
        ["molten.metastable oganesson"] = 1000000,
        ["molten.precious metals alloy"] = 1000000,
        ["molten.iron"] = 10000000,
        ["molten.steel"] = 10000000,
        ["molten.copper"] = 10000000,
        ["molten.neutronium"] = 0,
        ["molten.bedrockium"] = 0,
        ["molten.shirabon"] = 0,
        ["molten.infinity"] = 0,
    }
    local items = { ["Avaritia:Resource:5"] = 10000, ["minecraft:cobblestone:0"] = 100000 }
    local odFluids, odItems = {}, {}
    component._register("t12-stock", "me_controller", makeAENet(fluids, items))
    component._register("t12-od", "me_interface", makeAENet(odFluids, odItems))

    -- 5 DTPFs: #1, #2, #4, #5 have 13500K coils; #3 has 12600K coil
    local dtpfStates = {}
    for i = 1, 5 do
        local r, c = math.floor((i - 1) / 2) + 1, ((i - 1) % 2) + 1
        local x, z = (c == 1 and 25 or 53), 82 + (r - 1) * 28
        local coil = (i == 3) and 12600 or 13500
        local dp, ds = makeDTPF(string.format("t12-dtpf-%02d", i), x, 67, z, { coilHeat = coil })
        local hp = makeEP(x + 2, 66, z + 1)
        local bp = makeEP(x - 2, 66, z + 1)
        component._register(string.format("t12-dtpf-%02d", i), "dtpf", dp)
        component._register(string.format("t12-h-%02d", i), "me_inputhatch", hp)
        component._register(string.format("t12-b-%02d", i), "me_inputbus", bp)
        dtpfStates[i] = ds
    end

    local cfg = Scheduler.ensureConfig({})
    Scheduler.syncHardware(cfg)
    assertEq(#cfg.channels, 5, "T12 discovered 5 Hatch/Bus channels")

    for id, rc in pairs(cfg.recipes) do
        rc.enabled = (id == "molten_neutronium" or id == "molten_bedrockium")
    end
    cfg.recipes["molten_infinity"].modifierIndex = 1 -- dust_64x (13500K at DTEC)
    cfg.armed = true

    local st = {}
    Scheduler.step(cfg, st)
    assertEq(st.dtpfStatus[1].familyId, "molten_neutronium", "T12 exposed familyId on dtpfStatus[1]")

    local gpu = component._newMockGPU(160, 50)
    local ui = UI.new(cfg, st)
    ui.tab = 2
    ui:render()

    local function clickT12(needle, xMin, xMax, yMin, yMax, button)
        for i = #ui.hitboxes, 1, -1 do
            local hb = ui.hitboxes[i]
            if (not xMin or hb.x1 >= xMin) and (not xMax or hb.x2 <= xMax)
                and (not yMin or hb.y1 >= yMin) and (not yMax or hb.y2 <= yMax) then
                local row = gpu._rowText(hb.y1)
                if unicode.sub(row, hb.x1, hb.x2):find(needle, 1, true) then
                    ui:handleTouch(hb.x1, hb.y1, button)
                    ui:render()
                    return true
                end
            end
        end
        return false
    end

    local hdrRow2 = gpu._rowText(2)
    assert(hdrRow2:find("Run:2 Loop:2 OD:0 Idle:1", 1, true), "T12 multi-channel header summarizes Run/Loop/OD/Idle fleet")

    -- Click DTPF #1 active recipe chip on Tab 2 Fleet -> jumps straight to Tab 3 Recipe Inspector
    assert(clickT12("▸ Molten Neutronium", 2, 39, 8, 8), "T12 left-clicked recipe name on DTPF #1 card")
    assertEq(ui.tab, 3, "T12 jumped to Tab 3 Recipe Inspector")
    assertEq(ui.selectedFamilyId, "molten_neutronium", "T12 Inspector focused molten_neutronium")

    -- In Tab 2 Recipe Inspector: select Molten Shirabon, open [Pin to a DTPF…] modal, step -> #2, pin <Target>, verify ◆ indicator, return via [<- Fleet]
    ui.selectedFamilyId = "molten_shirabon"
    ui:render()
    assert(clickT12("[Pin to a DTPF…]", 85, 159, 9, 9), "T12 clicked [Pin to a DTPF…] inside Tab 2")
    assertEq(ui.passiveModalActive, true, "T12 Passive Modal opened from Tab 2 Inspector")
    assert(clickT12("[▶]", 23, 136, 7, 7), "T12 Modal stepped DTPF selector 1 -> 2")
    assertEq(ui.selectedDtpf, 2, "T12 Modal DTPF selector advanced to DTPF #2")
    local pinnedShirInModal = false
    for i = #ui.hitboxes, 1, -1 do
        local hb = ui.hitboxes[i]
        if hb.y1 == hb.y2 and hb.y1 >= 14 and hb.y1 <= 40 then
            local row = gpu._rowText(hb.y1)
            local slice = unicode.sub(row, hb.x1, hb.x2)
            if row:find("Molten Shirabon", 1, true) and slice:find("[◆ Pin <Target]", 1, true) then
                ui:handleTouch(hb.x1, hb.y1, 0)
                ui:render()
                pinnedShirInModal = true
                break
            end
        end
    end
    assert(pinnedShirInModal, "T12 pinned Molten Shirabon to DTPF #2 via unified modal")
    assertEq(ui.passiveModalActive, false, "T12 Passive Modal closed on pin")
    assertEq(cfg.dtpfs[2].roleOverride, "pinned", "T12 DTPF #2 roleOverride -> pinned")
    assertEq(cfg.dtpfs[2].pinnedFamilyId, "molten_shirabon", "T12 DTPF #2 pinnedFamilyId -> molten_shirabon")
    assert(gpu._allText():find("◆", 1, true), "T12 Tab 2 displays ◆ pin indicator in recipe list")
    assert(gpu._rowText(9):find("Pinned to:", 1, true), "T12 Tab 2 Row 9 displays Pinned to summary")
    assert(clickT12("[<- Fleet]", 85, 159, 4, 4), "T12 clicked [<- Fleet] back to Tab 2")
    assertEq(ui.tab, 2, "T12 [<- Fleet] returned to Tab 2 Control Center")

    -- On 5-DTPF non-compact layout where all full cards fit, Row 47 quick-bar is contextually hidden
    assert(not gpu._rowText(47):find("[Assign Passive", 1, true), "T12 Row 47 bar hidden when all full cards fit")
    assert(clickT12("Auto Queue", 2, 39, 12, 12), "T12 opened Passive Modal via Card #1 inline Mode button")
    assertEq(ui.selectedDtpf, 1, "T12 selectedDtpf -> 1")
    assertEq(ui.passiveModalActive, true, "T12 Passive Modal opened for #1")
    assert(clickT12("[1 Loop+Rest Q]", 23, 136, 10, 10), "T12 clicked [1 Loop+Rest Q] preset inside Passive Modal")
    assertEq(ui.passiveModalActive, false, "T12 Passive Modal closed after [1 Loop+Rest Q]")
    assertEq(cfg.dtpfs[1].roleOverride, "auto", "T12 DTPF #1 stays auto (Loop keeper)")
    assertEq(cfg.dtpfs[2].roleOverride, "passive_only", "T12 DTPF #2 set to passive_only")
    assertEq(cfg.dtpfs[4].roleOverride, "passive_only", "T12 DTPF #4 set to passive_only")
    ui:openPassiveModal(5)
    ui:render()
    assert(clickT12("[ ON-DEMAND ONLY ]", 23, 136, 10, 10), "T12 clicked [ ON-DEMAND ONLY ] for DTPF #5")
    assertEq(cfg.dtpfs[5].roleOverride, "od_only", "T12 last DTPF (#5) set to od_only")

    -- Satisfy active queue targets: only DTPF #1 keeps looping, #2..#4 sleep (passive_only), #5 sleeps (od_only)
    fluids["molten.neutronium"] = 50000000000
    fluids["molten.bedrockium"] = 50000000000
    Scheduler.step(cfg, st)
    assertEq(dtpfStates[1].workAllowed, true, "T12 DTPF #1 runs Forever Loop after targets full")
    assertEq(st.dtpfStatus[1].jobMode, "FALLBACK", "T12 DTPF #1 jobMode is FALLBACK")
    for k = 2, 5 do
        assertEq(dtpfStates[k].workAllowed, false, "T12 DTPF #" .. k .. " sleeps when targets full")
    end

    -- Trigger OD work and check OD fleet header badge
    odFluids["molten.copper"] = 73728
    Scheduler.step(cfg, st)
    ui:render()
    assert(gpu._rowText(2):find("OD:5", 1, true) or gpu._rowText(2):find("OD:1", 1, true), "T12 header shows live OD count")
    odFluids["molten.copper"] = nil
    Scheduler.step(cfg, st)
    ui:render()

    -- Test Card #1 Mode button -> Passive Modal [▶] stepping + [Coil OK] filter + R-click stay + Name->Inspector jump
    ui.selectedDtpf = 2
    ui:render()
    assert(clickT12("Auto Queue", 2, 39, 12, 12), "T12 opened Passive Modal via Card #1 inline Mode button (2nd time)")
    assertEq(ui.passiveModalActive, true, "T12 Passive Modal open")
    assert(clickT12("[▶]", 23, 136, 7, 7), "T12 Modal stepped DTPF 1 -> 2")
    assert(clickT12("[▶]", 23, 136, 7, 7), "T12 Modal stepped DTPF 2 -> 3 (12600K coils)")
    assertEq(ui.passiveModalDtpfIdx, 3, "T12 Modal now inspecting DTPF #3")
    assert(gpu._allText():find("!Eternal", 1, true), "T12 Modal flags !Eternal recipes on 12600K DTPF #3 by default")
    assert(clickT12("!Eternal", 55, 65, 14, 37), "T12 Modal clicked !Eternal coil cell to toggle temp display")
    assertEq(cfg.coilDisplayMode, "temp", "T12 clicking modal coil switched coilDisplayMode -> temp")
    assert(gpu._allText():find("!13.5kK", 1, true), "T12 Modal displays !13.5kK after toggling to temp mode")
    assert(clickT12("!13.5kK", 55, 65, 14, 37), "T12 Modal clicked !13.5kK to toggle back to tier name")
    assertEq(cfg.coilDisplayMode, "name", "T12 clicking modal coil restored coilDisplayMode -> name")
    assert(clickT12("[Coil OK]", 23, 136, 12, 12), "T12 Modal enabled [Coil OK] filter")
    assert(not gpu._allText():find("Molten Shirabon", 1, true), "T12 [Coil OK] hides 13.5kK Molten Shirabon for 12600K DTPF #3")
    assert(clickT12("[All ", 23, 136, 12, 12), "T12 Modal restored [All] filter")
    assert(clickT12("[◆ Pin <Target]", 23, 136, 14, 37, 1), "T12 Modal R-clicked [◆ Pin <Target] to keep modal open")
    assertEq(ui.passiveModalActive, true, "T12 R-click pin kept Passive Modal open")
    assertEq(cfg.dtpfs[3].roleOverride, "pinned", "T12 DTPF #3 pinned via R-click in modal")
    assert(clickT12("Molten Neutronium", 24, 55, 14, 37), "T12 Modal clicked Molten Neutronium recipe name to inspect")
    assertEq(ui.passiveModalActive, false, "T12 Modal closed when jumping to Recipe Inspector")
    assertEq(ui.tab, 3, "T12 jumped to Tab 3 from Modal recipe name")
    assertEq(ui.selectedFamilyId, "molten_neutronium", "T12 Inspector focused clicked modal recipe")

    -- Test Tab 4 Setup click-to-focus DTPF #5 row back to Tab 2 Fleet
    ui.tab = 4
    ui:render()
    assert(clickT12("DTPF #5", 2, 160, 27, 49), "T12 Tab 4 clicked DTPF #5 row")
    assertEq(ui.tab, 2, "T12 Tab 4 row click jumped to Tab 2 Fleet")
    assertEq(ui.selectedDtpf, 5, "T12 Tab 4 row click focused DTPF #5")

    -- Test [Floors…] jump Header Row 3 -> Tab 4 + Walk-Up Touch Number Picker (ZERO keyboard events!)
    assert(clickT12("[Floors…]", 145, 160, 3, 3), "T12 clicked [Floors…] shortcut on Header Row 3")
    assertEq(ui.tab, 4, "T12 [Floors…] navigated to Tab 4 Setup")
    assert(clickT12("[Min:", 4, 30, 13, 13), "T12 clicked DTEC [Min:...] floor button on Tab 4")
    assertEq(ui.promptActive, true, "T12 Number Picker modal opened")
    assertEq(ui.promptIsNumeric, true, "T12 Number Picker enabled touch preset chips")
    assert(clickT12("[10M]"), "T12 touch-clicked [10M] preset chip")
    assert(clickT12("[x2]"), "T12 touch-clicked [x2] adjustment chip")
    assert(clickT12("[ APPLY ]"), "T12 touch-clicked [ APPLY ] without keyboard input")
    assertEq(ui.promptActive, false, "T12 Number Picker closed")
    assertEq(cfg.catalystFloors["DTEC"], 20000000, "T12 touch chips updated DTEC reserve floor -> 20M")

    -- Keyboard navigation: Tab cycles views 1..4, ]/[ cycle DTPFs, P opens Passive Modal, Esc closes
    ui.tab = 2
    ui:render()
    ui:handleKeyDown(9, 15) -- Tab -> 3
    assertEq(ui.tab, 3, "T12 Tab key cycled View 2 -> 3")
    ui:handleKeyDown(9, 15) -- Tab -> 4
    assertEq(ui.tab, 4, "T12 Tab key cycled View 3 -> 4")
    ui:handleKeyDown(9, 15) -- Tab -> 1
    assertEq(ui.tab, 1, "T12 Tab key wrapped View 4 -> 1")
    ui.tab = 2
    ui:handleKeyDown(string.byte("]"), 27)
    assertEq(ui.selectedDtpf, 1, "T12 ] key wrapped selectedDtpf 5 -> 1")
    ui:handleKeyDown(string.byte("["), 26)
    assertEq(ui.selectedDtpf, 5, "T12 [ key wrapped selectedDtpf 1 -> 5")
    ui:handleKeyDown(string.byte("p"), 25)
    assertEq(ui.passiveModalActive, true, "T12 P key opened Passive Modal")
    ui:handleKeyDown(0, 1) -- Esc
    assertEq(ui.passiveModalActive, false, "T12 Esc key closed Passive Modal")

    -- Render Touch Number Picker one last time to include its GPU calls in glyph check
    ui:openNumberPrompt("Sample Touch Floor:", "1M", function() end)
    ui:render()
    for _, s in ipairs(gpu._calls) do
        _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s
    end

    Hardware.resetClusterState()
end

-- ============================================================================
-- TEST 13: GUI Sugar, [Log / ! Why] Bottleneck Modal, AE2 Checkmarks & QoL
-- ============================================================================
do
    Hardware.resetClusterState()
    local env, fluids, items, odFluids, odItems, fsbSlots, fsbCalls, isbSlots, isbCalls, dtpfStates = setupStandardEnv()
    -- Enable Molten Neutronium (#1, runnable) and Molten Shirabon (#27, missing molten.spacetime)
    for id, rc in pairs(env.recipes) do
        rc.enabled = (id == "molten_neutronium" or id == "molten_shirabon")
    end
    fluids["molten.spacetime"] = 0
    env.armed = true

    local st = {}
    Scheduler.step(env, st)
    assertEq(st.stepCount, 1, "T13 Scheduler.step increments stepCount")
    assert(#(st.events or {}) >= 1, "T13 Scheduler.step records transition events")
    assert(#(st.bottlenecks or {}) >= 1, "T13 Scheduler.step detects blocked enabled recipe bottleneck")
    assertEq(st.recipeStatus["molten_neutronium"].activeDtpfs[1], 1, "T13 tracks running DTPF indices per recipe")

    local gpu = component._newMockGPU(160, 50)
    local ui = UI.new(env, st)
    ui.tab = 2
    ui:render()

    local function clickT13(needle, xMin, xMax, yMin, yMax, button)
        for i = #ui.hitboxes, 1, -1 do
            local hb = ui.hitboxes[i]
            if (not xMin or hb.x1 >= xMin) and (not xMax or hb.x2 <= xMax)
                and (not yMin or hb.y1 >= yMin) and (not yMax or hb.y2 <= yMax) then
                local row = gpu._rowText(hb.y1)
                if unicode.sub(row, hb.x1, hb.x2):find(needle, 1, true) then
                    ui:handleTouch(hb.x1, hb.y1, button)
                    ui:render()
                    return true
                end
            end
        end
        return false
    end

    assert(gpu._rowText(1):find("[! 1 Alert]", 1, true), "T13 Header renders [! N Alert] bottleneck badge")
    assert(gpu._allText():find("█", 1, true) or gpu._allText():find("░", 1, true), "T13 Cards render block progress bar")

    -- Click [! 1 Alert] -> opens Log & Bottleneck Modal -> [Inspect →] jumps to blocked Molten Shirabon on Tab 3 (Recipes)
    assert(clickT13("[! ", 1, 160, 1, 1), "T13 clicked header [! N Alert] button")
    assertEq(ui.logModalActive, true, "T13 Log/Bottleneck Modal opened")
    assert(gpu._allText():find("Molten Shirabon", 1, true), "T13 Modal lists Molten Shirabon bottleneck")
    assert(clickT13("[Inspect →]", 8, 152, 7, 15), "T13 clicked [Inspect →] on blocked bottleneck")
    assertEq(ui.logModalActive, false, "T13 Modal closed after [Inspect →]")
    assertEq(ui.tab, 3, "T13 [Inspect →] jumped to Tab 3 Recipes")
    assertEq(ui.selectedFamilyId, "molten_shirabon", "T13 Inspector focused Molten Shirabon")
    local inspMissingTxt = gpu._allText()
    assert(inspMissingTxt:find("✗", 1, true) and inspMissingTxt:find("0 crafts", 1, true),
        "T13 Inspector shows ✗ and 0 crafts when Molten SpaceTime is missing")

    -- Restore Molten SpaceTime and click header [↻ Poll] -> clears bottleneck and updates AE2 checkmarks!
    fluids["molten.spacetime"] = 5000000
    assert(clickT13("[↻ Poll]", 1, 160, 1, 1), "T13 clicked header [↻ Poll] refresh button")
    assertEq(#st.bottlenecks, 0, "T13 [↻ Poll] cleared bottlenecks")
    assert(gpu._rowText(1):find("[Log:", 1, true), "T13 Header transitioned from [! N Alert] to [Log:]")
    local inspReadyTxt = gpu._allText()
    assert(inspReadyTxt:find("✓", 1, true) and inspReadyTxt:find("crafts ready", 1, true),
        "T13 Inspector displays live ✓ craft count after [↻ Poll]")
    assert(gpu._rowText(11):find("█", 1, true) or gpu._rowText(11):find("░", 1, true),
        "T13 Row 11 renders visual Stock/Target bar")

    -- Switch to Tab 1 and verify QoL shortcuts:
    ui.tab = 2
    ui:render()
    -- 1. Right-click ▲ jumps Molten Shirabon (#27, row 3 y=14) straight to priority #1; Right-click ▼ jumps back to #27
    assert(clickT13("▲", 82, 86, 14, 14, 1), "T13 R-clicked ▲ to jump Molten Shirabon to priority #1")
    assertEq(env.recipes["molten_shirabon"].priority, 1, "T13 Molten Shirabon moved to #1")
    assert(clickT13("▼", 82, 86, 12, 12, 1), "T13 R-clicked ▼ to jump Molten Shirabon to bottom (#27)")
    assertEq(env.recipes["molten_shirabon"].priority, 27, "T13 Molten Shirabon moved to #27")

    -- 2. Open Tab 4 via Header [Floors…], right-click DTEC [Min:...] to copy floor across all 5 catalyst tiers
    local RecipesDB = require("lib.recipes_db")
    env.catalystFloors["DTEC"] = 250000
    assert(clickT13("[Floors…]", 145, 160, 3, 3), "T13 clicked Header [Floors…] to jump to Tab 4 Setup")
    assertEq(ui.tab, 4, "T13 [Floors…] opened Tab 4")
    assert(clickT13("[Min:", 4, 30, 13, 13, 1), "T13 R-clicked DTEC [Min:...] to copy across all 5 catalysts")
    for _, tier in ipairs(RecipesDB.CATALYST_TIERS) do
        assertEq(env.catalystFloors[tier.code], 250000, "T13 copied 250K reserve floor -> " .. tier.code)
    end

    -- 3. Click active DTPF status badge (● #1 Run) in Priority Queue focuses DTPF #1
    ui.tab = 2
    ui.selectedDtpf = 3
    ui:render()
    assert(clickT13("● #1", 146, 160, 12, 47), "T13 clicked ● #1 Run status badge in Priority Queue")
    assertEq(ui.selectedDtpf, 1, "T13 clicking ● #1 Run focused DTPF #1")

    -- Open Log Modal via [L] hotkey, render it to audit all glyphs via font.hex, then close via Esc
    ui:handleKeyDown(string.byte("l"), 38)
    assertEq(ui.logModalActive, true, "T13 [L] hotkey opened Log Modal")
    ui:render()
    for _, s in ipairs(gpu._calls) do
        _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s
    end
    ui:handleKeyDown(0, 1)
    assertEq(ui.logModalActive, false, "T13 Esc closed Log Modal")

    Hardware.resetClusterState()
end

-- ============================================================================
-- TEST 14: Sci-Fi Icons, Double/Rounded Frames, Sub-Pixel Bars & Tank Gauges
-- ============================================================================
do
    Hardware.resetClusterState()
    local env, fluids, items, odFluids, odItems, fsbSlots, fsbCalls, isbSlots, isbCalls, dtpfStates = setupStandardEnv()
    for id, rc in pairs(env.recipes) do
        rc.enabled = (id == "molten_neutronium" or id == "molten_bedrockium")
    end
    env.armed = true
    dtpfStates[1].active = true
    dtpfStates[1].hasWork = true
    dtpfStates[1].conv = true
    dtpfStates[1].progress = 110
    dtpfStates[1].maxProgress = 200 -- 55%

    local st = {}
    Scheduler.step(env, st) -- stepCount = 1 (odd)

    -- Verify 8-step sub-pixel progress bar produces fractional block chars (▏..▉)
    local barZero = UI.buildProgressBar(0.0, 10)
    local barFrac = UI.buildProgressBar(0.54, 10)
    local barFull = UI.buildProgressBar(1.0, 10)
    assertEq(barZero, "[░░░░░░░░░░]", "T14 buildProgressBar 0%")
    assertEq(barFull, "[██████████]", "T14 buildProgressBar 100%")
    local hasFrac = false
    for _, sub in ipairs({ "▏", "▎", "▍", "▌", "▋", "▊", "▉" }) do
        if barFrac:find(sub, 1, true) then hasFrac = true break end
    end
    assert(hasFrac, "T14 buildProgressBar 0.54 uses fractional sub-pixel block")
    assert(barFrac ~= UI.buildProgressBar(0.50, 10), "T14 54% bar differs smoothly from 50% bar")

    local gpu = component._newMockGPU(160, 50)
    local ui = UI.new(env, st)
    ui.selectedDtpf = 1
    ui.tab = 2
    ui:render()
    local oddTab1 = gpu._allText()
    assert(oddTab1:find("╔", 1, true) and oddTab1:find("╝", 1, true), "T14 Selected DTPF renders double-line focus frame")
    assert(oddTab1:find("╭", 1, true) and oddTab1:find("╯", 1, true), "T14 Unselected DTPFs render rounded frames")
    assert(oddTab1:find("⚡◈⚡", 1, true), "T14 Converging sprite renders steady ⚡◈⚡ plasma pinch")
    assert(gpu._rowText(3):find("█DTEC", 1, true) or gpu._rowText(3):find("▇DTEC", 1, true), "T14 Header Row 3 renders catalyst vertical tank gauge")
    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    -- Step again (stepCount = 2, even) and confirm zero sprite alternation flicker
    Scheduler.step(env, st)
    ui:render()
    local evenTab1 = gpu._allText()
    assert(evenTab1:find("⚡◈⚡", 1, true), "T14 Converging sprite stays steady ⚡◈⚡ across steps (zero flicker)")
    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    -- Tab 3 Recipes category badges across all 3 categories + Coil:Eternal tier readout
    ui.selectedFamilyId = "molten_shirabon"
    ui.tab = 3
    ui:render()
    local tab2Txt = gpu._allText()
    assert(tab2Txt:find("Coil:Eternal", 1, true), "T14 Tab 3 Inspector renders GTNH Coil:Eternal tier name by default")
    for _, sym in ipairs({ "◈", "▣", "⊕" }) do
        assert(tab2Txt:find(sym, 1, true), "T14 Tab 3 renders category icon " .. sym)
    end
    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    -- Tab 4 Setup subnets & bridge card
    ui.tab = 4
    ui:render()
    local tab3Txt = gpu._allText()
    assert(tab3Txt:find("SUBNETS & BRIDGE", 1, true), "T14 Tab 4 renders SUBNETS & BRIDGE card")
    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    -- Also render double-framed Passive & Log Modals to include every glyph in font.hex check
    ui:openPassiveModal(1)
    ui:render()
    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    ui.passiveModalActive = false
    ui.logModalActive = true
    ui:render()
    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    Hardware.resetClusterState()
end

-- ============================================================================
-- TEST 15: Per-DTPF On-Demand Subnets (`odNetAddr`), Keep-Running Convergence,
--          `[OD NET]` / `[ 1:1 PAIR OD ]` UI & `main.lua` Config Persistence
-- ============================================================================
do
    Hardware.resetClusterState()
    component._reset()

    local function makeCoordAENet(fluidsMap, itemsMap, x, y, z)
        local p = makeAENet(fluidsMap, itemsMap)
        p.getCoordinates = function() return x, y, z end
        return p
    end

    local stockFluids = {
        exciteddtcc = 500000, exciteddtpc = 500000, exciteddtrc = 500000, exciteddtec = 500000, exciteddtsc = 500000,
        ["molten.iron"] = 10000000,
        ["molten.neutronium"] = 0,
    }
    local stockItems = {}
    local od1Fluids, od1Items = {}, {}
    local od2Fluids, od2Items = {}, {}
    local od3Fluids, od3Items = {}, {}

    component._register("t15-stock", "me_controller", makeCoordAENet(stockFluids, stockItems, 0, 64, 0))
    -- Intentionally register out of coordinate/index order so 3D nearest pairing proves itself
    component._register("t15-od3", "fluid_interface", makeCoordAENet(od3Fluids, od3Items, 25, 67, 112))
    component._register("t15-od1", "fluid_interface", makeCoordAENet(od1Fluids, od1Items, 25, 67, 84))
    component._register("t15-od2", "fluid_interface", makeCoordAENet(od2Fluids, od2Items, 53, 67, 84))

    local fsb1, fsb1Slots, fsb1Calls = makeStorageBus("t15-fsb1", 0, true)
    local isb1, isb1Slots, isb1Calls = makeStorageBus("t15-isb1", 0, false)
    component._register("t15-fsb1", "fluid_storagebus", fsb1)
    component._register("t15-isb1", "me_storagebus", isb1)

    local dtpfStates = {}
    local dCoords = { { 25, 67, 82 }, { 53, 67, 82 }, { 25, 67, 110 } }
    for i = 1, 3 do
        local p, ds = makeDTPF("t15-d" .. i, dCoords[i][1], dCoords[i][2], dCoords[i][3])
        dtpfStates[i] = ds
        component._register("t15-d" .. i, "dtpf", p)
    end

    local cfg = Scheduler.ensureConfig({})
    local nets = Scheduler.syncHardware(cfg)
    assertEq(#nets, 4, "T15 discovered 1 stock + 3 per-DTPF OD nets")
    assertEq(#cfg.dtpfs, 3, "T15 discovered 3 DTPFs")
    assertEq(cfg.dtpfs[1].odNetAddr, "t15-od1", "T15 auto-paired DTPF #1 -> nearest t15-od1")
    assertEq(cfg.dtpfs[2].odNetAddr, "t15-od2", "T15 auto-paired DTPF #2 -> nearest t15-od2")
    assertEq(cfg.dtpfs[3].odNetAddr, "t15-od3", "T15 auto-paired DTPF #3 -> nearest t15-od3")

    for id, rc in pairs(cfg.recipes) do
        rc.enabled = (id == "molten_neutronium")
    end
    cfg.fallbackEnabled = false
    cfg.globalConvMode = "ondemand"
    cfg.onDemandConvMode = "auto_safe"
    cfg.pausePassivesOnOD = false -- KEEP RUNNING
    cfg.dtpfs[3].roleOverride = "od_only"
    cfg.armed = true

    -- Phase A: All OD subnets idle
    local st = {}
    Scheduler.step(cfg, st)
    assertEq(st.onDemand.hasWork, false, "T15 Phase A OD idle")
    assertEq(st.channelStatus["ch1"].mode, "PASSIVE", "T15 Phase A ch1 runs PASSIVE")
    assertEq(dtpfStates[1].workAllowed, true, "T15 Phase A DTPF #1 runs PASSIVE")
    assertEq(dtpfStates[1].conv, false, "T15 Phase A DTPF #1 passive stays 2x (ondemand mode)")
    assertEq(dtpfStates[2].workAllowed, true, "T15 Phase A DTPF #2 runs PASSIVE")
    assertEq(dtpfStates[2].conv, false, "T15 Phase A DTPF #2 passive stays 2x")
    assertEq(dtpfStates[3].workAllowed, false, "T15 Phase A DTPF #3 (od_only) sleeps")

    -- Phase B: OD fluid + patterned catalyst arrive on t15-od2 ONLY
    od2Fluids["molten.copper"] = 144000
    od2Fluids["exciteddtec"] = 10000
    Scheduler.step(cfg, st)
    assertEq(st.onDemand.hasWork, true, "T15 Phase B OD active")
    assert(st.onDemand.summary:find("#2:", 1, true), "T15 Phase B summary identifies #2")
    assertEq(st.channelStatus["ch1"].mode, "PASSIVE", "T15 Phase B ch1 keeps running passives under KEEP RUNNING")
    assertEq(st.dtpfStatus[1].jobMode, "PASSIVE", "T15 Phase B DTPF #1 stays PASSIVE")
    assertEq(dtpfStates[1].conv, false, "T15 Phase B DTPF #1 keeps conv=false")
    assertEq(st.dtpfStatus[2].jobMode, "ON-DEMAND", "T15 Phase B DTPF #2 enters ON-DEMAND")
    assertEq(dtpfStates[2].workAllowed, true, "T15 Phase B DTPF #2 enabled for OD")
    assertEq(dtpfStates[2].conv, true, "T15 Phase B DTPF #2 enables 4x OD Convergence with patterned catalyst")
    assertEq(dtpfStates[3].workAllowed, false, "T15 Phase B DTPF #3 stays asleep")
    local neutActive = st.recipeStatus["molten_neutronium"].activeDtpfs
    assertEq(#neutActive, 1, "T15 Phase B activeDtpfs lists only #1 (excludes #2 busy on OD)")
    assertEq(neutActive[1], 1, "T15 Phase B activeDtpfs[1] == 1")

    -- Phase C: Clear od2, add catalyst-free OD fluid to t15-od3 ONLY (wakes od_only #3 at auto_safe 2x)
    od2Fluids["molten.copper"] = nil
    od2Fluids["exciteddtec"] = nil
    od3Fluids["molten.tin"] = 144000
    Scheduler.step(cfg, st)
    assert(st.onDemand.summary:find("#3:", 1, true), "T15 Phase C summary identifies #3")
    assertEq(st.dtpfStatus[1].jobMode, "PASSIVE", "T15 Phase C DTPF #1 runs PASSIVE")
    assertEq(st.dtpfStatus[2].jobMode, "PASSIVE", "T15 Phase C DTPF #2 resumed PASSIVE")
    assertEq(dtpfStates[2].conv, false, "T15 Phase C DTPF #2 reverted to 2x")
    assertEq(st.dtpfStatus[3].jobMode, "ON-DEMAND", "T15 Phase C DTPF #3 wakes into ON-DEMAND")
    assertEq(dtpfStates[3].workAllowed, true, "T15 Phase C DTPF #3 woke up")
    assertEq(dtpfStates[3].conv, false, "T15 Phase C DTPF #3 stays 2x (auto_safe without patterned catalyst)")

    -- Phase D: Dedicated passive channels (ch1..ch3) + PAUSE PASSIVES preempts ONLY the busy DTPF's channel
    od3Fluids["molten.tin"] = nil
    local fsb2, fsb2Slots = makeStorageBus("t15-fsb2", 0, true)
    local isb2, isb2Slots = makeStorageBus("t15-isb2", 0, false)
    local fsb3, fsb3Slots = makeStorageBus("t15-fsb3", 0, true)
    local isb3, isb3Slots = makeStorageBus("t15-isb3", 0, false)
    component._register("t15-fsb2", "fluid_storagebus", fsb2)
    component._register("t15-isb2", "me_storagebus", isb2)
    component._register("t15-fsb3", "fluid_storagebus", fsb3)
    component._register("t15-isb3", "me_storagebus", isb3)

    cfg.dtpfs[3].roleOverride = "auto"
    cfg.pausePassivesOnOD = true
    cfg.allowParallelSameRecipe = true
    Scheduler.syncHardware(cfg)
    assertEq(#cfg.channels, 3, "T15 Phase D expanded to 3 dedicated StorageBus channels")
    for i = 1, 3 do cfg.dtpfs[i].channelId = "ch" .. i end

    od2Fluids["molten.copper"] = 144000
    Scheduler.step(cfg, st)
    assertEq(st.channelStatus["ch1"].mode, "PASSIVE", "T15 Phase D ch1 keeps running PASSIVE")
    assertEq(st.channelStatus["ch2"].mode, "ON-DEMAND", "T15 Phase D ONLY ch2 cleared for ON-DEMAND")
    assertEq(st.channelStatus["ch3"].mode, "PASSIVE", "T15 Phase D ch3 keeps running PASSIVE")
    assertEq(cfg.channels[2].fluidSentinel, "ic2pahoehoelava", "T15 Phase D ch2 wrote 0-stock sentinel while preempted")

    -- Phase E: Tab 4 [OD NET] & [ 1:1 PAIR OD ] UI clicks + main.lua config persistence & --check
    local gpu = component._newMockGPU(160, 50)
    local ui = UI.new(cfg, st)
    ui.tab = 4
    ui:render()
    local tab3Txt = gpu._allText()
    assert(tab3Txt:find("3 OD Nets", 1, true), "T15 Tab 3 shows 3 OD Nets summary")
    assert(tab3Txt:find("[ 1:1 PAIR OD ]", 1, true), "T15 Tab 3 renders [ 1:1 PAIR OD ] button")
    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    local function clickT15(needle, yMin, yMax, rowMatch)
        for i = #ui.hitboxes, 1, -1 do
            local hb = ui.hitboxes[i]
            if (not yMin or hb.y1 >= yMin) and (not yMax or hb.y2 <= yMax) then
                local row = gpu._rowText(hb.y1)
                if (not rowMatch or row:find(rowMatch, 1, true))
                    and unicode.sub(row, hb.x1, hb.x2):find(needle, 1, true) then
                    ui:handleTouch(hb.x1, hb.y1, 0)
                    ui:render()
                    return true
                end
            end
        end
        return false
    end

    assertEq(cfg.dtpfs[1].odNetAddr, "t15-od1", "T15 initial DTPF #1 OD net")
    assert(clickT15("[t15-od1 ]", 28, 49, "DTPF #1"), "T15 clicked DTPF #1 [OD NET] -> t15-od3")
    assertEq(cfg.dtpfs[1].odNetAddr, "t15-od3", "T15 cycled DTPF #1 OD net to t15-od3")
    assert(clickT15("[t15-od3 ]", 28, 49, "DTPF #1"), "T15 clicked DTPF #1 [OD NET] -> None")
    assertEq(cfg.dtpfs[1].odNetAddr, "none", "T15 cycled DTPF #1 OD net to none")
    assert(clickT15("[None    ]", 28, 49, "DTPF #1"), "T15 clicked DTPF #1 [OD NET] -> Global")
    assertEq(cfg.dtpfs[1].odNetAddr, "global", "T15 cycled DTPF #1 OD net to global")
    assert(clickT15("[Global  ]", 28, 49, "DTPF #1"), "T15 clicked DTPF #1 [OD NET] -> t15-od2")
    assertEq(cfg.dtpfs[1].odNetAddr, "t15-od2", "T15 cycled DTPF #1 OD net to t15-od2")
    assert(clickT15("[ 1:1 PAIR OD ]", 13, 13), "T15 clicked [ 1:1 PAIR OD ]")
    assertEq(cfg.dtpfs[1].odNetAddr, "t15-od1", "T15 [ 1:1 PAIR OD ] restored DTPF #1 -> t15-od1")
    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    -- Verify main.lua saveConfig & --check preserve odNetAddr using in-memory VFS
    local evQ = require("event")._queue
    while #evQ > 0 do table.remove(evQ) end
    evQ[1] = { "key_down", "kbd", string.byte("q"), 16 }
    component.gpu = gpu
    local mainPath = _G.__DTPF_ROOT .. "/main.lua"
    local cfgPath = _G.__DTPF_ROOT .. "/config.cfg"
    local mChunk, mErr = load(assert(__py_read_file(mainPath)), "@" .. mainPath)
    assert(mChunk, mErr)
    mChunk()
    component.gpu = nil
    while #evQ > 0 do table.remove(evQ) end

    local savedRaw = __py_read_file(cfgPath)
    assert(savedRaw ~= nil, "T15 main.lua saved config.cfg to in-memory VFS")
    local savedTbl = serialization.unserialize(savedRaw)
    assertEq(savedTbl.dtpfs[1].odNetAddr, "t15-od1", "T15 config.cfg persisted DTPF #1 odNetAddr")
    assertEq(savedTbl.dtpfs[2].odNetAddr, "t15-od2", "T15 config.cfg persisted DTPF #2 odNetAddr")
    assertEq(savedTbl.dtpfs[3].odNetAddr, "t15-od3", "T15 config.cfg persisted DTPF #3 odNetAddr")

    mChunk("--check")
    __py_remove_vfs(cfgPath)
end

-- Run main.lua --check end-to-end under OpenOS-style wrapped debug.getinfo and verify zero hardware mutations
do
    Hardware.resetClusterState()
    local _, _, _, _, _, _, fsbCalls, _, isbCalls, dtpfStates = setupStandardEnv()
    local mainPath = _G.__DTPF_ROOT .. "/main.lua"

    local origGetInfo = debug.getinfo
    local origPath = package.path
    local savedMods = {
        ["lib.hardware"] = package.loaded["lib.hardware"],
        ["lib.scheduler"] = package.loaded["lib.scheduler"],
        ["lib.ui"] = package.loaded["lib.ui"],
        ["lib.recipes_db"] = package.loaded["lib.recipes_db"],
    }

    -- Simulate OpenComputers machine.lua wrapping debug.getinfo inside "=machine"
    local wrappedGetInfo = assert(load("local o = ... return function(...) return o(...) end", "=machine"))(origGetInfo)
    debug.getinfo = wrappedGetInfo
    package.path = "/lib/?.lua;/usr/lib/?.lua;/home/lib/?.lua;./?.lua"
    for k in pairs(savedMods) do package.loaded[k] = nil end

    local okRun, errRun = pcall(function()
        local chunk, err = load(assert(__py_read_file(mainPath)), "=" .. mainPath)
        assert(chunk, err)
        chunk("--check")
        assert(package.path:find(_G.__DTPF_ROOT .. "/?.lua", 1, true),
            "main.lua added its script directory to package.path under wrapped debug.getinfo")
        assert(package.loaded["lib.hardware"] ~= nil, "main.lua resolved and loaded lib.hardware")
    end)

    debug.getinfo = origGetInfo
    package.path = origPath
    for k, v in pairs(savedMods) do package.loaded[k] = v end
    if not okRun then error(errRun) end

    assertEq(#fsbCalls, 0, "main --check zero fluid StorageBus writes")
    assertEq(#isbCalls, 0, "main --check zero item StorageBus writes")
    for i = 1, #dtpfStates do
        assertEq(#dtpfStates[i].calls, 0, "main --check zero DTPF writes #" .. i)
    end

    -- Verify `main.lua --lock` evicts stale package.loaded modules and forces autoPull=false
    local apFlag = true
    component._register("lock-h1", "me_inputhatch", {
        getAutoPull = function() return apFlag end,
        setAutoPull = function(v) apFlag = v; return true end,
    })
    local savedMods2 = {
        ["lib.hardware"] = package.loaded["lib.hardware"],
        ["lib.scheduler"] = package.loaded["lib.scheduler"],
        ["lib.ui"] = package.loaded["lib.ui"],
        ["lib.recipes_db"] = package.loaded["lib.recipes_db"],
    }
    package.loaded["lib.hardware"] = { stale = true }
    local chunkLock, errLock = load(assert(__py_read_file(mainPath)), "=" .. mainPath)
    assert(chunkLock, errLock)
    local okLock, lockErr = pcall(function()
        chunkLock("--lock")
    end)
    assert(okLock, "main --lock succeeded despite stale package.loaded: " .. tostring(lockErr))
    assertEq(apFlag, false, "main --lock sets autoPull=false")

    -- Verify loadConfig() still loads config.cfg even when filesystem.exists returns false (stale OpenOS dir cache)
    local fs = require("filesystem")
    local origExists = fs.exists
    local origPrint = _G.print
    local cfgPath = _G.__DTPF_ROOT .. "/config.cfg"
    __py_write_file(cfgPath, "{armed=false,globalConvMode=\"ondemand\"}")
    fs.exists = function(p)
        if p == cfgPath then return false end
        return origExists(p)
    end
    local captured = {}
    _G.print = function(...)
        local parts = {}
        for j = 1, select("#", ...) do parts[j] = tostring(select(j, ...)) end
        captured[#captured + 1] = table.concat(parts, "\t")
        origPrint(...)
    end
    local okChk, chkErr = pcall(function()
        chunkLock("--check")
    end)
    fs.exists = origExists
    _G.print = origPrint
    __py_remove_vfs(cfgPath)
    for k, v in pairs(savedMods2) do package.loaded[k] = v end
    assert(okChk, "main --check with cached-out config.cfg failed: " .. tostring(chkErr))
    local outBlob = table.concat(captured, "\n")
    assert(outBlob:find("(exists)", 1, true), "loadConfig reported config.cfg exists via io.open despite stale filesystem.exists")
    assert(outBlob:find("Conv=ondemand", 1, true), "loadConfig applied serialized config.cfg values despite stale filesystem.exists")
end

-- ============================================================================
-- TEST 16: 2-Way OC Transposer Catalyst Bridge & Multi-Line `subnets` Config
-- ============================================================================
do
    Hardware.resetClusterState()
    component._reset()

    local function makeEP16(x, y, z)
        local s = { autoPull = false, slots = {} }
        return {
            getCoordinates = function() return x, y, z end,
            getSlotSize = function() return 16 end,
            getAutoPull = function() return s.autoPull end,
            setAutoPull = function(v) s.autoPull = v; return true end,
            getConfiguration = function(slot) return s.slots[slot] end,
            setConfiguration = function(slot, d) s.slots[slot] = d; return true end,
        }
    end

    local function makeDualIFBridge(backingFluids, backingItems)
        local cfgCalls = {}
        local slotCfg = {}
        local tank = { name = nil, amount = 0 }

        local function syncTank()
            local c = slotCfg[1]
            if c and c.name then
                -- If another fluid was previously inside internal tank, return it first
                if tank.name and tank.name ~= c.name and tank.amount > 0 then
                    backingFluids[tank.name] = (backingFluids[tank.name] or 0) + tank.amount
                    tank.amount = 0
                end
                tank.name = c.name
                local want = 64000 - tank.amount
                local have = backingFluids[c.name] or 0
                local pull = math.min(want, have)
                if pull > 0 then
                    backingFluids[c.name] = have - pull
                    tank.amount = tank.amount + pull
                end
            else
                if tank.name and tank.amount > 0 then
                    backingFluids[tank.name] = (backingFluids[tank.name] or 0) + tank.amount
                end
                tank.name = nil
                tank.amount = 0
            end
        end

        local netProxy = makeAENet(backingFluids, backingItems)
        netProxy.setFluidInterfaceConfiguration = function(slot, detail)
            cfgCalls[#cfgCalls + 1] = { slot, detail and detail.name or nil }
            slotCfg[slot] = detail
            syncTank()
            return true
        end
        return netProxy, { cfgCalls = cfgCalls, tank = tank, sync = syncTank, fluids = backingFluids }
    end

    local stockFluids = {
        exciteddtcc = 500000, exciteddtpc = 500000, exciteddtrc = 500000,
        exciteddtec = 5000000, exciteddtsc = 500000,
        dimensionallytranscendentresidue = 20000000,
        ["molten.iron"] = 10000000,
        ["molten.neutronium"] = 30000000000,
        ["molten.cosmicneutronium"] = 10000000000,
        ["molten.bedrockium"] = 30000000000,
        ["molten.hypogen"] = 500000000,
        ["molten.spacetime"] = 600000000,
        ["molten.celestialtungsten"] = 30000000000,
        ["molten.transcendentmetal"] = 30000000000,
        ["molten.shirabon"] = 5000000,
        ["molten.infinity"] = 60000000000,
    }
    local stockItems = {
        ["gregtech:gt.metaitem.01:32415"] = 5000000,
        ["miscutils:MU-metaitem.01:32105"] = 100000,
        ["Avaritia:Resource:5"] = 100000,
        ["minecraft:cobblestone:0"] = 100000,
    }
    local odFluids = {}
    local odItems = {}

    local stockIf, stockIfSt = makeDualIFBridge(stockFluids, stockItems)
    local odIf, odIfSt = makeDualIFBridge(odFluids, odItems)
    component._register("t16-stock-if", "fluid_interface", stockIf)
    component._register("t16-od-if", "fluid_interface", odIf)

    local tpCalls = {}
    local function sideObj(side)
        if side == 1 then return stockIfSt end
        if side == 0 then return odIfSt end
        return nil
    end
    local tpProxy = {
        getTankLevel = function(side, tankNum)
            local obj = sideObj(side)
            if not obj then return 0 end
            obj.sync()
            return (obj.tank and obj.tank.amount) or 0
        end,
        transferFluid = function(srcSide, dstSide, count)
            tpCalls[#tpCalls + 1] = { srcSide, dstSide, count }
            local src = sideObj(srcSide)
            local dst = sideObj(dstSide)
            if not src or not dst then return false, 0 end
            src.sync()
            if not src.tank.name or src.tank.amount <= 0 then
                return false, 0
            end
            local moved = math.min(src.tank.amount, math.max(1, math.floor(count)))
            local fname = src.tank.name
            src.tank.amount = src.tank.amount - moved
            src.sync()
            -- Receiving ME Dual Interface inserts directly into its AE2 grid (`DualityFluidInterface.fill`)
            dst.fluids[fname] = (dst.fluids[fname] or 0) + moved
            dst.sync()
            return true, moved
        end,
    }
    component._register("t16-tp", "transposer", tpProxy)

    local dtpfStates16 = {}
    for i = 1, 5 do
        local r, c = math.floor((i - 1) / 2) + 1, ((i - 1) % 2) + 1
        local x, z = (c == 1 and 25 or 53), 82 + (r - 1) * 28
        local dp, ds = makeDTPF("t16-d" .. i, x, 67, z, { discountPct = 50 })
        component._register("t16-d" .. i, "dtpf", dp)
        component._register("t16-h" .. i, "me_inputhatch", makeEP16(x + 9, 65, z + 8))
        component._register("t16-b" .. i, "me_inputbus", makeEP16(x + 9, 65, z + 9))
        dtpfStates16[i] = ds
    end

    local cfg = Scheduler.ensureConfig({ stockNetAddr = "t16-stock-if", onDemandNetAddr = "t16-od-if" })
    Scheduler.syncHardware(cfg)
    assertEq(cfg.transposerAddr, "t16-tp", "T16 discovered Transposer address")
    assertEq(cfg.subnets.passive.interfaceAddr, "t16-stock-if", "T16 synced subnets.passive.interfaceAddr")
    assertEq(cfg.subnets.onDemand.interfaceAddr, "t16-od-if", "T16 synced subnets.onDemand.interfaceAddr")
    assertEq(cfg.subnets.transposer.address, "t16-tp", "T16 synced subnets.transposer.address")

    cfg.fallbackEnabled = false
    cfg.armed = true
    local st = {}

    -- Phase A: Zero steady-state overhead when all DTPFs are at 50% discount
    Scheduler.step(cfg, st)
    assertEq(st.odBridgeStatus, "Idle (0 calls)", "T16 Phase A1 idle reports 0 calls")
    assertEq(#tpCalls, 0, "T16 Phase A1 made 0 Transposer calls when idle")
    assertEq(#stockIfSt.cfgCalls, 0, "T16 Phase A1 made 0 Stock IF config calls")
    assertEq(#odIfSt.cfgCalls, 0, "T16 Phase A1 made 0 OD IF config calls")

    -- A2: 1 batch SC Base UMV with exact 50% catalyst (39,212 L) -> 0 calls, Convergence ON
    local function setOdScUmv(batches, catL)
        for k in pairs(odFluids) do odFluids[k] = nil end
        odFluids["molten.spacetime"] = 7776 * batches
        odFluids["molten.orundum"] = 3888 * batches
        odFluids["molten.hypogen"] = 14256 * batches
        odFluids["molten.titansteel"] = 6480 * batches
        odFluids["molten.dragonblood"] = 2592 * batches
        odFluids["plasma.oxygen"] = 1296 * batches
        odFluids["exciteddtec"] = (catL and catL > 0) and catL or nil
    end
    setOdScUmv(1, 39212)
    Scheduler.step(cfg, st)
    assertEq(st.odBridgeStatus, "Ready (0 overhead)", "T16 Phase A2 1-batch 50% patterned OD -> 0 overhead")
    assertEq(#tpCalls, 0, "T16 Phase A2 made 0 Transposer calls")
    assertEq(#stockIfSt.cfgCalls, 0, "T16 Phase A2 made 0 Stock IF calls")
    assertEq(dtpfStates16[1].conv, true, "T16 Phase A2 1-batch auto_safe enables Convergence")

    -- A3: 10 batches SC Base UMV with 50% catalyst -> 0 calls AND auto_safe protects batch #2..10 by staying 2x
    setOdScUmv(10, 392120)
    Scheduler.step(cfg, st)
    assertEq(st.odBridgeStatus, "Ready (0 overhead)", "T16 Phase A3 10-batch 50% patterned OD -> 0 overhead")
    assertEq(#tpCalls, 0, "T16 Phase A3 made 0 Transposer calls")
    assertEq(dtpfStates16[1].conv, false, "T16 Phase A3 multi-batch auto_safe keeps Convergence OFF to prevent catalyst stealing")

    -- A4: Molten Shirabon (NONE catalyst) -> 0 calls
    for k in pairs(odFluids) do odFluids[k] = nil end
    odFluids["molten.metastable oganesson"] = 1152
    odFluids["molten.precious metals alloy"] = 2304
    odFluids["molten.spacetime"] = 288
    odFluids["dimensionallytranscendentresidue"] = 5000
    Scheduler.step(cfg, st)
    assertEq(st.odBridgeStatus, "Idle (No-Cat OD)", "T16 Phase A4 NONE recipe -> Idle (No-Cat OD)")
    assertEq(#tpCalls, 0, "T16 Phase A4 made 0 Transposer calls on NONE recipe")

    -- Phase B: 46 batches of SC Base UMV with 0L catalyst at 0% discount -> chunked Passive -> OD top-up (max 2 batches buffer)
    dtpfStates16[1].discountPct = 0
    setOdScUmv(46, 0)
    local stockDtecStart = stockFluids["exciteddtec"]
    Scheduler.step(cfg, st)
    assertEq(odFluids["exciteddtec"], 5120, "T16 Phase B chunk #1 moved 5,120L into OD")
    assertEq(stockIfSt.tank.name, "exciteddtec", "T16 Phase B configured Stock IF Slot 1 during top-up")
    for sStep = 2, 40 do
        Scheduler.step(cfg, st)
        if stockIfSt.tank.name == nil then break end
    end
    assertEq(odFluids["exciteddtec"], 156848, "T16 Phase B topped up 2-batch buffer (156,848L) so 46-batch craft starts fast")
    assertEq(stockIfSt.tank.name, nil, "T16 Phase B cleared Stock IF Slot 1 back to nil once buffer satisfied")
    assertEq(stockFluids["exciteddtec"], stockDtecStart - 156848, "T16 Phase B deducted exact 156,848L from Main Net")

    -- Phase B2: 50%-encoded craft running on 25% discount DTPF tops up only the 19,606L deficit
    for i = 1, 5 do dtpfStates16[i].discountPct = 50 end
    dtpfStates16[2].discountPct = 25
    setOdScUmv(1, 39212)
    -- Step 1 waits 1 poll grace for 50% DTPF before pulling catalyst for 25% DTPF
    Scheduler.step(cfg, st)
    assertEq(st.odBridgeStatus, "Wait 1 poll (50% DTPF ready)", "T16 Phase B2 waits 1 poll in mixed 50%/25% fleet")
    for sStep = 1, 10 do
        Scheduler.step(cfg, st)
        if odFluids["exciteddtec"] >= 58818 and stockIfSt.tank.name == nil then break end
    end
    assertEq(odFluids["exciteddtec"], 58818, "T16 Phase B2 topped up exact 25%-discount deficit (39212 -> 58818L)")
    assertEq(stockIfSt.tank.name, nil, "T16 Phase B2 cleared Stock IF Slot 1 after top-up")

    -- Phase C: Excess catalyst drain-out when OD is idle (`0` items & `0` non-catalyst fluids)
    for k in pairs(odFluids) do odFluids[k] = nil end
    odFluids["exciteddtec"] = 8000
    local stockBeforeDrain = stockFluids["exciteddtec"]
    local tpBeforeDrain = #tpCalls

    -- Poll 1 holds against AE2 push race
    Scheduler.step(cfg, st)
    assertEq(st.odBridgeStatus, "Hold (verifying OD idle)", "T16 Phase C poll 1 holds before draining excess catalyst")
    assertEq(#tpCalls, tpBeforeDrain, "T16 Phase C poll 1 made 0 Transposer calls")

    -- Poll 2 opens OD Dual IF Slot 1 (pulling all 8,000L into internal tank!) and drains 5,120L
    Scheduler.step(cfg, st)
    assertEq(odIfSt.tank.name, "exciteddtec", "T16 Phase C poll 2 keeps OD IF Slot 1 open while 2,880L remains in tank")
    assertEq(odIfSt.tank.amount, 2880, "T16 Phase C poll 2 left exact 2,880L in OD IF internal tank")

    -- Poll 3 drains remaining 2,880L and clears OD IF Slot 1 cleanly
    Scheduler.step(cfg, st)
    assertEq(odIfSt.tank.name, nil, "T16 Phase C poll 3 cleared OD IF Slot 1 once tank & OD net hit 0")
    assertEq(odFluids["exciteddtec"] or 0, 0, "T16 Phase C drained 100% of excess OD catalyst")
    assertEq(stockFluids["exciteddtec"], stockBeforeDrain + 8000, "T16 Phase C returned all 8,000L back to Main Net")
    assertEq(st.odBridgeStatus, "Idle (Drained clean)", "T16 Phase C reported Drained clean")

    -- Poll 4 verifies return to 0-call steady state
    local tpAfterDrain = #tpCalls
    Scheduler.step(cfg, st)
    assertEq(#tpCalls, tpAfterDrain, "T16 Phase C poll 4 back to 0 Transposer calls")
    assertEq(st.odBridgeStatus, "Idle (0 calls)", "T16 Phase C poll 4 Idle (0 calls)")

    -- Phase D: Tab 4 Catalyst Bridge UI render, Zero-Call Diff Re-Render & Multi-line `config.cfg` save & reload
    local gpu16 = component._newMockGPU(160, 50)
    local ui16 = UI.new(cfg, st)
    ui16.tab = 2
    ui16:render()
    local tab1Calls = #gpu16._calls
    ui16:render()
    assertEq(#gpu16._calls, tab1Calls, "T16 Phase D unchanged Tab 2 re-render emits 0 GPU calls")

    ui16:setStatus("Updated footer check")
    ui16:render()
    local statusDelta = #gpu16._calls - tab1Calls
    assert(statusDelta >= 1 and statusDelta <= 4,
        "T16 Phase D footer status change emits <= 4 GPU calls (got " .. tostring(statusDelta) .. ")")
    assert(gpu16._rowText(50):find("Updated footer check", 1, true),
        "T16 Phase D incremental flush updated footer text on row 50")

    ui16.tab = 4
    ui16:render()
    local tab3BridgeTxt = gpu16._allText()
    assert(tab3BridgeTxt:find("Bridge (TP):", 1, true), "T16 Tab 4 renders Catalyst Bridge row")
    assert(tab3BridgeTxt:find("t16-tp", 1, true), "T16 Tab 4 displays discovered Transposer address")
    local tab3Calls = #gpu16._calls
    ui16:render()
    assertEq(#gpu16._calls, tab3Calls, "T16 Phase D unchanged Tab 4 re-render emits 0 GPU calls")
    for _, s in ipairs(gpu16._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    local gpuMain16 = component._newMockGPU(160, 50)
    local evQ16 = require("event")._queue
    while #evQ16 > 0 do table.remove(evQ16) end
    -- Real 5-argument OC key_down events + post-Q sentinel to prove `q` exits cleanly via main.lua
    evQ16[1] = { "key_down", "kbd", string.byte("4"), 5, "TestPlayer" }
    evQ16[2] = { "key_down", "kbd", string.byte("q"), 16, "TestPlayer" }
    evQ16[3] = { "nebula_bogus_signal", "after_q" }
    component.gpu = gpuMain16
    local mainPath16 = _G.__DTPF_ROOT .. "/main.lua"
    local cfgPath16 = _G.__DTPF_ROOT .. "/config.cfg"
    local mChunk16, mErr16 = load(assert(__py_read_file(mainPath16)), "@" .. mainPath16)
    assert(mChunk16, mErr16)
    mChunk16()
    component.gpu = nil
    assertEq(#evQ16, 1, "T16 key_down 'q' exited main.lua cleanly before pulling post-Q sentinel")
    assertEq(evQ16[1][1], "nebula_bogus_signal", "T16 remaining queued event is post-Q sentinel")
    while #evQ16 > 0 do table.remove(evQ16) end
    assert(gpuMain16._allText():find("DISCOVERED DTPF CONTROLLERS", 1, true),
        "T16 key_down '3' switched main.lua GUI to Tab 3 before 'q'")

    local savedRaw16 = __py_read_file(cfgPath16)
    assert(savedRaw16 ~= nil, "T16 saved multi-line config.cfg")
    assert(savedRaw16:find("subnets = {", 1, true), "T16 config.cfg includes subnets section")
    assert(savedRaw16:find("passive = {", 1, true), "T16 config.cfg includes passive subnet section")
    assert(savedRaw16:find("onDemand = {", 1, true), "T16 config.cfg includes onDemand subnet section")
    assert(savedRaw16:find("transposer = {", 1, true), "T16 config.cfg includes transposer bridge section")
    assert(savedRaw16:find("passiveHatchAddr =", 1, true), "T16 config.cfg organizes passiveHatchAddr per-DTPF")
    assert(not savedRaw16:find("\n  channels = {", 1, true), "T16 omits duplicate channels section in 1:1 MFU mode")

    local parsed16 = serialization.unserialize(savedRaw16)
    assert(type(parsed16) == "table", "T16 OpenOS serialization.unserialize parses multi-line config.cfg")
    assertEq(parsed16.subnets.transposer.address, "t16-tp", "T16 parsed subnets.transposer.address cleanly")
    assertEq(parsed16.subnets.passive.interfaceAddr, "t16-stock-if", "T16 parsed subnets.passive.interfaceAddr cleanly")
    assertEq(parsed16.subnets.onDemand.interfaceAddr, "t16-od-if", "T16 parsed subnets.onDemand.interfaceAddr cleanly")
    assertEq(#parsed16.dtpfs, 5, "T16 parsed all 5 DTPFs cleanly")
    assertEq(parsed16.dtpfs[1].passiveHatchAddr, "t16-h1", "T16 parsed DTPF #1 passiveHatchAddr cleanly")

    local loaded16 = Scheduler.ensureConfig(parsed16)
    assertEq(loaded16.transposerAddr, "t16-tp", "T16 ensureConfig hydrated transposerAddr")
    assertEq(loaded16.channels[1].hatchAddr, "t16-h1", "T16 ensureConfig hydrated ch1 hatchAddr from DTPF #1")
    mChunk16("--check")
    __py_remove_vfs(cfgPath16)
end

-- ============================================================================
-- TEST 17: Unified Forever Priority Queue, Spread-First Parallelism, Dark Matter,
--          and Stalled-OD Auto-Bypass (zero flapping + UI banner)
-- ============================================================================
do
    Hardware.resetClusterState()
    component._reset()

    local RecipesDB17 = require("lib.recipes_db")
    assertEq(RecipesDB17.BY_ID["meteoric_iron_rock"].name, "Dark Matter",
        "T17 renamed meteoric_iron_rock display name -> Dark Matter")

    local function makeEP17(x, y, z)
        local s = { autoPull = false, slots = {} }
        return {
            getCoordinates = function() return x, y, z end,
            getSlotSize = function() return 16 end,
            getAutoPull = function() return s.autoPull end,
            setAutoPull = function(v) s.autoPull = v; return true end,
            getConfiguration = function(slot) return s.slots[slot] end,
            setConfiguration = function(slot, d) s.slots[slot] = d; return true end,
        }
    end

    local fluids = {
        exciteddtcc = 5000000, exciteddtpc = 5000000, exciteddtrc = 5000000,
        exciteddtec = 5000000, exciteddtsc = 5000000,
        dimensionallytranscendentresidue = 20000000,
        ["molten.iron"] = 10000000,
        ["molten.steel"] = 10000000,
        ["molten.neutronium"] = 0,
        ["molten.bedrockium"] = 0,
        ["molten.infinity"] = 0,
    }
    local items = {
        ["Avaritia:Resource:5"] = 100000,
        ["minecraft:cobblestone:0"] = 100000,
    }
    local odFluids, odItems = {}, {}
    component._register("t17-stock", "me_controller", makeAENet(fluids, items))
    component._register("t17-od", "me_interface", makeAENet(odFluids, odItems))

    local dtpfStates = {}
    for i = 1, 5 do
        local r, c = math.floor((i - 1) / 2) + 1, ((i - 1) % 2) + 1
        local x, z = (c == 1 and 25 or 53), 82 + (r - 1) * 28
        local dp, ds = makeDTPF(string.format("t17-d%02d", i), x, 67, z, { coilHeat = 13500, discountPct = 50 })
        component._register(string.format("t17-d%02d", i), "dtpf", dp)
        component._register(string.format("t17-h%02d", i), "me_inputhatch", makeEP17(x + 2, 66, z + 1))
        component._register(string.format("t17-b%02d", i), "me_inputbus", makeEP17(x - 2, 66, z + 1))
        dtpfStates[i] = ds
    end

    local cfg = Scheduler.ensureConfig({})
    Scheduler.syncHardware(cfg)
    assertEq(#cfg.channels, 5, "T17 discovered 5 Hatch/Bus channels")

    for _, rc in pairs(cfg.recipes) do
        rc.enabled = false
        rc.forever = false
    end
    cfg.recipes["molten_neutronium"].enabled = true
    cfg.recipes["molten_neutronium"].priority = 1
    cfg.recipes["molten_neutronium"].target = 10000000
    cfg.recipes["molten_bedrockium"].enabled = true
    cfg.recipes["molten_bedrockium"].priority = 2
    cfg.recipes["molten_bedrockium"].target = 10000000
    cfg.recipes["molten_infinity"].enabled = true
    cfg.recipes["molten_infinity"].forever = true
    cfg.recipes["molten_infinity"].modifierIndex = 1
    cfg.recipes["molten_infinity"].priority = 3
    cfg.allowParallelSameRecipe = true
    cfg.fallbackEnabled = false
    cfg.pausePassivesOnOD = true
    cfg.armed = true

    -- Pass 1 spreads across all 3 distinct enabled recipes; Pass 2 parallelizes <Tgt before doubling 24/7
    local st = {}
    Scheduler.step(cfg, st)
    assertEq(st.channelStatus["ch1"].familyId, "molten_neutronium", "T17 ch1 runs prio #1 Neutronium (<Tgt)")
    assertEq(st.channelStatus["ch1"].mode, "PASSIVE", "T17 ch1 mode is PASSIVE")
    assertEq(st.channelStatus["ch2"].familyId, "molten_bedrockium", "T17 ch2 spreads to prio #2 Bedrockium (<Tgt)")
    assertEq(st.channelStatus["ch2"].mode, "PASSIVE", "T17 ch2 mode is PASSIVE")
    assertEq(st.channelStatus["ch3"].familyId, "molten_infinity", "T17 ch3 spreads to prio #3 24/7 Infinity")
    assertEq(st.channelStatus["ch3"].mode, "FALLBACK", "T17 ch3 mode is FALLBACK (24/7 loop)")
    assertEq(st.channelStatus["ch4"].familyId, "molten_neutronium", "T17 ch4 parallelizes <Tgt Neutronium before doubling 24/7")
    assertEq(st.channelStatus["ch5"].familyId, "molten_bedrockium", "T17 ch5 parallelizes <Tgt Bedrockium before doubling 24/7")

    -- Once <Tgt targets are satisfied, all 5 channels converge on 24/7 Infinity loop
    fluids["molten.neutronium"] = 50000000
    fluids["molten.bedrockium"] = 50000000
    Scheduler.step(cfg, st)
    for k = 1, 5 do
        local chSt = st.channelStatus["ch" .. k]
        assertEq(chSt.familyId, "molten_infinity", "T17 ch" .. k .. " shifts to 24/7 Infinity after <Tgt met")
        assertEq(chSt.mode, "FALLBACK", "T17 ch" .. k .. " mode is FALLBACK")
    end

    -- Stalled-OD Auto-Bypass: stalled SC Base UMV (0 active DTPFs) triggers bypass after 4 polls
    fluids["molten.neutronium"] = 0
    odFluids["molten.spacetime"] = 7776
    odFluids["molten.orundum"] = 3888
    odFluids["molten.hypogen"] = 14256
    odFluids["molten.titansteel"] = 6480
    odFluids["molten.dragonblood"] = 2592
    odFluids["plasma.oxygen"] = 1296
    odFluids["exciteddtec"] = 39212
    for sStep = 1, 3 do
        Scheduler.step(cfg, st)
        assertEq(st.odStalled == true, false, "T17 OD stall grace step " .. sStep .. " waits before bypass")
        assertEq(st.channelStatus["ch1"].mode, "ON-DEMAND", "T17 ch1 holds in ON-DEMAND during grace step " .. sStep)
    end
    Scheduler.step(cfg, st)
    assertEq(st.odStalled, true, "T17 step 4 sets st.odStalled = true")
    assertEq(st.onDemand.stalled, true, "T17 step 4 sets st.onDemand.stalled = true")
    assertEq(st.channelStatus["ch1"].mode, "PASSIVE", "T17 step 4 unblocks ch1 into PASSIVE")
    assertEq(st.channelStatus["ch1"].familyId, "molten_neutronium", "T17 step 4 ch1 runs Molten Neutronium")
    local sawOdStallBn = false
    for _, bn in ipairs(st.bottlenecks or {}) do
        if bn.kind == "od_stall" and tostring(bn.reason or ""):find("Circuit", 1, true) then
            sawOdStallBn = true
            break
        end
    end
    assert(sawOdStallBn, "T17 records od_stall bottleneck mentioning Circuit")

    -- Step 5: Passive DTPF #1 goes active=true -> must NOT clear odStalled (zero flapping!)
    dtpfStates[1].active = true
    dtpfStates[1].maxProgress = 100
    Scheduler.step(cfg, st)
    assertEq(st.odStalled, true, "T17 Passive DTPF running does not flap st.odStalled back to false")
    assertEq(st.channelStatus["ch1"].mode, "PASSIVE", "T17 ch1 stays PASSIVE with zero flapping")

    local gpu17 = component._newMockGPU(160, 50)
    local ui17 = UI.new(cfg, st)
    ui17.tab = 2
    ui17:render()
    assert(gpu17._rowText(2):find("OD STALLED", 1, true) ~= nil, "T17 header Row 2 displays OD STALLED warning banner")
    for _, s in ipairs(gpu17._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    -- Step 6: Clear OD net -> resets st.odStalled cleanly
    for k in pairs(odFluids) do odFluids[k] = nil end
    Scheduler.step(cfg, st)
    assertEq(st.odStalled, false, "T17 clearing OD fluids resets st.odStalled = false")

    -- Verify NC item warning path specifically names Programmed Circuit #6 when SC Base LuV stalls
    dtpfStates[1].active = false
    dtpfStates[1].maxProgress = 0
    odFluids["molten.indium"] = 157248
    odFluids["molten.tin"] = 78624
    odFluids["molten.barium"] = 78624
    odFluids["molten.titanium"] = 39312
    odFluids["molten.copper"] = 275184
    odFluids["plasma.oxygen"] = 119301
    odFluids["exciteddtec"] = 10000
    for _ = 1, 4 do Scheduler.step(cfg, st) end
    local sawCirc6 = false
    for _, bn in ipairs(st.bottlenecks or {}) do
        if bn.kind == "od_stall" and tostring(bn.reason or ""):find("Programmed Circuit #6", 1, true) then
            sawCirc6 = true
            break
        end
    end
    assert(sawCirc6, "T17 od_stall bottleneck names missing non-consumed Programmed Circuit #6")

    Hardware.resetClusterState()
    component._reset()
end

-- ============================================================================
-- TEST 18: Sensor Throttle, Single-Output DTR Filter, maxDtpfs Cap, Stalled Passive & Warmup ETA
-- ============================================================================
do
    component._reset()
    local RecipesDB = require("lib.recipes_db")
    local fluids = {
        exciteddtcc = 5000000, exciteddtpc = 5000000, exciteddtrc = 5000000,
        exciteddtec = 5000000, exciteddtsc = 5000000,
        dimensionallytranscendentresidue = 50000000,
        ["molten.iron"] = 10000000,
        ["molten.steel"] = 10000000,
        ["molten.neutronium"] = 0,
        ["molten.bedrockium"] = 0,
        ["molten.shirabon"] = 0,
        ["molten.infinity"] = 0,
    }
    local items = {
        ["gregtech:gt.metaitem.01:32415"] = 1000,
        ["miscutils:MU-metaitem.01:32105"] = 64,
        ["Avaritia:Resource:5"] = 1000,
        ["minecraft:cobblestone:0"] = 1000,
    }
    component._register("t18-stock", "me_controller", makeAENet(fluids, items))
    component._register("t18-od", "me_interface", makeAENet({}, {}))

    local function makeEP18(x, y, z)
        local s = { autoPull = true, slots = {} }
        return {
            getCoordinates = function() return x, y, z end,
            getSlotSize = function() return 16 end,
            getAutoPull = function() return s.autoPull end,
            setAutoPull = function(v) s.autoPull = v; return true end,
            getConfiguration = function(slot) return s.slots[slot] end,
            setConfiguration = function(slot, d) s.slots[slot] = d; return true end,
        }
    end

    local dtpfStates, dpProxies = {}, {}
    local sensorCalls = 0
    for i = 1, 5 do
        local x, z = 20 + i * 10, 60
        local dp, ds = makeDTPF(string.format("t18-d%02d", i), x, 67, z, { coilHeat = 13500, discountPct = (i == 1 and 10 or 50) })
        if i == 1 then
            local origSensor = dp.getSensorInformation
            dp.getSensorInformation = function()
                sensorCalls = sensorCalls + 1
                return origSensor()
            end
        end
        dpProxies[i] = dp
        dtpfStates[i] = ds
        component._register(string.format("t18-d%02d", i), "dtpf", dp)
        component._register(string.format("t18-h%02d", i), "me_inputhatch", makeEP18(x + 2, 66, z + 1))
        component._register(string.format("t18-b%02d", i), "me_inputbus", makeEP18(x - 2, 66, z + 1))
    end

    -- 18a: allowSensorCache throttles getSensorInformation to every 5th poll unless state/conv changes
    local entry1 = { dtpfProxy = dpProxies[1], gtProxy = dpProxies[1], isLocal = true }
    Hardware.getDTPFStatus(entry1, { allowSensorCache = true })
    assertEq(sensorCalls, 1, "T18a poll 1 reads getSensorInformation")
    for _ = 2, 5 do
        Hardware.getDTPFStatus(entry1, { allowSensorCache = true })
    end
    assertEq(sensorCalls, 1, "T18a polls 2..5 use cached sensor info")
    Hardware.getDTPFStatus(entry1, { allowSensorCache = true })
    assertEq(sensorCalls, 2, "T18a poll 6 refreshes sensor info")
    Hardware.setLocalDTPFConvergence(entry1, true, 4)
    Hardware.getDTPFStatus(entry1, { allowSensorCache = true })
    assertEq(sensorCalls, 3, "T18a convergence change invalidates sensor cache immediately")

    -- 18b: Scheduler.getOutputCandidates excludes byproduct DTR + Tab 2 hides Tracked Output on single-output recipes
    local cfg = Scheduler.ensureConfig({})
    cfg.fallbackEnabled = false
    Scheduler.syncHardware(cfg)
    local rtFam = RecipesDB.BY_ID["raw_tesseract"]
    local _, _, _, rtData = Scheduler.resolveRecipe(rtFam, cfg.recipes["raw_tesseract"], cfg, { fluids = fluids, items = items }, { wantConvergence = false })
    local rtOuts = Scheduler.getOutputCandidates(rtData, rtFam)
    assertEq(#rtOuts, 1, "T18b raw_tesseract has single tracked output (DTR excluded)")
    assertEq(rtOuts[1].label, "Raw Tesseract", "T18b single tracked output is Raw Tesseract")

    -- 18c: Per-recipe maxDtpfs parallel cap + Tab 2 contextual Max:[N DTPF] button & Conv Cat hiding
    for _, rc in pairs(cfg.recipes) do rc.enabled = false; rc.forever = false end
    cfg.recipes["molten_neutronium"].enabled = true
    cfg.recipes["molten_neutronium"].priority = 1
    cfg.recipes["molten_neutronium"].target = 50000000
    cfg.recipes["molten_neutronium"].maxDtpfs = 2
    cfg.recipes["molten_bedrockium"].enabled = true
    cfg.recipes["molten_bedrockium"].priority = 2
    cfg.recipes["molten_bedrockium"].target = 50000000
    cfg.allowParallelSameRecipe = true
    cfg.armed = true

    local st = {}
    Scheduler.step(cfg, st, { nowUptime = 100 })
    assertEq(st.channelStatus["ch1"].familyId, "molten_neutronium", "T18c ch1 runs prio 1 neutronium")
    assertEq(st.channelStatus["ch2"].familyId, "molten_bedrockium", "T18c Pass 1 covers distinct prio 2 bedrockium on ch2")
    local neutCnt, bedCnt = 0, 0
    for k = 1, 5 do
        local fid = st.channelStatus["ch" .. k].familyId
        if fid == "molten_neutronium" then neutCnt = neutCnt + 1
        elseif fid == "molten_bedrockium" then bedCnt = bedCnt + 1 end
    end
    assertEq(neutCnt, 2, "T18c Pass 2 caps neutronium at maxDtpfs = 2 across 5 channels")
    assertEq(bedCnt, 3, "T18c spare channels beyond maxDtpfs=2 spill cleanly into bedrockium")

    local gpu18 = component._newMockGPU(160, 50)
    local ui18 = UI.new(cfg, st)
    ui18.tab = 3
    ui18.selectedFamilyId = "raw_tesseract"
    ui18:render()
    local rtTxt = gpu18._allText()
    assert(not rtTxt:find("Tracked Output:", 1, true), "T18b Tab 2 hides Tracked Output on single-product Raw Tesseract")
    assert(rtTxt:find("Dimensionally Transcendent Residue", 1, true), "T18b Tab 2 still displays byproduct DTR under OUTPUTS:")

    cfg.recipes["quantum_anomaly"].convMode = "off"
    ui18.selectedFamilyId = "quantum_anomaly"
    ui18:render()
    assert(not gpu18._allText():find("Conv Cat:", 1, true), "T18c Tab 2 hides Conv Cat when NONE + 4x Policy OFF")

    ui18.selectedFamilyId = "molten_neutronium"
    ui18:render()
    assert(gpu18._rowText(9):find("[Max:2 DTPF]", 1, true), "T18c Tab 2 Row 9 displays contextual [Max:2 DTPF] when allowParallelSameRecipe=true")
    cfg.allowParallelSameRecipe = false
    ui18:render()
    assert(not gpu18._rowText(9):find("[Max:", 1, true), "T18c Tab 2 Row 9 hides Max cap when allowParallelSameRecipe=false")

    -- 18d: Passive stall detection after 4 armed polls following job assignment at 0/0 progress
    for p = 1, 4 do
        Scheduler.step(cfg, st, { nowUptime = 100 + p * 5 })
    end
    assertEq(st.dtpfStatus[1].passiveStalled, false, "T18d not prematurely stalled before 4 idle polls post-assignment")
    Scheduler.step(cfg, st, { nowUptime = 125 })
    assertEq(st.dtpfStatus[1].passiveStalled, true, "T18d DTPF #1 flagged passiveStalled after 4 idle armed polls")
    local sawPassiveStall = false
    for _, bn in ipairs(st.bottlenecks or {}) do
        if bn.kind == "passive_stall" then sawPassiveStall = true break end
    end
    assert(sawPassiveStall, "T18d emits passive_stall bottleneck")
    ui18.tab = 2
    ui18:render()
    assert(gpu18._allText():find("! STALLED", 1, true), "T18d Tab 2 card renders ! STALLED badge")

    -- 18e: GTNH 576k-tick warmup ETA + stock/DTR rates & Tab 1 rate UI
    dtpfStates[1].active = true
    dtpfStates[1].maxProgress = 100
    dtpfStates[1].progress = 20
    dtpfStates[1].discountPct = 10
    dtpfStates[1].ticks = 115200
    Scheduler.step(cfg, st, { nowUptime = 200 })
    dtpfStates[1].discountPct = 20
    dtpfStates[1].ticks = 230400
    fluids.dimensionallytranscendentresidue = 50005000
    fluids["molten.neutronium"] = 5000000
    Scheduler.step(cfg, st, { nowUptime = 260 })
    assertEq(st.dtpfStatus[1].passiveStalled, false, "T18e active DTPF clears passiveStalled")
    assert(st.dtrRatePerMin and math.abs(st.dtrRatePerMin - 5000) < 1e-6, "T18e tracks DTR rate/min (+5000L/m)")
    assert(st.dtpfStatus[1].warmupEtaSec and math.abs(st.dtpfStatus[1].warmupEtaSec - 17280) < 1,
        "T18e computes exact GTNH warmupEtaSec = 17280s (4.8h) at 20% discount / 230,400 ticks")
    assert(st.recipeStatus["molten_neutronium"].ratePerMin and st.recipeStatus["molten_neutronium"].etaSec,
        "T18e computes recipe craft ratePerMin and etaSec")
    ui18.tab = 2
    ui18:render()
    local cardTxt = gpu18._allText()
    assert(cardTxt:find("Disc:20% (4.8h)", 1, true), "T18e Tab 2 card renders Disc:20% (4.8h)")
    assert(gpu18._rowText(3):find("DTR:", 1, true) and gpu18._rowText(3):find("▲", 1, true), "T18e Row 3 renders DTR▲ rate arrow")
    for _, s in ipairs(gpu18._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    -- 18f: Block-letter DTPF CONTROL header, "by StankCIty" footer signature, and zero-overhead animation toggle
    assert(gpu18._rowText(1):find("█▀▀▄ ▀█▀ █▀▀▄ █▀▀▀", 1, true) and gpu18._rowText(2):find("█▄▄▀  █  █▀▀  █▀▀", 1, true),
        "T18f Header renders stylized 2-row block-letter DTPF CONTROL banner")
    assert(gpu18._rowText(50):find("by StankCIty", 1, true), "T18f Footer renders by StankCIty signature in bottom-right corner")

    -- Exercise all 8 animation frames across active/converging/looping modes and audit every glyph width
    dtpfStates[1].conv = true
    cfg.dtpfs[1].convOverride = "always"
    cfg.recipes["molten_bedrockium"].forever = true
    Scheduler.step(cfg, st, { nowUptime = 260 })
    for k = 1, 8 do
        ui18:advanceAnim(260 + k * 0.5)
        ui18:render()
        if k == 1 then
            assert(gpu18._allText():find("30%", 1, true), "T18f active progress bar smoothly interpolates between polls (20 -> 30 ticks)")
        end
        for _, s in ipairs(gpu18._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    end

    -- Click header [Anim] toggle button -> disables animations and resets animTick = 0 (zero GPU diff overhead)
    local clickedAnim = false
    for i = #ui18.hitboxes, 1, -1 do
        local hb = ui18.hitboxes[i]
        if hb.y1 == 1 and hb.y2 == 1 then
            local slice = unicode.sub(gpu18._rowText(1), hb.x1, hb.x2)
            if slice:find("Anim]", 1, true) then
                ui18:handleTouch(hb.x1, hb.y1, 0)
                ui18:render()
                clickedAnim = true
                break
            end
        end
    end
    assert(clickedAnim, "T18f clicked header [Anim] toggle button")
    assertEq(cfg.uiAnimations, false, "T18f clicking [Anim] disabled uiAnimations")
    assertEq(ui18.animTick, 0, "T18f disabling animations reset animTick = 0")
    assert(gpu18._rowText(1):find("[○ Anim]", 1, true), "T18f Header shows [○ Anim] when animations disabled")
    ui18:advanceAnim(270.0)
    local callsOff = #gpu18._calls
    ui18:render()
    assertEq(#gpu18._calls, callsOff, "T18f disabled animations advanceAnim + render emits 0 GPU calls")

    -- Hotkey 'a' toggles animations back ON
    ui18:handleKeyDown(string.byte("a"), 30)
    assertEq(cfg.uiAnimations, true, "T18f [A] hotkey re-enabled uiAnimations")

    -- 18g: Single-# status lists and zero unintended ellipsis clipping across all 27 recipes
    cfg.allowParallelSameRecipe = true
    cfg.recipes["molten_neutronium"].maxDtpfs = 0
    Scheduler.step(cfg, st, { nowUptime = 275 })
    ui18.tab = 2
    ui18:render()
    local qTxt = gpu18._allText()
    assert(qTxt:find("#1,", 1, true) and not qTxt:find(",#", 1, true), "T18g Tab 2 Queue uses single-# compact list (#1,2,...)")

    ui18.tab = 3
    ui18.selectedFamilyId = "molten_neutronium"
    ui18:render()
    assert(gpu18._rowText(9):find("Running on: #1,", 1, true) and not gpu18._rowText(9):find(",#", 1, true),
        "T18g Tab 3 Running on: uses single-# compact list")

    local RecipesDB18 = require("lib.recipes_db")
    for _, fam in ipairs(RecipesDB18.FAMILIES) do
        ui18.selectedFamilyId = fam.id
        ui18:render()
        for ry = 4, 48 do
            local r = unicode.sub(gpu18._rowText(ry), 85, 160)
            local clean = r:gsub("%[Pin to a DTPF…%]", ""):gsub("%[Custom…%]", ""):gsub("%[Target: [^%]]+…%]", "")
            assert(not clean:find("…", 1, true),
                string.format("T18g Tab 2 Right Inspector clipped (%s y=%d): %s", fam.id, ry, r))
        end
    end

    -- 18h: Default coilDisplayMode="name" + click-to-toggle across Tab 1, Tab 2, and Tab 3
    assertEq(cfg.coilDisplayMode, "name", "T18h coilDisplayMode defaults to 'name'")
    local function clickSlice18(needle, yMin, yMax, xMin, xMax)
        for i = #ui18.hitboxes, 1, -1 do
            local hb = ui18.hitboxes[i]
            if hb.y1 >= (yMin or 1) and hb.y2 <= (yMax or 50)
               and hb.x1 >= (xMin or 1) and hb.x2 <= (xMax or 160) then
                local row = gpu18._rowText(hb.y1)
                local slice = unicode.sub(row, hb.x1, hb.x2)
                if slice:find(needle, 1, true) then
                    ui18:handleTouch(hb.x1, hb.y1, 0)
                    ui18:render()
                    for _, s in ipairs(gpu18._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
                    return true
                end
            end
        end
        return false
    end

    ui18.tab = 2
    ui18:render()
    for _, s in ipairs(gpu18._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    local t1NameTxt = gpu18._allText()
    assert(t1NameTxt:find("Eternal", 1, true), "T18h Tab 2 cards show Eternal tier name by default")
    assert(not t1NameTxt:find("13,500K", 1, true) and not t1NameTxt:find("13.5kK", 1, true),
        "T18h Tab 2 cards hide Kelvin temp while in 'name' mode")
    assert(clickSlice18("Eternal", 10, 46, 2, 79), "T18h clicked on-card Eternal coil readout")
    assertEq(cfg.coilDisplayMode, "temp", "T18h clicking card coil switched coilDisplayMode -> 'temp'")
    local t1TempTxt = gpu18._allText()
    assert(t1TempTxt:find("13,500K", 1, true) or t1TempTxt:find("13.5kK", 1, true),
        "T18h Tab 2 cards show Kelvin temp after toggling")
    local beforeIdleCalls = #gpu18._calls
    ui18:render()
    assertEq(#gpu18._calls, beforeIdleCalls, "T18h idle re-render in temp mode emits 0 GPU calls")

    ui18.tab = 3
    for _, fam in ipairs(RecipesDB18.FAMILIES) do
        ui18.selectedFamilyId = fam.id
        ui18:render()
        for ry = 4, 48 do
            local r = unicode.sub(gpu18._rowText(ry), 85, 160)
            local clean = r:gsub("%[Pin to a DTPF…%]", ""):gsub("%[Custom…%]", ""):gsub("%[Target: [^%]]+…%]", "")
            assert(not clean:find("…", 1, true),
                string.format("T18h Tab 3 Right Inspector clipped in temp mode (%s y=%d): %s", fam.id, ry, r))
        end
    end
    ui18.selectedFamilyId = "molten_shirabon"
    ui18:render()
    for _, s in ipairs(gpu18._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu18._rowText(6):find("Coil:13,500K", 1, true), "T18h Tab 3 Row 6 renders Coil:13,500K in temp mode")
    assert(clickSlice18("Coil:13,500K", 6, 6, 85, 159), "T18h clicked Tab 3 Row 6 Coil readout")
    assertEq(cfg.coilDisplayMode, "name", "T18h clicking Tab 3 Coil restored coilDisplayMode -> 'name'")
    assert(gpu18._rowText(6):find("Coil:Eternal", 1, true), "T18h Tab 3 Row 6 shows Coil:Eternal again")

    ui18.tab = 4
    ui18:render()
    for _, s in ipairs(gpu18._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu18._allText():find("Eternal", 1, true), "T18h Tab 4 COIL column shows Eternal")
    assert(clickSlice18("Eternal", 22, 48, 125, 135), "T18h clicked Tab 4 COIL row cell")
    assertEq(ui18.tab, 4, "T18h clicking Tab 4 COIL cell stays on Tab 4 instead of focusing Tab 2")
    assertEq(cfg.coilDisplayMode, "temp", "T18h Tab 4 COIL click switched to 'temp' mode")
    assert(gpu18._allText():find("13500K", 1, true), "T18h Tab 4 COIL column shows 13500K in temp mode")
    assert(clickSlice18("COIL", 20, 22, 125, 135), "T18h clicked Tab 4 COIL column header")
    assertEq(cfg.coilDisplayMode, "name", "T18h Tab 4 COIL header restored 'name' mode")

    -- 18i: Tab 4 Transposer side click-to-cycle + auto-detection + 64-entry rolling log modal
    component._register("t18-tp-auto", "transposer", {
        getFluidInTank = function(side)
            if side == 2 then return { { name = "exciteddtec", amount = 5120 } } end
            if side == 5 then return { { amount = 0 } } end
            return {}
        end,
    })
    local autoCfg = {}
    Scheduler.ensureConfig(autoCfg)
    assertEq(autoCfg._hasExplicitTpSides, false, "T18i fresh config marks _hasExplicitTpSides = false")
    Scheduler.syncHardware(autoCfg)
    assertEq(autoCfg.stockTransposerSide, 2, "T18i auto-detected non-empty tank side 2 (North) as stockTransposerSide")
    assertEq(autoCfg.odTransposerSide, 5, "T18i auto-detected second tank side 5 (East) as odTransposerSide")

    cfg.transposerAddr = "t18-tp-auto"
    cfg.stockTransposerSide = 1
    cfg.odTransposerSide = 0
    ui18.tab = 4
    ui18:render()
    assert(clickSlice18("[P:Up]", 15, 15, 95, 155), "T18i clicked Tab 4 [P:Up] transposer side button")
    assertEq(cfg.stockTransposerSide, 2, "T18i [P:Up] stepped stockTransposerSide 1 -> 2 (North)")
    assert(gpu18._rowText(15):find("[P:North]", 1, true), "T18i Row 15 renders [P:North]")
    assert(clickSlice18("[OD:Down]", 15, 15, 95, 155), "T18i clicked Tab 4 [OD:Down] transposer side button")
    assertEq(cfg.odTransposerSide, 1, "T18i [OD:Down] stepped odTransposerSide 0 -> 1 (Up)")

    st.events = {}
    for idx = 1, 25 do
        cfg.fallbackFamilyId = (idx % 2 == 0) and "molten_infinity" or "molten_shirabon"
        cfg.dtpfs[1].roleOverride = (idx % 2 == 0) and "auto" or "fallback_only"
        Scheduler.step(cfg, st, { nowUptime = 280 + idx * 5 })
    end
    assert(#(st.events or {}) > 16 and #(st.events or {}) <= 64, "T18i rolling events log retains >16 up to 64 entries")
    ui18.logModalActive = true
    ui18.logModalTab = 1
    ui18.logStageFilter = "ALL"
    ui18.logModalScroll = 0
    ui18:render()
    for _, s in ipairs(gpu18._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    local logTxt = gpu18._allText()
    assert(logTxt:find("EVENT MESSAGE", 1, true), "T18i Log Modal renders structured EVENT MESSAGE header")
    assert(logTxt:find("Showing 1-", 1, true), "T18i Log Modal paginates log rows cleanly")
    ui18.logModalActive = false

    Hardware.resetClusterState()
    component._reset()
end

-- ============================================================================
-- TEST 18j: Official GTNH Fluid Names, Stock GTNH No-Patch Convergence & Installer
-- ============================================================================
do
    local RecipesDB18j = require("lib.recipes_db")
    local timeLoop = RecipesDB18j.BY_ID["molten_time_loop"]
    local spaceLoop = RecipesDB18j.BY_ID["molten_space_loop"]
    assert(timeLoop and spaceLoop, "T18j loop recipes exist")
    assertEq(timeLoop.name, "Tachyon Rich Temporal Fluid", "T18j official GTNH Temporal Fluid name")
    assertEq(timeLoop.primaryOutput.name, "temporalfluid", "T18j official Forge fluid name temporalfluid")
    assertEq(spaceLoop.name, "Spatially Enlarged Fluid", "T18j official GTNH Spatial Fluid name")
    assertEq(spaceLoop.primaryOutput.name, "spatialfluid", "T18j official Forge fluid name spatialfluid")
    local amalgDtsc = RecipesDB18j.BY_ID["chipped_amalgatite"].modifiers[1].tiers["DTSC"]
    local dssDtec = RecipesDB18j.BY_ID["dimensionally_shifted_superfluid"].modifiers[1].tiers["DTEC"]
    local sawSg, sawGrade8 = false, false
    for _, fl in ipairs(amalgDtsc.fluidsIn or {}) do
        if fl.name == "sgcrystalslurry" and fl.label == "Stargate Crystal Slurry" then
            sawSg = true
        end
    end
    for _, fl in ipairs(dssDtec.fluidsIn or {}) do
        if fl.name == "grade8purifiedwater" and fl.label == "Subatomically Perfect Water (Grade 8)" then
            sawGrade8 = true
        end
    end
    assert(sawSg, "T18j official sgcrystalslurry ID present on Chipped Amalgatite (DTSC)")
    assert(sawGrade8, "T18j official Subatomically Perfect Water (Grade 8) label present (DTEC)")
    local dbRaw = assert(__py_read_file(_G.__DTPF_ROOT .. "/lib/recipes_db.lua"))
    assert(not dbRaw:find("Molten Time", 1, true), "T18j zero invented 'Molten Time' strings in recipes_db.lua")
    assert(not dbRaw:find("Molten Space\"", 1, true), "T18j zero invented 'Molten Space' strings in recipes_db.lua")

    -- Stock GTNH gt_machine without custom DriverDTPF OC patch
    Hardware.resetClusterState()
    component._reset()
    local stockSensorConv = false
    local stockWorkAllowed = true
    component._register("stock-gt-1", "gt_machine", {
        getCoordinates = function() return 10, 67, 10 end,
        getName = function() return "plasmaforge" end,
        isWorkAllowed = function() return stockWorkAllowed end,
        setWorkAllowed = function(v) stockWorkAllowed = v end,
        isMachineActive = function() return true end,
        hasWork = function() return true end,
        getWorkProgress = function() return 50 end,
        getWorkMaxProgress = function() return 200 end,
        getSensorInformation = function()
            return {
                "GT5U.EBF.heat.s\\13,500",
                "GT5U.infodata.plasma_forge.ticks_run_fuel_discount\\576,000\\50%\\0",
                "GT5U.infodata.plasma_forge.convergence\\" .. (stockSensorConv and "Active" or "Inactive"),
            }
        end,
    })

    local hSlots = {}
    local bSlots = {}
    component._register("stock-h1", "me_inputhatch", {
        getCoordinates = function() return 11, 67, 10 end,
        getAutoPull = function() return false end,
        setAutoPull = function() return true end,
        getSlotSize = function() return 16 end,
        setConfiguration = function(slot, f) hSlots[slot] = f; return true end,
    })
    component._register("stock-b1", "me_inputbus", {
        getCoordinates = function() return 12, 67, 10 end,
        getAutoPull = function() return false end,
        setAutoPull = function() return true end,
        getSlotSize = function() return 16 end,
        setConfiguration = function(slot, it) bSlots[slot] = it; return true end,
    })

    local fluids18j = {
        exciteddtec = 10000000,
        exciteddtcc = 10000000,
        dimensionallytranscendentresidue = 50000000,
        ["molten.spacetime"] = 5000000,
        ["molten.metastable oganesson"] = 5000000,
        ["molten.precious metals alloy"] = 5000000,
        ["molten.shirabon"] = 1000,
    }
    component._register("stock-ae2", "me_interface", {
        getFluidsInNetwork = function()
            local out = {}
            for k, v in pairs(fluids18j) do
                out[#out + 1] = { name = k, amount = v, label = k }
            end
            return out
        end,
        getItemsInNetwork = function() return {} end,
    })

    local cfgJ = Scheduler.ensureConfig({ armed = true })
    for _, rc in pairs(cfgJ.recipes) do rc.enabled = false end
    cfgJ.recipes["molten_shirabon"].enabled = true
    cfgJ.recipes["molten_shirabon"].priority = 1
    cfgJ.recipes["molten_shirabon"].target = 1000000
    Scheduler.syncHardware(cfgJ)

    local stJ = {}
    Scheduler.step(cfgJ, stJ, { nowUptime = 500 })
    assertEq(stJ.convControlSupported, false, "T18j stock gt_machine sets convControlSupported = false")
    assertEq(stJ.dtpfStatus[1].supportsConvControl, false, "T18j dtpfStatus[1].supportsConvControl = false")
    assertEq(stJ.dtpfStatus[1].wantConv, false, "T18j NONE recipe skips convergence when GUI conv is OFF")
    for s = 1, 16 do
        if hSlots[s] and tostring(hSlots[s].name):find("^excited") then
            error("T18j unexpectedly injected catalyst " .. tostring(hSlots[s].name) .. " when GUI conv is OFF")
        end
    end

    local gpuJ = component._newMockGPU(160, 50)
    local uiJ = UI.new(cfgJ, stJ)
    uiJ.tab = 2
    uiJ:render()
    for _, s in ipairs(gpuJ._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    local tab1J = gpuJ._allText()
    assert(tab1J:find("[Manual (No OC Patch)]", 1, true), "T18j Tab 2 Global Settings shows [Manual (No OC Patch)]")
    assert(tab1J:find("[Manual]", 1, true), "T18j Tab 2 DTPF Card shows [Manual]")
    assert(not tab1J:find("[Man.]", 1, true), "T18j Tab 2 Queue uses clean 'Manual' without period")

    -- Simulate player turning Convergence ON directly inside DTPF GUI
    stockSensorConv = true
    Scheduler.step(cfgJ, stJ, { nowUptime = 510 })
    assertEq(stJ.dtpfStatus[1].convergenceEnabled, true, "T18j reads manual GUI Convergence ON via sensor")
    assertEq(stJ.dtpfStatus[1].wantConv, true, "T18j updates wantConv when GUI Convergence is ON")
    assert(hSlots[1] and hSlots[1].name == "exciteddtec", "T18j injects exciteddtec into slot 1 once player enables GUI Conv")

    -- Installer & config.cfg backup/restore + atomic syntax rollback test
    local fail404Url = nil
    component._register("mock-inet", "internet", {
        request = function(url)
            local rel = tostring(url):match("https://raw%.githubusercontent%.com/[^/]+/[^/]+/[^/]+/(.+)$")
            local body = (fail404Url and url == fail404Url) and "404: Not Found"
                or (rel and __py_read_file(_G.__DTPF_ROOT .. "/" .. rel))
                or ""
            local sent = false
            return {
                finishConnect = function() return true end,
                response = function()
                    if fail404Url and url == fail404Url then return 404, "Not Found" end
                    return (#body > 0) and 200 or 404, "OK"
                end,
                read = function()
                    if sent then return nil end
                    sent = true
                    return body
                end,
                close = function() end,
            }
        end,
    })

    local customCfgStr = "{ armed = false, dtrReserveFloor = 42000000 }\n"
    __py_write_file("/home/dtpf/config.cfg", customCfgStr)
    __py_write_file("/home/install.lua", "-- bootstrapper in /home")
    local instChunk, instErr = load(assert(__py_read_file(_G.__DTPF_ROOT .. "/install.lua")), "@/home/install.lua")
    assert(instChunk, instErr)
    local okInst, instRunErr = instChunk("example/gtnh-dtpf-control", "main")
    assertEq(okInst, true, "T18j install.lua completed cleanly: " .. tostring(instRunErr))
    assertEq(__py_read_file("/home/install.lua"), nil, "T18j cleans up temporary /home/install.lua bootstrapper")
    assertEq(__py_read_file("/home/dtpf/config.cfg"), customCfgStr, "T18j install.lua preserved existing config.cfg")
    assertEq(__py_read_file("/home/config.dtpf.bak"), customCfgStr, "T18j install.lua backed up /home/config.dtpf.bak")
    assert(__py_read_file("/usr/bin/dtpf.lua") ~= nil, "T18j install.lua created /usr/bin/dtpf.lua")
    assertEq(__py_read_file("/home/dtpf/.repo"), "example/gtnh-dtpf-control\nmain\n", "T18j persisted custom repo/branch")

    -- Simulate broken remote Lua / 404 during update -> aborts without corrupting live lib/ui.lua
    local origUi = assert(__py_read_file("/home/dtpf/lib/ui.lua"))
    fail404Url = "https://raw.githubusercontent.com/example/gtnh-dtpf-control/main/lib/ui.lua"
    local okFail = instChunk()
    assertEq(okFail, false, "T18j failed update aborts safely")
    assertEq(__py_read_file("/home/dtpf/lib/ui.lua"), origUi, "T18j rollback left live lib/ui.lua untouched")
    fail404Url = nil

    -- Simulate full wipe of config.cfg + fresh reinstall -> restores from /home/config.dtpf.bak
    os.remove("/home/dtpf/config.cfg")
    local okReinstall = instChunk("example/gtnh-dtpf-control", "main")
    assertEq(okReinstall, true, "T18j reinstall succeeded after deleting config.cfg")
    assertEq(__py_read_file("/home/dtpf/config.cfg"), customCfgStr, "T18j restored /home/dtpf/config.cfg from /home/config.dtpf.bak")

    -- Interactive prompt tests: dtpf alias + /home/.shrc autostart (coordinator vs headless --worker vs update)
    local origIoWrite, origIoRead = io.write, io.read
    local mockAnswers, promptLog = {}, {}
    local readCalls = 0
    io.write = function(s) promptLog[#promptLog + 1] = tostring(s) end
    io.read = function()
        readCalls = readCalls + 1
        return table.remove(mockAnswers, 1)
    end

    -- 1. Coordinator (has gpu + screen), Enter on both prompts -> /usr/bin/dtpf.lua + "dtpf\n"
    os.remove("/usr/bin/dtpf.lua")
    os.remove("/home/.shrc")
    component._register("mock-gpu-inst", "gpu", {})
    component._register("mock-scr-inst", "screen", {})
    mockAnswers = { "", "" }
    promptLog = {}
    readCalls = 0
    assertEq(instChunk("example/gtnh-dtpf-control", "main"), true, "T18j interactive coordinator install succeeded")
    assertEq(readCalls, 2, "T18j coordinator install prompted twice (alias + autostart)")
    assert(__py_read_file("/usr/bin/dtpf.lua") ~= nil, "T18j Enter confirmed /usr/bin/dtpf.lua alias")
    assertEq(__py_read_file("/home/.shrc"), "dtpf\n", "T18j Enter added dtpf autostart to /home/.shrc")

    -- 2. Re-run when /usr/bin/dtpf.lua and /home/.shrc already configured -> 0 prompts, no duplicate line
    __py_write_file("/home/.shrc", "/home/dtpf/main.lua\n")
    mockAnswers = {}
    readCalls = 0
    assertEq(instChunk("example/gtnh-dtpf-control", "main"), true, "T18j idempotent reinstall succeeded")
    assertEq(readCalls, 0, "T18j skips already-configured alias and .shrc prompts")
    assertEq(__py_read_file("/home/.shrc"), "/home/dtpf/main.lua\n", "T18j did not duplicate .shrc autostart")

    -- 3. Headless server (no screen), preserve pre-existing non-dtpf .shrc line -> appends "dtpf --worker\n"
    component._register("mock-scr-inst", "removed", {})
    os.remove("/usr/bin/dtpf.lua")
    __py_write_file("/home/.shrc", "echo hello")
    mockAnswers = { "y", "" }
    readCalls = 0
    assertEq(instChunk("example/gtnh-dtpf-control", "main"), true, "T18j headless worker install succeeded")
    assertEq(readCalls, 2, "T18j headless worker prompted twice")
    assertEq(__py_read_file("/home/.shrc"), "echo hello\ndtpf --worker\n", "T18j appended headless dtpf --worker to .shrc cleanly")

    -- 4. Decline both ("n", "n") -> neither created; subsequent --update triggers 0 prompts and keeps both absent
    os.remove("/usr/bin/dtpf.lua")
    os.remove("/home/.shrc")
    component._register("mock-scr-inst", "screen", {})
    mockAnswers = { "n", "n" }
    readCalls = 0
    assertEq(instChunk("example/gtnh-dtpf-control", "main"), true, "T18j declined install succeeded")
    assertEq(readCalls, 2, "T18j asked both prompts when declined")
    assertEq(__py_read_file("/usr/bin/dtpf.lua"), nil, "T18j respected 'n' for /usr/bin/dtpf.lua")
    assertEq(__py_read_file("/home/.shrc"), nil, "T18j respected 'n' for /home/.shrc")

    mockAnswers = {}
    readCalls = 0
    assertEq(instChunk("--update"), true, "T18j --update succeeded cleanly")
    assertEq(readCalls, 0, "T18j --update performs 0 interactive prompts")
    assertEq(__py_read_file("/usr/bin/dtpf.lua"), nil, "T18j --update kept absent /usr/bin/dtpf.lua absent")
    assertEq(__py_read_file("/home/.shrc"), nil, "T18j --update left /home/.shrc untouched")

    io.write, io.read = origIoWrite, origIoRead

    -- Cleanup VFS artifacts so subsequent tests stay isolated
    for _, rp in ipairs({
        "/home/dtpf/install.lua", "/home/dtpf/main.lua", "/home/dtpf/lib/recipes_db.lua",
        "/home/dtpf/lib/hardware.lua", "/home/dtpf/lib/scheduler.lua", "/home/dtpf/lib/ui.lua",
        "/home/dtpf/config.cfg", "/home/dtpf/.repo", "/home/config.dtpf.bak", "/usr/bin/dtpf.lua",
        "/home/.shrc",
    }) do
        os.remove(rp)
    end
    Hardware.resetClusterState()
    component._reset()
end

-- ============================================================================
-- TEST 18k: [1] OVERVIEW Tab, Multi-Verbosity [Log] (IN/DEC/OUT + Raw I/O), & install --local
-- ============================================================================
do
    Hardware.resetClusterState()
    local cfg, fluids = setupStandardEnv({ neutronium = 0 })
    for id, rc in pairs(cfg.recipes) do rc.enabled = false; rc.forever = false end
    cfg.recipes["molten_neutronium"].enabled = true
    cfg.recipes["molten_neutronium"].priority = 1
    cfg.recipes["molten_neutronium"].target = 1000000
    cfg.fallbackEnabled = false
    cfg.armed = true

    -- 1. Quiet mode: emits DEC milestone, omits routine OUT ch1 write, 0 steady chatter, logs Target met
    cfg.logLevel = "quiet"
    local st = {}
    Scheduler.step(cfg, st, { nowUptime = 600 })
    local nQuiet1 = #(st.events or {})
    assert(nQuiet1 >= 1, "T18k quiet emits initial DEC transition")
    for _, ev in ipairs(st.events) do
        assert(not tostring(ev.text):find("write:", 1, true) and not tostring(ev.text):find("clear:", 1, true),
            "T18k quiet omits routine OUT channel write event (got " .. tostring(ev.text) .. ")")
    end
    Scheduler.step(cfg, st, { nowUptime = 605 })
    assertEq(#(st.events or {}), nQuiet1, "T18k quiet emits 0 events on steady-state poll")

    fluids["molten.neutronium"] = 2000000
    Scheduler.step(cfg, st, { nowUptime = 610 })
    local sawTargetMet = false
    for _, ev in ipairs(st.events) do
        if ev.stage == "IN" and tostring(ev.text):find("Target met: Molten Neutronium", 1, true) then
            sawTargetMet = true
            break
        end
    end
    assert(sawTargetMet, "T18k logs [IN] Target met milestone when recipe reaches target")

    -- 2. Normal mode: logs [OUT] Hatch/Bus writes on recipe switch and 0 events on steady polls
    fluids["molten.neutronium"] = 0
    cfg.logLevel = "normal"
    st.events = {}
    Scheduler.step(cfg, st, { nowUptime = 615 })
    local sawChWrite = false
    for _, ev in ipairs(st.events) do
        if ev.stage == "OUT" and tostring(ev.text):find("ch1 write:", 1, true) then
            sawChWrite = true
            break
        end
    end
    assert(sawChWrite, "T18k normal logs [OUT] ch1 write hardware filter summary")
    local nNormSteady = #(st.events or {})
    Scheduler.step(cfg, st, { nowUptime = 620 })
    assertEq(#(st.events or {}), nNormSteady, "T18k normal emits 0 events on identical steady-state poll")

    -- 3. Raw mode: emits IN/DEC/OUT per live poll, 0 on cached/interactive, capped <= 64
    cfg.logLevel = "raw"
    st.events = {}
    Scheduler.step(cfg, st, { nowUptime = 625 })
    assertEq(#(st.events or {}), 3, "T18k raw emits 3 structured IN/DEC/OUT trace lines on steady poll")
    assertEq(st.events[1].stage, "IN", "T18k raw line 1 (top) is [IN]")
    assertEq(st.events[2].stage, "DEC", "T18k raw line 2 (mid) is [DEC]")
    assertEq(st.events[3].stage, "OUT", "T18k raw line 3 (bot) is [OUT]")

    local rawBeforeCache = #st.events
    Scheduler.step(cfg, st, { cachedOnly = true, interactive = true, nowUptime = 626 })
    assertEq(#st.events, rawBeforeCache, "T18k raw emits 0 trace lines on cachedOnly interactive calls")

    for k = 1, 30 do
        Scheduler.step(cfg, st, { nowUptime = 630 + k * 3 })
    end
    assert(#st.events <= 64, "T18k raw bounds rolling event buffer <= 64")

    -- 4. [1] OVERVIEW tab + KPI drill-downs + [Log] View 1 stage filter & View 2 Raw I/O Snapshot
    local gpu = component._newMockGPU(160, 50)
    local ui = UI.new(cfg, st)
    assertEq(ui.tab, 1, "T18k UI defaults to Tab 1 [1] OVERVIEW")
    ui:render()
    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    local ovTxt = gpu._allText()
    assert(ovTxt:find("SYSTEM HEALTH", 1, true), "T18k Overview renders SYSTEM HEALTH card")
    assert(ovTxt:find("DTPF FLEET", 1, true), "T18k Overview renders DTPF FLEET card")
    assert(ovTxt:find("STOCK TARGETS", 1, true), "T18k Overview renders STOCK TARGETS card")
    assert(ovTxt:find("ACTIVE PRODUCTION & ALERTS", 1, true), "T18k Overview renders ACTIVE PRODUCTION card")
    assert(ovTxt:find("CATALYST & DTR RESERVES", 1, true), "T18k Overview renders CATALYST & DTR RESERVES card")
    assert(ovTxt:find("RECENT MILESTONES", 1, true), "T18k Overview renders RECENT MILESTONES feed")
    assert((not ovTxt:find("[DEC]", 1, true)) and (not ovTxt:find("hw writes", 1, true)),
        "T18k Overview keeps raw debug trace chatter out of Recent Milestones")

    local function click18k(needle, xMin, xMax, yMin, yMax)
        for i = #ui.hitboxes, 1, -1 do
            local hb = ui.hitboxes[i]
            if (not xMin or hb.x1 >= xMin) and (not xMax or hb.x2 <= xMax)
                and (not yMin or hb.y1 >= yMin) and (not yMax or hb.y2 <= yMax) then
                local row = gpu._rowText(hb.y1)
                if unicode.sub(row, hb.x1, hb.x2):find(needle, 1, true) then
                    ui:handleTouch(hb.x1, hb.y1, 0)
                    ui:render()
                    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
                    return true
                end
            end
        end
        return false
    end

    ui:handleTouch(10, 7, 0) -- Health card -> Log modal
    ui:render()
    assertEq(ui.logModalActive, true, "T18k clicking SYSTEM HEALTH opens Log Modal")
    for _, s in ipairs(gpu._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    assert(click18k("[OUT]", 8, 150, 7, 16), "T18k clicked [OUT] stage filter inside Log Modal")
    assertEq(ui.logStageFilter, "OUT", "T18k logStageFilter -> OUT")
    assert(click18k("[2: Raw I/O Snapshot]", 8, 150, 5, 5), "T18k switched Log Modal to [2: Raw I/O Snapshot]")
    assertEq(ui.logModalTab, 2, "T18k logModalTab -> 2")
    local snapTxt = gpu._allText()
    assert(snapTxt:find("1. RAW INPUTS", 1, true) and snapTxt:find("2. RAW DECISIONS", 1, true) and snapTxt:find("3. RAW OUTPUTS", 1, true),
        "T18k Log View 2 renders structured 1. RAW INPUTS / 2. RAW DECISIONS / 3. RAW OUTPUTS")
    assert(snapTxt:find("Hatch:", 1, true), "T18k Log View 2 renders exact written Hatch slot filters")
    ui.logModalActive = false
    ui:render()

    ui:handleTouch(55, 7, 0) -- DTPF Fleet card -> Tab 2
    assertEq(ui.tab, 2, "T18k clicking DTPF FLEET KPI jumps to Tab 2 Fleet")
    ui.tab = 1; ui:render()
    ui:handleTouch(95, 7, 0) -- Recipe Queue card -> Tab 3
    assertEq(ui.tab, 3, "T18k clicking RECIPE QUEUE KPI jumps to Tab 3 Recipes")
    ui.tab = 1; ui:render()
    ui:handleTouch(140, 7, 0) -- On-Demand KPI -> Tab 4
    assertEq(ui.tab, 4, "T18k clicking ON-DEMAND & BRIDGE KPI jumps to Tab 4 Setup")

    -- 5. Verify main.lua persists logLevel and --check emits structured sections
    local serialization = require("serialization")
    local evQ = require("event")._queue
    while #evQ > 0 do table.remove(evQ) end
    evQ[1] = { "key_down", "kbd", string.byte("q"), 16 }
    component.gpu = gpu
    local mainPath = _G.__DTPF_ROOT .. "/main.lua"
    local cfgPath = _G.__DTPF_ROOT .. "/config.cfg"
    __py_write_file(cfgPath, "{ armed = true, logLevel = \"raw\" }\n")
    local mChunk, mErr = load(assert(__py_read_file(mainPath)), "@" .. mainPath)
    assert(mChunk, mErr)
    mChunk()
    component.gpu = nil
    while #evQ > 0 do table.remove(evQ) end

    local savedRaw = assert(__py_read_file(cfgPath))
    local savedCfg = serialization.unserialize(savedRaw)
    assertEq(savedCfg.logLevel, "raw", "T18k main.lua preserved and serialized logLevel = 'raw'")
    local origPrint = _G.print
    local chkLines = {}
    _G.print = function(...)
        local parts = {}
        for j = 1, select("#", ...) do parts[j] = tostring(select(j, ...)) end
        chkLines[#chkLines + 1] = table.concat(parts, "\t")
        origPrint(...)
    end
    mChunk("--check")
    _G.print = origPrint
    local chkBlob = table.concat(chkLines, "\n")
    assert(chkBlob:find("--- [1] RAW INPUTS ---", 1, true)
        and chkBlob:find("--- [2] SCHEDULER DECISIONS ---", 1, true)
        and chkBlob:find("--- [3] DRY-RUN OUTPUTS ---", 1, true),
        "T18k main --check emits structured INPUTS / DECISIONS / OUTPUTS sections")
    os.remove(cfgPath)

    -- 6. Verify install.lua --local <srcDir> installs cleanly without Internet Card & restores backup
    for addr in component.list("internet", true) do
        component._register(addr, "removed", {})
    end
    __py_write_file("/home/config.dtpf.bak", "{ armed = true, logLevel = \"normal\", dtrReserveFloor = 777 }\n")
    local locChunk, locErr = load(assert(__py_read_file(_G.__DTPF_ROOT .. "/install.lua")), "@/tmp/inst_local.lua")
    assert(locChunk, locErr)
    local okLoc, errLoc = locChunk("--local", _G.__DTPF_ROOT)
    assertEq(okLoc, true, "T18k install.lua --local completed without Internet Card: " .. tostring(errLoc))
    assertEq(__py_read_file("/home/dtpf/config.cfg"), "{ armed = true, logLevel = \"normal\", dtrReserveFloor = 777 }\n",
        "T18k install.lua --local restored /home/config.dtpf.bak into /home/dtpf/config.cfg")
    assert(__py_read_file("/usr/bin/dtpf.lua") ~= nil, "T18k install.lua --local created /usr/bin/dtpf.lua")
    for _, rp in ipairs({
        "/home/dtpf/install.lua", "/home/dtpf/main.lua", "/home/dtpf/lib/recipes_db.lua",
        "/home/dtpf/lib/hardware.lua", "/home/dtpf/lib/scheduler.lua", "/home/dtpf/lib/ui.lua",
        "/home/dtpf/config.cfg", "/home/dtpf/.repo", "/home/config.dtpf.bak", "/usr/bin/dtpf.lua",
    }) do
        os.remove(rp)
    end

    Hardware.resetClusterState()
    component._reset()
end

-- ============================================================================
-- TEST 20: OD Evacuation [FLUSH OD], Backpressure Rollback & Auto-Flush Loop Guard
-- ============================================================================
do
    Hardware.resetClusterState()
    component._reset()

    local function makeRichAE2Bridge()
        local fluids = {}
        local items = {} -- array of { name, damage, amount, maxSize, tag, label }
        local itemSlotCfg = {}
        local fluidSlotCfg = {}
        local itemBuf = nil
        local fluidTank = { name = nil, amount = 0 }
        local itemCfgLog = {}
        local rejectsInsert = false

        local function itemKey(it)
            return tostring(it.name) .. ":" .. tostring(it.damage or 0) .. (it.tag ~= nil and ("#" .. tostring(it.tag)) or "")
        end

        local function addItem(spec, qty)
            if qty <= 0 then return end
            local k = itemKey(spec)
            for i = 1, #items do
                if itemKey(items[i]) == k then
                    items[i].amount = items[i].amount + qty
                    return
                end
            end
            items[#items + 1] = {
                name = spec.name,
                damage = spec.damage or 0,
                amount = qty,
                maxSize = spec.maxSize or 64,
                tag = spec.tag,
                label = spec.label or spec.name,
            }
        end

        local function getItemTotal(spec)
            local k = itemKey(spec)
            for i = 1, #items do
                if itemKey(items[i]) == k then return items[i].amount end
            end
            return 0
        end

        local function takeItem(spec, qty)
            local k = itemKey(spec)
            for i = 1, #items do
                if itemKey(items[i]) == k then
                    local take = math.min(qty, items[i].amount)
                    items[i].amount = items[i].amount - take
                    if items[i].amount <= 0 then table.remove(items, i) end
                    return take
                end
            end
            return 0
        end

        local function syncItemBuf()
            local c = itemSlotCfg[1]
            if c and c.name then
                if itemBuf and itemKey(itemBuf) ~= itemKey(c) and itemBuf.amount > 0 then
                    addItem(itemBuf, itemBuf.amount)
                    itemBuf = nil
                end
                local want = math.max(1, math.min(64, tonumber(c.size) or 64))
                local curAmt = itemBuf and itemBuf.amount or 0
                if curAmt < want then
                    local pull = takeItem(c, want - curAmt)
                    if pull > 0 then
                        itemBuf = {
                            name = c.name,
                            damage = c.damage or 0,
                            amount = curAmt + pull,
                            maxSize = 64,
                            tag = c.tag,
                            label = c.name,
                        }
                    end
                end
            else
                if (not rejectsInsert) and itemBuf and itemBuf.amount > 0 then
                    addItem(itemBuf, itemBuf.amount)
                    itemBuf = nil
                end
            end
        end

        local function syncFluidTank()
            local c = fluidSlotCfg[1]
            if c and c.name then
                if fluidTank.name and fluidTank.name ~= c.name and fluidTank.amount > 0 then
                    fluids[fluidTank.name] = (fluids[fluidTank.name] or 0) + fluidTank.amount
                    fluidTank.amount = 0
                end
                fluidTank.name = c.name
                local want = 64000 - fluidTank.amount
                local have = fluids[c.name] or 0
                local pull = math.min(want, have)
                if pull > 0 then
                    fluids[c.name] = have - pull
                    fluidTank.amount = fluidTank.amount + pull
                end
            else
                if fluidTank.name and fluidTank.amount > 0 then
                    fluids[fluidTank.name] = (fluids[fluidTank.name] or 0) + fluidTank.amount
                end
                fluidTank.name = nil
                fluidTank.amount = 0
            end
        end

        local proxy = {
            getFluidsInNetwork = function()
                local out = {}
                for k, v in pairs(fluids) do
                    if v > 0 then out[#out + 1] = { name = k, amount = v, size = v, label = k } end
                end
                return out
            end,
            getItemsInNetwork = function()
                local out = {}
                for i = 1, #items do
                    local it = items[i]
                    if it.amount > 0 then
                        out[#out + 1] = {
                            name = it.name,
                            damage = it.damage or 0,
                            size = it.amount,
                            amount = it.amount,
                            maxSize = it.maxSize or 64,
                            tag = it.tag,
                            label = it.label or it.name,
                        }
                    end
                end
                return out
            end,
            setInterfaceConfiguration = function(slot, detail)
                itemCfgLog[#itemCfgLog + 1] = detail and detail.name or nil
                itemSlotCfg[slot] = detail
                syncItemBuf()
                return true
            end,
            getInterfaceConfiguration = function(slot)
                return itemSlotCfg[slot]
            end,
            setFluidInterfaceConfiguration = function(slot, detail)
                fluidSlotCfg[slot] = detail
                syncFluidTank()
                return true
            end,
        }

        return proxy, {
            fluids = fluids,
            items = items,
            itemSlotCfg = itemSlotCfg,
            fluidSlotCfg = fluidSlotCfg,
            itemCfgLog = itemCfgLog,
            addItem = addItem,
            getItemAmt = getItemTotal,
            getItemBuf = function() return itemBuf end,
            setItemBuf = function(b) itemBuf = b end,
            getTank = function() return fluidTank end,
            syncItemBuf = syncItemBuf,
            syncFluidTank = syncFluidTank,
            setRejectInsert = function(v) rejectsInsert = v end,
            isRejectInsert = function() return rejectsInsert end,
            clear = function()
                for k in pairs(fluids) do fluids[k] = nil end
                for i = #items, 1, -1 do table.remove(items, i) end
                itemSlotCfg[1] = nil
                fluidSlotCfg[1] = nil
                itemBuf = nil
                fluidTank.name = nil
                fluidTank.amount = 0
            end,
        }
    end

    local stockProxy20, stockSt20 = makeRichAE2Bridge()
    local odProxy20, odSt20 = makeRichAE2Bridge()
    stockSt20.fluids.exciteddtcc = 500000
    stockSt20.fluids.exciteddtpc = 500000
    stockSt20.fluids.exciteddtrc = 500000
    stockSt20.fluids.exciteddtec = 5000000
    stockSt20.fluids.exciteddtsc = 500000
    stockSt20.fluids.dimensionallytranscendentresidue = 20000000
    stockSt20.fluids["molten.iron"] = 10000000
    stockSt20.fluids["molten.neutronium"] = 30000000000
    stockSt20.addItem({ name = "minecraft:cobblestone", damage = 0 }, 100000)

    component._register("t20-stock-if", "fluid_interface", stockProxy20)
    component._register("t20-od-if", "fluid_interface", odProxy20)

    local function sideBridge(side)
        if side == 1 then return stockSt20 end
        if side == 0 then return odSt20 end
        return nil
    end

    local tp20 = {
        getTankLevel = function(side)
            local s = sideBridge(side)
            if not s then return 0 end
            s.syncFluidTank()
            return s.getTank().amount or 0
        end,
        transferFluid = function(srcSide, dstSide, count)
            local src = sideBridge(srcSide)
            local dst = sideBridge(dstSide)
            if not src or not dst then return false, 0 end
            src.syncFluidTank()
            local t = src.getTank()
            if not t.name or (t.amount or 0) <= 0 then return false, 0 end
            local mv = math.min(count, t.amount)
            local fname = t.name
            t.amount = t.amount - mv
            if t.amount <= 0 then t.name = nil end
            dst.fluids[fname] = (dst.fluids[fname] or 0) + mv
            -- Once last fluid leaves OD, clear any virtual ae2fc:fluid_drop representing it
            if srcSide == 0 and (dst.fluids[fname] ~= nil) and (src.fluids[fname] or 0) == 0 and (t.amount or 0) == 0 then
                for i = #src.items, 1, -1 do
                    if src.items[i].name == "ae2fc:fluid_drop" and src.items[i].label == fname then
                        table.remove(src.items, i)
                    end
                end
            end
            src.syncFluidTank()
            return true, mv
        end,
        getSlotStackSize = function(side, slot)
            if (slot or 1) ~= 1 then return 0 end
            local s = sideBridge(side)
            if not s then return 0 end
            s.syncItemBuf()
            local b = s.getItemBuf()
            return (b and b.amount) or 0
        end,
        transferItem = function(srcSide, dstSide, count, srcSlot, sinkSlot)
            local src = sideBridge(srcSide)
            local dst = sideBridge(dstSide)
            if not src or not dst then return 0 end
            src.syncItemBuf()
            local b = src.getItemBuf()
            if not b or (b.amount or 0) <= 0 then return 0 end
            local mv = math.min(count or 64, b.amount)
            local movedSpec = { name = b.name, damage = b.damage, maxSize = 64, tag = b.tag, label = b.label }
            b.amount = b.amount - mv
            if b.amount <= 0 then src.setItemBuf(nil) end
            if dst.isRejectInsert() then
                local db = dst.getItemBuf()
                if db and db.name == movedSpec.name and db.damage == movedSpec.damage and db.tag == movedSpec.tag then
                    db.amount = db.amount + mv
                elseif not db then
                    dst.setItemBuf({
                        name = movedSpec.name,
                        damage = movedSpec.damage,
                        amount = mv,
                        maxSize = 64,
                        tag = movedSpec.tag,
                        label = movedSpec.label,
                    })
                end
            else
                dst.addItem(movedSpec, mv)
            end
            src.syncItemBuf()
            -- Single integer return matching OpenComputers Transposer.transferItem
            return mv
        end,
    }
    component._register("t20-tp", "transposer", tp20)
    component._register("t20-dtpf1", "dtpf", {
        getCoordinates = function() return 10, 65, 10 end,
        getCoilHeat = function() return 13500 end,
        getFuelDiscount = function() return 50 end,
        isMachineActive = function() return false end,
        isWorkAllowed = function() return true end,
        setWorkAllowed = function() return true end,
        isConvergenceActive = function() return false end,
        getConvergenceMode = function() return false end,
        setConvergenceMode = function() return true end,
        getProgress = function() return 0 end,
        getMaxProgress = function() return 0 end,
        getSensorInformation = function() return {} end,
    })
    component._register("t20-h1", "me_inputhatch", {
        getCoordinates = function() return 10, 64, 10 end,
        getSlotSize = function() return 16 end,
        getAutoPull = function() return false end,
        setAutoPull = function() return true end,
        getConfiguration = function() return nil end,
        setConfiguration = function() return true end,
    })
    component._register("t20-b1", "me_inputbus", {
        getCoordinates = function() return 10, 64, 11 end,
        getSlotSize = function() return 16 end,
        getAutoPull = function() return false end,
        setAutoPull = function() return true end,
        getConfiguration = function() return nil end,
        setConfiguration = function() return true end,
    })

    local cfg20 = Scheduler.ensureConfig({
        armed = false,
        stockNetAddr = "t20-stock-if",
        onDemandNetAddr = "t20-od-if",
        transposerAddr = "t20-tp",
        transposerEnabled = true,
        stockTransposerSide = 1,
        odTransposerSide = 0,
        pollInterval = 2.0,
        odAutoFlushPolls = 0,
        catalystAutoFallback = true,
    })
    local st20 = {}

    -- Part A: Manual [FLUSH OD] drains multi-stack (>64) + NBT-tagged items + fluids + catalyst while skipping ae2fc:fluid_drop
    odSt20.addItem({ name = "gregtech:gt.metaitem.01", damage = 17032, label = "Neutronium Ingot" }, 150)
    odSt20.addItem({ name = "miscutils:nbt_part", damage = 3, tag = "nbt-bytes", label = "NBT Core" }, 8)
    odSt20.addItem({ name = "ae2fc:fluid_drop", damage = 0, label = "molten.copper" }, 1)
    odSt20.fluids["molten.copper"] = 7200
    odSt20.fluids["exciteddtec"] = 4000

    local gpu20 = component._newMockGPU(160, 50)
    Scheduler.step(cfg20, st20)
    local ui20 = UI.new(cfg20, st20, function() end)
    local function clickBtn20(needle, rowY, btn)
        for i = #ui20.hitboxes, 1, -1 do
            local hb = ui20.hitboxes[i]
            if hb.y1 == rowY and hb.y2 == rowY then
                local row = gpu20._rowText(rowY)
                if unicode.sub(row, hb.x1, hb.x2):find(needle, 1, true) then
                    ui20:handleTouch(hb.x1, rowY, btn or 0)
                    return true
                end
            end
        end
        return false
    end

    ui20.tab = 4; ui20:render()
    local row15Txt = gpu20._rowText(15)
    local row6Txt = gpu20._rowText(6)
    assert(row15Txt:find("[AutoFlush:OFF]", 1, true), "T20 Tab 4 renders [AutoFlush:OFF]")
    assert(row6Txt:find("FLUSH OD", 1, true), "T20 Tab 4 renders FLUSH OD big action button")
    for _, s in ipairs(gpu20._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    assert(clickBtn20("FLUSH OD", 6, 0), "T20 clicked FLUSH OD big button hitbox on Tab 4")
    assertEq(st20.odFlushActive, true, "T20 clicking [FLUSH OD] activates odFlushActive (even when paused)")
    assertEq(st20._forcePollNow, true, "T20 clicking [FLUSH OD] requests immediate poll")
    ui20.tab = 1; ui20:render()
    local card4Hdr = gpu20._rowText(6)
    assert(card4Hdr:find("[Stop ]", 1, true), "T20 Overview Card 4 shows [Stop ] while flush active")
    assert(gpu20._rowText(7):find("FLUSHING OD", 1, true), "T20 Overview Card 4 row 7 displays flushing state")
    for _, s in ipairs(gpu20._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    for _ = 1, 10 do
        Scheduler.step(cfg20, st20)
        if not st20.odFlushActive then break end
    end
    assertEq(st20.odFlushActive, false, "T20 Part A manual flush completes")
    assertEq(st20.odBridgeStatus, "Idle (Flushed -> Main)", "T20 Part A status Idle (Flushed -> Main)")
    assertEq(stockSt20.getItemAmt({ name = "gregtech:gt.metaitem.01", damage = 17032 }), 150,
        "T20 Part A drained all 150 multi-stack items to Main")
    assertEq(stockSt20.getItemAmt({ name = "miscutils:nbt_part", damage = 3, tag = "nbt-bytes" }), 8,
        "T20 Part A drained all 8 NBT-tagged items preserving tag")
    assertEq(stockSt20.fluids["molten.copper"], 7200, "T20 Part A drained non-catalyst fluid to Main")
    assertEq(stockSt20.fluids["exciteddtec"], 5004000, "T20 Part A drained catalyst fluid back to Main")
    assertEq(#odSt20.items, 0, "T20 Part A Color 1 item network empty")
    assertEq(odSt20.itemSlotCfg[1], nil, "T20 Part A cleared OD Dual IF item slot 1")
    assertEq(odSt20.fluidSlotCfg[1], nil, "T20 Part A cleared OD Dual IF fluid slot 1")
    for _, cfgName in ipairs(odSt20.itemCfgLog) do
        assert(cfgName ~= "ae2fc:fluid_drop", "T20 Part A never configured virtual ae2fc:fluid_drop into item slot 1")
    end

    -- Part B: Backpressure rollback when Passive Item Storage Bus rejects insert (Extract-Only)
    odSt20.addItem({ name = "gregtech:gt.metaitem.01", damage = 17032, label = "Neutronium Ingot" }, 32)
    stockSt20.setRejectInsert(true)
    Scheduler.step(cfg20, st20)
    ui20.tab = 1; ui20:render()
    assert(clickBtn20("[Flush]", 6, 0), "T20 Part B Overview Card 4 clicked [Flush] hitbox when OD has work")
    assertEq(st20.odFlushActive, true, "T20 Part B [Flush] button triggered odFlushActive")
    Scheduler.step(cfg20, st20)
    assertEq(st20.odFlushActive, false, "T20 Part B backpressure halts flush")
    assertEq(st20.odBridgeStatus, "! Set Passive Item SB -> Bi-Dir", "T20 Part B surfaces bi-dir warning")
    assertEq(tp20.getSlotStackSize(1, 1), 0, "T20 Part B leaves 0 items stranded on Passive Dual IF")
    assertEq(odSt20.getItemAmt({ name = "gregtech:gt.metaitem.01", damage = 17032 }), 32,
        "T20 Part B rolled all 32 items cleanly back to Color 1")
    stockSt20.setRejectInsert(false)
    odSt20.clear()
    Scheduler.step(cfg20, st20)
    Scheduler.step(cfg20, st20) -- 2 idle polls reset backpressure & loop latches

    -- Part C: Auto-Flush on Stall (`odAutoFlushPolls = 8`) + AE2 Crafting CPU Re-Push Loop Guard
    cfg20.armed = true
    cfg20.pausePassivesOnOD = true
    cfg20.odAutoFlushPolls = 0
    st20 = {}
    odSt20.addItem({ name = "gregtech:gt.metaitem.01", damage = 17032, label = "Neutronium Ingot" }, 64)
    odSt20.fluids["molten.copper"] = 1000
    for _ = 1, 8 do
        Scheduler.step(cfg20, st20)
    end
    assertEq(st20.odStalled, true, "T20 Part C stalls at >=4 polls when odAutoFlushPolls=0")
    assertEq(st20.odFlushActive ~= true, true, "T20 Part C never auto-flushes when odAutoFlushPolls=0")

    cfg20.odAutoFlushPolls = 8
    st20 = {}
    for p = 1, 8 do
        Scheduler.step(cfg20, st20)
        if p < 8 then
            assertEq(st20.odFlushActive ~= true, true, "T20 Part C does not trigger auto-flush before poll 8")
        end
    end
    assertEq(st20.odFlushActive, true, "T20 Part C triggers auto-flush at poll 8")
    for _ = 1, 6 do
        Scheduler.step(cfg20, st20)
        if not st20.odFlushActive then break end
    end
    assertEq(st20.odBridgeStatus, "Idle (Flushed -> Main)", "T20 Part C auto-flush emptied stalled craft to Main")

    -- Immediately re-push identical stalled craft (0 idle polls between flush & re-push) -> Loop Breaker must halt cycling!
    odSt20.addItem({ name = "gregtech:gt.metaitem.01", damage = 17032, label = "Neutronium Ingot" }, 64)
    odSt20.fluids["molten.copper"] = 1000
    for _ = 1, 10 do
        Scheduler.step(cfg20, st20)
        assertEq(st20.odFlushActive ~= true, true, "T20 Part C loop guard refuses infinite re-flush on AE2 CPU re-push")
    end
    assert(tostring(st20.odStallReason or ""):find("AE2 CPU re-pushed", 1, true),
        "T20 Part C stall reason explains AE2 CPU re-push loop guard")

    -- Clear OD for 2 idle polls -> loop guard resets cleanly
    odSt20.clear()
    Scheduler.step(cfg20, st20)
    Scheduler.step(cfg20, st20)
    assertEq(st20._odAutoFlushLastSig, nil, "T20 Part C loop guard resets after 2 idle polls")

    -- Part D: UI [AutoFlush] preset cycling, [STOP FLUSH] render & main.lua config persistence round-trip
    ui20.tab = 4; ui20:render()
    assert(clickBtn20("[AutoFlush:16s]", 15, 0), "T20 Part D Tab 4 clicked [AutoFlush:16s] (8 -> 15)")
    assertEq(cfg20.odAutoFlushPolls, 15, "T20 Part D forward click cycles AutoFlush 8 -> 15")
    ui20:render()
    assert(clickBtn20("[AutoFlush:30s]", 15, 1), "T20 Part D Tab 4 right-clicked [AutoFlush:30s] (15 -> 8)")
    assertEq(cfg20.odAutoFlushPolls, 8, "T20 Part D right-click cycles AutoFlush 15 -> 8")

    cfg20.odAutoFlushPolls = 0
    ui20:render()
    local afOffX
    for i = #ui20.hitboxes, 1, -1 do
        local hb = ui20.hitboxes[i]
        if hb.y1 == 15 and hb.y2 == 15 and unicode.sub(gpu20._rowText(15), hb.x1, hb.x2):find("[AutoFlush:OFF]", 1, true) then
            afOffX = hb.x1
            break
        end
    end
    assert(afOffX ~= nil, "T20 Part D located [AutoFlush:OFF] hitbox")

    local evQ20 = require("event")._queue
    while #evQ20 > 0 do table.remove(evQ20) end
    evQ20[1] = { "key_down", "kbd", string.byte("4"), 5 }
    evQ20[2] = { "touch", "scr", afOffX, 15, 0 }
    evQ20[3] = { "key_down", "kbd", string.byte("q"), 16 }
    component.gpu = gpu20
    local mainPath20 = _G.__DTPF_ROOT .. "/main.lua"
    local cfgPath20 = _G.__DTPF_ROOT .. "/config.cfg"
    __py_write_file(cfgPath20, "{ armed = true }\n")
    local m20, mErr20 = load(assert(__py_read_file(mainPath20)), "@" .. mainPath20)
    assert(m20, mErr20)
    m20()
    component.gpu = nil
    local saved20 = assert(__py_read_file(cfgPath20), "T20 Part D main.lua wrote config.cfg")
    assert(saved20:find("odAutoFlushPolls = 8", 1, true), "T20 Part D main.lua persisted odAutoFlushPolls = 8")
    assert(saved20:find("autoFlushPolls = 8", 1, true), "T20 Part D main.lua persisted subnets.transposer.autoFlushPolls = 8")
    local reloadedTbl = assert(load("return " .. saved20:match("(%b{})")), "T20 Part D valid Lua config table")()
    reloadedTbl.odAutoFlushPolls = nil -- Prove ensureConfig also hydrates cleanly from subnets.transposer.autoFlushPolls
    local hydratedCfg = Scheduler.ensureConfig(reloadedTbl)
    assertEq(hydratedCfg.odAutoFlushPolls, 8, "T20 Part D Scheduler.ensureConfig hydrates autoFlushPolls from subnets.transposer")
    __py_remove_vfs(cfgPath20)
    for _, s in ipairs(gpu20._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    Hardware.resetClusterState()
    component._reset()
end

-- ============================================================================
-- TEST 21: Convergence `below_tgt` Hysteresis, UI Controls & WebBridge RPC
-- ============================================================================
do
    Hardware.resetClusterState()
    local env, fluids, items, odFluids, odItems, fsbSlots, fsbCalls, isbSlots, isbCalls, dtpfStates = setupStandardEnv()
    for id, rc in pairs(env.recipes) do
        rc.enabled = false
    end
    env.fallbackEnabled = false

    -- Scenario 1: raw_tesseract 24/7 with convMode="below_tgt" (target=40M) + molten_infinity 24/7 with convMode="off"
    env.recipes["raw_tesseract"].enabled = true
    env.recipes["raw_tesseract"].forever = true
    env.recipes["raw_tesseract"].priority = 1
    env.recipes["raw_tesseract"].target = 40000000
    env.recipes["raw_tesseract"].convMode = "below_tgt"
    items["gregtech:gt.metaitem.01:32415"] = 100000
    items["miscutils:MU-metaitem.01:32105"] = 10000
    items["minecraft:cobblestone:0"] = 100000

    local RecipesDB = require("lib.recipes_db")
    local rtFam = RecipesDB.BY_ID["raw_tesseract"]
    local _, _, _, rtData = Scheduler.resolveRecipe(rtFam, env.recipes["raw_tesseract"], env, { fluids = fluids, items = items }, {})
    for _, ii in ipairs((rtData and rtData.itemsIn) or {}) do
        items[ii.name .. ":" .. tostring(ii.damage or 0)] = 100000
    end
    for _, fi in ipairs((rtData and rtData.fluidsIn) or {}) do
        fluids[fi.name] = 10000000
    end

    env.recipes["molten_infinity"].enabled = true
    env.recipes["molten_infinity"].forever = true
    env.recipes["molten_infinity"].priority = 2
    env.recipes["molten_infinity"].convMode = "off"
    env.recipes["molten_infinity"].modifierIndex = 1
    local infFam = RecipesDB.BY_ID["molten_infinity"]
    local _, _, _, infData = Scheduler.resolveRecipe(infFam, env.recipes["molten_infinity"], env, { fluids = fluids, items = items }, {})
    for _, ii in ipairs((infData and infData.itemsIn) or {}) do
        items[ii.name .. ":" .. tostring(ii.damage or 0)] = 100000
    end
    for _, fi in ipairs((infData and infData.fluidsIn) or {}) do
        fluids[fi.name] = 10000000
    end

    env.armed = true
    local st21 = {}

    -- A. Tesseract stock = 5.8M (< 99% of 40M) -> 24/7 active AND Convergence ON (4x)
    local rtKey = rtFam.primaryOutput.name .. ":" .. tostring(rtFam.primaryOutput.damage or 0)
    items[rtKey] = 5800000
    dtpfStates[1].discountPct = 50
    Scheduler.step(env, st21)
    assertEq(st21.dtpfStatus[1].familyId, "raw_tesseract", "T21 DTPF runs priority-1 24/7 raw_tesseract")
    assertEq(st21.recipeStatus["raw_tesseract"].convBelowTarget, true, "T21A 5.8M < 40M sets convBelowTarget=true")
    assertEq(dtpfStates[1].workAllowed, true, "T21A workAllowed stays ON")
    assertEq(dtpfStates[1].conv, true, "T21A Convergence ON below 40M target")

    -- B. Stock = 39.8M (between 99% and 100% while active) -> hysteresis keeps Convergence ON
    items[rtKey] = 39800000
    Scheduler.step(env, st21)
    assertEq(st21.recipeStatus["raw_tesseract"].convBelowTarget, true, "T21B hysteresis keeps convBelowTarget=true at 39.8M")
    assertEq(dtpfStates[1].conv, true, "T21B hysteresis keeps Convergence ON")

    -- C. Stock hits 40.0M -> Convergence drops OFF (1x keepalive) while DTPF stays ON (24/7)!
    items[rtKey] = 40000000
    Scheduler.step(env, st21)
    assertEq(st21.recipeStatus["raw_tesseract"].convBelowTarget, false, "T21C >= 40M clears convBelowTarget")
    assertEq(dtpfStates[1].workAllowed, true, "T21C 24/7 keepalive keeps workAllowed ON")
    assertEq(dtpfStates[1].conv, false, "T21C Convergence OFF once >= 40M target")

    -- D. Stock dips to 39.8M (still >= 99% = 39.6M) -> hysteresis keeps Convergence OFF
    items[rtKey] = 39800000
    Scheduler.step(env, st21)
    assertEq(st21.recipeStatus["raw_tesseract"].convBelowTarget, false, "T21D hysteresis avoids rapid toggle at 39.8M")
    assertEq(dtpfStates[1].conv, false, "T21D Convergence stays OFF until < 99%")

    -- E. Stock falls below 99% (39.5M) -> Convergence turns back ON
    items[rtKey] = 39500000
    Scheduler.step(env, st21)
    assertEq(st21.recipeStatus["raw_tesseract"].convBelowTarget, true, "T21E < 99% re-enables convBelowTarget")
    assertEq(dtpfStates[1].conv, true, "T21E Convergence back ON")

    -- F. Cheap 24/7 molten_infinity with convMode="off" stays workAllowed=true, conv=false even at 50% discount
    env.recipes["raw_tesseract"].enabled = false
    Scheduler.step(env, st21)
    assertEq(st21.dtpfStatus[1].familyId, "molten_infinity", "T21F switched to 24/7 molten_infinity")
    assertEq(dtpfStates[1].workAllowed, true, "T21F molten_infinity workAllowed ON for discount keepalive")
    assertEq(dtpfStates[1].conv, false, "T21F convMode=off keeps cheap 24/7 keepalive at 1x")

    -- G. UI render check for [⚡<Tg] + clickable 40M button on Fleet & [⚡<Tgt] + [Conv < ...] on Recipes
    env.recipes["raw_tesseract"].enabled = true
    items[rtKey] = 5800000
    Scheduler.step(env, st21)
    local gpu21 = component._newMockGPU(160, 50)
    local ui21 = UI.new(env, st21, function() end)
    ui21.tab = 2; ui21:render()
    local tab2Txt = gpu21._allText()
    assert(tab2Txt:find("[⚡<Tg]", 1, true), "T21G Tab 2 Fleet renders [⚡<Tg] badge")
    assert(tab2Txt:find("[ 40M ]", 1, true) or tab2Txt:find("[40M]", 1, true), "T21G Tab 2 Fleet shows editable 40M threshold for 24/7 below_tgt")
    ui21.tab = 3; ui21.selectedFamilyId = "raw_tesseract"; ui21:render()
    local tab3Txt = gpu21._allText()
    assert(tab3Txt:find("[⚡<Tgt]", 1, true), "T21G Tab 3 Inspector renders [⚡<Tgt] policy chip")
    assert(tab3Txt:find("[Conv < ", 1, true), "T21G Tab 3 Inspector renders editable [Conv < ...] button on 24/7 below_tgt")
    for _, s in ipairs(gpu21._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end

    -- H. WebBridge mock TCP handshake + dtpf_state + dtpf_patch + dtpf_action under strict _G
    local WebBridge = require("lib.web_bridge")
    local wbOut, wbIn = {}, {}
    local mockSock = {
        finishConnect = function() return true end,
        read = function(_)
            if #wbIn > 0 then
                return table.remove(wbIn, 1)
            end
            return ""
        end,
        write = function(data)
            wbOut[#wbOut + 1] = data
            return #data
        end,
        close = function() end,
    }
    component._register("t21-inet", "internet", {
        connect = function(addr, port)
            local expect = "127.0.0.1:8766"
            local got = port and (tostring(addr) .. ":" .. tostring(port)) or tostring(addr)
            assertEq(got, expect, "T21H connects to loopback 127.0.0.1:8766")
            return mockSock
        end,
    })
    local savedFlag = 0
    local wb = WebBridge.new(env, st21, ui21, function() savedFlag = savedFlag + 1 end, Scheduler, Hardware)
    wb:step(200)
    assertEq(wb.ready, true, "T21H WebBridge finished connect")
    assert(#wbOut >= 1 and wbOut[1]:find('"role":"dtpf"', 1, true), "T21H sent dtpf hello packet")

    wbIn[#wbIn + 1] = '{"id":1,"op":"dtpf_state"}\n'
    wbIn[#wbIn + 1] = '{"id":2,"op":"dtpf_patch","patch":{"armed":false,"familyId":"molten_infinity","convMode":"below_tgt","target":1000000000}}\n'
    wbIn[#wbIn + 1] = '{"id":3,"op":"dtpf_action","action":"poll_now"}\n'
    local drained = wb:drain()
    assertEq(drained, true, "T21H WebBridge drained incoming RPCs")
    assertEq(env.armed, false, "T21H WebBridge patch updated armed=false")
    assertEq(env.recipes["molten_infinity"].convMode, "below_tgt", "T21H WebBridge patch updated convMode")
    assertEq(env.recipes["molten_infinity"].target, 1000000000, "T21H WebBridge patch updated target")
    assertEq(savedFlag >= 1, true, "T21H WebBridge triggered scheduleSave")
    assertEq(st21._forcePollNow, true, "T21H WebBridge poll_now set _forcePollNow")
    local allSent = table.concat(wbOut)
    assert(allSent:find('"id":1', 1, true) and allSent:find('"id":2', 1, true) and allSent:find('"id":3', 1, true),
        "T21H WebBridge replied to all 3 RPC IDs")
    wb:close()
    Hardware.resetClusterState()
    component._reset()
end

-- ============================================================================
-- TEST 22: Batch-Starvation Guard, Fallback Chain Cascade & Non-Clobbering
-- ============================================================================
do
    Hardware.resetClusterState()
    local env, fluids, items, odFluids, odItems, fsbSlots, fsbCalls, isbSlots, isbCalls, dtpfStates = setupStandardEnv()
    -- Register 2 more Storage Bus pairs so ch1, ch2, ch3 run distinct channels concurrently
    component._register("t22-fsb2", "fluid_storagebus", (makeStorageBus("t22-fsb2", 0, true)))
    component._register("t22-isb2", "me_storagebus", (makeStorageBus("t22-isb2", 0, false)))
    component._register("t22-fsb3", "fluid_storagebus", (makeStorageBus("t22-fsb3", 0, true)))
    component._register("t22-isb3", "me_storagebus", (makeStorageBus("t22-isb3", 0, false)))
    Scheduler.syncHardware(env)
    for i = 1, 3 do env.dtpfs[i].channelId = "ch" .. i end
    for _, rc in pairs(env.recipes) do
        rc.enabled = false
        rc.forever = false
        rc.maxDtpfs = 0
    end
    -- Zero out pre-populated items/fluids except catalysts & DTR so batch counts are exact
    for k in pairs(items) do items[k] = 0 end
    for k in pairs(fluids) do
        if not k:find("^exciteddt") and k ~= "dimensionallytranscendentresidue" then
            fluids[k] = 0
        end
    end

    local RecipesDB22 = require("lib.recipes_db")
    local function stockExactBatches(famId, batches)
        local fam = RecipesDB22.BY_ID[famId]
        local rc = env.recipes[famId]
        local _, _, _, tData = Scheduler.resolveRecipe(fam, rc, env, nil, { wantConvergence = false })
        for _, fi in ipairs(tData.fluidsIn or {}) do
            fluids[fi.name] = (fluids[fi.name] or 0) + (fi.amount or 144) * batches
        end
        for _, ii in ipairs(tData.itemsIn or {}) do
            local key = ii.name .. ":" .. tostring(ii.damage or 0)
            local amt = math.max(1, ii.amount or 1)
            items[key] = (items[key] or 0) + (amt * batches)
        end
    end

    -- Give raw_tesseract (<Tgt) exactly 1 batch; cosmic_neutronium (24/7, maxDtpfs=1) >=3 batches; molten_infinity as fallback
    env.recipes["raw_tesseract"].enabled = true
    env.recipes["raw_tesseract"].priority = 1
    env.recipes["raw_tesseract"].target = 1000000
    env.recipes["molten_cosmic_neutronium"].enabled = true
    env.recipes["molten_cosmic_neutronium"].forever = true
    env.recipes["molten_cosmic_neutronium"].priority = 2
    env.recipes["molten_cosmic_neutronium"].maxDtpfs = 1
    env.allowParallelSameRecipe = true
    env.fallbackEnabled = true
    env.fallbackFamilyId = "molten_infinity"

    stockExactBatches("raw_tesseract", 1)
    stockExactBatches("molten_cosmic_neutronium", 3)
    stockExactBatches("molten_infinity", 3)

    local st22 = {}
    Scheduler.step(env, st22)

    assertEq(st22.recipeStatus["raw_tesseract"].availBatches, 1, "T22 countAvailableBatches exact 1-batch detection")
    assertEq(st22.channelStatus["ch1"].familyId, "raw_tesseract", "T22 ch1 picks priority raw_tesseract")
    assertEq(st22.channelStatus["ch2"].familyId, "molten_cosmic_neutronium", "T22 Pass 2 starvation guard skips doubling 1-batch raw_tesseract -> cosmic_neutronium")
    assertEq(st22.channelStatus["ch3"].mode, "FALLBACK", "T22 ch3 respects maxDtpfs=1 on cosmic_neutronium -> Fallback")
    assertEq(st22.channelStatus["ch3"].familyId, "molten_infinity", "T22 ch3 runs visible fallbackFamilyId molten_infinity")

    -- Non-clobbering toggle test via WebBridge + UI
    local UI = require("lib.ui")
    local WebBridge = require("lib.web_bridge")
    component.gpu = component._newMockGPU(160, 50)
    local ui22 = UI.new(env, st22, function() end)
    local wb22 = WebBridge.new(env, st22, ui22, function() end, Scheduler, Hardware)

    env.fallbackFamilyId = "raw_tesseract"
    env.fallbackEnabled = true
    local okP1 = wb22:applyPatch({ familyId = "raw_tesseract", enabled = false })
    assertEq(okP1, true, "T22 WebBridge disabled raw_tesseract")
    assertEq(env.fallbackEnabled, true, "T22 disabling raw_tesseract does NOT clobber fallbackEnabled=false")

    ui22.tab = 3
    ui22.selectedFamilyId = "raw_tesseract"
    env.recipes["raw_tesseract"].enabled = true
    ui22:render()
    local clickedRow8 = false
    for _, hb in ipairs(ui22.hitboxes) do
        if hb.y1 == 8 and hb.y2 == 8 and hb.x1 == 87 then
            ui22:handleTouch(87, 8, 0)
            clickedRow8 = true
            break
        end
    end
    assert(clickedRow8, "T22 clicked Tab 3 row-8 ON/OFF toggle hitbox at x=87")
    assertEq(env.recipes["raw_tesseract"].enabled, false, "T22 UI row-8 toggle disabled raw_tesseract")
    assertEq(env.fallbackEnabled, true, "T22 UI row-8 toggle does NOT clobber fallbackEnabled=false")

    local snap22 = wb22:buildSnapshot()
    assertEq(snap22.policy.fallbackFamilyId, "raw_tesseract", "T22 WebBridge snapshot reports visible fallbackFamilyId")
    assertEq(snap22.policy.fallbackChain, nil, "T22 WebBridge snapshot has no hidden fallbackChain")
    local okFb = wb22:applyPatch({ fallbackFamilyId = "molten_infinity" })
    assertEq(okFb, true, "T22 WebBridge fallbackFamilyId patch succeeded")
    assertEq(env.fallbackFamilyId, "molten_infinity", "T22 fallbackFamilyId updated")

    -- Verify main.lua saves & Scheduler.ensureConfig reloads fallbackFamilyId + maxDtpfs cleanly
    local evQ22 = require("event")._queue
    while #evQ22 > 0 do table.remove(evQ22) end
    evQ22[1] = { "key_down", "kbd", string.byte("q"), 16 }
    local mainPath22 = _G.__DTPF_ROOT .. "/main.lua"
    local cfgPath22 = _G.__DTPF_ROOT .. "/config.cfg"
    __py_write_file(cfgPath22, '{ armed = false, fallbackEnabled = true, fallbackFamilyId = "molten_infinity", recipes = { raw_tesseract = { enabled = true, forever = true, maxDtpfs = 2 } } }\n')
    local m22, mErr22 = load(assert(__py_read_file(mainPath22)), "@" .. mainPath22)
    assert(m22, mErr22)
    m22()
    local saved22 = assert(__py_read_file(cfgPath22), "T22 main.lua wrote config.cfg")
    assert(saved22:find('fallbackFamilyId = "molten_infinity"', 1, true), "T22 main.lua persisted fallbackFamilyId")
    assert(saved22:find('maxDtpfs = 2', 1, true), "T22 main.lua persisted maxDtpfs = 2")
    assert(not saved22:find('fallbackChain', 1, true), "T22 main.lua does not write hidden fallbackChain")
    local parsed22 = assert(load("return " .. saved22:match("(%b{})")), "T22 valid saved Lua config")()
    local hydrated22 = Scheduler.ensureConfig(parsed22)
    assertEq(hydrated22.fallbackFamilyId, "molten_infinity", "T22 hydrated fallbackFamilyId")
    assertEq(hydrated22.recipes["raw_tesseract"].maxDtpfs, 2, "T22 hydrated maxDtpfs=2")
    __py_remove_vfs(cfgPath22)

    component.gpu = nil
    Hardware.resetClusterState()
    component._reset()
end

-- ============================================================================
-- TEST 23: 24/7 Discount Coverage Warning & DTPF GUI QoL
-- ============================================================================
do
    Hardware.resetClusterState()
    local RecipesDB = require("lib.recipes_db")
    local env, fluids, items, _, _, _, _, _, _, dtpfStates = setupStandardEnv()
    -- Enable Infinity Comb + Catalyst Dust ingredients for molten_infinity & Raw Tesseract rods
    items["gregtech:gt.metaitem.01:28032"] = 100000 -- Iron/Infinity Catalyst Dust check
    fluids["exciteddtcc"] = 500000
    fluids["exciteddtpc"] = 500000
    fluids["exciteddtrc"] = 500000
    fluids["exciteddtec"] = 500000
    fluids["exciteddtsc"] = 500000
    -- Give molten_infinity & raw_tesseract their required ingredients dynamically via RecipesDB
    for _, fid in ipairs({ "molten_infinity", "raw_tesseract" }) do
        local fam = RecipesDB.BY_ID[fid]
        for _, mod in ipairs((fam and fam.modifiers) or {}) do
            for _, tKey in ipairs({ "DTRC", "DTEC", "DTSC" }) do
                local tier = mod and mod.tiers and mod.tiers[tKey]
                if tier then
                    for _, ii in ipairs(tier.itemsIn or {}) do
                        items[tostring(ii.name) .. ":" .. tostring(ii.damage or 0)] = 100000
                    end
                    for _, fi in ipairs(tier.fluidsIn or {}) do
                        fluids[fi.name] = 10000000
                    end
                end
            end
        end
    end
    for _, rc in pairs(env.recipes) do
        rc.enabled = false
        rc.forever = false
        rc.maxDtpfs = 0
    end
    env.armed = true
    env.allowParallelSameRecipe = true
    env.fallbackEnabled = true
    env.fallbackFamilyId = "molten_infinity"
    env.recipes["raw_tesseract"].enabled = true
    env.recipes["raw_tesseract"].forever = true
    env.recipes["raw_tesseract"].maxDtpfs = 2

    local st23 = {}
    -- Test 0/5 covered on shared ch1 when Fallback is OFF & no 24/7 recipe is enabled
    env.recipes["raw_tesseract"].enabled = false
    env.fallbackEnabled = false
    Scheduler.step(env, st23)
    assert(st23.coverageWarning ~= nil, "T23 Fallback OFF + 0 24/7 recipes triggers coverageWarning")
    assertEq(st23.coverageWarning.covered, 0, "T23 0/5 covered when no 24/7 or Fallback")

    -- Configure 5 independent channels (ch1..ch5) like the live base so Max DTPFs = 2 covers 2/5
    env.channels = {}
    for c = 1, 5 do
        env.channels[c] = { id = "ch" .. c, name = "Passive ch" .. c, mode = "storage_bus", shareOnDemand = true, enabled = true, hatchAddr = "sb-fluid-1", busAddr = "sb-item-1" }
        env.dtpfs[c].channelId = "ch" .. c
    end
    env.fallbackEnabled = true
    env.fallbackFamilyId = "molten_infinity"
    env.recipes["raw_tesseract"].enabled = true
    env.recipes["raw_tesseract"].forever = true
    env.recipes["raw_tesseract"].maxDtpfs = 2
    Scheduler.step(env, st23)
    assert(st23.coverageWarning == nil, "T23 unexpected warning: " .. tostring(st23.coverageWarning and st23.coverageWarning.reason))

    -- Disable Fallback -> only 2/5 DTPFs covered by Raw Tesseract Max 2
    env.fallbackEnabled = false
    Scheduler.step(env, st23)
    assert(st23.coverageWarning ~= nil, "T23 Fallback OFF with Max 2 triggers coverageWarning")
    assertEq(st23.coverageWarning.kind, "unconfigured", "T23 partial Max-DTPF coverage kind is unconfigured")
    assertEq(st23.coverageWarning.covered, 2, "T23 partial Max-DTPF covered = 2")
    assertEq(st23.coverageWarning.uncovered, 3, "T23 partial Max-DTPF uncovered = 3")

    -- Re-enable Fallback, then remove Infinity Comb/Catalyst -> Fallback blocked
    env.fallbackEnabled = true
    local infFam = RecipesDB.BY_ID["molten_infinity"]
    local infMod = infFam.modifiers[env.recipes["molten_infinity"].modifierIndex or 1] or infFam.modifiers[1]
    local infTier = infMod.tiers.DTEC or infMod.tiers.DTRC
    local removedKey = tostring(infTier.itemsIn[1].name) .. ":" .. tostring(infTier.itemsIn[1].damage or 0)
    local savedInfAmt = items[removedKey]
    items[removedKey] = 0
    Scheduler.step(env, st23)
    assert(st23.coverageWarning ~= nil, "T23 blocked Fallback emits coverageWarning")
    assertEq(st23.coverageWarning.kind, "blocked", "T23 blocked Fallback kind is blocked")
    assertEq(st23.coverageWarning.familyId, "molten_infinity", "T23 blocked Fallback targets molten_infinity")
    items[removedKey] = savedInfAmt

    -- Per-DTPF role restrictions: passive_only and pinned warn; pinned_loop covers
    env.dtpfs[5].roleOverride = "passive_only"
    Scheduler.step(env, st23)
    assert(st23.coverageWarning ~= nil and st23.coverageWarning.kind == "unconfigured", "T23 passive_only DTPF warns on idle discount loss")
    env.dtpfs[5].roleOverride = "pinned"
    env.dtpfs[5].pinnedFamilyId = "raw_tesseract"
    Scheduler.step(env, st23)
    assert(st23.coverageWarning ~= nil and st23.coverageWarning.kind == "unconfigured", "T23 pinned <Tgt DTPF warns on idle discount loss")
    env.dtpfs[5].roleOverride = "pinned_loop"
    Scheduler.step(env, st23)
    assert(st23.coverageWarning == nil, "T23 pinned_loop DTPF cleanly covers 24/7 discount")
    env.dtpfs[5].roleOverride = "auto"
    env.dtpfs[5].pinnedFamilyId = nil

    -- UI verification: Tab 2 Row 9 warning + Fallback bar, Tab 1 Overview, [Log] modal, Tab 3 24/7 Max + [*Fallback]
    for k = 1, 5 do
        dtpfStates[k].active = true
        dtpfStates[k].maxProgress = 100
        dtpfStates[k].progress = 25
    end
    env.fallbackEnabled = false
    local stUi23 = {}
    Scheduler.step(env, stUi23)
    local UI = require("lib.ui")
    local gpu23 = component._newMockGPU(160, 50)
    local ui23 = UI.new(env, stUi23, function() end)

    local function clickT23(needle, yMin, yMax, xMin, xMax)
        for i = #ui23.hitboxes, 1, -1 do
            local hb = ui23.hitboxes[i]
            if (not yMin or hb.y1 >= yMin) and (not yMax or hb.y2 <= yMax)
                and (not xMin or hb.x1 >= xMin) and (not xMax or hb.x2 <= xMax) then
                local row = gpu23._rowText(hb.y1)
                if unicode.sub(row, hb.x1, hb.x2):find(needle, 1, true) then
                    ui23:handleTouch(hb.x1, hb.y1, 0)
                    ui23:render()
                    for _, s in ipairs(gpu23._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
                    return true
                end
            end
        end
        return false
    end

    ui23.tab = 1; ui23:render()
    for _, s in ipairs(gpu23._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu23._allText():find("24/7 DISCOUNT WARN", 1, true), "T23 Tab 1 Overview displays 24/7 DISCOUNT WARN")

    ui23.tab = 2; ui23:render()
    for _, s in ipairs(gpu23._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu23._rowText(9):find("[Fallback:ON]", 1, true), "T23 Tab 2 Row 9 displays warning + [Fallback:ON] button")
    assert(clickT23("[Fallback:ON]", 9, 9, 82, 160), "T23 clicked [Fallback:ON] on Tab 2 Row 9")
    assertEq(env.fallbackEnabled, true, "T23 [Fallback:ON] enabled Fallback")
    Scheduler.step(env, stUi23)
    ui23:render()
    for _, s in ipairs(gpu23._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu23._rowText(9):find("24/7 OK", 1, true), "T23 Tab 2 Row 9 shows 24/7 OK after Fallback enabled")

    ui23.tab = 3
    ui23.selectedFamilyId = "raw_tesseract"
    ui23:render()
    for _, s in ipairs(gpu23._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu23._rowText(9):find("[Max:2 DTPF]", 1, true), "T23 Tab 3 Row 9 shows [Max:2 DTPF] on 24/7 Raw Tesseract")
    assert(clickT23("[Max:2 DTPF]", 9, 9, 85, 160), "T23 clicked [Max:2 DTPF] on 24/7 Raw Tesseract")
    assertEq(env.recipes["raw_tesseract"].maxDtpfs, 3, "T23 [Max:2 DTPF] cycled to 3")
    env.recipes["raw_tesseract"].maxDtpfs = 2
    assert(clickT23("[Fallback]", 8, 8, 85, 160), "T23 clicked [Fallback] button on Tab 3 Row 8")
    assertEq(env.fallbackFamilyId, "raw_tesseract", "T23 [Fallback] switched fallbackFamilyId to raw_tesseract")

    ui23.logModalActive = true
    ui23.logModalTab = 1
    env.fallbackEnabled = false
    Scheduler.step(env, stUi23)
    ui23:render()
    for _, s in ipairs(gpu23._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu23._allText():find("24/7 Coverage", 1, true), "T23 Log Modal displays 24/7 Coverage alert")

    component.gpu = nil
    Hardware.resetClusterState()
    component._reset()
end

-- ============================================================================
-- TEST 24: Hatch/EU Telemetry, Power-Aware Routing, Level Maintainer & Mesh RPC
-- ============================================================================
do
    Hardware.resetClusterState()
    local parsedUHV = Hardware.parseDTPFSensor({
        "GT5U.EBF.heat.s\\\\13,500",
        "GT5U.multiblock.scanner.mei_amp\\\\§a8,796,093,022,208§r\\\\§a65,536§r\\\\§eUMV§r",
        "GT5U.multiblock.scanner.usage\\\\§a3,355,443,200,000§r",
        "GT5U.infodata.plasma_forge.convergence\\\\§aActive§r, perfect convergence achieved",
    })
    assertEq(parsedUHV.maxInputEu, 8796093022208, "T24 maxInputEu parsed from mei_amp")
    assertEq(parsedUHV.hatchAmps, 65536, "T24 hatchAmps parsed")
    assertEq(parsedUHV.hatchTier, "UMV", "T24 hatchTier parsed")
    assertEq(parsedUHV.liveEut, 3355443200000, "T24 liveEut parsed from usage")
    assert(type(parsedUHV.hatchLabel) == "string" and #parsedUHV.hatchLabel > 0, "T24 hatchLabel populated")

    local parsedEng = Hardware.parseDTPFSensor({
        "Max Energy Input: 137,438,953,472 EU/t (16,384A UEV)",
        "Currently uses: 52,428,800,000 EU/t",
    })
    assertEq(parsedEng.maxInputEu, 137438953472, "T24 English Max Energy Input")
    assertEq(parsedEng.hatchAmps, 16384, "T24 English hatchAmps")
    assertEq(parsedEng.hatchTier, "UEV", "T24 English hatchTier")
    assertEq(parsedEng.liveEut, 52428800000, "T24 English Currently uses")

    -- Setup 5 independent channels with heterogeneous hatches (#1 small 1024A UMV, #5 huge 65536A UMV)
    local env, fluids, items, _, _, _, _, _, _, dtpfStates = setupStandardEnv()
    local RecipesDB = require("lib.recipes_db")
    local WebBridge = require("lib.web_bridge")
    local UI = require("lib.ui")
    for _, fid in ipairs({ "molten_infinity", "molten_neutronium" }) do
        local fam = RecipesDB.BY_ID[fid]
        for _, mod in ipairs((fam and fam.modifiers) or {}) do
            for _, tKey in ipairs({ "DTRC", "DTEC", "DTSC" }) do
                local tier = mod and mod.tiers and mod.tiers[tKey]
                if tier then
                    for _, ii in ipairs(tier.itemsIn or {}) do
                        items[tostring(ii.name) .. ":" .. tostring(ii.damage or 0)] = 1000000
                    end
                    for _, fi in ipairs(tier.fluidsIn or {}) do
                        fluids[fi.name] = 100000000
                    end
                end
            end
        end
    end
    fluids["molten.neutronium"] = 0
    fluids["molten.infinity"] = 0

    local hatchSensors = {
        { "GT5U.EBF.heat.s\\\\13,500", "GT5U.multiblock.scanner.mei_amp\\\\137,438,953,472\\\\1,024\\\\UMV" },
        { "GT5U.EBF.heat.s\\\\13,500", "GT5U.multiblock.scanner.mei_amp\\\\549,755,813,888\\\\4,096\\\\UMV" },
        { "GT5U.EBF.heat.s\\\\13,500", "GT5U.multiblock.scanner.mei_amp\\\\137,438,953,472\\\\1,024\\\\UMV" },
        { "GT5U.EBF.heat.s\\\\13,500", "GT5U.multiblock.scanner.mei_amp\\\\137,438,953,472\\\\16,384\\\\UEV" },
        { "GT5U.EBF.heat.s\\\\13,500", "GT5U.multiblock.scanner.mei_amp\\\\8,796,093,022,208\\\\65,536\\\\UMV" },
    }
    env.channels = {}
    for c = 1, 5 do
        env.channels[c] = { id = "ch" .. c, name = "Passive ch" .. c, mode = "storage_bus", shareOnDemand = false, enabled = true, hatchAddr = "sb-fluid-1", busAddr = "sb-item-1" }
        env.dtpfs[c].channelId = "ch" .. c
        dtpfStates[c].active = true
        dtpfStates[c].maxProgress = 100
        dtpfStates[c].progress = 20
        local proxy = component.proxy("dtpf-" .. c)
        proxy.getSensorInformation = function() return hatchSensors[c] end
    end

    local infFam = RecipesDB.BY_ID["molten_infinity"]
    local infTier = infFam.modifiers[1].tiers.DTEC
    local directHuge, catHuge, estHuge = Scheduler.estimateDtpfPower(
        { active = true, maxInputEu = 8796093022208 }, infTier, "DTEC", 4, true
    )
    local directSmall, catSmall, estSmall = Scheduler.estimateDtpfPower(
        { active = true, maxInputEu = 137438953472 }, infTier, "DTEC", 4, true
    )
    assert(estHuge == true and estSmall == true, "T24 estimateDtpfPower flags estimate when liveEut absent")
    assert(directHuge > directSmall and catHuge > catSmall, "T24 larger hatch scales overclock EU/t & catalyst burn higher")

    for _, rc in pairs(env.recipes) do rc.enabled = false; rc.forever = false; rc.maxDtpfs = 0 end
    env.armed = true
    env.fallbackEnabled = false
    env.globalConvMode = "auto"
    env.allowParallelSameRecipe = true
    env.powerAwareAssign = true
    env.recipes["molten_infinity"].enabled = true
    env.recipes["molten_infinity"].forever = true
    env.recipes["molten_infinity"].priority = 1
    env.recipes["molten_infinity"].convMode = "force"
    env.recipes["molten_infinity"].maxDtpfs = 1
    env.recipes["molten_neutronium"].enabled = true
    env.recipes["molten_neutronium"].forever = true
    env.recipes["molten_neutronium"].priority = 2
    env.recipes["molten_neutronium"].convMode = "off"
    env.recipes["molten_neutronium"].maxDtpfs = 1

    local st24 = {}
    Scheduler.step(env, st24)
    assert(st24.recipeStatus["molten_infinity"].runnable, "T24 inf blocked: " .. tostring(st24.recipeStatus["molten_infinity"].reason))
    assert(st24.recipeStatus["molten_neutronium"].runnable, "T24 neut blocked: " .. tostring(st24.recipeStatus["molten_neutronium"].reason))
    assertEq(st24.channelStatus["ch5"].familyId, "molten_infinity", "T24 powerAware routes Converged job to largest hatch ch5")
    assertEq(st24.channelStatus["ch1"].familyId, "molten_neutronium", "T24 powerAware routes Non-Converged job to smallest hatch ch1")
    assert(st24.powerSummary and st24.powerSummary.totalEut > 0, "T24 powerSummary populated")

    env.powerAwareAssign = false
    st24 = {}
    Scheduler.step(env, st24)
    assertEq(st24.channelStatus["ch1"].familyId, "molten_infinity", "T24 non-powerAware falls back to slot order ch1")

    -- Level Maintainer: mock Mainnet AE2 proxy via component._register
    local craftCalls = {}
    local nextCraftStatus = { failMsg = nil, failErr = false }
    local cpusMock = {
        { name = "CPU #1", busy = false, storages = 1048576 },
        { name = "CPU #2", busy = false, storages = 1048576 },
        {
            name = "CPU #3",
            busy = true,
            storages = 1048576,
            cpu = {
                finalOutput = function()
                    return { name = "custom:busy_item", damage = 0, maxSize = 64, label = "Busy" }
                end,
            },
        },
        { name = "CPU #4", busy = false, storages = 1048576 },
    }
    local aeItemsStock = {
        { name = "custom:always_item", damage = 0, label = "Always", size = 0 },
        { name = "custom:auto_unused", damage = 0, label = "Auto Idle", size = 0 },
        { name = "custom:off_item", damage = 0, label = "Off", size = 0 },
        { name = "custom:busy_item", damage = 0, label = "Busy", size = 0 },
    }
    local realDemanded = infTier.itemsIn[1]
    aeItemsStock[#aeItemsStock + 1] = {
        name = realDemanded.name, damage = realDemanded.damage or 0, label = "Inf Cat", size = 10
    }
    component._register("mainnet-1", "me_interface", {
        getItemsInNetwork = function(filter)
            local out = {}
            for _, it in ipairs(aeItemsStock) do
                if (not filter or ((not filter.name or it.name == filter.name) and (filter.damage == nil or (it.damage or 0) == filter.damage))) then
                    out[#out + 1] = it
                end
            end
            return out
        end,
        getFluidsInNetwork = function(_) return {} end,
        getCpus = function() return cpusMock end,
        getCraftable = function(filter, cType)
            return {
                getItemStack = function() return { name = filter.name, damage = filter.damage or 0, maxSize = (cType == "fluid") and nil or 64 } end,
                request = function(amt)
                    if nextCraftStatus.failErr then return nil, "missing pattern" end
                    craftCalls[#craftCalls + 1] = { name = filter.name, damage = filter.damage or 0, amount = amt }
                    local fMsg = nextCraftStatus.failMsg
                    return {
                        isComputing = function() return false end,
                        hasFailed = function()
                            if fMsg then return true, fMsg end
                            return false
                        end,
                    }
                end,
            }
        end,
        getCraftables = function(filter)
            return {
                {
                    getItemStack = function() return { name = filter.name, damage = filter.damage or 0 } end,
                    request = function(amt)
                        if nextCraftStatus.failErr then return nil, "missing pattern" end
                        craftCalls[#craftCalls + 1] = { name = filter.name, damage = filter.damage or 0, amount = amt }
                        local fMsg = nextCraftStatus.failMsg
                        return {
                            isComputing = function() return false end,
                            hasFailed = function()
                                if fMsg then return true, fMsg end
                                return false
                            end,
                        }
                    end,
                }
            }
        end,
    })
    env.mainnetAddr = "mainnet-1"
    env.maintFreeCpus = 1
    env.maintPollSec = 5
    env.maintRules = {
        { id = "r_always", type = "item", name = "custom:always_item", damage = 0, label = "Always", target = 500, batch = 250, mode = "always" },
        { id = "r_auto_dem", type = "item", name = realDemanded.name, damage = realDemanded.damage or 0, label = "Inf Cat", target = 1000, batch = 100, mode = "auto" },
        { id = "r_auto_idle", type = "item", name = "custom:auto_unused", damage = 0, label = "Auto Idle", target = 500, batch = 100, mode = "auto" },
        { id = "r_off", type = "item", name = "custom:off_item", damage = 0, label = "Off", target = 500, batch = 100, mode = "off" },
        { id = "r_busy", type = "item", name = "custom:busy_item", damage = 0, label = "Busy", target = 500, batch = 100, mode = "always" },
    }

    -- Disabled Maintainer must fire 0 crafts
    env.maintEnabled = false
    st24._forceMaintSync = true
    Scheduler.step(env, st24)
    assertEq(#craftCalls, 0, "T24 Maintainer OFF issues 0 craft requests")

    -- Enabled: freeCpus = 3 (> reserve 1). Poll 1 dispatches highest deficit (custom:always_item, 100% deficit);
    -- Poll 2 sees r_always inFlight and dispatches r_auto_dem (99% deficit). auto_idle, off_item, and busy_item stay skipped!
    env.maintEnabled = true
    st24._forceMaintSync = true
    Scheduler.step(env, st24)
    st24._forceMaintSync = true
    Scheduler.step(env, st24)
    local dispatched = {}
    for _, c in ipairs(craftCalls) do dispatched[c.name] = c.amount end
    assertEq(dispatched["custom:always_item"], 250, "T24 Maintainer dispatches ALWAYS rule when low")
    assertEq(dispatched[realDemanded.name], 100, "T24 Maintainer dispatches AUTO rule demanded by enabled recipe")
    assert(dispatched["custom:auto_unused"] == nil, "T24 Maintainer skips un-demanded AUTO rule")
    assert(dispatched["custom:off_item"] == nil, "T24 Maintainer skips OFF rule")
    assert(dispatched["custom:busy_item"] == nil, "T24 Maintainer dedups item already crafting on CPU")

    -- Free CPU headroom guard: if freeCpus <= maintFreeCpus, 0 crafts dispatched
    craftCalls = {}
    env.maintRules = {
        { id = "r_headroom", type = "item", name = "custom:always_item", damage = 0, label = "Always", target = 500, batch = 250, mode = "always" },
    }
    cpusMock = {
        { name = "CPU #1", busy = false, storages = 1048576 },
        { name = "CPU #2", busy = true, storages = 1048576, cpu = { finalOutput = function() return { name = "other:x", damage = 0, maxSize = 64, label = "Other" } end } },
    }
    st24._forceMaintSync = true
    Scheduler.step(env, st24)
    assertEq(#craftCalls, 0, "T24 Maintainer freeCpus == reserve blocks dispatch")

    -- Verify 60s failure backoff when request fails
    env.maintRules = {
        { id = "r_fail", type = "item", name = "custom:always_item", damage = 0, label = "Always", target = 500, batch = 250, mode = "always" },
    }
    cpusMock = {
        { name = "CPU #1", busy = false, storages = 1048576 },
        { name = "CPU #2", busy = false, storages = 1048576 },
    }
    craftCalls = {}
    nextCraftStatus.failErr = true
    st24._forceMaintSync = true
    Scheduler.step(env, st24) -- fails -> records backoff
    nextCraftStatus.failErr = false
    st24._forceMaintSync = true
    Scheduler.step(env, st24) -- within 60s -> must still be backed off!
    assertEq(#craftCalls, 0, "T24 Maintainer 60s failure backoff blocks immediate retry")

    -- Test WebBridge:executeRpcTable + Modem chunked DTPF_REPLY
    local modemSent = {}
    component._register("modem-1", "modem", {
        isWireless = function() return true end,
        setStrength = function() return 400 end,
        open = function(port) return port == Hardware.MESH_PORT end,
        send = function(target, port, ...)
            modemSent[#modemSent + 1] = { target = target, port = port, args = { ... } }
            return true
        end,
        broadcast = function(port, ...)
            modemSent[#modemSent + 1] = { target = "*", port = port, args = { ... } }
            return true
        end,
    })
    local gpu24 = component._newMockGPU(160, 50)
    component.gpu = gpu24
    local ui24 = UI.new(env, st24, function() end)
    local wb24 = WebBridge.new(env, st24, ui24, function() end, Scheduler, Hardware)
    local patchRes = wb24:executeRpcTable({
        id = "p1",
        op = "dtpf_patch",
        patch = {
            powerAwareAssign = true,
            maintEnabled = true,
            maintFreeCpus = 2,
            maintRule = { name = "custom:added_rule", label = "Added", target = 900, batch = 50, mode = "always" },
        },
    })
    assertEq(patchRes.policy.powerAwareAssign, true, "T24 RPC patch updated powerAwareAssign")
    assertEq(patchRes.policy.maintFreeCpus, 2, "T24 RPC patch updated maintFreeCpus")
    assertEq(#env.maintRules, 2, "T24 RPC patch appended maintRule")
    wb24:executeRpcTable({ id = "p2", op = "dtpf_patch", patch = { maintRule = { index = 2, delete = true } } })
    assertEq(#env.maintRules, 1, "T24 RPC patch deleted maintRule")

    -- Test Scheduler.collectRecipeMaintInputs + maintRulesBatch + type+name+damage dedup + smart default target/batch
    local rtInps = Scheduler.collectRecipeMaintInputs(env, "raw_tesseract")
    assert(#rtInps >= 2, "T24 collectRecipeMaintInputs returns catalyst + consumed inputs for raw_tesseract")
    for _, x in ipairs(rtInps) do
        assert(x.name ~= "dimensionallytranscendentresidue", "T24 collectRecipeMaintInputs excludes DTR")
    end
    local countBeforeDedup = #env.maintRules
    wb24:executeRpcTable({
        id = "p3",
        op = "dtpf_patch",
        patch = { maintRule = { type = "item", name = "custom:dedup", damage = 1, label = "Dedup", amount = 64 } },
    })
    assertEq(#env.maintRules, countBeforeDedup + 1, "T24 maintRule creates with default target/batch")
    assert(env.maintRules[#env.maintRules].target >= 1000 and env.maintRules[#env.maintRules].batch >= 64, "T24 smart default target/batch populated")
    wb24:executeRpcTable({
        id = "p4",
        op = "dtpf_patch",
        patch = { maintRule = { type = "item", name = "custom:dedup", damage = 1, target = 4096, mode = "always" } },
    })
    assertEq(#env.maintRules, countBeforeDedup + 1, "T24 type+name+damage deduplicates instead of appending duplicate rule")
    assertEq(env.maintRules[#env.maintRules].target, 4096, "T24 deduped rule updated target")
    wb24:executeRpcTable({
        id = "p5",
        op = "dtpf_patch",
        patch = {
            maintRulesBatch = {
                { type = rtInps[1].type, name = rtInps[1].name, damage = rtInps[1].damage, label = rtInps[1].label, amount = rtInps[1].amount },
                { type = rtInps[2].type, name = rtInps[2].name, damage = rtInps[2].damage, label = rtInps[2].label, amount = rtInps[2].amount },
            },
        },
    })
    assert(Scheduler.findMaintRule(env, rtInps[2].type, rtInps[2].name, rtInps[2].damage) ~= nil, "T24 maintRulesBatch added recipe inputs")

    modemSent = {}
    local handled = Hardware.handleMeshMessage(wb24, "modem-1", "mainnet-modem", Hardware.MESH_PORT, "DTPF_CMD", "req-42", serialization.serialize({ id = "req-42", op = "dtpf_state" }))
    assert(handled == true, "T24 handleMeshMessage handled DTPF_CMD")
    assert(#modemSent >= 2, "T24 chunked DTPF_REPLY split across >= 2 packets for large snapshot")
    local parts = {}
    local expectedTotal = modemSent[1].args[4]
    for idx, pkt in ipairs(modemSent) do
        assertEq(pkt.port, Hardware.MESH_PORT, "T24 reply sent on MESH_PORT")
        assertEq(pkt.args[1], "DTPF_REPLY", "T24 reply msgType == DTPF_REPLY")
        assertEq(pkt.args[2], "req-42", "T24 reply reqId == req-42")
        assertEq(pkt.args[3], idx, "T24 reply chunk idx monotonic")
        assertEq(pkt.args[4], expectedTotal, "T24 reply chunk total consistent")
        assert(#pkt.args[5] <= 5500, "T24 reply chunk <= 5500 bytes")
        parts[idx] = pkt.args[5]
    end
    local decoded = serialization.unserialize(table.concat(parts))
    assert(type(decoded) == "table", "T24 reassembled DTPF_REPLY unserializes cleanly")
    assert(decoded.power ~= nil and decoded.maintainer ~= nil, "T24 reassembled snapshot has power and maintainer")
    assertEq(decoded.policy.powerAwareAssign, true, "T24 reassembled snapshot has policy.powerAwareAssign == true")

    -- UI render + glyph capture on Tabs 1, 2, 4 + Maintainer modal
    ui24.tab = 1
    ui24:render()
    for _, s in ipairs(gpu24._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu24._allText():find("[M]Maint", 1, true), "T24 Tab 1 footer renders [M]Maint")

    ui24.tab = 2
    ui24:render()
    for _, s in ipairs(gpu24._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu24._allText():find("Pwr:", 1, true), "T24 Tab 2 renders Pwr:Smart/Order toggle")

    ui24.tab = 3
    ui24.selectedFamilyId = "raw_tesseract"
    env.maintRules = {}
    ui24:render()
    for _, s in ipairs(gpu24._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    local clickedMaintY = nil
    for ry = 1, 49 do
        if gpu24._rowText(ry):find("[  +Maint  ]", 1, true) then
            clickedMaintY = ry
            break
        end
    end
    assert(clickedMaintY ~= nil, "T24 Tab 3 renders [+Maint] tags on recipe inputs")
    ui24:handleTouch(150, clickedMaintY, 0)
    ui24:render()
    for _, s in ipairs(gpu24._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assertEq(#env.maintRules, 1, "T24 clicking Tab 3 input row creates Maintainer rule")
    assert(gpu24._rowText(clickedMaintY):find("[↻", 1, true), "T24 Tab 3 input tag switched to [Auto]")

    ui24.tab = 4
    ui24:render()
    for _, s in ipairs(gpu24._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu24._allText():find("Maint:", 1, true), "T24 Tab 4 renders Maint:ON/OFF toggle")

    ui24.maintModalActive = true
    ui24.maintFilterActive = true
    ui24:render()
    for _, s in ipairs(gpu24._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(gpu24._allText():find("AE2 LEVEL MAINTAINER:", 1, true), "T24 Maintainer modal renders")
    assert(gpu24._allText():find("[+ Selected Recipe]", 1, true) and gpu24._allText():find("[Show:Active]", 1, true),
        "T24 Maintainer modal renders [+ Selected Recipe] and [Show:Active]")
    -- Click [+ Selected Recipe] footer button and verify all raw_tesseract inputs added
    for i = #ui24.hitboxes, 1, -1 do
        local hb = ui24.hitboxes[i]
        if hb.y1 == 45 and unicode.sub(gpu24._rowText(45), hb.x1, hb.x2):find("Selected Recipe", 1, true) then
            ui24:handleTouch(hb.x1, hb.y1, 0)
            break
        end
    end
    ui24:render()
    for _, s in ipairs(gpu24._calls) do _G.__RENDERED_GPU_CALLS[#_G.__RENDERED_GPU_CALLS + 1] = s end
    assert(#env.maintRules >= #rtInps, "T24 [+ Selected Recipe] maintains all inputs of selected recipe")

    -- T24b: O(1) getItemInNetwork/getFluidInNetwork, hysteresis lowThreshold, exponential backoff, multi-dispatch, and STOCK_CLAIMS overlap
    local o1Calls = { item = 0, fluid = 0, fullItems = 0, fullFluids = 0 }
    local o1Dispatched = {}
    local o1Cpus = {
        { name = "CPU #1", busy = false, storages = 1048576 },
        { name = "CPU #2", busy = false, storages = 1048576 },
        { name = "CPU #3", busy = false, storages = 1048576 },
        { name = "CPU #4", busy = false, storages = 1048576 },
    }
    local o1Fail = false
    component._register("mainnet-o1", "me_controller", {
        getItemInNetwork = function(filter)
            o1Calls.item = o1Calls.item + 1
            if type(filter) == "table" and filter.name == "custom:hyst" then
                return { name = "custom:hyst", damage = 0, size = 450, label = "Hyst" } -- below target 500, above lowThreshold 400
            elseif type(filter) == "table" and filter.name == "custom:low_a" then
                return { name = "custom:low_a", damage = 0, size = 10, label = "LowA" }
            end
            return nil
        end,
        getFluidInNetwork = function(fname)
            o1Calls.fluid = o1Calls.fluid + 1
            if fname == "exciteddtec" then return { name = "exciteddtec", amount = 5000, label = "DTEC" } end
            return nil
        end,
        getItemsInNetwork = function()
            o1Calls.fullItems = o1Calls.fullItems + 1
            return {}
        end,
        getFluidsInNetwork = function()
            o1Calls.fullFluids = o1Calls.fullFluids + 1
            return {}
        end,
        getCpus = function() return o1Cpus end,
        getCraftable = function(filter, cType)
            return {
                getItemStack = function() return { name = filter.name, damage = filter.damage or 0, maxSize = (cType == "fluid") and nil or 64 } end,
                request = function(amt)
                    if o1Fail then return nil, "no cpu" end
                    o1Dispatched[filter.name] = (o1Dispatched[filter.name] or 0) + amt
                    return { isComputing = function() return false end, hasFailed = function() return false end }
                end,
            }
        end,
    })
    env.mainnetAddr = "mainnet-o1"
    env.maintEnabled = true
    env.maintFreeCpus = 1
    env.maintMaxDispatch = 2
    env.maintConflictMode = "defer"
    env.maintRules = {
        { id = "hyst", type = "item", name = "custom:hyst", damage = 0, label = "Hyst", target = 500, lowThreshold = 400, batch = 100, mode = "always" },
        { id = "lowa", type = "item", name = "custom:low_a", damage = 0, label = "LowA", target = 500, lowThreshold = 200, batch = 150, mode = "always" },
        { id = "lowb", type = "fluid", name = "exciteddtec", damage = 0, label = "DTEC", target = 100000, lowThreshold = 50000, batch = 20000, mode = "always" },
    }
    st24._maintTrack = {}
    st24._lastMaintSync = nil
    st24.stockPeer = nil
    st24._forceMaintSync = true
    local compMod = require("computer")
    local baseT = compMod.uptime()
    Scheduler.step(env, st24, { nowUptime = baseT })
    assert(o1Calls.item >= 2 and o1Calls.fluid >= 1, "T24b used O(1) getItemInNetwork and getFluidInNetwork")
    assertEq(o1Calls.fullItems, 0, "T24b avoided full getItemsInNetwork scan")
    assertEq(o1Calls.fullFluids, 0, "T24b avoided full getFluidsInNetwork scan")
    assert(o1Dispatched["custom:hyst"] == nil, "T24b hysteresis skipped item above lowThreshold (450 >= 400)")
    assertEq(o1Dispatched["custom:low_a"], 150, "T24b multi-dispatch crafted LowA")
    assertEq(o1Dispatched["exciteddtec"], 20000, "T24b multi-dispatch crafted DTEC in same cycle")

    -- Test STOCK_CLAIMS overlap deferral & warn mode
    o1Dispatched = {}
    st24._maintTrack = {}
    local handledClaims = Hardware.handleMeshMessage(wb24, "modem-1", "stock-modem", Hardware.MESH_PORT, "STOCK_CLAIMS",
        serialization.serialize({ armed = true, keys = { "i:custom:low_a:0", "f:exciteddtec" } }))
    assert(handledClaims == true, "T24b handleMeshMessage handled STOCK_CLAIMS")
    st24._forceMaintSync = true
    Scheduler.step(env, st24, { nowUptime = compMod.uptime() + 1 })
    assertEq(o1Dispatched["custom:low_a"], nil, "T24b defer mode blocked overlap craft when Stock OC armed")
    assertEq(o1Dispatched["exciteddtec"], nil, "T24b defer mode blocked fluid overlap craft when Stock OC armed")
    assertEq(st24.maintStatus.overlapCount, 2, "T24b maintStatus tracks overlapCount")
    assertEq(st24.maintStatus.stockPeerOnline, true, "T24b maintStatus tracks stockPeerOnline")

    -- Test warn mode emits warning but still dispatches if not busy
    env.maintConflictMode = "warn"
    st24._forceMaintSync = true
    Scheduler.step(env, st24, { nowUptime = compMod.uptime() + 2 })
    assertEq(o1Dispatched["custom:low_a"], 150, "T24b warn mode allows dispatch with warning")

    -- Test exponential backoff (30s -> 60s -> 120s)
    env.maintRules = {
        { id = "exp_fail", type = "item", name = "custom:low_a", damage = 0, label = "LowA", target = 500, batch = 50, mode = "always" },
    }
    st24.stockPeer = nil
    st24._maintTrack = {}
    o1Fail = true
    st24._forceMaintSync = true
    local failT = compMod.uptime() + 100
    Scheduler.step(env, st24, { nowUptime = failT }) -- fail 1 -> failT + 30
    assertEq(st24._maintTrack["exp_fail"].failCount, 1, "T24b fail 1 increments failCount")
    assertEq(st24._maintTrack["exp_fail"].backoffUntil, failT + 30, "T24b fail 1 -> 30s backoff")
    st24._forceMaintSync = true
    Scheduler.step(env, st24, { nowUptime = failT + 31 }) -- fail 2 -> +60s
    assertEq(st24._maintTrack["exp_fail"].failCount, 2, "T24b fail 2 increments failCount")
    assertEq(st24._maintTrack["exp_fail"].backoffUntil, failT + 91, "T24b fail 2 -> 60s backoff")

    -- Test DTPF_CLAIMS emission via pushMeshMetrics (includes maintInfo + passiveInfo & suppresses stock-only resends)
    modemSent = {}
    Hardware._lastClaimsRaw = nil
    Hardware._lastClaimsSig = nil
    Hardware.pushMeshMetrics(env, st24, 2100, nil, true)
    local sentClaimsPkt, claimsRawLen = nil, 0
    for _, pkt in ipairs(modemSent) do
        if pkt.args[1] == "DTPF_CLAIMS" then
            claimsRawLen = #tostring(pkt.args[2] or "")
            sentClaimsPkt = serialization.unserialize(pkt.args[2])
        end
    end
    assert(sentClaimsPkt ~= nil, "T24b pushMeshMetrics emits DTPF_CLAIMS packet")
    assert(claimsRawLen <= 5500, "T24b DTPF_CLAIMS packet fits within 5500B MTU: " .. tostring(claimsRawLen))
    assert(type(sentClaimsPkt.maintInfo) == "table" and next(sentClaimsPkt.maintInfo) ~= nil, "T24b DTPF_CLAIMS includes maintInfo")
    assert(type(sentClaimsPkt.passiveInfo) == "table" and next(sentClaimsPkt.passiveInfo) ~= nil, "T24b DTPF_CLAIMS includes passiveInfo")
    local anyK, anyM = next(sentClaimsPkt.maintInfo)
    assert(anyM.tgt ~= nil and anyM.stk ~= nil and anyM.m ~= nil, "T24b maintInfo has tgt/stk/m fields for " .. tostring(anyK))
    -- Fluctuating only stk within 15s throttle window must NOT resend DTPF_CLAIMS
    st24._dtpfClaims.maintInfo[anyK].stk = (tonumber(anyM.stk) or 0) + 12345
    modemSent = {}
    Hardware.pushMeshMetrics(env, st24, 2103, nil, false)
    local resendClaims = false
    for _, pkt in ipairs(modemSent) do
        if pkt.args[1] == "DTPF_CLAIMS" then resendClaims = true end
    end
    assert(resendClaims == false, "T24b DTPF_CLAIMS suppresses volatile stock-only resends inside 15s window")

    -- Test DTPF_HANDOFF passive + maint rule application & DTPF_HANDOFF_ACK reply
    modemSent = {}
    local hReq = {
        items = {
            { ruleId = "r_p", kind = "passive", familyId = "astral_titanium_quantum", target = 7500000 },
            { ruleId = "r_m", kind = "maint", type = "fluid", name = "exciteddt_h", label = "Excited DT-H", target = 500000, batch = 100000 },
        },
    }
    Hardware.handleMeshMessage(wb24, "modem-1", "stock-modem", Hardware.MESH_PORT, "DTPF_HANDOFF", "dh-7", serialization.serialize(hReq))
    assert(env.recipes.astral_titanium_quantum.enabled == true, "DTPF_HANDOFF enables passive recipe family")
    assertEq(env.recipes.astral_titanium_quantum.target, 7500000, "DTPF_HANDOFF updates passive target")
    local handedMaint = Scheduler.findMaintRule(env, "fluid", "exciteddt_h", 0)
    assert(handedMaint ~= nil and handedMaint.target == 500000, "DTPF_HANDOFF installs DTPF maintRule")
    local ackPkt = nil
    for _, pkt in ipairs(modemSent) do
        if pkt.args[1] == "DTPF_HANDOFF_ACK" and pkt.args[2] == "dh-7" then
            ackPkt = serialization.unserialize(pkt.args[3])
        end
    end
    assert(ackPkt ~= nil and ackPkt.ok == true, "DTPF_HANDOFF emits DTPF_HANDOFF_ACK with reqId dh-7")
    assertEq(ackPkt.passiveCount, 1, "DTPF_HANDOFF_ACK counts 1 passive")
    assertEq(ackPkt.maintCount, 1, "DTPF_HANDOFF_ACK counts 1 maint rule")

    -- Test Hardware.openMeshPort sets GTNH_WAKE, GTNH_WAKE responds with DTPF_METRICS, and stale Mainnet wake is rate-limited
    local dtpfWakeMsg, dtpfWakeSet = nil, 0
    component._register("modem-w24", "modem", {
        isWireless = function() return true end,
        open = function() return true end,
        setStrength = function() return 400 end,
        getWakeMessage = function() return dtpfWakeMsg end,
        setWakeMessage = function(m) dtpfWakeSet = dtpfWakeSet + 1; dtpfWakeMsg = m; return dtpfWakeMsg end,
        send = function(addr, port, ...) modemSent[#modemSent + 1] = { addr = addr, port = port, args = { ... } }; return true end,
        broadcast = function(port, ...) modemSent[#modemSent + 1] = { port = port, args = { ... } }; return true end,
    })
    Hardware.openMeshPort()
    Hardware.openMeshPort()
    assertEq(dtpfWakeMsg, "GTNH_WAKE", "T24b openMeshPort configures GTNH_WAKE wake message")
    assertEq(dtpfWakeSet, 1, "T24b openMeshPort does not repeat setWakeMessage once configured")
    modemSent = {}
    assert(Hardware.handleMeshMessage(wb24, "modem-w24", "ae2-wake", Hardware.MESH_PORT, "GTNH_WAKE", "dtpf"), "T24b GTNH_WAKE handled")
    local sawWakeMetrics = false
    for _, pkt in ipairs(modemSent) do if pkt.args[1] == "DTPF_METRICS" then sawWakeMetrics = true end end
    assert(sawWakeMetrics == true, "T24b GTNH_WAKE immediately pushed DTPF_METRICS")
    Hardware._lastMainnetSeen = 1000
    Hardware._lastMainnetWakeAt = -1000
    modemSent = {}
    Hardware.pushMeshMetrics(env, st24, 2200, nil, true)
    local wakeCnt1 = 0
    for _, pkt in ipairs(modemSent) do if pkt.args[1] == "GTNH_WAKE" then wakeCnt1 = wakeCnt1 + 1 end end
    assertEq(wakeCnt1, 1, "T24b stale Mainnet emitted 1 GTNH_WAKE")
    modemSent = {}
    Hardware.pushMeshMetrics(env, st24, 2210, nil, true)
    local wakeCnt2 = 0
    for _, pkt in ipairs(modemSent) do if pkt.args[1] == "GTNH_WAKE" then wakeCnt2 = wakeCnt2 + 1 end end
    assertEq(wakeCnt2, 0, "T24b Mainnet GTNH_WAKE suppressed within 60s window")

    -- Test Mainnet Maintainer status clarity & push_recipe_inputs (Mainnet Stock + Local fallback)
    local nowMain = compMod.uptime()
    st24.stockPeer = { addr = "stock-modem", lastSeen = nowMain, armed = true, keys = {} }
    st24._forceMaintSync = true
    Scheduler.step(env, st24, { nowUptime = nowMain + 1 })
    assertEq(st24.maintStatus.maintMode, "mainnet", "T24b maintMode reports mainnet when Stock OC armed")
    modemSent = {}
    local famId = RecipesDB.FAMILIES[1].id
    local pOn = wb24:executeRpcTable({ id = "push-on", op = "push_recipe_inputs", familyId = famId })
    assertEq(pOn.ok, true, "T24b push_recipe_inputs online succeeds")
    assertEq(pOn.target, "mainnet", "T24b push_recipe_inputs routes to mainnet Stock when armed")
    local sawDtpfPushPkt = false
    for _, pkt in ipairs(modemSent) do
        if pkt.args[1] == "STOCK_PUSH_RULES" then sawDtpfPushPkt = true end
    end
    assert(sawDtpfPushPkt == true, "T24b push_recipe_inputs emitted STOCK_PUSH_RULES packet")
    assert(Hardware.handleMeshMessage(wb24, "modem-w24", "ae2-wake", Hardware.MESH_PORT, "STOCK_PUSH_ACK", "r-ack",
        serialization.serialize({ ok = true, added = pOn.count })), "T24b handleMeshMessage handled STOCK_PUSH_ACK")
    assertEq(st24._lastStockPushAck.ack.ok, true, "T24b recorded STOCK_PUSH_ACK")

    st24.stockPeer = nil
    env.maintEnabled = false
    st24._forceMaintSync = true
    Scheduler.step(env, st24, { nowUptime = compMod.uptime() + 20 })
    assertEq(st24.maintStatus.maintMode, "off", "T24b maintMode reports off when Stock offline and local disabled")
    local pOff = wb24:executeRpcTable({ id = "push-off", op = "push_recipe_inputs", familyId = famId })
    assertEq(pOff.ok, true, "T24b push_recipe_inputs offline fallback succeeds")
    assertEq(pOff.target, "local", "T24b push_recipe_inputs falls back to local when Stock offline")
    assertEq(env.maintEnabled, true, "T24b local fallback auto-enables maintEnabled")

    component.gpu = nil
    Hardware.resetClusterState()
    component._reset()
end

return "OK"
"""
            res = host.exec_lua(test_suite, "test_suite")
            assert res == "OK", f"Unexpected test result: {res}"

            # Check every rendered glyph in GPU calls is strictly width-1 in font.hex!
            bad_glyphs = []
            # Query all unique non-ASCII chars via Lua helper
            non_ascii_json = host.exec_lua(
                """
                local seen = {}
                local out = {}
                for _, s in ipairs(_G.__RENDERED_GPU_CALLS or {}) do
                    for _, cp in utf8.codes(s) do
                        if cp > 127 and not seen[cp] then
                            seen[cp] = true
                            out[#out + 1] = tostring(cp)
                        end
                    end
                end
                return table.concat(out, ",")
                """,
                "glyph_audit",
            )
            if non_ascii_json:
                for cp_s in non_ascii_json.split(","):
                    if cp_s:
                        cp = int(cp_s)
                        w = font_widths.get(cp, -1)
                        if w != 1:
                            bad_glyphs.append((chr(cp), hex(cp), w))
            assert not bad_glyphs, f"Found non-width-1 rendered glyphs: {bad_glyphs}"

            check_out = "\n".join(host.stdout)
            assert "=== DTPF AUTOMATION READ-ONLY CHECK ===" in check_out, "Missing --check header"
            assert "CHECK COMPLETE (NO HARDWARE MODIFIED)" in check_out, "Missing --check footer"
            assert "Molten Shirabon" in check_out, "Missing recipe in --check output"
            assert "[OD #1]" in check_out and "[OD #2]" in check_out and "[OD #3]" in check_out, "Missing per-DTPF OD roles in T15 --check"

            # Verify 64-bit libjnlua53 live heap fits comfortably inside 2x Memory Tier 3.5 (3,686 KB scaled)
            mem_host = LuaHost(Path(td))
            try:
                L = mem_host.lib
                L.lua_gc.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
                L.lua_gc.restype = ctypes.c_int
                mem_host.exec_lua(
                    """
                    local component = require("component")
                    component.gpu = component._newMockGPU(160, 50)
                    local Scheduler = require("lib.scheduler")
                    local UI = require("lib.ui")
                    local WebBridge = require("lib.web_bridge")
                    local cfg = Scheduler.ensureConfig({ armed = true, logLevel = "raw" })
                    local st = {}
                    Scheduler.step(cfg, st)
                    local ui = UI.new(cfg, st, function() end)
                    local wb = WebBridge.new(cfg, st, ui, function() end, Scheduler, require("lib.hardware"))
                    for t = 1, 4 do ui.tab = t; ui:render() end
                    ui.logModalActive = true
                    ui.logModalTab = 1; ui:render()
                    ui.logModalTab = 2; ui:render()
                    ui.logModalActive = false
                    ui.maintModalActive = true; ui:render()
                    rawset(_G, "__mem_hold", { cfg, st, ui, wb })
                    """,
                    "mem_check",
                )
                L.lua_gc(mem_host.L, 2, 0)
                live_kb = L.lua_gc(mem_host.L, 3, 0)
                assert live_kb < 2850, f"Live JNLua heap too large for 2x Tier 3.5 RAM: {live_kb} KB"
            finally:
                mem_host.close()

            print(f"ALL 24 OFFLINE TEST SUITES PASSED (0 bad-width glyphs, {live_kb} KB live JNLua heap, Lua 5.3 + OpenOS verified).")
            print("--- Sample main.lua --check output ---")
            for line in check_out.splitlines():
                print("  " + line)
        finally:
            host.close()


if __name__ == "__main__":
    run_all_tests()
