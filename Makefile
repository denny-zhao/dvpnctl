SWIFTC ?= swiftc
ARCH ?= universal
MIN_MACOS = 13.0
CORE = $(wildcard Sources/DVPNCore/*.swift)
UI = $(wildcard Sources/dvpnctl/*.swift)
DAEMON = Sources/Daemon/DaemonMain.swift
DAEMON_HEADER = Sources/Daemon/LaunchSocket.h
DAEMON_PLIST = local.it-admin.dvpnctl.installed-vpn-service.plist
TESTS = $(wildcard Tests/DVPNCoreTests/*.swift)
NAME = dFortiClient
APP = dist/$(NAME).app
DMG = dist/$(NAME).dmg
PKG = dist/$(NAME).pkg
DMG_STAGE = .build/installer-image
PKG_ROOT = .build/installer-root
PKG_SCRIPTS = .build/installer-scripts
SUPPORT = Library/Application Support/dFortiClient
ARCHIVES = .build/sources
VPN_RUNTIME_SOURCES = scripts/build-vpn-runtime.sh scripts/openfortivpn-macos-dns.patch \
	scripts/macos-vpn-dns.c scripts/macos-vpn-dns.h scripts/ipv4-dns.c scripts/ipv4-dns.h
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
SIGN_ID ?= -
SIGN_OPTIONS ?= --options runtime
INSTALLER_SIGN_ID ?=
HOST_ARCHITECTURES = $(if $(filter universal,$(ARCH)),arm64$(comma)x86_64,$(ARCH))
comma := ,

.PHONY: all app pkg dmg install test test-dmg clean vpn-runtime
all: app

.build/$(NAME)-universal: .build/$(NAME)-arm64 .build/$(NAME)-x86_64
	lipo -create -output "$@" $^

.build/$(NAME)Daemon-universal: .build/$(NAME)Daemon-arm64 .build/$(NAME)Daemon-x86_64
	lipo -create -output "$@" $^

.build/$(NAME)-%: $(CORE) $(UI) Makefile
	mkdir -p .build
	$(SWIFTC) -parse-as-library -target $*-apple-macosx$(MIN_MACOS) -O -o $@ $(CORE) $(UI)

.build/$(NAME)Daemon-%: $(CORE) $(DAEMON) $(DAEMON_HEADER) Makefile
	mkdir -p .build
	$(SWIFTC) -parse-as-library -import-objc-header $(DAEMON_HEADER) -target $*-apple-macosx$(MIN_MACOS) -O -o $@ $(CORE) $(DAEMON)

app: .build/$(NAME)-$(ARCH) Info.plist
	mkdir -p "$(APP)/Contents/MacOS"
	install -m 755 "$<" "$(APP)/Contents/MacOS/$(NAME)"
	rm -f "$(APP)/Contents/MacOS/$(NAME)Daemon" "$(APP)/Contents/Library/LaunchDaemons/local.it-admin.dvpnctl.vpn-service.plist"
	install -m 644 Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_ID)" $(SIGN_OPTIONS) "$(APP)"

pkg: app .build/$(NAME)Daemon-$(ARCH) .build/openfortivpn-$(ARCH)
	install -d -m 755 "$(PKG_ROOT)/Applications" "$(PKG_ROOT)/Library" \
		"$(PKG_ROOT)/Library/Application Support" "$(PKG_ROOT)/$(SUPPORT)" \
		"$(PKG_ROOT)/Library/LaunchDaemons" "$(PKG_SCRIPTS)"
	ditto "$(APP)" "$(PKG_ROOT)/Applications/$(NAME).app"
	install -m 755 ".build/$(NAME)Daemon-$(ARCH)" "$(PKG_ROOT)/$(SUPPORT)/dFortiClientDaemon"
	install -m 755 ".build/openfortivpn-$(ARCH)" "$(PKG_ROOT)/$(SUPPORT)/openfortivpn"
	install -m 644 "Packaging/$(DAEMON_PLIST)" "$(PKG_ROOT)/Library/LaunchDaemons/$(DAEMON_PLIST)"
	install -m 755 Packaging/preinstall Packaging/postinstall "$(PKG_SCRIPTS)"
	codesign --force --sign "$(SIGN_ID)" $(SIGN_OPTIONS) --identifier local.it-admin.dvpnctl.installed-vpn-service "$(PKG_ROOT)/$(SUPPORT)/dFortiClientDaemon"
	codesign --force --sign "$(SIGN_ID)" $(SIGN_OPTIONS) --identifier local.it-admin.dvpnctl.openfortivpn "$(PKG_ROOT)/$(SUPPORT)/openfortivpn"
	pkgbuild --root "$(PKG_ROOT)" --component-plist Packaging/components.plist \
		--scripts "$(PKG_SCRIPTS)" --install-location / --ownership recommended \
		--identifier local.it-admin.dvpnctl.installer --version "$(VERSION)" \
		.build/dFortiClient-payload.pkg
	sed 's/@HOST_ARCHITECTURES@/$(HOST_ARCHITECTURES)/g; s/@MIN_MACOS@/$(MIN_MACOS)/g' \
		Packaging/Distribution.xml > .build/Distribution.xml
	productbuild --distribution .build/Distribution.xml --package-path .build \
		$(if $(INSTALLER_SIGN_ID),--sign "$(INSTALLER_SIGN_ID)") "$(PKG)"

dmg: pkg
	mkdir -p "$(DMG_STAGE)/Third-Party Sources"
	install -m 644 "$(PKG)" "$(DMG_STAGE)/$(NAME).pkg"
	install -m 644 "$(ARCHIVES)/openfortivpn-1.24.1.tar.gz" "$(ARCHIVES)/openssl-3.5.9.tar.gz" \
		$(VPN_RUNTIME_SOURCES) "Packaging/Third-Party.txt" "$(DMG_STAGE)/Third-Party Sources"
	hdiutil create -ov -volname "$(NAME)" -srcfolder "$(DMG_STAGE)" -format UDZO "$(DMG)"

install: pkg
	open "$(PKG)"

.build/core-tests: $(CORE) $(TESTS) Makefile
	mkdir -p .build
	$(SWIFTC) -parse-as-library -o $@ $(CORE) $(TESTS)

.build/macos-vpn-dns-tests: Tests/Packaging/macos-vpn-dns-tests.c scripts/macos-vpn-dns.c scripts/macos-vpn-dns.h scripts/ipv4-dns.h Makefile
	mkdir -p .build
	xcrun clang -Wall -Wextra -Werror -I scripts \
		-DSCDynamicStoreCreate=test_store_create -DSCDynamicStoreAddTemporaryValue=test_store_add \
		-Dif_nametoindex=test_if_nametoindex -Dsetsockopt=test_setsockopt -Dconnect=test_connect \
		$< scripts/macos-vpn-dns.c -framework CoreFoundation -framework SystemConfiguration -o "$@"

.build/ipv4-dns-tests: Tests/Packaging/ipv4-dns-tests.c scripts/ipv4-dns.c scripts/ipv4-dns.h Makefile
	mkdir -p .build
	xcrun clang -Wall -Wextra -Werror -I scripts $< scripts/ipv4-dns.c -o "$@"

test: .build/core-tests .build/macos-vpn-dns-tests .build/ipv4-dns-tests
	.build/core-tests
	.build/macos-vpn-dns-tests
	.build/ipv4-dns-tests

.build/openfortivpn-universal: .build/openfortivpn-arm64 .build/openfortivpn-x86_64
	lipo -create -output "$@" $^

.build/sources/.downloaded: scripts/build-vpn-runtime.sh
	/bin/sh scripts/build-vpn-runtime.sh --download "$(ARCHIVES)"
	touch "$@"

.build/openfortivpn-%: $(VPN_RUNTIME_SOURCES) Makefile .build/sources/.downloaded
	mkdir -p .build
	/bin/sh scripts/build-vpn-runtime.sh "$@" "$*" "$(MIN_MACOS)" "$(ARCHIVES)"

vpn-runtime: .build/openfortivpn-$(ARCH)

test-dmg:
	/bin/sh Tests/Packaging/check-image.sh "$(DMG)" "$(ARCH)"

clean:
	rm -rf .build dist
