#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

TARGET="${1:?usage: clean.sh <path>}"
rm -f "$TARGET"
