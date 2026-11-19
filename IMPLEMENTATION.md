# dvpnctl Implementation Plan

1. Define `VPNProfile` and `TunnelStatus` in `Sources/DVPNCore`. First exercise config validation, persistent intervals and tunnel log transitions with `make test`. Generate only supported OpenFortiVPN settings and never persist the password.
2. Implement `LocalSocket`, `VPNWorker`, and `AuthorizationSession` in `Sources/DVPNCore`. Use the macOS administrator prompt once per session, verify Unix socket peer identities, and pass typed settings over the socket. Feed configuration to `openfortivpn -c /dev/fd/0` through an anonymous pipe. The helper signals only the child it starts and waits for it on disconnect. Test the worker with a local stand-in and no elevated permissions.
3. Build an AppKit menu-bar app with a SwiftUI configuration window in `Sources/dvpnctl`. Closing or minimizing the window hides it without disconnecting. On Quit, request disconnection and wait for the worker to finish. Package an ad-hoc-signed `.app` and drag-to-install `.dmg` with `make dmg`.
4. Run `make test`, verify the bundle signature and disk image, and confirm whether a live VPN session can be tested without private credentials.

## Named profiles and Keychain

1. Add store tests for migrating one legacy profile, saving multiple names, updating and deleting by UUID, and keeping passwords out of the encoded profiles. Test password replacement, removal, and invalidation when the sign-in target changes.
2. Implement `NamedVPNProfile` and `VPNProfileStore` with a separate `VPNPasswordStore`. Use Security's generic-password Keychain items keyed by profile UUID in the production password store.
3. Add profile selection and editing to the window. Build the “连接 VPN” submenu from saved profiles; keep one active session at a time and show its profile name. If a profile has no available password, open the window for entry.
4. Verify the store, Keychain round trip and app bundle; rebuild the universal installer.

## dFortiClient background authorization

1. Test the daemon protocol over local sockets: admission before sending credentials, framing including split log lines, exit status, stop and lost-service handling. Reuse the existing narrow VPN worker and its cleanup path.
2. Add a socket-activated SMAppService LaunchDaemon. Verify the Unix peer UID in each direction; admit only administrators and run a root-owned runtime with no user-writable code or configuration. Forbid concurrent tunnels on the daemon. Do not pass commands, paths, or administrator passwords in the request.
3. Keep the existing per-session authorization when the service is disabled or pending approval. Add explicit enable, System Settings and unregister actions. When enabled, surface service failure instead of silently prompting for administrator credentials.
4. Rename the application, menu and disk image without changing the preferences or Keychain identities. Verify both executable architectures, their signatures, daemon plist, and disk image without approving or enabling a system daemon on the user's behalf.

## English and Simplified Chinese

1. Add tests for system-language resolution, persistence, status labels, and localized error rendering.
2. Store a separate language preference in UserDefaults. Render notices from bilingual values so changing languages refreshes both existing notices and menu commands without replacing the connection model.
3. Provide a language picker in the window and a checked menu-bar submenu. Localize app labels, validation, and authorization messages; leave profile names, external tool logs, and system dialogs unchanged.
4. Cross-link the Chinese and English READMEs. Verify the language tests and rebuild the universal installer.
