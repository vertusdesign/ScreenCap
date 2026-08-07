#!/bin/bash
# Creates a local self-signed code-signing certificate in the login keychain.
#
# Why this exists: an ad-hoc signature (`codesign --sign -`) carries no identity, so the
# only thing macOS can pin the Screen Recording grant to is the hash of the binary —
# `designated => cdhash H"…"`. Every rebuild changes that hash, the grant stops matching,
# and the stale row has to be removed from Privacy settings by hand.
#
# With a certificate the requirement becomes
# `identifier "com.vertusdesign.ScreenCap" and certificate leaf = H"…"`, which survives
# rebuilds, so the permission is granted once and stays granted.
#
# The certificate is only ever used locally. It is not trusted by the system and does not
# need to be — codesign accepts it as-is, and Gatekeeper is not involved for an app you
# built yourself. Released disk images are signed ad-hoc instead, because a certificate
# only this machine has is worth nothing to anyone downloading the app.
#
# To remove it: Keychain Access → login → find "ScreenCap Local Signing".
set -euo pipefail

NAME="ScreenCap Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    SHA="$(security find-certificate -c "$NAME" -Z 2>/dev/null | awk '/SHA-1 hash/{print $3}')"
    echo "Certificate already present: $NAME ($SHA)"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 7300 -config "$WORK/cert.cnf" 2>/dev/null

# macOS rejects PKCS12 files written with modern ciphers, so ask for the legacy ones.
openssl pkcs12 -export -out "$WORK/cert.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:screencap -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# -A / -T authorise codesign up front, so signing never raises a keychain prompt.
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P screencap -T /usr/bin/codesign -A

SHA="$(security find-certificate -c "$NAME" -Z 2>/dev/null | awk '/SHA-1 hash/{print $3}')"
echo "Created certificate: $NAME ($SHA)"
