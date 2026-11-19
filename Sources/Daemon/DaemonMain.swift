import Darwin
import Foundation

@main
enum DaemonMain {
    static func main() {
        guard geteuid() == 0 else { exit(EX_NOPERM) }
        guard let listener = try? LocalSocket(descriptor: take_vpn_listener()) else { exit(EX_CONFIG) }

        let shutdown = SessionCancellation()
        signal(SIGTERM) { _ in }
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminate.setEventHandler { shutdown.stop() }
        terminate.resume()
        defer { terminate.cancel() }

        let connection = DispatchGroup()
        let workerQueue = DispatchQueue(label: "dFortiClient.vpn-service")
        defer { connection.wait() }
        do {
            var idleDeadline = ProcessInfo.processInfo.systemUptime + 30
            while !shutdown.isStopped {
                let busy = connection.wait(timeout: .now()) == .timedOut
                if busy { idleDeadline = ProcessInfo.processInfo.systemUptime + 30 }
                if ProcessInfo.processInfo.systemUptime >= idleDeadline { return }
                if try listener.waitForInput(milliseconds: 150) {
                    let socket = try listener.accept()
                    guard let user = socket.peerUser(), PrivilegePolicy.isAdministrator(user) else {
                        try? BackgroundEvent.rejection(.administratorRequired).send(to: socket)
                        continue
                    }
                    if connection.wait(timeout: .now()) == .timedOut {
                        try? BackgroundEvent.rejection(.busy).send(to: socket)
                        continue
                    }
                    workerQueue.async(group: connection) { handle(socket, shutdown: shutdown) }
                    idleDeadline = ProcessInfo.processInfo.systemUptime + 30
                }
            }
        } catch {
            shutdown.stop()
            connection.wait()
            exit(EX_IOERR)
        }
    }

    private static func handle(_ socket: LocalSocket, shutdown: SessionCancellation) {
        guard !shutdown.isStopped else { return }
        let executable = PrivilegePolicy.backgroundRuntime
        guard PrivilegePolicy.isProtectedRuntime(at: executable) else {
            try? BackgroundEvent.rejection(.runtimeRequired).send(to: socket)
            return
        }
        guard (try? BackgroundEvent.accepted.send(to: socket)) != nil else { return }
        var replyIntact = true
        let status = VPNWorker.run(socket: socket, executable: executable, protectedRuntime: true,
                                   shouldStop: { shutdown.isStopped }, onOutput: { data in
            do { try BackgroundEvent.output(data).send(to: socket) }
            catch {
                replyIntact = false
                throw error
            }
        })
        if replyIntact { try? BackgroundEvent.finished(status).send(to: socket) }
    }
}
