#!/bin/sh
# Moves the Tin pin (TIN_VERSION) to another release, only when everything builds and passes with it. Nothing else
# ever changes the pin.
#   scripts/tin-update.sh            the latest release
#   scripts/tin-update.sh 0.4.262    a chosen one
# With Docker available it runs the end-to-end check too (tests/local.sh); set TINBOX_SKIP_E2E=1 to skip it.
set -eu
cd "$(dirname "$0")/.."
old=$(tr -d ' \r\n' < TIN_VERSION)
new=${1:-}
if [ -z "$new" ]; then
  url=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/yasserreslan/tin/releases/latest)
  new=${url##*/}
fi
new=${new#v}
if [ "$new" = "$old" ]; then
  echo "tin-update: already on Tin $old"
  exit 0
fi
echo "tin-update: trying Tin $new (the pin is $old)"
printf '%s\n' "$new" > TIN_VERSION
ok=1
scripts/test.sh || ok=0
if [ $ok -eq 1 ] && [ "${TINBOX_SKIP_E2E:-}" != "1" ] && command -v docker >/dev/null 2>&1; then
  tests/local.sh || ok=0
fi
if [ $ok -eq 0 ]; then
  printf '%s\n' "$old" > TIN_VERSION
  echo "tin-update: Tin $new fails the checks above, so the pin stays at $old"
  exit 1
fi
echo "tin-update: Tin $new passes. What changed: https://github.com/yasserreslan/tin/releases"
echo "Commit the bump on its own:"
echo "  git commit -am 'Tin $old -> $new'"
