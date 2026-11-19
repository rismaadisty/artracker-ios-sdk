#!/usr/bin/env bash
# ==============================================================================
# ARTracker iOS SDK - dSYM Upload Helper Script
# Usage:
#   ./Scripts/upload-dsym.sh [OPTIONS] <path-to-dSYM-or-app>
#
# Options:
#   -k, --api-key <key>    ARTracker API Key (or ARTRACKER_API_KEY env var)
#   -u, --url <url>        ARTracker Base URL (default: https://artracker.exlm.my.id)
#   -a, --app-id <bundle>  App Bundle Identifier (or PRODUCT_BUNDLE_IDENTIFIER env var)
#   -r, --version <ver>    Release / App Version (default: $MARKETING_VERSION from Xcode or 1.0.0)
#   -b, --build <num>      Build Number (default: $CURRENT_PROJECT_VERSION from Xcode)
#   -v, --verbose          Enable verbose output
#   -h, --help             Show this help message
#
# Xcode Run Script Build Phase Integration:
#   if [ "$CONFIGURATION" = "Release" ]; then
#     "${PROJECT_DIR}/../Scripts/upload-dsym.sh" --api-key "YOUR_KEY"
#   fi
# ==============================================================================

set -euo pipefail

DEFAULT_URL="https://artracker.exlm.my.id"
API_KEY="${ARTRACKER_API_KEY:-}"
BASE_URL="${ARTRACKER_URL:-$DEFAULT_URL}"
APP_ID="${PRODUCT_BUNDLE_IDENTIFIER:-}"
APP_VERSION="${MARKETING_VERSION:-${APP_VERSION:-}}"
BUILD_NUMBER="${CURRENT_PROJECT_VERSION:-${BUILD_NUMBER:-}}"
VERBOSE=false
TARGET_PATH=""

print_help() {
    cat << EOF
ARTracker dSYM Upload Tool

Usage:
  $(basename "$0") [OPTIONS] [PATH]

Arguments:
  PATH                   Path to .dSYM bundle, .xcarchive, or directory containing dSYMs.
                         If omitted, uses Xcode environment variables.

Options:
  -k, --api-key <KEY>    ARTracker Secret Key (art_sec_...)
  -u, --url <URL>        Backend Base URL (default: $DEFAULT_URL)
  -a, --app-id <ID>      App Bundle Identifier (can also set PRODUCT_BUNDLE_IDENTIFIER)
  -r, --version <VER>    Release Version (can also set MARKETING_VERSION)
  -b, --build <NUM>      Build Number (can also set CURRENT_PROJECT_VERSION)
  -v, --verbose          Print debug info
  -h, --help             Show this help
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--api-key)
            API_KEY="$2"
            shift 2
            ;;
        -u|--url)
            BASE_URL="$2"
            shift 2
            ;;
        -a|--app-id)
            APP_ID="$2"
            shift 2
            ;;
        -r|--version)
            APP_VERSION="$2"
            shift 2
            ;;
        -b|--build)
            BUILD_NUMBER="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            print_help
            exit 1
            ;;
        *)
            if [[ -z "$TARGET_PATH" ]]; then
                TARGET_PATH="$1"
            fi
            shift
            ;;
    esac
done

# If path is not provided via CLI, try Xcode Build environment
if [[ -z "$TARGET_PATH" ]]; then
    if [[ -n "${DWARF_DSYM_FOLDER_PATH:-}" && -n "${DWARF_DSYM_FILE_NAME:-}" ]]; then
        TARGET_PATH="${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}"
    elif [[ -n "${ARCHIVE_DSYMS_PATH:-}" ]]; then
        TARGET_PATH="${ARCHIVE_DSYMS_PATH}"
    fi
fi

# Fallback to Info.plist if MARKETING_VERSION not available in environment
if [[ -z "$APP_VERSION" && -n "${PRODUCT_SETTINGS_PATH:-}" && -f "${PRODUCT_SETTINGS_PATH:-}" ]]; then
    APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PRODUCT_SETTINGS_PATH" 2>/dev/null || echo "")
fi
if [[ -z "$BUILD_NUMBER" && -n "${PRODUCT_SETTINGS_PATH:-}" && -f "${PRODUCT_SETTINGS_PATH:-}" ]]; then
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PRODUCT_SETTINGS_PATH" 2>/dev/null || echo "")
fi

# Default fallback to 1.0.0 if not specified
if [[ -z "$APP_VERSION" ]]; then
    APP_VERSION="1.0.0"
fi

if [[ -z "$API_KEY" ]]; then
    echo "❌ Error: API Key is required. Pass --api-key or export ARTRACKER_API_KEY." >&2
    exit 1
fi

if [[ -z "$TARGET_PATH" ]]; then
    echo "❌ Error: No dSYM path specified and not running inside Xcode build phase." >&2
    print_help
    exit 1
fi

if [[ ! -e "$TARGET_PATH" ]]; then
    echo "❌ Error: Target path does not exist: $TARGET_PATH" >&2
    exit 1
fi

echo "=========================================================="
echo " ARTracker dSYM Uploader"
echo " Endpoint: $BASE_URL"
echo " Target:   $TARGET_PATH"
echo " Version:  $APP_VERSION${BUILD_NUMBER:+ (Build $BUILD_NUMBER)}"
echo "=========================================================="

# Collect all .dSYM bundles
DSYM_BUNDLES=()
if [[ "$TARGET_PATH" == *.dSYM ]]; then
    DSYM_BUNDLES+=("$TARGET_PATH")
else
    while IFS= read -r -d '' dsym; do
        DSYM_BUNDLES+=("$dsym")
    done < <(find "$TARGET_PATH" -name "*.dSYM" -print0)
fi

if [[ ${#DSYM_BUNDLES[@]} -eq 0 ]]; then
    echo "⚠️ Warning: No .dSYM bundles found at '$TARGET_PATH'."
    exit 0
fi

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

SUCCESS_COUNT=0
TOTAL_COUNT=${#DSYM_BUNDLES[@]}

for dsym in "${DSYM_BUNDLES[@]}"; do
    NAME=$(basename "$dsym")
    echo ""
    echo "Processing $NAME..."

    # Extract UUIDs via dwarfdump
    if command -v dwarfdump >/dev/null 2>&1; then
        UUIDS=$(dwarfdump --uuid "$dsym" | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        ARCHS=$(dwarfdump --uuid "$dsym" | awk '{print $3}' | tr -d '()' | tr '\n' ',' | sed 's/,$//')
        echo "  UUIDs:        $UUIDS"
        echo "  Architecture: $ARCHS"
    else
        UUIDS=""
        ARCHS=""
    fi

    # Zip dSYM bundle
    ZIP_FILE="${TEMP_DIR}/${NAME}.zip"
    DSYM_DIR=$(dirname "$dsym")
    (cd "$DSYM_DIR" && zip -rq "$ZIP_FILE" "$NAME")

    FILE_SIZE=$(stat -f%z "$ZIP_FILE" 2>/dev/null || stat -c%s "$ZIP_FILE")
    echo "  Archive Size: $(( FILE_SIZE / 1024 )) KB"

    # Upload to backend symbols endpoint
    UPLOAD_URL="${BASE_URL%/}/api/v1/symbols?version=${APP_VERSION}"
    if [[ -n "$BUILD_NUMBER" ]]; then
        UPLOAD_URL="${UPLOAD_URL}&build=${BUILD_NUMBER}"
    fi
    echo "  Uploading to ${UPLOAD_URL}..."

    HTTP_STATUS=$(curl -s -o "${TEMP_DIR}/response.txt" -w "%{http_code}" \
        -X POST "$UPLOAD_URL" \
        -H "X-Artracker-Key: $API_KEY" \
        -H "X-App-Version: $APP_VERSION" \
        -F "file=@${ZIP_FILE}" \
        -F "app_id=${APP_ID}" \
        -F "uuids=${UUIDS}" \
        -F "archs=${ARCHS}" \
        -F "bundle_name=${NAME}")

    if [[ "$HTTP_STATUS" =~ ^2 ]]; then
        echo "  ✅ Uploaded successfully (HTTP $HTTP_STATUS)"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  ⚠️ Upload returned HTTP $HTTP_STATUS"
        RESP=$(cat "${TEMP_DIR}/response.txt" 2>/dev/null || echo "")
        echo "  Response: $RESP"
        
        if [[ "$HTTP_STATUS" == "400" && "$RESP" =~ "release version is required" ]]; then
            echo ""
            echo "  💡 Hint: Versi rilis aplikasi wajib disertakan."
            echo "     Gunakan opsi --version <versi> (contoh: --version 1.0.0)"
            echo "     atau pastikan MARKETING_VERSION terisi di target Xcode."
            echo ""
        elif [[ "$HTTP_STATUS" == "403" && "$RESP" =~ "secret key required" ]]; then
            echo ""
            echo "  💡 Hint: Key yang digunakan adalah Client/Public Key."
            echo "     Endpoint ini mewajibkan Secret Key (art_sec_...)."
            echo "     Silakan ambil Secret Key dari Project Settings -> API Keys di dashboard ARTracker."
            echo ""
        fi
    fi
done

echo ""
echo "=========================================================="
echo " Upload Summary: $SUCCESS_COUNT / $TOTAL_COUNT dSYMs processed"
echo "=========================================================="

