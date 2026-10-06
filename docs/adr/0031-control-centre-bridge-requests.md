# 0031: Mac-side actions from the VM: a fixed list of Bridge requests

Status: accepted, built (rounds 1 to 3). Branch `control-centre`.

## Context

Switching a feature changes both sides: the Mac installs or stops helpers,
then installs into the VM over SSH (`omacvm apply`). From inside the VM the
control centre has to ask the Mac to do that. The guest is untrusted
(STANDARDS 4): whatever it sends must not let it run anything else on the Mac.

## Options

1. Give the guest a way to run `omacvm` on the Mac (SSH back to the Mac, a
   generic "run" request). Simple, and a hole: any guest process with the
   token runs commands on the Mac.
2. A fixed set of requests on the existing Bridge (token + proof as today),
   each mapped by the Mac to one fixed `omacvm` invocation for the VM the
   request came from.
3. Do everything on the Mac only; the VM shows state and the command to type.
   Safe, but not the "in Omarchy" control centre that was asked for.

## Decision

Option 2. Requests under `/omacvm/`: `hello`, `status`, `updates`,
`updates/check`, `settings/update-checks`, `jobs` (actions `enable`,
`disable`, `reinstall`, `update`) and `jobs/<id>`. Nothing else. (Later:
`graphics` jobs and `gpu-memory`, read-only numbers for OmacVM.app VMs, 3.0.0.)

- The Mac decides which VM: the peer address must match exactly one running
  VM that OmacVM set up (pinned host key); otherwise 409 and nothing runs.
  The guest never names a VM. Each request is signed with that VM's own key
  (made by `omacvm apply`, kept on the Mac in `omacvm/vm-keys/` and in the
  VM in `~/.config/omacvm-bridge/vm-key`), which never crosses the network:
  `X-OmacVM-Auth: 1 <time> <nonce> <HMAC-SHA256(key, method, path, time,
  nonce, protocol header, SHA-256 of the body)>`. The Bridge takes it within
  5 minutes of its own clock and each nonce once. Nonces are kept per VM
  (each with its own cap, at most 4 requests a second per VM after a burst
  of 60), so a VM that floods the Bridge is refused ("rate") and no other
  VM is; they are kept in `omacvm-bridge/nonces` too, so a request caught
  before a Bridge restart (every update restarts it) is still refused after
  it. Answers to signed requests
  carry `X-OmacVM-Answer: <HMAC-SHA256(key, nonce, status, SHA-256 of the
  body)>`, and the VM believes nothing else: a VM that answers for the Mac's
  address (it has the Bridge token, as every VM does, so it passes /proof)
  sees only signatures, cannot change a request it passes on, and cannot
  send one twice. A VM whose clock is off gets a signed answer with the
  Mac's time and signs again once. Everything except `hello` needs this,
  also the Mac-wide update settings; `hello` carries nothing of the key.
- Strict JSON (≤ 4 KB, unknown keys rejected); feature names must be in the
  Mac's own `features.tsv`.
- The CLI runs by posix_spawn with a fixed argv, no shell; its path comes
  from a file `src/mac/install.sh` writes, checked for owner and mode. Only
  the installed checkout writes it (the one the `omacvm` command links to;
  `cli_for_bridge` in `src/lib/mac.sh`): another clone or an agent's
  worktree that runs the script never becomes what the Bridge runs, or what
  an update moves.
- One job per VM, 20 per hour; every request logged.
- Toggles only when the Mac's and the VM's OmacVM versions match; otherwise
  `update` installs the version the Mac fetched and verified itself (ADR
  0032), never one the guest names, and only forward (409 `not-newer` for a
  release older than the Mac or the VM). A failed update never locks a VM:
  the Mac keeps the new version, the VM goes back, and turning a feature off
  or repairing it still runs (they bring the VM to the Mac's version without
  that feature, or with it installed again). A VM newer than the Mac: 409
  `mac-older`, update the Mac first.
- Every job runs `omacvm apply --transaction`: the new OmacVM is unpacked
  beside the VM's old one and swapped in; on failure the old one and the
  saved feature set come back, and apply ends with exit code 4, which the
  job shows as `rolled-back` (the exit code alone decides, never the
  output). A part that is only logged when it fails (battery, camera,
  thp-kernel, control centre) fails the job only when it belongs to it: the
  features switched or repaired, or for an update the parts whose digest
  changes; others keep being logged only. `reinstall` repairs only the named
  features (`apply --reinstall F`), and its rollback re-runs only those.
  Apply names what failed in a JSON line (`{"omacvm_failed": 1, "part",
  "text"}`), which the job answer carries as its text and `failed_part`.
  Progress comes as JSON lines (`OMACVM_PROGRESS=json`): step n of m, shown
  on the rows the job changes or, for an update of OmacVM's own scripts or
  the app, in the banner.
- With update checks off, `update` installs only from a check made in the
  last hour (409 `stale-update`).
- Protocol number in `hello` and the `X-OmacVM-Proto` header; an older Mac
  (404) makes the control centre read-only with the command to update the
  Mac.
- OmacVM.app's VMs use a virtio-serial port, `org.omacvm.control`: one JSON
  line per request (`{"id", "method", "path", "body", "proto", "version"}`)
  and per answer (`{"id", "status", "body"}`). The app passes each request
  on to the Bridge with the relay key (`omacvm-bridge/relay-key`, never
  given to a VM) and the VM's name, which only the app knows, on the
  Bridge's relay socket (`omacvm-bridge/relay.sock`, owner only), or on
  127.0.0.1 to a Bridge older than the socket. The Bridge applies the same
  list; without the relay key 127.0.0.1 still gets `hello` only (the app's
  guests reach the Mac from there too).

## Consequences

- A hostile guest can switch its own VM's features and trigger an update to
  a signed release. It cannot reach other VMs, pass arguments, pick a version
  or get a shell.
- macOS permission prompts still appear on the Mac.
- The Bridge app stays installed while control-centre is on, also with the
  bridge feature off (as for the camera).

## Found while building

- macOS's Local Network privacy counts a child of an app as the app: the
  CLI's ssh to the VM was refused when the Bridge ran it (every check failed
  on SSH). The Bridge spawns the CLI with its responsibility disclaimed
  (`responsibility_spawnattrs_setdisclaim`, looked up at run time; Terminal
  does the same for its shells), so the CLI answers for itself.
- That disclaimed bash is then refused a VMs folder on an external drive,
  with no prompt (Removable Volumes): the app's VMs there were "no such
  OmacVM.app VM" (3.0.0, found on a MacBook Air with an SD card). For the
  app's VMs the Bridge runs omacvm through the app's executable
  (`OmacVM --control-run`, also spawned disclaimed), so the run is the
  app's, with the grants the person gave the app. The app runs only its own
  omacvm, only the Bridge's commands, and only when its parent is OmacVM
  Bridge of the same identity and signer. A program can pass that parent
  check (start the app, then exec the signed Bridge in its own place), so
  the app takes nothing from its caller that changes what runs: it sets
  PATH, HOME and TMPDIR itself, keeps only a job status file of the
  Bridge's shape, and refuses `--ip`, `--key` and `--user`. Its access is
  not lent to any other program.
- A job can outlive the Bridge: an update reinstalls the Bridge, which stops
  it mid-job. Jobs run in their own session and write their output and exit
  code to `omacvm-bridge/jobs/`; a restarted Bridge reports them from there
  and still refuses a second job for that VM while one runs.
- Identity was the VM's address on its network alone in round 1: a guest
  that took another VM's address could ask in that VM's name. Round 2 adds
  the per-VM key above.
- From 127.0.0.1 and the Mac's own addresses only `hello` is answered,
  unless OmacVM.app relays it with the relay key.
- The app's guests share 127.0.0.1 with the relay, so a guest holding
  connections there took the relay's places (and so every app VM's control
  centre). The relay now has its own Unix socket and its own places.
- Round 2's key travelled in a header (`X-OmacVM-VM-Key`). Every VM has the
  Bridge token, so a VM answering for 10.211.55.2 towards another (ARP on
  the shared network) passed /proof and got that VM's key. Round 3 signs
  instead (above); the impostor test is in the round 3 notes.
- OmacVM.app's control port opens for one program at a time, and a status
  request holds it up to 60 s: meanwhile job polls wait and the notice
  timer gives up for that run ("offline"). Accepted for now; a port shared
  by several clients (a small multiplexer in the guest) would remove it.
- The Bridge logs a request's method and path with control characters
  replaced: a `%0A` in a path must not write a forged line into the log that
  `omacvm report` on the Mac includes.
