#!/bin/bash
# One-time setup for a developer who builds Composer Bubbles on their own Mac.
set -euo pipefail
umask 077
signer="Composer Bubbles Local Signing"
store="$HOME/Library/Application Support/Composer Bubbles/Signing"
public_cert="$store/local-signer.der"
keychain="$(/usr/bin/security default-keychain -d user | /usr/bin/sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
[[ -f "$keychain" ]] || { echo "Open and unlock your default user keychain, then try again." >&2; exit 1; }

mkdir -p "$store"
exec 9>>"$store/setup.lock"
if ! /usr/bin/lockf -st 0 9; then
  echo "Another signing setup is in progress." >&2
  exit 1
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/composer-bubbles-signing.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT

if [[ ! -f "$public_cert" ]]; then
  if /usr/bin/security find-certificate -c "$signer" "$keychain" >/dev/null 2>&1; then
    echo "A certificate with that name already exists. Select its identity explicitly with COMPOSER_BUBBLES_SIGN_IDENTITY, or inspect it in Keychain Access." >&2
    exit 1
  fi
  cat > "$scratch/cert.cnf" <<'CERT'
[req]
prompt = no
distinguished_name = subject
x509_extensions = local_signing
[subject]
CN = Composer Bubbles Local Signing
[local_signing]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CERT
  /usr/bin/openssl rand -hex 32 > "$scratch/wrap-pass"
  /usr/bin/openssl req -new -x509 -newkey rsa:3072 -sha256 -days 3650 \
    -config "$scratch/cert.cnf" \
    -passout "file:$scratch/wrap-pass" -keyout "$scratch/key.pem" -out "$scratch/certificate.pem"
  /usr/bin/openssl x509 -in "$scratch/certificate.pem" -outform DER -out "$scratch/certificate.der"
  # Keychain requires a nonempty PKCS#12 password. Send the one-time password
  # on stdin so it stays out of the process list and shell history.
  /usr/bin/openssl rand -hex 32 > "$scratch/import-pass"
  /usr/bin/openssl pkcs12 -export -name "$signer" -inkey "$scratch/key.pem" \
    -in "$scratch/certificate.pem" -passin "file:$scratch/wrap-pass" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -passout "file:$scratch/import-pass" -out "$scratch/import.p12"
  (
    cd "$scratch"
    IFS= read -r transport_pass < import-pass
    # security import targets the default user keychain when -k is omitted.
    printf 'import import.p12 -f pkcs12 -P %s -x -T /usr/bin/codesign\n' "$transport_pass" | /usr/bin/security -i
  )
  rm -f "$scratch/import.p12" "$scratch/key.pem" "$scratch/wrap-pass" "$scratch/import-pass"
  install -m 600 "$scratch/certificate.der" "$public_cert"
fi

fingerprint="$(/usr/bin/shasum -a 1 "$public_cert" | /usr/bin/awk '{print toupper($1)}')"
# On a retry, only trust the saved, single-purpose leaf for this app's local builds.
if ! /usr/bin/openssl x509 -inform der -in "$public_cert" -noout -subject -issuer -text -nameopt RFC2253 |
  /usr/bin/awk -v name="CN=$signer" '
    $0 == "subject= " name { subject=1 }
    $0 == "issuer= " name { issuer=1 }
    /X509v3 Basic Constraints: critical/ { getline; basic=($0 ~ /^[[:space:]]*CA:FALSE$/) }
    /X509v3 Key Usage: critical/ { getline; signing=($0 ~ /^[[:space:]]*Digital Signature$/) }
    /X509v3 Extended Key Usage: critical/ { getline; purpose=($0 ~ /^[[:space:]]*Code Signing$/) }
    END { exit !(subject && issuer && basic && signing && purpose) }'; then
  echo "The saved public certificate does not match the local Composer Bubbles signing profile." >&2
  exit 1
fi
has_identity() {
  /usr/bin/security find-identity "$@" -p codesigning "$keychain" |
    /usr/bin/awk -v fingerprint="$fingerprint" '$2 == fingerprint { found=1 } END { exit !found }'
}
if ! has_identity -v; then
  if ! has_identity; then
    echo "The saved certificate has no matching key in your default user keychain. Restore that identity before building." >&2
    exit 1
  fi
  # Scope trust to code signing in this user's account. macOS handles consent.
  /usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$public_cert"
  has_identity -v || { echo "macOS has not enabled this signing identity yet." >&2; exit 1; }
fi
echo "Composer Bubbles local signing is ready."
