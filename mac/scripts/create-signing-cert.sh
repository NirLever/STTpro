#!/usr/bin/env bash
# One-time setup: creates a self-signed code-signing certificate named
# "STTpro Local Code Signing" in your login keychain. build-app.sh then signs
# with it automatically.
#
# Why: ad-hoc signed builds get a new identity on every rebuild, so macOS
# silently drops the Accessibility (and Keychain "Always Allow") grant even
# though the toggle in System Settings still looks on. A stable certificate
# keeps the same identity across rebuilds.
#
# macOS will ask for your login password to trust the certificate for code
# signing. Remove it later in Keychain Access (search "STTpro Local").
set -euo pipefail

NAME="STTpro Local Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Certificate \"$NAME\" already exists."
  security find-identity -p codesigning | grep "$NAME" || true
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "==> Generating certificate"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -passout "pass:$PASS" -name "$NAME" 2>/dev/null

echo "==> Importing into your login keychain"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -f pkcs12 -T /usr/bin/codesign

echo "==> Trusting it for code signing (macOS will ask for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" && echo "==> Done. Run scripts/build-app.sh --install"
