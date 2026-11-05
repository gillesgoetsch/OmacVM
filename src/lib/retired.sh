# Parallels, UTM and VMware Fusion VMs that OmacVM set up on this Mac before
# 3.4.0 (sourced by vm.sh; bash 3.2). OmacVM 3.4.0 retired those routes: it
# lists such a VM and says so, and never changes, starts or reaches it (no SSH,
# no prlctl, utmctl or vmrun call but a listing, no read of UTM's container).
# Never added back without the owner's explicit consent (AGENTS.md).
#   retired_list              NAME<TAB>parallels|utm|fusion<TAB>retired, one per VM
#   route_retired TYPE        true for parallels, utm and fusion
#   retired_message NAME TYPE the one text for such a VM
#   retired_stop NAME TYPE    that text (JSON with JSON=1) and exit 3
# Test: src/tests/retired-routes.sh

RETIRED_IN=3.4.0
RETIRED_URL=https://github.com/gillesgoetsch/omacvm#retired-routes

route_retired() { case $1 in parallels|utm|fusion) return 0 ;; esac; return 1; }

retired_name() {   # TYPE -> how the person knows that app
  case $1 in parallels) echo Parallels ;; utm) echo UTM ;; fusion) echo "VMware Fusion" ;; *) echo "$1" ;; esac
}

retired_message() {   # NAME TYPE
  printf "'%s' is a %s VM. OmacVM %s retired Parallels, UTM and VMware Fusion: OmacVM no longer changes or updates this VM, and nothing in it was changed; it keeps running as it is. To stay up to date, move to OmacVM.app: omacvm build makes a new VM there, then copy your files over. How: %s" \
    "$1" "$(retired_name "$2")" "$RETIRED_IN" "$RETIRED_URL"
}

retired_json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/}
  printf '"%s"' "$s"
}

retired_stop() {   # NAME TYPE: exit 3 (a person decides: move to OmacVM.app)
  local m; m=$(retired_message "$1" "$2")
  if [[ ${JSON:-0} == 1 ]]; then
    printf '{"error": "route-retired", "route": "%s", "vm": %s, "retired_in": "%s", "message": %s}\n' \
      "$2" "$(retired_json_str "$1")" "$RETIRED_IN" "$(retired_json_str "$m")"
  else
    echo "omacvm: $m" >&2
  fi
  exit 3
}

# retired_pinned TYPE NAME: OmacVM set this VM up here (it remembered the VM's
# SSH host key; the same file name as vm_pin's).
retired_pinned() {
  [[ -f "$OMA_PINS/$1-$(printf %s "$2" | tr -c 'A-Za-z0-9._-' _)-$(printf %s "$2" | cksum | cut -d' ' -f1)" ]]
}

retired_list() {
  # The test identity has only its own app's VMs.
  [[ ${OMACVM_TEST_IDENTITY:-} == 1 ]] && return 0
  local prl=${PRLCTL:-/usr/local/bin/prlctl} n h x
  # A subshell without set -e and pipefail: a VM app that is not there (a
  # failed glob, no file) is an empty list, not the end of the caller.
  ( set +e +o pipefail
  {
    # Parallels: its own list (names only); a VM OmacVM set up (its pin) or built (its description).
    if [[ -x $prl ]]; then
      "$prl" list -a -o name 2>/dev/null | sed 1d | sed 's/[[:space:]]*$//' | while IFS= read -r n; do
        [[ -n $n ]] || continue
        if ! retired_pinned parallels "$n"; then
          h=$("$prl" list -a -i "$n" 2>/dev/null | sed -n 's/^Home: \(.*\)$/\1/p' | head -1)
          grep -q "built by OmacVM" "${h%/}/config.pvs" 2>/dev/null || continue
        fi
        printf '%s\tparallels\tretired\n' "$n"
      done
    fi
    # VMware Fusion: its library file and the folder omacvm build used; a pin or OmacVM's mark in the .vmx.
    {
      sed -n 's/^vmlist[0-9]*\.config = "\(.*\.vmx\)"$/\1/p' "$HOME/Library/Application Support/VMware Fusion/vmInventory" 2>/dev/null
      for x in "$HOME/Virtual Machines.localized"/*.vmwarevm/*.vmx; do [[ -f $x ]] && echo "$x"; done
    } | awk '!seen[$0]++' | while IFS= read -r x; do
      [[ -f $x ]] || continue
      n=$(sed -n 's/^displayName = "\(.*\)"$/\1/p' "$x" | head -1); n=${n:-$(basename "$x" .vmx)}
      retired_pinned fusion "$n" || grep -q "built by OmacVM" "$x" 2>/dev/null || continue
      printf '%s\tfusion\tretired\n' "$n"
    done
    # UTM: the names OmacVM saw (its own file; UTM's data is never read), with a pin.
    while IFS= read -r n; do
      [[ -n $n ]] && retired_pinned utm "$n" && printf '%s\tutm\tretired\n' "$n"
    done < <(cat "$OMA_SUPPORT/utm-vms" 2>/dev/null)
  } | awk -F'\t' '!seen[$1 FS $2]++' )
  return 0
}

retired_build_message() {
  printf 'OmacVM %s retired Parallels, UTM and VMware Fusion: omacvm build makes OmacVM.app VMs (--vm-type app). How to move: %s' \
    "$RETIRED_IN" "$RETIRED_URL"
}
