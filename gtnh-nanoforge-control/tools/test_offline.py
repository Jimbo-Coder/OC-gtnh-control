#!/usr/bin/env python3
"""Offline Lua 5.3 + OpenComputers JNLua test suite for gtnh-nanoforge-control."""

from __future__ import annotations

import ctypes
import os
import tempfile
import zipfile
from pathlib import Path

NANO_ROOT = Path(__file__).resolve().parent.parent


def _find_gtnh_root(start: Path) -> Path:
    for parent in start.parents:
        if (parent / "tools/jdks").exists() or list(parent.glob("GT_NH_*/mods/OpenComputers-*.jar")):
            return parent
    return start.parent.parent


def _discover_jvm_dylib() -> Path:
    env = os.environ.get("JVM_DYLIB")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(NANO_ROOT)
    cands = sorted(gtnh_root.glob("tools/jdks/**/libjvm.dylib"), reverse=True) + sorted(gtnh_root.glob("tools/jdks/**/libjvm.so"), reverse=True)
    return cands[0] if cands else (gtnh_root / "tools/jdks/jdk8/Contents/Home/jre/lib/server/libjvm.dylib")


def _discover_oc_jar() -> Path:
    env = os.environ.get("OC_JAR")
    if env:
        return Path(env)
    gtnh_root = _find_gtnh_root(NANO_ROOT)
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
        package = { path = "/home/nanoforge/?.lua;/usr/lib/?.lua", loaded = { io = io, os = os }, preload = {} }
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
    common_path = NANO_ROOT.parent / "common" / "gtnh_common.lua"
    with tempfile.TemporaryDirectory() as td:
        host = LuaHost(Path(td), font_widths)
        try:
            host.vfs["/usr/lib/gtnh_common.lua"] = common_path.read_text(encoding="utf-8")
            for rel in ["install.lua", "main.lua", "lib/recipes_db.lua", "lib/hardware.lua", "lib/scheduler.lua", "lib/ui.lua"]:
                host.vfs[f"/home/nanoforge/{rel}"] = (NANO_ROOT / rel).read_text(encoding="utf-8")
                host.vfs[f"/src/gtnh-nanoforge-control/{rel}"] = host.vfs[f"/home/nanoforge/{rel}"]
            host.vfs["/src/common/gtnh_common.lua"] = host.vfs["/usr/lib/gtnh_common.lua"]

            test_lua = r"""
            local function assertEq(a, b, msg)
                if a ~= b then error(string.format("ASSERT FAIL [%s]: expected=%s actual=%s", msg, tostring(b), tostring(a))) end
            end
            local function assertNear(a, b, tol, msg)
                if math.abs((a or 0) - b) > tol then error(string.format("ASSERT FAIL [%s]: %s != %s", msg, tostring(a), tostring(b))) end
            end

            local component = require("component")
            local RecipesDb = require("lib.recipes_db")
            local Hardware = require("lib.hardware")
            local Scheduler = require("lib.scheduler")
            local UI = require("lib.ui")
            local serialization = require("serialization")

            -- 1. All 12 GTNH 2.9.0 nanite tiers & Magmatter / 0.9999^P / 4/4 OC formulas
            assertEq(#RecipesDb.RECIPES, 12, "Catalog has all 12 nanite recipes")
            assertEq(RecipesDb.BY_ID.carbon.tier, 1, "Carbon = T1")
            assertEq(RecipesDb.BY_ID.neutronium.tier, 1, "Neutronium = T1")
            assertEq(RecipesDb.BY_ID.silver.tier, 2, "Silver = T2")
            assertEq(RecipesDb.BY_ID.glowstone.tier, 2, "Glowstone = T2")
            assertEq(RecipesDb.BY_ID.transcendent.tier, 2, "Transcendent = T2")
            assertEq(RecipesDb.BY_ID.gold.tier, 3, "Gold = T3")
            assertEq(RecipesDb.BY_ID.eternity.tier, 3, "Eternity = T3")
            assertEq(RecipesDb.BY_ID.magmatter.tier, 4, "Magmatter = T4")

            assertEq(RecipesDb.magmatterPerParallel(1), 36, "T1 Magmatter/P = 36L")
            assertEq(RecipesDb.magmatterPerParallel(2), 72, "T2 Magmatter/P = 72L")
            assertEq(RecipesDb.magmatterPerParallel(3), 144, "T3 Magmatter/P = 144L")
            assertEq(RecipesDb.magmatterPerParallel(4), 288, "T4 Magmatter/P = 288L")
            assertEq(RecipesDb.exactMagmatter(4, 1), 0, "1x parallel needs 0L Magmatter")
            assertEq(RecipesDb.exactMagmatter(4, 4), 1152, "4x T4 Magmatter needs 1152L")
            assertNear(RecipesDb.speedMultiplier(100, 4), 0.9999 ^ 100, 1e-9, "0.9999^100 duration mult")
            assertEq(RecipesDb.hasPerfectOC(4, 2, 1), true, "T4 gets 4/4 OC on T2 even @1x")
            assertEq(RecipesDb.hasPerfectOC(4, 3, 1), false, "T4 does NOT get 4/4 OC on T3 @1x")
            assertEq(RecipesDb.hasPerfectOC(4, 3, 2), true, "T4 gets 4/4 OC on T3 @>=2x")
            assertEq(RecipesDb.hasPerfectOC(4, 4, 16), false, "T4 does NOT get 4/4 OC on T4")

            -- 2. planBatch rules: bootstrap 1x, T3 min perfect OC, Magmatter reserve
            local cfg = Scheduler.defaultConfig()
            local bBoot = Scheduler.planBatch(cfg, RecipesDb.BY_ID.eternity, 4, 0, 50000, 10000)
            assertEq(bBoot.parallels, 1, "Bootstrap 1x when output stock=0")
            assertEq(bBoot.magmatterL, 0, "Bootstrap 1x meters 0L Magmatter")
            assertEq(bBoot.bootstrap1x, true, "Marked bootstrap1x=true")

            local bT3 = Scheduler.planBatch(cfg, RecipesDb.BY_ID.eternity, 1, 5, 50000, 10000)
            assertEq(bT3.parallels, 2, "t3MinPerfectOc bumps T3 1x -> 2x")
            assertEq(bT3.magmatterL, 288, "2x T3 Eternity meters 288L Magmatter")
            assertEq(bT3.perfectOC, true, "T3 @2x unlocks 4/4 Perfect OC")

            local bRes = Scheduler.planBatch(cfg, RecipesDb.BY_ID.magmatter, 8, 5, 10287, 10000)
            assertEq(bRes.parallels, 1, "magmatterReserveL=10000 prevents dipping reserve below 10000L for 2x (576L)")

            cfg.forgeTier = 3
            local bTier = Scheduler.planBatch(cfg, RecipesDb.BY_ID.magmatter, 1, 5, 50000, 10000)
            assert(bTier.blockedReason ~= nil, "T3 Forge blocks T4 recipe")
            cfg.forgeTier = 4

            -- 3. Mock hardware: Bus Purity + Foreign AutoSweep + Allowed Universium Input + Exact Hatch Top-Up (need - existing) + Staging
            local stagingInv = {
                -- Put 2x Eternity batches in staging so T3 >=2x Perfect OC (288L) applies!
                { name = "gregtech:gt.metaitem.03", damage = 4139, size = 4, label = "Universium Nanites" },
                { name = "gregtech:gt.blockmetal9", damage = 9, size = 16, label = "Block of Eternity" },
                { name = "gregtech:gt.metaitem.03", damage = 32269, size = 128, label = "Atto Power IC" },
                { name = "gregtech:gt.metaitem.03", damage = 32757, size = 2, label = "Timepiece" },
            }
            local seedInv = {
                { name = "gregtech:gt.metaitem.03", damage = 4141, size = 8, label = "Eternity Nanites" },
            }
            local busInv = {
                { name = "gregtech:gt.metaitem.03", damage = 4010, size = 1, label = "Carbon Nanites" }, -- Foreign nanite!
                { name = "gregtech:gt.metaitem.03", damage = 4139, size = 2, label = "Universium Nanites" }, -- Valid Eternity input!
            }
            local returnInv = {}
            local hatchMag = 100 -- Pre-existing 100L Magmatter in dedicated hatch -> top-up for 288L should transfer ONLY 188L!
            local srcTankMag = 20000
            local transferredMag = 0
            local machActive = false
            local sentPackets = {}
            local wakeMsg = "INIT"

            component._reset()
            component._register("nf-1", "gt_machine", {
                getName = function() return "multimachine.nanoforge" end,
                isMachineActive = function() return machActive end,
                isWorkAllowed = function() return true end,
                getWorkProgress = function() return machActive and 50 or 0 end,
                getWorkMaxProgress = function() return 3750 end,
                getMaxInputVoltage = function() return 2147483640 end,
                getSensorInformation = function() return { "0 Problems" } end,
            })
            component._register("tp-item", "transposer", {
                getAllStacks = function(side)
                    local t = (side == 2 and stagingInv) or (side == 4 and seedInv) or (side == 5 and busInv) or returnInv
                    return { getAll = function() return t end }
                end,
                getFluidInTank = function(side)
                    if side == 2 then
                        return {
                            { name = "spatialfluid", amount = 576 },
                            { name = "exciteddtsc", amount = 25000 },
                            { name = "primordialmatter", amount = 128000 },
                        }
                    end
                    return {}
                end,
                transferItem = function(src, dst, cnt, slot)
                    local sTbl = (src == 2 and stagingInv) or (src == 4 and seedInv) or (src == 5 and busInv)
                    local dTbl = (dst == 5 and busInv) or returnInv
                    if not sTbl or not sTbl[slot] or sTbl[slot].size < cnt then return 0 end
                    local mv = math.min(cnt, sTbl[slot].size)
                    sTbl[slot].size = sTbl[slot].size - mv
                    dTbl[#dTbl + 1] = { name = sTbl[slot].name, damage = sTbl[slot].damage, size = mv, label = sTbl[slot].label }
                    if sTbl[slot].size == 0 then sTbl[slot] = nil end
                    return mv
                end,
                transferFluid = function() return true, 0 end,
            })
            component._register("tp-mag", "transposer", {
                getFluidInTank = function(side)
                    if side == 1 then return { { name = "molten.magmatter", amount = hatchMag } } end
                    if side == 0 then return { { name = "molten.magmatter", amount = srcTankMag } } end
                    return {}
                end,
                transferFluid = function(src, dst, amt)
                    local mv = math.min(amt, srcTankMag)
                    srcTankMag = srcTankMag - mv
                    hatchMag = hatchMag + mv
                    transferredMag = transferredMag + mv
                    return true, mv
                end,
            })
            component._register("ae-1", "me_interface", {
                getItemsInNetwork = function(f)
                    if f and f.damage == 4141 then return { { size = 10 } } end
                    return {}
                end,
                getFluidsInNetwork = function() return { { name = "molten.magmatter", amount = 20000 } } end,
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

            cfg.armed = true
            cfg.itemTransposerAddr = "tp-item"
            cfg.magTransposerAddr = "tp-mag"
            cfg.aeAddr = "ae-1"
            cfg.targets.eternity.targetParallels = 2 -- 2x Eternity = 288L target Magmatter
            local st = Scheduler.newState()
            Scheduler.syncHardware(cfg, st)

            -- Scan with Universium allowed & Carbon foreign
            local scan0 = Hardware.scanBusNanites(cfg, 4141, { [4139] = true })
            assertEq(scan0.clean, false, "Carbon nanite (4010) flagged foreign even when Universium (4139) allowed")
            assertEq(#scan0.foreign, 1, "Exactly 1 foreign nanite found (Universium NOT flagged)")

            -- AutoSweep disabled blocks dispatch
            cfg.autoSweepForeign = false
            assertEq(Scheduler.step(cfg, st, 100.0), false, "Foreign nanite blocks dispatch when autoSweepForeign=false")

            -- Re-enable autoSweepForeign -> sweeps Carbon to returnSide, meters ONLY 188L (288 - 100 existing), injects 1x Eternity seed, dispatches staging!
            cfg.autoSweepForeign = true
            assertEq(Scheduler.step(cfg, st, 101.0), true, "Swept foreign nanite and dispatched Eternity batch")
            assertEq(st.phase, "RUNNING", "Phase transitioned IDLE -> RUNNING")
            assertEq(st.currentBatch.recipeId, "eternity", "Dispatched Eternity staging order")
            assertEq(st.currentBatch.parallels, 2, "Dispatched 2x Eternity batch with 4/4 Perfect OC")
            assertEq(transferredMag, 188, "Exact single-hatch top-up transferred 288 - 100 = 188L Magmatter")
            assertEq(hatchMag, 288, "Dedicated hatch now holds exact 288L")
            assertEq(#returnInv, 1, "Carbon nanite swept into return chest")
            assertEq(returnInv[1].damage, 4010, "Swept slot was Carbon Nanites (4010)")
            local seedInBus = 0
            for _, x in pairs(busInv) do if x and x.damage == 4141 then seedInBus = seedInBus + x.size end end
            assertEq(seedInBus, 1, "Injected exactly 1x Eternity Nanite output seed into clean bus")

            -- Serialized lock while running -> second step stays RUNNING and does not double-dispatch
            machActive = true
            assertEq(Scheduler.step(cfg, st, 103.0), true, "Stays RUNNING while active")
            assertEq(st.completedBatches, 0, "Not yet completed")
            machActive = false
            assertEq(Scheduler.step(cfg, st, 105.0), true, "Transitions RUNNING -> IDLE once machine stops")
            assertEq(st.phase, "IDLE", "Returned to IDLE")
            assertEq(st.completedBatches, 1, "Completed batch counter = 1")

            -- 4. RPC push_inputs + set_auto_wake=false persistence + chunked NANO_REPLY format
            local function rpcCall(cmd) return Scheduler.executeRpcTable(cfg, st, cmd, nil, function() end) end
            Hardware.openMeshPort(cfg, nil, st)
            assertEq(wakeMsg, "GTNH_WAKE", "Auto-Wake initially GTNH_WAKE")
            local pushRes = rpcCall({ op = "push_inputs", recipeId = "magmatter", mult = 1 })
            assertEq(pushRes.ok, true, "push_inputs sent STOCK_PUSH_RULES")
            assertEq(Hardware.handleMeshMessage(cfg, st, "mod-1", "ae2-addr", 4205, "NANO_CMD", "n1",
                serialization.serialize({ op = "nano_action", action = "set_auto_wake", enabled = false }), nil, rpcCall), true, "Handled NANO_CMD set_auto_wake=false")
            assertEq(wakeMsg, "", "Cleared setWakeMessage")
            Hardware.pushMeshMetrics(cfg, st, 110.0, nil, true)
            assertEq(wakeMsg, "", "Preserved cleared wakeMsg across subsequent pushMeshMetrics")
            local sawChunkReply = false
            for _, sp in ipairs(sentPackets) do
                if sp.t == "NANO_REPLY" and sp.r == "n1" and sp.a2 == 1 and type(sp.a3) == "number" and type(sp.a4) == "string" then
                    sawChunkReply = true
                end
            end
            assert(sawChunkReply, "NANO_REPLY uses chunked (reqId, idx, total, slice) wire format")

            -- 5. Render all 4 UI tabs (160x50, 0 non-width-1 glyphs)
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
            for t = 1, 4 do
                ui.tab = t
                ui:render()
            end
            for cp, w in pairs(usedCps) do
                assertEq(w, 1, "Non-width-1 glyph codepoint=" .. tostring(cp))
            end

            -- 6. Local installer + --check smoke test
            local instChunk = assert(load(__py_read_file("/src/gtnh-nanoforge-control/install.lua"), "@install.lua"))
            assertEq(instChunk("--local", "/src", "--no-autostart"), true, "Local Nano Forge installer succeeded")
            assert(__py_exists("/usr/bin/nanoforge.lua"), "Created /usr/bin/nanoforge.lua")
            local mainChunk = assert(load(__py_read_file("/home/nanoforge/main.lua"), "@/home/nanoforge/main.lua"))
            mainChunk("--check")
            print("ALL NANO FORGE OFFLINE SUITES PASSED (0 bad-width glyphs)")
            """
            host.exec_lua(test_lua, "nanoforge_test_suite")
            print("ALL NANO FORGE OFFLINE SUITES PASSED")
        finally:
            host.close()


if __name__ == "__main__":
    run_all_tests()
