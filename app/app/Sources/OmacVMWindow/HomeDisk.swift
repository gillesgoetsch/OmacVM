import Foundation

/// The home disk (docs/adr/0076): a second sparse raw file in the VM's
/// folder, data.img, for a VM whose vm.env has HOME_GB (the setup's Home
/// disk row, `omacvm build --home-gb`). Omarchy has /home on it, on xfs: the
/// system disk's btrfs copies on write and compresses, which costs most
/// where a home's files change in place (databases, build trees, VM images).
/// Every other VM keeps /home on disk.img and starts as before.
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

    /// The sizes the setup offers besides Off, in GB (as its Disk row's).
    public static let setupGB = [64, 128, 256, 512]

    /// vm.env's line for a new VM: none without a home disk, so such a VM's
    /// vm.env is as it always was.
    public static func envLine(gb: Int?) -> String {
        gb.map { "HOME_GB=\($0)\n" } ?? ""
    }

    /// The setup's line under Home disk. A VM downloaded ready made has its
    /// home on its system disk: the row is for a VM built here.
    public static func setupNote(download: Bool) -> String {
        download ? "Only for a VM built here: choose Build Here above."
                 : "A second disk for your home folder, faster for databases and builds."
    }

    /// The setup row's (i).
    public static let setupHelp = """
        Your home folder gets a second disk with the xfs file system. Files that change in place are faster: \
        databases, build trees, container and VM images. The system stays on btrfs for update snapshots. \
        The disk takes Mac space only as it fills and frees deleted space. Add it only to a new VM. \
        You can grow it later in settings, never shrink or remove it.
        """
}
