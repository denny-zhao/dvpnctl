import SwiftUI

struct MainWindowView: View {
    @ObservedObject var model: ConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            TabView(selection: $model.windowTab) {
                ConnectionView(model: model)
                    .tabItem { Text(model.localized("Connections", "连接")) }
                    .tag(WindowTab.connections)

                settings
                    .tabItem { Text(model.localized("Settings", "设置")) }
                    .tag(WindowTab.settings)
            }
        }
        .padding(16)
        .frame(minWidth: 565, minHeight: 665)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("dFortiClient").font(.title2.bold())
                Text(model.localized("OpenFortiVPN console", "OpenFortiVPN 控制台")).foregroundStyle(.secondary)
            }
            Spacer()
            let status = model.status.title.render(model.language)
            Label(model.activeProfileName.map { "\($0) · \(status)" } ?? status, systemImage: "circle.fill")
                .lineLimit(1)
                .font(.callout.weight(.medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(statusColor.opacity(0.10), in: Capsule())
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: return .secondary
        case .connected: return .green
        case .reconnecting: return .orange
        default: return .accentColor
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                HStack {
                    Text(model.localized("Language", "语言"))
                    Spacer()
                    Picker(model.localized("Language", "语言"),
                           selection: Binding(get: { model.languageChoice }, set: model.selectLanguage)) {
                        ForEach(LanguageChoice.allCases, id: \.self) { choice in
                            Text(choice.title.render(model.language)).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                .padding(8)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ConnectionView: View {
    @ObservedObject var model: ConnectionModel
    @State private var pendingProfileAction: ProfileAction?

    private enum ProfileAction: Identifiable {
        case select(UUID?)
        case delete

        var id: String {
            switch self {
            case .select: return "select"
            case .delete: return "delete"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    GridRow {
                        Text(localized("Saved profiles", "已保存配置"))
                        HStack {
                            Picker(localized("Saved profiles", "已保存配置"), selection: Binding(get: { model.savedDraft?.id }, set: requestSelection)) {
                                if model.savedDraft == nil { Text(localized("New profile", "新配置")).tag(UUID?.none) }
                                ForEach(model.profiles) { profile in
                                    Text(profile.name).tag(Optional(profile.id))
                                }
                            }
                            .labelsHidden()
                            Button(localized("New", "新建")) { requestSelection(nil) }
                            Button(localized("Delete", "删除")) { pendingProfileAction = .delete }
                                .disabled(model.savedDraft == nil)
                        }
                    }
                    GridRow {
                        Text(localized("Profile name", "配置名称"))
                        TextField(localized("e.g. Work VPN", "例如：公司 VPN"), text: $model.draft.name)
                            .accessibilityLabel(localized("Profile name", "配置名称"))
                    }
                    GridRow {
                        Text(localized("VPN gateway", "VPN 网关"))
                        HStack {
                            TextField("vpn.example.com", text: $model.draft.settings.host).accessibilityLabel(localized("VPN gateway", "VPN 网关"))
                            TextField("443", text: $model.draft.settings.port).frame(width: 70).accessibilityLabel(localized("Port", "端口"))
                        }
                    }
                    GridRow {
                        Text(localized("Username", "用户名"))
                        TextField(localized("VPN account", "VPN 账户"), text: $model.draft.settings.username)
                            .accessibilityLabel(localized("Username", "用户名"))
                    }
                    GridRow {
                        Text(localized("VPN password", "VPN 密码"))
                        SecureField(model.canReuseSavedPassword
                                    ? localized("Use saved password or enter a new one", "使用钥匙串密码（可输入新密码替换）")
                                    : localized("Enter VPN password", "输入 VPN 密码"),
                                    text: $model.password).accessibilityLabel(localized("VPN password", "VPN 密码"))
                    }
                    GridRow {
                        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
                        Toggle(localized("Save password in macOS Keychain", "将密码保存到 macOS 钥匙串"), isOn: $model.draft.remembersPassword)
                    }
                    GridRow {
                        Text("Realm")
                        TextField(localized("Optional", "可选"), text: $model.draft.settings.realm).accessibilityLabel("Realm")
                    }
                    GridRow {
                        Text(localized("Certificate fingerprint", "证书指纹"))
                        TextField(localized("Optional SHA-256 fingerprint from your administrator", "可选 · 由管理员提供的 SHA-256 指纹"),
                                  text: $model.draft.settings.trustedCertificate)
                            .accessibilityLabel(localized("Certificate fingerprint", "证书指纹"))
                    }
                }
                .padding(8)
            }
            .disabled(model.isActive)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle(localized("Reconnect automatically", "掉线后自动重连"), isOn: $model.draft.settings.keepConnected)
                        Spacer()
                        if model.draft.settings.keepConnected {
                            Text(localized("Retry interval", "重试间隔"))
                            TextField("30", text: $model.draft.settings.retryInterval).frame(width: 60)
                                .accessibilityLabel(localized("Retry interval", "重试间隔"))
                            Text(localized("seconds", "秒")).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(localized("Prefer IPv4 when the VPN only has an IPv4 default route",
                                     "VPN 只有 IPv4 默认路由时优先使用 IPv4"),
                           isOn: Binding(get: { model.draft.settings.preferIPv4 == true },
                                         set: { model.draft.settings.preferIPv4 = $0 ? true : nil }))
                        .help(localized("Try this if some websites or apps fail while the VPN is connected. Reconnect to apply.",
                                        "连着 VPN 时如果部分网站或应用无法访问，可以尝试开启。重新连接后生效。"))
                }
                .padding(8)
            }
            .disabled(model.isActive)

            HStack {
                if let notice = model.notice {
                    Text(notice.render(model.language)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button(localized("Save Profile", "保存配置"), action: model.save).disabled(model.isActive)
                Button(model.isActive ? localized("Disconnect", "断开") : localized("Connect", "连接")) {
                    if model.isActive { model.disconnect() }
                    else { model.connect() }
                }
                .buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(localized("Connection log", "连接日志")).font(.headline)
                ScrollViewReader { scroll in
                    ScrollView {
                        Text(model.logs.isEmpty ? localized("Connection messages will appear here.", "连接后，日志会显示在这里。") : model.logs.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(model.logs.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("log-end")
                    }
                    .onChange(of: model.logs) { _ in scroll.scrollTo("log-end", anchor: .bottom) }
                }
                .padding(10)
                .frame(minHeight: 100, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }

            Label(localized("Control the VPN from the menu bar after closing or minimizing this window.", "关闭或最小化窗口后，仍可从菜单栏控制 VPN。"),
                  systemImage: "menubar.rectangle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .alert(item: $pendingProfileAction) { action in
            switch action {
            case .select(let id):
                return Alert(title: Text(localized("Discard unsaved changes?", "放弃未保存的修改？")),
                             primaryButton: .destructive(Text(localized("Discard Changes", "放弃修改"))) { model.selectProfile(id) },
                             secondaryButton: .cancel(Text(localized("Cancel", "取消"))))
            case .delete:
                let name = model.savedDraft?.name ?? ""
                return Alert(title: Text(localized("Delete “\(name)”?", "删除「\(name)」？")),
                             message: Text(localized("This removes the profile and its saved VPN password.", "此配置及其保存的 VPN 密码将被删除。")),
                             primaryButton: .destructive(Text(localized("Delete", "删除")), action: model.deleteProfile),
                             secondaryButton: .cancel(Text(localized("Cancel", "取消"))))
            }
        }
    }

    private func localized(_ english: String, _ chinese: String) -> String {
        model.localized(english, chinese)
    }

    private func requestSelection(_ id: UUID?) {
        if let id, id == model.draft.id { return }
        if model.hasUnsavedChanges { pendingProfileAction = .select(id) }
        else { model.selectProfile(id) }
    }
}
