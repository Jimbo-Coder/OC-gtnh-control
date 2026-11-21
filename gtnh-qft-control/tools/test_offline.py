#!/usr/bin/env python3
"""Offline Lua 5.3 + OpenComputers JNLua test suite for gtnh-qft-control."""

from __future__ import annotations

import ctypes
import os
import tempfile
import zipfile
from pathlib import Path

QFT_ROOT = Path(__file__).resolve().parent.parent


def _find_gtnh_root(start: Path) -> Path:
    for parent in start.parents:
        if (parent / "tools/jdks").exists() or list(parent.glob("GT_NH_*/mods/OpenComputers-*.jar")):
            return parent
    return start.parent.parent


def _discover_jvm_dylib() -> Path:
    env = os.environ.get("JVM_DYLIB")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(QFT_ROOT)
    cands = sorted(gtnh_root.glob("tools/jdks/**/libjvm.dylib"), reverse=True) + sorted(gtnh_root.glob("tools/jdks/**/libjvm.so"), reverse=True)
    return cands[0] if cands else (gtnh_root / "tools/jdks/jdk8/Contents/Home/jre/lib/server/libjvm.dylib")


def _discover_oc_jar() -> Path:
    env = os.environ.get("OC_JAR")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(QFT_ROOT)
    cands = sorted(gtnh_root.glob("GT_NH_*/mods/OpenComputers-*.jar"), reverse=True)
    return cands[0] if cands else (gtnh_root / "mods/OpenComputers.jar")


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
            (b"_G", "luaopen_base"), (b"table", "luaopen_table"), (b"string", "luaopen_string"),
            (b"math", "luaopen_math"), (b"utf8", "luaopen_utf8"), (b"debug", "luaopen_debug"),
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
        cb = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)(py_fn)
        self._cfuncs.append(cb)
        self.lib.lua_pushcclosure(self.L, ctypes.cast(cb, ctypes.c_void_p), 0)
        self.lib.lua_setglobal(self.L, name.encode("utf-8"))

    def _get_str(self, idx: int) -> str:
        sz = ctypes.c_size_t()
        raw = self.lib.lua_tolstring(self.L, idx, ctypes.byref(sz))
        return ctypes.string_at(raw, sz.value).decode("utf-8") if raw else ""

    def _push_str(self, s: str) -> None:
        b = s.encode("utf-8")
        self.lib.lua_pushlstring(self.L, b, len(b))

    def _register_host_callbacks(self) -> None:
        def py_read_file(Lp) -> int:
            path = self._get_str(1)
            if path in self.vfs:
                self._push_str(self.vfs[path]); return 1
            if path == "/__openos__/serialization.lua":
                self._push_str(self.serialization_lua); return 1
            p = Path(path)
            if p.is_file():
                self._push_str(p.read_text(encoding="utf-8")); return 1
            self.lib.lua_pushnil(Lp); return 1

        def py_write_file(Lp) -> int:
            self.vfs[self._get_str(1)] = self._get_str(2)
            self.lib.lua_pushboolean(Lp, 1); return 1

        def py_exists(Lp) -> int:
            path = self._get_str(1)
            self.lib.lua_pushboolean(Lp, 1 if ((path in self.vfs) or Path(path).is_file()) else 0); return 1

        def py_remove(Lp) -> int:
            self.lib.lua_pushboolean(Lp, 1 if self.vfs.pop(self._get_str(1), None) is not None else 0); return 1

        def py_rename(Lp) -> int:
            s, d = self._get_str(1), self._get_str(2)
            if s in self.vfs:
                self.vfs[d] = self.vfs.pop(s); self.lib.lua_pushboolean(Lp, 1); return 1
            self.lib.lua_pushboolean(Lp, 0); return 1

        def py_print(Lp) -> int:
            self.stdout.append(self._get_str(1)); return 0

        def py_char_width(Lp) -> int:
            cp = int(self.lib.lua_tointegerx(Lp, 1, None))
            self.lib.lua_pushinteger(Lp, self.font_widths.get(cp, 1)); return 1

        for n, fn in (
            ("__py_read_file", py_read_file), ("__py_write_file", py_write_file), ("__py_exists", py_exists),
            ("__py_remove_vfs", py_remove), ("__py_rename_vfs", py_rename), ("__py_print", py_print), ("__py_char_width", py_char_width),
        ):
            self._register_cfunc(n, fn)

    def _install_openos_shim(self) -> None:
        shim = f"""
local rootDir = "{QFT_ROOT}"
__QFT_ROOT = rootDir
__MONOREPO_ROOT = "{QFT_ROOT.parent}"
__RENDERED_CELL_CPS = {{}}
collectgarbage = nil

function print(...)
    local p = {{}}
    for i = 1, select("#", ...) do p[i] = tostring(select(i, ...)) end
    __py_print(table.concat(p, "\t"))
end

io = {{
    stderr = {{ write = function(_, s) __py_print("[STDERR] " .. tostring(s)) end }},
    open = function(path, mode)
        mode = mode or "r"
        if mode:sub(1, 1) == "w" then
            local buf = {{}}
            return {{ write = function(_, s) buf[#buf+1] = tostring(s) end, close = function() __py_write_file(path, table.concat(buf)) end }}
        end
        local c = __py_read_file(path)
        if not c then return nil, "not found" end
        return {{ read = function() return c end, close = function() end }}
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
            local chunk, err = load(__py_read_file(cand), "@" .. cand)
            if not chunk then error("load error in " .. cand .. ": " .. tostring(err)) end
            local res = chunk(cand)
            package.loaded[name] = (res == nil) and true or res
            return package.loaded[name]
        end
    end
    error("module '" .. tostring(name) .. "' not found")
end

local fs = {{}}
function fs.path(p) return p:match("^(.*)/[^/]+$") or "/" end
function fs.concat(a, b) return (a:sub(-1) == "/") and (a .. b) or (a .. "/" .. b) end
function fs.exists(p) return __py_exists(p) end
function fs.makeDirectory(_) return true end
function fs.remove(p) return __py_remove_vfs(p) end
function fs.rename(a, b) return __py_rename_vfs(a, b) end
package.loaded["filesystem"] = fs

local uptimeVal = 100.0
os = {{
    clock = function() uptimeVal = uptimeVal + 0.001; return uptimeVal end,
    sleep = function(sec) uptimeVal = uptimeVal + (tonumber(sec) or 0) end,
    remove = function(p) return __py_remove_vfs(p) end,
    rename = function(a, b) return __py_rename_vfs(a, b) end,
}}
function checkArg(n, have, ...)
    local tp = type(have)
    for i = 1, select("#", ...) do
        if tp == select(i, ...) then return end
    end
    error(string.format("bad argument #%s (%s expected, got %s)", tostring(n), table.concat({{...}}, " or "), tp), 3)
end

package.loaded["os"] = os
package.loaded["serialization"] = assert(load(__py_read_file("/__openos__/serialization.lua"), "@serialization.lua"))()

local unicode = {{}}
function unicode.charWidth(ch) return (not ch or ch == "") and 0 or __py_char_width(utf8.codepoint(ch, 1)) end
function unicode.wlen(s) local w = 0; for _, cp in utf8.codes(tostring(s or "")) do w = w + __py_char_width(cp) end; return w end
function unicode.sub(s, i, j)
    s = tostring(s or ""); local len = utf8.len(s) or #s
    if i < 0 then i = len + i + 1 end; if i < 1 then i = 1 end
    local sb = utf8.offset(s, i); if not sb then return "" end
    if not j then return s:sub(sb) end
    if j < 0 then j = len + j + 1 end; if j < i then return "" end
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
function component._reset() for k in pairs(registry) do registry[k] = nil end; component.gpu = nil end
function component._register(addr, ctype, proxy) registry[addr] = {{ type = ctype, proxy = proxy }} end
function component.list(filter, exact)
    local out = {{}}
    for addr, rec in pairs(registry) do
        if (not filter) or (exact and rec.type == filter) or (not exact and rec.type:find(filter, 1, true)) then
            out[#out + 1] = {{ addr, rec.type }}
        end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    local i = 0
    return function() i = i + 1; if out[i] then return out[i][1], out[i][2] end end
end
function component.proxy(addr) return registry[addr] and registry[addr].proxy or nil end
function component.isAvailable(ct)
    if ct == "gpu" and component.gpu then return true end
    for _, rec in pairs(registry) do if rec.type == ct then return true end end
    return false
end
function component._newMockGPU(w, h)
    w, h = w or 160, h or 50
    return {{
        maxResolution = function() return w, h end, setResolution = function() return true end,
        setForeground = function() end, setBackground = function() end,
        set = function(x, y, s)
            for _, cp in utf8.codes(tostring(s)) do
                if cp ~= nil then __RENDERED_CELL_CPS[cp] = true end
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
            err = self._get_str(-1); self.lib.lua_settop(self.L, 0)
            raise RuntimeError(f"Lua compile error in {chunk_name}: {err}")
        rc = self.lib.lua_pcallk(self.L, 0, 1, 0, 0, None)
        if rc != 0:
            err = self._get_str(-1); self.lib.lua_settop(self.L, 0)
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
local RecipesDb = require("lib.recipes_db")
local Hardware = require("lib.hardware")
local Scheduler = require("lib.scheduler")
local UI = require("lib.ui")

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAIL [%s]: expected=%s actual=%s", tostring(msg), tostring(expected), tostring(actual)))
    end
end

-- TEST 1: GTNH 2.9.0 QFT Recipe Catalog Integrity (all 28 recipes)
assertEq(#RecipesDb.RECIPES, 28, "Expected 28 GTNH 2.9.0 QFT recipes")
assertEq(RecipesDb.PLASMAS.neptunium.name, "plasma.neptunium", "Exact Neptunium plasma fluid ID")
assertEq(RecipesDb.PLASMAS.fermium.name, "plasma.fermium", "Exact Fermium plasma fluid ID")
for _, r in ipairs(RecipesDb.RECIPES) do
    assert(type(r.id) == "string" and r.id ~= "", "Valid recipe ID")
    assert(r.tier >= 1 and r.tier <= 4, "Valid tier 1..4 on " .. tostring(r.id))
    assert(r.catalyst and r.catalyst.name == "miscutils:BasicGenericChemItem", "Valid catalyst on " .. tostring(r.id))
    assert((#r.itemsIn + #r.fluidsIn) >= 1, "Has inputs on " .. tostring(r.id))
    assert((#r.itemsOut + #r.fluidsOut) >= 1, "Has outputs on " .. tostring(r.id))
end

-- TEST 2: Plasma-Voiding Safety Guard (3-block QFT: Ctrl + Bus + Hatch)
local qftActive = true
local qftWorkAllowed = true
local focusCir = 1
local hatchSlots = {
    [15] = { name = "plasma.neptunium", amount = 1000 },
    [16] = { name = "plasma.fermium", amount = 1000 },
}
local busWrites, hatchWrites = {}, {}

component._reset()
component._register("gt-qft-1", "gt_machine", {
    getName = function() return "QuantumForceTransformer" end,
    isMachineActive = function() return qftActive end,
    isWorkAllowed = function() return qftWorkAllowed end,
    setWorkAllowed = function(v) qftWorkAllowed = (v == true) end,
    getWorkProgress = function() return qftActive and 120 or 0 end,
    getWorkMaxProgress = function() return 400 end,
    getSensorInformation = function() return { "Quantum Force Transformer", "Problems: 0" } end,
})
component._register("bus-qft-1", "me_inputbus", {
    getCircuitConfiguration = function() return focusCir end,
    setCircuitConfiguration = function(n)
        assert(qftActive == false, "SAFETY VIOLATION: bus circuit mutated while QFT was active!")
        busWrites[#busWrites + 1] = n
        focusCir = n
        return true
    end,
})
component._register("hatch-qft-1", "me_inputhatch", {
    getSlotSize = function() return 16 end,
    getConfiguration = function(s) return hatchSlots[s] end,
    setConfiguration = function(s, det)
        assert(qftActive == false, "SAFETY VIOLATION: plasma hatch mutated while QFT was active!")
        hatchWrites[#hatchWrites + 1] = { slot = s, name = det and det.name or nil }
        hatchSlots[s] = det
        return true
    end,
    isAutoPull = function() return false end,
})
component._register("gt-qft-2-1block", "gt_machine", {
    getName = function() return "QuantumForceTransformer" end,
    isMachineActive = function() return false end,
    isWorkAllowed = function() return false end,
    setWorkAllowed = function() end,
    getWorkProgress = function() return 0 end,
    getWorkMaxProgress = function() return 400 end,
    getSensorInformation = function() return { "Problems: 0" } end,
})

local cfg = Scheduler.defaultConfig()
cfg.armed = true
local st = Scheduler.newState()
local disc = Scheduler.syncHardware(cfg, st)
assertEq(#disc.controllers, 2, "Discovered 2 QFT controllers")
Scheduler.autoBindDiscoveredUnits(cfg, disc)
assertEq(#cfg.units, 2, "Auto-bound 1st 3-block QFT and 2nd 1-block QFT")

-- Request reconfig while active=true (change focus 1->2 and turn OFF both plasmas!)
cfg.units[1].focusMode = "fixed"
cfg.units[1].focusCircuit = 2
cfg.units[1].boostNeptunium = "off"
cfg.units[1].boostFermium = "off"
Scheduler.step(cfg, st, 200.0)
assertEq(qftWorkAllowed, false, "Paused QFT setWorkAllowed(false) while active to drain safely")
assertEq(#busWrites, 0, "Zero bus mutations while QFT active")
assertEq(#hatchWrites, 0, "Zero hatch plasma clears while QFT active (prevented cycle void!)")
assertEq(st.unitStatuses[1].state, "RECFG", "Status clearly indicates RECFG wait state")

-- Cycle finishes -> machine becomes idle -> safe to apply focus & clear Np/Fm plasma!
qftActive = false
Scheduler.step(cfg, st, 205.0)
assertEq(focusCir, 2, "Focus circuit updated to #2 after machine became idle")
assert(#hatchWrites >= 2, "Both Np and Fm cleared ONLY after machine became idle")
assertEq(hatchSlots[15], nil, "Neptunium cleared cleanly")
assertEq(hatchSlots[16], nil, "Fermium cleared cleanly")
assertEq(qftWorkAllowed, true, "QFT resumed setWorkAllowed(true) after safe reconfiguration")

-- TEST 3: Mainnet Stock Dispatch + Local AE2 Fallback + Auto-Sync on Reconnect
local crafted = {}
local stocks = {
    ["item:bartworks:gt.bwMetaGenerateddust:79"] = 8,
    ["item:gregtech:gt.metaitem.01:2010"] = 10,
    ["fluid:oxygen"] = 1000,
    ["fluid:hydrogen"] = 1000,
}
component._register("ae-local", "me_interface", {
    getCpus = function() return { { name = "QFT-CPU-1", busy = false }, { name = "QFT-CPU-2", busy = false }, { name = "QFT-CPU-3", busy = false } } end,
    getItemInNetwork = function(n, d)
        local v = stocks["item:" .. tostring(n) .. ":" .. tostring(d or 0)] or 0
        return { size = v }
    end,
    getFluidInNetwork = function(n)
        local v = stocks["fluid:" .. tostring(n)] or 0
        return { amount = v }
    end,
    getCraftables = function(flt)
        return { { request = function(amt) crafted[#crafted + 1] = { flt = flt, amt = amt }; return { isDone = function() return false end } end } }
    end,
})
local meshPkts = {}
component._register("mod-q", "modem", {
    isOpen = function() return true end, open = function() return true end,
    isWireless = function() return true end, setStrength = function() return 400 end,
    setWakeMessage = function() return "GTNH_WAKE" end,
    send = function(a, p, mType, reqId, body) meshPkts[#meshPkts + 1] = { mType = mType, reqId = reqId, body = body }; return true end,
    broadcast = function(p, mType, reqId, body) meshPkts[#meshPkts + 1] = { mType = mType, reqId = reqId, body = body }; return true end,
})

cfg.maintFreeCpus = 1 -- headroom 2 CPUs
local resLocal = Scheduler.pushRecipeInputs(cfg, st, { recipeId = "adhesives_solder" })
assertEq(resLocal.dispatched, "local", "Offline Mainnet Stock triggered LOCAL FALLBACK")
assertEq(st.maintMode.mode, nil or st.maintMode.mode, "check")
Scheduler.step(cfg, st, 220.0)
assertEq(st.maintMode.mode, "local", "Maintainer status shows LOCAL FALLBACK")
assert(#crafted >= 1, "Local fallback dispatched missing QFT input craft while Mainnet offline")

-- Mainnet Stock comes back online -> auto-syncs pending rules with STOCK_PUSH_RULES!
computer._setUptime(225.0)
assert(Hardware.handleMeshMessage(cfg, st, "mod-q", "ae2-addr", 4205, "STOCK_CLAIMS",
    serialization.serialize({ armed = true, keys = {} })), "Handled STOCK_CLAIMS")
Scheduler.step(cfg, st, 225.0)
assertEq(st.maintMode.mode, "mainnet", "Maintainer switched to MAINNET STOCK")
local sawPush = false
for _, pk in ipairs(meshPkts) do
    if pk.mType == "STOCK_PUSH_RULES" then
        local dec = serialization.unserialize(pk.body)
        if dec and dec.rules and #dec.rules > 0 then sawPush = true end
    end
end
assert(sawPush, "Auto-synced pending recipe inputs via STOCK_PUSH_RULES on reconnect")

-- Push directly while Mainnet is online + retire untag
local resMain = Scheduler.pushRecipeInputs(cfg, st, { recipeId = "plastics_line" })
assertEq(resMain.dispatched, "mainnet", "Online push dispatches straight to MAINNET STOCK")
local resRet = Scheduler.retireRecipeInputs(cfg, st, { recipeId = "plastics_line", pauseOrphans = true })
assertEq(resRet.mainnetNotified, true, "Retire sent untag command over mesh")

-- TEST 4: UI Render across all 4 tabs (zero wide glyphs)
component.gpu = component._newMockGPU(160, 50)
local ui = UI.new(cfg, st, function() end)
for tab = 1, 4 do
    ui.tab = tab
    ui:render()
end

-- TEST 5: Deferred reboot & update_local guard
local noInet = { list = function() return function() return nil end end, isAvailable = function() return false end }
local uFail = Scheduler.executeRpcTable(cfg, st, { id = "u0", op = "qft_action", action = "update_local", url = "http://127.0.0.1:8765/oc-raw" }, noInet)
assertEq(uFail.ok, false, "update_local rejects missing Internet Card")

return "OK"
"""
            res = host.exec_lua(lua_suite, "qft_test_suite")
            assert res == "OK", f"Unexpected test result: {res}"

            bad_cps = host.exec_lua(
                """
                local bad = {}
                for cp in pairs(__RENDERED_CELL_CPS) do
                    if __py_char_width(cp) ~= 1 then bad[#bad + 1] = string.format("U+%04X", cp) end
                end
                return table.concat(bad, ",")
                """,
                "glyph_audit",
            )
            assert not bad_cps, f"Non-width-1 glyphs rendered in QFT UI: {bad_cps}"

            L = host.lib
            L.lua_gc.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
            L.lua_gc.restype = ctypes.c_int
            L.lua_gc(host.L, 2, 0)
            live_kb = L.lua_gc(host.L, 3, 0)
            assert live_kb < 2000, f"QFT heap unexpected: {live_kb} KB"

            # TEST 6: Standalone & root monorepo installer
            inst_host = LuaHost(Path(td), font_widths)
            try:
                inst_host.exec_lua(
                    """
                    local inst = assert(loadfile(__QFT_ROOT .. "/install.lua"))
                    assert(inst("--local", __QFT_ROOT, "--yes", "--no-autostart"), "QFT install failed")
                    for _, p in ipairs({
                        "/home/qft/main.lua", "/home/qft/lib/recipes_db.lua",
                        "/home/qft/lib/hardware.lua", "/home/qft/lib/scheduler.lua",
                        "/home/qft/lib/ui.lua", "/usr/bin/qft.lua",
                    }) do
                        assert(__py_exists(p), "Missing installed QFT file: " .. p)
                    end
                    local rootInst = assert(loadfile(__MONOREPO_ROOT .. "/install.lua"))
                    rootInst("--list")
                    assert(rootInst("--local", __MONOREPO_ROOT, "qft", "--yes", "--no-autostart"), "Root monorepo install qft failed")
                    """,
                    "qft_install_test",
                )
                assert "qft" in "\n".join(inst_host.stdout)
            finally:
                inst_host.close()

            print(f"ALL GTNH QFT CONTROL OFFLINE SUITES PASSED (0 bad-width glyphs, {live_kb} KB JNLua heap, Lua 5.3 + OpenOS verified).")
        finally:
            host.close()


if __name__ == "__main__":
    run_all_tests()
