# dFortiClient

[简体中文](README.md) · **English**

dFortiClient is a macOS menu bar client for OpenFortiVPN. It supports named VPN profiles, passwords stored in macOS Keychain, automatic reconnection, and an optional VPN background service.

## Install

The app requires macOS 13 or later. Homebrew's OpenFortiVPN package may have narrower requirements. To use the standard per-connection approval mode, install OpenFortiVPN if needed:

```sh
brew install openfortivpn
```

Open `dist/dFortiClient.dmg` and drag `dFortiClient.app` to Applications. If you're upgrading from `dvpnctl.app`, disconnect and quit the old app first. The new app uses the same preferences and Keychain identifiers. Don't run both versions at once. Once you've verified the new app, you can remove the old one. You don't need to start the Homebrew OpenFortiVPN service.

Local builds are ad hoc signed and are not notarized by Apple.

## Use the app

1. Select **New** and enter a profile name, VPN gateway (a hostname or IPv4 address, without a scheme or port), port, and username. Fill in the realm or SHA-256 certificate fingerprint only as instructed by your administrator. Leaving the fingerprint blank uses OpenFortiVPN's default TLS validation. Select **Save Profile**. Older single-profile settings are migrated automatically.
2. To remember a password, enter it and select **Save password in macOS Keychain** before saving. Leave the password field blank to use the saved password, or enter a new one to replace it. Saving with the option unchecked or deleting the profile removes its saved password. Changing the gateway, account, realm, or certificate fingerprint prevents reuse of the old password.
3. Use **Connect VPN** in the menu bar to choose a profile. Without a saved password, the app opens the window so you can enter one. Only one VPN connection can run at a time; disconnect before switching profiles.
4. Enable **Reconnect automatically** to retry using OpenFortiVPN's built-in reconnection support (30 seconds by default). A retry does not need another macOS administrator approval, but the VPN gateway may require reauthentication. Disconnect if your credentials are being rejected repeatedly.
5. Closing or minimizing the window leaves the VPN connected. **Quit dFortiClient** requests a disconnect and waits for the connection to exit. If OpenFortiVPN does not exit within 20 seconds, the app stops it; check VPN routes and DNS if that happens.

Open the **Settings** tab in the main window, or choose **Settings…** from the menu bar. Use **Language** to select **System Default**, **English**, or **简体中文**. The interface updates immediately without disconnecting the VPN, and the choice is saved across restarts. Profile names and system dialogs are unaffected. Logs are shown as received; connection worker diagnostics use the language selected when that connection started.

Profile metadata is stored in macOS user preferences. Saved VPN passwords are stored in Keychain, not in preferences, configuration files, or command-line arguments. macOS may ask for Keychain permission again after you update an ad hoc signed build. The app supports username/password login; it does not offer browser-based SAML or a separate one-time-code prompt.

## Optional background service

The background service avoids repeated administrator prompts for manual VPN connections. It is off by default and does not automatically connect the VPN at startup. It never stores the macOS administrator password or changes `sudoers`.

1. Install the protected OpenFortiVPN runtime as described below. Open dFortiClient from Applications, disconnect any active session, and select **Enable…** next to **VPN background service**.
2. In **System Settings → General → Login Items & Extensions**, allow dFortiClient to run in the background and complete the administrator approval.
3. Return to the app and confirm that the service shows **Enabled**. VPN credentials and Keychain permissions are still required as before.

To revoke access, disconnect and select **Disable**, or revoke approval in System Settings. Without the background service, the app asks for administrator approval for each manual connection. Before updating the service, disconnect and disable it, then re-enable it after updating.

Apple requires notarization for distribution builds that include a LaunchDaemon. If macOS rejects registration for a local build, use Developer ID signing and notarization rather than weakening system protections. See [Apple's Service Management guide](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos).

### Install the protected OpenFortiVPN runtime

The background service does not run the user-writable Homebrew executable or load its dynamic libraries. Build OpenFortiVPN with statically linked OpenSSL from the checked upstream source, then install the resulting executable as an administrator. Do not copy the Homebrew executable into this location.

Run these commands from the project directory containing this README and `Makefile`:

```sh
brew install autoconf automake pkgconf openssl@3
make vpn-runtime &&
  sudo install -d -o root -g wheel -m 0755 '/Library/Application Support/dFortiClient' &&
  sudo install -o root -g wheel -m 0755 .build/openfortivpn '/Library/Application Support/dFortiClient/openfortivpn'
```

Run the app from a trusted local macOS administrator account. Only use the app and its privileged runtime on systems where you trust the local administrators and the installed dependencies. Disconnect before replacing the runtime. Routine connections do not need these installation commands.

## Build and test

Install Xcode Command Line Tools with Swift 5.8 or later. From the project directory, run:

```sh
make test
make dmg
```

Run `DVPNCTL_TEST_KEYCHAIN=1 make test` to also test the system Keychain using a temporary entry.

The outputs are `dist/dFortiClient.app` and `dist/dFortiClient.dmg`. The default build is universal. Use `make dmg ARCH=arm64` or `make dmg ARCH=x86_64` for a single architecture, or `make install` to install directly. Before uninstalling, disconnect and disable the background service, then quit and remove the app.

To sign and notarize a distribution build, configure a Developer ID Application identity and a notarization Keychain profile, then follow [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow):

```sh
make dmg SIGN_ID='Developer ID Application: Your Identity'
xcrun notarytool submit dist/dFortiClient.dmg --keychain-profile 'your-notary-profile' --wait
xcrun stapler staple dist/dFortiClient.dmg
```
