#!/bin/zsh
# Creates a stable local signing identity so macOS keeps each tool's permissions across rebuilds.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/cunhatools-signing.keychain-db"
PASSWORD="cunhatools-local"
IDENTITY="Cunha Tools Local Signing"

if [[ ! -f "$KEYCHAIN" ]]; then
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD" -name "$IDENTITY"
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
  security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
fi

if ! security list-keychains -d user | grep -q "cunhatools-signing"; then
  security list-keychains -d user -s ${(f)"$(security list-keychains -d user | tr -d ' "')"} "$KEYCHAIN"
fi

security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
echo "$KEYCHAIN"
