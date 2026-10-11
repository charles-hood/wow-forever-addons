# wow-forever-addons

Addons for the WoW: Forever beta. Client on this Mac:
`/Applications/World of Warcraft/_classic_beta_` (AddOns under `Interface/AddOns`,
saves under `WTF/Account/<account>/`). Launch through Battle.net. The scripts find
the account folder on their own when there is exactly one; set `WOW_ACCOUNT` otherwise.

## Client facts (from the three reference repos, see README; verify with ForeverProbe)

- Interface `16001`, build line 1.60.x. The engine is Retail 12.x (Midnight). Write
  against Mainline APIs: `C_Spell`, `C_Item`, `C_Container`, `C_UnitAuras`. The old
  globals (`GetItemInfo`, `GetSpellInfo`, `UnitAura`, `UnitBuff`, `GetItemCount`,
  `GetContainerItemInfo`) are gone. Lua is 5.1.
- Secret values: in combat, unit health, threat and auras are unreadable; damage
  amounts (`UNIT_COMBAT`), range checks and `PLAYER_SWING` stay plain. Never
  boolean-test, compare, or `tostring` a value that might be secret. Check
  `issecretvalue(v)` first, or ask `C_Secrets.Should*BeSecret` before reading.
- `RegisterEvent` on an unknown event throws and aborts the whole file. Use
  `ForeverProbe.safeRegister` or `pcall`.
- `ReloadUI()` is protected. The client stops reporting Lua errors after 100 in a
  session. Do not key "modern engine" off `WOW_PROJECT_ID` (two repos disagree).
- SavedVariables: the kit measured on 2026-09-24 that they were never read back;
  tobarisu reports on 2026-10-06 that they persist. ForeverProbe's login verdict is
  the authority for the current build.

## Measured on this Mac (ForeverProbe, sessions 1 to 3, 2026-10-10, build 70338)

- **Dead zone, measured.** Walking a live boar from melee to range and back: Auto
  Shot (75) answers false inside the dead zone and beyond 35 yd, true between. The
  35 yd item (Zorbin's Ultra-Shrinker, 18904) answers true in both the dead zone and
  the ranged band, false beyond, so "Auto Shot false and 35 yd true" is the dead
  zone, "Auto Shot false and 35 yd false" is out of range. Interact 3 (9.9 yd)
  disagreed with Auto Shot for one sample near 10 yd, so it is only a fallback.
  Wing Clip (2974, 5 yd) answers true in melee and flickers as the mob moves.
  Item range checks answer within the first sample after RequestLoadItemDataByID.
- **The popup was the combat log, confirmed directly.** `/fp events full` in
  session 4 logged ADDON_ACTION_FORBIDDEN once "during RegisterEvent
  COMBAT_LOG_EVENT_UNFILTERED" and once "during UnregisterEvent
  COMBAT_LOG_EVENT_UNFILTERED", nothing else. Never register that event.
- **BuffReminder verified in game (2026-10-10, build 70338).** Dropping the Aspect
  made the icon appear; recasting it made it go away. Hunter's Mark target read
  and the other classes' checks are still offline-only.
- **HunterHUD validated in game (sessions 4 and 5).** With `/hh debug on`, every
  light change (RANGED, DEAD, OUT, NONE on the kill) matched HunterProbe's
  sampler within 0.1 s across three fights, zero Lua errors. Addon icons use
  `## IconTexture` in the TOC, which this engine honours.
- `PLAYER_SWING` carries swingType 2 for Auto Shot (2.091 s on the test hunter) and 0 for
  main-hand swings (2.4 s). `PLAYER_SWING_RANGE_UPDATE` fires once per type at login
  with checksRange false and never again; swing range is closed to addons.
- `GetInventoryItemCount("player", 0)` equals the projectile total in bags (no
  quiver equipped); it drops by the number of shots between BAG_UPDATE_DELAYED events.

- **SavedVariables load on a cold start.** Session 2 came up with session 1's
  counter and logout time, account-wide and per-character. The kit's September bug
  is fixed on this build; design persistence normally.
- **Creature health, max health and power are secret always**, in and out of combat
  (a dead boar's values stayed secret after the fight). Player and pet health and
  power are secret too, even out of combat; only max health and max power are plain.
- **Auras**: readable out of combat; in combat `C_UnitAuras.GetAuraDataByIndex`
  throws "Auras cannot be accessed when secret while tainted by 'ForeverProbe'".
  `C_Secrets.ShouldAurasBeSecret()` flips with combat and is the gate to use.
- **Range checks stay plain in combat.** `C_Spell.IsSpellInRange` for Auto Shot (75)
  answered true/false on a live hostile in combat; the interact distances and the
  LibRangeCheck items answered too. Raptor Strike (0-0 range) answers true at 20+
  yards; Wing Clip answered false there, so it is the melee-range candidate.
  All range calls answer nil on a dead or friendly target.
- `C_Item.IsItemInRange` answers nil until the item is cached; the first query
  triggers the load. HunterProbe now calls `C_Item.RequestLoadItemDataByID` at login.
- `PLAYER_SWING` fires for Auto Shot with swingType 2 and the ranged speed (2.091 s
  on the test hunter). `C_SwingTimer.IsTargetWithinSwingRange` returns nil for addons.
- Ammo: `GetInventoryItemCount("player", 0)` is the ammo stack and decrements one per
  shot; `BAG_UPDATE_DELAYED` fires for each.

- `WOW_PROJECT_ID` is 18: neither MAINLINE (1) nor CLASSIC (2). A new project id.
- `UnitHealth("player")` and `UnitPower("player")` were secret while out of combat at
  login; `UnitHealthMax("player")` was plain. Health is not "secret only in combat"
  on this build. The pet's health was secret too.
- All 14 removed globals the kit listed are missing here as well; 104 planned calls
  present; `UNIT_HEALTH_FREQUENT` and `LEARNED_SPELL_IN_TAB` do not exist.
- Two `ADDON_ACTION_FORBIDDEN` events fired during the automatic event test (the
  "blocked from an action only available to the Blizzard UI" popup). Suspected:
  registering `COMBAT_LOG_EVENT_UNFILTERED`. Now behind `/fp events full`, and the
  warning names the step in flight.
- `C_SwingTimer.EnableRangeCheck` takes `(swingType, enable)`.
- Character saves live under `WTF/Account/<acct>/70/<Name>-<Realm>/`, not under the
  realm's display name. `scripts/seed-probe.sh` enumerates every realm folder.
- Session 1 verdict was NOT LOADED only because no file existed yet; the seed was
  written after that logout. Session 2 settled it (see above).

## Workflow

- `tests/run.sh` before every deploy: luac, luacheck against the real client
  globals (`.luacheckrc` is generated from the API dump), the stub-driven tests in
  `tests/test_probe.lua`, and the Python reader on the generated file.
- `scripts/deploy.sh` symlinks `addons/*` into the client. Lua edits need `/reload`
  in game; new files or TOC edits need a client restart.
- I cannot run the game. Charles plays, logs out (or `/reload`), and I read
  `scripts/read-probe.py` output. Every measurement must land in `ForeverProbeDB`
  through `ForeverProbe.info/debug/...` so it is readable from disk.
- Addon style follows tobarisu: small, slash commands, no Ace3, no options panel,
  one `SavedVariables` table per addon, tabs for indentation.
- New addon: folder `addons/Name/` with `Name.toc` (`## Interface: 16001`), add it
  to the stub test if it has logic worth checking, run `tests/run.sh`, deploy.

## Prose

No em dashes anywhere, including comments, READMEs and commit messages.
