import Foundation

/// A descriptor closed with `N>&-`. Its sink drops what's written, as
/// a closed fd would, but notes that something was: bash reports
/// `echo: write error: Bad file descriptor` for a command that writes
/// to a closed stdout, and fails it.
final class ClosedDescriptor: @unchecked Sendable {
    private static let registry = Registry()

    private let lock = NSLock()
    private var wrote = false

    /// A new sink standing for a closed descriptor.
    static func makeSink() -> OutputSink {
        let descriptor = ClosedDescriptor()
        let key = Box<ObjectIdentifier>()
        let sink = OutputSink(
            bufferingPolicy: .bufferingOldest(0),
            onWrite: { data in
                if !data.isEmpty { descriptor.noteWrite() }
            },
            onFinish: {
                if let id = key.value { registry.remove(id) }
            })
        let id = ObjectIdentifier(sink)
        key.value = id
        registry.insert(descriptor, for: id)
        return sink
    }

    /// The closed descriptor `sink` stands for, if it is one.
    static func of(_ sink: OutputSink) -> ClosedDescriptor? {
        registry.lookup(ObjectIdentifier(sink))
    }

    private func noteWrite() {
        lock.lock()
        wrote = true
        lock.unlock()
    }

    /// Whether anything was written since the last call.
    func takeWrite() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let result = wrote
        wrote = false
        return result
    }

    /// The open closed-descriptor sinks, by identity. A sink leaves
    /// when it's finished, which restoring the redirection does.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var bySink: [ObjectIdentifier: ClosedDescriptor] = [:]

        func insert(_ descriptor: ClosedDescriptor, for id: ObjectIdentifier) {
            lock.lock()
            defer { lock.unlock() }
            bySink[id] = descriptor
        }

        func remove(_ id: ObjectIdentifier) {
            lock.lock()
            defer { lock.unlock() }
            bySink.removeValue(forKey: id)
        }

        func lookup(_ id: ObjectIdentifier) -> ClosedDescriptor? {
            lock.lock()
            defer { lock.unlock() }
            return bySink[id]
        }
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }
}
