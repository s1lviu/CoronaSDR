#!/bin/bash
set -euo pipefail

# CoronaSDR Build, Install & Debug Script
# Usage:
#   ./build.sh              — Build, install, and launch on device
#   ./build.sh build        — Build only
#   ./build.sh install      — Install (assumes already built)
#   ./build.sh launch       — Launch on device
#   ./build.sh logs         — Stream live device logs (Console-like)
#   ./build.sh crash        — Fetch recent crash logs from device
#   ./build.sh clean        — Clean build folder
#   ./build.sh all          — Clean + build + install + launch + logs

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
APP_PATH="${BUILD_DIR}/Debug-iphoneos/CoronaSDR.app"
GENERATED_PROJECT="${PROJECT_DIR}/CoronaSDR.xcodeproj"
BUNDLE_ID="yo6say.coronasdr"
TEAM_ID="DDJCP893KF"
CRASH_DIR="${PROJECT_DIR}/CrashLogs"

ensure_generated_project() {
    local spec_file="${PROJECT_DIR}/project.yml"
    local pbxproj_file="${GENERATED_PROJECT}/project.pbxproj"

    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "ERROR: xcodegen is required to generate test scheme/project from project.yml." >&2
        echo "Install: brew install xcodegen" >&2
        exit 1
    fi

    if [ ! -f "$pbxproj_file" ] || [ "$spec_file" -nt "$pbxproj_file" ]; then
        echo "=== Generating Xcode project from project.yml ==="
        (cd "$PROJECT_DIR" && xcodegen generate)
    fi
}

# Auto-detect device
get_device_id() {
    local device_id
    # Extract UUID (pattern: 8-4-4-4-12 hex chars) from lines that are NOT unavailable
    device_id=$(xcrun devicectl list devices 2>/dev/null \
        | grep -v "unavailable" \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
        | head -1)
    if [ -z "$device_id" ]; then
        echo "ERROR: No available device found. Connect your iPhone and trust this Mac." >&2
        exit 1
    fi
    echo "$device_id"
}

get_test_destination_id() {
    local destination_id

    destination_id=$(xcodebuild \
        -project "$GENERATED_PROJECT" \
        -scheme CoronaSDRTests \
        -showdestinations 2>/dev/null \
        | sed -nE 's/.*platform:iOS, arch:arm64, id:([^,]+),.*/\1/p' \
        | grep -v "dvtdevice" \
        | head -1)

    if [ -z "$destination_id" ]; then
        echo "ERROR: No eligible iOS destination found for CoronaSDRTests." >&2
        echo "Run: xcodebuild -project \"$GENERATED_PROJECT\" -scheme CoronaSDRTests -showdestinations" >&2
        exit 1
    fi

    echo "$destination_id"
}

do_build() {
    echo "=== Building CoronaSDR ==="
    cd "$PROJECT_DIR"
    mkdir -p "$BUILD_DIR"

    xcodebuild \
        -target CoronaSDR \
        -sdk iphoneos \
        -arch arm64 \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="Apple Development" \
        CODE_SIGNING_ALLOWED=YES \
        ONLY_ACTIVE_ARCH=YES \
        -configuration Debug \
        build 2>&1 | tee "${BUILD_DIR}/build.log" | grep -E '(error:|warning:|BUILD|Signing|fatal)'

    local status=${PIPESTATUS[0]}
    if [ $status -ne 0 ]; then
        echo ""
        echo "=== BUILD FAILED ==="
        echo "Full log: ${BUILD_DIR}/build.log"
        echo ""
        echo "Last 30 lines with errors:"
        grep -A2 "error:" "${BUILD_DIR}/build.log" | tail -30
        exit 1
    fi

    echo "=== BUILD SUCCEEDED ==="
}

do_install() {
    local device_id
    device_id=$(get_device_id)

    echo "=== Installing on device ${device_id} ==="
    xcrun devicectl device install app \
        --device "$device_id" \
        "$APP_PATH" 2>&1

    echo "=== Installed ==="
}

do_launch() {
    local device_id
    device_id=$(get_device_id)

    echo "=== Launching CoronaSDR ==="
    xcrun devicectl device process launch \
        --device "$device_id" \
        "$BUNDLE_ID" 2>&1

    echo "=== Launched ==="
}

do_logs() {
    local device_id
    device_id=$(get_device_id)

    echo "=== Launching CoronaSDR with console attached (Ctrl+C to stop) ==="
    echo "=== You'll see all print() and os_log output in real-time ==="
    echo ""

    # Kill any existing instance first
    xcrun devicectl device process terminate \
        --device "$device_id" \
        "$BUNDLE_ID" 2>/dev/null || true

    # Launch with --console to attach stdin/stdout/stderr
    xcrun devicectl device process launch \
        --device "$device_id" \
        --console \
        "$BUNDLE_ID" 2>&1
}

do_crash() {
    local device_id
    device_id=$(get_device_id)

    mkdir -p "$CRASH_DIR"

    echo "=== Fetching crash logs ==="

    # Method 1: Copy crash logs from device
    local crash_src="$HOME/Library/Logs/CrashReporter/MobileDevice"
    if [ -d "$crash_src" ]; then
        echo "Looking in $crash_src ..."
        find "$crash_src" -name "*CoronaSDR*" -newer "${CRASH_DIR}/.last_fetch" 2>/dev/null | while read -r f; do
            cp "$f" "$CRASH_DIR/"
            echo "  Copied: $(basename "$f")"
        done
    fi

    # Method 2: Use devicectl to get diagnostics
    echo ""
    echo "Checking for crash reports via devicectl..."
    xcrun devicectl device info crashes \
        --device "$device_id" 2>&1 | head -50 || true

    # Method 3: Check .ips files
    local ips_dir="$HOME/Library/Logs/DiagnosticReports"
    if [ -d "$ips_dir" ]; then
        echo ""
        echo "Recent CoronaSDR crash reports in DiagnosticReports:"
        find "$ips_dir" -name "*CoronaSDR*" -mtime -7 2>/dev/null | while read -r f; do
            cp "$f" "$CRASH_DIR/"
            echo "  $(basename "$f") — $(stat -f '%Sm' "$f")"
        done
    fi

    touch "${CRASH_DIR}/.last_fetch"

    # Show most recent crash
    local latest
    latest=$(ls -t "$CRASH_DIR"/*.ips "$CRASH_DIR"/*.crash 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        echo ""
        echo "=== Most Recent Crash: $(basename "$latest") ==="
        echo ""
        # Show exception info and first part of backtrace
        head -100 "$latest"
    else
        echo ""
        echo "No CoronaSDR crash logs found yet."
        echo ""
        echo "Tips:"
        echo "  1. Open your iPhone → Settings → Privacy → Analytics & Improvements → Analytics Data"
        echo "  2. Look for entries starting with 'CoronaSDR'"
        echo "  3. Share the crash log via AirDrop/Mail"
        echo ""
        echo "  Or: Open Console.app on Mac, select your iPhone, reproduce the crash,"
        echo "  and look for crash/assertion messages."
    fi
}

do_clean() {
    echo "=== Cleaning build folder ==="
    rm -rf "$BUILD_DIR"
    echo "=== Clean done ==="
}

do_test() {
    local device_id
    local destination_id
    device_id=$(get_device_id)
    ensure_generated_project
    destination_id=$(get_test_destination_id)
    mkdir -p "$BUILD_DIR"

    echo "=== Running tests on device ${device_id} (xcode destination: ${destination_id}) ==="

    set +e
    xcodebuild \
        -project "$GENERATED_PROJECT" \
        -scheme CoronaSDRTests \
        -destination "id=${destination_id}" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="Apple Development" \
        CODE_SIGNING_ALLOWED=YES \
        -configuration Debug \
        test 2>&1 | tee "${BUILD_DIR}/test.log" | grep -E '(error:|warning:|Test Suite|Test Case|\*\* TEST|\*\* BUILD|Failing tests:|Executed)'
    local status=${PIPESTATUS[0]}
    set -e

    if [ $status -ne 0 ]; then
        echo ""
        echo "=== TESTS FAILED ==="
        echo "Full log: ${BUILD_DIR}/test.log"
        echo ""
        grep -E "(Failing tests:|error:|Test Case '.*' failed)" "${BUILD_DIR}/test.log" | tail -40 || true
        exit 1
    fi

    echo "=== TESTS PASSED ==="
}

do_test_perf() {
    local device_id
    local destination_id
    device_id=$(get_device_id)
    ensure_generated_project
    destination_id=$(get_test_destination_id)
    mkdir -p "$BUILD_DIR"

    echo "=== Running performance tests on device ${device_id} (xcode destination: ${destination_id}) ==="

    set +e
    xcodebuild \
        -project "$GENERATED_PROJECT" \
        -scheme CoronaSDRTests \
        -destination "id=${destination_id}" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="Apple Development" \
        CODE_SIGNING_ALLOWED=YES \
        -configuration Debug \
        -only-testing:CoronaSDRTests/IQRingBufferTests/testPerformanceWriteReadRawPath \
        -only-testing:CoronaSDRTests/AudioRingBufferTests/testPerformanceWriteReadHotPath \
        test 2>&1 | tee "${BUILD_DIR}/test-perf.log" | grep -E '(error:|warning:|Test Suite|Test Case|\*\* TEST|\*\* BUILD|Failing tests:|Executed|measure)'
    local status=${PIPESTATUS[0]}
    set -e

    if [ $status -ne 0 ]; then
        echo ""
        echo "=== PERFORMANCE TESTS FAILED ==="
        echo "Full log: ${BUILD_DIR}/test-perf.log"
        echo ""
        grep -E "(Failing tests:|error:|Test Case '.*' failed)" "${BUILD_DIR}/test-perf.log" | tail -40 || true
        exit 1
    fi

    echo "=== PERFORMANCE TESTS PASSED ==="
}

# Main
case "${1:-}" in
    build)
        do_build
        ;;
    install)
        do_install
        ;;
    launch)
        do_launch
        ;;
    logs)
        do_logs
        ;;
    crash)
        do_crash
        ;;
    test)
        do_test
        ;;
    test-perf|perf)
        do_test_perf
        ;;
    clean)
        do_clean
        ;;
    all)
        do_clean
        do_build
        do_install
        do_launch
        sleep 2
        do_logs
        ;;
    ""|run)
        do_build
        do_install
        do_launch
        ;;
    *)
        echo "Usage: $0 {build|install|launch|logs|crash|test|test-perf|clean|all|run}"
        echo ""
        echo "  (no args) / run  — Build + install + launch"
        echo "  build            — Build only"
        echo "  install          — Install on device"
        echo "  launch           — Launch on device"
        echo "  logs             — Stream live device logs"
        echo "  crash            — Fetch crash logs"
        echo "  test             — Run all XCTest tests on connected device"
        echo "  test-perf|perf   — Run only performance XCTest cases on connected device"
        echo "  clean            — Clean build folder"
        echo "  all              — Clean + build + install + launch + logs"
        exit 1
        ;;
esac
