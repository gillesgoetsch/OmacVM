#!/bin/sh
# OmacVM.app: gives the VM's cold file cache and its scattered free memory back
# to the Mac (ADR 0059). The app runs this from its own bundle through the
# guest agent, as root:
#   /bin/sh -c "$(cat giveback.sh)" giveback compressing|idle|compact|report
# compressing: macOS is compressing the VM. idle: the VM is quiet (the app saw
# QEMU use little CPU for a minute, macOS's pressure normal). compact: after
# macOS's warning made the VM drop its file cache, once the pressure is normal
# again and the VM quiet. report: numbers only.
# Prints one line of key=value for the app, at most 200 characters (sizes in MB).
# The cache: only file cache read once and not again (Linux's inactive file
# list; memory.reclaim with swappiness=0, oldest first), except the newest
# part, so the files read last stay: min(1 GB, an eighth of the VM) while
# macOS compresses, min(2 GB, a quarter) when idle. Never programs' memory,
# zram, swap or the balloon. The memory-optimized kernel (MGLRU) counts nearly
# all of its cache as inactive, so idle leaves its cache alone (act=mglru).
# Compaction (idle and compact): free page reporting hands only free blocks
# of page_reporting_order (256 KiB) and up to QEMU; free memory in smaller
# blocks stays on the Mac. compact_memory moves pages in use to join them, so
# it runs only when 256 MB or more is in such blocks and the VM does not wait
# for memory (PSI memory some avg10 <= 0.10), at most 10 s (SIGKILL stops
# it); never while macOS compresses the VM (moving pages makes macOS
# decompress them: not shown to be safe there, ADR 0059).
# The whole script stays under 25 s (the app waits 30 s), and only one runs at
# a time (flock): the VM goes on running it after the app stopped waiting.
# Linux reports the freed pages to QEMU (free page reporting); QEMU's reclaim
# fix gives them back to macOS.
R=${OMACVM_GIVEBACK_ROOT:-}   # tests: a fake /proc and /sys
P=${OMACVM_GIVEBACK_PAUSE:-1}
B=${OMACVM_GIVEBACK_BUDGET:-25}
mode=${1:-report}
export LC_ALL=C
mb() { awk -v k="$1:" '$1 == k { print int($2 / 1024); f = 1; exit } END { if (!f) print 0 }' "$R/proc/meminfo"; }
cache() { echo $(( $(mb 'Active(file)') + $(mb 'Inactive(file)') )); }
ms() { t=$(date +%s%N); case $t in *N) t=$(( $(date +%s) * 1000000000 )) ;; esac; echo $(( t / 1000000 )); }
avg10() { awk '$1 == "some" { for (i = 2; i <= NF; i++) if (sub(/^avg10=/, "", $i)) print $i + 0 }' "$R/proc/pressure/$1" 2>/dev/null; }
le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 <= b + 0) }'; }
pg=$(getconf PAGESIZE 2>/dev/null || echo 4096)
order=$(cat "$R/sys/module/page_reporting/parameters/page_reporting_order" 2>/dev/null)
case $order in ''|-*|*[!0-9]*|4294967295) order=-1 ;; esac
rep=0
for f in "$R"/sys/bus/virtio/drivers/virtio_balloon/virtio*/features; do
  [ "$(cut -c6 "$f" 2>/dev/null)" = 1 ] && rep=1   # bit 5: VIRTIO_BALLOON_F_REPORTING
done
[ "$order" = -1 ] && rep=0
small() {   # free memory in blocks too small for free page reporting
  o=$order; [ "$o" -ge 0 ] || o=9
  awk -v o="$o" -v p="$pg" '
    /zone/ { for (i = 5; i <= NF && i - 5 < o; i++) s += $i * 2 ^ (i - 5) }
    END { print int(s * p / 1048576) }' "$R/proc/buddyinfo" 2>/dev/null
}
case $mode in compressing|idle|compact|report) ;; *) echo "act=usage"; exit 2 ;; esac
t0=$(ms); total=$(mb MemTotal); inact=$(mb 'Inactive(file)'); before=$(cache)
sf=$(small); sf=${sf:-0}; sfa=$sf; psi=$(avg10 memory); act=$mode; want=0; steps=0; cpt=skip; cms=0; lk=0
L=$R/run/omacvm-giveback.lock
if [ "$mode" != report ] && command -v flock >/dev/null 2>&1 && touch "$L" 2>/dev/null; then
  exec 9>>"$L"
  if flock -n 9; then lk=1; else act=locked; fi
fi
if [ "$rep" = 0 ] && [ "$act" != report ] && [ "$act" != locked ]; then act=norep
elif [ "$act" = compressing ] || [ "$act" = idle ]; then
  if [ "$mode" = idle ]; then keep=$(( total / 4 )); [ "$keep" -le 2048 ] || keep=2048
  else keep=$(( total / 8 )); [ "$keep" -le 1024 ] || keep=1024; fi   # the newest cold cache stays
  want=$(( inact - keep )); [ "$want" -ge 0 ] || want=0
  io=$(avg10 io)
  if [ "$mode" = idle ] && ! { le "${psi:-0}" 0.10 && le "${io:-0}" 1.00; }; then act=busy
  elif [ "$mode" = idle ] && case $(cat "$R/sys/kernel/mm/lru_gen/enabled" 2>/dev/null) in ''|0x0000) false ;; esac; then act=mglru
  elif [ "$want" -lt 64 ]; then act=none
  else
    act=reclaim; f=$R/sys/fs/cgroup/memory.reclaim; left=$want
    [ -f "$f" ] || act=refused
    while [ "$act" = reclaim ] && [ "$left" -gt 0 ]; do
      n=$left; [ "$n" -le 1024 ] || n=1024
      if ! err=$( { printf '%s swappiness=0' $(( n * 1048576 )) > "$f"; } 2>&1 ); then
        # The kernel does not know swappiness= (before Linux 6.11): EINVAL.
        case $err in *"nvalid argument"*) [ "$steps" -gt 0 ] || act=refused ;; esac
        break   # anything else (EAGAIN: nothing more it could take): stop
      fi
      steps=$(( steps + 1 )); left=$(( left - n ))
      [ $(( $(ms) - t0 )) -lt $(( (B - 5) * 1000 )) ] || break
      [ "$left" -le 0 ] || sleep "$P"
    done
    # No cold-only way: while macOS compresses, the whole cache, as at macOS's
    # warning; idle leaves it.
    [ "$act" = refused ] && [ "$mode" = compressing ] && sync && echo 1 > "$R/proc/sys/vm/drop_caches" && act=drop
  fi
fi
case $mode:$act in idle:reclaim|idle:none|idle:refused|idle:mglru|compact:compact)
  c=$(( B - ($(ms) - t0) / 1000 )); [ "$c" -le 10 ] || c=10
  if [ "$sf" -lt 256 ]; then cpt=small
  elif [ "$lk" = 0 ] || [ ! -e "$R/proc/sys/vm/compact_memory" ] || ! command -v timeout >/dev/null 2>&1; then cpt=no
  elif [ -z "$psi" ]; then cpt=nopsi
  elif ! le "$psi" 0.10; then cpt=busy
  elif [ "$c" -lt 2 ]; then cpt=time
  else
    c0=$(ms)
    timeout -s KILL "$c" sh -c 'echo 1 > "$1"' sh "$R/proc/sys/vm/compact_memory" 2>/dev/null
    case $? in 0) cpt=ran ;; 137) cpt=cap ;; *) cpt=fail ;; esac
    cms=$(( $(ms) - c0 )); sfa=$(small)
  fi ;;
esac
rf=$(awk -v p="$pg" '$1 == "workingset_refault_file" { print int($2 * p / 1048576) }' "$R/proc/vmstat" 2>/dev/null)
after=$(cache); got=$(( before - after )); [ "$got" -ge 0 ] || got=0
echo "mode=$mode act=$act want=$want got=$got cache=$before cache_to=$after small=$sf small_to=$sfa cpt=$cpt cpt_ms=$cms psi=${psi:-na} rf=${rf:-0} rep=$rep order=$order steps=$steps secs=$(( ($(ms) - t0) / 1000 ))"
