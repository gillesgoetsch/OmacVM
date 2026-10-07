# Progress for OmacVM.app from pacman's output, in the VM. create-vm.sh sends
# this file in front of base-install.sh and omarchy-install.sh (one "bash -s").
#
# pac_progress FILE: reads pacman/pacstrap output on stdin. Each line goes to
# FILE as it is, and to stdout as "| line" (the app's details view; vm-common.sh
# run_logged keeps these out of the app's step text). "==>" lines go through
# plain. pacman's own lines become one JSON line each for the app:
#   {"omacvm_progress": 1, "phase": "download", "now": "hyprland", "n": 14, "of": 190, "done": B, "total": B}
#   {"omacvm_progress": 1, "phase": "install", "now": "gum", "n": 3, "of": 190}
# "OMACVM_CACHE <bytes>" lines (from cache_watch) are the package cache's size:
# the download's bytes so far count from the size it had when the download began.
pac_progress() {
  LC_ALL=C awk -v raw="$1" '
    function j(s) { gsub(/[^A-Za-z0-9._+@:-]/, "", s); return substr(s, 1, 60) }
    function mib(v, u) { v += 0; if (u == "KiB") return v * 1024; if (u == "GiB") return v * 1073741824; if (u == "B") return v; return v * 1048576 }
    function emit(ph, now) {
      printf "{\"omacvm_progress\": 1, \"phase\": \"%s\", \"now\": \"%s\", \"n\": %d, \"of\": %d", ph, j(now), (ph == "download" ? dl : inst), of
      # Bytes only once the cache grows (pacman may download into another cache: then the count alone).
      if (ph == "download" && total > 0 && cache > base) printf ", \"done\": %.0f, \"total\": %.0f", (cache > base ? cache - base : 0), total
      print "}"; fflush()
    }
    { gsub(/\033\[[0-9;]*[A-Za-z]/, "") }
    /^OMACVM_CACHE [0-9]+$/ { cache = $2 + 0; if (phase == "download") emit("download", last); next }
    { print > raw; fflush(raw) }
    /^==> / { print; fflush(); next }       # to the app and the log as it is
    { print "| " $0; fflush() }
    # "Packages (190) ..." or, with VerbosePkgLists, "Package (190)  New Version ..."
    /^Packages? \([0-9]+\)/ { s = $0; sub(/^Packages? \(/, "", s); sub(/\).*/, "", s); of = s + 0; dl = 0; inst = 0; total = 0; phase = ""; last = ""; next }
    /^:: Synchronizing package databases/ { of = 0; phase = ""; next }
    /^checking keyring|^:: Processing package changes/ { phase = ""; next }
    /^Total Download Size:/ { total = mib($4, $5); base = cache; next }
    /^:: Retrieving packages/ { phase = "download"; base = cache; next }
    / downloading\.\.\.$/ {
      if (of == 0) next                       # package databases, not packages
      name = $1; sub(/\.pkg\.tar.*$/, "", name)
      # name-version-release-arch: the name only
      n = split(name, p, "-"); if (n > 3) { name = p[1]; for (i = 2; i <= n - 3; i++) name = name "-" p[i] }
      dl++; last = name; phase = "download"; emit("download", name); next
    }
    /^(installing|upgrading|reinstalling|downgrading) .*\.\.\.$/ {
      name = $2; sub(/\.\.\.$/, "", name)
      inst++; last = name; phase = "install"; emit("install", name); next
    }
  '
}

# cache_watch DIR...: the size of the package caches, every 2 seconds, as
# "OMACVM_CACHE <bytes>" lines, until killed or the script ($$) is gone.
cache_watch() {
  while kill -0 $$ 2>/dev/null; do
    printf 'OMACVM_CACHE %s\n' "$(du -sb "$@" 2>/dev/null | awk '{ s += $1 } END { printf "%.0f", s }')"
    sleep 2
  done
}
