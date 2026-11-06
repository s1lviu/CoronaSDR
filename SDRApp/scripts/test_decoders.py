#!/usr/bin/env python3
"""Build and test the production decoder/DSP sources on macOS without an iOS device."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import argparse
import hashlib
import json
import tarfile
import urllib.request

root = Path(__file__).resolve().parents[1]
work = root / "build" / "decoder-host"
sources = work / "Sources"
parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--liquid-build", type=Path)
options, swift_args = parser.parse_known_args()
liquid = options.liquid_build or work / "native-liquid"
if not (liquid / "libliquid.dylib").exists():
    archive = work / "liquid-dsp-v1.7.0.tar.gz"
    work.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        urllib.request.urlretrieve("https://codeload.github.com/jgaeddert/liquid-dsp/tar.gz/refs/tags/v1.7.0", archive)
    expected = "33c42ebc2e6088570421e282c6332e899705d42b4f73ebd1212e6a11da714dd4"
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise SystemExit("liquid-dsp archive checksum mismatch")
    with tarfile.open(archive) as tar:
        tar.extractall(work, filter="data")
    subprocess.run(["rtk", "proxy", "cmake", "-S", str(work / "liquid-dsp-1.7.0"), "-B", str(liquid),
                    "-DBUILD_EXAMPLES=OFF", "-DBUILD_AUTOTESTS=OFF", "-DBUILD_BENCHMARKS=OFF", "-DENABLE_SIMD=OFF", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0"], check=True)
    subprocess.run(["rtk", "proxy", "cmake", "--build", str(liquid), "-j", "6"], check=True)
if sources.exists():
    shutil.rmtree(sources)
sources.mkdir(parents=True, exist_ok=True)
for name in ["CFT8", "SDRDecoding", "CLiquidDSP"]:
    shutil.copytree(root / "Packages" / name / "Sources" / name, sources / name, dirs_exist_ok=True)
for name, files in {
    "RTLTCPClientKit": ["IQRingBuffer.swift"],
    "SDRCoreDSP": ["FIRFilter.swift", "ChannelFilterDesign.swift", "ComplexBuffer.swift", "NCOMixer.swift", "Demodulator.swift", "CWDemodulator.swift", "Demodulators.swift", "AGC.swift", "DCBlocker.swift", "Resampler.swift", "DecoderAudioPath.swift"],
}.items():
    dest = sources / name
    dest.mkdir(exist_ok=True)
    for file in files:
        shutil.copy2(root / "Packages" / name / "Sources" / name / file, dest / file)
shutil.copytree(root / "Tests" / "DecoderFixtures", sources / "DecoderFixtures", dirs_exist_ok=True)
if (work / "Tests").exists():
    shutil.rmtree(work / "Tests")
shutil.copytree(root / "Tests" / "DecoderTests", work / "Tests")
(work / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DecoderHarness", platforms: [.macOS(.v14)], targets: [
    .target(name: "CFT8", exclude: ["vendor/LICENSE", "vendor/fft/COPYING"], publicHeadersPath: "include", cSettings: [.define("CORONA_FT8_NO_LOG"), .unsafeFlags(["-O2"], .when(configuration: .debug))]),
    .target(name: "SDRDecoding", dependencies: ["CFT8"]),
    .target(name: "RTLTCPClientKit"),
    .target(name: "CLiquidDSP", publicHeadersPath: "include"),
    .target(name: "SDRCoreDSP", dependencies: ["CLiquidDSP"], linkerSettings: [.linkedFramework("Accelerate"), .linkedLibrary("liquid"), .unsafeFlags(["-L", LIQUID_PATH, "-Xlinker", "-rpath", "-Xlinker", LIQUID_PATH])]),
    .target(name: "DecoderFixtures", dependencies: ["CFT8"], publicHeadersPath: "include", cSettings: [.headerSearchPath("../CFT8/vendor")]),
    .testTarget(name: "DecoderTests", dependencies: ["SDRDecoding", "SDRCoreDSP", "RTLTCPClientKit", "DecoderFixtures"], path: "Tests", resources: [.copy("Fixtures")])
])
'''.replace("LIQUID_PATH", json.dumps(str(liquid.resolve()))))
command = ["rtk", "proxy", "swift", "test", "--package-path", str(work), "--disable-sandbox"] + swift_args
env = dict(os.environ)
env["CLANG_MODULE_CACHE_PATH"] = str(work / "ModuleCache")
env["SWIFT_MODULECACHE_PATH"] = str(work / "ModuleCache")
raise SystemExit(subprocess.call(command, env=env))
