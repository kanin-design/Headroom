import Darwin
import Foundation

/// Takes away the socket file a copy of the app left, and only that: anything at the path that isn't a socket stays.
private func removeSocketFile(_ path: String) {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return }
    Darwin.unlink(path)
}

/// The door agents come in by: a socket file in the app's own folder that only the user can open. Nothing listens on the
/// network.
enum AgentSocket {
    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < room else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        guard var address = address(path) else { return -1 }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A socket that doesn't end the app when the other end has gone: writing to it then fails instead.
    private static func open() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// Connects to a listening app, or returns nil when none is there.
    static func connect(to path: String) -> Int32? {
        let fd = open()
        guard fd >= 0 else { return nil }
        guard withAddress(path, { Darwin.connect(fd, $0, $1) }) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Starts listening. A file left by a copy that has quit is cleared away; one a running copy listens on is left alone.
    static func listen(at path: String) -> Int32? {
        if let other = connect(to: path) {
            close(other)
            return nil
        }
        removeSocketFile(path)
        let fd = open()
        guard fd >= 0 else { return nil }
        // Only the user: set before anyone can find it, and again on the file itself.
        let before = umask(0o177)
        let bound = withAddress(path) { bind(fd, $0, $1) }
        umask(before)
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}

/// One agent's connection: lines in, lines out.
final class AgentConnection: @unchecked Sendable {
    let fd: Int32
    /// A line longer than this isn't a request, and the connection is closed.
    static let longestRequest = 4 << 20
    /// A line longer than this ends the connection: `longestRequest` for what agents send, more for what the app answers,
    /// which can carry a picture.
    let longestLine: Int

    private let writes = DispatchQueue(label: "agent.writes")
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32, longestLine: Int = AgentConnection.longestRequest) {
        self.fd = fd
        self.longestLine = longestLine
    }

    /// Reads until the other end hangs up, handing over each line as it's complete, then closes the connection. Blocks: call
    /// it once, on a thread of its own.
    func read(_ line: (Data) -> Void) {
        var pending = Data()
        // How much of `pending` has been looked through for the end of a line, so a long line, such as one carrying an
        // image, is looked through once however many reads it takes to arrive.
        var searched = 0
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let got = Darwin.read(fd, &buffer, buffer.count)
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { break }
            pending.append(buffer, count: got)
            var from = pending.startIndex
            var search = pending.startIndex + searched
            while let end = pending[search...].firstIndex(of: 0x0A) {
                if end > from { line(pending.subdata(in: from..<end)) }
                from = end + 1
                search = from
            }
            if from > pending.startIndex { pending.removeSubrange(pending.startIndex..<from) }
            searched = pending.count
            if pending.count > longestLine { break }
        }
        // Closed here and nowhere else, so its number can't be handed to another connection while this one still reads.
        lock.withLock {
            closed = true
            close(fd)
        }
    }

    /// Sends one line. In order, and never on the caller's thread: a slow reader holds up only itself.
    func send(_ line: Data) {
        writes.async { [self] in
            var data = line
            data.append(0x0A)
            lock.withLock {
                guard !closed else { return }
                data.withUnsafeBytes { raw in
                    // Never empty: the line ends in a newline.
                    guard let start = raw.baseAddress else { return }
                    var sent = 0
                    while sent < raw.count {
                        let wrote = write(fd, start + sent, raw.count - sent)
                        if wrote < 0, errno == EINTR { continue }
                        guard wrote > 0 else { return }
                        sent += wrote
                    }
                }
            }
        }
    }

    /// Hangs up, once what's already been said is on its way. The reading thread wakes, ends and closes.
    func hangUp() {
        writes.async { [self] in
            lock.withLock {
                if !closed { shutdown(fd, SHUT_RDWR) }
            }
        }
    }
}

/// Waits for agents and hands over each connection as it arrives.
final class AgentListener: @unchecked Sendable {
    let path: String
    private var fd: Int32 = -1

    init(path: String) { self.path = path }

    /// Starts listening on a thread of its own. False when the door couldn't be opened, or another copy already has it.
    func start(_ arrived: @escaping @Sendable (AgentConnection) -> Void) -> Bool {
        guard let listening = AgentSocket.listen(at: path) else { return false }
        fd = listening
        Thread.detachNewThread { [listening] in
            while true {
                let one = accept(listening, nil, nil)
                if one < 0 {
                    if errno == EINTR { continue }
                    return
                }
                var on: Int32 = 1
                setsockopt(one, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                _ = fcntl(one, F_SETFD, FD_CLOEXEC)
                arrived(AgentConnection(fd: one))
            }
        }
        return true
    }

    func stop() {
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        fd = -1
        removeSocketFile(path)
    }
}
