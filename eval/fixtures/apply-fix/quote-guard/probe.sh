#!/usr/bin/env bash
# Deterministic "is the vuln gone?" probe for the quote-guard archetype.
set -u
f="script/clean.sh"
[ -f "$f" ] || exit 1
grep -q 'rm -f "\$TARGET"' "$f"
