#!/usr/bin/env bash

# Application Configuration
# These variables configure your application name, bundle ID, and build options.
# Run `make setup` to set the app name and bundle ID, or modify this file directly.

export APP_NAME="${APP_NAME:-KapKap}"
export BUNDLE_ID="${BUNDLE_ID:-com.kapkap.app}"
export MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-12.3}"
export MIC_USAGE_DESCRIPTION="${MIC_USAGE_DESCRIPTION:-Records your microphone into screen recordings.}"
export COPYRIGHT="${COPYRIGHT:-Copyright © $(date +%Y). All rights reserved.}"
export LS_UI_ELEMENT="${LS_UI_ELEMENT:-true}" # Set to "true" for menu-bar-only / agent apps

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The VERSION file is the single source of truth for the app version.
# Environment overrides are intentionally ignored.
version_file="${project_root}/VERSION"
VERSION=""
if [[ -f "$version_file" ]]; then
	VERSION="$(<"$version_file")"
	VERSION="${VERSION//[[:space:]]/}"
fi
export VERSION="${VERSION:-0.0.0}"

# The BUILD_NUMBER file is the single source of truth for the build number.
build_num_file="${project_root}/BUILD_NUMBER"
BUILD_NUMBER=""
if [[ -f "$build_num_file" ]]; then
	BUILD_NUMBER="$(<"$build_num_file")"
	BUILD_NUMBER="${BUILD_NUMBER//[[:space:]]/}"
fi
export BUILD_NUMBER="${BUILD_NUMBER:-0}"
