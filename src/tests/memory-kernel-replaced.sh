#!/bin/bash
# The memory step (src/memory/guest/install.sh) on a VM whose kernel was
# replaced since it started (the move to Omarchy 4.5): sysctl --system fails
# on settings of modules that kernel can no longer load; that is not a
# failure of the step (they apply after the restart). With the running
# kernel's modules there, a sysctl failure still is. Stand-ins for install,
# sysctl, uname and systemd-tmpfiles; nothing is written outside a scratch folder.
#   src/tests/memory-kernel-replaced.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
B=$T/bin; mkdir -p "$B" "$T/modules/7.2.11-1-aarch64-ARCH/kernel"
printf '#!/bin/bash\necho "install $*" >> "%s/calls"\n' "$T" > "$B/install"
printf '#!/bin/bash\necho "systemd-tmpfiles $*" >> "%s/calls"\n' "$T" > "$B/systemd-tmpfiles"
printf '#!/bin/bash\necho 7.2.8-1-aarch64-ARCH\n' > "$B/uname"
cat > "$B/sysctl" <<'EOF'
#!/bin/bash
echo "sysctl $*" >> "$T/calls"
[[ -n ${SYSCTL_FAILS:-} ]] || exit 0
echo 'sysctl: setting key "net.core.default_qdisc": No such file or directory' >&2; exit 1
EOF
chmod 755 "$B"/*
export T
m() { PATH="$B:$PATH" OMACVM_MODULES_DIR=$T/modules bash "$R/src/memory/guest/install.sh" > "$T/out" 2>&1; echo $?; }
expect "sysctl fine: done" 0 "$(m)"
expect "the running kernel's modules gone, a module's setting fails: done, the line says a restart applies it" "0 1" \
  "$(SYSCTL_FAILS=1 m) $(grep -c 'apply after a restart' "$T/out")"
mkdir -p "$T/modules/7.2.8-1-aarch64-ARCH/kernel"
expect "the running kernel's modules there: a sysctl failure fails the step" 1 "$(SYSCTL_FAILS=1 m)"
exit $fail
