#!/bin/bash
# Ctrl-C in omacvm build stops the step that runs with a spinner (waiting for
# SSH, for an IP address, ...) and everything it started. ui_spin runs the
# step as a background job, and a script's background jobs ignore Ctrl-C:
# without the exit cleanup it went on after the build had stopped. The same
# for the spinner line under a step's output (ui_follow).
# Driven through a terminal (a pty: ^C typed, the terminal sends SIGINT to the
# build's process group), with the spinner drawn and without (TERM=dumb).
# The real src/cmd/build.sh (from a checkout, which needs the Command Line
# Tools, so the Swift check runs) up to its first spinner step, whose command is a
# stand-in that only sleeps; no VM, nothing of this Mac's setup touched (its
# own HOME).
#   src/tests/build-ctrlc.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
T=$(mktemp -d)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"

expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The step: "Checking the Swift compiler" runs swiftc. This one writes its pid
# and its child's, then sleeps; it never ends by itself. (swift: 100 GB free
# for the free space check, swift -e or mac-free-gb.swift, so a Mac with less
# free space runs it too; no notch.)
cat > "$T/bin/swiftc" <<'EOF'
#!/bin/bash
sleep 600 &
echo "$$ $!" >> "$OMACVM_TEST_PIDS"
while :; do sleep 0.2; done
EOF
printf '#!/bin/bash\n[[ $1 == -e || $1 == */mac-free-gb.swift ]] && echo 100 || echo none\n' > "$T/bin/swift"
chmod +x "$T/bin/swiftc" "$T/bin/swift"

# A step's output under ui_follow, as "Installing Omarchy": a producer that
# never ends.
cat > "$T/follow.sh" <<'EOF'
R=$1
source "$R/src/lib/ui.sh"
echo "$$" >> "$OMACVM_TEST_PIDS"
while :; do echo "a line"; sleep 0.2; done | ui_follow "Installing Omarchy"
EOF

# drive.py WAIT_FOR TERM CMD...: runs CMD in a new terminal as a shell runs
# it (its own process group in the foreground, the shell stays the session
# leader: no hang-up when CMD ends, which would stop what it left behind),
# types ^C once WAIT_FOR was printed and the step wrote its pids, and says
# how it ended: the exit status, how long the exit took, and whether anything
# of CMD's process group (the step, its children, a spinner) is still there.
cat > "$T/drive.py" <<'PY'
import os, pty, re, select, signal, subprocess, sys, time
wait_for, term, cmd = sys.argv[1].encode(), sys.argv[2], sys.argv[3:]
pids_file = os.environ["OMACVM_TEST_PIDS"]
pid, fd = pty.fork()
if pid == 0:   # the "shell": session leader, the terminal's owner
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    c = os.fork()
    if c == 0:
        os.setpgid(0, 0)
        os.tcsetpgrp(0, os.getpid())
        for s in (signal.SIGTTOU, signal.SIGPIPE, signal.SIGINT):
            signal.signal(s, signal.SIG_DFL)
        os.environ["TERM"] = term
        os.execv(cmd[0], cmd)
    try: os.setpgid(c, c)
    except OSError: pass   # it did it itself (and maybe exec'd already)
    os.tcsetpgrp(0, c)
    os.write(1, b"PGID %d\n" % c)
    _, st = os.waitpid(c, 0)
    os.tcsetpgrp(0, os.getpgrp())   # the terminal back, as a shell takes it
    os.write(1, b"\nEXIT %d\n" % os.waitstatus_to_exitcode(st))
    time.sleep(300)
    os._exit(0)

out = b""
def read_until(pat, secs):
    global out
    end = time.time() + secs
    while True:
        m = re.search(pat, out)
        if m: return m
        left = end - time.time()
        if left <= 0 or not select.select([fd], [], [], left)[0]: return None
        try: b = os.read(fd, 4096)
        except OSError: return None
        if not b: return None
        out += b

def finish(msg):   # the terminal closed first: an exit waits for its output to drain
    os.close(fd); os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
    print(msg); sys.exit(0)

m = read_until(rb"PGID (\d+)\r?\n", 10)
if not m: finish("the command did not start")
pgid = int(m.group(1))
started = read_until(re.escape(wait_for), 60)
end = time.time() + 30
while started and time.time() < end and not os.path.exists(pids_file):
    time.sleep(0.05)
if not (started and os.path.exists(pids_file)):
    sys.stderr.write(out.decode(errors="replace")[-2000:] + "\n")
    subprocess.run(["pkill", "-KILL", "-g", str(pgid)])
    finish("the step never started")
time.sleep(0.5)   # the spinner has drawn a few frames
os.write(fd, b"\x03")
t0 = time.time()
m = read_until(rb"EXIT (\d+)\r?\n", 30)
took = time.time() - t0
time.sleep(1)   # anything left over has had time to draw or write again
ps = subprocess.run(["ps", "-A", "-o", "pid=,pgid="], capture_output=True, text=True).stdout.split()
left = [int(p) for p, g in zip(ps[::2], ps[1::2]) if int(g) == pgid]
left += [int(p) for p in open(pids_file).read().split()]
alive = sorted(set(p for p in left if subprocess.run(["kill", "-0", str(p)], capture_output=True).returncode == 0))
for p in alive:
    try: os.kill(p, signal.SIGKILL)
    except ProcessLookupError: pass
finish("rc %s, exit %s, %s" % (m.group(1).decode() if m else "none", "in <5s" if took < 5 else "took %.0fs" % took,
                               "still running: %s" % " ".join(map(str, alive)) if alive else "nothing left"))
PY

for term in xterm-256color dumb; do
  rm -f "$T/pids"
  got=$(cd "$T" && HOME=$T/home PATH="$T/bin:$PATH" OMACVM_TEST_PIDS=$T/pids \
    python3 "$T/drive.py" "Checking the Swift compiler" "$term" /bin/bash "$R/src/cmd/build.sh" --yes --no-mac --vm-type app)
  expect "build: Ctrl-C during a spinner step (TERM=$term) stops it" "rc 130, exit in <5s, nothing left" "$got"
done

rm -f "$T/pids"
got=$(OMACVM_TEST_PIDS=$T/pids python3 "$T/drive.py" "Installing Omarchy" xterm-256color /bin/bash "$T/follow.sh" "$R")
expect "ui_follow: Ctrl-C stops the step and its spinner line" "rc 130, exit in <5s, nothing left" "$got"

exit $fail
