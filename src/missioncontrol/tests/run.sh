#!/bin/bash
# Mission Control (feature mission-control), offline: OmacVM's copy of the
# plugin is the pinned commit byte for byte, and the VM step
# (guest/install.sh on|off|--repair|--status) against a made-up Omarchy
# shell, Hyprland and pacman in a scratch home. No VM, no network.
#   src/missioncontrol/tests/run.sh
set -uo pipefail
M=$(cd "$(dirname "$0")/.." && pwd)
R=$(cd "$M/.." && pwd)   # src/
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
yes_no() { if "$@"; then echo yes; else echo no; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# ---------- the copy is the pinned commit, byte for byte ----------
PLUG=$M/plugin/mac.missioncontrol
expect "PIN: the plugin's repository" "https://github.com/gillesgoetsch/omarchy-mac-mission-control.git" "$(sed -n 's/^repo //p' "$M/PIN")"
expect "PIN: a full commit" yes "$(yes_no grep -Eq '^commit [0-9a-f]{40}$' "$M/PIN")"
tag=$(sed -n 's/^tag //p' "$M/PIN")
expect "PIN: a tag line (a release, or - before one)" yes "$(yes_no grep -Eq '^(-|v?[0-9]+\.[0-9]+(\.[0-9]+)?)$' <<<"$tag")"
[[ $tag == - ]] && echo "note pinned to a commit that is no released tag yet: pin one before a release (sync.sh TAG)"
# release.sh's check refuses a PIN without a released tag (sync.sh --released).
for t in "v1.0.1 yes" "1.0.1 yes" "- no" "main no"; do
  printf 'repo x\ntag %s\ncommit %040d\n' "${t% *}" 0 > "$T/PIN"
  expect "release check: tag ${t% *}" "${t#* }" "$(yes_no eval '"$M/sync.sh" --released < "$T/PIN" >/dev/null 2>&1')"
done
expect "release check: a PIN without a tag line" no "$(yes_no eval 'printf "repo x\n" | "$M/sync.sh" --released >/dev/null 2>&1')"
[[ $tag == - ]] && expect "release check: this PIN (tag -) is refused" no "$(yes_no eval '"$M/sync.sh" --released < "$M/PIN" >/dev/null 2>&1')"
grep -q 'missioncontrol/sync.sh" --released' "$R/release/release.sh"; expect "release.sh's check step asks sync.sh --released" 0 "$?"
expect "the copy's files are the ones SHA256SUMS lists" \
  "$(awk '{ print $2 }' "$M/SHA256SUMS" | LC_ALL=C sort)" "$(cd "$PLUG" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
expect "every file has its pinned sha256" yes "$(yes_no eval '(cd "$PLUG" && sha -c "$M/SHA256SUMS") >/dev/null 2>&1')"
expect "manifest: the plugin's own id" mac.missioncontrol "$(jq -r .id "$PLUG/manifest.json")"
expect "manifest: an overlay kept loaded" "overlay true" "$(jq -r '"\(.kinds | join(",")) \(.keepLoaded)"' "$PLUG/manifest.json")"
printf 'Module {\n  Component {\n    name: "QQuickColor"\n    exports: ["QtQuick/Color 6.12"]\n    isSingleton: true\n  }\n}\n' > "$T/qt612.qmltypes"
expect "Qt 6.12: OmacVM's colour fix has nothing to change in it (it never edits the copy)" \
  "qtquick-color yes, patched 0, to patch 0, to restore 0" "$(python3 -I "$R/guest/shell-colors.py" --qmltypes "$T/qt612.qmltypes" --status "$PLUG")"
expect "OmacVM never removes a bind or gesture at run time (unbind, :remove()" "" \
  "$(grep -nE 'unbind|:remove\(' "$M/guest/install.sh" | grep -v '^[0-9]*:#' || true)"
# A changed byte is found.
cp -R "$PLUG" "$T/copy"; printf ' ' >> "$T/copy/Layout.js"
expect "a changed byte fails the check" no "$(yes_no eval '(cd "$T/copy" && sha -c "$M/SHA256SUMS") >/dev/null 2>&1')"
rm -rf "$T/copy"

# ---------- the VM step against stand-ins ----------
# State of the made-up session, one file each under $S: omarchy (version),
# shell (open|locked|down), hung, hypr (Hyprland runs), hooks, live, layer,
# hidden (count), planted (a 4-finger vertical gesture of the user's own),
# errors (config errors the user already had), stuck (a restart does not help).
S=$T/state B=$T/bin H=$T/home RUNDIR=$T/run LOG=$T/log
mkdir -p "$B"
cat > "$B/timeout" <<'EOF'
#!/bin/bash
shift; exec "$@"
EOF
cat > "$B/pacman" <<'EOF'
#!/bin/bash
[[ "$*" == "-Q omarchy" && -s $S/omarchy ]] && echo "omarchy $(cat "$S/omarchy")"
EOF
cat > "$B/pgrep" <<'EOF'
#!/bin/bash
[[ $(cat "$S/shell") != down ]] && echo 4242
EOF
cat > "$B/pkill" <<'EOF'
#!/bin/bash
echo "pkill $*" >> "$LOG"
EOF
cat > "$B/omarchy-hyprland-session-locked" <<'EOF'
#!/bin/bash
[[ -e $S/hyprlocked ]]
EOF
# The plugin as the shell runs it: enabled and in place, the shell up and
# answering -> its Hyprland half loads (hooks, live).
cat > "$B/fake-load" <<'EOF'
#!/bin/bash
C=$HOME/.config/omarchy/shell.json
if [[ $(cat "$S/shell") != down && ! -e $S/hung && -d $HOME/.config/omarchy/plugins/mac.missioncontrol ]] &&
   jq -e '.plugins[]? | select(.id == "mac.missioncontrol")' "$C" >/dev/null 2>&1; then
  : > "$S/hooks"; : > "$S/live"
else
  rm -f "$S/live"
fi
EOF
cat > "$B/omarchy" <<'EOF'
#!/bin/bash
echo "omarchy $*" >> "$LOG"
C=$HOME/.config/omarchy/shell.json
[[ -e $S/hung ]] && exit 124
[[ $(cat "$S/shell") == down ]] && exit 1
[[ -f $C ]] || echo '{}' > "$C"
# A shell that has not read a new plugin folder yet (its rescan runs in the background): "unknown".
if [[ "$1 $2" == "plugin enable" && -s $S/unknown ]]; then n=$(cat "$S/unknown"); echo $((n - 1)) > "$S/unknown"; (( n > 0 )) && exit 1; fi
case "$1 $2" in
  "plugin enable") jq --arg id "$3" '.plugins = ((.plugins // []) | map(select(.id != $id)) + [{id: $id}])' "$C" > "$C.n" && mv "$C.n" "$C" ;;
  "plugin disable") jq --arg id "$3" '.plugins = ((.plugins // []) | map(select(.id != $id)))' "$C" > "$C.n" && mv "$C.n" "$C" ;;
esac
fake-load
EOF
cat > "$B/omarchy-shell" <<'EOF'
#!/bin/bash
[[ -e $S/hung ]] && exit 124
sh=$(cat "$S/shell")
[[ $sh == down ]] && exit 1
case "$1 $2" in
  "shell ping") echo pong ;;
  "lock status") [[ $sh == locked ]] && echo '{"requested":true,"sessionLocked":true,"secure":true}' || echo '{"requested":false,"sessionLocked":false,"secure":false}' ;;
  "shell call") [[ -e $S/live ]] && echo "{\"phase\":\"$(cat "$S/phase" 2>/dev/null || echo closed)\",\"windows\":0}" || echo unknown ;;
esac
EOF
cat > "$B/omarchy-restart-shell" <<'EOF'
#!/bin/bash
echo "omarchy-restart-shell" >> "$LOG"
[[ -e $S/stuck ]] && exit 1
rm -f "$S/hung" "$S/layer"
fake-load
EOF
cat > "$B/hyprctl" <<'EOF'
#!/bin/bash
[[ -e $S/hypr ]] || exit 1
echo "hyprctl $*" >> "$LOG"
case $1 in
  monitors) echo '[]' ;;
  configerrors)
    cat "$S/errors" 2>/dev/null
    [[ -e $S/planted && -e $S/hooks ]] && echo "gesture: 4 fingers vertical is taken" ;;
  layers) [[ -e $S/layer ]] && echo '{"Virtual-1":{"levels":{"3":[{"namespace":"mac-mission-control"}]}}}' || echo '{}' ;;
  clients) n=$(cat "$S/hidden" 2>/dev/null || echo 0)
    jq -n --argjson n "$n" '[range($n) | {tags: ["mac-mission-control-hidden*"]}] + [{tags: []}]' ;;
  binds) [[ -e $S/hooks ]] && echo '[{"description":"Mission Control"}]' || echo '[]' ;;
  reload) rm -f "$S/hooks" "$S/live"; fake-load ;;
  eval)
    case $2 in
      *"mac_mission_control_hooks == nil"*) [[ -e $S/hooks ]] ;;
      *"mac_mission_control.live"*) [[ -e $S/live ]] ;;
      *"reset()"*) echo 0 > "$S/hidden"; echo reset >> "$LOG" ;;
      *sideways*) exit 1 ;;
    esac ;;
esac
EOF
# lib/install-plugin.sh as it behaves: the same copy writes nothing; a new
# one is staged under the lock, else copied (a running shell restarts once);
# enabled when the shell answers, queued otherwise.
cat > "$B/install-plugin" <<'EOF'
#!/bin/bash
P=$HOME/.config/omarchy/plugins/mac.missioncontrol ST=$HOME/.local/state/omacvm
sh=$(cat "$S/shell"); [[ -e $S/hung ]] && sh=busy
if diff -rq "$2" "$P" >/dev/null 2>&1; then echo "install-plugin same" >> "$LOG"
elif [[ $sh == locked || $sh == busy ]]; then mkdir -p "$ST/plugins-staged"; rm -rf "$ST/plugins-staged/mac.missioncontrol"; cp -R "$2" "$ST/plugins-staged/mac.missioncontrol"; echo "install-plugin staged" >> "$LOG"
else
  [[ $sh == open && -d $P ]] && : > "$ST/restart-shell"
  mkdir -p "$(dirname "$P")"; rm -rf "$P"; cp -R "$2" "$P"; echo "install-plugin copied" >> "$LOG"
fi
if jq -e '.plugins[]? | select(.id == "mac.missioncontrol")' "$HOME/.config/omarchy/shell.json" >/dev/null 2>&1; then :
elif [[ $sh == open ]] && omarchy plugin enable mac.missioncontrol >/dev/null; then :
elif ! jq -e '.plugins[]? | select(.id == "mac.missioncontrol")' "$HOME/.config/omarchy/shell.json" >/dev/null 2>&1; then
  grep -qx mac.missioncontrol "$ST/pending-plugins" 2>/dev/null || echo mac.missioncontrol >> "$ST/pending-plugins"
fi
EOF
chmod +x "$B"/*
export S LOG PATH="$B:$PATH" OMACVM_MC_HOME=$H OMACVM_MC_RUN=$RUNDIR OMACVM_MC_INSTALL_PLUGIN=$B/install-plugin HOME=$H
P=$H/.config/omarchy/plugins/mac.missioncontrol MARK=$H/.local/state/omacvm/missioncontrol C=$H/.config/omarchy/shell.json
I=$M/guest/install.sh
fresh() {   # a 4.5 VM, logged in, the shell open, the plugin nowhere
  rm -rf "$S" "$H" "$RUNDIR"; mkdir -p "$S" "$H/.config/omarchy/plugins" "$H/.config/hypr" "$RUNDIR/hypr/sig"
  echo '{"plugins":[]}' > "$C"; : > "$LOG"
  echo 4.5.0-3 > "$S/omarchy"; echo open > "$S/shell"; : > "$S/hypr"
  printf 'hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })\n' > "$H/.config/hypr/input.lua"
}
in_conf() { jq -e '.plugins[]? | select(.id == "mac.missioncontrol")' "$C" >/dev/null 2>&1; }
enabled() { yes_no in_conf; }
there() { if [[ -e $1 ]]; then echo yes; else echo no; fi; }
logged() { yes_no grep -qF -- "$1" "$LOG"; }
st() { bash "$I" me --status "$1"; }

# Omarchy 4.0: refused, nothing written.
fresh; echo 4.0.3-1 > "$S/omarchy"
out=$(bash "$I" me on); rc=$?
expect "4.0: refused (exit 3)" 3 "$rc"
expect "4.0: says why" yes "$(yes_no grep -q 'needs Omarchy 4.5' <<<"$out")"
expect "4.0: nothing in place, no marker, not enabled" "no no no" "$(there "$P") $(there "$MARK") $(enabled)"
expect "4.0 off: check says off (needs Omarchy 4.5)" "skip off (needs Omarchy 4.5)" "$(st off)"

# On, session open: OmacVM's copy, enabled, loaded; the check says ok.
fresh
bash "$I" me on >/dev/null; rc=$?
expect "on: done" 0 "$rc"
expect "on: the copy in place, byte for byte" yes "$(yes_no diff -rq "$M/plugin/mac.missioncontrol" "$P")"
expect "on: enabled, its Hyprland half live" "yes yes" "$(enabled) $(there "$S/live")"
expect "on: the marker names the pinned commit" "$(sed -n 's/^commit //p' "$M/PIN")" "$(cat "$MARK")"
expect "on: check ok" "ok four fingers up open it, sideways page while it is open" "$(st on)"
# The shell reads a new folder in the background: the first enable comes too early; the step enables it itself.
fresh; echo 2 > "$S/unknown"
bash "$I" me on >/dev/null
expect "early enable: on and loaded within the step, not left queued" "yes yes no" \
  "$(enabled) $(there "$S/live") $(yes_no grep -qx mac.missioncontrol "$H/.local/state/omacvm/pending-plugins")"
fresh; bash "$I" me on >/dev/null
# A second apply: nothing written, nothing queued, no restart, no wait.
: > "$LOG"; rm -f "$H/.local/state/omacvm/restart-shell"; t0=$SECONDS
bash "$I" me on >/dev/null
expect "second apply: the same copy, nothing written" "yes no" "$(logged 'install-plugin same') $(logged 'install-plugin copied')"
expect "second apply: no shell restart owed, no enable call" "no no" "$(there "$H/.local/state/omacvm/restart-shell") $(logged 'omarchy plugin enable')"
expect "second apply: no wait for a hot reload" yes "$(yes_no test $((SECONDS - t0)) -lt 3)"
# Update VM with a changed copy in place: replaced, then 3 s for the hot reload before the restart.
printf ' ' >> "$P/Layout.js"; t0=$SECONDS
bash "$I" me on >/dev/null
expect "changed copy: replaced, a shell restart owed" "yes yes" "$(logged 'install-plugin copied') $(there "$H/.local/state/omacvm/restart-shell")"
expect "changed copy: waits for the hot reload (3 s) before the apply's restart" yes "$(yes_no test $((SECONDS - t0)) -ge 3)"
# Paging needs OmacVM's 4-finger workspace line.
: > "$H/.config/hypr/input.lua"
expect "no 4-finger workspace swipe: check warns" "warn" "$(st on | cut -d' ' -f1)"
printf 'hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })\n' > "$H/.config/hypr/input.lua"
# Windows left hidden while closed: the check fails, a repair shows them.
echo 2 > "$S/hidden"
expect "hidden while closed: check fails" "fail Mission Control is closed, but 2 windows are hidden: omacvm apply --reinstall mission-control" "$(st on)"
echo 0 > "$S/hidden"; : > "$S/layer"
expect "only the overview left on the screen while closed: check fails, says so" "fail Mission Control is closed, but its overview covers the screen: omacvm apply --reinstall mission-control" "$(st on)"
rm -f "$S/layer"; echo 2 > "$S/hidden"
bash "$I" me --repair >/dev/null
expect "repair: windows shown (the plugin's reset)" "0 yes" "$(cat "$S/hidden") $(logged reset)"

# Off, session open: windows shown, disabled, hooks gone with one reload, copy gone, marker gone.
echo 1 > "$S/hidden"; : > "$LOG"
bash "$I" me off; rc=$?
expect "off: done" 0 "$rc"
expect "off: windows shown, disabled, reloaded" "0 no yes" "$(cat "$S/hidden") $(enabled) $(logged 'hyprctl reload')"
expect "off: no hooks or keys left in Hyprland" "no []" "$(there "$S/hooks") $(hyprctl binds -j)"
expect "off: OmacVM's copy and the marker gone" "no no" "$(there "$P") $(there "$MARK")"
expect "off: check says off" "skip off (experimental: omacvm enable mission-control)" "$(st off)"
: > "$LOG"; bash "$I" me off
expect "off again: nothing asked of the shell or Hyprland" "" "$(cat "$LOG")"

# Off under the lock: disabled at once; the folder and the reload wait.
fresh; bash "$I" me on >/dev/null; echo locked > "$S/shell"; : > "$LOG"
bash "$I" me off >/dev/null
expect "locked off: disabled, no reload, the folder and marker stay" "no no yes yes" "$(enabled) $(logged 'hyprctl reload') $(there "$P") $(there "$MARK")"
expect "locked off: check says the rest comes" "human" "$(st off | cut -d' ' -f1)"
echo open > "$S/shell"
bash "$I" me off >/dev/null
expect "next apply after the unlock: reloaded, folder and marker gone" "yes no no no" "$(logged 'hyprctl reload') $(there "$S/hooks") $(there "$P") $(there "$MARK")"

# On under the lock: staged, not in the plugins folder.
fresh; echo locked > "$S/shell"
bash "$I" me on >/dev/null
expect "locked on: staged, nothing in the plugins folder" "yes no" "$(there "$H/.local/state/omacvm/plugins-staged/mac.missioncontrol") $(there "$P")"
expect "locked on: check says after the unlock" "human in place right after the next unlock" "$(st on)"
# Switched off before the unlock: the staged copy goes too.
bash "$I" me off >/dev/null
expect "off before the unlock: the staged copy goes" no "$(there "$H/.local/state/omacvm/plugins-staged/mac.missioncontrol")"

# Nobody logged in: queued for the login; off takes it out of shell.json and the queue.
fresh; echo down > "$S/shell"; rm -f "$S/hypr"; rm -rf "$RUNDIR/hypr/sig"
bash "$I" me on >/dev/null
expect "no session: in place, queued for the login" "yes yes" "$(there "$P") $(yes_no grep -qx mac.missioncontrol "$H/.local/state/omacvm/pending-plugins")"
expect "no session: check says at the next login" "human enabled at the next login" "$(st on)"
bash "$I" me off >/dev/null
expect "no session off: not queued, folder and marker gone" "no no no" "$(yes_no grep -qx mac.missioncontrol "$H/.local/state/omacvm/pending-plugins") $(there "$P") $(there "$MARK")"

# A four-finger up/down gesture of the user's own: a new config error -> off again, with the reason.
fresh; echo "an old error of the user's" > "$S/errors"; : > "$S/planted"
out=$(bash "$I" me on); rc=$?
expect "own vertical gesture: on fails" 1 "$rc"
expect "a new config error: says which" yes "$(yes_no grep -q "Hyprland reported .gesture: 4 fingers vertical is taken. once it was on: switched off again" <<<"$out")"
expect "own vertical gesture: off again, copy and marker gone" "no no no" "$(enabled) $(there "$P") $(there "$MARK")"
expect "own vertical gesture: config errors as before" "an old error of the user's" "$(hyprctl configerrors)"
# The same gesture in the user's config as a plain line (Hyprland 0.56.2 gives no error for it): refused before anything.
fresh; printf 'hl.gesture({ fingers = 4, direction = "vertical", action = "workspace" })\n' >> "$H/.config/hypr/input.lua"
out=$(bash "$I" me on); rc=$?
expect "own vertical line: refused, says where" "1 yes" "$rc $(yes_no grep -q '~/.config/hypr/input.lua:2' <<<"$out")"
expect "own vertical line: nothing written, not enabled" "no no no" "$(there "$P") $(there "$MARK") $(enabled)"
# One with a modifier (mods =) is another gesture: not refused.
fresh; printf 'hl.gesture({ fingers = 4, direction = "vertical", mods = "SUPER", action = "workspace" })\n' >> "$H/.config/hypr/input.lua"
bash "$I" me on >/dev/null
expect "own vertical line with mods: on works" "yes yes" "$(enabled) $(there "$MARK")"
# One added after it was on: the check warns.
sed -i.bak '$d' "$H/.config/hypr/input.lua"; bash "$I" me on >/dev/null
printf 'hl.gesture({ fingers = 4, direction = "up", action = "fullscreen" })\n' >> "$H/.config/hypr/input.lua"
expect "own vertical line added later: check warns with the place" "warn a four-finger up or down gesture of your own (~/.config/hypr/input.lua:2) takes the swipe; ⌃↑ still opens it" "$(st on)"
# An error the user had before is no reason.
fresh; echo "an old error of the user's" > "$S/errors"
bash "$I" me on >/dev/null
expect "an earlier config error alone: on works" "yes yes" "$(enabled) $(there "$MARK")"

# The owner's own copy (omarchy plugin add, a git clone).
fresh; cp -R "$M/plugin/mac.missioncontrol" "$P"; mkdir "$P/.git"; echo own > "$P/README.md"
jq '.plugins = [{id: "mac.missioncontrol"}]' "$C" > "$C.n" && mv "$C.n" "$C"
before=$(cd "$P" && find . -type f -exec cat {} + | sha | cut -c1-16)
: > "$LOG"; bash "$I" me off
expect "own copy, feature off, apply: left alone (enabled, files, no shell call)" "yes $before no" \
  "$(enabled) $(cd "$P" && find . -type f -exec cat {} + | sha | cut -c1-16) $(logged omarchy)"
expect "own copy, feature off: check says so" "skip off in OmacVM; your own copy (omarchy plugin) is on" "$(st off)"
omarchy plugin disable mac.missioncontrol >/dev/null
bash "$I" me on >/dev/null
expect "own copy, on: enabled, never copied over" "yes no yes" "$(enabled) $(logged 'install-plugin') $(there "$P/.git")"
expect "own copy, on: files as they were" "$before" "$(cd "$P" && find . -type f -exec cat {} + | sha | cut -c1-16)"
expect "own copy, on: check names it" yes "$(yes_no grep -q 'your own copy' <<<"$(st on)")"
bash "$I" me off >/dev/null
expect "own copy, off after OmacVM's on: disabled, the clone stays" "no yes yes no" "$(enabled) $(there "$P/.git") $(there "$P/README.md") $(there "$MARK")"

# A shell that hangs with the overview up.
fresh; bash "$I" me on >/dev/null; : > "$S/hung"; : > "$S/layer"; echo 3 > "$S/hidden"
expect "hung: check fails, says what is stuck" "fail the Omarchy shell does not answer and 3 windows are hidden and its overview covers the screen: omacvm apply --reinstall mission-control" "$(st on)"
echo 0 > "$S/hidden"
expect "hung, only the overview on the screen: says it covers the screen" "fail the Omarchy shell does not answer and its overview covers the screen: omacvm apply --reinstall mission-control" "$(st on)"
echo 3 > "$S/hidden"
: > "$LOG"; bash "$I" me --repair >/dev/null; rc=$?
expect "hung: repair restarts the shell, windows shown, overview gone" "0 yes 0 no" "$rc $(logged omarchy-restart-shell) $(cat "$S/hidden") $(there "$S/layer")"
# Locked by Hyprland: not restarted, says so.
: > "$S/hung"; : > "$S/layer"; : > "$S/hyprlocked"; : > "$LOG"
out=$(bash "$I" me --repair); rc=$?
expect "hung and locked: no restart, says unlock" "1 no yes" "$rc $(logged omarchy-restart-shell) $(yes_no grep -q 'unlock' <<<"$out")"
rm -f "$S/hyprlocked"
# Off with the shell hung: it still goes off (restart, then shell.json).
: > "$S/stuck"
bash "$I" me off >/dev/null; rc=$?
expect "hung off: done, out of shell.json" "0 no" "$rc $(enabled)"
expect "hung off: the old shell killed once its restart did not help" yes "$(logged 'pkill -KILL -u me -x quickshell')"
rm -f "$S/stuck" "$S/hung" "$S/layer"

echo
if (( fail )); then echo "Mission Control tests: FAILED"; exit 1; fi
echo "Mission Control tests: all passed"
