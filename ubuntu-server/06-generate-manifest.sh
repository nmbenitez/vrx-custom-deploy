#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Configuration
# ============================================
PACKAGE_DIR="${PACKAGE_DIR:-/srv/packages}"
MANIFEST="$PACKAGE_DIR/manifest.txt"

# ============================================
# Generate recursive manifest atomically
# ============================================
if [ ! -d "$PACKAGE_DIR" ]; then
    echo "ERROR: Package directory not found: $PACKAGE_DIR" >&2
    exit 1
fi

TEMP_MANIFEST=$(mktemp "$PACKAGE_DIR/.manifest.XXXXXXXX")
trap 'rm -f "$TEMP_MANIFEST"' EXIT

COUNT=0
while IFS= read -r -d '' FULLPATH; do
    RELATIVE=${FULLPATH#"$PACKAGE_DIR"/}
    # This plaintext format cannot represent newlines or the pipe delimiter.
    if [[ "$RELATIVE" == *'|'* || "$RELATIVE" == *$'\n'* || "$RELATIVE" == *$'\r'* ]]; then
        echo "ERROR: Unsupported filename in manifest: $RELATIVE" >&2
        exit 1
    fi
    SIZE=$(stat -c%s -- "$FULLPATH")
    SHA256=$(sha256sum -- "$FULLPATH" | awk '{print $1}')
    printf '%s|%s|%s\n' "$RELATIVE" "$SIZE" "$SHA256" >> "$TEMP_MANIFEST"
    COUNT=$((COUNT + 1))
done < <(find "$PACKAGE_DIR" -type d -name '.*' -prune -o -type f ! -name 'manifest.txt' ! -name '.manifest.*' ! -name '*.download' -print0 | LC_ALL=C sort -z)

chmod 644 "$TEMP_MANIFEST"
mv -f -- "$TEMP_MANIFEST" "$MANIFEST"
trap - EXIT
printf 'Manifest generated: %s (%s files)\n' "$MANIFEST" "$COUNT"
cat "$MANIFEST"
