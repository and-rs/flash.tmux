#!/usr/bin/env bash
set -euo pipefail

json=${1:?usage: oneline-json.sh JSON}
printf '%s\n' "$json" | tr -d '\n'
