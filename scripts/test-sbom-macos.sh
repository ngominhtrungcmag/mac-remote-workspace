#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT
"$root/scripts/sbom-macos.sh" "$out"
for name in FREERDP OPENSSL; do
  version="$(sed -n "s/^${name}_VERSION=\"\([^\"]*\)\"$/\1/p" "$root/scripts/build-freerdp-macos.sh")"
  [ -n "$version" ]
  case "$name" in FREERDP) label='FreeRDP (xcframework)' ;; OPENSSL) label='OpenSSL (static, built for FreeRDP)' ;; esac
  grep -F "| $label | $version |" "$out" >/dev/null
done
/usr/bin/python3 -I - "$root/Package.resolved" "$out" <<'PY'
import json, sys
with open(sys.argv[1]) as source, open(sys.argv[2]) as output:
    pins, sbom = json.load(source)["pins"], output.read()
for pin in pins:
    assert f'| {pin["identity"]} | {pin["location"]} |' in sbom
PY
echo 'SBOM version and package pin checks passed'
