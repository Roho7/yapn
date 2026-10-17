#!/bin/sh
# Creates a self-signed code-signing identity that scripts/bundle.sh signs Dictation.app with.
# macOS ties Microphone and Accessibility grants to the app's designated requirement. With ad-hoc
# signing that requirement is the cdhash, which changes on every build and silently drops the grants.
# Signed with this identity it is `identifier "dev.roho.dictation" and certificate leaf = H"..."`,
# which stays the same across rebuilds.
#
# The identity lives in its own keychain, unlocked by a random password kept next to it, so neither
# signing nor this script needs your login password or a dialog. Nothing is added to your login
# keychain, your keychain search list, or your trust settings. The tradeoff: any process running as
# you can read that password and sign code as Dictation, inheriting its Microphone and Accessibility
# grants. Run `scripts/make-signing-identity.sh --remove` to delete it.
set -eu

NAME="Dictation Local Signing"
KEYCHAIN="${DICTATION_KEYCHAIN:-$HOME/Library/Keychains/dictation-signing.keychain-db}"
PASSWORD_FILE="${DICTATION_KEYCHAIN_PASSWORD_FILE:-$HOME/Library/Application Support/Dictation/signing-keychain-password}"
OPENSSL=/usr/bin/openssl

if [ "${1:-}" = "--remove" ]; then
  [ -f "$KEYCHAIN" ] && security delete-keychain "$KEYCHAIN"
  rm -f "$PASSWORD_FILE"
  echo "removed $KEYCHAIN"
  exit 0
fi

if [ -f "$KEYCHAIN" ]; then
  echo "identity keychain already exists: $KEYCHAIN"
  security find-identity -p codesigning "$KEYCHAIN"
  exit 0
fi

umask 077
mkdir -p "$(dirname "$PASSWORD_FILE")"
WORK=$(mktemp -d)
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
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
P12_PASSWORD=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$P12_PASSWORD"

"$OPENSSL" rand -hex 24 > "$PASSWORD_FILE"
KEYCHAIN_PASSWORD=$(cat "$PASSWORD_FILE")
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a keychain access dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

security find-identity -p codesigning "$KEYCHAIN"
echo "created $KEYCHAIN"
echo "CSSMERR_TP_NOT_TRUSTED above is expected: codesign signs with an untrusted identity."
echo "Next: scripts/bundle.sh, then grant Microphone and Accessibility to build/Dictation.app once."
