import Darwin
import Foundation

final class AuthorizationSession {
    enum Event {
        case authorized
        case output(Data)
        case finished(AppText?)
    }

    private let cancellation = SessionCancellation()

    func stop() { cancellation.stop() }

    private var shouldStop: Bool { cancellation.isStopped }

    func start(request: VPNRequest, worker: URL, useBackground: Bool, report: @escaping (Event) -> Void) {
        DispatchQueue(label: "dvpnctl.authorization", qos: .userInitiated).async {
            let failure: AppText?
            do {
                if useBackground {
                    failure = try BackgroundSession(cancellation: self.cancellation).run(request: request, report: report)
                } else {
                    failure = try self.run(request: request, worker: worker, report: report)
                }
            }
            catch { failure = AppText.from(error) }
            report(.finished(failure))
        }
    }

    private func run(request: VPNRequest, worker: URL, report: (Event) -> Void) throws -> AppText? {
        guard !shouldStop else { return nil }
        var listener: LocalListener? = try LocalListener()
        guard let path = listener?.path else { return nil }
        let command = ["exec", "--", Self.shellQuote(worker.path), "--vpn-worker", Self.shellQuote(path), String(getuid())]
            .joined(separator: " ") + " </dev/null >/dev/null 2>&1"
        let prompt = AppText("dFortiClient: OpenFortiVPN requires administrator privileges to configure the VPN.",
                             "dFortiClient：OpenFortiVPN 需要管理员权限才能配置 VPN。").render(request.language ?? .english)
        let authorization = Process()
        authorization.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        authorization.arguments = ["-e", "do shell script \(Self.scriptString(command)) with prompt \(Self.scriptString(prompt)) with administrator privileges"]
        let errors = Pipe()
        authorization.standardError = errors
        authorization.standardOutput = FileHandle.nullDevice
        try authorization.run()

        var connection: LocalSocket?
        var authorized = false
        var sentRequest = false
        var inputClosed = false
        defer {
            listener = nil
            connection?.endInput()
            if authorization.isRunning && !authorized { authorization.terminate() }
            authorization.waitUntilExit()
        }

        while authorization.isRunning || connection != nil {
            if shouldStop && !inputClosed {
                listener = nil
                connection?.endInput()
                if !authorized && authorization.isRunning { authorization.terminate() }
                inputClosed = true
            }
            if let current = connection {
                if try current.waitForInput(milliseconds: 150) {
                    let data = try current.read()
                    if data.isEmpty { connection = nil }
                    else { report(.output(data)) }
                }
            } else if let current = listener, try current.socket.waitForInput(milliseconds: 150) {
                if let root = try current.accept(expectedUser: 0) {
                    connection = root
                    authorized = true
                    listener = nil
                    if shouldStop {
                        root.endInput()
                        inputClosed = true
                    } else {
                        try root.sendRequest(request)
                        sentRequest = true
                        report(.authorized)
                    }
                }
            } else if listener == nil {
                Thread.sleep(forTimeInterval: 0.15)
            }
        }

        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if shouldStop {
            return sentRequest && authorization.terminationStatus != 0
                ? .disconnectFailed : nil
        }
        if !authorized {
            return stderr.contains("(-128)")
                ? AppText("Administrator approval was canceled.", "已取消管理员授权。")
                : AppText("Could not start the VPN or obtain administrator approval.", "无法启动 VPN 或取得管理员授权。")
        }
        return authorization.terminationStatus == 0 ? nil : .workerExited
    }

    private static func scriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
