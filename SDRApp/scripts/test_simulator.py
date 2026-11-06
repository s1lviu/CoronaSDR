#!/usr/bin/env python3
"""Run app tests without a radio. Builds a separate arm64 simulator DSP library."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tarfile
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument("--device", required=True, help="Existing iOS simulator UDID")
parser.add_argument("--scheme", choices=["CoronaSDRTests", "CoronaSDRUITests"])
parser.add_argument("--only-testing", help="Optional Xcode target/class/test selector")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
work = root / "build"
library = work / "liquid-simulator"
work.mkdir(exist_ok=True)

def run(command):
    subprocess.run(["rtk", "proxy", *map(str, command)], cwd=root, check=True)

if not (library / "libliquid.a").exists():
    archive = work / "liquid-dsp-v1.7.0.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve("https://codeload.github.com/jgaeddert/liquid-dsp/tar.gz/refs/tags/v1.7.0", archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != "33c42ebc2e6088570421e282c6332e899705d42b4f73ebd1212e6a11da714dd4":
        raise SystemExit("liquid-dsp archive checksum mismatch")
    with tarfile.open(archive) as tar:
        tar.extractall(work, filter="data")
    source = work / "liquid-dsp-1.7.0"
    cmake = source / "CMakeLists.txt"
    text = cmake.read_text()
    text = text.replace("add_library(${LIBNAME} SHARED", "add_library(${LIBNAME} STATIC")
    text = text.replace("include(cmake/FindSIMD.cmake)", "if(ENABLE_SIMD)\ninclude(cmake/FindSIMD.cmake)\nendif()")
    cmake.write_text(text)
    run(["cmake", "-S", source, "-B", library, "-DCMAKE_SYSTEM_NAME=iOS",
         "-DCMAKE_OSX_SYSROOT=iphonesimulator", "-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0",
         "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
         "-DBUILD_EXAMPLES=OFF", "-DBUILD_AUTOTESTS=OFF", "-DBUILD_BENCHMARKS=OFF", "-DENABLE_SIMD=OFF"])
    run(["cmake", "--build", library, "-j", "6"])

run(["xcodegen", "generate"])
for scheme in [args.scheme] if args.scheme else ["CoronaSDRTests", "CoronaSDRUITests"]:
    run(["xcodebuild", "-project", "CoronaSDR.xcodeproj", "-scheme", scheme,
         "-sdk", "iphonesimulator", "-destination", "platform=iOS Simulator,id="+args.device,
         "-configuration", "Debug", "-derivedDataPath", "build/DecoderSimDerivedData",
         "-clonedSourcePackagesDirPath", "build/SourcePackages",
         "SUPPORTED_PLATFORMS=iphoneos iphonesimulator", "LIBRARY_SEARCH_PATHS=$(SRCROOT)/build/liquid-simulator",
         "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64", "-parallel-testing-enabled", "NO",
         *(["-only-testing:"+args.only_testing] if args.only_testing else []), "test"])
