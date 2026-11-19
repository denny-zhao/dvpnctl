import Darwin
import Foundation

enum VPNWorker {
    static let shutdownTimedOut: Int32 = 75

    static func run(socket: LocalSocket, executable: String, stopGracePeriod: TimeInterval = 20,
                    shouldStop: () -> Bool = { false },
                    onOutput: ((Data) throws -> Void)? = nil) -> Int32 {
        let emit = onOutput ?? socket.send
        var language = AppLanguage.english
        do {
            let request = try socket.readRequest()
            language = request.language ?? .english
            if shouldStop() { return 0 }
            let config = try request.profile.configuration(password: request.password)
            return try supervise(socket: socket, executable: executable, config: Data(config.utf8),
                                 stopGracePeriod: stopGracePeriod,
                                 language: language, shouldStop: shouldStop, emit: emit)
        } catch {
            try? emit(Data("dFortiClient: \(AppText.from(error).render(language))\n".utf8))
            return 1
        }
    }

    private static func supervise(socket: LocalSocket, executable: String, config: Data,
                                  stopGracePeriod: TimeInterval, language: AppLanguage,
                                  shouldStop: () -> Bool,
                                  emit: (Data) throws -> Void) throws -> Int32 {
        let configuration = Pipe()
        try configuration.fileHandleForWriting.write(contentsOf: config)
        try configuration.fileHandleForWriting.close()

        let output = Pipe()
        let reader = output.fileHandleForReading
        guard fcntl(reader.fileDescriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw VPNError("Could not read openfortivpn output.", "无法读取 openfortivpn 的输出。")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.currentDirectoryURL = URL(fileURLWithPath: "/")
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C",
                             "OPENSSL_CONF": "/dev/null", "OPENSSL_MODULES": "/var/empty",
                             "OPENSSL_ENGINES": "/var/empty", "SSL_CERT_FILE": "/etc/ssl/cert.pem",
                             "SSL_CERT_DIR": "/var/empty"]
        child.arguments = ["-c", "/dev/fd/0"]
        child.standardInput = configuration.fileHandleForReading
        child.standardOutput = output
        child.standardError = output
        try child.run()

        var shutdownDeadline: TimeInterval?
        var forced = false
        var canForward = true
        func stop() {
            guard shutdownDeadline == nil else { return }
            shutdownDeadline = ProcessInfo.processInfo.systemUptime + stopGracePeriod
            if child.isRunning { child.terminate() }
        }
        func forceIfOverdue() {
            guard let deadline = shutdownDeadline, !forced, ProcessInfo.processInfo.systemUptime >= deadline,
                  child.isRunning, kill(child.processIdentifier, SIGKILL) == 0 else { return }
            forced = true
            let message = AppText("Graceful disconnection timed out and the process was stopped. VPN routes and DNS may not have been restored.",
                                  "正常断开超时，已强制停止；无法确认 VPN 路由和 DNS 已恢复。")
            try? emit(Data("dFortiClient: \(message.render(language))\n".utf8))
        }
        defer {
            stop()
            while child.isRunning {
                forceIfOverdue()
                Thread.sleep(forTimeInterval: 0.15)
            }
            child.waitUntilExit()
        }

        var outputOpen = true
        func forwardOutput() {
            var bytes = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<16 {
                let count = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                if count > 0 {
                    if canForward {
                        do { try emit(Data(bytes.prefix(count))) }
                        catch {
                            canForward = false
                            stop()
                        }
                    }
                } else if count == 0 {
                    outputOpen = false
                    break
                } else if errno != EINTR {
                    break
                }
            }
        }

        while child.isRunning {
            if shouldStop() { stop() }
            var events = [pollfd(fd: shutdownDeadline == nil ? socket.descriptor : -1, events: Int16(POLLIN), revents: 0),
                          pollfd(fd: outputOpen ? reader.fileDescriptor : -1, events: Int16(POLLIN), revents: 0)]
            _ = try events.withUnsafeMutableBufferPointer { buffer in
                try LocalSocket.pollEvents(buffer.baseAddress!, count: nfds_t(buffer.count), milliseconds: 150)
            }
            if events[0].revents != 0 { stop() }
            if events[1].revents != 0 { forwardOutput() }
            forceIfOverdue()
        }
        child.waitUntilExit()
        if outputOpen { forwardOutput() }
        if forced { return shutdownTimedOut }
        return child.terminationReason == .exit ? child.terminationStatus : 128 + child.terminationStatus
    }
}
