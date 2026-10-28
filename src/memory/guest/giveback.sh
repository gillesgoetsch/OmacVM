#!/bin/sh
# OmacVM.app: gives the VM's cold file cache back to the Mac (ADR 0059).
# The app runs this from its own bundle through the guest agent, as root:
#   /bin/sh -c "$(cat giveback.sh)" giveback compressing|report
# compressing: macOS is compressing the VM; report: numbers only.
# Prints one line of key=value (sizes in MB).
# Takes only file cache that was not used lately (memory.reclaim with
# swappiness=0, oldest first), all but the newest min(1 GB, an eighth of the
# VM): files read in the last minutes stay. Never programs' memory, zram, swap,
# compaction or the balloon. Linux reports the freed pages to QEMU, which
# gives them back to the Mac (free page reporting).
R=${OMACVM_GIVEBACK_ROOT:-}   # tests: a fake /proc and /sys
P=${OMACVM_GIVEBACK_PAUSE:-1}
mode=${1:-report}
export LC_ALL=C
mb() { awk -v k="$1:" '$1 == k { print int($2 / 1024); f = 1; exit } END { if (!f) print 0 }' "$R/proc/meminfo"; }
cache() { echo $(( $(mb 'Active(file)') + $(mb 'Inactive(file)') )); }
order=$(cat "$R/sys/module/page_reporting/parameters/page_reporting_order" 2>/dev/null)
case $order in ''|-*|*[!0-9]*|4294967295) order=-1 ;; esac
rep=0
for f in "$R"/sys/bus/virtio/drivers/virtio_balloon/virtio*/features; do
  [ "$(cut -c6 "$f" 2>/dev/null)" = 1 ] && rep=1   # bit 5: VIRTIO_BALLOON_F_REPORTING
done
[ "$order" = -1 ] && rep=0
small() {   # free memory in blocks too small for free page reporting
  o=$order; [ "$o" -ge 0 ] || o=9
  awk -v o="$o" -v p="$(getconf PAGESIZE 2>/dev/null || echo 4096)" '
    /zone/ { for (i = 5; i <= NF && i - 5 < o; i++) s += $i * 2 ^ (i - 5) }
    END { print int(s * p / 1048576) }' "$R/proc/buddyinfo" 2>/dev/null
}
total=$(mb MemTotal); inact=$(mb 'Inactive(file)'); before=$(cache)
t0=$(date +%s); act=$mode; want=0; steps=0
case $mode in compressing|report) ;; *) echo "act=usage"; exit 2 ;; esac
if [ "$mode" = compressing ]; then
  keep=$(( total / 8 )); [ "$keep" -le 1024 ] || keep=1024   # the newest cold cache stays
  want=$(( inact - keep )); [ "$want" -ge 0 ] || want=0
  if [ "$rep" = 0 ]; then act=norep
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
      [ $(( $(date +%s) - t0 )) -lt 20 ] || break
      [ "$left" -le 0 ] || sleep "$P"
    done
    # No cold-only way: the whole cache, as at macOS's memory warning.
    [ "$act" = refused ] && sync && echo 1 > "$R/proc/sys/vm/drop_caches" && act=drop
  fi
fi
after=$(cache); got=$(( before - after )); [ "$got" -ge 0 ] || got=0
echo "mode=$mode act=$act want_mb=$want got_mb=$got cache_mb=$before cache_after_mb=$after small_free_mb=$(small) total_mb=$total reporting=$rep order=$order steps=$steps secs=$(( $(date +%s) - t0 ))"
