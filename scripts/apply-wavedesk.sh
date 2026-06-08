#!/usr/bin/env bash
#
# apply-wavedesk.sh
#
# Re-apply all WaveDesk fork changes onto a fresh RustDesk upstream checkout.
# Run from the repository root. Idempotent-ish: if the patch is already applied
# it will report a clean tree and exit 0.
#
# When upstream changes and conflicts occur, resolve them, then regenerate the
# patch:
#   git diff --binary <upstream-base>..HEAD > patches/wavedesk.patch
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PATCH="patches/wavedesk.patch"

if [ ! -f "$PATCH" ]; then
  echo "error: $PATCH not found" >&2
  exit 1
fi

echo "==> Checking patch applicability ($PATCH)"
if git apply --check "$PATCH" 2>/dev/null; then
  echo "==> Applying WaveDesk patch"
  git apply --binary "$PATCH"
  echo "    Done. Review with: git status"
elif git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "==> Patch already applied (reverse-check passed). Nothing to do."
else
  echo "==> Clean apply failed — falling back to 3-way merge." >&2
  echo "    Resolve any conflicts, then regenerate patches/wavedesk.patch." >&2
  git apply --binary --3way "$PATCH"
fi

echo ""
echo "WaveDesk changes applied. Next:"
echo "  - build:  VCPKG_ROOT=~/vcpkg cargo build --locked --features hwcodec,flutter --release"
echo "  - flutter:( cd flutter && flutter build macos --release )   # -> WaveDesk.app"
echo "  - sign:   see WAVEDESK.md"
