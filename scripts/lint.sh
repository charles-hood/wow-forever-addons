#!/usr/bin/env bash
# Syntax-check every addon file with luac and lint with luacheck (if installed).
set -uo pipefail
cd "$(dirname "$0")/.."
status=0
for f in addons/*/*.lua; do
	if ! luac -p "$f"; then status=1; fi
done
echo "luac: $( [ $status -eq 0 ] && echo ok || echo FAILED )"
if command -v luacheck >/dev/null; then
	luacheck addons || status=1
else
	echo "luacheck not installed (brew install luacheck); skipped"
fi
exit $status
