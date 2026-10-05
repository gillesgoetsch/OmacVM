#!/bin/bash
# Put omacvm.monitor where Omarchy's display widget sits (it takes over its
# slot, clonedFrom). Idempotent: does nothing once the widget is on the bar.
set -euo pipefail
id=omacvm.monitor
config=${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json
in_bar() {
  [[ -f $config ]] && jq -e --arg id "$1" '[.bar.layout[]?[]?.id] | index($id) != null' "$config" >/dev/null
}
in_bar "$id" && exit 0
omarchy-shell -q shell rescanPlugins
if in_bar omarchy.monitor; then
  omarchy plugin enable "$id"
elif in_bar omarchy.power; then
  omarchy plugin enable "$id" --before omarchy.power
else
  omarchy plugin enable "$id" --section right
fi
