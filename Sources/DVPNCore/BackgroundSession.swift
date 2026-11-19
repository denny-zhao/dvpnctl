import Foundation

enum BackgroundEvent: Codable {
    case accepted
    case rejected(String)
    case output(Data)
    case finished(Int32)

    func send(to socket: LocalSocket) throws {
        var data = try JSONEncoder().encode(self)
        data.append(10)
        try socket.send(data)
    }
}

final class SessionCancellation {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

struct BackgroundSession {
    static let label = "local.it-admin.dvpnctl.vpn-service"
    static let socketPath = "/var/run/\(label).sock"
    let cancellation: SessionCancellation

    init(cancellation: SessionCancellation = SessionCancellation()) {
        self.cancellation = cancellation
    }

    func stop() { cancellation.stop() }

    func run(request: VPNRequest, report: (AuthorizationSession.Event) -> Void) throws -> String? {
        if cancellation.isStopped { return nil }
        let socket: LocalSocket
        do {
            socket = try LocalSocket.connect(path: Self.socketPath, expectedUser: 0)
        } catch {
            throw VPNError("无法连接已启用的 VPN 后台服务。请检查「登录项与扩展」；若刚升级，请停用后重新启用。")
        }
        return try run(socket: socket, request: request, report: report)
    }

    func run(socket: LocalSocket, request: VPNRequest, report: (AuthorizationSession.Event) -> Void) throws -> String? {
        defer { socket.endInput() }
        let admissionDeadline = ProcessInfo.processInfo.systemUptime + 5
        var stopDeadline: TimeInterval?
        var accepted = false
        var buffer = Data()

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if cancellation.isStopped {
                if !accepted { return nil }
                if stopDeadline == nil {
                    socket.endInput()
                    stopDeadline = now + 30
                }
            }
            if let stopDeadline, now >= stopDeadline {
                return "后台服务未确认 VPN 已断开，请检查 VPN 路由和 DNS。"
            }
            if !accepted && now >= admissionDeadline { return "VPN 后台服务未响应，或已有连接正在运行。" }
            guard try socket.waitForInput(milliseconds: 150) else { continue }
            let chunk = try socket.read()
            if chunk.isEmpty { return "VPN 后台服务连接意外中断，请检查 VPN 路由和 DNS。" }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let event = try JSONDecoder().decode(BackgroundEvent.self, from: buffer.prefix(upTo: end))
                buffer.removeSubrange(...end)
                switch event {
                case .accepted where !accepted:
                    if cancellation.isStopped { return nil }
                    try socket.sendRequest(request)
                    accepted = true
                    report(.authorized)
                case .rejected(let message) where !accepted:
                    return message
                case .output(let data) where accepted:
                    report(.output(data))
                case .finished(let code) where accepted:
                    if code == 0 { return nil }
                    return cancellation.isStopped
                        ? "断开未正常完成，请查看日志并检查 VPN 路由和 DNS。"
                        : "openfortivpn 异常退出，请查看连接日志。"
                default:
                    throw VPNError("VPN 后台服务返回了无效的状态。")
                }
            }
            if buffer.count > 16_384 { throw VPNError("VPN 后台服务消息过长。") }
        }
    }
}
