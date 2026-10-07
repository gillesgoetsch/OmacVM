#!/bin/bash
# OmacVM, guest side: the desktop user's default keyring, made as Omarchy's
# installer makes it (install/user/default-keyring.sh: "Default keyring", no
# password), so Chromium and other apps keep their secrets without asking
# "Choose password for new keyring" at their first start. A VM from a
# prebuilt image never ran that step for its user (the image's home has no
# keyrings: generalize.sh removes them).
#   guest/default-keyring.sh setup USER HOME   as root: makes it for a home
#       without a keyring of its own (Omarchy's script as the user when the VM
#       has it, else the same files), then restarts the user's gnome-keyring
#       if it runs; a home with its own keyrings is left alone
#   guest/default-keyring.sh status HOME       prints the default keyring's
#       name, or "none" (exit 1) when an app would be asked for a password
set -uo pipefail

# The keyring gnome-keyring takes as the default: the one named in "default",
# else "login". Empty when that keyring does not exist.
default_keyring() {   # HOME
  local d=$1/.local/share/keyrings n=login
  if [[ -s $d/default ]]; then n=$(head -1 "$d/default"); fi
  [[ $n =~ ^[A-Za-z0-9_.-]+$ && -f $d/$n.keyring ]] && echo "$n"
}

# Omarchy's install/user/default-keyring.sh (omarchy and omarchy-mac), for a
# VM without Omarchy's installer files.
OMARCHY_COPY='
KEYRING_DIR="$HOME/.local/share/keyrings"
KEYRING_FILE="$KEYRING_DIR/Default_keyring.keyring"
DEFAULT_FILE="$KEYRING_DIR/default"
mkdir -p "$KEYRING_DIR"
if [[ ! -f $KEYRING_FILE ]]; then
  cat > "$KEYRING_FILE" <<EOF
[keyring]
display-name=Default keyring
ctime=$(date +%s)
mtime=0
lock-on-idle=false
lock-after=false
EOF
fi
if [[ ! -f $DEFAULT_FILE ]]; then
  echo Default_keyring > "$DEFAULT_FILE"
fi
chmod 700 "$KEYRING_DIR"
chmod 600 "$KEYRING_FILE"
chmod 644 "$DEFAULT_FILE"
'

case ${1:-} in
  status)
    [[ -n ${2:-} ]] || { echo "usage: guest/default-keyring.sh status HOME" >&2; exit 2; }
    n=$(default_keyring "$2")
    if [[ -n $n ]]; then echo "$n"; else echo none; exit 1; fi ;;
  setup)
    U=${2:-}; H=${3:-}
    [[ -n $U && -d $H ]] || { echo "usage: guest/default-keyring.sh setup USER HOME" >&2; exit 2; }
    n=$(default_keyring "$H")
    if [[ -n $n ]]; then echo "kept ($n)"; exit 0; fi
    # Keyrings of the user's own (secrets in them): never switch the default away.
    for k in "$H"/.local/share/keyrings/*.keyring; do
      [[ -e $k && $(basename "$k") != Default_keyring.keyring ]] || continue
      echo "left alone: $H/.local/share/keyrings has keyrings but no default one"; exit 0
    done
    from=""
    for s in "${OMACVM_OMARCHY_DIR:-/usr/share/omarchy}" "$H/.local/share/omarchy"; do
      [[ -f $s/install/user/default-keyring.sh ]] || continue
      runuser -u "$U" -- env HOME="$H" bash "$s/install/user/default-keyring.sh" >/dev/null 2>&1 || true
      from="Omarchy's $s/install/user/default-keyring.sh"; break
    done
    if [[ -z $(default_keyring "$H") ]]; then
      from="OmacVM's copy of Omarchy's step"
      runuser -u "$U" -- env HOME="$H" bash -c "$OMARCHY_COPY" || true
    fi
    n=$(default_keyring "$H")
    [[ -n $n ]] || { echo "could not make it in $H/.local/share/keyrings" >&2; exit 1; }
    # A gnome-keyring that runs already (apply in a logged-in VM) does not take
    # a new default keyring: Chromium would still ask. It had no keyrings to
    # keep; stopped, it starts again on the next request (D-Bus) with this one.
    if pkill -u "$U" -x gnome-keyring-d 2>/dev/null; then from+="; gnome-keyring restarted"; fi
    echo "made ($n, $from)" ;;
  *) sed -n '8,13s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
