#!/usr/bin/env bash
# Parse the tool pins from mise.toml and compose the warm CI image tag.
#
# Single source of truth shared by:
#   - .github/workflows/ci-image.yml (builds/pushes the image)
#   - .github/workflows/release.yml  (pulls/consumes the image)
#
# Drift between what ci-image bakes and what release consumes cannot happen
# because both derive the tag from mise.toml through this same script.
#
# Standalone-friendly: prints `KEY=VALUE` lines to stdout (so you can
# `eval "$(bash scripts/ci/derive-image.sh)"` locally, e.g. with mise pins).
# When run inside GitHub Actions ($GITHUB_ENV is set), the same lines are
# appended to $GITHUB_ENV so later steps see them as env vars.
#
# Exits nonzero (with a clear message) if mise.toml is missing or unparseable.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mise_file="$repo_root/mise.toml"

[ -f "$mise_file" ] || {
  echo "error: mise.toml not found at $mise_file" >&2
  exit 1
}

rust_pin="$(awk -F'"' '/^\[tools\]/{t=1;next} t&&/rust[ =]/{print $2; exit}' "$mise_file")"
zig_pin="$(awk -F'"' '/^\[tools\]/{t=1;next} t&&/zig[ =]/{print $2; exit}' "$mise_file")"

[ -n "$rust_pin" ] || {
  echo "error: could not parse rust pin from $mise_file" >&2
  exit 1
}
[ -n "$zig_pin" ] || {
  echo "error: could not parse zig pin from $mise_file" >&2
  exit 1
}

owner_lc="$(echo "${REPO_OWNER:-d0whc3r}" | tr '[:upper:]' '[:lower:]')"
image_name="ghcr.io/${owner_lc}/devcroft-ci:rust${rust_pin}-zig${zig_pin}"

lines=(
  "RUST_PIN=$rust_pin"
  "ZIG_PIN=$zig_pin"
  "OWNER_LC=$owner_lc"
  "CI_IMAGE=$image_name"
)

if [ -n "${GITHUB_ENV:-}" ]; then
  printf '%s\n' "${lines[@]}" >> "$GITHUB_ENV"
fi

printf '%s\n' "${lines[@]}"
