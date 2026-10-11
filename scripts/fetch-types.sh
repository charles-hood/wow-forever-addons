#!/usr/bin/env bash
# Download the generated client API dump and Lua LSP definitions from
# https://github.com/Atraeau/WoW-Addons into types/ (gitignored), then
# regenerate .luacheckrc from the dump so the linter knows this client's globals.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p types
base="https://raw.githubusercontent.com/Atraeau/WoW-Addons/main"
curl -sfL "$base/types/WowForeverAPI.lua" -o types/WowForeverAPI.lua
curl -sfL "$base/docs/api.json" -o types/api.json
echo "fetched types/WowForeverAPI.lua ($(du -h types/WowForeverAPI.lua | cut -f1)) and types/api.json"
python3 -I scripts/gen-luacheckrc.py types/api.json .luacheckrc
