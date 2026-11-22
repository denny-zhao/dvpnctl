#!/bin/sh
set -eu

image=${1:?Specify the DMG path}
arch=${2:-universal}
archive=$3
scratch=$(mktemp -d)
volume="$scratch/volume"
mkdir "$volume"
trap 'hdiutil detach "$volume" >/dev/null 2>&1 || :; rm -r "$scratch"' EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$volume" "$image" >/dev/null
test -f "$volume/dFortiClient.pkg"
test ! -e "$volume/dFortiClient.app"
pkgutil --expand-full "$volume/dFortiClient.pkg" "$scratch/pkg"
component="$scratch/pkg/dFortiClient-payload.pkg"
payload="$component/Payload"
grep -q 'min="13.0"' "$scratch/pkg/Distribution"
if [ "$arch" = universal ]; then
    grep -q 'hostArchitectures="arm64,x86_64"' "$scratch/pkg/Distribution"
else
    grep -q "hostArchitectures=\"$arch\"" "$scratch/pkg/Distribution"
fi
app="$payload/Applications/dFortiClient.app"
support="$payload/Library/Application Support/dFortiClient"
plist="$payload/Library/LaunchDaemons/local.it-admin.dvpnctl.installed-vpn-service.plist"
test -x "$app/Contents/MacOS/dFortiClient"
test -x "$support/dFortiClientDaemon"
test -x "$support/openfortivpn"
test -x "$component/Scripts/postinstall"
test -x "$component/Scripts/preinstall"
test ! -e "$app/Contents/MacOS/dFortiClientDaemon"
test -f "$volume/Third-Party Sources/$archive"
test -f "$volume/Third-Party Sources/openssl-3.5.9.tar.gz"
for source in build-vpn-runtime.sh openfortivpn-macos-dns.patch macos-vpn-dns.c macos-vpn-dns.h vpn-dns-proxy.c vpn-dns-proxy.h openfortivpn-source.conf; do
    test -f "$volume/Third-Party Sources/$source"
done
test ! -e "$volume/Third-Party Sources/ipv4-dns.c"
test ! -e "$volume/Third-Party Sources/ipv4-dns.h"
plutil -lint "$plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist")" = '/Library/Application Support/dFortiClient/dFortiClientDaemon'
test "$(/usr/libexec/PlistBuddy -c 'Print :Sockets:VPNControl:SockPathName' "$plist")" = /var/run/local.it-admin.dvpnctl.installed-vpn-service.sock
for executable in "$app/Contents/MacOS/dFortiClient" "$support/dFortiClientDaemon" "$support/openfortivpn"; do
    if [ "$arch" = universal ]; then
        lipo "$executable" -verify_arch arm64 x86_64
    else
        lipo "$executable" -verify_arch "$arch"
    fi
    codesign --verify --strict --all-architectures "$executable"
done
otool -L "$support/openfortivpn" |
    awk '
        /^\t.*\/SystemConfiguration\.framework\// { system_configuration = 1 }
        /^\t/ && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad = 1 }
        END { exit (bad || !system_configuration) }
    '
lsbom -p fmug "$component/Bom" | awk -F '\t' '
    $1 ~ /\/(dFortiClientDaemon|openfortivpn|local\.it-admin\.dvpnctl\.installed-vpn-service\.plist)$/ {
        count++
        if ($3 != 0 || $4 != 0 || $2 !~ /100(755|644)$/) bad = 1
    }
    $1 == "./Library/Application Support/dFortiClient" || $1 == "./Library/LaunchDaemons" {
        count++
        if ($3 != 0 || $4 != 0 || $2 != 40755) bad = 1
    }
    END { exit (bad || count != 5) }
'
if lipo "$support/openfortivpn" -verify_arch "$(uname -m)"; then
    test "$("$support/openfortivpn" --version)" = 1.24.1
    "$support/openfortivpn" --help | grep -q -- "--ipv6"
fi
printf 'Verified installer payload, architectures, signatures, and ownership\n'
