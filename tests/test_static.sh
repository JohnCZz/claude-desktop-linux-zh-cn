#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/claude_linux_zh_unified.sh"

[[ -f "$SCRIPT" ]]
bash -n "$SCRIPT"

help_output="$(bash "$SCRIPT" --help)"
grep -Fq -- '--apply' <<<"$help_output"
grep -Fq -- '--rollback' <<<"$help_output"
grep -Fq -- '--offline' <<<"$help_output"

printf 'static checks passed: %s\n' "$SCRIPT"
