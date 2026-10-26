#!/usr/bin/env bash
# OmacVM's edits of Omarchy's shell on omarchy-mac's files and on upstream's
# from October 2026 (omarchy-shell/README.md), offline: the toasts under
# Omanotch's strip (guest/omanotch-notifications.sh), Omanotch's display
# panel (NOTCH left out), OmacVM.app's display panel and the Bridge's night
# light indicator. The bar and background patches have their own tests
# (omanotch/guest/tests, notch-wallpaper.sh); shell-colors.sh the colours.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
O=$R/src/tests/omarchy-shell
T=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-shell.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
t() {  # want got name
  if [[ $2 == "$1" ]]; then echo "ok   $3"; else echo "FAIL $3: want '$1', got '$2'"; fail=1; fi
}
MAC=omarchy-mac-ba546a61
UP=omarchy-a06ec133
UP45=omarchy-03ff1eff   # Omarchy 4.5.0-rc1 (branch omarchy-45 only)

# --- Toasts under the strip: omarchy-mac's service is patched, upstream's asks the bar ---
N=$R/src/guest/omanotch-notifications.sh
for v in $MAC $UP; do cp "$O/$v/shell/plugins/notifications/Service.qml" "$T/$v-Service.qml"; done
t "changed" "$(bash "$N" on "$T/$MAC-Service.qml")" "$MAC: the notification service gets the parked bar's gap"
t "" "$(bash "$N" on "$T/$MAC-Service.qml")" "  again: nothing"
t "changed" "$(bash "$N" off "$T/$MAC-Service.qml")" "  off: back"
t "" "$(diff "$O/$MAC/shell/plugins/notifications/Service.qml" "$T/$MAC-Service.qml")" "  as Omarchy shipped it"
out=$(bash "$N" on "$T/$UP-Service.qml" 2>&1); rc=$?
t "0 " "$rc $out" "$UP: nothing to patch, no error (the bar's barSizeFor answers)"
t "" "$(diff "$O/$UP/shell/plugins/notifications/Service.qml" "$T/$UP-Service.qml")" "  the service as Omarchy shipped it"
cp "$O/$UP45/shell/plugins/notifications/Service.qml" "$T/$UP45-Service.qml"
out=$(bash "$N" on "$T/$UP45-Service.qml" 2>&1); rc=$?
t "0 " "$rc $out" "$UP45: nothing to patch, no error (Delivery.barThickness asks the bar)"
t "" "$(diff "$O/$UP45/shell/plugins/notifications/Service.qml" "$T/$UP45-Service.qml")" "  the service as Omarchy shipped it"
sed 's/service.barClearanceFor(/service.someOtherClearance(/' "$O/$UP/shell/plugins/notifications/Service.qml" > "$T/x-Service.qml"
out=$(bash "$N" on "$T/x-Service.qml" 2>&1); rc=$?
t "1" "$rc" "a service in neither form: says so (exit 1)"

# --- Omanotch's display panel and OmacVM.app's: on both panels ---
for v in $MAC $UP $UP45; do
  r=$(OMARCHY_PATH="$O/$v" XDG_CONFIG_HOME="$T/$v-config" python3 - "$R/src/omanotch/guest/monitor/display-panel.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dp", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
text = (m.source_dir() / "Panel.qml").read_text()
try:
    out = m.patch(text)
    print("ok" if m.VERSION_LINE in out and m.patch(out) == out else "no")
except ValueError as e:
    print("no fit: %s" % e)
PY
)
  t "ok" "$r" "$v: Omanotch's display panel leaves NOTCH out"
  rm -rf "$T/mon"
  python3 "$R/src/app/guest/monitor-widget/build.py" "$T/mon" "$O/$v/shell/plugins/panels/monitor" 2>/dev/null
  t "0" "$?" "$v: OmacVM.app's display panel builds"
  t "1 fill: Style.hoverFillFor(root.bar.foreground, Commons.Color.accent)" \
    "$(grep -c '^import qs.Commons as Commons$' "$T/mon/Panel.qml") $(awk '/id: macExternalRow/ {on = 1} on && /fill:/ {sub(/^ */, ""); print; exit}' "$T/mon/Panel.qml")" \
    "  its own row's colour is Commons.Color (Qt 6.12)"
  t "1 1" "$(grep -c 'id: macExtraRow' "$T/mon/Panel.qml") $(grep -c '^ *ToggleSwitch {$' "$T/mon/Panel.qml")" \
    "  the Extra brightness row with Omarchy's own switch (shell/Ui here)"
done

# --- The Bridge's night light: Omarchy's indicators less NightLight ---
I=$R/src/bridge/guest/nightlight-indicator.sh
items() { jq -c '[.bar.layout[]?[]? | select(.id == "omarchy.indicators") | .items] | first' "$1"; }
layout() {  # the indicators widget with these items ("" = none of its own)
  if [[ -n $1 ]]; then jq -n --argjson i "$1" '{bar: {layout: {left: [], center: [{id: "omarchy.indicators", items: $i}], right: []}}}'
  else jq -n '{bar: {layout: {left: [], center: [{id: "omarchy.indicators"}], right: []}}}'; fi
}
want_mac='["Dictation","ScreenRecording","Reminder","Dnd","StayAwake"]'
want_up='["PasswordlessSudo","ScreenRecording","RemoteSession","Reminder","Dnd","StayAwake"]'
for v in $MAC $UP $UP45; do
  [[ $v == "$MAC" ]] && want=$want_mac || want=$want_up
  layout "" > "$T/$v.json"; rm -f "$T/$v.mark"
  t "changed" "$(bash "$I" "$T/$v.json" "$T/$v.mark" "$O/$v/shell/plugins/bar/widgets/Indicators.qml")" "$v: no items of its own: Omarchy's default less NightLight"
  t "$want" "$(items "$T/$v.json")" "  the default of this Omarchy"
  t "null" "$(cat "$T/$v.mark")" "  the marker says: Omarchy's default"
  t "" "$(bash "$I" "$T/$v.json" "$T/$v.mark" "$O/$v/shell/plugins/bar/widgets/Indicators.qml")" "  again: nothing"
done
# What OmacVM up to 3.1.2 wrote, then Omarchy's newer shell: its default now.
layout "$want_mac" > "$T/old.json"; echo null > "$T/old.mark"
bash "$I" "$T/old.json" "$T/old.mark" "$O/$UP/shell/plugins/bar/widgets/Indicators.qml" >/dev/null
t "$want_up" "$(items "$T/old.json")" "older OmacVM's list on upstream's shell: upstream's default less NightLight"
# And back (or a later default): the list it wrote last follows Omarchy's default.
bash "$I" "$T/old.json" "$T/old.mark" "$O/$MAC/shell/plugins/bar/widgets/Indicators.qml" >/dev/null
t "$want_mac" "$(items "$T/old.json")" "  then omarchy-mac's shell again: its default again (the list it wrote follows)"
# The user's own items: theirs less NightLight, kept for off.
layout '["Dnd","NightLight"]' > "$T/own.json"; rm -f "$T/own.mark"
bash "$I" "$T/own.json" "$T/own.mark" "$O/$UP/shell/plugins/bar/widgets/Indicators.qml" >/dev/null
t '["Dnd"] ["Dnd","NightLight"]' "$(items "$T/own.json") $(cat "$T/own.mark")" "the user's own items: less NightLight, the marker keeps them"
layout '["Dnd"]' > "$T/own2.json"; echo null > "$T/own2.mark"
bash "$I" "$T/own2.json" "$T/own2.mark" "$O/$UP/shell/plugins/bar/widgets/Indicators.qml" >/dev/null
t '["Dnd"]' "$(items "$T/own2.json")" "items changed by the user since: kept"
# No widget file (or no list in it): omarchy-mac's list.
layout "" > "$T/none.json"; rm -f "$T/none.mark"
bash "$I" "$T/none.json" "$T/none.mark" "$T/missing.qml" >/dev/null
t "$want_mac" "$(items "$T/none.json")" "no Indicators.qml: the older default less NightLight"
# No shell.json, or no indicators widget: nothing.
t "0 " "$(bash "$I" "$T/nothing.json" "$T/nothing.mark"; echo "$? $(ls "$T/nothing.mark" 2>/dev/null)")" "no shell.json: nothing"
jq -n '{bar: {layout: {left: [{id: "omarchy.clock"}]}}}' > "$T/noind.json"
t "0 " "$(bash "$I" "$T/noind.json" "$T/noind.mark"; echo "$? $(ls "$T/noind.mark" 2>/dev/null)")" "no indicators widget: nothing"

echo "omarchy-shell: $([[ $fail == 0 ]] && echo all ok || echo FAILED)"
exit $fail
