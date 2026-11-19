#!/bin/sh
set -eu

destination=${1:?Specify an output executable path}
case "$destination" in
    /*) ;;
    *) destination="$(pwd)/$destination" ;;
esac

for tool in autoconf automake pkg-config brew; do
    command -v "$tool" >/dev/null || { printf 'Missing %s\n' "$tool" >&2; exit 1; }
done

openssl_prefix=$(brew --prefix openssl@3)
test -f "$openssl_prefix/lib/libssl.a"
test -f "$openssl_prefix/lib/libcrypto.a"
scratch=$(mktemp -d)
trap 'rm -r "$scratch"' EXIT
archive="$scratch/openfortivpn.tar.gz"
curl --fail --location --silent --show-error \
    https://codeload.github.com/adrienverge/openfortivpn/tar.gz/refs/tags/v1.24.1 -o "$archive"
printf '%s  %s\n' c40d33acd97b89c2e943bfd839c19b69e5a7a5997052e2fc9a595602745c0465 "$archive" | shasum -a 256 -c
tar -xzf "$archive" -C "$scratch"
cd "$scratch/openfortivpn-1.24.1"
./autogen.sh
OPENSSL_CFLAGS="-I$openssl_prefix/include" OPENSSL_LIBS="$openssl_prefix/lib/libssl.a $openssl_prefix/lib/libcrypto.a" \
    ./configure --enable-legacy-pppd --with-pppd=/usr/sbin/pppd --with-resolvconf=DISABLED --with-systemdsystemunitdir=no
make openfortivpn
otool -L ./openfortivpn | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad = 1 } END { exit bad }'
install -m 755 ./openfortivpn "$destination"
