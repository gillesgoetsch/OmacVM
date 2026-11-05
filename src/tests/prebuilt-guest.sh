#!/bin/bash
# The prebuilt image's guest pieces. (1) A VM from a prebuilt image makes its own pacman keyring (src/prebuilt/guest/
# pacman-keyring): generalize.sh takes the image's out, the first boot (or
# first-update, if that failed) makes a new one, --init, --populate, and signs
# Omarchy's package key; a key file is imported only when its one primary key
# is Omarchy's. Stand-in pacman-key (a folder of key files); real gpg for the
# fingerprint check (Linux CI's guest job; skipped where gpg is missing).
# (2) omarchy-version: the manifest's Omarchy line (stand-in pacman).
#   src/tests/prebuilt-guest.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
PKR=$R/src/prebuilt/guest/pacman-keyring
KEY=40DFB630FF42BCFFB047046CF0134EE680CAC571
fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# pacman-key stand-in: $G is the keyring (a folder), $T/pop the keys
# --populate brings, $T/calls what was asked.
G=$T/gnupg
cat > "$T/pacman-key" <<EOF
#!/bin/bash
echo "\$*" >> "$T/calls"
[[ -e $T/fail-\${1#--} ]] && exit 1
case \$1 in
  --init) mkdir -p "$G"; : > "$G/master" ;;
  --populate) [[ -d $G ]] || exit 1; for k in \$(cat "$T/pop" 2>/dev/null); do : > "$G/\$k"; done ;;
  --list-keys) [[ -e $G/\$2 ]] ;;
  --lsign-key) [[ -e $G/\$2 ]] && : > "$G/\$2.lsigned" ;;
  --add) [[ -d $G ]] && : > "$G/$KEY" ;;
esac
EOF
chmod +x "$T/pacman-key"
export OMACVM_PACMAN_KEY=$T/pacman-key OMACVM_GNUPG=$G OMACVM_SHARE=$T/share
P=$T/prebuilt; mkdir -p "$P" "$T/share/guest"
reset() { rm -rf "$G" "$P"/* "$T/calls" "$T"/fail-*; mkdir -p "$G"; : > "$G/old-master"; : > "$P/keyring"; echo "$1" > "$T/pop"; }

reset "archlinuxarm $KEY"
out=$("$PKR" "$P/keyring" 2>&1); rc=$?
[[ $rc == 0 && ! -e $G/old-master && -e $G/master && -e $G/$KEY.lsigned && ! -e $P/keyring &&
   $(tr '\n' ' ' < "$T/calls") == "--init --populate --list-keys $KEY --list-keys $KEY --lsign-key $KEY " ]] &&
  pass "4.5 image: a new keyring, populated, Omarchy's key signed, request gone" || bad "4.5 image: rc $rc, calls '$(tr '\n' ' ' < "$T/calls")', said '$out'"

reset archlinuxarm; rm -f "$P/keyring"
out=$("$PKR" "$P/keyring" 2>&1); rc=$?
[[ $rc == 0 && -e $G/old-master && ! -e $T/calls ]] && pass "no request: the keyring is left alone" || bad "no request: rc $rc, said '$out'"

reset archlinuxarm
out=$("$PKR" "$P/keyring" 2>&1); rc=$?
[[ $rc == 0 && ! -e $G/$KEY && ! -e $P/keyring && $out == *"no Omarchy key"* ]] &&
  pass "4.0 image without Omarchy's key and no key file: new keyring, said so" || bad "4.0, no key: rc $rc, said '$out'"

for step in init populate lsign-key; do
  reset "archlinuxarm $KEY"; : > "$T/fail-$step"
  out=$("$PKR" "$P/keyring" 2>&1); rc=$?
  [[ $rc == 1 && -e $P/keyring ]] && pass "pacman-key --$step fails: exit 1, the request stays (next run tries again)" ||
    bad "--$step fails: rc $rc, request $( [[ -e $P/keyring ]] && echo kept || echo gone), said '$out'"
done

if command -v gpg >/dev/null; then
  # Real keys: Omarchy's fingerprint cannot be made, so the test's own key
  # stands in for it (KEY read from a copy of the script).
  H=$T/gpghome; mkdir -m700 "$H"
  mk() { gpg --homedir "$H" --batch --passphrase '' --quick-gen-key "$1" ed25519 sign never >/dev/null 2>&1
         gpg --homedir "$H" --batch --with-colons --list-keys "$1" | awk -F: '$1 == "fpr" { print $10; exit }'; }
  A=$(mk "omarchy stand-in <a@example.org>"); B=$(mk "someone else <b@example.org>")
  sed "s/^KEY=.*/KEY=$A/" "$PKR" > "$T/pkr"; chmod +x "$T/pkr"
  sed -i.bak "s/$KEY/$A/g" "$T/pacman-key"
  gpg --homedir "$H" --batch --armor --export "$A" > "$T/a.asc"
  gpg --homedir "$H" --batch --armor --export "$B" > "$T/b.asc"
  gpg --homedir "$H" --batch --armor --export "$A" "$B" > "$T/ab.asc"
  for c in "a.asc|1|the image's exported key with Omarchy's fingerprint: imported, signed" \
           "b.asc|0|a key file with another key: not used" \
           "ab.asc|0|a key file with Omarchy's key and another: not used"; do
    IFS='|' read -r f want what <<<"$c"
    reset archlinuxarm; cp "$T/$f" "$P/omarchy-key.asc"
    out=$("$T/pkr" "$P/keyring" 2>&1); rc=$?
    got=0; [[ -e $G/$A.lsigned ]] && got=1
    [[ $rc == 0 && $got == "$want" ]] && pass "$what" || bad "$what: rc $rc, signed $got, said '$out'"
  done
  reset archlinuxarm; rm -f "$P/omarchy-key.asc"; cp "$T/a.asc" "$T/share/guest/omarchy-key.asc"
  out=$("$T/pkr" "$P/keyring" 2>&1); rc=$?
  [[ $rc == 0 && -e $G/$A.lsigned ]] && pass "OmacVM's own copy of the key (guest/omarchy-key.asc): imported, signed" ||
    bad "OmacVM's copy: rc $rc, said '$out'"
  rm -f "$T/share/guest/omarchy-key.asc"
else
  echo "skip key files: no gpg here (Linux CI runs them)"
fi

# The scripts that use it.
g=$R/src/prebuilt/guest
[[ $(grep -c 'rm -rf /etc/pacman.d/gnupg' "$g/generalize.sh") == 1 && $(grep -c ': > "$P/keyring"' "$g/generalize.sh") == 1 &&
   $(grep -c 'omacvm-pacman-keyring' "$g/generalize.sh") == 1 ]] &&
  pass "generalize.sh takes the keyring out, asks for a new one, installs pacman-keyring" || bad "generalize.sh: keyring lines missing"
[[ $(grep -c 'omacvm-pacman-keyring "$P/keyring"' "$g/omacvm-firstboot") == 1 ]] &&
  pass "the first boot makes the keyring" || bad "omacvm-firstboot: no pacman-keyring call"
# generalize.sh: the keyring goes after its last pacman call.
last_pacman=$(grep -n 'pacman -Scc' "$g/generalize.sh" | tail -1 | cut -d: -f1)
rm_line=$(grep -n 'rm -rf /etc/pacman.d/gnupg' "$g/generalize.sh" | cut -d: -f1)
(( rm_line > last_pacman )) && pass "generalize.sh: no pacman call after the keyring is gone" || bad "generalize.sh: pacman after the keyring reset"
# first boot: the keyring before the user (nothing installs a package before it).
kr=$(grep -n 'omacvm-pacman-keyring "$P/keyring"' "$g/omacvm-firstboot" | cut -d: -f1)
ua=$(grep -n '^useradd ' "$g/omacvm-firstboot" | cut -d: -f1)
(( kr < ua )) && pass "first boot: keyring before the user is made" || bad "first boot: keyring after useradd"
# omarchy-version: the manifest's "omarchy" line, which manifest.py fits reads.
OV=$R/src/prebuilt/guest/omarchy-version
mkdir -p "$T/bin" "$T/homes"
printf '#!/bin/bash\n[[ -f %s/pq ]] && cat %s/pq || exit 1\n' "$T" "$T" > "$T/bin/pacman"
printf '#!/bin/bash\necho aarch64\n' > "$T/bin/omarchy-hw-platform"; chmod +x "$T/bin/pacman" "$T/bin/omarchy-hw-platform"
printf '[omarchy]\nSigLevel = Required\nServer = https://pkgs.omarchy.org/stable/$arch\n' > "$T/pacman.conf"
ov() { PATH=$T/bin:$PATH OMACVM_PACMAN_CONF=$T/pacman.conf OMACVM_HOMES=$T/homes "$OV" u; }
echo "omarchy 4.5.0-3" > "$T/pq"
got=$(ov); [[ $got == "4.5.0 (aarch64 stable)" ]] && pass "omarchy-version: 4.5 from the package: '$got'" || bad "omarchy-version 4.5: '$got'"
python3 "$R/src/prebuilt/manifest.py" fits 3.4.0 "$got" && pass "that line fits a 3.4.0 app" || bad "'$got' does not fit 3.4.0"
echo "omarchy 1:4.10.2-1" > "$T/pq"; sed -i.bak 's#/stable/#/rc/#' "$T/pacman.conf"
got=$(ov); [[ $got == "4.10.2 (aarch64 rc)" ]] && pass "omarchy-version: epoch and pkgrel off, channel rc: '$got'" || bad "omarchy-version rc: '$got'"
rm -f "$T/pq"
got=$(ov); [[ $got == unknown ]] && pass "omarchy-version: no omarchy package: unknown (fits nothing from 3.4.0)" || bad "no package: '$got'"
if command -v git >/dev/null; then
  d=$T/homes/u/.local/share/omarchy; mkdir -p "$d"; echo 4.0.3rc4 > "$d/version"
  git -C "$d" init -q && git -C "$d" -c user.name=t -c user.email=t@t add version && git -C "$d" -c user.name=t -c user.email=t@t commit -qm v
  got=$(ov); [[ $got == "4.0.3rc4 (omarchy-mac $(git -C "$d" rev-parse --short HEAD))" ]] &&
    pass "omarchy-version: omarchy-mac 4.0 as before: '$got'" || bad "omarchy-mac: '$got'"
  python3 "$R/src/prebuilt/manifest.py" fits 3.4.0 "$got" && bad "an omarchy-mac line fits 3.4.0" || pass "an omarchy-mac line does not fit 3.4.0"
fi
[[ $(grep -c 'omacvm-prebuilt/omarchy-version' "$R/src/prebuilt/make-image.sh") == 1 ]] &&
  pass "make-image.sh takes the line from omarchy-version" || bad "make-image.sh does not use omarchy-version"
exit $fail
