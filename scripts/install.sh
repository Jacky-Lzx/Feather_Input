#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="dist/FeatherInput.app"
[ -d "$app" ] || { echo 'Run scripts/build-app.sh first.' >&2; exit 1; }
input_methods_dir="$HOME/Library/Input Methods"
destination="$input_methods_dir/FeatherInput.app"
mkdir -p "$input_methods_dir"

# Stage the new bundle on the destination filesystem, then swap it into place.
# If registration fails, restore the previous installation automatically.
install_dir=$(mktemp -d "$input_methods_dir/.FeatherInput.install.XXXXXX")
staged="$install_dir/FeatherInput.app"
previous="$install_dir/Previous.app"
restore_previous=false
cleanup() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && [ "$restore_previous" = true ]; then
    rm -rf "$destination"
    mv "$previous" "$destination"
    echo 'Installation failed; restored the previous FeatherInput.app.' >&2
  fi
  rm -rf "$install_dir"
  exit "$status"
}
trap cleanup EXIT

ditto "$app" "$staged"
if [ -e "$destination" ]; then
  mv "$destination" "$previous"
  restore_previous=true
fi
mv "$staged" "$destination"
"$destination/Contents/MacOS/register-input-source" "$destination"
# IMK may keep the server alive even after another input source is selected.
# Terminate it only after the new bundle is in place so any automatic restart
# loads the new executable and metadata.
pkill -x FeatherInput >/dev/null 2>&1 || true
restore_previous=false
echo "Installed and enabled without removing the input source. Choose Feather Input in the input source menu."
