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
    printf '%s\n' "Error: Failed to obtain SDK path from xcrun" >&2
    exit 1
fi
IFS= read -r sdk_path <"$sdk_file"
rm -f "$sdk_file"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "Error: VERSION file must contain a version like 1.2.3 (found '${VERSION}')" >&2
    exit 1
fi

# Every build increments BUILD_NUMBER; the file is the single source of truth.
if [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    build_number=$((10#$BUILD_NUMBER + 1))
else
    build_number=1
fi
printf '%s\n' "$build_number" >"$build_num_file"
export BUILD_NUMBER="$build_number"

build_dir="build"
app_name="${APP_NAME}"
bundle_id="${BUNDLE_ID}"
app_dir="${build_dir}/${app_name}.app"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"

mkdir -p "$macos_dir" "$resources_dir"

if [[ -d "Resources" ]]; then
    cp -R Resources/. "${resources_dir}/"
fi

if [[ -f "VERSION" ]]; then
    cp "VERSION" "${resources_dir}/VERSION"
fi
printf '%s\n' "$build_number" >"${resources_dir}/BUILD_NUMBER"

sources=()
while IFS= read -r file; do
    sources+=("$file")
done < <(find Sources/App -type f -name "*.swift" | sort)

# Universal binary: one slice per architecture (Intel and Apple silicon), merged with lipo.
# swiftc defaults to the host minimum (12.0); ScreenCaptureKit needs an explicit 12.3 target.
architectures=(x86_64 arm64)
slices_dir="${build_dir}/obj/slices"
mkdir -p "$slices_dir"

printf '%s\n' "Compiling ${app_name} v${VERSION} (Build ${BUILD_NUMBER}) (${#sources[@]} source files) for ${architectures[*]}..."
slices=()
for arch in "${architectures[@]}"; do
    slice="${slices_dir}/${app_name}-${arch}"
    swiftc -sdk "$sdk_path" \
        -target "${arch}-apple-macos${MIN_MACOS_VERSION}" \
        -O \
        -whole-module-optimization \
        -Xlinker -dead_strip \
        "${sources[@]}" \
        -o "$slice"
    slices+=("$slice")
done
lipo -create "${slices[@]}" -output "${macos_dir}/${app_name}"

built_archs="$(lipo -archs "${macos_dir}/${app_name}")"
for arch in "${architectures[@]}"; do
    if [[ " ${built_archs} " != *" ${arch} "* ]]; then
        printf '%s\n' "Error: ${arch} slice missing from the binary (has: ${built_archs})" >&2
        exit 1
    fi
done
printf '%s\n' "Universal binary: ${built_archs}"

printf '%s\n' "Generating ${app_name} Info.plist..."
cat <<EOF >"${contents_dir}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${app_name}</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleName</key>
    <string>${app_name}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS_VERSION}</string>
    <key>LSUIElement</key>
    <${LS_UI_ELEMENT}/>
    <key>NSMicrophoneUsageDescription</key>
    <string>${MIC_USAGE_DESCRIPTION}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>${COPYRIGHT}</string>
</dict>
</plist>
EOF

# Self-signed certificate when present (grants locked to your key), else ad-hoc pinned to the
# bundle ID. See scripts/signing.sh.
source "${script_dir}/signing.sh"
sign_app "$app_dir" "$bundle_id"

printf '%s\n' "Refreshing macOS LaunchServices cache..."
touch "$app_dir"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$app_dir" >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true

printf '%s\n' "✅ Build complete:"
printf '%s\n' "   - ${app_dir}"
