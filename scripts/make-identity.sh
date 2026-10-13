#!/bin/bash
# Creates a self-signed code-signing identity "Focus Local Signing" in the
# login keychain. Idempotent: does nothing if the identity already exists.
# A stable identity keeps TCC grants (camera, automation) across rebuilds.
set -eu

NAME="Focus Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "identity \"$NAME\" already present"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=$(openssl rand -hex 16)

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$NAME" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "keyUsage=digitalSignature" \
    -addext "basicConstraints=CA:FALSE" 2>/dev/null

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" \
    -T /usr/bin/codesign -T /usr/bin/security

# Let codesign use the key without a per-use prompt. Only works when the
# login keychain has an empty password; otherwise it is skipped quietly.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "created identity \"$NAME\""
else
    echo "warning: identity \"$NAME\" not listed after import" >&2
    exit 1
fi
