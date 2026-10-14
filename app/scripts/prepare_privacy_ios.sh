#!/usr/bin/env bash
# Prepare only the generated files the existing Xcode graph requires for the
# standalone privacy target. The copied plist is the repository's local
# placeholder; lib/privacy_main.dart never initializes Firebase.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "${script_dir}/.." && pwd)"
placeholder="${app_dir}/setup/prebuilt/GoogleService-Info-Local.plist"

test -f "${placeholder}"
install -d "${app_dir}/ios/Config/Dev" "${app_dir}/ios/Config/Prod" "${app_dir}/ios/Runner"
install -m 0644 "${placeholder}" "${app_dir}/ios/Config/Dev/GoogleService-Info.plist"
install -m 0644 "${placeholder}" "${app_dir}/ios/Config/Prod/GoogleService-Info.plist"
install -m 0644 "${placeholder}" "${app_dir}/ios/Runner/GoogleService-Info.plist"

cd "${app_dir}"
flutter pub get

echo 'Privacy iOS prerequisites are ready.'
