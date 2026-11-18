#!/usr/bin/env bash
# Loads the panel in a throwaway Quickshell with a fake service.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
command -v quickshell >/dev/null || { echo "Quickshell is required." >&2; exit 1; }
case_root=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-voxtype-panel.XXXXXX")
trap 'rm -rf -- "$case_root"' EXIT
cp -- "$repo_root/tests/qml/PanelSmoke.qml" "$case_root/shell.qml"
mkdir -p "$case_root/Plugin"
cp -- "$repo_root"/*.qml "$repo_root"/*.js "$case_root/Plugin/"
ln -s /usr/share/omarchy/shell/Commons "$case_root/Commons"
ln -s /usr/share/omarchy/shell/Ui "$case_root/Ui"
set +e
output=$(timeout 15s quickshell --no-color --path "$case_root/shell.qml" 2>&1)
status=$?
set -e
if (( status != 0 )) || [[ $output != *PANEL_SMOKE_OK* ]] || grep -E "Plugin/" <<<"$output" | grep -qE "(Error|is not defined|Cannot assign|Unable to assign|unavailable)"; then
  printf '%s\n' "$output" >&2
  exit 1
fi
echo "panel smoke: ok"
