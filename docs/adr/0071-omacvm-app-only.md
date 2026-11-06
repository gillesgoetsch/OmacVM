# 0071: OmacVM.app only: Parallels, UTM and VMware Fusion retired

Status: accepted, 3.4.0. Decided by the owner (2026-11-05): "let's sunset
them, we can still bring them back if users request, but never without my
explicit consent".

## Context

OmacVM built the same Omarchy VM on four routes: OmacVM.app (its own QEMU),
UTM, VMware Fusion and Parallels Desktop. By 3.3.0 OmacVM.app was the
recommended one and the only route with hardware video decoding, Vulkan,
WebGPU, GPU compute, HDR and the Mac's input methods; most new features were
app-only. The other three carried their own builders (`src/vm/live`,
`utm.sh`, `fusion.sh`, `pvs.py`), Mac helpers (clipboard, displays, network
listeners), prebuilt images, docs, tests and CI, and every change had to be
checked against them. The project targets people with one VM (memory note
"keep it simple").

## Decision

- 3.4.0 supports OmacVM.app only. The Parallels, UTM and VMware Fusion
  routes are removed in full: builders, helpers, prebuilt images, docs,
  benchmarks against them, tests.
- An existing VM on one of them keeps running as it is with its OmacVM 3.3.x.
  OmacVM never deletes, changes, starts or stops it; `omacvm` lists it as
  retired and refuses to change it (exit 3, one message). Its owner moves to
  OmacVM.app: a new VM, then copy the files over (README, "Coming from
  Parallels, UTM or VMware Fusion?").
- The routes are never added back without the owner's explicit consent,
  also when users ask for them. A guard test keeps their names out of the
  code and docs outside a short allowlist (this ADR, older ADRs, the
  CHANGELOG's history, the licence notices, the retired message and its
  README section).

## Consequences

- The docs, the feature list and the benchmark charts are shorter: one app,
  measured against the Mac itself. Older rounds and route pages stay in the
  v3.3.0 tag.
- Users of the old routes lose OmacVM's updates and, from 3.4.0 on the Mac,
  the Mac helpers for that VM. Their hypervisor's own features keep working.
- Earlier ADRs stay as written; where they mention the other routes, that
  is history.
