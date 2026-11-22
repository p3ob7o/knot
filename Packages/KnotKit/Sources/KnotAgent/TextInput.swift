import Foundation
import KnotCore

/// Where a command's `-` reads its text: the process's standard input, or what a test gives.
public protocol TextInput: Sendable {
    /// At most `limit + 1` bytes, so that the caller can tell text over the bound without
    /// holding more of it. `nil` when there is nothing to read: standard input is closed, or
    /// it is a terminal, which would wait for a person, and no command waits for one.
    func read(atMost limit: Int) throws(KnotError) -> Data?
}

/// The process's standard input, read with `read(2)`.
public struct StandardInput: TextInput {
    public init() {}

    public func read(atMost limit: Int) throws(KnotError) -> Data? {
        // A terminal would wait for a person to type (docs/product-spec.md §10).
        if isatty(STDIN_FILENO) == 1 { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= limit {
            let wanted = min(buffer.count, limit + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, wanted) }
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EBADF {
                // Standard input is closed: there is nothing to read.
                return data.isEmpty ? nil : data
            } else {
                throw KnotError.unexpected.with(.init(posixError: errno))
            }
        }
        return data
    }
}

/// Text that a test gives as standard input, or none for an input that is closed.
public struct GivenInput: TextInput {
    public let data: Data?

    public init(_ text: String?) {
        self.data = text.map { Data($0.utf8) }
    }

    public init(data: Data?) {
        self.data = data
    }

    public func read(atMost limit: Int) throws(KnotError) -> Data? {
        data.map { $0.prefix(limit + 1) }
    }
}
