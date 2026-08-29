#!/bin/bash
set -e

# Configuration
LIQUID_REPO="https://github.com/jgaeddert/liquid-dsp.git"
BUILD_DIR="/tmp/liquid-dsp-build"
PROJECT_ROOT="$(pwd)"
OUTPUT_DIR="$PROJECT_ROOT/SDRApp/Packages/CLiquidDSP"
INCLUDE_DIR="$OUTPUT_DIR/Sources/CLiquidDSP/include"
LIB_DIR="$OUTPUT_DIR/lib"

# Check if output directory exists
mkdir -p "$INCLUDE_DIR"
mkdir -p "$LIB_DIR"

echo "🚀 Building liquid-dsp for iOS (arm64)..."

# Clone repository
if [ -d "$BUILD_DIR" ]; then
    rm -rf "$BUILD_DIR"
fi
git clone --depth 1 "$LIQUID_REPO" "$BUILD_DIR"
cd "$BUILD_DIR"

# Bootstrap
echo "🔧 Bootstrapping..."
./bootstrap.sh > /dev/null

# Configure for iOS (arm64)
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
ARCH="arm64"
MIN_VERSION="-miphoneos-version-min=17.0"

export CC="xcrun -sdk iphoneos clang"
export CFLAGS="-arch $ARCH -isysroot $SDK_PATH $MIN_VERSION -O3 -fno-common"
export LDFLAGS="-arch $ARCH -isysroot $SDK_PATH $MIN_VERSION"

echo "⚙️ Configuring..."
export ac_cv_func_malloc_0_nonnull=yes
export ac_cv_func_realloc_0_nonnull=yes
./configure --host=aarch64-apple-darwin --prefix="$BUILD_DIR/install" > /dev/null

# Build
echo "🔨 Compiling..."
make -j$(sysctl -n hw.ncpu)


# Copy artifacts
echo "📦 Installing to project..."
if [ -f "include/liquid.h" ]; then
    cp include/liquid.h "$INCLUDE_DIR/"
elif [ -f "liquid.h" ]; then
    cp liquid.h "$INCLUDE_DIR/"
else
    echo "❌ Error: liquid.h not found!"
    exit 1
fi
if [ -f "libliquid.a" ]; then
    cp libliquid.a "$LIB_DIR/"
elif [ -f "libliquid.ar" ]; then
    cp libliquid.ar "$LIB_DIR/libliquid.a"
else
    echo "❌ Error: libliquid.a (or .ar) not found!"
    exit 1
fi

# Cleanup
cd "$PROJECT_ROOT"
rm -rf "$BUILD_DIR"


echo "✅ liquid-dsp built successfully!"
echo "Headers: $INCLUDE_DIR/liquid.h"
echo "Library: $LIB_DIR/libliquid.a"
