import Foundation
import Combine
import Darwin

enum WindowTab {
    case connections
    case settings
}

final class ConnectionModel: ObservableObject {
    @Published var windowTab = WindowTab.connections
    @Published private(set) var profiles: [NamedVPNProfile] = []
    @Published var draft = NamedVPNProfile() {
        didSet {
            if draft.id != oldValue.id || draft.settings.loginTarget != oldValue.settings.loginTarget {
                password = ""
            }
        }
    }
    @Published var password = ""
    @Published private(set) var status = TunnelStatus.idle
    @Published private(set) var activeProfileName: String?
    @Published private(set) var logs: [String] = []
    @Published private(set) var notice: AppText?
    @Published private(set) var languageChoice = LanguageChoice.load()

    var onStateChanged: (() -> Void)?
    var onSessionEnded: (() -> Void)?
    private let store: VPNProfileStore
    private var session: BackgroundSession?
    private var isPersistent = false
    private var pendingLog = Data()

    init(store: VPNProfileStore = VPNProfileStore()) {
        self.store = store
        do {
            profiles = try store.load()
            draft = profiles.first ?? NamedVPNProfile()
        } catch {
            notice = AppText("Could not load VPN profiles: ", "无法读取 VPN 配置：").appending(.from(error))
        }
    }

    var isActive: Bool { session != nil }
    var language: AppLanguage { languageChoice.resolve() }

    func localized(_ english: String, _ chinese: String) -> String {
        AppText(english, chinese).render(language)
    }

    func selectLanguage(_ choice: LanguageChoice) {
        guard choice != languageChoice else { return }
        choice.save()
        languageChoice = choice
        onStateChanged?()
    }

    var savedDraft: NamedVPNProfile? { profiles.first { $0.id == draft.id } }
    var hasUnsavedChanges: Bool {
        if !password.isEmpty { return true }
        if let saved = savedDraft { return saved != draft || saved.settings.loginTarget != draft.settings.loginTarget }
        return !draft.name.isEmpty || draft.settings != VPNProfile() || draft.remembersPassword
    }
    var canReuseSavedPassword: Bool {
        draft.remembersPassword && savedDraft?.remembersPassword == true
            && savedDraft?.settings.loginTarget == draft.settings.loginTarget
    }

    func selectProfile(_ id: UUID?) {
        guard !isActive else { return }
        draft = profiles.first { $0.id == id } ?? NamedVPNProfile()
        password = ""
        notice = nil
    }

    func deleteProfile() {
        guard !isActive, let saved = savedDraft else { return }
        do {
            try store.delete(saved.id)
            profiles.removeAll { $0.id == saved.id }
            selectProfile(profiles.first?.id)
            onStateChanged?()
            notice = AppText("Profile deleted.", "已删除配置。")
        } catch {
            notice = .from(error)
        }
    }

    func connect() { _ = connectProfile(draft, enteredPassword: password, saveDraft: true) }

    @discardableResult
    func connectSavedProfile(_ id: UUID) -> Bool {
        guard !isActive, let profile = profiles.first(where: { $0.id == id }) else { return false }
        if connectProfile(profile, enteredPassword: "", saveDraft: false) { return true }
        if !hasUnsavedChanges {
            draft = profile
            password = ""
        } else if draft.id != profile.id, let failure = notice {
            notice = failure.appending(AppText(" Save or discard your changes before selecting this profile.", " 请先保存或放弃当前修改，再选择该配置。"))
        }
        return false
    }

    private func connectProfile(_ profile: NamedVPNProfile, enteredPassword: String, saveDraft: Bool) -> Bool {
        guard !isActive else { return false }
        do {
            let secret: String
            if !enteredPassword.isEmpty {
                secret = enteredPassword
            } else if let stored = try store.password(for: profile) {
                secret = stored
            } else {
                if profile.name.isEmpty { throw VPNError("Enter your VPN password.", "请输入 VPN 密码。") }
                throw VPNError("Enter the VPN password for “\(profile.name)”.", "请为「\(profile.name)」输入 VPN 密码。")
            }
            _ = try profile.settings.configuration(password: secret)
            let user = getuid()
            guard PrivilegePolicy.isAdministrator(user) else {
                throw VPNError("Run dFortiClient from a trusted local macOS administrator account.", "请从受信任的本机 macOS 管理员账户启动 dFortiClient。")
            }
            if saveDraft { try persistDraft() }
            let request = VPNRequest(profile: profile.settings, password: secret, language: language)
            let current = BackgroundSession()
            session = current
            isPersistent = profile.settings.keepConnected
            activeProfileName = saveDraft ? draft.name : profile.name
            if saveDraft { password = "" }
            logs = []
            pendingLog.removeAll()
            notice = nil
            setStatus(.connecting)
            current.start(request: request) { [weak self, weak current] event in
                DispatchQueue.main.async {
                    guard let self, let current, self.session === current else { return }
                    self.receive(event)
                }
            }
            return true
        } catch {
            notice = .from(error)
            return false
        }
    }

    func disconnect() {
        guard let session else { return }
        setStatus(.disconnecting)
        session.stop()
    }

    func save() {
        guard !isActive else { return }
        do {
            try persistDraft()
            if draft.remembersPassword { password = "" }
            notice = draft.remembersPassword
                ? AppText("Profile saved. The password is stored in macOS Keychain.", "配置已保存，密码存于 macOS 钥匙串。")
                : AppText("Profile saved without its password.", "配置已保存，未保存密码。")
        } catch {
            notice = .from(error)
        }
    }

    private func persistDraft() throws {
        draft = try store.save(draft, password: password)
        if let index = profiles.firstIndex(where: { $0.id == draft.id }) {
            profiles[index] = draft
        } else {
            profiles.append(draft)
        }
        onStateChanged?()
    }

    private func receive(_ event: BackgroundSession.Event) {
        switch event {
        case .authorized:
            if status != .disconnecting { setStatus(.connecting) }
        case .output(let data):
            pendingLog.append(data)
            while let newline = pendingLog.firstIndex(of: 10) {
                appendLog(pendingLog.prefix(upTo: newline))
                pendingLog.removeSubrange(...newline)
            }
            if pendingLog.count > 16_384 { pendingLog = Data(pendingLog.suffix(4096)) }
        case .finished(let failure):
            if !pendingLog.isEmpty { appendLog(pendingLog) }
            pendingLog.removeAll()
            session = nil
            activeProfileName = nil
            notice = failure
            setStatus(.idle)
            onSessionEnded?()
        }
    }

    private func appendLog(_ data: Data) {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return }
        var next = status
        next.observe(line, persistent: isPersistent)
        if next != status { setStatus(next) }
        logs.append(line)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    private func setStatus(_ newStatus: TunnelStatus) {
        status = newStatus
        onStateChanged?()
    }
}
