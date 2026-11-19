import Darwin
import Foundation

private func posixFailure(_ operation: String) -> VPNError {
    VPNError("\(operation): \(String(cString: strerror(errno)))")
}

private func withUnixAddress<Result>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) throws -> Result {
    var address = sockaddr_un()
    let bytes = path.utf8CString
    let size = MemoryLayout<sockaddr_un>.size
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw VPNError("套接字路径过长。") }
    address.sun_len = UInt8(size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(size)) }
    }
}

final class LocalSocket {
    private static let requestLimit = 8192
    let descriptor: Int32

    init(descriptor: Int32 = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)) throws {
        guard descriptor >= 0 else { throw posixFailure("socket") }
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let error = posixFailure("socket options")
            Darwin.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit { Darwin.close(descriptor) }

    static func connect(path: String, expectedUser: uid_t) throws -> LocalSocket {
        let socket = try LocalSocket()
        try socket.makeNonblocking()
        guard try withUnixAddress(path: path, { Darwin.connect(socket.descriptor, $0, $1) }) == 0 else {
            throw posixFailure("connect")
        }
        guard socket.peerIs(user: expectedUser) else { throw VPNError("本地连接的用户身份不符。") }
        return socket
    }

    private func makeNonblocking() throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw posixFailure("fcntl")
        }
    }

    func peerIs(user: uid_t) -> Bool {
        peerUser() == user
    }

    func peerUser() -> uid_t? {
        var actual: uid_t = 0
        var group: gid_t = 0
        return getpeereid(descriptor, &actual, &group) == 0 ? actual : nil
    }

    func accept() throws -> LocalSocket {
        let connection = try LocalSocket(descriptor: Darwin.accept(descriptor, nil, nil))
        try connection.makeNonblocking()
        return connection
    }

    func waitForInput(milliseconds: Int32) throws -> Bool {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return try Self.pollEvents(&event, count: 1, milliseconds: milliseconds)
    }

    static func pollEvents(_ events: UnsafeMutablePointer<pollfd>, count: nfds_t, milliseconds: Int32) throws -> Bool {
        while true {
            let result = Darwin.poll(events, count, milliseconds)
            if result >= 0 { return result > 0 }
            if errno != EINTR { throw posixFailure("poll") }
        }
    }

    func read() throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count >= 0 { return Data(buffer.prefix(count)) }
            if errno != EINTR { throw posixFailure("recv") }
        }
    }

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, start + offset, bytes.count - offset, 0)
                if count > 0 { offset += count }
                else if count == 0 || errno != EINTR { throw posixFailure("send") }
            }
        }
    }

    func sendRequest(_ request: VPNRequest) throws {
        var data = try JSONEncoder().encode(request)
        data.append(10)
        guard data.count <= Self.requestLimit else { throw VPNError("连接配置过长。") }
        try send(data)
    }

    func readRequest() throws -> VPNRequest {
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while data.count < Self.requestLimit {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, try waitForInput(milliseconds: Int32(remaining * 1000)) else { break }
            let chunk = try read()
            guard !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= Self.requestLimit else { break }
            if data.last == 10 { return try JSONDecoder().decode(VPNRequest.self, from: data) }
        }
        throw VPNError("未收到完整的连接配置。")
    }

    func endInput() { _ = shutdown(descriptor, SHUT_WR) }
}

final class LocalListener {
    let directory: String
    let path: String
    let socket: LocalSocket

    init() throws {
        var template = Array("/tmp/dvpnctl.XXXXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw posixFailure("mkdtemp") }
        directory = String(cString: template)
        path = directory + "/control"
        do {
            socket = try LocalSocket()
            guard try withUnixAddress(path: path, { bind(socket.descriptor, $0, $1) }) == 0,
                  listen(socket.descriptor, 4) == 0 else { throw posixFailure("listen") }
        } catch {
            unlink(path)
            rmdir(directory)
            throw error
        }
    }

    deinit {
        unlink(path)
        rmdir(directory)
    }

    func accept(expectedUser: uid_t) throws -> LocalSocket? {
        let connection = try socket.accept()
        return connection.peerIs(user: expectedUser) ? connection : nil
    }
}
