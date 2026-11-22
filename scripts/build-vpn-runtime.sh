#!/bin/sh
set -eu

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
script_dir=$(cd "$(dirname "$0")" && pwd)
case "${1:-}" in
    --download) archives=${2:?Specify the source archive directory} ;;
    *) archives=${4:?Specify the source archive directory} ;;
esac
case "$archives" in /*) ;; *) archives="$PWD/$archives";; esac
openssl_version=3.5.9
forti_version=1.24.1
openssl_archive="$archives/openssl-$openssl_version.tar.gz"
forti_archive="$archives/openfortivpn-$forti_version.tar.gz"
mkdir -p "$archives"
scratch=$(mktemp -d)
trap 'rm -r "$scratch"' EXIT

verify() { printf '%s  %s\n' "$2" "$1" | shasum -a 256 -c; }

download() {
    if [ ! -f "$1" ]; then
        printf 'Downloading %s …\n' "${1##*/}"
        curl --fail --location --silent --show-error --retry 2 --proto '=https' \
            --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
            "$3" -o "$scratch/download"
        verify "$scratch/download" "$2"
        mv -f "$scratch/download" "$1"
    fi
    verify "$1" "$2"
}

download "$openssl_archive" 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a \
    "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz"
download "$forti_archive" c40d33acd97b89c2e943bfd839c19b69e5a7a5997052e2fc9a595602745c0465 \
    "https://codeload.github.com/adrienverge/openfortivpn/tar.gz/refs/tags/v$forti_version"

if [ "$1" = --download ]; then exit 0; fi
destination=$1
arch=$2
deployment_target=$3
case "$destination" in /*) ;; *) destination="$PWD/$destination";; esac
case "$arch" in
    arm64) openssl_target=darwin64-arm64-cc ;;
    x86_64) openssl_target=darwin64-x86_64-cc ;;
    *) printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 1 ;;
esac
export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
unset SDKROOT CFLAGS CPPFLAGS LDFLAGS
sdk=$(xcrun --sdk macosx --show-sdk-path)
CC=$(xcrun --sdk macosx --find clang)
export CC

tar -xzf "$openssl_archive" -C "$scratch"
openssl_source="$scratch/openssl-$openssl_version"
cd "$openssl_source"
perl ./Configure "$openssl_target" no-shared no-module no-tests no-docs no-apps \
    "-isysroot" "$sdk" "-mmacosx-version-min=$deployment_target" --openssldir=/etc/ssl
log="$scratch/openssl-build.log"
printf 'Building static OpenSSL for %s …\n' "$arch"
if ! /usr/bin/make -j "$(sysctl -n hw.ncpu)" build_libs >"$log" 2>&1; then
    tail -80 "$log" >&2
    exit 1
fi

tar -xzf "$forti_archive" -C "$scratch"
cd "$scratch/openfortivpn-$forti_version"
patch -p1 -i "$script_dir/openfortivpn-macos-dns.patch"
"$CC" -arch "$arch" -isysroot "$sdk" "-mmacosx-version-min=$deployment_target" -O2 \
    -DHAVE_MACH_MACH_H=1 -DHAVE_STRUCT_TERMIOS=1 -DHAVE_UTIL_H=1 -DHAVE_VDPRINTF=1 \
    -DHAVE_USR_SBIN_PPPD=1 -DLEGACY_PPPD=1 -DUSE_RESOLVCONF=0 \
    '-DSYSCONFDIR="/etc"' '-DPPP_PATH="/usr/sbin/pppd"' '-DNETSTAT_PATH="/usr/sbin/netstat"' \
    '-DREVISION="unavailable"' "-DVERSION=\"$forti_version\"" \
    -I "$openssl_source/include" -I "$script_dir" src/*.c "$script_dir/macos-vpn-dns.c" \
    "$script_dir/ipv4-dns.c" \
    "$openssl_source/libssl.a" "$openssl_source/libcrypto.a" \
    -framework CoreFoundation -framework SystemConfiguration -lutil -lpthread -o "$scratch/openfortivpn"
otool -L "$scratch/openfortivpn" |
    awk '/^\t/ && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad = 1 } END { exit bad }'
lipo "$scratch/openfortivpn" -verify_arch "$arch"
install -m 755 "$scratch/openfortivpn" "$destination"
