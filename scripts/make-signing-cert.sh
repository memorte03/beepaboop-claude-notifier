#!/usr/bin/env bash
# Creates a stable self-signed code-signing certificate in your login keychain,
# so macOS TCC (Accessibility, Automation) grants for Boopr persist
# across rebuilds and relaunches.
#
# WHY: ad-hoc-signed apps have no stable code identity. macOS ties a TCC grant
# to the app's code requirement; for ad-hoc apps that can't be matched reliably,
# so the app keeps re-prompting for Accessibility even though Settings shows it
# granted. Signing with a real (even self-signed) certificate gives a stable
# identity the grant sticks to.
#
# Run this ONCE:  scripts/make-signing-cert.sh
# Then reinstall: scripts/install.sh   (it auto-detects and uses the cert)
#
# macOS may ask for your login password (to import the key and trust the cert);
# that's expected. Run from a real terminal so the prompts can appear.
set -euo pipefail

CERT_NAME="Boopr Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "✓ signing identity '$CERT_NAME' already exists — nothing to do."
    echo "  reinstall with scripts/install.sh to sign with it."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Self-signed cert with the Code Signing extended key usage.
cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
EOF

echo "→ generating key pair + self-signed certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

# Import the key and cert as separate PEMs, NOT a PKCS12 — OpenSSL 3 writes p12
# files whose MAC macOS's `security import` rejects ("MAC verification failed /
# wrong password"). macOS links the key and cert by their shared public key.
echo "→ importing key + certificate into the login keychain (authorizing codesign)"
security import "$TMP/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
security import "$TMP/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null

echo "→ trusting it for code signing (you may be asked for your login password)"
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null; then
    cat <<EOF
   couldn't set trust automatically. Finish it by hand:
     1. open Keychain Access → login → '$CERT_NAME'
     2. expand Trust → Code Signing → Always Trust
EOF
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$CERT_NAME"; then
    echo "✓ created code-signing identity '$CERT_NAME'"
    echo
    echo "next: scripts/install.sh   (signs the app with this identity)"
    echo "the first sign may prompt 'codesign wants to use a key' — click Always Allow."
else
    echo "⚠ identity not visible yet — if you set trust by hand, re-run this to verify." >&2
    exit 1
fi
