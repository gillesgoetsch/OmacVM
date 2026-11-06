#!/bin/bash
# OmacVM is OmacVM.app only since 3.4.0: Parallels, UTM and VMware Fusion are
# retired and come back only with the owner's explicit consent (AGENTS.md).
# This keeps them out: no tracked file names them (whole words), except the
# files and lines below, each with its reason (a line that says a route is
# retired is listed too, by its own text). Changing this list is changing
# that rule: say so in the PR.
#   src/tests/no-retired-routes.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
cd "$R" || exit 1
WORDS='\b(parallels|prlctl|prl_[a-z]+|utm|utmctl|vmware|vmrun|vmwgfx|vmx|open-vm-tools|spice-vdagent|vdagent|fusion)\b'

# PATH<TAB>TEXT<TAB>WHY: a hit in PATH (a folder when it ends in /) is allowed
# when its line contains TEXT ("*": any line of it).
ALLOW='CHANGELOG.md	*	the history
docs/adr/	*	decisions as they were made (ADR 0071 records the retirement)
app/runtime/patches/	*	QEMU patches: their text is the runtime cache key
src/lib/retired.sh	*	the retired helper: lists and refuses those VMs
src/bridge/mac/retired.swift	*	the Bridge on those routes'"'"' addresses: the move text only
src/bridge/mac/tests/retired/	*	its test and the 3.3.0 guest clients it runs (byte copies)
src/tests/retired-routes.sh	*	stand-ins for the retired apps
src/tests/no-retired-routes.sh	*	this list
src/control/vendor/	*	third-party wheels
THIRD_PARTY_NOTICES.md	UTM	QEMU'"'"'s cocoa code adapted from UTM (Apache-2.0)
app/THIRD_PARTY_NOTICES.md	UTM	QEMU'"'"'s cocoa code adapted from UTM (Apache-2.0)
README.md	<a name="four-ways-parallels-utm-vmware-fusion-or-omacvmapp">	the retired-routes section'"'"'s old anchor
README.md	## Coming from Parallels, UTM or VMware Fusion?	the retired-routes section
README.md	battery (UTM, VMware Fusion); Touch ID asks for the password	the retired-routes section: what stops for such a VM
README.md	[UTM](https://github.com/utmapp/UTM)	credit: QEMU'"'"'s cocoa code from UTM
docs/benchmarks/README.md	Older rounds that also measured Parallels,	the pointer to v3.3.0'"'"'s rounds
docs/troubleshooting.md	<a name="22-parallels-fusion-app-the-microphone-records-nothing-or-silence">	an old anchor that links still use
docs/experiments/trackpad-scrolling.md	*	the record of an experiment, as it was run
app/README.md	No Parallels, UTM or	OmacVM.app: no change for the sunset
app/README.md	VMware Fusion: the app brings its own QEMU	OmacVM.app: no change for the sunset
app/app/OmacVMBridge.entitlements	the camera for UTM and Fusion VMs	OmacVM.app: no change for the sunset (the key goes later)
app/app/Sources/OmacVM/EscapeSetting.swift	(Parallels, UTM, Fusion) too	OmacVM.app: no change for the sunset
app/app/Sources/OmacVM/RenderVMWindow.swift	UTM, Fusion and Parallels: nothing changes.	OmacVM.app: no change for the sunset
app/app/Sources/OmacVM/SettingsRows.swift	(as Parallels and UTM)	OmacVM.app: no change for the sunset
src/control/omacvm_cc/report.py	mac-parallels	problem reports: old addresses redacted
src/control/omacvm_cc/report.py	"parallels", "utm", "fusion", "vmware"	problem reports: product words kept
src/control/omacvm_cc/report.py	Parallels writes MACs	problem reports: MAC addresses redacted
src/control/tests/test_report.py	<mac-parallels>	problem reports: old addresses redacted
src/control/tests/test_report.py	Parallels-Mac	problem reports: product words kept
src/control/tests/test_report.py	Parallels Desktop'"'"'s Tools	problem reports: product words kept
src/net/mac/omacvm-netd.c	what Parallels and UTM use	other apps on this Mac use vmnet too
src/net/mac/omacvm-netd.c	while UTM (or another app)	other apps on this Mac use vmnet too
src/net/mac/omacvm-netd.c	so Parallels'"'"' and other VM networks	other apps on this Mac use vmnet too
src/net/mac/test-netd.c	bridges (Parallels, other VM networks)	other apps on this Mac use vmnet too
src/net/mac/test-netd.c	Parallels'"'"' bridge, the fast network'"'"'s bridge	other apps on this Mac use vmnet too
src/guest/omacvm_vm.lua	(OmacVM.app, UTM, Parallels, VMware Fusion)	in the VM: a change reloads Hyprland
src/guest/omacvm_vm.lua	virtio-gpu'"'"'s plane (OmacVM.app, UTM,	in the VM: a change reloads Hyprland
src/guest/omacvm_vm.lua	-- Parallels) takes XRGB8888 only	in the VM: a change reloads Hyprland
src/omanotch/guest/hypr/notchbar.lua	(the Parallels mouse,	in the VM: a change reloads Hyprland
src/omanotch/guest/hypr/notchbar.lua	UTM'"'"'s USB tablet)	in the VM: a change reloads Hyprland
src/workspaces/guest/monitor_workspaces.lua	(Parallels, Fusion	in the VM: a change reloads Hyprland
src/keyboard/guest/mac-paste.lua	with a Mac keyboard in Parallels	in the VM: a change reloads Hyprland
src/memory/guest/90-omacvm.sysctl	memory tuning for a Parallels guest	in the VM: a change reapplies the settings
src/memory/guest/90-omacvm-zram.conf	Parallels, UTM and Fusion keep every page	in the VM: a change restarts zram
.claude/skills/omacvm/SKILL.md	- A retired Parallels, UTM or VMware Fusion VM (`"retired": true` in `vms	says it is retired
.github/workflows/check.yml	- name: Retired Parallels, UTM and VMware Fusion VMs are listed and refused, never touched	says it is retired
AGENTS.md	- OmacVM is OmacVM.app only. Parallels, UTM and VMware Fusion were retired in	says it is retired
AGENTS.md	- **A Parallels, UTM or VMware Fusion VM** (retired in 3.4.0): `omacvm vms`	says it is retired
AGENTS.md	| `src/lib/retired.sh` | The retired Parallels, UTM and VMware Fusion VMs (3.4.0): `retired_list`	says it is retired
AGENTS.md	--full-name --hostname` (`--vm-type parallels|utm|fusion`: exit 2, retired), `--feature NAME=on|off`	says it is retired
AGENTS.md	Omanotch (uninstall also removes the retired Parallels clipboard helper `clip-in` of 3.3 and	says it is retired
CONTRIBUTING.md	OmacVM is OmacVM.app only. Parallels, UTM and VMware Fusion were retired in	says it is retired
docs/README.md	Parallels, UTM and VMware Fusion were retired in 3.4.0	says it is retired
docs/benchmarks/README.md	UTM and VMware Fusion (retired in 3.4.0) are in	says it is retired
docs/notes/findings.md	Parallels, UTM and VMware Fusion (retired in 3.4.0) are in	says it is retired
docs/troubleshooting.md	- **A VM in Parallels, UTM or VMware Fusion**: OmacVM 3.4.0 retired those	says it is retired
docs/troubleshooting.md	were about Parallels, UTM and VMware Fusion, retired in 3.4.0; they are in	says it is retired
src/battery/README.md	1.91.4, dkms 3.4.3: an OmacVM.app VM (and a retired UTM 5 VM through the Bridge)	says it is retired
src/bridge/README.md	Parallels, UTM and VMware Fusion were retired in OmacVM 3.4.0 (AGENTS.md).	says it is retired
src/bridge/mac/main.swift	// The Mac'"'"'s address on the retired Parallels, UTM and VMware Fusion networks	says it is retired
src/bridge/mac/test-retired.sh	*	the test of the Bridge on those routes'"'"' addresses
src/bridge/mac/tests/touchid_tests.swift	let retiredApps = ["Parallels Desktop.app/Contents/MacOS/prl_client_app", "UTM.app/Contents/MacOS/UTM",	says it is retired
src/cmd/apply.sh	# --reset-host-key forgets it (a rebuilt VM). A retired Parallels, UTM or	says it is retired
src/cmd/apply.sh	# VMware Fusion VM is not touched (exit 3, src/lib/retired.sh).	says it is retired
src/cmd/check.sh	# The retired routes'"'"' addresses (Parallels'"'"' and the others'"'"' networks, when up) get the	says it is retired
src/cmd/report.sh	# A retired Parallels, UTM or VMware Fusion VM (src/lib/retired.sh): exit 3,	says it is retired
src/cmd/update.sh	# A retired Parallels, UTM or VMware Fusion VM (src/lib/retired.sh) is never	says it is retired
src/cmd/update.sh	$RETIRED_IN no longer serve them: no Bridge bar items (Wi-Fi, Bluetooth, audio), media keys, wallpaper or time zone, no gestures or scroll momentum, no Omanotch, no camera and battery (UTM,	says it is retired
src/cmd/vms.sh	# retired Parallels, UTM and VMware Fusion VMs OmacVM set up here before 3.4.0	says it is retired
src/cmd/vms.sh	# type parallels|utm|fusion, state "retired", "retired": true, note "retired in 3.4.0".	says it is retired
src/gestures/mac/omacvm-gestures.c	// Parallels, UTM and VMware Fusion are retired (3.4.0): nothing listens on	says it is retired
src/gestures/mac/test-identity.c	const char *retiredApps[] = { "UTM", "prl_client_app", "VMware Fusion" }; int retiredOurs = 0;	says it is retired
src/guest/install.sh	# 3.4.0 retired Parallels, UTM and VMware Fusion.	says it is retired
src/guest/install.sh	echo "guest/install.sh: OmacVM 3.4.0 retired Parallels, UTM and VMware Fusion: --vm-type app	says it is retired
src/lib/vm.sh	#                            NAME<TAB>parallels|utm|fusion<TAB>retired (retired.sh)	says it is retired
src/lib/vm.sh	# cannot tell which VM ("soft": returns 1). A retired Parallels, UTM or	says it is retired
src/lib/vm.sh	# VMware Fusion VM: exit 3 with the text of retired.sh, nothing done to it.	says it is retired
src/lib/vm.sh	# vm_type NAME -> app, or parallels | utm | fusion for a retired VM. An	says it is retired
src/mac/uninstall.sh	# The clipboard helper of the retired Parallels route (OmacVM 3.3 and older).	says it is retired
src/omanotch/README.md	accepted only from that network. The retired Parallels, UTM and VMware Fusion networks are not	says it is retired
src/prebuilt/make-image.sh	parallels|utm|fusion) echo "make-image.sh: $(retired_build_message)" >&2; exit 2 ;;	says it is retired
src/tests/vm-names.sh	*	stand-ins: VM names beside retired ones'

# The docs (README.md, docs/, the chart and its test) are the docs PR's: until
# its ADR 0071 is in, they are 3.3's and not checked here.
DOCS=1
ls docs/adr/0071-*.md >/dev/null 2>&1 || { DOCS=0; echo "note README.md and docs/ not checked: their 3.4.0 version (ADR 0071) is not in this tree yet"; }

hits=$(git grep -n -I -i -P "$WORDS" -- . |
  ALLOW=$ALLOW DOCS=$DOCS awk '
    BEGIN { docs = ENVIRON["DOCS"] + 0; n = split(ENVIRON["ALLOW"], rows, "\n"); for (i = 1; i <= n; i++) { split(rows[i], f, "\t"); path[i] = f[1]; text[i] = f[2] } }
    {
      p = index($0, ":"); file = substr($0, 1, p - 1); rest = substr($0, p + 1)
      q = index(rest, ":"); line = substr(rest, q + 1)
      if (!docs && (file == "README.md" || file ~ /^docs\// || file == "src/bench/chart.py" || file == "src/tests/bench-docs.sh")) next
      for (i = 1; i <= n; i++) {
        inside = substr(path[i], length(path[i])) == "/" ? index(file, path[i]) == 1 : file == path[i]
        if (inside && (text[i] == "*" || index(line, text[i]))) next
      }
      print
    }')
if [[ -n $hits ]]; then
  echo "FAIL Parallels, UTM or VMware Fusion named outside the retired notes:"
  echo "$hits" | cut -c1-200 | head -400
  exit 1
fi
# Each allowed line is still there (a stale entry would allow too much later).
stale=$(printf '%s\n' "$ALLOW" | while IFS=$'\t' read -r p t _; do
  [[ $DOCS == 1 || ( $p != README.md && $p != docs/* ) ]] || continue
  if [[ $p == */ ]]; then [[ -d $p ]] || echo "$p"
  elif [[ ! -f $p ]]; then echo "$p"
  elif [[ $t != '*' ]] && ! grep -qF -- "$t" "$p"; then echo "$p: $t"; fi
done)
if [[ -n $stale ]]; then
  echo "FAIL allowed but no longer there (take it off the list):"
  echo "$stale"
  exit 1
fi
echo "ok   no retired route named outside the retired notes ($(printf '%s\n' "$ALLOW" | wc -l | tr -d ' ') allowed files and lines)"
