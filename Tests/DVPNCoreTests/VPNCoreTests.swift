import Foundation
import Darwin

@main
struct VPNCoreTests {
    static func main() throws {
        let tests = VPNCoreTests()
        try tests.testConfigEnablesOrDisablesNativeReconnect()
        tests.testConfigRejectsValuesThatWouldBeInjectedOrAltered()
        try tests.testConfigNormalizesPortAndFingerprint()
        tests.testStatusTracksTunnelNotGatewayAndDoesNotUndoDisconnect()
        tests.testFirstFailureEntersReconnectOnlyWhenEnabled()
        try tests.testWorkerPipesConfigAndStopsOnControlEOF()
        try tests.testWorkerStopsWhenChildIgnoresTermination()
        try tests.testFullLogSocketDoesNotBlockSender()
        try tests.testPrivilegePolicy()
        try tests.testLegacyProfileMigration()
        try tests.testNamedProfilesAndPasswordLifecycle()
        try tests.testChangedSignInTargetDoesNotReusePassword()
        try tests.testPasswordCannotCrossTargetsAfterInterruptedSave()
        try tests.testBackgroundSessionWaitsForAdmission()
        try tests.testBackgroundSessionReturnsExitStatusAndDisconnects()
        try tests.testBackgroundSessionReportsLostService()
        try tests.testBackgroundSessionControlsVPNWorker()
        try tests.testBackgroundRuntimeRequiresProtectedPath()
        try tests.testBackgroundSessionControlsVPNWorker(childExit: 42)
        try tests.testLanguageChoicePersistsAndResolvesSystemPreferences()
        tests.testStatusAndErrorsRenderInBothLanguages()
        try tests.testLanguageDoesNotOversizeRequestWithReconnectOff()
        print("22 tests passed")
        try tests.testKeychainRoundTripIfEnabled()
    }

    func testLanguageChoicePersistsAndResolvesSystemPreferences() throws {
        let suite = "dvpnctl.tests.language.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(LanguageChoice.load(from: defaults) == .system)
        check(LanguageChoice.system.resolve(["fr-FR", "zh-Hans-CN", "en-US"]) == .simplifiedChinese)
        check(LanguageChoice.system.resolve(["en-GB", "zh-CN"]) == .english)
        check(LanguageChoice.system.resolve(["fr-FR"]) == .english)
        check(LanguageChoice.system.resolve(["zh-Hant-TW", "en-US"]) == .english)
        LanguageChoice.english.save(to: defaults)
        check(LanguageChoice.load(from: defaults) == .english)
        check(LanguageChoice.load(from: defaults).resolve(["zh-CN"]) == .english)
        LanguageChoice.simplifiedChinese.save(to: defaults)
        check(LanguageChoice.load(from: defaults).resolve(["en-US"]) == .simplifiedChinese)
        LanguageChoice.system.save(to: defaults)
        check(LanguageChoice.load(from: defaults) == .system)
    }

    func testStatusAndErrorsRenderInBothLanguages() {
        check(TunnelStatus.connected.title.render(.english) == "Connected")
        check(TunnelStatus.connected.title.render(.simplifiedChinese) == "已连接")
        let error = VPNError("Profile is missing.", "未找到配置。")
        let message = AppText.from(error).appending(AppText(" Check your settings.", " 请检查设置。"))
        check(message.render(.english) == "Profile is missing. Check your settings.")
        check(message.render(.simplifiedChinese) == "未找到配置。 请检查设置。")
    }

    func testLegacyProfileMigration() throws {
        let suite = "dvpnctl.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(sampleProfile), forKey: "vpn-profile-v1")
        let store = VPNProfileStore(defaults: defaults, passwords: TestPasswords())
        let migrated = try store.load()
        check(migrated.count == 1)
        check(migrated.first?.name == "默认 VPN")
        check(migrated.first?.settings.username == "alice")
        check(migrated.first?.remembersPassword == false)
        check(try store.load().first?.id == migrated.first?.id)
        check(defaults.data(forKey: "vpn-profile-v1") == nil)
    }

    func testNamedProfilesAndPasswordLifecycle() throws {
        let suite = "dvpnctl.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let passwords = TestPasswords()
        let store = VPNProfileStore(defaults: defaults, passwords: passwords)
        var work = NamedVPNProfile(name: " 工作 ", settings: sampleProfile, remembersPassword: true)
        let lab = NamedVPNProfile(name: "实验室", settings: sampleProfile, remembersPassword: true)
        let other = NamedVPNProfile(name: "工作", settings: sampleProfile)
        work = try store.save(work, password: "work-secret")
        _ = try store.save(lab, password: "lab-secret")
        rejects { try store.save(other, password: "") }
        check(try store.load().map(\.name) == ["工作", "实验室"])
        check(try store.password(for: work) == "work-secret")
        check(try store.password(for: lab) == "lab-secret")
        let stored = defaults.data(forKey: "vpn-profiles-v2")!
        check(!String(decoding: stored, as: UTF8.self).contains("-secret"))
        work.name = "公司"
        work = try store.save(work, password: "")
        check(try store.password(for: work) == "work-secret")
        work = try store.save(work, password: "new-secret")
        check(try store.password(for: work) == "new-secret")
        work.remembersPassword = false
        work = try store.save(work, password: "")
        check(passwords.values[work.id] == nil)
        check(try store.password(for: work) == nil)
        try store.delete(lab.id)
        check(passwords.values[lab.id] == nil)
        check(try store.load().map(\.id) == [work.id])
    }

    func testChangedSignInTargetDoesNotReusePassword() throws {
        let suite = "dvpnctl.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VPNProfileStore(defaults: defaults, passwords: TestPasswords())
        var profile = NamedVPNProfile(name: "工作", settings: sampleProfile, remembersPassword: true)
        profile = try store.save(profile, password: "old-secret")
        profile.settings.host = "other.example.com"
        check(try store.password(for: profile) == nil)
        rejects { try store.save(profile, password: "") }
        check(try store.load().first?.settings.host == sampleProfile.host)
        profile = try store.save(profile, password: "new-secret")
        check(try store.password(for: profile) == "new-secret")
    }

    func testPasswordCannotCrossTargetsAfterInterruptedSave() throws {
        let suite = "dvpnctl.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let passwords = TestPasswords()
        let store = VPNProfileStore(defaults: defaults, passwords: passwords)
        var profile = NamedVPNProfile(name: "工作", settings: sampleProfile, remembersPassword: true)
        profile.settings.username = "\u{e9}"
        profile = try store.save(profile, password: "original")
        let stored = defaults.data(forKey: "vpn-profiles-v2")
        var edited = profile
        edited.settings.username = "e\u{301}"
        check(try store.password(for: edited) == nil)
        _ = try store.save(edited, password: "replacement")
        defaults.set(stored, forKey: "vpn-profiles-v2")
        check(try store.password(for: profile) == nil)
    }

    func testKeychainRoundTripIfEnabled() throws {
        guard ProcessInfo.processInfo.environment["DVPNCTL_TEST_KEYCHAIN"] == "1" else { return }
        let passwords = KeychainVPNPasswords(service: "local.it-admin.dvpnctl.test.\(UUID())")
        let profileID = UUID()
        defer { try? passwords.remove(for: profileID) }
        check(try passwords.read(for: profileID) == nil)
        let original = VPNCredential(target: sampleProfile.loginTarget, password: "测试 secret")
        let replacement = VPNCredential(target: sampleProfile.loginTarget, password: "replacement")
        try passwords.write(original, for: profileID)
        check(try passwords.read(for: profileID) == original)
        try passwords.write(replacement, for: profileID)
        check(try passwords.read(for: profileID) == replacement)
        try passwords.remove(for: profileID)
        check(try passwords.read(for: profileID) == nil)
        print("Keychain round trip passed")
    }

    func testConfigEnablesOrDisablesNativeReconnect() throws {
        var profile = sampleProfile
        let config = try profile.configuration(password: "a=b' $word")
        check(config == """
            host = vpn.example.com
            port = 443
            username = alice
            password = a=b' $word
            persistent = 20
            realm = staff

            """)
        profile.keepConnected = false
        check(try profile.configuration(password: "secret").contains("persistent = 0\n"))
    }

    func testBackgroundSessionWaitsForAdmission() throws {
        try exerciseBackgroundSession { socket in
            check(try !socket.waitForInput(milliseconds: 100))
            try BackgroundEvent.rejection(.busy).send(to: socket)
        } client: { session, socket, request in
            var events = [AuthorizationSession.Event]()
            let failure = try session.run(socket: socket, request: request) { events.append($0) }
            check(failure?.render(.english) == "A VPN session is already running. Disconnect it first.")
            check(failure?.render(.simplifiedChinese) == "已有 VPN 会话，请先断开。")
            check(events.isEmpty)
        }
    }

    func testLanguageDoesNotOversizeRequestWithReconnectOff() throws {
        var profile = sampleProfile
        profile.keepConnected = false
        profile.retryInterval = String(repeating: "0", count: 8192)
        try exerciseBackgroundSession { socket in
            try BackgroundEvent.accepted.send(to: socket)
            let received = try socket.readRequest()
            check(received.language == .simplifiedChinese)
            check(!received.profile.keepConnected)
            check(try received.profile.configuration(password: received.password).contains("persistent = 0"))
            try BackgroundEvent.finished(0).send(to: socket)
        } client: { session, socket, _ in
            let request = VPNRequest(profile: profile, password: "demo-password", language: .simplifiedChinese)
            check(try session.run(socket: socket, request: request) { _ in } == nil)
        }
    }

    func testBackgroundSessionReturnsExitStatusAndDisconnects() throws {
        try exerciseBackgroundSession { socket in
            try BackgroundEvent.accepted.send(to: socket)
            check(try socket.readRequest().password == "demo-password")
            try BackgroundEvent.output(Data("Tunnel log\n".utf8)).send(to: socket)
            check(try socket.waitForInput(milliseconds: 3000))
            check(try socket.read().isEmpty)
            try BackgroundEvent.finished(VPNWorker.shutdownTimedOut).send(to: socket)
        } client: { session, socket, request in
            var observedLog = Data()
            let failure = try session.run(socket: socket, request: request) { event in
                if case .output(let output) = event {
                    observedLog.append(output)
                    session.stop()
                }
            }
            check(observedLog == Data("Tunnel log\n".utf8))
            check(failure == .disconnectFailed)
        }
    }

    func testBackgroundSessionReportsLostService() throws {
        try exerciseBackgroundSession { socket in
            try BackgroundEvent.accepted.send(to: socket)
            _ = try socket.readRequest()
        } client: { session, socket, request in
            check(try session.run(socket: socket, request: request) { _ in } != nil)
        }
    }

    func testBackgroundRuntimeRequiresProtectedPath() throws {
        check(PrivilegePolicy.isProtectedRuntime(at: "/bin/sh"))
        let listener = try LocalListener()
        let alias = listener.directory + "/shell"
        check(symlink("/bin/sh", alias) == 0)
        defer { unlink(alias) }
        check(!PrivilegePolicy.isProtectedRuntime(at: alias))
        check(!PrivilegePolicy.isProtectedRuntime(at: "/bin/../bin/sh"))
    }

    func testBackgroundSessionControlsVPNWorker(childExit: Int32 = 0) throws {
        let location = try LocalListener()
        let executable = URL(fileURLWithPath: location.directory).appendingPathComponent("test-vpn")
        try """
            #!/bin/sh
            /bin/cat "$2" | /usr/bin/grep -qx 'password = demo-password' || exit 41
            trap 'echo stopped; exit \(childExit)' TERM
            echo ready
            while :; do /bin/sleep 0.1; done
            """.write(to: executable, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: executable) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try exerciseBackgroundSession { socket in
            try BackgroundEvent.accepted.send(to: socket)
            let status = VPNWorker.run(socket: socket, executable: executable.path, stopGracePeriod: 1, onOutput: { data in
                try BackgroundEvent.output(data).send(to: socket)
            })
            try BackgroundEvent.finished(status).send(to: socket)
        } client: { session, socket, request in
            var output = Data()
            let failure = try session.run(socket: socket, request: request) { event in
                if case .output(let data) = event {
                    output.append(data)
                    if String(decoding: output, as: UTF8.self).contains("ready\n") { session.stop() }
                }
            }
            check(childExit == 0 ? failure == nil : failure == .disconnectFailed)
            check(String(decoding: output, as: UTF8.self) == "ready\nstopped\n")
        }
    }

    private func exerciseBackgroundSession(
        server: @escaping (LocalSocket) throws -> Void,
        client: (BackgroundSession, LocalSocket, VPNRequest) throws -> Void
    ) throws {
        let listener = try LocalListener()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                check(try listener.socket.waitForInput(milliseconds: 3000))
                guard let socket = try listener.accept(expectedUser: getuid()) else { fatalError("Wrong peer") }
                try server(socket)
            } catch {
                fatalError("Background test server: \(error)")
            }
        }
        let socket = try LocalSocket.connect(path: listener.path, expectedUser: getuid())
        try client(BackgroundSession(), socket, VPNRequest(profile: sampleProfile, password: "demo-password"))
        check(done.wait(timeout: .now() + 3) == .success)
    }

    func testConfigRejectsValuesThatWouldBeInjectedOrAltered() {
        for invalid in ["", " a", "a ", "a\u{0}b", "a\npppd-plugin = danger", String(repeating: "é", count: 129)] {
            rejects { try sampleProfile.configuration(password: invalid) }
        }
        var profile = sampleProfile
        profile.host = "https://vpn.example.com"
        rejects { try profile.configuration(password: "secret") }
        profile = sampleProfile
        profile.port = "65536"
        rejects { try profile.configuration(password: "secret") }
        profile = sampleProfile
        profile.trustedCertificate = "abcdef"
        rejects { try profile.configuration(password: "secret") }
    }

    func testConfigNormalizesPortAndFingerprint() throws {
        var profile = sampleProfile
        profile.port = "00443"
        profile.trustedCertificate = String(repeating: "AB", count: 32)
        let config = try profile.configuration(password: "secret")
        check(config.contains("port = 443\n"))
        check(config.contains("trusted-cert = \(String(repeating: "ab", count: 32))\n"))
    }

    func testStatusTracksTunnelNotGatewayAndDoesNotUndoDisconnect() {
        var status = TunnelStatus.connecting
        status.observe("INFO:   Connected to gateway.", persistent: true)
        check(status == .connecting)
        status.observe("INFO:   Tunnel is up and running.", persistent: true)
        check(status == .connected)
        status.observe("INFO:   Cancelling threads...", persistent: true)
        check(status == .reconnecting)
        status.observe("INFO:   Tunnel is up and running.", persistent: true)
        check(status == .connected)
        status.observe("INFO:   Setting ppp0 interface down.", persistent: false)
        check(status == .disconnecting)
        status.observe("INFO:   Tunnel is up and running.", persistent: false)
        check(status == .disconnecting)
    }

    func testFirstFailureEntersReconnectOnlyWhenEnabled() {
        var persistent = TunnelStatus.connecting
        var single = TunnelStatus.connecting
        persistent.observe("INFO:   Closed connection to gateway.", persistent: true)
        single.observe("INFO:   Closed connection to gateway.", persistent: false)
        check(persistent == .reconnecting)
        check(single == .connecting)
    }

    func testWorkerPipesConfigAndStopsOnControlEOF() throws {
        let script = """
        #!/bin/sh
        [ "$#" = 2 ] && [ "$1" = -c ] && [ "$2" = /dev/fd/0 ] || exit 40
        /bin/cat "$2" | /usr/bin/grep -qx 'persistent = 20' || exit 41
        trap 'echo stopped; exit 0' TERM
        echo ready
        while :; do /bin/sleep 0.1; done
        """
        try exerciseWorker(script: script, expectedStatus: 0, expectedOutput: "stopped\n")
    }

    func testWorkerStopsWhenChildIgnoresTermination() throws {
        let script = """
        #!/bin/sh
        /bin/cat "$2" >/dev/null
        trap '' TERM
        echo ready
        while :; do /bin/sleep 0.1; done
        """
        try exerciseWorker(script: script, expectedStatus: VPNWorker.shutdownTimedOut,
                           expectedOutput: "VPN routes and DNS may not have been restored.")
    }

    func testFullLogSocketDoesNotBlockSender() throws {
        let listener = try LocalListener()
        let sender = try LocalSocket.connect(path: listener.path, expectedUser: getuid())
        guard let receiver = try listener.accept(expectedUser: getuid()) else { fatalError("Wrong peer UID") }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try sender.send(Data(repeating: 65, count: 2_000_000))
                fatalError("Expected a backpressure error")
            } catch {
                finished.signal()
            }
        }
        withExtendedLifetime(receiver) { check(finished.wait(timeout: .now() + 3) == .success) }
    }

    func testPrivilegePolicy() throws {
        let tool = Process()
        let output = Pipe()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/id")
        tool.arguments = ["-Gn", String(getuid())]
        tool.standardOutput = output
        try tool.run()
        tool.waitUntilExit()
        check(tool.terminationStatus == 0)
        let groups = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check(PrivilegePolicy.isAdministrator(getuid()) == (getuid() != 0 && groups.split(whereSeparator: \.isWhitespace).contains("admin")))
        check(!PrivilegePolicy.isAdministrator(0))
        check(PrivilegePolicy.canAuthorizeExecutable(at: "/bin/sh", for: getuid()))
        check(!PrivilegePolicy.canAuthorizeExecutable(at: "./openfortivpn", for: getuid()))
    }

    private func exerciseWorker(script: String, expectedStatus: Int32, expectedOutput: String) throws {
        let listener = try LocalListener()
        let executable = URL(fileURLWithPath: listener.directory).appendingPathComponent("fake-vpn")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                let socket = try LocalSocket.connect(path: listener.path, expectedUser: getuid())
                check(VPNWorker.run(socket: socket, executable: executable.path, stopGracePeriod: 0.5) == expectedStatus)
            } catch {
                fatalError("Worker setup: \(error)")
            }
        }
        check(try listener.socket.waitForInput(milliseconds: 5000))
        guard let socket = try listener.accept(expectedUser: getuid()) else { fatalError("Wrong worker UID") }
        try socket.sendRequest(VPNRequest(profile: sampleProfile, password: "secret"))
        var output = ""
        while !output.contains("ready\n") {
            check(try socket.waitForInput(milliseconds: 5000))
            let data = try socket.read()
            check(!data.isEmpty)
            output += String(decoding: data, as: UTF8.self)
        }
        socket.endInput()
        while !output.contains(expectedOutput) {
            check(try socket.waitForInput(milliseconds: 5000))
            let data = try socket.read()
            check(!data.isEmpty)
            output += String(decoding: data, as: UTF8.self)
        }
        check(finished.wait(timeout: .now() + 5) == .success)
    }

    private var sampleProfile: VPNProfile {
        VPNProfile(host: "vpn.example.com", username: "alice", realm: "staff", retryInterval: "20")
    }
}

private func check(_ condition: Bool, line: UInt = #line) {
    guard condition else { fatalError("Test failed at line \(line)") }
}

private func rejects<Result>(line: UInt = #line, _ body: () throws -> Result) {
    do {
        _ = try body()
        fatalError("Expected validation failure at line \(line)")
    } catch {}
}

private final class TestPasswords: VPNPasswordStore {
    var values: [UUID: VPNCredential] = [:]

    func read(for id: UUID) throws -> VPNCredential? { values[id] }
    func write(_ credential: VPNCredential, for id: UUID) throws { values[id] = credential }
    func remove(for id: UUID) throws { values.removeValue(forKey: id) }
}
