# dFortiClient

macOS 菜单栏里的 OpenFortiVPN 图形客户端。支持多个命名配置、从菜单选择 VPN、用 macOS 钥匙串保存密码、掉线重连，以及可选的 VPN 后台服务。

## 安装

应用最低要求 macOS 13；Homebrew 对 `openfortivpn` 的支持范围可能更窄。如果没有 OpenFortiVPN，先运行：

```sh
brew install openfortivpn
```

打开 `dist/dFortiClient.dmg`，把 `dFortiClient.app` 拖到「应用程序」，然后打开应用。升级前先断开 VPN 并退出旧版 `dvpnctl.app`；新版保留原有配置和钥匙串标识，不要同时运行两个版本。确认新版正常后，可移除旧应用。不需要启动 Homebrew 的 `openfortivpn` 服务；由应用管理自己的连接。安装包默认使用本地临时签名，未经过 Apple 公证。

## 一次授权，后续免逐次输入系统密码

1. 按下方步骤部署受保护的 OpenFortiVPN。然后从「应用程序」打开 dFortiClient，在未连接时点击「VPN 后台服务」旁的「启用…」。
2. 到「系统设置 → 通用 → 登录项与扩展」允许 dFortiClient 在后台运行，并按 macOS 提示完成管理员批准。
3. 返回应用，确认状态为「已启用」。之后手动连接、断开和切换配置不再使用逐次的管理员密码弹窗。VPN 网关、钥匙串的验证不受影响。

系统批准的是只处理本机管理员 VPN 请求的按需服务，不是 VPN 自动连接。服务不保存系统密码，也不修改 `sudoers`。可在断开 VPN 后点「停用」，或在系统设置中撤销批准；未启用时仍使用原来的逐次授权。应用或签名变更后，macOS 可能要求重新批准。只在信任本机管理员和 Homebrew 安装的机器上启用。

Apple 要求包含 LaunchDaemon 的分发构建经过公证。当前本地安装包是临时签名、未公证版本；若系统拒绝注册，请使用 Developer ID 构建并公证，不要关闭系统安全保护。未注册时仍可按次授权连接。参见 [Apple Service Management 指南](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)。更新后台服务前先断开、停用，更新后重新启用。

### 部署受保护的 OpenFortiVPN

免逐次授权的服务不运行普通用户可改写的 Homebrew 二进制及其动态库。可用以下命令从校验过的上游源码构建静态链接 OpenSSL 的客户端，然后由管理员安装。不要把 Homebrew 的动态链接版本直接复制到此路径。

在仓库根目录 `it-admin` 运行以下命令；`vpn-runtime` 目标定义在 `dvpnctl/Makefile`，不在根目录的 Makefile 里。

```sh
brew install autoconf automake pkgconf openssl@3
make -C dvpnctl vpn-runtime &&
  sudo install -d -o root -g wheel -m 0755 '/Library/Application Support/dFortiClient' &&
  sudo install -o root -g wheel -m 0755 dvpnctl/.build/openfortivpn '/Library/Application Support/dFortiClient/openfortivpn'
```

日常连接不需要运行这些命令。要更新此客户端，先断开 VPN，再构建并以相同方式安装新版。

## 使用

1. 点「新建」，填写配置名称、VPN 网关（域名或 IPv4，不带协议和端口）、端口和用户名，然后点「保存配置」。Realm 和证书 SHA-256 指纹按管理员提供的信息填写，留空指纹时使用 OpenFortiVPN 的默认 TLS 校验。旧版配置会自动迁移为「默认 VPN」。
2. 如需记住密码，输入 VPN 密码，勾选「将密码保存到 macOS 钥匙串」并保存。之后可以留空密码，或输入新密码并保存以替换。取消勾选后保存，或删除配置，会移除该配置的钥匙串密码。修改网关、账号、Realm 或证书指纹后，不会自动复用原密码。
3. 勾选「掉线后自动重连」时，应用为同一 OpenFortiVPN 进程设置原生 `persistent` 间隔（默认 30 秒）。无需在每次重试时重新进行 macOS 管理员授权；VPN 网关本身仍可能要求重新验证。遇到凭据错误时请主动断开，避免反复登录。
4. 在菜单栏点击锁盾图标，展开「连接 VPN」，选择配置。没有保存密码时，应用会打开窗口提示输入。每次只运行一个 VPN；切换前先点「断开 VPN」。系统仍可能请求钥匙串访问许可或管理员授权；「已连接」以隧道就绪日志为准。
5. 关闭或最小化窗口不会断开 VPN。「退出 dFortiClient」会先请求断开并等待本次连接退出。若 OpenFortiVPN 在 20 秒内未正常退出，应用会强制停止它；此时请检查残留的 VPN 路由和 DNS。

非密码配置保存在 macOS 用户偏好设置中。VPN 密码仅在用户选择保存时写入 macOS 钥匙串，不写入配置文件、偏好设置或命令行参数。临时签名版本在更新后，macOS 可能再次询问是否允许读取钥匙串。应用仅支持由可信的本机管理员账户安装和使用；授权后，VPN 连接进程及 Homebrew 提供的 `openfortivpn` 会以管理员权限运行。请确保应用、Homebrew 及其依赖均由可信的管理员管理，不要为标准账户代输管理员密码。

当前支持用户名和密码登录；不提供浏览器 SAML 或手动输入一次性验证码的界面。退出应用或重启 Mac 后不会保持 VPN 连接。

## 构建与测试

需要 Xcode Command Line Tools 和 Swift 5.8+。在 `dvpnctl` 目录运行：

```sh
make test
make dmg
```

可用 `DVPNCTL_TEST_KEYCHAIN=1 make test` 额外验证系统钥匙串；测试使用随机名称创建临时条目，并在结束时删除。

产物为 `dist/dFortiClient.app` 和 `dist/dFortiClient.dmg`。默认构建通用版本（Apple Silicon 和 Intel），也可以用 `make dmg ARCH=x86_64` 或 `make dmg ARCH=arm64` 仅构建一种架构。若要直接安装，运行 `make install`。可用 `SIGN_ID` 指定签名身份。卸载前先断开 VPN 并停用后台服务，再退出应用并将其移到废纸篓。

准备好 Developer ID Application 证书和用于公证的钥匙串配置后，可按 [Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) 构建：

```sh
make dmg SIGN_ID='Developer ID Application: 你的身份'
xcrun notarytool submit dist/dFortiClient.dmg --keychain-profile '你的公证配置' --wait
xcrun stapler staple dist/dFortiClient.dmg
```
