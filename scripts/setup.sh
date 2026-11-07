#!/usr/bin/env bash

# Interactive project setup: asks for the app ID (bundle identifier) and app name,
# and writes them to scripts/config.sh.
#
# Usage:
#   ./scripts/setup.sh [bundle-id] [app-name]

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
cd "$project_dir"

config_file="${script_dir}/config.sh"

# Read the configured values, not environment overrides.
unset APP_NAME BUNDLE_ID
source "$config_file"
current_app_name="$APP_NAME"
current_bundle_id="$BUNDLE_ID"

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

ask() {
    local prompt="$1" default="$2" answer
    if [[ ! -t 0 ]]; then
        printf '%s\n' "$default"
        return
    fi
    IFS= read -r -p "${prompt} [${default}]: " answer || answer=""
    printf '%s\n' "${answer:-$default}"
}

bundle_id="${1:-}"
while [[ -z "$bundle_id" ]]; do
    bundle_id="$(ask "App ID (bundle identifier, e.g. com.example.MyApp)" "$current_bundle_id")"
done
[[ "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] ||
    die "Invalid app ID '${bundle_id}'. Use reverse-DNS form, e.g. com.example.MyApp"

if [[ "$bundle_id" == "$current_bundle_id" ]]; then
    default_app_name="$current_app_name"
else
    default_app_name="${bundle_id##*.}"
fi
app_name="${2:-$(ask "App name" "$default_app_name")}"
[[ "$app_name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] ||
    die "Invalid app name '${app_name}'. Use letters, digits, '-' or '_', starting with a letter."

# Rewrite the defaults in config.sh, keeping everything else untouched.
tmp_config="$(mktemp "${TMPDIR:-/tmp}/config.XXXXXX")"
trap 'rm -f "$tmp_config"' EXIT
while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
    'export APP_NAME='*) line="export APP_NAME=\"\${APP_NAME:-${app_name}}\"" ;;
    'export BUNDLE_ID='*) line="export BUNDLE_ID=\"\${BUNDLE_ID:-${bundle_id}}\"" ;;
    esac
    printf '%s\n' "$line"
done <"$config_file" >"$tmp_config"
cat "$tmp_config" >"$config_file"

# Keep the Swift package name in sync for IDEs and `swift build`.
if [[ "$app_name" != "$current_app_name" && -f "Package.swift" ]]; then
    package="$(<Package.swift)"
    printf '%s\n' "${package//\"${current_app_name}\"/\"${app_name}\"}" >Package.swift
fi

printf '%s\n' "Configured ${app_name} (${bundle_id}) in scripts/config.sh."

if [[ "$bundle_id" != "$current_bundle_id" ]]; then
    printf '%s\n' "Note: Permissions granted to ${current_bundle_id} do not carry over to the new app ID."
fi

printf '\n%s\n' "✅ Setup complete. Next: make run"
