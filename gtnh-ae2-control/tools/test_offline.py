#!/usr/bin/env python3
"""Offline Lua 5.3 + OpenComputers JNLua test suite for gtnh-ae2-control."""

from __future__ import annotations

import ctypes
import os
import sys
import tempfile
import zipfile
from pathlib import Path

AE2_ROOT = Path(__file__).resolve().parent.parent


def _find_gtnh_root(start: Path) -> Path:
    for parent in start.parents:
        if (parent / "tools/jdks").exists() or list(parent.glob("GT_NH_*/mods/OpenComputers-*.jar")):
            return parent
    return start.parent.parent


def _discover_jvm_dylib() -> Path:
    env = os.environ.get("JVM_DYLIB")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(AE2_ROOT)
    cands = sorted(gtnh_root.glob("tools/jdks/**/libjvm.dylib"), reverse=True) + sorted(gtnh_root.glob("tools/jdks/**/libjvm.so"), reverse=True)
    if cands:
        return cands[0]
    return gtnh_root / "tools/jdks/jdk8/Contents/Home/jre/lib/server/libjvm.dylib"


def _discover_oc_jar() -> Path:
    env = os.environ.get("OC_JAR")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(AE2_ROOT)
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
            self.internet_lua = zf.read("assets/opencomputers/loot/openos/lib/internet.lua").decode("utf-8")

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
            if path == "/__openos__/internet.lua":
                self._push_str(self.internet_lua)
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
local rootDir = "{AE2_ROOT}"
__AE2_ROOT = rootDir
__MONOREPO_ROOT = "{AE2_ROOT.parent}"
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
    write = function(s) __py_print(tostring(s)) end,
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

package = {{ path = rootDir .. "/?.lua;/home/?.lua", loaded = {{ io = io }}, preload = {{}} }}
function require(name)
    if package.loaded[name] ~= nil then return package.loaded[name] end
    if package.preload[name] then
        local res = package.preload[name](name)
        package.loaded[name] = (res == nil) and true or res
        return package.loaded[name]
    end
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

package.preload["buffer"] = function()
    return {{ new = function() return {{}} end }}
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
local osTimeVal = 10000
os = {{
    clock = function() return uptimeVal end,
    time = function() osTimeVal = osTimeVal + 100; return osTimeVal end,
    sleep = function(sec) uptimeVal = uptimeVal + (tonumber(sec) or 0) end,
    remove = function(p) return __py_remove_vfs(p) end,
    rename = function(a, b) return __py_rename_vfs(a, b) end,
}}
package.loaded["os"] = os

local serChunk, serErr = load(__py_read_file("/__openos__/serialization.lua"), "@serialization.lua")
assert(serChunk, serErr)
package.loaded["serialization"] = serChunk()

local inetChunk, inetErr = load(__py_read_file("/__openos__/internet.lua"), "@internet.lua")
assert(inetChunk, inetErr)
package.preload["internet"] = function() return inetChunk() end

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
    freeMemory = function() return 1048576 end,
    totalMemory = function() return 2097152 end,
    shutdown = function() end,
}}
package.loaded["shell"] = {{
    getRunningProgram = function() return "/home/exporter.lua" end,
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
    component.internet = nil
    component.tps_card = nil
end
function component._register(addr, ctype, proxy)
    registry[addr] = {{ type = ctype, proxy = proxy }}
    if ctype == "internet" then component.internet = proxy end
    if ctype == "tps_card" then component.tps_card = proxy end
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
local event = require("event")
local serialization = require("serialization")

assert(collectgarbage == nil, "OpenComputers sandbox must omit collectgarbage")

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAIL [%s]: expected=%s actual=%s", tostring(msg), tostring(expected), tostring(actual)))
    end
end

-- =====================================================================
-- TEST 1: Syntax / Load Check of All Lua Files
-- =====================================================================
for _, rel in ipairs({
    "exporter.lua",
    "ae2_ui.lua",
    "install.lua",
    "config.example.lua",
}) do
    local src = __py_read_file(__AE2_ROOT .. "/" .. rel)
    assert(src and #src > 0, "Missing file: " .. rel)
    local chunk, err = load(src, "@" .. rel, "t")
    assert(chunk, "Syntax error in " .. rel .. ": " .. tostring(err))
end

-- Copy config.example.lua -> /home/config.lua inside VFS
local cfgSrc = __py_read_file(__AE2_ROOT .. "/config.example.lua")
__py_write_file("/home/config.lua", cfgSrc:gsub("enableEnergyAE2 = false", "enableEnergyAE2 = true"):gsub("enableResilience = true", "enableResilience = false"):gsub("enableItems = true", "enableItems = false"):gsub("enableFluids = true", "enableFluids = false"):gsub("enableEssentia = true", "enableEssentia = false"))
__py_write_file("/home/exporter.lua", __py_read_file(__AE2_ROOT .. "/exporter.lua"))
-- Intentionally omit ae2_ui.lua from /home initially & temporarily hide package.path root to prove headless runs WITHOUT ae2_ui.lua!
local savedPkgPath = package.path
package.path = "/home/?.lua"

-- =====================================================================
-- TEST 2: Headless Run Without ae2_ui.lua + Cached Mesh Transports
--         + GORGE_METRICS Influx Export + univ_action / gorge_action
-- =====================================================================
component._reset()
local posts = {}
local bridgeWrites = {}
local bridgeIn = {
    '{"id":10,"op":"ping"}\n',
    '{"id":11,"op":"univ_action","action":"pause"}\n',
    '{"id":12,"op":"gorge_action","action":"set_mode","exoticizerId":1,"mode":"magmatter"}\n',
    '{"id":13,"op":"stock_action","action":"retry_errors"}\n',
    '{"id":14,"op":"mesh_recover","role":"dtpf"}\n',
}
local openCalls, strCalls, sendCalls = 0, 0, 0
local o1ItemCalls, o1FluidCalls, legacyItemsCalls, legacyFluidsCalls = 0, 0, 0, 0
local sentPackets = {}
local meshEventQueue = {}
local pullStep = 0

local function makeSocket()
    local closed = false
    return {
        finishConnect = function() return true end,
        read = function(_)
            if #meshEventQueue == 0 and pullStep >= 4 and #bridgeIn > 0 then
                return table.remove(bridgeIn, 1)
            end
            return ""
        end,
        write = function(data)
            bridgeWrites[#bridgeWrites + 1] = data
            return #data
        end,
        close = function() closed = true end,
    }
end

component._register("inet-1", "internet", {
    request = function(url, body)
        posts[#posts + 1] = { url = url, body = body }
        local readDone = false
        return { read = function() if readDone then return nil end readDone = true return "" end, close = function() end }
    end,
    connect = function(_) return makeSocket() end,
})

local function enqueueReply(addr, port, msgType, p1)
    if msgType == "UNIV_CMD" then
        meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", addr or "univ-addr", port, 0, "UNIV_REPLY", p1, serialization.serialize({ ok = true, armed = false }) }
    elseif msgType == "GORGE_CMD" then
        meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", addr or "gorge-addr", port, 0, "GORGE_REPLY", p1, serialization.serialize({ ok = true, mode = "magmatter" }) }
    elseif msgType == "STOCK_CMD" then
        local full = serialization.serialize({ ok = true, armed = true, retried = true })
        local mid = math.floor(#full / 2)
        meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", addr or "stock-addr", port, 0, "STOCK_REPLY", p1, 1, 2, full:sub(1, mid) }
        meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", addr or "stock-addr", port, 0, "STOCK_REPLY", p1, 2, 2, full:sub(mid + 1) }
    end
end

local wakeMsg, wakeSetCalls = nil, 0
component._register("mod-1", "modem", {
    isOpen = function() return true end,
    open = function() openCalls = openCalls + 1 end,
    isWireless = function() return true end,
    getStrength = function() return 400 end,
    setStrength = function() strCalls = strCalls + 1 end,
    getWakeMessage = function() return wakeMsg end,
    setWakeMessage = function(m) wakeSetCalls = wakeSetCalls + 1; wakeMsg = m; return wakeMsg end,
    broadcast = function(port, msgType, p1, p2)
        sendCalls = sendCalls + 1
        sentPackets[#sentPackets + 1] = { port = port, t = msgType, p1 = p1, p2 = p2 }
        enqueueReply(nil, port, msgType, p1)
    end,
    send = function(addr, port, msgType, p1, p2)
        sendCalls = sendCalls + 1
        sentPackets[#sentPackets + 1] = { addr = addr, port = port, t = msgType, p1 = p1, p2 = p2 }
        enqueueReply(addr, port, msgType, p1)
    end,
})

component._register("me-1", "me_controller", {
    getCpus = function()
        return {
            { name = "CPU-Alpha", storage = 65536, coprocessors = 8, busy = true,
              cpu = {
                  finalOutput = function() return { label = "Quantum Anomaly", size = 32 } end,
                  cancel = function() return true end,
              } },
            { name = "CPU-Beta", storage = 16384, coprocessors = 2, busy = false, cpu = {} },
        }
    end,
    getItemInNetwork = function(filter)
        o1ItemCalls = o1ItemCalls + 1
        if type(filter) == "table" and filter.name == "gregtech:gt.metaitem.01" and tonumber(filter.damage) == 100 then
            return { name = filter.name, damage = 100, size = 777 }
        end
        return nil
    end,
    getFluidInNetwork = function(flName)
        o1FluidCalls = o1FluidCalls + 1
        if flName == "water" then return { name = "water", amount = 12345 } end
        return nil
    end,
    getItemsInNetwork = function() legacyItemsCalls = legacyItemsCalls + 1; return {} end,
    getFluidsInNetwork = function() legacyFluidsCalls = legacyFluidsCalls + 1; return {} end,
    getAvgPowerInjection = function() return 4000 end,
    getAvgPowerUsage = function() return 1000 end,
    getMaxStoredPower = function() return 200000 end,
    getStoredPower = function() return 150000 end,
    getIdlePowerUsage = function() return 200 end,
})
component._register("lsc-1", "gt_machine", {
    getName = function() return "multimachine.supercapacitor" end,
    getSensorInformation = function()
        return {
            "kekztech.infodata.lapotronic_super_capacitor.used_capacity\\62.5%",
            "kekztech.infodata.lapotronic_super_capacitor.eu_stored\\1000",
            "kekztech.infodata.lapotronic_super_capacitor.total_capacity\\1600",
            "kekztech.infodata.lapotronic_super_capacitor.avg_eu_in.sec\\500\\5",
            "kekztech.infodata.lapotronic_super_capacitor.avg_eu_out.sec\\200\\5",
        }
    end,
})
component._register("tps-1", "tps_card", {
    getOverallTickTime = function() return 25.0 end,
    getOverallChunksLoaded = function() return 410 end,
    getOverallDimsLoaded = function() return 5 end,
    getAllTickTimes = function() return { [0] = 18.2 } end,
})

-- Inject DTPF_METRICS + GORGE_METRICS + UNIV_METRICS + PUMP_STATUS before polling ends
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "dtpf-addr", 4205, 0, "DTPF_METRICS", serialization.serialize({
    armed = true, odActive = false, dtrStock = 500000, directEut = 1e6, catEut = 2e6, totalEut = 3e6,
    units = { { name = "DTPF-1", online = true, active = true, discountPct = 90.5, coilHeat = 13500, familyId = "spacetime" } },
}) }
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "gorge-addr", 4205, 0, "GORGE_METRICS", serialization.serialize({
    armed = true, activeCount = 1, completedCycles = 5, errorCount = 0, lscPct = 62.5,
    godforge = { bound = true, online = true, active = true, workAllowed = true, rings = 3, connected = 4, upgrades = 12 },
    exoticizers = { { id = 1, name = "Ex#1", mode = "magmatter", activeMode = "magmatter", phase = "WAIT_END", cycles = 5 } },
}) }
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "univ-addr", 4205, 0, "UNIV_METRICS", serialization.serialize({
    armed = true, activePools = 2, queuedSlices = 4, stalledCount = 0, completedBatches = 11, preemptions = 1,
    pools = { { id = 1, name = "EBF Pool", phase = "ACTIVE", activeLabel = "Chrome Ingot" } },
}) }
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "pump-addr", 4205, 0, "PUMP_STATUS", serialization.serialize({
    paused = false, threshold = 0.95,
    pumps = { { active = true, mult = 8 } },
    fluids = { Helium = { label = "Helium", total = 100000, target = 100000 } },
}) }
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "stock-addr", 4205, 0, "STOCK_METRICS", serialization.serialize({
    armed = true, totalRules = 12, enabledRules = 10, okCount = 7, lowCount = 2, craftingCount = 1, errorCount = 0, warnCount = 1,
    freeCpus = 4, totalCpus = 6,
    perf = { lastCycleMs = 1.4, aeCallsPerSec = 0.8, equivBlocksSaved = 3, freeMemKB = 1800 },
}) }
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "stock-addr", 4205, 0, "STOCK_CLAIMS", "claims-from-stock" }
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "dtpf-addr", 4205, 0, "DTPF_CLAIMS", "claims-from-dtpf" }
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "stock-addr", 4205, 0, "DTPF_HANDOFF", "dh-1", "handoff-payload" }
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "dtpf-addr", 4205, 0, "DTPF_HANDOFF_ACK", "dh-1", "ack-payload" }
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "dtpf-addr", 4205, 0, "GTNH_WAKE", "dtpf" }
meshEventQueue[#meshEventQueue + 1] = { "modem_message", "mod-1", "dtpf-addr", 4205, 0, "MESH_MAINT_SYNC", "req-o1", serialization.serialize({
    items = {
        { id = "r1", type = "item", name = "gregtech:gt.metaitem.01", damage = 100, hasTag = false },
        { id = "r2", type = "fluid", name = "water" },
    },
}) }

-- Enable bridge in config for Test 2
__py_write_file("/home/config.lua", __py_read_file("/home/config.lua"):gsub("enableBridge = false", "enableBridge = true"))

event.pull = function(timeout, filter)
    if #meshEventQueue > 0 then
        local ev = meshEventQueue[1]
        if (not filter) or ev[1] == filter then
            table.remove(meshEventQueue, 1)
            return table.unpack(ev)
        end
    end
    if timeout == 0 then return nil end
    computer._setUptime(computer.uptime() + (tonumber(timeout) or 0.5))
    pullStep = pullStep + 1
    if pullStep == 8 then
        computer._setUptime(computer.uptime() + 75)
    end
    if pullStep >= 10 then return "interrupted" end
    return nil
end

local expChunk = assert(load(__py_read_file("/home/exporter.lua"), "@/home/exporter.lua"))
expChunk("--headless")

-- Assert 0 redundant open() / setStrength() calls because isOpen=true & getStrength=400!
assertEq(openCalls, 0, "Zero redundant modem.open() calls when already open")
assertEq(strCalls, 0, "Zero redundant modem.setStrength() calls when >= 400")
assertEq(wakeMsg, "GTNH_WAKE", "Modem configured with GTNH_WAKE wake message")
assertEq(wakeSetCalls, 1, "Zero redundant setWakeMessage() calls")
assert(sendCalls >= 4, "Sent Mesh ACKs/RPCs without re-opening modem")
assert(o1ItemCalls >= 1 and o1FluidCalls >= 1, "inspectMainnetForMaint must use O(1) getItemInNetwork/getFluidInNetwork")
assertEq(legacyItemsCalls, 0, "inspectMainnetForMaint must NOT scan getItemsInNetwork when O(1) exists")
assertEq(legacyFluidsCalls, 0, "inspectMainnetForMaint must NOT scan getFluidsInNetwork when O(1) exists")

local sawStockToDtpf, sawDtpfToStock, sawHandoffToDtpf, sawHandoffAckToStock, sawWakeHelloReply, sawWatchdogWake, sawMaintAckO1 = false, false, false, false, false, false, false
for _, pkt in ipairs(sentPackets) do
    if pkt.addr == "dtpf-addr" and pkt.t == "STOCK_CLAIMS" and pkt.p1 == "claims-from-stock" then sawStockToDtpf = true end
    if pkt.addr == "stock-addr" and pkt.t == "DTPF_CLAIMS" and pkt.p1 == "claims-from-dtpf" then sawDtpfToStock = true end
    if pkt.addr == "dtpf-addr" and pkt.t == "DTPF_HANDOFF" and pkt.p1 == "dh-1" and pkt.p2 == "handoff-payload" then sawHandoffToDtpf = true end
    if pkt.addr == "stock-addr" and pkt.t == "DTPF_HANDOFF_ACK" and pkt.p1 == "dh-1" and pkt.p2 == "ack-payload" then sawHandoffAckToStock = true end
    if pkt.addr == "dtpf-addr" and pkt.t == "MESH_MAINNET_HELLO" and pkt.p1 == "wake_ack" then sawWakeHelloReply = true end
    if pkt.t == "GTNH_WAKE" and (pkt.p1 == "stock" or pkt.p1 == "gorge" or pkt.p1 == "univ") then sawWatchdogWake = true end
    if pkt.addr == "dtpf-addr" and pkt.t == "MESH_MAINT_ACK" and pkt.p1 == "req-o1" then
        local ackTbl = serialization.unserialize(pkt.p2)
        if ackTbl and ackTbl.stocks and ackTbl.stocks.r1 == 777 and ackTbl.stocks.r2 == 12345 then
            sawMaintAckO1 = true
        end
    end
end
assert(sawStockToDtpf, "Exporter must relay STOCK_CLAIMS -> dtpf-addr")
assert(sawDtpfToStock, "Exporter must relay DTPF_CLAIMS -> stock-addr")
assert(sawHandoffToDtpf, "Exporter must relay DTPF_HANDOFF -> dtpf-addr")
assert(sawHandoffAckToStock, "Exporter must relay DTPF_HANDOFF_ACK -> stock-addr")
assert(sawWakeHelloReply, "Exporter must answer GTNH_WAKE with MESH_MAINNET_HELLO wake_ack")
assert(sawWatchdogWake, "Watchdog must send GTNH_WAKE to stale peers (>60s) without false-alarming Space Pump")
assert(sawMaintAckO1, "MESH_MAINT_ACK did not return O(1) stocks r1=777, r2=12345")

local joinedInflux = {}
for _, p in ipairs(posts) do joinedInflux[#joinedInflux + 1] = p.body end
local allInflux = table.concat(joinedInflux, "\n")
assert(allInflux:find("godforge_control ", 1, true), "Missing godforge_control InfluxDB line")
assert(allInflux:find("oc_health ", 1, true), "Missing oc_health InfluxDB watchdog telemetry")
assert(allInflux:find("univ_ok=", 1, true), "oc_health missing univ_ok field")
assert(allInflux:find("pump_ok=1i", 1, true), "Space Pump (240s threshold) remained healthy during 75s step")
assert(allInflux:find("active_exoticizers=1i,completed_cycles=5i,errors=0i,gf_online=1i,gf_active=1i,gf_work_allowed=1i,gf_rings=3i,gf_connected=4i,gf_upgrades=12i,lsc_pct=62.50", 1, true),
    "Bad godforge_control fields: " .. allInflux)
assert(allInflux:find("stock_maintainer armed=1i,total_rules=12i,enabled_rules=10i,ok_count=7i,low_count=2i,crafting_count=1i,error_count=0i,warn_count=1i,cycle_ms=1.40,ae_calls_s=0.80,blocks_saved=3i", 1, true),
    "Missing/bad stock_maintainer InfluxDB line: " .. allInflux)

local allBridge = table.concat(bridgeWrites, "")
assert(allBridge:find('"meshUniv":true', 1, true), "Ping missing meshUniv=true")
assert(allBridge:find('"meshGorge":true', 1, true), "Ping missing meshGorge=true")
assert(allBridge:find('"meshStock":true', 1, true), "Ping missing meshStock=true")
assert(allBridge:find('"meshHealth"', 1, true), "Ping/mesh_recover missing meshHealth table")
assert(allBridge:find('"brief"', 1, true), "meshHealth missing brief summary field")
assert(allBridge:find('"woken"', 1, true), "mesh_recover reply missing woken list")
assert(allBridge:find('"armed":false', 1, true), "univ_action pause reply missing armed=false")
assert(allBridge:find('"mode":"magmatter"', 1, true), "gorge_action set_mode reply missing mode")
assert(allBridge:find('"retried":true', 1, true), "Chunked STOCK_REPLY missing retried=true")

-- =====================================================================
-- TEST 3: Full 160x50 GUI Across All 4 Tabs, Log Modal, 2-Click Cancel,
--         Setup Overrides Persistence & Clean Shutdown
-- =====================================================================
package.path = savedPkgPath
local Ae2UI = require("ae2_ui")
component.gpu = component._newMockGPU(160, 50)
component._register("scr-1", "screen", {})

local canceledCpuName = nil
local cpuBusyState = true
local peerActionsLog = {}

local cfg3 = assert(loadfile("/home/config.lua"))()
cfg3._sec = {
    itemInterval = 65, fluidInterval = 55, essentiaInterval = 60, energyInterval = 10,
    energyAE2Interval = 10, cpuInterval = 20, tpsInterval = 5, allItemsInterval = 1800,
}
local hub3 = {
    nowUptime = 200,
    freeMem = 900000,
    totalMem = 2097152,
    bridgeConnected = true,
    meshModemOk = true,
    meshTunnelOk = true,
    lastScanDurSec = 1.42,
    lastItemsCount = 1234,
    ae2 = { connected = true, avgInjection = 4000, avgUsage = 1000, maxStorage = 200000, currStorage = 150000, idleUsage = 200 },
    lsc = { online = true, pct = 62.5, in5s = 500, out5s = 200, net5s = 300, wirelessStr = "2.42e21", wirelessOn = true },
    tps = { online = true, mspt = 25.0, tps = 20.0, chunks = 410, dims = 5 },
    cpus = {
        total = 2,
        busyCount = 1,
        list = {
            { name = "CPU-Alpha", storage = 65536, coprocessors = 8, busy = true, craftingItem = "Quantum Anomaly", craftingCount = 32 },
            { name = "CPU-Beta", storage = 16384, coprocessors = 2, busy = false, craftingItem = "N/A", craftingCount = 0 },
        },
    },
    peers = {
        dtpf = { addr = "dtpf-addr", lastSeen = 198, status = { armed = true, totalEut = 3e6, dtrStock = 500000, units = { { name = "DTPF-1", online = true, active = true, discountPct = 90.5, coilHeat = 13500, familyId = "spacetime" } } } },
        pump = { addr = "pump-addr", lastSeen = 195, status = { paused = false, threshold = 0.95, pumps = { { active = true, mult = 8 } }, fluids = { Helium = { label = "Helium", total = 100000, target = 100000 } } } },
        univ = { addr = "univ-addr", lastSeen = 197, status = { armed = true, activePools = 2, queuedSlices = 4, stalledCount = 0, completedBatches = 11, preemptions = 1, pools = { { name = "EBF Pool", phase = "ACTIVE", activeLabel = "Chrome Ingot" } } } },
        gorge = { addr = "gorge-addr", lastSeen = 199, status = { armed = true, activeCount = 1, completedCycles = 5, errorCount = 0, lscPct = 62.5, godforge = { active = true, rings = 3, connected = 4 }, exoticizers = { { name = "Ex#1", activeMode = "magmatter", phase = "WAIT_END", cycles = 5 } } } },
        stock = { addr = "stock-addr", lastSeen = 199, status = { armed = true, totalRules = 12, enabledRules = 10, okCount = 7, lowCount = 2, craftingCount = 1, errorCount = 0, warnCount = 1, freeCpus = 4, totalCpus = 6, perf = { lastCycleMs = 1.4, aeCallsPerSec = 0.8, equivBlocksSaved = 3, freeMemKB = 1800 }, rulesPreview = { { label = "Raw Tesseract", type = "item", stock = 100, target = 1000, state = "LOW", warn = "! DTPF Passive" } } } },
    },
    logs = {
        { t = 190, tag = "OUT", msg = "Exported energy" },
        { t = 192, tag = "MESH", msg = "Gorge & Exoticizer Rack connected" },
        { t = 194, tag = "WRN", msg = "Test warning line" },
        { t = 196, tag = "ERR", msg = "Sample error line" },
    },
}

local ui3 = Ae2UI.new(cfg3, hub3, {
    onCancelCpu = function(cpuName)
        canceledCpuName = cpuName
        cpuBusyState = false
        hub3.cpus.list[1].busy = false
        hub3.cpus.busyCount = 0
        return true, "Canceled " .. cpuName
    end,
    onPeerAction = function(pk, act, extra)
        local tag = pk .. ":" .. act
        if type(extra) == "table" and extra.exoticizerId then
            tag = tag .. ":" .. tostring(extra.exoticizerId)
        end
        if type(extra) == "table" and extra.mode then
            tag = tag .. ":" .. tostring(extra.mode)
        end
        peerActionsLog[#peerActionsLog + 1] = tag
        return tag .. " OK"
    end,
})

for t = 1, 9 do
    ui3.tab = t
    ui3:render()
end
ui3.tab = 1
ui3:render()
ui3:handleTouch(30, 15, 0) -- Click DTPF overview tile badge -> switches to TAB_DTPF (4)
assertEq(ui3.tab, 4, "Overview DTPF tile badge switches to TAB_DTPF")
ui3.tab = 1
ui3:render()
ui3.logModalActive = true
ui3:render()
ui3.logModalActive = false

-- Also exercise offline peer guide state glyph safety on Tabs 4..8
do
    local savedPeers = hub3.peers
    hub3.peers = { dtpf = {}, pump = {}, univ = {}, gorge = {}, stock = {} }
    for t = 4, 8 do ui3.tab = t; ui3:render() end
    hub3.peers = savedPeers
end

-- Switch to Tab 2 (CPUs) & verify 2-click Cancel safety!
ui3:handleKeyDown(50, 3)
assertEq(ui3.tab, 2, "Key '2' switched to Crafting CPUs tab")
-- Row 1 busy CPU button starts at x=125, y=10
ui3:handleTouch(127, 10, 0)
assertEq(ui3.confirmCancelCpu, "CPU-Alpha", "1st click armed [Confirm Cancel?] without canceling yet")
assertEq(canceledCpuName, nil, "1st click must NOT cancel immediately")
ui3:handleTouch(127, 10, 0)
assertEq(canceledCpuName, "CPU-Alpha", "2nd click confirmed and canceled CPU-Alpha")
assertEq(ui3.confirmCancelCpu, nil, "Cleared confirm state after cancel")

-- Switch to Tab 3 (Mesh Peers) & click Card 1 [Pause] (x=6, y=16) and Card 5 Stock [Pause] (x=6, y=45)
ui3:handleKeyDown(51, 4)
assertEq(ui3.tab, 3, "Key '3' switched to OC Mesh Peers tab")
ui3:handleTouch(6, 16, 0)
assertEq(peerActionsLog[#peerActionsLog], "dtpf:pause", "Peer button clicked dtpf:pause")
ui3:handleTouch(6, 45, 0)
assertEq(peerActionsLog[#peerActionsLog], "stock:pause", "Peer button clicked stock:pause")

-- Test dedicated orchestrator Tabs 4..8 actions!
ui3:handleKeyDown(52, 5) -- Key '4': DTPF
assertEq(ui3.tab, 4, "Key '4' switched to DTPF tab")
ui3:handleTouch(46, 9, 0) -- [Maint Sync]
assertEq(peerActionsLog[#peerActionsLog], "dtpf:maint_sync", "DTPF Maint Sync clicked")

ui3:handleKeyDown(53, 6) -- Key '5': UNIVERSAL
assertEq(ui3.tab, 5, "Key '5' switched to Universal tab")
ui3:handleTouch(44, 9, 0) -- [Clear Stalls]
assertEq(peerActionsLog[#peerActionsLog], "univ:clear_stalls", "Universal Clear Stalls clicked")

ui3:handleKeyDown(54, 7) -- Key '6': GORGE
assertEq(ui3.tab, 6, "Key '6' switched to Gorge tab")
ui3:handleTouch(36, 10, 0) -- [Unstick All]
assertEq(peerActionsLog[#peerActionsLog], "gorge:unstick", "Gorge Unstick All clicked")
ui3:handleTouch(125, 19, 0) -- Row 1 [Unstick]
assertEq(peerActionsLog[#peerActionsLog], "gorge:unstick:1", "Gorge row Unstick clicked")

ui3:handleKeyDown(55, 8) -- Key '7': PUMP
assertEq(ui3.tab, 7, "Key '7' switched to Pump tab")
ui3:handleTouch(24, 9, 0) -- [Refresh Pumps]
assertEq(peerActionsLog[#peerActionsLog], "pump:refresh_pumps", "Pump Refresh Pumps clicked")

ui3:handleKeyDown(56, 9) -- Key '8': STOCK
assertEq(ui3.tab, 8, "Key '8' switched to Stock tab")
ui3:handleTouch(35, 9, 0) -- [Retry Errors]
assertEq(peerActionsLog[#peerActionsLog], "stock:retry_errors", "Stock Retry Errors clicked")

-- =====================================================================
-- TEST 4: Live exporter.lua GUI Integration + Overrides Persistence + Pause Export
-- =====================================================================
__py_write_file("/home/ae2_ui.lua", __py_read_file(__AE2_ROOT .. "/ae2_ui.lua"))
-- Seed clean config without bridge for integrated GUI event loop test
local baseCfgSrc = __py_read_file(__AE2_ROOT .. "/config.example.lua")
__py_write_file("/home/config.lua", baseCfgSrc
    :gsub("enableEnergyAE2 = false", "enableEnergyAE2 = true")
    :gsub("enableResilience = true", "enableResilience = false")
    :gsub("enableItems = true", "enableItems = false")
    :gsub("enableFluids = true", "enableFluids = false")
    :gsub("enableEssentia = true", "enableEssentia = false")
    :gsub("energyInterval = 10", "energyInterval = 0"))

posts = {}
local guiEvs = {
    -- Touch header [EXPORT: ON    ] at x=33, y=1 -> pauses exports & saves /home/config_overrides.lua
    { "touch", "scr-1", 33, 1, 0 },
    -- Key '9' (Setup & Exports tab)
    { "key_down", "kbd-1", 57, 10 },
    -- Touch [+] on itemInterval (y=7, x=126) -> 65 + 5 = 70s & saves /home/config_overrides.lua
    { "touch", "scr-1", 126, 7, 0 },
    -- Key 'Q' to exit cleanly
    { "key_down", "kbd-1", 113, 16 },
}
event.pull = function(_, filter)
    if #guiEvs > 0 then
        local ev = guiEvs[1]
        if (not filter) or ev[1] == filter then
            table.remove(guiEvs, 1)
            return table.unpack(ev)
        end
    end
    return nil
end

package.loaded["ae2_ui"] = nil
local expGuiChunk = assert(load(__py_read_file("/home/exporter.lua"), "@/home/exporter.lua"))
expGuiChunk()

assert(__py_exists("/home/config_overrides.lua"), "Setup changes saved /home/config_overrides.lua")
local ovTbl = serialization.unserialize(__py_read_file("/home/config_overrides.lua"))
assertEq(ovTbl.exportPaused, true, "Saved exportPaused=true override")
assertEq(ovTbl.intervals.itemInterval, 70, "Saved itemInterval=70s override")

-- Reload headless exporter.lua -> verify overrides load & exportPaused suppresses Influx POSTs!
local postCountBeforeReload = #posts
pullStep = 0
event.pull = function(timeout)
    if timeout == 0 then return nil end
    pullStep = pullStep + 1
    if pullStep >= 2 then return "interrupted" end
    return nil
end
local reloadCfg = assert(load(__py_read_file("/home/exporter.lua"), "@/home/exporter.lua"))
reloadCfg("--headless")
assertEq(#posts, postCountBeforeReload, "Paused export from config_overrides.lua sent 0 InfluxDB POSTs")

rawset(_G, "__HELD_OBJECTS", { cfg3, hub3, ui3 })
"""
            host.exec_lua(lua_suite, "ae2_test_suite")

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
            assert not bad_glyphs, f"Non-width-1 glyphs found in AE2 UI: {bad_glyphs}"

            L = host.lib
            L.lua_gc.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
            L.lua_gc.restype = ctypes.c_int
            L.lua_gc(host.L, 2, 0)
            live_kb = L.lua_gc(host.L, 3, 0)
            assert live_kb < 2400, f"Live JNLua heap exceeded suite budget: {live_kb} KB"

            # Dedicated single-instance production footprint (< 950 KB)
            prod_host = LuaHost(Path(td), font_widths)
            try:
                prod_host.exec_lua(
                    """
                    local component = require("component")
                    local Ae2UI = require("ae2_ui")
                    component._reset()
                    component.gpu = {
                        maxResolution = function() return 160, 50 end,
                        setResolution = function() return true end,
                        setForeground = function() end,
                        setBackground = function() end,
                        set = function() end,
                    }
                    component._register("scr-p", "screen", {})
                    local cfg = assert(loadfile(__AE2_ROOT .. "/config.example.lua"))()
                    local hub = {
                        nowUptime = 10, freeMem = 1000000, totalMem = 2000000,
                        ae2 = { connected = true, avgInjection = 0, avgUsage = 0, maxStorage = 100, currStorage = 50, idleUsage = 0 },
                        lsc = { online = true, pct = 50, in5s = 0, out5s = 0, net5s = 0, wirelessStr = "0", wirelessOn = true },
                        tps = { online = true, mspt = 20, tps = 20, chunks = 100, dims = 1 },
                        cpus = { total = 0, busyCount = 0, list = {} },
                        peers = { dtpf = {}, pump = {}, univ = {}, gorge = {}, stock = {} },
                        logs = {},
                    }
                    local u = Ae2UI.new(cfg, hub, {})
                    for t = 1, 9 do u.tab = t; u:render() end
                    rawset(_G, "__PROD_HOLD", { cfg, hub, u })
                    """,
                    "prod_footprint_test",
                )
                Lp = prod_host.lib
                Lp.lua_gc.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
                Lp.lua_gc.restype = ctypes.c_int
                Lp.lua_gc(prod_host.L, 2, 0)
                prod_kb = Lp.lua_gc(prod_host.L, 3, 0)
                assert prod_kb < 950, f"Single-instance JNLua production footprint exceeded 950 KB: {prod_kb} KB"
            finally:
                prod_host.close()

            # =====================================================================
            # TEST 5: Standalone install.lua & Monorepo install.lua (`ae2`)
            # =====================================================================
            inst_host = LuaHost(Path(td), font_widths)
            try:
                inst_host.exec_lua(
                    """
                    local inst = assert(loadfile(__AE2_ROOT .. "/install.lua"))
                    assert(inst("--local", __AE2_ROOT, "--yes", "--no-autostart"), "Standalone AE2 install failed")
                    assert(__py_exists("/home/exporter.lua"), "Missing /home/exporter.lua")
                    assert(__py_exists("/home/ae2_ui.lua"), "Missing /home/ae2_ui.lua")
                    assert(__py_exists("/home/config.lua"), "Missing /home/config.lua")

                    local fCfg = io.open("/home/config.lua", "w"); fCfg:write("return { customAe = 88 }"); fCfg:close()
                    local fOv = io.open("/home/config_overrides.lua", "w"); fOv:write("{exportPaused=true}"); fOv:close()

                    assert(inst("--local", __AE2_ROOT, "--update", "--yes"), "Standalone AE2 --update failed")
                    local c2 = io.open("/home/config.lua", "r"):read("*a")
                    assert(c2:find("customAe = 88", 1, true), "Update overwrote /home/config.lua!")
                    local o2 = io.open("/home/config_overrides.lua", "r"):read("*a")
                    assert(o2:find("exportPaused=true", 1, true), "Update overwrote /home/config_overrides.lua!")

                    local rootInst = assert(loadfile(__MONOREPO_ROOT .. "/install.lua"))
                    assert(rootInst("--local", __MONOREPO_ROOT, "ae2", "--yes", "--no-autostart"), "Monorepo install ae2 failed")
                    assert(__py_exists("/home/.oc-gtnh.manifest"), "Missing monorepo manifest")
                    """,
                    "install_test",
                )
            finally:
                inst_host.close()

            print(
                f"ALL AE2 CONTROL OFFLINE SUITES PASSED "
                f"(0 bad-width glyphs, {prod_kb} KB single-instance / {live_kb} KB suite live JNLua heap, Lua 5.3 + OpenOS verified)."
            )
        finally:
            host.close()


if __name__ == "__main__":
    run_all_tests()
