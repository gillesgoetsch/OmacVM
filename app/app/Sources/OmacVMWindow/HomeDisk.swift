import Foundation

/// The home disk (docs/adr/0076): a second sparse raw file in the VM's
/// folder, data.img, for a VM whose vm.env has HOME_GB (`omacvm build
/// --home-gb`). Omarchy has /home on it, on xfs: the system disk's btrfs
/// copies on write and compresses, which costs most where a home's files
/// change in place (databases, build trees, VM images). Every other VM keeps
/// /home on disk.img and starts as before.
public enum HomeDisk {
    public static let file = "data.img"
    /// The VM finds the disk by it, wherever it is (src/vm/base-install.sh).
    public static let serial = "omacvm-home"

    /// QEMU's arguments for a start: an NVMe disk with the system disk's
    /// options (docs/adr/0039), never a boot device. `path` is data.img with
    /// QEMU's commas doubled; nil (no home disk): nothing.
    public static func arguments(path: String?) -> [String] {
        guard let path else { return [] }
        return ["-drive", "if=none,id=home,file=\(path),format=raw,cache=writeback,discard=unmap",
                "-device", "nvme,serial=\(serial),drive=home"]
    }

    /// Why Disk › Change… only makes it larger (DiskSize.bounds' unknownWhy).
    public static let onlyLarger = "xfs, the home disk's file system, cannot shrink."
}
