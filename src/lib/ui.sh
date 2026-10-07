# The setup's screens (sourced; macOS's bash 3.2, no dependencies): a choice
# list, a checklist, a box, numbered steps. They draw on the terminal (/dev/tty)
# with ↑/↓ (or k/j), space and Return, and fall back to numbered prompts when
# the terminal cannot move the cursor (TERM=dumb). Everything they print goes to
# the terminal, so a script's own output can still be piped; results come back
# in variables.
#   ui_select VAR "Title" DEFAULT "label|detail" ...        VAR = chosen index
#   ui_checklist "Title" ...                                 edits the arrays below
#   ui_box "line" ...                                        a framed block
#   ui_step N TOTAL "text"                                   "[N/TOTAL] text"
TTY=${TTY:-/dev/tty}
# Characters, not bytes, for the spinner, ✓ and the box (a C locale, e.g. over
# SSH or with LANG unset, would cut them apart): a UTF-8 locale, which every
# Mac has.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
  *) if [[ -n ${LC_ALL:-} ]]; then export LC_ALL=en_US.UTF-8; else export LC_CTYPE=en_US.UTF-8; fi ;;
esac
UI_FANCY=0
if { : < "$TTY"; } 2>/dev/null && [[ ${TERM:-dumb} != dumb ]] && tput cuu1 >/dev/null 2>&1; then UI_FANCY=1; fi

UB=$'\033[1m'; UD=$'\033[2m'; UR=$'\033[0m'; UACC=$'\033[36m'; UOK=$'\033[32m'; UEXP=$'\033[35m'
(( UI_FANCY )) || { UB=""; UD=""; UR=""; UACC=""; UOK=""; UEXP=""; }

ui_cols() { local c; c=$(tput cols 2>/dev/null < "$TTY"); echo "${c:-80}"; }

# Restore the cursor whatever happens (Ctrl-C in a list included).
ui_restore() { (( UI_FANCY )) || return 0; { printf '\033[?25h' > "$TTY"; stty echo icanon < "$TTY"; } 2>/dev/null || true; }
trap 'ui_restore' EXIT
trap 'ui_restore; echo; exit 130' INT

# ui_key: one key from the terminal into UI_KEY: up, down, left, right, space,
# enter, esc, or the character.
ui_key() {
  local k rest
  IFS= read -rsn1 k < "$TTY" || { UI_KEY=eof; return; }
  case $k in
    $'\033')
      IFS= read -rsn2 -t 1 rest < "$TTY" || rest=""
      case $rest in '[A') UI_KEY=up ;; '[B') UI_KEY=down ;; '[C') UI_KEY=right ;; '[D') UI_KEY=left ;; *) UI_KEY=esc ;; esac ;;
    "") UI_KEY=enter ;;
    " ") UI_KEY=space ;;
    k) UI_KEY=up ;;
    j) UI_KEY=down ;;
    *) UI_KEY=$k ;;
  esac
}

# Shorten to the terminal's width (the redraw counts on one line per row).
ui_fit() { local w=$(( $(ui_cols) - 2 )) s=$1; (( ${#s} > w )) && s="${s:0:w-1}…"; printf '%s' "$s"; }

ui_select() {
  local var=$1 title=$2 cur=$3; shift 3
  local n=$# i k label detail drawn=0 lw=0
  local items=("$@")
  for ((i = 0; i < n; i++)); do label=${items[$i]%%|*}; (( ${#label} > lw )) && lw=${#label}; done
  printf '\n%s%s%s\n' "$UB" "$title" "$UR" > "$TTY"
  if (( ! UI_FANCY )); then
    for ((i = 0; i < n; i++)); do
      label=${items[$i]%%|*}; detail=${items[$i]#*|}; [[ $detail == "${items[$i]}" ]] && detail=""
      printf '  %d  %s%s\n' $((i + 1)) "$label" "${detail:+  $detail}" > "$TTY"
    done
    while :; do
      read -r -p "  Choose 1-$n [$((cur + 1))]: " k < "$TTY" || exit 1
      k=${k:-$((cur + 1))}
      [[ $k =~ ^[0-9]+$ ]] && (( k >= 1 && k <= n )) && { eval "$var=$((k - 1))"; return 0; }
    done
  fi
  printf '\033[?25l' > "$TTY"; stty -echo < "$TTY" 2>/dev/null || true
  while :; do
    (( drawn )) && printf '\033[%dA' $((n + 1)) > "$TTY"
    for ((i = 0; i < n; i++)); do
      label=${items[$i]%%|*}; detail=${items[$i]#*|}; [[ $detail == "${items[$i]}" ]] && detail=""
      label="$label$(printf '%*s' $(( lw - ${#label} )) "")"
      if (( i == cur )); then
        printf '\r\033[2K  %s❯ %s%s%s\n' "$UACC" "$UB" "$(ui_fit "$label${detail:+   $detail}")" "$UR" > "$TTY"
      else
        printf '\r\033[2K    %s%s%s%s\n' "$label" "${detail:+   $UD}" "$(ui_fit "$detail")" "$UR" > "$TTY"
      fi
    done
    printf '\r\033[2K  %s↑/↓ choose · Return confirm%s\n' "$UD" "$UR" > "$TTY"
    drawn=1
    ui_key
    case $UI_KEY in
      up) (( cur > 0 )) && cur=$((cur - 1)) ;;
      down) (( cur < n - 1 )) && cur=$((cur + 1)) ;;
      [1-9]) (( UI_KEY <= n )) && cur=$((UI_KEY - 1)) ;;
      enter) break ;;
      q|eof) printf '\033[?25h' > "$TTY"; exit 1 ;;
    esac
  done
  printf '\033[1A\r\033[2K' > "$TTY"   # drop the key hint
  printf '\033[?25h' > "$TTY"; stty echo < "$TTY" 2>/dev/null || true
  eval "$var=$cur"
}

# Checklist over parallel arrays the caller fills:
#   UI_KEYS  UI_LABELS  UI_DETAILS  UI_ON (1/0)  UI_TAG ("" | experimental | slow)
#   UI_OFF_REASON ("" or why it cannot be chosen)  UI_NEEDS (key it needs, or "")
# Ticking an item ticks what it needs; unticking one unticks what needs it.
ui_check_set() {   # INDEX 1|0
  local i=$1 v=$2 j
  [[ -n ${UI_OFF_REASON[$i]} && $v == 1 ]] && return 0
  UI_ON[$i]=$v
  if (( v )) && [[ -n ${UI_NEEDS[$i]} ]]; then
    for ((j = 0; j < ${#UI_KEYS[@]}; j++)); do [[ ${UI_KEYS[$j]} == "${UI_NEEDS[$i]}" && ${UI_ON[$j]} == 0 ]] && ui_check_set "$j" 1; done
  fi
  if (( ! v )); then
    for ((j = 0; j < ${#UI_KEYS[@]}; j++)); do [[ ${UI_NEEDS[$j]} == "${UI_KEYS[$i]}" && ${UI_ON[$j]} == 1 ]] && ui_check_set "$j" 0; done
  fi
  return 0
}

ui_checklist() {
  local title=$1 n=${#UI_KEYS[@]} cur=0 i drawn=0 mark tag line a
  printf '\n%s%s%s\n' "$UB" "$title" "$UR" > "$TTY"
  if (( ! UI_FANCY )); then
    while :; do
      for ((i = 0; i < n; i++)); do
        mark="[ ]"; (( UI_ON[i] )) && mark="[x]"; [[ -n ${UI_OFF_REASON[$i]} ]] && mark="[-]"
        tag=""; [[ -n ${UI_TAG[$i]} ]] && tag=" (${UI_TAG[$i]})"; [[ -n ${UI_OFF_REASON[$i]} ]] && tag=" (${UI_OFF_REASON[$i]})"
        printf '  %d %s %s%s\n' $((i + 1)) "$mark" "${UI_LABELS[$i]}" "$tag" > "$TTY"
      done
      read -r -p "  A number switches it, Return keeps these: " a < "$TTY" || exit 1
      [[ -z $a ]] && return 0
      [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= n )) && ui_check_set $((a - 1)) $(( UI_ON[a - 1] ? 0 : 1 ))
    done
  fi
  printf '\033[?25l' > "$TTY"; stty -echo < "$TTY" 2>/dev/null || true
  while :; do
    (( drawn )) && printf '\033[%dA' $((n + 2)) > "$TTY"
    for ((i = 0; i < n; i++)); do
      if [[ -n ${UI_OFF_REASON[$i]} ]]; then mark="${UD}[–]$UR"
      elif (( UI_ON[i] )); then mark="${UOK}[✓]$UR"
      else mark="[ ]"; fi
      tag=""
      [[ ${UI_TAG[$i]} == experimental ]] && tag=" ${UEXP}experimental$UR"
      [[ ${UI_TAG[$i]} == slow ]] && tag=" ${UD}adds about 10 minutes to the build$UR"
      [[ -n ${UI_OFF_REASON[$i]} ]] && tag=" $UD${UI_OFF_REASON[$i]}$UR"
      line="${UI_LABELS[$i]}"
      if (( i == cur )); then printf '\r\033[2K  %s❯%s %s %s%s%s%s\n' "$UACC" "$UR" "$mark" "$UB" "$(ui_fit "$line")" "$UR" "$tag" > "$TTY"
      else printf '\r\033[2K    %s %s%s\n' "$mark" "$(ui_fit "$line")" "$tag" > "$TTY"; fi
    done
    printf '\r\033[2K      %s%s%s\n' "$UD" "$(ui_fit "${UI_DETAILS[$cur]}")" "$UR" > "$TTY"
    printf '\r\033[2K  %s↑/↓ move · space switch · Return confirm%s\n' "$UD" "$UR" > "$TTY"
    drawn=1
    ui_key
    case $UI_KEY in
      up) (( cur > 0 )) && cur=$((cur - 1)) ;;
      down) (( cur < n - 1 )) && cur=$((cur + 1)) ;;
      space) ui_check_set "$cur" $(( UI_ON[cur] ? 0 : 1 )) ;;
      enter) break ;;
      q|eof) printf '\033[?25h' > "$TTY"; exit 1 ;;
    esac
  done
  printf '\033[2A\r\033[2K\n\r\033[2K\033[1A' > "$TTY"   # drop the detail and hint lines
  printf '\033[?25h' > "$TTY"; stty echo < "$TTY" 2>/dev/null || true
}

ui_box() {
  local w=0 l pad max=$(( $(ui_cols) - 6 ))
  for l in "$@"; do (( ${#l} > w )) && w=${#l}; done
  (( w > max )) && w=$max
  printf '\n  ╭%s╮\n' "$(printf '─%.0s' $(seq 1 $((w + 2))))" > "$TTY"
  for l in "$@"; do
    (( ${#l} > w )) && l="${l:0:w-1}…"
    pad=$(( w - ${#l} ))   # characters, not bytes: printf would pad "·" and "…" short
    printf '  │ %s%*s │\n' "$l" "$pad" "" > "$TTY"
  done
  printf '  ╰%s╯\n' "$(printf '─%.0s' $(seq 1 $((w + 2))))" > "$TTY"
}

ui_step() { printf '\n\033[1;36m[%s/%s]\033[0m \033[1m%s\033[0m\n' "$1" "$2" "$3"; }

# ui_spin "Message" command...: runs the command with a spinner and the elapsed
# time, its output kept aside (and in the build log, if any); a ✓ when done,
# or ✗ and the output's last lines when it fails. Returns the command's status.
# ui_spin_val VAR "Message" command...: the same, the command's output into VAR.
# ui_spin_stop: stops the command ui_spin is running, and all it started (for
# an EXIT trap: a script's background jobs ignore Ctrl-C and would go on).
UI_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
UI_SPIN_PID=""
ui_spin() {
  local msg=$1; shift
  local out rc pid i=0 t0=$SECONDS e
  out=$(mktemp)
  if (( ! UI_FANCY )); then
    printf '  %s...\n' "$msg"   # no terminal to draw on (scripts, agents): plain output
    # In the background and waited for, as in the spinner branch: set -e
    # still stops the step, and a die inside still shows its reason.
    ( "$@" ) > "$out" 2>&1 &
    UI_SPIN_PID=$!
    wait $! && rc=0 || rc=$?
  else
    "$@" > "$out" 2>&1 &
    pid=$!; UI_SPIN_PID=$pid
    printf '\033[?25l' > "$TTY"
    while kill -0 "$pid" 2>/dev/null; do
      e=$(( SECONDS - t0 ))
      printf '\r\033[2K  %s%s%s %s %s%dm %02ds%s' "$UACC" "${UI_FRAMES:i % 10:1}" "$UR" "$(ui_fit "$msg")" "$UD" $(( e / 60 )) $(( e % 60 )) "$UR" > "$TTY"
      i=$(( i + 1 )); sleep 0.1
    done
    wait "$pid" && rc=0 || rc=$?
    printf '\r\033[2K\033[?25h' > "$TTY"
  fi
  UI_SPIN_PID=""
  e=$(( SECONDS - t0 ))
  if (( rc == 0 )); then printf '  %s✓%s %s %s(%dm %02ds)%s\n' "$UOK" "$UR" "$msg" "$UD" $(( e / 60 )) $(( e % 60 )) "$UR"
  else printf '  \033[31m✗\033[0m %s\n' "$msg"; tail -15 "$out" | sed 's/^/    /'; fi
  [[ -n ${UI_LOG:-} ]] && cat "$out" >> "$UI_LOG" 2>/dev/null
  UI_SPIN_OUT=$(cat "$out"); rm -f "$out"
  return $rc
}
ui_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do ui_tree "$c"; done; echo "$1"; }
ui_spin_stop() {
  local pids p i
  [[ -n $UI_SPIN_PID ]] || return 0
  pids=$(ui_tree "$UI_SPIN_PID"); UI_SPIN_PID=""
  kill -TERM $pids 2>/dev/null || true
  for i in $(seq 1 50); do   # gone before the caller deletes what they wrote (5 s at most)
    for p in $pids; do kill -0 "$p" 2>/dev/null && break; p=""; done
    [[ -z $p ]] && break
    sleep 0.1
  done
  return 0
}
ui_spin_val() {
  local var=$1 rc; shift
  ui_spin "$@" && rc=0 || rc=$?
  printf -v "$var" '%s' "$(tail -1 <<<"$UI_SPIN_OUT")"
  return $rc
}

# command | ui_follow "Message": shows the command's lines as they come (into
# the build log too), a repeated line once with a count, and below them a
# status line with a spinner and the elapsed time, so a long quiet stretch
# never looks stuck. (The spinner is its own background loop: bash 3.2's read
# cannot tell a timeout from the end of the input.)
ui_follow() {
  local msg=$1 line last="" n=0 ticker=""
  if (( UI_FANCY )); then
    ( t0=$SECONDS; i=0
      while :; do
        e=$(( SECONDS - t0 ))
        printf '\r\033[2K  %s%s%s %s %s%dm %02ds%s' "$UACC" "${UI_FRAMES:i % 10:1}" "$UR" "$msg" "$UD" $(( e / 60 )) $(( e % 60 )) "$UR" > "$TTY"
        i=$(( i + 1 )); sleep 0.2
      done ) &
    ticker=$!
  fi
  while IFS= read -r line; do
    (( UI_FANCY )) && printf '\r\033[2K' > "$TTY"
    if [[ $line == "$last" ]]; then n=$(( n + 1 )); continue; fi
    (( n > 1 )) && printf '    %s(× %d)%s\n' "$UD" "$n" "$UR"
    printf '%s\n' "$line"; last=$line; n=1
  done
  (( n > 1 )) && printf '    %s(× %d)%s\n' "$UD" "$n" "$UR"
  if [[ -n $ticker ]]; then kill "$ticker" 2>/dev/null || true; wait "$ticker" 2>/dev/null || true; printf '\r\033[2K' > "$TTY"; fi
  return 0
}
