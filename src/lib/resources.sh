# A VM's CPUs and memory, read and changed from the Mac (sourced after mac.sh,
# vm.sh, setup.sh and vm/fusion.sh; bash 3.2). Each app keeps them in its own
# settings, read when the VM starts:
#   Parallels   prlctl set (Standard has no prlctl set: config.pvs while
#               unregistered)
#   UTM         System.CPUCount / System.MemorySize of config.plist (through
#               UTM's scripting while UTM runs: it keeps what it read)
#   Fusion      numvcpus / memsize of the .vmx
#   OmacVM.app  CPUS / MEM_MB of the VM folder's vm.env
#   res_get NAME TYPE            -> "CPUS MEMORY_MB"
#   res_set NAME TYPE CPUS MB    the VM must be stopped (OmacVM.app: not
#                                needed, the app reads vm.env at each start)

PVS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../vm" && pwd)/pvs.py

vmx_get() {   # <vmx> <key> -> its value
  awk -v k="$2" '$1 == k && $2 == "=" { v = $0; sub(/^[^=]*= *"?/, "", v); sub(/"$/, "", v); print v; exit }' "$1"
}

res_get() {   # NAME TYPE
  local b x d c="" m=""
  case $2 in
    parallels) b=$(vm_bundle "$1")
               c=$(python3 "$PVS" "$b/config.pvs" get Hardware/Cpu/Number 2>/dev/null)
               m=$(python3 "$PVS" "$b/config.pvs" get Hardware/Memory/RAM 2>/dev/null) ;;
    utm) b=$(utm_bundle "$1") || return 1
         c=$(plutil -extract System.CPUCount raw "$b/config.plist" 2>/dev/null)
         m=$(plutil -extract System.MemorySize raw "$b/config.plist" 2>/dev/null) ;;
    fusion) x=$(fusion_vmx "$1") || return 1
            c=$(vmx_get "$x" numvcpus); m=$(vmx_get "$x" memsize) ;;
    app) d=$(app_dir "$1") || return 1
         c=$(app_env "$d" CPUS); m=$(app_env "$d" MEM_MB) ;;
    *) return 1 ;;
  esac
  [[ $c =~ ^[0-9]+$ && $m =~ ^[0-9]+$ ]] || return 1
  echo "$c $m"
}

# The writers, one per settings file (also what the tests run on fixtures).
res_pvs_set() { python3 "$PVS" "$1" resources --cpus "$2" --memsize "$3"; }   # CONFIG.PVS CPUS MB

res_plist_set() {   # CONFIG.PLIST CPUS MB
  plutil -replace System.CPUCount -integer "$2" "$1" && plutil -replace System.MemorySize -integer "$3" "$1"
}

# Fusion takes the GPU's memory out of the VM's own (svga.graphicsMemoryKB):
# when it would no longer fit, it goes down to what omacvm build would give
# (a quarter, 1-8 GB) and RES_NOTE says so.
res_vmx_set() {   # VMX CPUS MB
  local g new
  vmx_set "$1" numvcpus "$2"
  vmx_set "$1" memsize "$3"
  g=$(vmx_get "$1" svga.graphicsMemoryKB)
  if [[ $g =~ ^[0-9]+$ ]] && (( g / 1024 >= $3 )); then
    new=$(( $3 / 1024 / 4 )); (( new > 8 )) && new=8; (( new < 1 )) && new=1
    vmx_set "$1" svga.graphicsMemoryKB $(( new * 1048576 ))
    [[ -n $(vmx_get "$1" vmotion.svga.graphicsMemoryKB) ]] && vmx_set "$1" vmotion.svga.graphicsMemoryKB $(( new * 1048576 ))
    RES_NOTE="graphics memory down to $new GB (part of the VM's memory)"
  fi
  return 0
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

# utm_set_resources NAME CPUS MB: through UTM's scripting, so the running UTM
# saves the change itself (the VM must be stopped).
utm_set_resources() {
  local out
  out=$(utm_osa \
    -e 'on run argv' \
    -e '  tell application "UTM"' \
    -e '    set vm to virtual machine named (item 1 of argv)' \
    -e '    copy (configuration of vm) to c' \
    -e '    set cpu cores of c to ((item 2 of argv) as integer)' \
    -e '    set memory of c to ((item 3 of argv) as integer)' \
    -e '    update configuration of vm with c' \
    -e '    copy (configuration of vm) to c2' \
    -e '    return ((cpu cores of c2) as text) & " " & ((memory of c2) as text)' \
    -e '  end tell' \
    -e 'end run' "$1" "$2" "$3")
  [[ $out == "$2 $3" ]] || { echo "UTM: $out" >&2; return 1; }
}

res_set() {   # NAME TYPE CPUS MB (Parallels: P_EDITION from parallels_limits)
  local b d x err
  RES_NOTE=""
  case $2 in
    parallels)
      err=$("$PRLCTL" set "$1" --cpus "$3" --memsize "$4" 2>&1 >/dev/null) || {
        # Parallels Desktop Standard has no prlctl set: the settings file,
        # while Parallels does not hold the VM (as omacvm build does). Other
        # editions have it, so their error is the real one.
        [[ ${P_EDITION:-} == standard ]] || { echo "Parallels: ${err:-prlctl set failed}" >&2; return 1; }
        b=$(vm_bundle "$1")
        [[ -f $b/config.pvs ]] || return 1
        "$PRLCTL" unregister "$1" >/dev/null || return 1
        res_pvs_set "$b/config.pvs" "$3" "$4" || { "$PRLCTL" register "$b" >/dev/null; return 1; }
        "$PRLCTL" register "$b" >/dev/null || die "Parallels did not take '$1' back: prlctl register $(printf %q "$b")"
      } ;;
    utm)
      if pgrep -xq UTM; then utm_set_resources "$1" "$3" "$4" || return 1
      else b=$(utm_bundle "$1") && res_plist_set "$b/config.plist" "$3" "$4" || return 1; fi ;;
    fusion) x=$(fusion_vmx "$1") && res_vmx_set "$x" "$3" "$4" || return 1 ;;
    app) d=$(app_dir "$1") && res_env_set "$d/vm.env" "$3" "$4" || return 1 ;;
    *) return 1 ;;
  esac
  [[ $(res_get "$1" "$2") == "$3 $4" ]]
}
