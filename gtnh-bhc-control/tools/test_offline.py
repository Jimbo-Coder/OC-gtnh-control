#!/usr/bin/env python3
"""Offline Lua 5.3 + OpenComputers JNLua test suite for gtnh-bhc-control."""

from __future__ import annotations

import ctypes
import os
import tempfile
import zipfile
from pathlib import Path

BHC_ROOT = Path(__file__).resolve().parent.parent


def _find_gtnh_root(start: Path) -> Path:
    for parent in start.parents:
        if (parent / "tools/jdks").exists() or list(parent.glob("GT_NH_*/mods/OpenComputers-*.jar")):
            return parent
    return start.parent.parent


def _discover_jvm_dylib() -> Path:
    env = os.environ.get("JVM_DYLIB")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(BHC_ROOT)
    cands = sorted(gtnh_root.glob("tools/jdks/**/libjvm.dylib"), reverse=True) + sorted(gtnh_root.glob("tools/jdks/**/libjvm.so"), reverse=True)
    return cands[0] if cands else (gtnh_root / "tools/jdks/jdk8/Contents/Home/jre/lib/server/libjvm.dylib")


def _discover_oc_jar() -> Path:
    env = os.environ.get("OC_JAR")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(BHC_ROOT)
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

    def _register_host_callbacks(self) -> None:
        CFUNC = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)
        L = self.lib

        def _get_str(ptr: int, idx: int) -> str:
            ln = ctypes.c_size_t(0)
            raw = L.lua_tolstring(ptr, idx, ctypes.byref(ln))
            return raw[:ln.value].decode("utf-8", errors="replace") if raw else ""

        def wrap(fn):
            cb = CFUNC(fn)
            self._cfuncs.append(cb)
            L.lua_pushcclosure(self.L, cb, 0)

        wrap(lambda p: (self.vfs.__setitem__(_get_str(p, 1), _get_str(p, 2)), L.lua_pushboolean(p, 1), 1)[-1])
        L.lua_setglobal(self.L, b"__py_write_file")
        wrap(lambda p: (L.lua_pushlstring(p, self.vfs[_get_str(p, 1)].encode("utf-8"), len(self.vfs[_get_str(p, 1)].encode("utf-8"))) if _get_str(p, 1) in self.vfs else L.lua_pushnil(p), 1)[-1])
        L.lua_setglobal(self.L, b"__py_read_file")
        wrap(lambda p: (L.lua_pushboolean(p, 1 if _get_str(p, 1) in self.vfs else 0), 1)[-1])
        L.lua_setglobal(self.L, b"__py_exists")
        wrap(lambda p: (self.vfs.pop(_get_str(p, 1), None), L.lua_pushboolean(p, 1), 1)[-1])
        L.lua_setglobal(self.L, b"__py_remove")
        wrap(lambda p: (self.stdout.append(_get_str(p, 1)), 0)[-1])
        L.lua_setglobal(self.L, b"__py_print")
        wrap(lambda p: (L.lua_pushinteger(p, self.font_widths.get(int(L.lua_tointegerx(p, 1, None)), 1)), 1)[-1])
        L.lua_setglobal(self.L, b"__py_char_width")

    def exec_lua(self, code: str, name: str = "chunk") -> str | None:
        L = self.lib
        b = code.encode("utf-8")
        if L.luaL_loadbufferx(self.L, b, len(b), name.encode("utf-8"), b"t") != 0:
            err = L.lua_tolstring(self.L, -1, None)
            L.lua_settop(self.L, 0)
            raise RuntimeError(f"Lua compile error in {name}: {err.decode('utf-8', errors='replace') if err else ''}")
        if L.lua_pcallk(self.L, 0, 1, 0, 0, None) != 0:
            err = L.lua_tolstring(self.L, -1, None)
            L.lua_settop(self.L, 0)
            raise RuntimeError(f"Lua runtime error in {name}: {err.decode('utf-8', errors='replace') if err else ''}")
        res = None
        if L.lua_gettop(self.L) >= 1:
            ln = ctypes.c_size_t(0)
            raw = L.lua_tolstring(self.L, -1, ctypes.byref(ln))
            if raw:
                res = raw[:ln.value].decode("utf-8", errors="replace")
        L.lua_settop(self.L, 0)
        return res

    def _install_openos_shim(self) -> None:
        shim = r"""
        local __files = {}
        local __uptime = 100.0
        _G.print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
            __py_print(table.concat(parts, "\t"))
        end
        _G.os = _G.os or {}
        os.clock = function() return __uptime end
        os.sleep = function(dt) __uptime = __uptime + (tonumber(dt) or 0) end
        _G.io = {
            stderr = { write = function(_, s) __py_print("[ERR] " .. tostring(s)) end },
            open = function(path, mode)
                mode = mode or "r"
                if mode:sub(1, 1) == "r" then
                    local data = __py_read_file(path)
                    if not data then return nil, "not found" end
                    return { read = function(_, what) return (what == "*a") and data or data end, close = function() end }
                elseif mode:sub(1, 1) == "w" then
                    local buf = {}
                    return { write = function(_, s) buf[#buf + 1] = tostring(s) end, close = function() __py_write_file(path, table.concat(buf)) end }
                end
            end,
        }
        _G.loadfile = function(path)
            local src = __py_read_file(path)
            if not src then return nil, "missing " .. tostring(path) end
            return load(src, "=" .. path, "t")
        end
        function checkArg(n, have, ...)
            local tp = type(have)
            for i = 1, select("#", ...) do
                if tp == select(i, ...) then return end
            end
            error(string.format("bad argument #%s (%s expected, got %s)", tostring(n), table.concat({...}, " or "), tp), 3)
        end
        package = { path = "/home/bhc/?.lua;/usr/lib/?.lua", loaded = { io = io, os = os }, preload = {} }
        function require(name)
            if package.loaded[name] ~= nil then return package.loaded[name] end
            if package.preload[name] then
                local r = package.preload[name](name)
                package.loaded[name] = (r == nil) and true or r
                return package.loaded[name]
            end
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
        local _compList, _compProxies = {}, {}
        local compMod = {
            _reset = function() _compList = {}; _compProxies = {} end,
            _register = function(addr, ctype, proxy)
                _compProxies[addr] = proxy
                _compList[ctype] = _compList[ctype] or {}
                _compList[ctype][addr] = ctype
                proxy.address = proxy.address or addr
                proxy.type = proxy.type or ctype
            end,
            isAvailable = function(ct) return _compList[ct] ~= nil and next(_compList[ct]) ~= nil end,
            proxy = function(addr) return _compProxies[addr] end,
            list = function(ct, exact)
                local keys = {}
                for k, t in pairs(_compList[ct] or {}) do keys[#keys + 1] = { k, t } end
                table.sort(keys, function(a, b) return a[1] < b[1] end)
                local idx = 0
                return function() idx = idx + 1; if keys[idx] then return keys[idx][1], keys[idx][2] end end
            end,
        }
        package.preload.component = function() return compMod end
        package.preload.computer = function()
            return {
                uptime = function() return __uptime end,
                _advance = function(dt) __uptime = __uptime + dt end,
                freeMemory = function() return 1800 * 1024 end,
                totalMemory = function() return 2048 * 1024 end,
                shutdown = function() _G.__LAST_SHUTDOWN = true end,
            }
        end
        package.preload.filesystem = function()
            return {
                exists = function(p) return __py_exists(p) end,
                makeDirectory = function() return true end,
                remove = function(p) return __py_remove(p) end,
                rename = function(a, b) local d = __py_read_file(a); if d then __py_write_file(b, d); __py_remove(a); return true end return false end,
                path = function(p) return (tostring(p):match("^(.*)/[^/]*$") or "/") end,
                canonical = function(p) return p end,
                concat = function(a, b) return (tostring(a):gsub("/+$", "")) .. "/" .. (tostring(b):gsub("^/+", "")) end,
            }
        end
        package.preload.event = function()
            local listeners = {}
            return {
                listen = function(ev, fn) listeners[ev] = fn; return 1 end,
                ignore = function(ev) listeners[ev] = nil; return true end,
                pull = function() return nil end,
                _listeners = listeners,
            }
        end
        package.preload.term = function() return { clear = function() end } end
        package.preload.unicode = function()
            return {
                wlen = function(s) local w = 0; for _, cp in utf8.codes(tostring(s or "")) do w = w + __py_char_width(cp) end; return w end,
                charWidth = function(ch) local cp = utf8.codepoint(tostring(ch or " "), 1) or 32; return __py_char_width(cp) end,
                sub = function(s, i, j)
                    s = tostring(s or ""); local len = utf8.len(s) or #s
                    if i < 0 then i = len + i + 1 end; if i < 1 then i = 1 end
                    local sb = utf8.offset(s, i); if not sb then return "" end
                    if not j then return s:sub(sb) end
                    if j < 0 then j = len + j + 1 end; if j < i then return "" end
                    local eb = utf8.offset(s, j + 1)
                    return eb and s:sub(sb, eb - 1) or s:sub(sb)
                end,
            }
        end
        local serChunk, serErr = load(__py_read_file("/lib/serialization.lua"), "@/lib/serialization.lua", "t")
        if not serChunk then error(serErr) end
        package.preload.serialization = function() return serChunk() end
        """
        self.vfs["/lib/serialization.lua"] = self.serialization_lua
        self.exec_lua(shim, "openos_shim")


def run_all_tests() -> None:
    font_widths = load_font_widths()
    common_path = BHC_ROOT.parent / "common" / "gtnh_common.lua"
    with tempfile.TemporaryDirectory() as td:
        host = LuaHost(Path(td), font_widths)
        try:
            host.vfs["/usr/lib/gtnh_common.lua"] = common_path.read_text(encoding="utf-8")
            for rel in ["install.lua", "main.lua", "lib/hardware.lua", "lib/scheduler.lua", "lib/ui.lua"]:
                host.vfs[f"/home/bhc/{rel}"] = (BHC_ROOT / rel).read_text(encoding="utf-8")
                host.vfs[f"/src/gtnh-bhc-control/{rel}"] = host.vfs[f"/home/bhc/{rel}"]
            host.vfs["/src/common/gtnh_common.lua"] = host.vfs["/usr/lib/gtnh_common.lua"]

            test_lua = r"""
            local function assertEq(a, b, msg)
                if a ~= b then error(string.format("ASSERT FAIL [%s]: expected=%s actual=%s", msg, tostring(b), tostring(a))) end
            end

            local component = require("component")
            local computer = require("computer")
            local Hardware = require("lib.hardware")
            local Scheduler = require("lib.scheduler")
            local UI = require("lib.ui")
            local serialization = require("serialization")

            -- 1. Voltage tier & parallel multipliers match MTEBlackHoleCompressor bytecode
            assertEq(Hardware.calcVoltageTier(524288), 8, "UV voltage = tier 8")
            assertEq(Hardware.calcVoltageTier(2097152), 9, "UHV voltage = tier 9")
            assertEq(Scheduler.calcEffectiveParallels(8, "pseudostable", 100, true), 64, "UV Normal @100% = 64p")
            assertEq(Scheduler.calcEffectiveParallels(8, "pseudostable", 49, true), 128, "UV Normal @49% = 128p")
            assertEq(Scheduler.calcEffectiveParallels(8, "pseudostable", 19, true), 256, "UV Normal @19% = 256p")
            assertEq(Scheduler.calcEffectiveParallels(8, "pseudostable", 19, false), -1, "Non-BH @19% = uncapped (-1)")
            assertEq(Scheduler.calcEffectiveParallels(8, "supermassive", 19, true), 1024, "UV Supermassive @19% = 1024p")
            assertEq(Scheduler.calcEffectiveParallels(8, "superstable", 100, true), 256, "UV Superstable = 256p")

            -- 2. Full mock hardware: Collapser reserve guard + Pulse lifecycle + 30s SpaceTime doubling + Safe emergency collapse
            local mockCat = {
                { name = "gregtech:gt.metaitem.01", damage = 32418, size = 4 }, -- Black Hole Seed
                { name = "gregtech:gt.metaitem.01", damage = 32419, size = 0 }, -- Collapser = 0 initially!
            }
            local mockStTank = 5000
            local bhDst = {}
            local valveOut, gateOut = 0, 15
            local utilSig = 0
            local workProg, workMax, machActiveOv = 10, 100, nil
            local sentPackets = {}
            local wakeMsg = "INIT"

            component._reset()
            component._register("bhc-1", "gt_machine", {
                getName = function() return "multimachine.blackholecompressor" end,
                isMachineActive = function()
                    if machActiveOv ~= nil then return machActiveOv end
                    return utilSig > 0
                end,
                isWorkAllowed = function() return true end,
                getWorkProgress = function() return workProg end,
                getWorkMaxProgress = function() return workMax end,
                getMaxInputVoltage = function() return 524288 end,
                getSensorInformation = function() return { "Max Input: 524288 EU/t", "0 Problems" } end,
            })
            component._register("rs-1", "redstone", {
                getInput = function(side) return (side == 1) and utilSig or 0 end,
                setOutput = function(side, v)
                    if side == 2 then valveOut = v
                    elseif side == 3 then gateOut = v end
                    return v
                end,
            })
            component._register("tp-1", "transposer", {
                getAllStacks = function(side)
                    if side == 4 then return { getAll = function() return mockCat end } end
                    return { getAll = function() return {} end }
                end,
                transferItem = function(src, dst, cnt, slot)
                    if src == 4 and dst == 5 and mockCat[slot] and mockCat[slot].size >= cnt then
                        mockCat[slot].size = mockCat[slot].size - cnt
                        bhDst[#bhDst + 1] = mockCat[slot].damage
                        return cnt
                    end
                    return 0
                end,
                getFluidInTank = function() return { { name = "molten.spacetime", amount = mockStTank } } end,
                transferFluid = function(s, d, amt)
                    local mv = math.min(amt, mockStTank)
                    mockStTank = mockStTank - mv
                    return true, mv
                end,
            })
            component._register("mod-1", "modem", {
                isOpen = function() return true end,
                isWireless = function() return true end,
                open = function() return true end,
                getStrength = function() return 400 end,
                setStrength = function() return 400 end,
                getWakeMessage = function() return wakeMsg end,
                setWakeMessage = function(m) wakeMsg = m; return true end,
                send = function(a, p, t, r, a2, a3, a4) sentPackets[#sentPackets + 1] = { t = t, r = r, a2 = a2, a3 = a3, a4 = a4 }; return true end,
                broadcast = function(p, t, r, a2, a3, a4) sentPackets[#sentPackets + 1] = { t = t, r = r, a2 = a2, a3 = a3, a4 = a4 }; return true end,
            })

            local cfg = Scheduler.defaultConfig()
            cfg.armed = true
            cfg.spacetimeValveMode = "transposer"
            cfg.minSpacetimeReserve = 4900 -- leaves 100 L budget for hold test
            local st = Scheduler.newState()
            Scheduler.syncHardware(cfg, st)

            -- Must refuse to open without a Collapser in reserve!
            Scheduler.step(cfg, st, 100.0)
            assertEq(st.phase, "CLOSED", "Refused to open BHC without Collapser reserve")
            assert(#bhDst == 0, "Zero catalysts injected while Collapser=0")

            -- Add Collapsers and step -> injects Seed -> OPENING
            mockCat[2].size = 3
            Scheduler.step(cfg, st, 101.0)
            assertEq(st.phase, "OPENING", "Injected Seed and entered OPENING")
            assertEq(bhDst[#bhDst], 32418, "Injected Black Hole Seed (32418)")

            -- Pulse 1 (real redstone rising/falling edge): Utility Hatch confirms BH open at 100%
            utilSig = 15
            Scheduler.step(cfg, st, 102.0)
            utilSig = 0
            Scheduler.step(cfg, st, 102.25)
            assertEq(st.phase, "FREE_DECAY", "First pulse transitions OPENING -> FREE_DECAY")
            assertEq(st.estStability, 100, "Initial stability = 100%")

            -- Free decay down to 15% (85 pulses @ 1/s) -> enters HOLDING
            for s = 1, 85 do
                utilSig = 15
                Scheduler.step(cfg, st, 102.0 + s)
                utilSig = 0
                Scheduler.step(cfg, st, 102.25 + s)
            end
            assertEq(st.estStability, 15, "Stability reached 15% sweet spot")
            assertEq(st.phase, "HOLDING", "Entered HOLDING at targetStability=15%")
            assertEq(valveOut, 15, "Opened SpaceTime valve in HOLDING")
            assertEq(st.heldSec, 0, "Zero hold seconds spent before entering HOLDING")

            -- Hold 30 pulses (t = 188..217) -> SpaceTime cost doubles 1 -> 2 L/s!
            for s = 1, 30 do
                utilSig = 15
                Scheduler.step(cfg, st, 187.0 + s)
                utilSig = 0
                Scheduler.step(cfg, st, 187.25 + s)
            end
            assertEq(st.heldSec, 30, "Held 30s at 1 L/s")
            assertEq(st.costMod, 2, "SpaceTime cost doubled to 2 L/s after 30s hold")

            -- Step while ST remaining drops below minSpacetimeReserve (4899 < 4900)
            mockStTank = 4899
            Scheduler.step(cfg, st, 218.0)
            assertEq(st.phase, "COLLAPSING", "Low SpaceTime triggers safe COLLAPSING before 0%")
            assertEq(gateOut, 0, "Paused new inputs during COLLAPSING")
            assertEq(bhDst[#bhDst], 32419, "Injected Black Hole Collapser (32419) safely before stability=0")

            -- Utility stops pulsing for >= 4s -> confirmed CLOSED (pause first so it stays CLOSED)
            cfg.armed = false
            utilSig = 0
            Scheduler.step(cfg, st, 237.0)
            assertEq(st.phase, "CLOSED", "BHC confirmed CLOSED after utility signal stopped")
            assertEq(st.cyclesCompleted, 1, "Incremented cyclesCompleted=1")
            cfg.armed = true

            -- 3. Mesh RPC: set_auto_wake=false persists across subsequent BHC_METRICS
            local savedCount = 0
            local rpcReply = nil
            local function rpcCall(cmd) return Scheduler.executeRpcTable(cfg, st, cmd, nil, function() savedCount = savedCount + 1 end) end
            Hardware.openMeshPort(cfg, nil, st)
            assertEq(wakeMsg, "GTNH_WAKE", "Auto-Wake initially armed GTNH_WAKE")
            assertEq(Hardware.handleMeshMessage(cfg, st, "mod-1", "ae2-addr", 4205, "BHC_CMD", "r1",
                serialization.serialize({ op = "bhc_action", action = "set_auto_wake", enabled = false }), nil, rpcCall), true, "Handled set_auto_wake=false")
            assertEq(cfg.autoWake, false, "cfg.autoWake updated to false")
            assertEq(wakeMsg, "", "setWakeMessage cleared to empty string")
            Hardware.pushMeshMetrics(cfg, st, 240.0, nil, true)
            assertEq(wakeMsg, "", "Subsequent pushMeshMetrics preserved cleared wakeMsg")
            local lastPkt = serialization.unserialize(sentPackets[#sentPackets].r)
            assertEq(lastPkt.autoWake, false, "BHC_METRICS includes autoWake=false")
            local bhcReplies = {}
            for _, sp in ipairs(sentPackets) do
                if sp.t == "BHC_REPLY" and sp.r == "r1" then bhcReplies[#bhcReplies + 1] = sp end
            end
            assert(#bhcReplies >= 1, "Sent BHC_REPLY packets")
            assertEq(bhcReplies[1].a2, 1, "BHC_REPLY uses chunk index arg (idx=1)")
            assertEq(type(bhcReplies[1].a3), "number", "BHC_REPLY uses total chunks arg")
            assertEq(type(bhcReplies[1].a4), "string", "BHC_REPLY uses slice string arg")

            -- 3b. Save Recipe Mode: save_spacetime (maxHoldSec=0) saves active recipe near collapseFloor!
            cfg.armed = false
            utilSig = 0
            Scheduler.applyPreset(cfg, "save_spacetime")
            cfg.saveRecipeMode = true
            cfg.minSpacetimeReserve = 1000
            mockStTank = 10000
            mockCat[1].size = 4
            mockCat[2].size = 4
            st = Scheduler.newState()
            Scheduler.syncHardware(cfg, st)
            cfg.armed = true
            Scheduler.step(cfg, st, 300.0)
            assertEq(st.phase, "OPENING", "Save Recipe test opened BH")
            utilSig = 15; Scheduler.step(cfg, st, 301.0); utilSig = 0; Scheduler.step(cfg, st, 301.25)
            assertEq(st.phase, "FREE_DECAY", "Save Recipe test entered FREE_DECAY")
            machActiveOv = false
            for s = 1, 93 do
                utilSig = 15; Scheduler.step(cfg, st, 301.0 + s)
                utilSig = 0; Scheduler.step(cfg, st, 301.25 + s)
            end
            assertEq(st.estStability, 7, "Decayed to 7% before active long craft check")
            machActiveOv = true; workProg = 0; workMax = 200 -- 10.0s remaining > (6 - 5) headroom!
            utilSig = 15; Scheduler.step(cfg, st, 395.0); utilSig = 0; Scheduler.step(cfg, st, 395.25)
            assertEq(st.estStability, 6, "Decayed to 6% with 10s craft still running")
            assertEq(st.phase, "HOLDING", "Save Recipe Mode overrode save_spacetime maxHoldSec=0 -> HOLDING")
            assertEq(st.savingRecipe, true, "savingRecipe flag active")
            assertEq(gateOut, 0, "Closed new input gate while saving active recipe")
            assertEq(valveOut, 15, "Opened SpaceTime valve for Save Recipe Mode")
            for s = 1, 5 do
                utilSig = 15; Scheduler.step(cfg, st, 395.0 + s)
                utilSig = 0; Scheduler.step(cfg, st, 395.25 + s)
            end
            assertEq(st.estStability, 6, "Save Recipe Mode held stability at 6% for 5s without voiding")
            machActiveOv = false
            Scheduler.step(cfg, st, 401.0)
            assertEq(st.savingRecipe, false, "savingRecipe cleared once craft finished")
            assertEq(st.phase, "COLLAPSING", "Collapsed immediately after saved recipe finished")
            assertEq(bhDst[#bhDst], 32419, "Injected Collapser cleanly after Save Recipe Mode")
            cfg.armed = false
            utilSig = 0
            Scheduler.step(cfg, st, 410.0)
            machActiveOv = nil
            Scheduler.applyPreset(cfg, "balanced")
            cfg.armed = true

            -- 4. Render all 3 UI tabs (160x50, 0 non-width-1 glyphs)
            local usedCps = {}
            component._register("gpu-1", "gpu", {
                maxResolution = function() return 160, 50 end,
                getResolution = function() return 160, 50 end,
                setResolution = function() return true end,
                getViewport = function() return 160, 50 end,
                setViewport = function() return true end,
                getScreen = function() return "scr-1" end,
                setBackground = function() end,
                setForeground = function() end,
                set = function(x, y, txt)
                    for _, cp in utf8.codes(txt) do usedCps[cp] = __py_char_width(cp) end
                end,
            })
            component._register("scr-1", "screen", {})
            local ui = UI.new(cfg, st, function() end)
            for t = 1, 3 do
                ui.tab = t
                ui:render()
            end
            for cp, w in pairs(usedCps) do
                assertEq(w, 1, "Non-width-1 glyph codepoint=" .. tostring(cp))
            end

            -- 5. Preset & installer smoke test
            local resP = rpcCall({ op = "bhc_action", action = "apply_preset", preset = "save_spacetime" })
            assertEq(resP.policy.maxHoldSec, 0, "Zero SpaceTime preset sets maxHoldSec=0")
            local instChunk = assert(load(__py_read_file("/src/gtnh-bhc-control/install.lua"), "@install.lua"))
            assertEq(instChunk("--local", "/src", "--no-autostart"), true, "Local BHC installer succeeded")
            assert(__py_exists("/usr/bin/bhc.lua"), "Created /usr/bin/bhc.lua")
            local mainChunk = assert(load(__py_read_file("/home/bhc/main.lua"), "@/home/bhc/main.lua"))
            mainChunk("--check")
            print("ALL BHC OFFLINE SUITES PASSED (0 bad-width glyphs)")
            """
            host.exec_lua(test_lua, "bhc_test_suite")
            print("ALL BHC OFFLINE SUITES PASSED")
        finally:
            host.close()


if __name__ == "__main__":
    run_all_tests()
