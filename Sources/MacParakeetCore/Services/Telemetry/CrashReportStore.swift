import Darwin
import Foundation

/// A small, process-shared diagnostic spool. The stable lease file is separate
/// from the report because an Objective-C exception atomically replaces it.
/// Filesystem work is bounded, but filesystem syscall latency is not guaranteed.
struct CrashReportStore: Sendable {
    static let capacity = 16
    static let scanLimit = 64
    static let maximumReportBytes = 32 * 1024
    static let reportName = "report.txt"
    private static let ownerName = "owner.lock"
    private static let queueLockName = ".queue.lock"

    let rootURL: URL
    let legacyURL: URL

    init(appSupportURL: URL) {
        rootURL = appSupportURL.appendingPathComponent("CrashReports", isDirectory: true)
        legacyURL = appSupportURL.appendingPathComponent("crash_report.txt")
    }

    /// Retain this object until process exit. Closing its descriptor releases
    /// ownership, including automatically when a process crashes.
    final class Lease: @unchecked Sendable {
        let reportURL: URL
        fileprivate let name: String
        fileprivate let directoryDescriptor: Int32
        private let ownerDescriptor: Int32

        fileprivate init(reportURL: URL, name: String, directoryDescriptor: Int32, ownerDescriptor: Int32) {
            self.reportURL = reportURL
            self.name = name
            self.directoryDescriptor = directoryDescriptor
            self.ownerDescriptor = ownerDescriptor
        }

        deinit {
            close(ownerDescriptor)
            close(directoryDescriptor)
        }
    }

    private struct Entry {
        let name: String
        let modifiedSeconds: Int
    }

    /// Startup fast path: at most 64 directory entries, never a blocking lock.
    /// Failure disables persistence for this process rather than using the old
    /// shared destination or disturbing another process's report.
    func reserve() -> Lease? {
        withQueueLock { rootDescriptor in
            guard makeRoom(rootDescriptor: rootDescriptor) else { return nil }
            return createLease(rootDescriptor: rootDescriptor)
        } ?? nil
    }

    /// Called by the off-main drain. Every returned claim excludes other
    /// drainers, live writers, and capacity eviction until the caller releases it.
    func claimPendingReports() -> [Lease] {
        withQueueLock { rootDescriptor in
            guard let entries = entries(rootDescriptor: rootDescriptor) else { return [] }
            var claims: [Lease] = []
            for entry in entries.prefix(Self.capacity) {
                guard let lease = claim(name: entry.name, rootDescriptor: rootDescriptor) else { continue }
                if reportIsPresent(in: lease) {
                    claims.append(lease)
                } else {
                    _ = remove(lease, rootDescriptor: rootDescriptor)
                }
            }
            // Adopt before awaiting delivery. A new legacy writer can replace
            // the old pathname later without that new file being deleted here.
            if let legacy = adoptLegacy(rootDescriptor: rootDescriptor) {
                claims.append(legacy)
            }
            return claims
        } ?? []
    }

    /// Only the claimed directory is removed. The held owner lease already
    /// excludes every other claimant, so the report itself is unlinked without
    /// the queue lock: queue contention must not leave a report that telemetry
    /// dropped for opt-out uploadable after a later opt-in. An empty
    /// reservation left by contention is reclaimed by later scans.
    @discardableResult
    func discard(_ lease: Lease) -> Bool {
        var info = stat()
        if fstatat(lease.directoryDescriptor, Self.reportName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG,
                unlinkat(lease.directoryDescriptor, Self.reportName, 0) == 0
            else { return false }
        } else if errno != ENOENT {
            return false
        }
        return withQueueLock { rootDescriptor in
            remove(lease, rootDescriptor: rootDescriptor)
        } ?? false
    }

    /// Never follows a report symlink and never allocates proportional to an
    /// untrusted report's size. One extra byte detects a file that grew on read.
    static func readReport(at url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size > 0,
            info.st_size <= maximumReportBytes
        else { return nil }
        var data = Data(count: maximumReportBytes + 1)
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            var total = 0
            while total < buffer.count {
                let result = read(descriptor, buffer.baseAddress!.advanced(by: total), buffer.count - total)
                if result > 0 { total += result } else if result == 0 { break } else if errno != EINTR { return -1 }
            }
            return total
        }
        guard count > 0, count <= maximumReportBytes else { return nil }
        data.count = count
        return data
    }

    private func withQueueLock<T>(_ body: (Int32) -> T) -> T? {
        // Do not replace an unexpected parent file or follow a spool symlink.
        var parentInfo = stat()
        guard lstat(rootURL.deletingLastPathComponent().path, &parentInfo) == 0,
            (parentInfo.st_mode & S_IFMT) == S_IFDIR
        else { return nil }
        if mkdir(rootURL.path, S_IRWXU) != 0, errno != EEXIST { return nil }
        let rootDescriptor = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else { return nil }
        defer { close(rootDescriptor) }
        let lockDescriptor = openat(
            rootDescriptor, Self.queueLockName, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard lockDescriptor >= 0 else { return nil }
        defer { close(lockDescriptor) }
        var lockInfo = stat()
        guard fstat(lockDescriptor, &lockInfo) == 0,
            (lockInfo.st_mode & S_IFMT) == S_IFREG,
            flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0
        else { return nil }
        return body(rootDescriptor)
    }

    private func entries(rootDescriptor: Int32) -> [Entry]? {
        guard let names = directoryNames(descriptor: rootDescriptor, limit: Self.scanLimit) else { return nil }
        var result: [Entry] = []
        for name in names where UUID(uuidString: name) != nil {
            var info = stat()
            guard fstatat(rootDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                (info.st_mode & S_IFMT) == S_IFDIR
            else { continue }
            result.append(Entry(name: name, modifiedSeconds: info.st_mtimespec.tv_sec))
        }
        return result.sorted { ($0.modifiedSeconds, $0.name) < ($1.modifiedSeconds, $1.name) }
    }

    private func makeRoom(rootDescriptor: Int32) -> Bool {
        guard let entries = entries(rootDescriptor: rootDescriptor) else { return false }
        var count = entries.count
        for entry in entries {
            guard count >= Self.capacity else { break }
            guard let lease = claim(name: entry.name, rootDescriptor: rootDescriptor) else { continue }
            if remove(lease, rootDescriptor: rootDescriptor) { count -= 1 }
        }
        return count < Self.capacity
    }

    private func createLease(rootDescriptor: Int32) -> Lease? {
        let name = UUID().uuidString.lowercased()
        guard mkdirat(rootDescriptor, name, S_IRWXU) == 0 else { return nil }
        guard let lease = claim(name: name, rootDescriptor: rootDescriptor) else {
            _ = unlinkat(rootDescriptor, name, AT_REMOVEDIR)
            return nil
        }
        return lease
    }

    private func claim(name: String, rootDescriptor: Int32) -> Lease? {
        let directoryDescriptor = openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { return nil }
        let ownerDescriptor = openat(
            directoryDescriptor, Self.ownerName, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard ownerDescriptor >= 0 else { close(directoryDescriptor); return nil }
        var info = stat()
        guard fstat(ownerDescriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            flock(ownerDescriptor, LOCK_EX | LOCK_NB) == 0
        else {
            close(ownerDescriptor)
            close(directoryDescriptor)
            return nil
        }
        return Lease(
            reportURL: rootURL.appendingPathComponent(name, isDirectory: true).appendingPathComponent(Self.reportName),
            name: name,
            directoryDescriptor: directoryDescriptor,
            ownerDescriptor: ownerDescriptor
        )
    }

    private func reportIsPresent(in lease: Lease) -> Bool {
        var info = stat()
        // A malformed or oversized regular report is still a pending entry:
        // the bounded parser may reject it. Retain unreadable/unparseable
        // evidence until capacity eviction rather than treating I/O failure as
        // proof that the report is malformed.
        if fstatat(lease.directoryDescriptor, Self.reportName, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        // Only a definite missing file identifies an empty reservation. Other
        // metadata failures must not turn transient I/O into destructive cleanup.
        return errno != ENOENT
    }

    private func adoptLegacy(rootDescriptor: Int32) -> Lease? {
        var info = stat()
        guard lstat(legacyURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            makeRoom(rootDescriptor: rootDescriptor),
            let lease = createLease(rootDescriptor: rootDescriptor)
        else { return nil }
        guard rename(legacyURL.path, lease.reportURL.path) == 0 else {
            _ = remove(lease, rootDescriptor: rootDescriptor)
            return nil
        }
        return lease
    }

    private func remove(_ lease: Lease, rootDescriptor: Int32) -> Bool {
        // Only our two known regular diagnostic files may be removed. A
        // polluted directory or symlink is left alone, not recursively deleted.
        guard let names = directoryNames(descriptor: lease.directoryDescriptor, limit: 2),
            names.allSatisfy({ $0 == Self.reportName || $0 == Self.ownerName })
        else { return false }
        for name in names {
            var info = stat()
            guard fstatat(lease.directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                (info.st_mode & S_IFMT) == S_IFREG
            else { return false }
        }
        if names.contains(Self.reportName), unlinkat(lease.directoryDescriptor, Self.reportName, 0) != 0 {
            return false
        }
        guard unlinkat(lease.directoryDescriptor, Self.ownerName, 0) == 0 else { return false }
        return unlinkat(rootDescriptor, lease.name, AT_REMOVEDIR) == 0
    }

    private func directoryNames(descriptor: Int32, limit: Int) -> [String]? {
        // openat(".") creates an independent directory cursor: dup() would
        // share offsets with earlier scans and silently miss existing entries.
        let scanDescriptor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard scanDescriptor >= 0 else { return nil }
        guard let directory = fdopendir(scanDescriptor) else { close(scanDescriptor); return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? names : nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            guard names.count < limit else { return nil }
            names.append(name)
        }
    }
}
