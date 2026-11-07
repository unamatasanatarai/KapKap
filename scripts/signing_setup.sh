#!/usr/bin/env bash
# Creates the self-signed code-signing certificate used by scripts/signing.sh (no Apple account).
#
# The certificate and its private key go into a dedicated, password-protected keychain
# (SIGNING_KEYCHAIN), never the login keychain: whatever can use the key can sign a binary as KapKap
# and inherit its Screen Recording / Microphone grants, and the login keychain is unlocked whenever
# you are logged in. The signing keychain stays locked except while a build signs, locks itself after
# 5 minutes and on sleep, and is not left in the keychain search list. The temporary key files are
# deleted; the key never stays on disk outside the keychain.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/config.sh"
source "${script_dir}/signing.sh"

if signing_keychain_exists; then
    printf '%s\n' "${SIGNING_KEYCHAIN} already exists. Nothing to do."
    printf '%s\n' "(To start over: security delete-keychain \"${SIGNING_KEYCHAIN}\", then run this again.)"
    exit 0
fi

# A certificate from the previous setup, which used the login keychain.
login_keychain="${HOME}/Library/Keychains/login.keychain-db"
if security find-certificate -c "$SIGNING_CERT_NAME" "$login_keychain" >/dev/null 2>&1; then
    printf '%s\n' "Note: an older '${SIGNING_CERT_NAME}' is in your login keychain, where any program can use it."
    printf '%s\n' "      Delete it in Keychain Access (My Certificates) once this setup has finished."
fi

work_dir="$(mktemp -d)"
saved_list=()
while IFS= read -r line; do
    [[ -n "$line" ]] && saved_list+=("$line")
done < <(_signing_saved_search_list)

cleanup() {
    rm -rf "$work_dir"
    # create-keychain adds the new keychain to the search list; keep the list as it was.
    if [[ ${#saved_list[@]} -gt 0 ]]; then
        security list-keychains -d user -s "${saved_list[@]}" || true
    fi
    if signing_keychain_exists; then
        security lock-keychain "$SIGNING_KEYCHAIN" 2>/dev/null || true
    fi
}
trap cleanup EXIT
chmod 700 "$work_dir"

cat >"${work_dir}/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = ${SIGNING_CERT_NAME}
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

# /usr/bin/openssl (LibreSSL) writes a PKCS#12 that `security import` accepts; a Homebrew OpenSSL 3
# would need -legacy.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "${work_dir}/key.pem" -out "${work_dir}/cert.pem" -config "${work_dir}/cert.cnf"
p12_password="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "${work_dir}/key.pem" -in "${work_dir}/cert.pem" \
    -out "${work_dir}/identity.p12" -passout "pass:${p12_password}" -name "${SIGNING_CERT_NAME}"

cat <<EOF

Choose a password for the KapKap signing keychain. Builds ask for it each time they sign.
Use a different password from your login password.
EOF
security create-keychain "$SIGNING_KEYCHAIN"
# Lock after 5 minutes of inactivity and on sleep.
security set-keychain-settings -l -u -t 300 "$SIGNING_KEYCHAIN"
# Only codesign may use the key, and only while the keychain is unlocked (during a build).
security import "${work_dir}/identity.p12" -k "$SIGNING_KEYCHAIN" -P "$p12_password" -T /usr/bin/codesign >/dev/null
# No `security set-key-partition-list`: it takes the keychain password on the command line (visible
# to other processes). macOS asks once in a dialog instead, on the first signing.

created="$(signing_identity_hash)"
if [[ -z "$created" ]]; then
    printf '%s\n' "Error: the certificate was imported but is not visible as a code-signing identity." >&2
    exit 1
fi

cat <<EOF

✅ Created '${SIGNING_CERT_NAME}' (${created}) in ${SIGNING_KEYCHAIN} (now locked).

Next:
  1. make run          Asks for the signing keychain password, signs, and locks it again.
                       The first time, macOS also shows a dialog asking that password for codesign:
                       enter it and choose "Always Allow" (the keychain is locked outside builds).
  2. make revoke       Your existing grants were recorded under the old, bundle-ID-only requirement
                       and would still accept impostors. Reset them once...
  3. Grant Screen Recording and Microphone again when KapKap asks.

Back up ${SIGNING_KEYCHAIN} and its password somewhere safe: without them, a new certificate
means every user grants permissions again.
EOF
