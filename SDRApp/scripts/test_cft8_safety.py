#!/usr/bin/env python3
"""Run the production C decoder and message parser under address/undefined sanitizers."""
from pathlib import Path
import os
import subprocess

root = Path(__file__).resolve().parents[1]
source = root / "Packages/CFT8/Sources/CFT8"
output = root / "build/cft8-safety"
output.parent.mkdir(exist_ok=True)
files = [root / "Tests/CFT8Safety/main.c"] + sorted(source.glob("*.c"))
files += sorted((source / "vendor/ft8").glob("*.c"))
files += sorted((source / "vendor/fft").glob("*.c"))
subprocess.run(["rtk", "proxy", "clang", "-O1", "-g", "-fsanitize=address,undefined",
                "-fno-omit-frame-pointer", "-DCORONA_FT8_NO_LOG", "-I"+str(source / "include"),
                "-I"+str(source / "vendor"), *map(str,files), "-o", str(output)], check=True)
env = dict(os.environ, UBSAN_OPTIONS="halt_on_error=1", ASAN_OPTIONS="halt_on_error=1")
subprocess.run([str(output)], env=env, check=True)
