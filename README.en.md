# dFortiClient

[简体中文](README.md) · **English**

dFortiClient is a macOS menu bar client for OpenFortiVPN. It supports named profiles, passwords stored in macOS Keychain, and automatic reconnection. The installer includes OpenFortiVPN; Homebrew is not required.

## Install

Build on macOS 13 or later with Apple's Xcode Command Line Tools (Swift 5.8 or later) and an internet connection:

```sh
git clone https://github.com/denny-zhao/dvpnctl.git
cd dvpnctl
make dmg
```

Open `dist/dFortiClient.dmg`, double-click `dFortiClient.pkg`, and approve the installation in macOS Installer. Then open dFortiClient from Applications. The package installs the app, protected OpenFortiVPN runtime, and on-demand VPN service together. You don't need to install Homebrew, build dependencies separately, copy files, or enable a background mode inside the app.

Before upgrading, disconnect and quit the old app. Disable its optional background service if it was enabled. Preferences and Keychain identifiers stay the same. If the older `dvpnctl.app` remains, don't run both apps at once.

Installation requires administrator approval. Connections don't prompt for the Mac administrator password each time. The service accepts VPN requests only from local administrators; it does not store the system password, edit `sudoers`, or connect the VPN automatically at boot. If macOS or your organization's policy rejects a local unnotarized installer, use a Developer ID-signed and notarized build instead of weakening system protections.

## Use the app

1. Select **New** and enter a profile name, VPN gateway (a hostname or IPv4 address, without a scheme or port), port, and username. Fill in the realm or SHA-256 certificate fingerprint only as instructed by your administrator. Leaving the fingerprint blank uses OpenFortiVPN's default TLS validation. Select **Save Profile**. Older single-profile settings are migrated automatically.
2. To remember a password, enter it and select **Save password in macOS Keychain** before saving. Leave the password field blank to use the saved password, or enter a new one to replace it. Saving with the option unchecked or deleting the profile removes its saved password. Changing the gateway, account, realm, or certificate fingerprint prevents reuse of the old password.
3. Use **Connect VPN** in the menu bar to choose a profile. Without a saved password, the app opens the window so you can enter one. Only one VPN connection can run at a time; disconnect before switching profiles.
4. Enable **Reconnect automatically** to retry using OpenFortiVPN's built-in reconnection support (30 seconds by default). A retry does not need another macOS administrator approval, but the VPN gateway may require reauthentication. Disconnect if your credentials are being rejected repeatedly.
5. Closing or minimizing the window leaves the VPN connected. **Quit dFortiClient** requests a disconnect and waits for the connection to exit. If OpenFortiVPN does not exit within 20 seconds, the app stops it. Check for leftover VPN routes if that happens.
6. When connected, VPN-provided DNS servers with a route through the tunnel are registered with the macOS system resolver in a temporary record. The registration is removed on disconnect. Use `scutil --dns` to inspect the resolver.
7. During an OpenFortiVPN session, a dedicated resolver uses IPv4 for ChatGPT and Codex service domains. It obtains IPv4 addresses from the VPN DNS servers. The rule is removed on disconnect.

Open the **Settings** tab in the main window, or choose **Settings…** from the menu bar. Use **Language** to select **System Default**, **English**, or **简体中文**. The interface updates immediately without disconnecting the VPN, and the choice is saved across restarts. Profile names and system dialogs are unaffected. Logs are shown as received; connection worker diagnostics use the language selected when that connection started.

Profile metadata is stored in macOS user preferences. Saved VPN passwords are stored in Keychain, not in preferences, configuration files, or command-line arguments. macOS may ask for Keychain permission again after you update an ad hoc signed build. The app supports username/password login; it does not offer browser-based SAML or a separate one-time-code prompt.

## Build and test

Install Xcode Command Line Tools with Swift 5.8 or later. From the project directory, run:

```sh
make test
make test-dmg
```

Run `DVPNCTL_TEST_KEYCHAIN=1 make test` to also test the system Keychain using a temporary entry.

`make dmg` downloads and verifies pinned OpenFortiVPN and OpenSSL sources, builds them, and creates the installer. The default build is universal. Use `ARCH=arm64` or `ARCH=x86_64` for a single architecture. The first build takes longer; subsequent builds reuse the output. `make test-dmg` inspects the built installer without installing it.

To uninstall, disconnect and quit the app, then unload the service and remove the installed files. This leaves user preferences and Keychain entries intact.

```sh
sudo launchctl bootout system/local.it-admin.dvpnctl.installed-vpn-service
sudo rm '/Library/LaunchDaemons/local.it-admin.dvpnctl.installed-vpn-service.plist'
sudo rm -r '/Library/Application Support/dFortiClient' '/Applications/dFortiClient.app'
sudo pkgutil --forget local.it-admin.dvpnctl.installer
```

To sign and notarize a distribution build, configure Developer ID Application and Installer identities and a notarization Keychain profile, then follow [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow):

```sh
make dmg SIGN_ID='Developer ID Application: Your Identity' \
  INSTALLER_SIGN_ID='Developer ID Installer: Your Identity'
xcrun notarytool submit dist/dFortiClient.dmg --keychain-profile 'your-notary-profile' --wait
xcrun stapler staple dist/dFortiClient.dmg
```
