#!/bin/bash
# Per-display workspaces step aside on Omarchy 4.5 (src/workspaces/guest/install.sh):
# OmacVM's block goes from ~/.config/hypr/bindings.lua and the rest of the file
# stays byte for byte, monitor_workspaces.lua goes, and the bar widget is
# disabled (shell running) or queued for the next login. Until the review of
# #506 the block was cut out through a pipe into the same file, which emptied
# it now and then (always with a big file): every binding of the user's gone.
# No VM: the script runs as the caller, with getent, sudo and Omarchy's
# commands replaced and Omarchy 4.5 faked by its monitor-workspaces.lua.
#   src/tests/workspaces-45.sh
#   OMACVM_SRC=DIR src/tests/workspaces-45.sh   against another checkout (an older one fails)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$(cd "${OMACVM_SRC:-$R}/src" && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=$T/home; BL=$H/.config/hypr/bindings.lua; MW=$H/.config/hypr/monitor_workspaces.lua
P=$H/.config/omarchy/plugins/omacvm.workspaces; Q=$H/.local/state/omacvm/pending-plugins-off

# Stand-ins: getent gives the test's home, sudo runs the command, the shell
# answers when $T/up exists, omarchy writes what it was asked into $T/omarchy.log.
S=$T/bin; mkdir -p "$S" "$T/omarchy/default/hypr"
printf '#!/bin/sh\necho "$2:x:%s:%s::%s:/bin/bash"\n' "$(id -u)" "$(id -g)" "$H" > "$S/getent"
printf '#!/bin/bash\n[[ $1 == -u ]] && shift 2\nexec "$@"\n' > "$S/sudo"
printf '#!/bin/sh\n[ -e "%s/up" ]\n' "$T" > "$S/omarchy-shell"
printf '#!/bin/sh\necho "$*" >> "%s/omarchy.log"\n' "$T" > "$S/omarchy"
chmod 755 "$S"/*
echo '-- Omarchy 4.5' > "$T/omarchy/default/hypr/monitor-workspaces.lua"

# A user's bindings.lua: their lines, OmacVM's block as apply appends it, more lines.
user_lines() {   # N: N lines of the user's own
  awk -v n="$1" -v p="$2" 'BEGIN { for (i = 1; i <= n; i++) printf "o.bind(\"SUPER + F%d\", \"%s %d\", function() end)\n", i % 12 + 1, p, i }'
}
setup() {   # LINES [no-end]: a fresh home; $T/want = what bindings.lua must be after
  rm -rf "$H" "$T/up" "$T/omarchy.log"; mkdir -p "$H/.config/hypr" "$P"
  user_lines "$1" before > "$T/before"; user_lines "$1" after > "$T/after"
  echo '{}' > "$P/manifest.json"
  echo '-- OmacVM' > "$MW"
  if [[ ${2:-} == no-end ]]; then
    { cat "$T/before"; grep -vxF -e '-- <<< OmacVM per-display workspaces' "$SRC/workspaces/guest/workspace-bindings.lua"; cat "$T/after"; } > "$BL"
    cp "$BL" "$T/want"
  else
    { cat "$T/before"; cat "$SRC/workspaces/guest/workspace-bindings.lua"; cat "$T/after"; } > "$BL"
    cat "$T/before" "$T/after" > "$T/want"
  fi
}
run() { PATH="$S:$PATH" OMARCHY_PATH="$T/omarchy" "$SRC/workspaces/guest/install.sh" "$(id -un)" 2>&1; }
same() { cmp -s "$1" "$2" && echo same || echo "differs ($(wc -l < "$1" | tr -d ' ') lines)"; }

# ---------- the block goes, the rest stays (big files: the pipe lost them) ----------
bad=0
for i in 1 2 3 4 5; do
  setup 40000
  out=$(run)
  [[ $(same "$BL" "$T/want") == same ]] || bad=$((bad + 1))
done
expect "OmacVM's block out of bindings.lua, the user's 80000 lines kept byte for byte (5 runs)" 0 "$bad"
expect "the step says Omarchy's own" "per-display workspaces: Omarchy's own" "$out"
expect "monitor_workspaces.lua gone" no "$([[ -e $MW ]] && echo yes || echo no)"
expect "no shell: the widget is queued for the next login" omacvm.workspaces "$(cat "$Q" 2>/dev/null)"
expect "no shell: Omarchy was not asked" "" "$(cat "$T/omarchy.log" 2>/dev/null)"

setup 30
out=$(run)
expect "a small bindings.lua: the block out, the rest kept" same "$(same "$BL" "$T/want")"

# ---------- shell running: Omarchy disables the widget, its folder goes ----------
setup 30; touch "$T/up"
out=$(run)
expect "shell running: omarchy plugin disable" "plugin disable omacvm.workspaces" "$(cat "$T/omarchy.log" 2>/dev/null)"
expect "shell running: the widget's folder gone" no "$([[ -e $P ]] && echo yes || echo no)"
expect "shell running: nothing queued" no "$([[ -e $Q ]] && echo yes || echo no)"

# ---------- a block without its end line (changed by hand) stays whole ----------
setup 30 no-end
out=$(run)
expect "no end line: bindings.lua as it was" same "$(same "$BL" "$T/want")"
expect "no end line: monitor_workspaces.lua kept (still required)" yes "$([[ -e $MW ]] && echo yes || echo no)"

# ---------- no block: nothing changes ----------
setup 30; cat "$T/before" "$T/after" > "$BL"; cp "$BL" "$T/want"
out=$(run)
expect "no block: bindings.lua as it was" same "$(same "$BL" "$T/want")"

exit $fail
