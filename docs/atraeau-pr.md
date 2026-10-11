Branch: mac-deploy-and-luacheck-globals (local clone of Atraeau/WoW-Addons, not pushed)
Target: Atraeau/WoW-Addons main

Title: macOS/Linux deploy script and client-accurate luacheck globals

Two small additions that keep the same config file and conventions as the
existing scripts.

**`scripts/deploy.sh`** is the macOS/Linux counterpart of `deploy.ps1`: same
`wow-dev.config.json` plus `wow-dev.config.local.json` override, same modes
(`--name X`, `--copy`, `--clean`), symlinks in place of junctions, and the same
"remove any existing deployment first, never the target" behaviour. On a Mac the
only override needed is `{ "gamePath": "/Applications/World of Warcraft" }`.
Tested against a live Forever client on macOS: link, clean, and a bad name.

**`scripts/generate-luacheck-globals.ps1`** writes `types/luacheck-globals.lua`
from `docs/api.json`: every global function, `C_*` namespace and `Enum`, as a
Lua file returning a list. `.luacheckrc` merges that into `read_globals` at the
end, so the curated list you already keep stays readable while the lint knows
the whole client. The regenerate workflow runs it alongside the other two
generators so it stays in step with `api.json`.

Effect on `luacheck src`: warnings go from 473 to 453. What remains as
"accessing undefined variable" is now real signal rather than list gaps:
functions this client removed (`GetContainerItemInfo`, `getglobal`,
`PickupContainerItem`), FrameXML constants the dump does not carry
(`NUM_BAG_SLOTS`), and the addons' own undeclared globals
(`g_BagSorterSettings`, `SuicideKingsList`, `HelloForeverDB`). That is the
distinction a port needs: "not in the hand list" versus "gone from the client".

The generated file is 6,300 lines, the same trade-off as the committed
`types/WowForeverAPI.lua`. If you would rather not track it, the merge block
in `.luacheckrc` is a no-op when the file is absent, so it can stay local.

Measured on build 70338 along the way, in case it is useful for the docs:
`WOW_PROJECT_ID` is 18 on the current client, neither MAINLINE nor CLASSIC,
so the project-id checks in `vendor/forever-compat-patches.md` now miss in
both directions; `issecretvalue ~= nil` still works as the engine test.
Details and the probe that measured it: https://github.com/charles-hood/wow-forever-addons
