#!/usr/bin/env bash
set -euo pipefail

source_dir=/tmp/flash.tmux-history
output_dir=tests/fixtures/snapshots
min_visible=256
declare -A forced

usage() {
  printf 'usage: %s [options]\n' "$0"
  printf '  --source DIR          snapshot source (default: %s)\n' "$source_dir"
  printf '  --output DIR          repository output (default: %s)\n' "$output_dir"
  printf '  --keep FILE           force a snapshot to be kept\n'
  printf '  --min-visible N       minimum non-whitespace bytes (default: %s)\n' "$min_visible"
  printf '  --dry-run             report decisions without copying\n'
}

dry_run=false
while (($# > 0)); do
  case $1 in
    --source)
      source_dir=${2:?missing argument for --source}
      shift 2
      ;;
    --output)
      output_dir=${2:?missing argument for --output}
      shift 2
      ;;
    --keep)
      forced[${2##*/}]=1
      shift 2
      ;;
    --min-visible)
      min_visible=${2:?missing argument for --min-visible}
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d $source_dir ]] || {
  printf 'snapshot source does not exist: %s\n' "$source_dir" >&2
  exit 1
}

shopt -s nullglob
files=("$source_dir"/*.txt)
((${#files[@]} > 0)) || {
  printf 'no snapshots found in %s\n' "$source_dir" >&2
  exit 1
}

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

manifest=''
if [[ $dry_run == false ]]; then
  mkdir -p "$output_dir"
  manifest="$output_dir/manifest.tsv"
  [[ ! -e $manifest ]] || {
    printf 'output already contains %s; remove it or choose another output directory\n' "$manifest" >&2
    exit 1
  }
  printf 'decision\tfixture\tfile\treason\trows\tbytes\tvisible\thash\n' > "$manifest"
fi

strip_ansi() {
  perl -pe 's/\e\][^\a]*(?:\a|\e\\)//g; s/\e\[[0-?]*[ -\/]*[@-~]//g; s/\e\([0-2A-Z]//g' "$1"
}

declare -A seen_hash
selected=0
excluded=0
duplicates=0

printf 'decision\tfixture\tfile\treason\trows\tbytes\tvisible\thash\n'

mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -r)
for source in "${files[@]}"; do
  name=${source##*/}
  hash=$(sha256sum "$source" | cut -d' ' -f1)
  raw_bytes=$(wc -c < "$source")
  rows=$(wc -l < "$source")
  plain="$tmp_dir/$name"
  strip_ansi "$source" > "$plain"
  visible=$(tr -d '[:space:]' < "$plain" | wc -c)
  reason=''

  if [[ ${forced[$name]+yes} ]]; then
    decision=keep
    reason=forced
  elif rg -q 'FLASH-(NOISE|MARKER)-[0-9]+' "$source"; then
    decision=exclude
    reason=generated-sandbox-output
  elif rg -q 'flash\.tmux (jump target|match start|snapshot=/tmp/)' "$source"; then
    decision=exclude
    reason=debug-transcript
  elif ((visible < min_visible)); then
    decision=exclude
    reason=too-small
  elif [[ ${seen_hash[$hash]+yes} ]]; then
    decision=duplicate
    reason="same-as-${seen_hash[$hash]}"
  else
    decision=keep
    reason=distinct
  fi

  if [[ $decision == keep ]]; then
    if [[ ${seen_hash[$hash]+yes} ]]; then
      decision=duplicate
      reason="same-as-${seen_hash[$hash]}"
    else
      seen_hash[$hash]=$name
      ((selected += 1))
    fi
  fi
  case $decision in
    exclude) ((excluded += 1)) ;;
    duplicate) ((duplicates += 1)) ;;
  esac

  destination_name='-'
  if [[ $decision == keep ]]; then
    destination_name="bench-$(printf '%03d' "$selected").txt"
  fi
  report_line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$decision" "$destination_name" "$name" "$reason" "$rows" "$raw_bytes" "$visible" "$hash")
  printf '%s\n' "$report_line"
  if [[ $dry_run == false ]]; then
    printf '%s\n' "$report_line" >> "$manifest"
  fi

  if [[ $decision == keep && $dry_run == false ]]; then
    destination="$output_dir/$destination_name"
    cp -- "$source" "$destination"
  fi
done

if [[ $dry_run == false ]]; then
  mkdir -p "$output_dir"
  printf 'selected=%s\texcluded=%s\tduplicates=%s\n' "$selected" "$excluded" "$duplicates" > "$output_dir/manifest.summary"
fi
