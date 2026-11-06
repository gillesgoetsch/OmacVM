# build.sh's setup questions (sourced; macOS's bash 3.2). Every question reads
# the terminal directly, so build.sh's own output can be piped or logged.

TTY=/dev/tty

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

# tier_best_mem -> the Best tier's memory in GB on this Mac (mac_mem_gb): it
# leaves macOS and the GPU (unified memory) max(8 GB, a quarter). OmacVM.app's
# ResourceLimits.safeMemoryGB is the same rule.
tier_best_mem() {
  local m=$mac_mem_gb reserve
  reserve=$(( m / 4 > 8 ? m / 4 : 8 ))
  echo $(( m - reserve > 4 ? m - reserve : 4 ))
}

# tier_values INDEX -> sets T_CPUS and T_MEM (GB), within CAP_CPUS / CAP_MEM_GB.
# Memory "Best" is tier_best_mem.
tier_values() {
  local m=$mac_mem_gb best_mem
  best_mem=$(tier_best_mem)
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

# mem_warning TYPE MEMORY_MB VM [GRAPHICS_PEAK_MB]: what a VM memory above this
# Mac's Best tier means, one line (nothing at or below it). As OmacVM.app's
# warning (ResourceLimits.warning): OmacVM.app takes the VM's graphics from the
# Mac on top of its memory (its last run peaked at GRAPHICS_PEAK_MB, from
# logs/gpu-memory). Only says so: the setting stays the person's.
mem_warning() {
  local best mem peak=""
  best=$(tier_best_mem)
  [[ $2 =~ ^[0-9]+$ ]] && (( $2 > best * 1024 )) || return 0
  if (( $2 % 1024 )); then mem="$2 MB"; else mem="$(( $2 / 1024 )) GB"; fi
  if [[ ${4:-} =~ ^[0-9]{1,7}$ ]] && (( $4 > 0 )); then
    peak=$(awk -v m="$4" 'BEGIN { if (m < 1024) printf " (peak %d MB last run)", m; else printf " (peak %.1f GB last run)", m / 1024 }')
  fi
  case $1 in
    app) printf '%s' "$mem and the VM's graphics on top$peak leave macOS too little of this Mac's $mac_mem_gb GB: the Mac can slow down or swap, and apps in the VM can lose their graphics." ;;
    *) printf '%s' "$mem leaves macOS too little of this Mac's $mac_mem_gb GB: the Mac can slow down or swap." ;;
  esac
  printf ' %s GB is this Mac'"'"'s Best tier: omacvm resources --vm "%s" --resources best\n' "$best" "$3"
}

# Which Omarchy a new VM gets: Omarchy 4.5 on Omarchy's own aarch64 repos
# (guest/omarchy-move.sh), the same rule as app/scripts/vm-common.sh. Tests
# only: OMACVM_TEST_OMARCHY=4.0 builds omarchy-mac 4.0 as before 3.4.0 (the
# move matrix's 4.0 bases), OMACVM_TEST_OMARCHY_CHANNEL another of 4.5's
# channels (rc, edge).
omarchy_route() { [[ ${OMACVM_TEST_OMARCHY:-} == 4.0 ]] && echo 4.0 || echo 4.5; }
omarchy45_channel() {
  case ${OMACVM_TEST_OMARCHY_CHANNEL:-stable} in stable|rc|edge) echo "${OMACVM_TEST_OMARCHY_CHANNEL:-stable}" ;; *) echo stable ;; esac
}

