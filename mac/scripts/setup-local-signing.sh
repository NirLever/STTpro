#!/usr/bin/env bash
# Creates a private signing identity in a keychain file inside this project
# (mac/.signing/, git-ignored). No password prompt, no change to the login
# keychain or to any trust settings.
#
# Why: an ad-hoc signature changes on every build, so macOS forgets the
# Accessibility permission. A certificate-based signature gives a stable
# identity ("identifier com.sttpro.mac and certificate leaf = H…"), so the
# permission survives rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="$(pwd)/.signing"
KC="$DIR/sttpro-signing.keychain-db"
PW="sttpro-local-signing"   # protects only this throwaway keychain file
NAME="STTpro Local Code Signing"

mkdir -p "$DIR"
if [[ ! -f "$KC" ]]; then
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:x 2>/dev/null \
  || /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:x
  security create-keychain -p "$PW" "$KC"
  security set-keychain-settings "$KC"            # no auto-lock
  security unlock-keychain -p "$PW" "$KC"
  security import "$WORK/id.p12" -k "$KC" -P x -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$PW" "$KC" >/dev/null
  echo "==> Created $KC"
fi
security unlock-keychain -p "$PW" "$KC"
echo "$KC"
