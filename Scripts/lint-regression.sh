#!/bin/sh
# Proves the lint gate: clean tree passes against the baseline, and a fresh
# violation (trailing comma, bad identifier) in a new file fails it.
set -u
cd "$(dirname "$0")/.."
run() { swiftlint lint --strict --quiet --baseline .swiftlint-baseline.json; }
run || { echo "FAIL: baseline does not cover current tree"; exit 1; }
probe=Sources/ForgeKit/IO/LintProbe.swift
trap 'rm -f "$probe"' EXIT
printf 'let xs = [\n    1,\n    2,\n]\nlet bad_Name = 1\n' > "$probe"
if run >/dev/null 2>&1; then echo "FAIL: new violation was not caught"; exit 1; fi
echo "ok: baseline passes, new violation fails"
