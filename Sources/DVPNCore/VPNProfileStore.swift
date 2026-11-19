import Foundation

struct NamedVPNProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var settings = VPNProfile()
    var remembersPassword = false
}

struct VPNCredential: Codable, Equatable {
    let target: VPNLoginTarget
    let password: String
}

protocol VPNPasswordStore {
    func read(for id: UUID) throws -> VPNCredential?
    func write(_ credential: VPNCredential, for id: UUID) throws
    func remove(for id: UUID) throws
}

struct VPNProfileStore {
    var defaults: UserDefaults = .standard
    var passwords: VPNPasswordStore = KeychainVPNPasswords()

    private let key = "vpn-profiles-v2"
    private let legacyKey = "vpn-profile-v1"

    func load() throws -> [NamedVPNProfile] {
        if let data = defaults.data(forKey: key) {
            return try JSONDecoder().decode([NamedVPNProfile].self, from: data)
        }
        guard let data = defaults.data(forKey: legacyKey) else { return [] }
        let settings = try JSONDecoder().decode(VPNProfile.self, from: data)
        let migrated = [NamedVPNProfile(name: "默认 VPN", settings: settings)]
        defaults.set(try JSONEncoder().encode(migrated), forKey: key)
        defaults.removeObject(forKey: legacyKey)
        return migrated
    }

    func password(for profile: NamedVPNProfile) throws -> String? {
        let target = profile.settings.loginTarget
        guard profile.remembersPassword,
              let saved = try load().first(where: { $0.id == profile.id && $0.remembersPassword }),
              saved.settings.loginTarget == target,
              let credential = try passwords.read(for: profile.id), credential.target == target else { return nil }
        return credential.password
    }

    @discardableResult
    func save(_ draft: NamedVPNProfile, password: String) throws -> NamedVPNProfile {
        var profile = draft
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, profile.name.count <= 80,
              profile.name.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw VPNError("请输入 1–80 个字符的配置名称，不要包含控制字符。")
        }
        var profiles = try load()
        guard !profiles.contains(where: { $0.id != profile.id && $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }) else {
            throw VPNError("已有同名 VPN 配置，请换一个名称。")
        }
        let index = profiles.firstIndex { $0.id == profile.id }
        let previous = index.map { profiles[$0] }
        _ = try profile.settings.configuration(password: password.isEmpty ? "placeholder" : password)
        if let index { profiles[index] = profile } else { profiles.append(profile) }
        let data = try JSONEncoder().encode(profiles)

        if profile.remembersPassword {
            if !password.isEmpty {
                let credential = VPNCredential(target: profile.settings.loginTarget, password: password)
                try passwords.write(credential, for: profile.id)
            } else if try self.password(for: profile) == nil {
                throw VPNError("请输入此配置的 VPN 密码后再保存到钥匙串。")
            }
        } else if previous?.remembersPassword == true {
            try passwords.remove(for: profile.id)
        }
        defaults.set(data, forKey: key)
        return profile
    }

    func delete(_ id: UUID) throws {
        var profiles = try load()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let removed = profiles.remove(at: index)
        let data = try JSONEncoder().encode(profiles)
        if removed.remembersPassword { try passwords.remove(for: id) }
        defaults.set(data, forKey: key)
    }
}
