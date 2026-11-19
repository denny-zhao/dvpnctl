import SwiftUI

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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("dFortiClient").font(.title2.bold())
                    Text("OpenFortiVPN 控制台").foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.activeProfileName.map { "\($0) · \(model.status.rawValue)" } ?? model.status.rawValue,
                      systemImage: "circle.fill")
                    .lineLimit(1)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(statusColor.opacity(0.10), in: Capsule())
            }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    GridRow {
                        Text("已保存配置")
                        HStack {
                            Picker("已保存配置", selection: Binding(get: { model.savedDraft?.id }, set: requestSelection)) {
                                if model.savedDraft == nil { Text("新配置").tag(UUID?.none) }
                                ForEach(model.profiles) { profile in
                                    Text(profile.name).tag(Optional(profile.id))
                                }
                            }
                            .labelsHidden()
                            Button("新建") { requestSelection(nil) }
                            Button("删除") { pendingProfileAction = .delete }
                                .disabled(model.savedDraft == nil)
                        }
                    }
                    GridRow {
                        Text("配置名称")
                        TextField("例如：公司 VPN", text: $model.draft.name).accessibilityLabel("配置名称")
                    }
                    GridRow {
                        Text("VPN 网关")
                        HStack {
                            TextField("vpn.example.com", text: $model.draft.settings.host).accessibilityLabel("VPN 网关")
                            TextField("443", text: $model.draft.settings.port).frame(width: 70).accessibilityLabel("端口")
                        }
                    }
                    GridRow {
                        Text("用户名")
                        TextField("VPN 账户", text: $model.draft.settings.username).accessibilityLabel("用户名")
                    }
                    GridRow {
                        Text("VPN 密码")
                        SecureField(model.canReuseSavedPassword ? "使用钥匙串密码（可输入新密码替换）" : "输入 VPN 密码",
                                    text: $model.password).accessibilityLabel("VPN 密码")
                    }
                    GridRow {
                        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
                        Toggle("将密码保存到 macOS 钥匙串", isOn: $model.draft.remembersPassword)
                    }
                    GridRow {
                        Text("Realm")
                        TextField("可选", text: $model.draft.settings.realm).accessibilityLabel("Realm")
                    }
                    GridRow {
                        Text("证书指纹")
                        TextField("可选 · 由管理员提供的 SHA-256 指纹", text: $model.draft.settings.trustedCertificate)
                            .accessibilityLabel("证书指纹")
                    }
                }
                .padding(8)
            } label: {
                Text("连接配置").font(.headline)
            }
            .disabled(model.isActive)

            GroupBox {
                HStack {
                    Toggle("掉线后自动重连", isOn: $model.draft.settings.keepConnected)
                    Spacer()
                    if model.draft.settings.keepConnected {
                        Text("重试间隔")
                        TextField("30", text: $model.draft.settings.retryInterval).frame(width: 60).accessibilityLabel("重试间隔")
                        Text("秒").foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            .disabled(model.isActive)

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VPN 后台服务 · \(model.backgroundState.title)").font(.headline)
                        Text("管理员首次批准后，手动连接无需逐次输入系统密码。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch model.backgroundState {
                    case .disabled, .unavailable:
                        Button("启用…", action: model.enableBackgroundService)
                    case .pending, .enabled:
                        Button("系统设置…", action: model.openBackgroundSettings)
                        Button("停用", action: model.disableBackgroundService)
                    }
                }
                .padding(8)
            }
            .disabled(model.isActive || model.changingBackgroundService)

            HStack {
                if let notice = model.notice {
                    Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("保存配置", action: model.save).disabled(model.isActive)
                Button(model.isActive ? "断开" : "连接") {
                    if model.isActive { model.disconnect() }
                    else { model.connect() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.changingBackgroundService)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("连接日志").font(.headline)
                ScrollViewReader { scroll in
                    ScrollView {
                        Text(model.logs.isEmpty ? "连接后，日志会显示在这里。" : model.logs.joined(separator: "\n"))
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

            Label("关闭或最小化窗口后，仍可从菜单栏控制 VPN。", systemImage: "menubar.rectangle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(minWidth: 565, minHeight: 675)
        .alert(item: $pendingProfileAction) { action in
            switch action {
            case .select(let id):
                return Alert(title: Text("放弃未保存的修改？"),
                             primaryButton: .destructive(Text("放弃修改")) { model.selectProfile(id) },
                             secondaryButton: .cancel())
            case .delete:
                return Alert(title: Text("删除「\(model.savedDraft?.name ?? "")」？"),
                             message: Text("此配置及其保存的 VPN 密码将被删除。"),
                             primaryButton: .destructive(Text("删除"), action: model.deleteProfile),
                             secondaryButton: .cancel())
            }
        }
    }

    private func requestSelection(_ id: UUID?) {
        if let id, id == model.draft.id { return }
        if model.hasUnsavedChanges { pendingProfileAction = .select(id) }
        else { model.selectProfile(id) }
    }

    private var statusColor: Color {
        switch model.status {
        case .idle: return .secondary
        case .connected: return .green
        case .reconnecting: return .orange
        default: return .accentColor
        }
    }
}
