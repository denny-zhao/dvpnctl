import Foundation

struct VPNProfile: Codable, Equatable {
    var host = ""
    var port = "443"
    var username = ""
    var realm = ""
    var trustedCertificate = ""
    var keepConnected = true
    var retryInterval = "30"

    var loginTarget: VPNLoginTarget {
        VPNLoginTarget(host: host.lowercased(), port: Int(port), username: Data(username.utf8),
                       realm: Data(realm.utf8), fingerprint: trustedCertificate.lowercased())
    }

    func configuration(password: String) throws -> String {
        guard host.utf8.count <= 253,
              host.range(of: #"\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9.])?\z"#, options: .regularExpression) != nil
        else { throw VPNError("请输入网关域名或 IPv4 地址，不要包含协议或端口。") }
        guard let portNumber = Int(port), (1...65535).contains(portNumber) else {
            throw VPNError("端口必须在 1–65535 之间。")
        }
        try Self.validate(username, name: "用户名", maxBytes: 64)
        try Self.validate(password, name: "VPN 密码", maxBytes: 256)
        if !realm.isEmpty { try Self.validate(realm, name: "Realm", maxBytes: 63) }
        let fingerprint = trustedCertificate.lowercased()
        if !fingerprint.isEmpty {
            guard fingerprint.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else {
                throw VPNError("证书指纹必须是 64 位十六进制 SHA-256，不含分隔符。")
            }
        }
        var interval = 0
        if keepConnected {
            guard let seconds = Int(retryInterval), (5...3600).contains(seconds) else {
                throw VPNError("重连间隔必须在 5–3600 秒之间。")
            }
            interval = seconds
        }
        var lines = ["host = \(host)", "port = \(portNumber)", "username = \(username)",
                     "password = \(password)", "persistent = \(interval)"]
        if !realm.isEmpty { lines.append("realm = \(realm)") }
        if !fingerprint.isEmpty { lines.append("trusted-cert = \(fingerprint)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func validate(_ value: String, name: String, maxBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maxBytes,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw VPNError("\(name)不能为空或包含控制字符、首尾空白，且不能超过 \(maxBytes) 字节。")
        }
    }
}

struct VPNLoginTarget: Codable, Equatable {
    let host: String
    let port: Int?
    let username: Data
    let realm: Data
    let fingerprint: String
}

struct VPNRequest: Codable {
    let profile: VPNProfile
    let password: String
}

struct VPNError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

enum TunnelStatus: String {
    case idle = "未连接"
    case authorizing = "等待管理员授权"
    case connecting = "正在连接"
    case connected = "已连接"
    case reconnecting = "等待重连"
    case disconnecting = "正在断开"

    mutating func observe(_ line: String, persistent: Bool) {
        guard self != .disconnecting, line.hasPrefix("INFO:") else { return }
        let message = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if message == "Tunnel is up and running." {
            self = .connected
        } else if message == "Cancelling threads..." || message == "Closed connection to gateway."
                    || (message.hasPrefix("Setting ") && message.hasSuffix(" interface down.")) {
            if persistent {
                self = .reconnecting
            } else if self == .connected {
                self = .disconnecting
            }
        }
    }
}
