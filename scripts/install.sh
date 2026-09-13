#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="dist/FeatherInput.app"
[ -d "$app" ] || { echo 'Run scripts/build-app.sh first.' >&2; exit 1; }
destination="$HOME/Library/Input Methods/FeatherInput.app"
if [ -e "$destination" ]; then
  echo 'An installation already exists. Quit its process and move the old bundle aside before updating.' >&2
  exit 1
fi
mkdir -p "$HOME/Library/Input Methods"
cp -R "$app" "$destination"
"$destination/Contents/MacOS/register-input-source" "$destination"
echo "Installed and enabled. Choose Feather Input in the input source menu."
