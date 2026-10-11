-- Offline tests for HunterHUD against tests/wowstub.lua.
-- Run: lua tests/test_hud.lua   (from the repo root)

package.path = "./tests/?.lua;" .. package.path
local Stub = require("wowstub")
Stub.echo = os.getenv("ECHO") == "1"

local passed, failed = 0, 0
local function check(cond, msg)
	if cond then
		passed = passed + 1
	else
		failed = failed + 1
		io.stderr:write("FAIL: " .. msg .. "\n")
	end
end
local function printedCount(s)
	local n = 0
	for _, line in ipairs(Stub.printed) do
		if line:find(s, 1, true) then n = n + 1 end
	end
	return n
end
local function same(c, r, g, b)
	return c and math.abs(c[1] - r) < 0.01 and math.abs(c[2] - g) < 0.01 and math.abs(c[3] - b) < 0.01
end

local function startSession(savedDb, classFile)
	Stub.reset()
	Stub.units.target = nil
	_G.UnitClass = function() return "Hunter", classFile or "HUNTER", 3 end
	_G.HunterHUDDB = nil
	Stub.ammo.count = 400
	local ns = Stub.loadAddon("addons/HunterHUD", "HunterHUD", { "HunterHUD.lua" })
	_G.HunterHUDDB = savedDb
	Stub.fire("ADDON_LOADED", "HunterHUD")
	Stub.fire("PLAYER_LOGIN")
	Stub.fire("PLAYER_ENTERING_WORLD", true, false)
	Stub.runTimers()
	return ns
end

------------------------------------------------------------------
-- hunter, fresh settings
------------------------------------------------------------------
local ns = startSession(nil)
local f = _G.HunterHUDFrame
check(f ~= nil and f:IsShown(), "frame built and shown for a hunter")
check(HunterHUDDB.warn == 200 and HunterHUDDB.crit == 50 and HunterHUDDB.locked == true, "defaults applied")
check(f.ammoText:GetText() == "400", "ammo count shown, got " .. tostring(f.ammoText:GetText()))
check(same(f.ammoText.color, 0.92, 0.92, 0.92), "ammo above warn is plain")
check(f.rangeText:GetText() == "", "no target: empty range label")

-- target at range
Stub.units.target = true
Stub.rangeAnswers[75] = true
Stub.rangeAnswers[2974] = false
Stub.fire("PLAYER_TARGET_CHANGED")
check(f.rangeText:GetText() == "IN RANGE", "ranged label, got " .. tostring(f.rangeText:GetText()))
check(same(f.light.color, 0.25, 0.9, 0.35), "ranged light is green")
check(not f.melee:IsShown(), "melee dot hidden at range")
check(#Stub.tickers == 1, "ticker started on target")

-- dead zone via the 35 yd item
Stub.rangeAnswers[75] = false
Stub.rangeAnswers[2974] = true
Stub.cachedItems[18904] = true
Stub.itemInRange[18904] = true
Stub.tick()
check(f.rangeText:GetText() == "DEAD ZONE", "dead zone label, got " .. tostring(f.rangeText:GetText()))
check(same(f.light.color, 1, 0.25, 0.25), "dead zone light is red")
check(f.melee:IsShown(), "melee dot shown when Wing Clip is in range")

-- out of range via the item
Stub.itemInRange[18904] = false
Stub.rangeAnswers[2974] = false
Stub.tick()
check(f.rangeText:GetText() == "OUT OF RANGE", "out of range label")
check(same(f.light.color, 0.5, 0.5, 0.5), "out of range light is grey")

-- item not cached: interact fallback
Stub.cachedItems[18904] = nil
Stub.interact[3] = true
Stub.tick()
check(f.rangeText:GetText() == "DEAD ZONE", "dead zone via interact fallback")
Stub.interact[3] = false
Stub.tick()
check(f.rangeText:GetText() == "OUT OF RANGE", "out of range via interact fallback")

-- secret answers in combat degrade to no signal, never an error
Stub.combat = true
Stub.secretRange = true
local ok, err = pcall(Stub.tick)
check(ok, "secret range answers do not raise: " .. tostring(err))
check(f.rangeText:GetText() == "", "secret answers show no label")
Stub.secretRange = false
Stub.combat = false

-- dead target stops the ticker
_G.UnitIsDead = function() return true end
Stub.tick()
check(f.rangeText:GetText() == "" and #Stub.tickers == 1 and Stub.tickers[1].cancelled, "dead target clears the label and cancels the ticker")
_G.UnitIsDead = function() return false end
Stub.fire("PLAYER_TARGET_CHANGED")
check(#Stub.tickers == 2 and not Stub.tickers[2].cancelled, "new target restarts the ticker")

-- ammo thresholds
Stub.ammo.count = 180
Stub.fire("BAG_UPDATE_DELAYED")
check(f.ammoText:GetText() == "180" and same(f.ammoText.color, 1, 0.85, 0.2), "ammo under warn is yellow")
check(printedCount("ammo low") == 0, "warn level does not nag")
Stub.ammo.count = 30
Stub.fire("BAG_UPDATE_DELAYED")
check(same(f.ammoText.color, 1, 0.3, 0.3), "ammo under crit is red")
check(f.flash.plays == 1, "flash played once on crossing into critical")
check(printedCount("ammo low: 30") == 1, "critical crossing printed once")
Stub.ammo.count = 29
Stub.fire("BAG_UPDATE_DELAYED")
check(printedCount("ammo low") == 1, "staying critical does not print again")
Stub.runTimers()
check(not f.flash:IsPlaying(), "flash stopped by its timer")
Stub.ammo.count = 0
Stub.fire("BAG_UPDATE_DELAYED")
check(f.ammoText:GetText() == "NO AMMO" and printedCount("out of ammo") == 1, "empty shows NO AMMO and says so once")
Stub.ammo.count = 300
Stub.fire("BAG_UPDATE_DELAYED")
check(f.ammoText:GetText() == "300" and same(f.ammoText.color, 0.92, 0.92, 0.92), "restocked back to plain")

-- thrown weapon: no ammo needed
Stub.equipped[18] = 2946
Stub.fire("PLAYER_EQUIPMENT_CHANGED", 18, true)
check(f.ammoText:GetText() == "--", "thrown weapon shows no ammo count")
Stub.equipped[18] = 2508
Stub.fire("PLAYER_EQUIPMENT_CHANGED", 18, true)
check(f.ammoText:GetText() == "300", "gun needs ammo again")
Stub.equipped[18] = 2504

-- slash commands
for _, cmd in ipairs({ "", "status", "unlock", "lock", "reset", "scale 1.4", "scale 9", "warn 300", "crit 75", "crit x", "debug on", "debug off", "off", "on", "bogus" }) do
	local okc, e = pcall(ns.handleSlash, cmd)
	check(okc, "/hh " .. cmd .. " raised: " .. tostring(e))
end
check(HunterHUDDB.scale == 1.4 and HunterHUDDB.warn == 300 and HunterHUDDB.crit == 75, "settings stored")
check(f:IsShown(), "frame shown again after /hh on")
ns.handleSlash("off")
check(not f:IsShown() and Stub.tickers[#Stub.tickers].cancelled, "/hh off hides and stops the ticker")
ns.handleSlash("on")

-- drag saves the position only when unlocked
ns.handleSlash("unlock")
f.scripts.OnDragStart(f)
check(f.moving == true, "drag starts when unlocked")
f.scripts.OnDragStop(f)
check(HunterHUDDB.pos and HunterHUDDB.pos[1] == "TOPLEFT" and HunterHUDDB.pos[2] == 40, "position saved after drag")
ns.handleSlash("lock")
f.moving = false
f.scripts.OnDragStart(f)
check(f.moving == false, "drag ignored when locked")

------------------------------------------------------------------
-- second session: saved settings come back
------------------------------------------------------------------
local saved = HunterHUDDB
ns = startSession(saved)
f = _G.HunterHUDFrame
check(f.scale == 1.4, "saved scale applied on load")
check(f.points[1] and f.points[1][1] == "TOPLEFT" and f.points[1][4] == 40, "saved position applied on load")

------------------------------------------------------------------
-- not a hunter
------------------------------------------------------------------
ns = startSession(nil, "WARRIOR")
f = _G.HunterHUDFrame
check(not f:IsShown(), "frame hidden for a warrior")
Stub.units.target = true
Stub.fire("PLAYER_TARGET_CHANGED")
check(#Stub.tickers == 0, "no ticker for a warrior")
local okw, ew = pcall(ns.handleSlash, "status")
check(okw, "/hh works for a warrior: " .. tostring(ew))

io.write(string.format("%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
