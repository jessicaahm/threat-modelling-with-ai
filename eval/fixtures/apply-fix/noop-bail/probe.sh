#!/usr/bin/env bash
# The tree is already safe; this probe simply confirms it stayed safe.
set -u
f="script/clean.sh"
[ -f "$f" ] || exit 1
grep -q 'rm -f "\$TARGET"' "$f"
