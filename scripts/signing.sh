#!/usr/bin/env bash
# Code signing policy, sourced by build.sh, build_dmg.sh and release.sh. No Apple developer account.
#
# macOS remembers Screen Recording / Microphone grants (TCC) against the app's designated requirement.
#
# Preferred: a self-signed code-signing certificate (create it once with `make signing-setup`). The
# requirement then becomes
#     identifier "<BUNDLE_ID>" and certificate leaf = H"<certificate hash>"
# so grants survive rebuilds AND no other binary can claim them without your private key.
#
# The key lives in its own password-protected keychain (SIGNING_KEYCHAIN), not the login keychain.
# Anything that can use the key can sign a binary as KapKap and inherit its grants, and the login
# keychain is unlocked whenever you are logged in. The signing keychain is unlocked (asking for its
# password) only while a build signs, added to the search list only for that moment (codesign only
# finds identities in listed keychains), then locked again; it also locks itself after 5 minutes and
# on sleep.
#
# Fallback (no signing keychain): ad-hoc signature with the requirement pinned to the bundle ID only.
# Grants still survive rebuilds, but ANY binary ad-hoc signed with the same identifier inherits them,
# so build_dmg.sh / release.sh refuse to package such builds unless ALLOW_ADHOC_RELEASE=1.
#
# Gatekeeper treats both as an unidentified developer (first launch: right-click → Open).
#
# Both are signed with the hardened runtime (no Apple account needed). Without it, dyld honours
# DYLD_INSERT_LIBRARIES, so any local program could load its code into KapKap and use its Screen
# Recording / Microphone grants. The runtime requires the microphone entitlement in app.entitlements.

SIGNING_ENTITLEMENTS="${SIGNING_ENTITLEMENTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app.entitlements}"
SIGNING_CERT_NAME="${SIGNING_CERT_NAME:-${APP_NAME} Self-Signed Code Signing}"
SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-${HOME}/Library/Keychains/${APP_NAME}-signing.keychain-db}"
ALLOW_ADHOC_RELEASE="${ALLOW_ADHOC_RELEASE:-0}"

# Whether `make signing-setup` has created the signing keychain.
signing_keychain_exists() {
    [[ -f "$SIGNING_KEYCHAIN" ]]
}

# SHA-1 of the signing certificate in the signing keychain (unlock it first), or empty. The
# certificate is self-signed and therefore "not trusted", so it is looked up without -v.
signing_identity_hash() {
    signing_keychain_exists || return 0
    security find-identity -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null |
        awk -v name="\"${SIGNING_CERT_NAME}\"" 'index($0, name) { print $2; exit }'
}

# Fails unless the build may be distributed: a signing keychain exists (sign_app then refuses to fall
# back to ad-hoc), or an explicit override.
require_release_signing() {
    if signing_keychain_exists; then
        return 0
    fi
    if [[ "$ALLOW_ADHOC_RELEASE" == "1" ]]; then
        printf '%s\n' "WARNING: packaging an AD-HOC signed build (ALLOW_ADHOC_RELEASE=1)." >&2
        printf '%s\n' "         Any binary claiming ${BUNDLE_ID} can reuse its Screen Recording and Microphone grants." >&2
        return 0
    fi
    printf '%s\n' "Error: no signing keychain at ${SIGNING_KEYCHAIN}." >&2
    printf '%s\n' "       Run 'make signing-setup' once (no Apple account needed)," >&2
    printf '%s\n' "       or set ALLOW_ADHOC_RELEASE=1 to package an ad-hoc build anyway." >&2
    return 1
}

# The user keychain search list, one path per line, without the signing keychain.
_signing_saved_search_list() {
    security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//' |
        grep -v -x -F "$SIGNING_KEYCHAIN" || true
}

_SIGNING_SAVED_LIST=()

# Puts the search list back as it was and locks the signing keychain. Safe to call more than once.
_signing_restore() {
    if [[ ${#_SIGNING_SAVED_LIST[@]} -gt 0 ]]; then
        security list-keychains -d user -s "${_SIGNING_SAVED_LIST[@]}" || true
    fi
    security lock-keychain "$SIGNING_KEYCHAIN" 2>/dev/null || true
}

# Signs the app bundle according to the policy above and verifies the designated requirement and the
# hardening.
sign_app() {
    local app_dir="$1" bundle_id="$2"
    if signing_keychain_exists; then
        _sign_with_keychain "$app_dir" "$bundle_id"
        return
    fi

    local designated_requirement="designated => identifier \"${bundle_id}\""
    printf '%s\n' "Signing ${app_dir} (ad-hoc: ${designated_requirement}). Run 'make signing-setup' to lock permissions to your certificate."
    codesign --force --sign - --options runtime --entitlements "$SIGNING_ENTITLEMENTS" \
        --requirements "=${designated_requirement}" "$app_dir"
    local signed_requirement
    signed_requirement="$(codesign -d -r- "$app_dir" 2>&1 | grep '^designated => ' || true)"
    if [[ "$signed_requirement" != "$designated_requirement" ]]; then
        printf '%s\n' "Error: Unexpected designated requirement '${signed_requirement}'; permissions would not persist." >&2
        return 1
    fi
    verify_hardening "$app_dir"
}

# Unlocks the signing keychain, signs, and always restores the search list and locks it again (also
# on failure or Ctrl-C).
_sign_with_keychain() {
    local app_dir="$1" bundle_id="$2" status=0 line
    _SIGNING_SAVED_LIST=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && _SIGNING_SAVED_LIST+=("$line")
    done < <(_signing_saved_search_list)

    trap '_signing_restore; exit 130' INT TERM
    printf '%s\n' "Unlocking ${SIGNING_KEYCHAIN} to sign (the password you chose in 'make signing-setup')."
    if security unlock-keychain "$SIGNING_KEYCHAIN"; then
        security list-keychains -d user -s ${_SIGNING_SAVED_LIST[@]+"${_SIGNING_SAVED_LIST[@]}"} "$SIGNING_KEYCHAIN" &&
            _sign_with_certificate "$app_dir" "$bundle_id" || status=$?
        [[ $status -eq 0 ]] || status=1
    else
        printf '%s\n' "Error: could not unlock ${SIGNING_KEYCHAIN}." >&2
        status=1
    fi
    _signing_restore
    trap - INT TERM
    return "$status"
}

_sign_with_certificate() {
    local app_dir="$1" bundle_id="$2" identity
    identity="$(signing_identity_hash)"
    if [[ -z "$identity" ]]; then
        printf '%s\n' "Error: no '${SIGNING_CERT_NAME}' identity in ${SIGNING_KEYCHAIN}." >&2
        return 1
    fi
    printf '%s\n' "Signing ${app_dir} with '${SIGNING_CERT_NAME}' (${identity:0:8}…)..."
    codesign --force --sign "$identity" --keychain "$SIGNING_KEYCHAIN" --options runtime \
        --entitlements "$SIGNING_ENTITLEMENTS" "$app_dir" || return 1
    local requirement expected
    requirement="$(codesign -d -r- "$app_dir" 2>&1 | grep '^designated => ' || true)"
    expected="designated => identifier \"${bundle_id}\" and certificate leaf = H\"$(printf '%s' "$identity" | tr 'A-F' 'a-f')\""
    if [[ "$requirement" != "$expected" ]]; then
        printf '%s\n' "Error: unexpected designated requirement '${requirement}' (expected '${expected}')." >&2
        return 1
    fi
    verify_hardening "$app_dir"
}

# Fails unless the signature has the hardened runtime and the microphone entitlement (without which
# microphone capture fails under the runtime).
verify_hardening() {
    local app_dir="$1" details entitlements
    # Captured first: piping into `grep -q` under pipefail can fail when grep exits early (SIGPIPE).
    details="$(codesign -dv "$app_dir" 2>&1 || true)"
    entitlements="$(codesign -d --entitlements - --xml "$app_dir" 2>/dev/null | tr -d '\000' || true)"
    if ! grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime' <<<"$details"; then
        printf '%s\n' "Error: ${app_dir} is not signed with the hardened runtime." >&2
        return 1
    fi
    if ! grep -q 'com.apple.security.device.audio-input' <<<"$entitlements"; then
        printf '%s\n' "Error: ${app_dir} lacks the microphone entitlement; microphone capture would fail." >&2
        return 1
    fi
}
