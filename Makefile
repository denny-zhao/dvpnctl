SWIFTC ?= swiftc
ARCH ?= universal
MIN_MACOS = 13.0
CORE = $(wildcard Sources/DVPNCore/*.swift)
UI = $(wildcard Sources/dvpnctl/*.swift)
DAEMON = Sources/Daemon/DaemonMain.swift
DAEMON_HEADER = Sources/Daemon/LaunchSocket.h
DAEMON_PLIST = local.it-admin.dvpnctl.vpn-service.plist
TESTS = $(wildcard Tests/DVPNCoreTests/*.swift)
NAME = dFortiClient
APP = dist/$(NAME).app
DMG = dist/$(NAME).dmg
DMG_STAGE = .build/$(NAME)-dmg
APP_DIR ?= /Applications
SIGN_ID ?= -
SIGN_OPTIONS ?= --options runtime

.PHONY: all app dmg install test clean vpn-runtime
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

app: .build/$(NAME)-$(ARCH) .build/$(NAME)Daemon-$(ARCH) Info.plist $(DAEMON_PLIST)
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Library/LaunchDaemons"
	install -m 755 "$<" "$(APP)/Contents/MacOS/$(NAME)"
	install -m 755 ".build/$(NAME)Daemon-$(ARCH)" "$(APP)/Contents/MacOS/$(NAME)Daemon"
	install -m 644 "$(DAEMON_PLIST)" "$(APP)/Contents/Library/LaunchDaemons/$(DAEMON_PLIST)"
	install -m 644 Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign "$(SIGN_ID)" $(SIGN_OPTIONS) --identifier local.it-admin.dvpnctl.vpn-service "$(APP)/Contents/MacOS/$(NAME)Daemon"
	codesign --force --sign "$(SIGN_ID)" $(SIGN_OPTIONS) "$(APP)"

dmg: app
	mkdir -p "$(DMG_STAGE)"
	ditto "$(APP)" "$(DMG_STAGE)/$(NAME).app"
	ln -sfn /Applications "$(DMG_STAGE)/Applications"
	hdiutil create -ov -volname "$(NAME)" -srcfolder "$(DMG_STAGE)" -format UDZO "$(DMG)"

install: app
	mkdir -p "$(APP_DIR)"
	ditto "$(APP)" "$(APP_DIR)/$(NAME).app"

.build/core-tests: $(CORE) $(TESTS) Makefile
	mkdir -p .build
	$(SWIFTC) -parse-as-library -o $@ $(CORE) $(TESTS)

test: .build/core-tests
	.build/core-tests

vpn-runtime:
	mkdir -p .build
	/bin/sh scripts/build-vpn-runtime.sh .build/openfortivpn

clean:
	rm -rf .build dist
