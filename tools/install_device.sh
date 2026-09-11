#!/usr/bin/env bash
# Install and launch SafeShare on a connected HarmonyOS handset (no simulator).
set -euo pipefail
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
HAP="${1:-/Users/macalan/Documents/SafeShare/entry/build/default/outputs/default/entry-default-signed.hap}"
BUNDLE="${BUNDLE:-com.safesharep.app}"
ABILITY="${ABILITY:-EntryAbility}"

targets="$("$HDC" list targets | tr -d '\r')"
if [[ -z "${targets}" || "${targets}" == "[Empty]" ]]; then
  echo "NO_DEVICE: connect a HarmonyOS phone with USB debugging, then re-run." >&2
  exit 2
fi
echo "targets=${targets}"
"$HDC" -t "${targets%%$'\n'*}" install -r "$HAP"
"$HDC" -t "${targets%%$'\n'*}" shell aa start -a "$ABILITY" -b "$BUNDLE"
echo "INSTALLED_AND_LAUNCHED ${BUNDLE}/${ABILITY}"
