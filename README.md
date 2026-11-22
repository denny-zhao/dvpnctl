# dFortiClient

**简体中文** · [English](README.en.md)

macOS 菜单栏里的 OpenFortiVPN 图形客户端。支持多个命名配置、菜单栏连接、钥匙串密码保存和自动重连。安装包内置 OpenFortiVPN，无需 Homebrew。

## 安装

在 macOS 13 或更新版本上，需要 Apple 的 Xcode Command Line Tools（Swift 5.8 或以上）和网络。工具就绪后：

```sh
git clone https://github.com/denny-zhao/dvpnctl.git
cd dvpnctl
make dmg
```

打开 `dist/dFortiClient.dmg`，双击里面的 `dFortiClient.pkg`，按 Installer 提示授权安装，然后从「应用程序」打开 dFortiClient。安装包会同时部署应用、受保护的 OpenFortiVPN 和按需后台服务。无需另装 Homebrew、编译依赖、复制文件或在应用内启用后台模式。

升级前请断开 VPN 并退出旧应用。如果旧版启用了可选后台服务，请先在旧版中停用。配置和钥匙串标识保持不变；如果还留着名称为 `dvpnctl.app` 的旧版，请勿同时运行两个版本。

安装需要管理员授权，日常连接无需逐次输入 Mac 管理员密码。后台服务只处理本机管理员的连接请求，不保存系统密码、不修改 `sudoers`，也不会开机自动连接 VPN。若 macOS 或组织策略阻止本地未公证安装包，请使用经 Developer ID 签名并公证的版本，不要关闭系统安全保护。

## 使用

在主窗口切换到「设置」标签，或从菜单栏打开「设置…」，再用「语言」选择「跟随系统」、English 或简体中文。界面立即更新，不会中断连接，选择会在重启后保留。配置名称和 macOS 系统对话框不受影响；日志会原样显示，连接进程的诊断文字使用启动该连接时的语言。

1. 点「新建」，填写配置名称、VPN 网关（域名或 IPv4，不带协议和端口）、端口和用户名，然后点「保存配置」。Realm 和证书 SHA-256 指纹按管理员提供的信息填写，留空指纹时使用 OpenFortiVPN 的默认 TLS 校验。旧版配置会自动迁移为「默认 VPN」。
2. 如需记住密码，输入 VPN 密码，勾选「将密码保存到 macOS 钥匙串」并保存。之后可以留空密码，或输入新密码并保存以替换。取消勾选后保存，或删除配置，会移除该配置的钥匙串密码。修改网关、账号、Realm 或证书指纹后，不会自动复用原密码。
3. 勾选「掉线后自动重连」时，应用为同一 OpenFortiVPN 进程设置原生 `persistent` 间隔（默认 30 秒）。无需在每次重试时重新进行 macOS 管理员授权；VPN 网关本身仍可能要求重新验证。遇到凭据错误时请主动断开，避免反复登录。
4. 在菜单栏点击锁盾图标，展开「连接 VPN」，选择配置。没有保存密码时，应用会打开窗口提示输入。每次只运行一个 VPN；切换前先点「断开 VPN」。系统仍可能请求钥匙串访问许可；「已连接」以隧道就绪日志为准。
5. 关闭或最小化窗口不会断开 VPN。「退出 dFortiClient」会先请求断开并等待本次连接退出。若 OpenFortiVPN 在 20 秒内未正常退出，应用会强制停止它。此时请检查残留的 VPN 路由。
6. 连接时，VPN 下发且可以经隧道路由的 DNS 会作为独立的 VPN 会话记录临时注册到 macOS 系统解析器，断开时自动清理。可用 `scutil --dns` 查看系统解析器。
7. 在 OpenFortiVPN 会话内，ChatGPT 和 Codex 的相关域名使用独立的 IPv4 解析规则。IPv4 地址由 VPN DNS 提供。规则随 VPN 断开移除。

非密码配置保存在 macOS 用户偏好设置中。VPN 密码仅在用户选择保存时写入 macOS 钥匙串，不写入配置文件、偏好设置或命令行参数。临时签名版本在更新后，macOS 可能再次询问是否允许读取钥匙串。

当前支持用户名和密码登录；不提供浏览器 SAML 或手动输入一次性验证码的界面。退出应用或重启 Mac 后不会保持 VPN 连接。

## 构建与测试

需要 Xcode Command Line Tools 和 Swift 5.8+。在 `dvpnctl` 目录运行：

```sh
make test
make test-dmg
```

可用 `DVPNCTL_TEST_KEYCHAIN=1 make test` 额外验证系统钥匙串；测试使用随机名称创建临时条目，并在结束时删除。

`make dmg` 会下载并校验固定版本的 OpenFortiVPN 和 OpenSSL，从源码编译并打包。默认构建 Apple Silicon 和 Intel 的通用版本；也可以指定 `ARCH=arm64` 或 `ARCH=x86_64`。首次构建耗时较长，后续会复用构建产物。`make test-dmg` 只检查已构建的安装包，不会安装它。

卸载时先断开 VPN 并退出应用，再卸载后台服务并移除下列安装文件。此操作不会删除用户配置和钥匙串条目。

```sh
sudo launchctl bootout system/local.it-admin.dvpnctl.installed-vpn-service
sudo rm '/Library/LaunchDaemons/local.it-admin.dvpnctl.installed-vpn-service.plist'
sudo rm -r '/Library/Application Support/dFortiClient' '/Applications/dFortiClient.app'
sudo pkgutil --forget local.it-admin.dvpnctl.installer
```

准备好 Developer ID Application 证书和用于公证的钥匙串配置后，可按 [Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) 构建：

```sh
make dmg SIGN_ID='Developer ID Application: 你的身份' \
  INSTALLER_SIGN_ID='Developer ID Installer: 你的身份'
xcrun notarytool submit dist/dFortiClient.dmg --keychain-profile '你的公证配置' --wait
xcrun stapler staple dist/dFortiClient.dmg
```
