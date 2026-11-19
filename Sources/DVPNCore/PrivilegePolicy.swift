import Darwin
import Foundation

enum PrivilegePolicy {
    static let backgroundRuntime = "/Library/Application Support/dFortiClient/openfortivpn"

    static func isProtectedRuntime(at path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "", parts.count > 1, parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        var current = ""
        for (index, part) in parts.enumerated() {
            if index > 0 { current += "/" + part }
            let component = current.isEmpty ? "/" : current
            var details = stat()
            let requiredType = index == parts.count - 1 ? S_IFREG : S_IFDIR
            guard lstat(component, &details) == 0, details.st_uid == 0,
                  details.st_mode & S_IFMT == requiredType,
                  details.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return false }
            if let acl = acl_get_file(component, ACL_TYPE_EXTENDED) {
                var entry: acl_entry_t?
                let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
                acl_free(UnsafeMutableRawPointer(acl))
                if result == 0 { return false }
            }
        }
        return access(path, X_OK) == 0
    }

    static func isAdministrator(_ user: uid_t) -> Bool {
        guard user != 0, let admin = getgrnam("admin")?.pointee.gr_gid,
              let account = getpwuid(user)?.pointee else { return false }
        let name = String(cString: account.pw_name)
        var count: Int32 = 256
        var groups = [Int32](repeating: 0, count: Int(count))
        guard getgrouplist(name, Int32(account.pw_gid), &groups, &count) == 0 else { return false }
        return groups.prefix(Int(count)).contains(Int32(admin))
    }

    static func canAuthorizeExecutable(at path: String, for user: uid_t) -> Bool {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path),
              let admin = getgrnam("admin")?.pointee.gr_gid else { return false }
        let executable = URL(fileURLWithPath: path).standardizedFileURL
        for candidate in [executable, executable.resolvingSymlinksInPath()] {
            var location = candidate
            while true {
                var details = stat()
                guard lstat(location.path, &details) == 0, details.st_uid == 0 || details.st_uid == user else { return false }
                if details.st_mode & S_IFMT != S_IFLNK {
                    guard details.st_mode & S_IWOTH == 0,
                          details.st_mode & S_IWGRP == 0 || details.st_gid == admin || details.st_gid == 0 else { return false }
                }
                if location.path == "/" { break }
                location.deleteLastPathComponent()
            }
        }
        return true
    }
}
