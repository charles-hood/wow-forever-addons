# wow-forever-addons

Addons for the World of Warcraft: Forever beta, developed on this Mac against the
client at `/Applications/World of Warcraft/_classic_beta_`.

The first two addons are probes. They exist to answer, from the live client, the
questions every later addon depends on: whether SavedVariables come back from
disk, which API calls and events exist on the current build, what becomes a
secret value in combat, and what the planned hunter addon can read about range,
ammo and auras. Everything they measure is written into SavedVariables so it can
be read from disk after a session with `scripts/read-probe.py`.

The first real addon built on those answers is **HunterHUD**: a dead-zone and
range light plus an ammo counter.

## Layout

```
addons/ForeverProbe/     platform probe: SavedVariables lifecycle, build facts, API and
                         event presence, secret-value snapshots, Lua error capture,
                         event watch, ring-buffer log shared by other probes   /fp
addons/HunterProbe/      range and dead zone, ammo slot and bags, auras, swing events   /hp
addons/HunterHUD/        hunter HUD: range light, dead zone, melee dot, ammo counter      /hh
scripts/deploy.sh        symlink (or --copy) the addons into the client
scripts/seed-probe.sh    pre-seed ForeverProbe's SavedVariables files for the cold-start test
scripts/read-probe.py    parse the SavedVariables file and print the report and log
scripts/fetch-types.sh   download the client API dump and LSP types, regenerate .luacheckrc
scripts/lint.sh          luac syntax check plus luacheck
tests/                   offline tests: a WoW API stub drives both addons end to end
types/                   (gitignored) fetched API dump and Lua LSP definitions
```

## Quick start

```bash
scripts/fetch-types.sh        # once: API dump, LSP types, .luacheckrc
tests/run.sh                  # lint + offline tests + reader check
scripts/deploy.sh             # symlink addons into the client
scripts/seed-probe.sh         # with the game closed: seed the SavedVariables files
```

Then launch the beta, enable **ForeverProbe** and **HunterProbe** on the
character-select AddOns screen, and log in. ForeverProbe prints the
SavedVariables verdict in chat on login. Play a little (target something, fight
something, open bags), then log out fully. Read what happened:

```bash
python3 -I scripts/read-probe.py            # summary and the last 40 log lines
python3 -I scripts/read-probe.py -n 300 --src HP
python3 -I scripts/read-probe.py --json > session.json
```

## HunterHUD

A 170 by 36 pixel frame, hidden on non-hunters. On the left a light: green with
IN RANGE, red with DEAD ZONE, grey with OUT OF RANGE, dark with no live hostile
target. A small white dot beside it means Wing Clip is in range. On the right the
ammo count: plain, yellow at or under the warn threshold, red and flashing once
at or under the critical threshold, NO AMMO when empty, and two dashes when the
ranged weapon needs none.

How it decides: Auto Shot's range check answers true only between the dead zone
and 35 yards. When it answers false, a 35-yard item range check (Zorbin's
Ultra-Shrinker) separates "too close" from "too far". Both stay readable in
combat on this client. The frame polls twice a second only while a live hostile
is targeted.

`/hh` prints the commands: `on|off`, `lock|unlock` (drag when unlocked), `reset`,
`scale 0.5..2`, `warn N`, `crit N`, `debug on|off`, `status`.

## In-game commands

`/fp` (ForeverProbe): `status`, `sv`, `build`, `api`, `events`, `secrets`,
`errors [list|clear|on|off]`, `watch EVENT`, `unwatch EVENT|all`, `log [n]`,
`verbose 0..3`, `scripterrors on|off`, `json`, `clear`, `reset`.

`/hp` (HunterProbe): `range`, `range on|off`, `ammo`, `auras`, `swing on|off`, `status`.

The log keeps everything regardless of chat verbosity. `/reload` writes the
SavedVariables file without logging out, so the reader can be run mid-session.

## Dev loop

Edit a `.lua` file, `/reload` in game. New files or TOC changes need a full
client restart. `tests/run.sh` before deploying catches syntax errors, unknown
globals against the real client API, and logic regressions without launching
the game.

## License

MIT. See LICENSE.

## Sources

- https://github.com/Thunderz96/forever-addon-kit for the measured client findings
- https://github.com/Atraeau/WoW-Addons for the API dump and LSP types
- https://github.com/tobarisu1/wow_forever_addons for working small addons and the Mac install approach
- https://github.com/WeakAuras/LibRangeCheck-3.0 for the range-check item IDs
