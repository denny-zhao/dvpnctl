import Foundation
import ServiceManagement

final class BackgroundService {
    private let service = SMAppService.daemon(plistName: BackgroundSession.label + ".plist")

    enum State: Equatable {
        case disabled, pending, enabled, unavailable

        var title: AppText {
            switch self {
            case .disabled: return AppText("Not enabled", "未启用")
            case .pending: return AppText("Awaiting administrator approval", "等待管理员批准")
            case .enabled: return AppText("Enabled", "已启用")
            case .unavailable: return AppText("Unavailable", "不可用")
            }
        }
    }

    var state: State {
        switch service.status {
        case .notRegistered: return .disabled
        case .requiresApproval: return .pending
        case .enabled: return .enabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func enable() throws {
        do { try service.register() }
        catch {
            if state != .pending && state != .enabled { throw error }
        }
    }

    func disable(completion: @escaping (Error?) -> Void) {
        service.unregister(completionHandler: completion)
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
