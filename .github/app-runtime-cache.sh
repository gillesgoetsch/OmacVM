#!/bin/bash
# CI's QEMU runtime cache on the self-hosted Mac mini, so the app job runs
# build-app.sh in minutes instead of building QEMU and its firmware each time.
# One folder per inputs hash (build-app.sh --runtime-inputs): only what
# build-app.sh takes from runtime/.build (qemu-gpu-runtime, firmware,
# inputs.sha256), never the edk2 build folder. The newest KEEP stay.
#   .github/app-runtime-cache.sh restore BUILD_DIR KEY   prints hit or miss
#   .github/app-runtime-cache.sh save BUILD_DIR          prints saved, have or skip
# OMACVM_CI_RUNTIME_CACHE: the cache folder (required). OMACVM_CI_RUNTIME_KEEP: 3.
# A miss leaves BUILD_DIR alone: build-app.sh builds the runtime, save keeps it.
set -euo pipefail
CACHE=${OMACVM_CI_RUNTIME_CACHE:?set OMACVM_CI_RUNTIME_CACHE}
KEEP=${OMACVM_CI_RUNTIME_KEEP:-3}
[[ $KEEP =~ ^[1-9][0-9]?$ ]] || { echo "OMACVM_CI_RUNTIME_KEEP is 1-99" >&2; exit 2; }
key_ok() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

# A runtime build-app.sh would take as it is: QEMU, the firmware, the inputs
# hash, no test hooks (a runtime with them is never shipped, so never cached).
complete() {   # DIR [KEY]
  [[ -x $1/qemu-gpu-runtime/bin/qemu-system-aarch64 && -f $1/firmware/edk2-aarch64-code.fd
     && -f $1/inputs.sha256 && ! -e $1/qemu-gpu-runtime.test-hooks ]] || return 1
  [[ -z ${2:-} || $(cat "$1/inputs.sha256") == "$2" ]]
}

case ${1:-} in
  restore)
    (( $# == 3 )) || { echo "usage: app-runtime-cache.sh restore BUILD_DIR KEY" >&2; exit 2; }
    dir=$2 key=$3
    key_ok "$key" || { echo "not an inputs hash: $key" >&2; exit 2; }
    if [[ -e $dir ]]; then echo "miss ($dir is there already)"; exit 0; fi
    if ! complete "$CACHE/$key" "$key"; then echo miss; exit 0; fi
    mkdir -p "$(dirname "$dir")" "$dir"
    # cp -c: a clone on APFS, no copy of the bytes.
    for p in qemu-gpu-runtime firmware inputs.sha256; do cp -cR "$CACHE/$key/$p" "$dir/"; done
    touch "$CACHE/$key"   # the newest used stays longest
    echo hit
    ;;
  save)
    (( $# == 2 )) || { echo "usage: app-runtime-cache.sh save BUILD_DIR" >&2; exit 2; }
    dir=$2
    if ! complete "$dir"; then echo "skip (no complete runtime in $dir)"; exit 0; fi
    key=$(cat "$dir/inputs.sha256")
    key_ok "$key" || { echo "skip ($dir/inputs.sha256 is not a hash)"; exit 0; }
    mkdir -p "$CACHE"
    if [[ -d $CACHE/$key ]]; then touch "$CACHE/$key"; echo have
    else
      # Put together beside it, then one rename: the other runner never sees half.
      t=$(mktemp -d "$CACHE/.new.XXXXXX")
      trap 'rm -rf "$t"' EXIT
      for p in qemu-gpu-runtime firmware inputs.sha256; do cp -cR "$dir/$p" "$t/"; done
      mv "$t" "$CACHE/$key" 2>/dev/null || true
      # The other runner saved the same key first: mv put ours inside theirs.
      rm -rf "${CACHE:?}/$key/${t##*/}"
      if complete "$CACHE/$key" "$key"; then echo saved; else echo "skip (not saved)"; fi
    fi
    # The oldest go (and leftovers of a save that was stopped).
    find "$CACHE" -mindepth 1 -maxdepth 1 -name '.new.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
    n=0
    while IFS= read -r e; do
      n=$((n + 1))
      if (( n > KEEP )); then rm -rf "${CACHE:?}/$e"; fi
    done < <(ls -t "$CACHE" | grep -E '^[0-9a-f]{64}$' || true)
    ;;
  *) echo "usage: app-runtime-cache.sh restore BUILD_DIR KEY | save BUILD_DIR" >&2; exit 2 ;;
esac
