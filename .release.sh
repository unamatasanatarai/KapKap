# ggrel release configuration (sourced by ggrel from the repository root).
#
#   gemini-release-notes 1.0.1 | ggrel 1.0.1
#   ggrel 1.0.1 -f notes.md --dry-run
#
# ggrel order: TEST_CMD -> write + commit VERSION -> BUILD_CMD -> tag -> push -> gh release.
# ggrel replaces $version with the target version, so keep these strings single-quoted.

APP_NAME='KapKap'

# Fails before VERSION is touched if release signing is not set up (make signing-setup) or tests fail.
TEST_CMD='source scripts/config.sh && source scripts/signing.sh && require_release_signing && make test'

# Build the DMG, keep a stable-named copy for the README download link,
# and commit the BUILD_NUMBER bump so the tag includes the shipped build number.
BUILD_CMD='make dmg && cp -f build/KapKap-$version.dmg build/KapKap.dmg && git commit --quiet -m "chore(release): build number for v$version" -- BUILD_NUMBER'

RELEASE_ASSETS=(
    'build/KapKap-$version.dmg'
    'build/KapKap.dmg'
)
