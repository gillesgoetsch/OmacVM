import Darwin

/// What macOS says about QEMU's memory and its own compressor, for the VM's
/// give-back (MemoryGiveBack, ADR 0059). Read in GPUMemoryWatch's 5 s look
/// only; both are plain calls for the app's own child, no privileges.
enum HostMemory {
    /// QEMU's footprint (what Activity Monitor shows) and its resident size,
    /// bytes; nil once it has ended.
    static func process(_ pid: pid_t) -> (footprint: UInt64, resident: UInt64)? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return nil }
        return (info.ri_phys_footprint, info.ri_resident_size)
    }

    private static let host = mach_host_self()

    /// What macOS has compressed since it started (every process), bytes.
    static func compressed() -> UInt64? {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return s.compressions &* UInt64(vm_kernel_page_size)
    }
}
