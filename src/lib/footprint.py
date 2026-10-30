"""footprint.py PID: the process's footprint in MB, the number Activity Monitor
shows as its Memory (phys_footprint, from proc_pid_rusage).

Reads no task port: the process runs on and is never suspended. Prints
nothing and exits 1 when the PID is gone or not this user's. omacvm check's
"Activity Monitor" row runs it on an OmacVM.app VM's QEMU (src/cmd/check.sh).
macOS's python3 (3.9) and OmacVM.app's.
"""
import ctypes
import sys


class RusageInfoV0(ctypes.Structure):
    """struct rusage_info_v0 (<sys/resource.h>)."""
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins",
        "wired_size", "resident_size", "phys_footprint", "proc_start_abstime",
        "proc_exit_abstime")]


def footprint_mb(pid):
    info = RusageInfoV0()
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    if libproc.proc_pid_rusage(ctypes.c_int(pid), 0, ctypes.byref(info)) != 0:   # RUSAGE_INFO_V0
        return None
    return info.phys_footprint // (1 << 20)


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        print("usage: footprint.py PID", file=sys.stderr)
        return 2
    mb = footprint_mb(int(sys.argv[1]))
    if mb is None:
        return 1
    print(mb)
    return 0


if __name__ == "__main__":
    sys.exit(main())
