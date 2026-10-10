import Foundation

/// The active worker holds a kernel-backed home-wide lease. Warm candidates never
/// hold it; a crashed owner cannot grant a second writer while an orphan still owns
/// this descriptor. CLOEXEC prevents unrelated child workloads inheriting authority.
public final class DaemonMutationLease: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var ownership: DaemonInstanceLock?
    public init(directory: URL = HarnessPaths.runtimeDirectory.appendingPathComponent("active-mutator"), initiallyActive: Bool) throws {
        self.directory = directory
        if initiallyActive { ownership = try DaemonInstanceLock(directory: directory) }
    }
    public var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return ownership != nil }
    public func activate() throws {
        lock.lock(); defer { lock.unlock() }
        if ownership == nil { ownership = try DaemonInstanceLock(directory: directory) }
    }
    public func suspend() { lock.lock(); ownership = nil; lock.unlock() }
}
