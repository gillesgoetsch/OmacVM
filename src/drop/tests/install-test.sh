#!/bin/bash
# drag-drop's VM step without a VM: src/drop/guest/install.sh on, --status,
# off, with every path under a scratch folder (OMACVM_DROP_ROOT) and the
# compiler, wayland-scanner, pkg-config, systemctl and udevadm as stand-ins
# that log their calls.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
t=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-drop-install.XXXXXX")
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/root"
for tool in systemctl udevadm; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$tool" "$t" > "$t/bin/$tool"
done
printf '#!/bin/sh\necho "wayland-scanner $*" >> "%s/calls"; : > "$3"\n' "$t" > "$t/bin/wayland-scanner"
printf '#!/bin/sh\necho "-lwayland-client"\n' > "$t/bin/pkg-config"
# The compiler: the -o file, executable.
cat > "$t/bin/cc" <<EOS
#!/bin/sh
echo "cc \$*" >> "$t/calls"
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { printf '#!/bin/sh\necho app\n' > "\$2"; chmod +x "\$2"; }; shift; done
EOS
chmod +x "$t/bin/"*
export PATH="$t/bin:$PATH" OMACVM_DROP_ROOT="$t/root"
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: wanted [$2], got [$3]"; fail=1; fi; }
I="$here/../guest/install.sh"
expect "status before: off" "off" "$("$I" omtest --status | cut -d' ' -f1)"
"$I" omtest on > "$t/out" 2>&1 || { cat "$t/out"; fail=1; }
expect "on: helper built" "yes" "$([[ -x $t/root/usr/local/lib/omacvm/omacvm-drop-at ]] && echo yes)"
expect "on: built with -Wall against both protocols" "1" "$(grep -c '^cc .*-Wall.*omacvm-drop-at.c' "$t/calls")"
expect "on: status ok" "ok" "$("$I" omtest --status | cut -d' ' -f1)"
expect "on: service, share unit, rule, scripts" "4" "$(ls "$t/root/etc/systemd/user/omacvm-drop.service" "$t/root/etc/systemd/system/omacvm-drop-share.service" "$t/root/etc/udev/rules.d/70-omacvm-drop.rules" "$t/root/usr/local/bin/omacvm-drop" 2>/dev/null | wc -l | tr -d ' ')"
expect "on: user service enabled for every user" "1" "$(grep -c '^systemctl --global enable omacvm-drop.service' "$t/calls")"
: > "$t/calls"
"$I" omtest on > /dev/null 2>&1
expect "on again: not built again (idempotent)" "0" "$(grep -c '^cc ' "$t/calls" || true)"
sed -i.bak 's/^source .*/source 0000/' "$t/root/usr/local/lib/omacvm/omacvm-drop-at.build"
expect "older helper: status needed" "needed" "$("$I" omtest --status | cut -d' ' -f1)"
"$I" omtest off > /dev/null 2>&1
expect "off: status off" "off" "$("$I" omtest --status | cut -d' ' -f1)"
expect "off: nothing left" "" "$(cd "$t/root" && find . -type f ! -name '*.bak' | sort | tr '\n' ' ')"
"$I" omtest off > /dev/null 2>&1 && echo "ok   off again: silent" || { echo "FAIL off again"; fail=1; }
exit $fail
