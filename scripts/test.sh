#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
cd "$project_dir"

source "${script_dir}/config.sh"

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/${APP_NAME,,}"
mkdir -p "$cache_dir"

sdk_file="${cache_dir}/sdk_path.tmp"
xcrun --show-sdk-path >"$sdk_file" 2>/dev/null
if [[ ! -s "$sdk_file" ]]; then
    rm -f "$sdk_file"
    printf '%s\n' "Error: Failed to locate macOS SDK via xcrun" >&2
    exit 1
fi
IFS= read -r sdk_path <"$sdk_file"
rm -f "$sdk_file"

test_dir="${XDG_RUNTIME_DIR:-/tmp}"
test_bin="${test_dir}/RunSwiftTests_${RANDOM}"
trap 'rm -f "$test_bin"' EXIT INT TERM

# Collect app sources excluding entry points with @main (e.g. Main.swift)
sources=()
while IFS= read -r file; do
    if ! grep -q "@main" "$file" 2>/dev/null; then
        sources+=("$file")
    fi
done < <(find Sources/App -type f -name "*.swift" | sort)

# Collect test sources
tests=(
    "Tests/AppTests/AppTests.swift"
    "Tests/AppTests/AudioMixerTests.swift"
    "Tests/AppTests/RecordingTests.swift"
    "Tests/AppTests/ScreenGeometryTests.swift"
    "Tests/AppTests/TestMain.swift"
)

if [[ ${#tests[@]} -eq 0 ]]; then
    printf '%s\n' "Error: No test files found under Tests" >&2
    exit 1
fi

# Match the app's deployment target so ScreenCaptureKit types compile unannotated.
target_triple="$(uname -m)-apple-macos${MIN_MACOS_VERSION}"

printf '%s\n' "Compiling unit test suite..."
swiftc -sdk "$sdk_path" \
    -target "$target_triple" \
    "${sources[@]}" \
    "${tests[@]}" \
    -o "$test_bin"

test_status=0
"$test_bin" || test_status=$?
rm -f "$test_bin"

if [[ "$test_status" -ne 0 ]]; then
    printf '%s\n' "Error: Swift unit tests failed with status ${test_status}" >&2
    exit "$test_status"
fi
