import Foundation

enum BackgroundEvent: Codable {
    case accepted
    case rejected(String)
    case output(Data)
    case finished(Int32)

    static func rejection(_ reason: BackgroundRejection) -> Self { .rejected(reason.rawValue) }

    func send(to socket: LocalSocket) throws {
        var data = try JSONEncoder().encode(self)
        data.append(10)
        try socket.send(data)
    }
}

enum BackgroundRejection: String, CaseIterable {
    case administratorRequired = "VPN 后台服务只接受本机管理员账户。"
    case busy = "已有 VPN 会话，请先断开。"
    case runtimeRequired = "后台服务需要管理员部署受保护的 openfortivpn。请参阅安装说明。"

    var title: AppText {
        switch self {
        case .administratorRequired:
            return AppText("The VPN background service only accepts local administrators.", rawValue)
        case .busy:
            return AppText("A VPN session is already running. Disconnect it first.", rawValue)
        case .runtimeRequired:
            return AppText("The installed VPN runtime is missing or untrusted. Reinstall dFortiClient from its package.",
                           "VPN 运行组件缺失或权限不正确，请通过安装包重新安装 dFortiClient。")
        }
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

final class BackgroundSession {
    enum Event {
        case authorized
        case output(Data)
        case finished(AppText?)
    }

    static let label = "local.it-admin.dvpnctl.installed-vpn-service"
    static let socketPath = "/var/run/\(label).sock"
    static let servicePlist = "/Library/LaunchDaemons/\(label).plist"
    let cancellation: SessionCancellation

    init(cancellation: SessionCancellation = SessionCancellation()) {
        self.cancellation = cancellation
    }

    func stop() { cancellation.stop() }

    func start(request: VPNRequest, report: @escaping (Event) -> Void) {
        DispatchQueue(label: Self.label + ".client", qos: .userInitiated).async {
            let failure: AppText?
            do { failure = try self.run(request: request, report: report) }
            catch { failure = .from(error) }
            report(.finished(failure))
        }
    }

    private func run(request: VPNRequest, report: (Event) -> Void) throws -> AppText? {
        if cancellation.isStopped { return nil }
        guard FileManager.default.fileExists(atPath: Self.servicePlist) else {
            throw VPNError("Install dFortiClient.pkg from the disk image to set up the VPN service.",
                           "请运行磁盘映像内的 dFortiClient.pkg 以安装 VPN 服务。")
        }
        let socket: LocalSocket
        do {
            socket = try LocalSocket.connect(path: Self.socketPath, expectedUser: 0)
        } catch {
            throw VPNError("Could not reach the VPN background service. Check Login Items & Extensions, or reinstall dFortiClient from its package.",
                           "无法连接 VPN 后台服务。请检查「登录项与扩展」，或通过安装包重新安装 dFortiClient。")
        }
        return try run(socket: socket, request: request, report: report)
    }

    func run(socket: LocalSocket, request: VPNRequest, report: (Event) -> Void) throws -> AppText? {
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
                return AppText("The background service did not confirm disconnection. Check VPN routes and DNS.", "后台服务未确认 VPN 已断开，请检查 VPN 路由和 DNS。")
            }
            if !accepted && now >= admissionDeadline {
                return AppText("The VPN background service did not respond, or a connection is already running.", "VPN 后台服务未响应，或已有连接正在运行。")
            }
            guard try socket.waitForInput(milliseconds: 150) else { continue }
            let chunk = try socket.read()
            if chunk.isEmpty {
                return AppText("The VPN background service connection was lost. Check VPN routes and DNS.", "VPN 后台服务连接意外中断，请检查 VPN 路由和 DNS。")
            }
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
                    return BackgroundRejection(rawValue: message)?.title ?? AppText(message)
                case .output(let data) where accepted:
                    report(.output(data))
                case .finished(let code) where accepted:
                    if code == 0 { return nil }
                    return cancellation.isStopped ? .disconnectFailed : .workerExited
                default:
                    throw VPNError("The VPN background service returned an invalid status.", "VPN 后台服务返回了无效的状态。")
                }
            }
            if buffer.count > 16_384 { throw VPNError("A VPN background service message was too large.", "VPN 后台服务消息过长。") }
        }
    }
}

extension AppText {
    static let disconnectFailed = AppText("Disconnection failed. Check the log, VPN routes, and DNS.", "断开未正常完成，请查看日志并检查 VPN 路由和 DNS。")
    static let workerExited = AppText("openfortivpn exited unexpectedly. Check the connection log.", "openfortivpn 异常退出，请查看连接日志。")
}
