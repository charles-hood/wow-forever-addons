#!/usr/bin/env bash
# Offline test run: lint, then the stub-driven tests, then the Python reader on the generated file.
set -uo pipefail
cd "$(dirname "$0")/.."
status=0
scripts/lint.sh || status=1
lua tests/test_probe.lua || status=1
lua tests/test_hud.lua || status=1
if [ -f tests/out/ForeverProbe.lua ]; then
	python3 -I scripts/read-probe.py --file tests/out/ForeverProbe.lua -n 5 > tests/out/report.txt || status=1
	grep -q "LOADED: the seed" tests/out/report.txt && echo "read-probe.py: ok" || { echo "read-probe.py: verdict not found in report"; status=1; }
fi
exit $status
