-- ForeverProbe/Log.lua
-- Ring-buffer log kept inside SavedVariables so a play session can be read
-- from disk afterwards (scripts/read-probe.py). Also the shared helper table
-- for sibling probe addons: it is exposed as the global ForeverProbe.
--
-- Rules this file enforces for everyone who logs through it:
--   * never tostring() or boolean-test a possibly secret value directly
--   * never let a formatting mistake raise inside an event handler

local ADDON, ns = ...
_G.ForeverProbe = ns

local unpack = unpack or table.unpack
local MAX_LOG = 3000      -- entries kept in ForeverProbeDB.log
local TRIM_TO = 2500      -- after trimming, this many remain
local LEVELS = { ERROR = 0, WARN = 0, INFO = 1, DEBUG = 2, TRACE = 3 }
local COLORS = { ERROR = "ff5555", WARN = "ffaa33", INFO = "33ff99", DEBUG = "99ccff", TRACE = "888888" }

ns.name = ADDON
ns.verbose = 1            -- 0 errors only, 1 info, 2 debug, 3 trace
ns.pre = {}               -- entries logged before the DB global exists
ns.seq = 0
ns.LEVELS = LEVELS

local issecret = _G.issecretvalue or function() return false end
local issecrettable = _G.issecrettable or function() return false end
ns.issecret = issecret
ns.issecrettable = issecrettable

-- Render any value as a plain string without ever tripping on a secret.
function ns.str(v)
	if issecret(v) then
		return "<secret>"
	end
	local ok, s = pcall(tostring, v)
	if ok then
		return s
	end
	return "<unprintable>"
end

-- One-word description used in reports: value, or what kind of secret it is.
function ns.describe(v)
	if issecret(v) then
		local ok, t = pcall(type, v)
		return "<secret " .. (ok and tostring(t) or "?") .. ">"
	end
	local ok, t = pcall(type, v)
	if not ok then
		return "<untypable>"
	end
	if t == "table" then
		if issecrettable(v) then
			return "<secret table>"
		end
		return "table"
	end
	if t == "string" then
		return '"' .. v .. '"'
	end
	return ns.str(v)
end

-- string.format that only ever sees plain strings. Use %s in the pattern.
function ns.fmt(fmt, ...)
	local n = select("#", ...)
	if n == 0 then
		return ns.str(fmt)
	end
	local args = {}
	for i = 1, n do
		args[i] = ns.str((select(i, ...)))
	end
	local ok, s = pcall(string.format, fmt, unpack(args, 1, n))
	if ok then
		return s
	end
	return ns.str(fmt) .. " [" .. table.concat(args, ", ") .. "]"
end

local function now()
	local t = (GetTime and GetTime()) or 0
	return math.floor(t * 100) / 100
end

local function db()
	local d = _G.ForeverProbeDB
	if type(d) == "table" then
		if type(d.log) ~= "table" then
			d.log = {}
		end
		return d
	end
	return nil
end

local function push(entry)
	local d = db()
	local log = d and d.log or ns.pre
	log[#log + 1] = entry
	if #log > MAX_LOG then
		local keep = {}
		for i = #log - TRIM_TO + 1, #log do
			keep[#keep + 1] = log[i]
		end
		if d then
			d.log = keep
		else
			ns.pre = keep
		end
	end
end

-- Move entries logged before ADDON_LOADED into the real DB.
function ns.flushPre()
	local d = db()
	if not d or #ns.pre == 0 then
		return 0
	end
	local n = #ns.pre
	for i = 1, n do
		d.log[#d.log + 1] = ns.pre[i]
	end
	ns.pre = {}
	return n
end

function ns.log(level, src, fmt, ...)
	ns.seq = ns.seq + 1
	local msg = ns.fmt(fmt, ...)
	local entry = {
		seq = ns.seq,
		t = now(),
		st = (GetServerTime and GetServerTime()) or 0,
		lvl = level,
		src = src,
		msg = msg,
	}
	local okc, inCombat = pcall(function()
		return InCombatLockdown and InCombatLockdown()
	end)
	if okc and inCombat then
		entry.c = true
	end
	push(entry)
	if ns.verbose >= (LEVELS[level] or 1) then
		print(("|cff%s[%s:%s]|r %s"):format(COLORS[level] or "ffffff", ns.str(src), ns.str(level), msg))
	end
	return msg
end

function ns.err(src, ...) return ns.log("ERROR", src, ...) end
function ns.warn(src, ...) return ns.log("WARN", src, ...) end
function ns.info(src, ...) return ns.log("INFO", src, ...) end
function ns.debug(src, ...) return ns.log("DEBUG", src, ...) end
function ns.trace(src, ...) return ns.log("TRACE", src, ...) end

function ns.print(msg, ...)
	print("|cff33ff99ForeverProbe|r: " .. ns.fmt(msg, ...))
end

-- Resolve "C_Secrets.ShouldAurasBeSecret" to the value at that path, or nil.
function ns.resolve(path)
	local cur = _G
	for part in string.gmatch(path, "[^%.]+") do
		local ok, nxt = pcall(function() return cur[part] end)
		if not ok or nxt == nil then
			return nil
		end
		cur = nxt
	end
	return cur
end

-- pcall a function found by dotted path. Returns ok, result...  (ok=false, err) on failure,
-- (nil, "missing") when the path does not resolve to a function.
function ns.call(path, ...)
	local fn = ns.resolve(path)
	local okt, t = pcall(type, fn)
	if not okt or t ~= "function" then
		return nil, "missing"
	end
	return pcall(fn, ...)
end

-- RegisterEvent that cannot abort the calling file. Returns true on success.
function ns.safeRegister(frame, event, src)
	local ok, err = pcall(frame.RegisterEvent, frame, event)
	if not ok then
		ns.warn(src or "FP", "RegisterEvent(%s) failed: %s", event, err)
		return false
	end
	return true
end

-- Count how many entries are in the live log (or the pre-buffer).
function ns.logCount()
	local d = db()
	if d then
		return #d.log
	end
	return #ns.pre
end

function ns.tail(n)
	local d = db()
	local log = d and d.log or ns.pre
	local out = {}
	for i = math.max(1, #log - (n or 20) + 1), #log do
		out[#out + 1] = log[i]
	end
	return out
end
