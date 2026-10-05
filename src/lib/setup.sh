# build.sh's setup questions (sourced; macOS's bash 3.2). Every question reads
# the terminal directly, so build.sh's own output can be piped or logged.

TTY=/dev/tty
README_ROUTES="https://github.com/gillesgoetsch/omacvm#four-ways-parallels-utm-vmware-fusion-or-omacvmapp"

say() { printf '%s\n' "$*"; }
hd() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ask_yn "question" y|n -> status 0 for yes
ask_yn() {
  local a hint="[y/N]"; [[ $2 == y ]] && hint="[Y/n]"
  while :; do
    read -r -p "  $1 $hint " a < "$TTY" || die "no answer (no terminal?)"
    a=${a:-$2}
    case $a in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
  done
}

# ask_value "label" default regex -> the answer (re-asks until it matches)
ask_value() {
  local a
  while :; do
    read -r -p "    $1 [$2]: " a < "$TTY" || die "no answer (no terminal?)"
    a=${a:-$2}
    [[ $a =~ $3 ]] && { printf '%s\n' "$a"; return; }
    printf '    "%s" does not fit, try again\n' "$a" > "$TTY"
  done
}

# pick DEFAULT_INDEX INFO_FUNCTION OPTION... -> the chosen index (0-based).
# ←/→ (or h/l) move, 1-9 jump, Return confirms; INFO_FUNCTION <index> prints
# a short description shown beside the options.
pick() {
  local i=$1 info=$2; shift 2
  local n=$# k line j o
  local opts=("$@")
  while :; do
    line=""
    for ((j = 0; j < n; j++)); do
      o=${opts[$j]}
      if (( j == i )); then line+=$'\033[1;7m'" $o "$'\033[0m '; else line+=" $o  "; fi
    done
    printf '\r\033[K  ◀ %s▶   %s' "$line" "$($info "$i")" > "$TTY"
    IFS= read -rsn1 k < "$TTY" || die "no answer (no terminal?)"
    case $k in
      $'\033') IFS= read -rsn2 -t 1 k < "$TTY" || k=""
               case $k in '[D') (( i > 0 )) && i=$((i - 1)) ;; '[C') (( i < n - 1 )) && i=$((i + 1)) ;; esac ;;
      h) (( i > 0 )) && i=$((i - 1)) ;;
      l) (( i < n - 1 )) && i=$((i + 1)) ;;
      [1-9]) (( k <= n )) && i=$((k - 1)) ;;
      "") break ;;
    esac
  done
  printf '\n' > "$TTY"
  printf '%s\n' "$i"
}

# ---------- resources ----------
TIERS=(Low Balanced High Best)

# mac_specs: this Mac's CPUs (all, performance, efficiency) and memory in GB.
mac_specs() {
  mac_cores=$(sysctl -n hw.ncpu)
  mac_perf=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo "$mac_cores")
  mac_eff=$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo 0)
  mac_mem_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
}

# tier_values INDEX -> sets T_CPUS and T_MEM (GB), within CAP_CPUS / CAP_MEM_GB.
# Memory "Best" leaves macOS and the GPU (unified memory) max(8 GB, a quarter).
tier_values() {
  local m=$mac_mem_gb best_mem reserve
  reserve=$(( m / 4 > 8 ? m / 4 : 8 ))
  best_mem=$(( m - reserve > 4 ? m - reserve : 4 ))
  case $1 in
    0) T_CPUS=$(( mac_perf / 2 > 2 ? mac_perf / 2 : 2 )); T_MEM=$(( m / 4 > 4 ? m / 4 : 4 )) ;;
    1) T_CPUS=$mac_perf; T_MEM=$(( m / 2 )) ;;
    2) T_CPUS=$(( mac_perf + mac_eff / 2 )); T_MEM=$(( (m / 2 + best_mem) / 2 )) ;;
    3) T_CPUS=$mac_cores; T_MEM=$best_mem ;;
  esac
  (( T_MEM > best_mem )) && T_MEM=$best_mem
  (( T_MEM < 4 )) && T_MEM=4
  (( T_CPUS > CAP_CPUS )) && T_CPUS=$CAP_CPUS
  (( T_MEM > CAP_MEM_GB )) && T_MEM=$CAP_MEM_GB
  return 0
}

tier_info() { tier_values "$1"; printf '%s CPUs, %s GB memory' "$T_CPUS" "$T_MEM"; }

# ---------- the apps ----------
# Parallels' own licence limits per VM: sets P_EDITION, P_TRIAL, P_STATUS,
# CAP_CPUS, CAP_MEM_GB. Status 0: read; 1: Parallels does not answer (not set up
# yet); 2: it answers, but reports no active licence with limits; 3: "No license
# installed", a fresh install: Parallels starts its trial (or asks to sign in)
# when the first VM starts, so the build can go ahead.
parallels_limits() {
  local info c m
  info=$(prlsrvctl info --license 2>/dev/null) || return 1
  grep -q "No license installed" <<<"$info" && { P_STATUS="no licence yet"; return 3; }
  P_EDITION=$(sed -n 's/.*edition="\([^"]*\)".*/\1/p' <<<"$info")
  P_TRIAL=$(sed -n 's/.*is_trial="\([^"]*\)".*/\1/p' <<<"$info")
  P_STATUS=$(sed -n 's/.*status="\([^"]*\)".*/\1/p' <<<"$info")
  c=$(sed -n 's/.*cpu_total=\([0-9]*\).*/\1/p' <<<"$info")
  m=$(sed -n 's/.*max_memory=\([0-9]*\).*/\1/p' <<<"$info")
  [[ -n $P_EDITION && -n $c && -n $m ]] || return 2
  CAP_CPUS=$c; CAP_MEM_GB=$(( m / 1024 ))
}

# Standard's per-VM limits: always within what any edition allows.
parallels_standard_limits() { P_EDITION=standard; P_TRIAL=""; CAP_CPUS=4; CAP_MEM_GB=8; }

# No licence yet (a fresh install): the edition the user plans on, standard or
# pro (the trial is Pro). P_PLANNED=1 marks the limits as planned, not read.
parallels_planned_limits() {
  if [[ $1 == pro ]]; then P_EDITION=pro; P_TRIAL=""; CAP_CPUS=32; CAP_MEM_GB=128
  else parallels_standard_limits; fi
  P_PLANNED=1
}

utm_major() { defaults read /Applications/UTM.app/Contents/Info CFBundleShortVersionString 2>/dev/null | cut -d. -f1; }

# wait_for_app parallels|utm|fusion: until the app is there (and usable), or the user quits.
wait_for_app() {
  local a
  while :; do
    case $1 in
      parallels)
        local rc=1
        if [[ -x $PRLCTL ]]; then parallels_limits && return 0; rc=$?; fi
        if [[ -x $PRLCTL && $rc == 3 ]]; then
          hd "Parallels Desktop has no licence yet"
          say "    That is fine: it starts its free trial (Pro) or asks you to sign in when the"
          say "    build starts the VM; click through it then. Until a licence is active it does"
          say "    not say how much a VM may use."
          local e
          ui_select e "Which edition will you use?" 0 \
            "Standard|4 CPUs, 8 GB per VM" \
            "Pro or the trial|up to 32 CPUs, 128 GB per VM (if the trial ends in Standard: 4 CPUs / 8 GB in the VM's settings)" \
            "Check the licence again|after starting the trial or signing in"
          case $e in
            0) parallels_planned_limits standard; return 0 ;;
            1) parallels_planned_limits pro; return 0 ;;
          esac
          continue
        elif [[ -x $PRLCTL && $rc == 2 ]]; then
          hd "Parallels Desktop has no active licence yet (it reports: ${P_STATUS:-no status}${P_EDITION:+, $P_EDITION})"
          say "    In Parallels Desktop, start the trial or sign in with your Parallels account,"
          say "    then press Return here."
          say "    Or type s to go on with Parallels Standard's limits (4 CPUs, 8 GB per VM),"
          say "    which every edition allows."
          read -r -p "  Return to check again, s to go on, q to quit: " a < "$TTY" || die "no answer (no terminal?)"
          case $a in
            q) exit 1 ;;
            s) parallels_standard_limits; return 0 ;;
          esac
          continue
        elif [[ -x $PRLCTL ]]; then
          hd "Parallels Desktop is installed but not set up yet"
          say "    Open Parallels Desktop once and sign in or start the trial."
        else
          hd "Parallels Desktop is not installed"
          say "    Download: https://www.parallels.com/products/desktop/"
          say "    or:       brew install --cask parallels"
          say "    Install it, open it once and sign in or start the trial."
        fi ;;
      utm)
        if [[ -x $UTMCTL ]] && (( $(utm_major || echo 0) >= 5 )); then return 0; fi
        utm_install_help ;;
      fusion)
        have_fusion && return 0
        hd "VMware Fusion is not installed"
        fusion_install_help
        say "    Then open it once." ;;
    esac
    read -r -p "  Press Return to check again, or q to quit: " a < "$TTY" || die "no answer (no terminal?)"
    [[ $a == q ]] && exit 1
  done
}

# How to get UTM 5. It is still a beta: UTM's website, the App Store and
# Homebrew's plain "utm" cask all give 4.7, whose GPU path leaves Linux apps
# black (ggalancs/omarchy-arm-utm#7).
utm_install_help() {
  local v; v=$(defaults read /Applications/UTM.app/Contents/Info CFBundleShortVersionString 2>/dev/null || true)
  if [[ -n $v ]]; then hd "UTM $v is installed, but OmacVM needs UTM 5"
  else hd "UTM 5 is not installed"; fi
  say "    UTM 5 is still a beta, and it is the first UTM whose GPU acceleration draws"
  say "    Linux apps (on 4.7 they stay black). UTM's website, the App Store and"
  say "    \"brew install --cask utm\" give 4.7. Install the beta (tested: 5.0.6):"
  if [[ -n $v ]] && brew list --cask utm >/dev/null 2>&1; then
    say "      brew uninstall --cask utm && brew install --cask utm@beta"
  elif [[ -n $v ]]; then
    say "      quit UTM, move /Applications/UTM.app to the Trash (your VMs stay), then"
    say "      brew install --cask utm@beta"
  else
    say "      brew install --cask utm@beta"
  fi
  say "    or download UTM.dmg from the newest \"Beta\" release:"
  say "      https://github.com/utmapp/UTM/releases"
  say "    Then open UTM once."
}

# omarchy-mac's published package lane: stable once it exists, else rc.
omarchy_channel() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
    https://api.github.com/repos/omarchy-mac/omarchy-pkgs-aarch64/releases/tags/stable) || code=0
  [[ $code == 200 ]] && echo stable || echo rc
}
