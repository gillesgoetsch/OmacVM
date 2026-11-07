# A VM's CPUs and memory, read and changed from the Mac (sourced after mac.sh,
# vm.sh and setup.sh; bash 3.2). OmacVM.app keeps them as CPUS / MEM_MB in the
# VM folder's vm.env, read when the VM starts:
#   res_get NAME TYPE            -> "CPUS MEMORY_MB"
#   res_set NAME TYPE CPUS MB    the VM need not be stopped: the app reads
#                                vm.env at each start

res_get() {   # NAME TYPE
  local d c="" m=""
  [[ $2 == app ]] || return 1
  d=$(app_dir "$1") || return 1
  c=$(app_env "$d" CPUS); m=$(app_env "$d" MEM_MB)
  [[ $c =~ ^[0-9]+$ && $m =~ ^[0-9]+$ ]] || return 1
  echo "$c $m"
}

res_env_set() {   # VM.ENV CPUS MB: those two lines, the rest as the app wrote it
  local tmp
  tmp=$(mktemp "$1.XXXXXX") || return 1
  awk -v c="$2" -v m="$3" '
    /^CPUS=/ { print "CPUS=" c; fc = 1; next }
    /^MEM_MB=/ { print "MEM_MB=" m; fm = 1; next }
    { print }
    END { if (!fc) print "CPUS=" c; if (!fm) print "MEM_MB=" m }' "$1" > "$tmp" && mv "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

res_set() {   # NAME TYPE CPUS MB
  local d
  RES_NOTE=""
  [[ $2 == app ]] || return 1
  d=$(app_dir "$1") && res_env_set "$d/vm.env" "$3" "$4" || return 1
  [[ $(res_get "$1" "$2") == "$3 $4" ]]
}
