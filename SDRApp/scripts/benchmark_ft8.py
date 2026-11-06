#!/usr/bin/env python3
"""Bounded production-C replay soak. Host timings are not an iPhone performance claim."""
import argparse
import ctypes as c
import json
from pathlib import Path
import platform
import resource
import statistics
import subprocess
import time
import wave

parser = argparse.ArgumentParser()
parser.add_argument("--cycles", type=int, default=30)
args = parser.parse_args()
if not 1 <= args.cycles <= 1000:
    parser.error("cycles must be between 1 and 1000")
root = Path(__file__).resolve().parents[1]
source = root / "Packages/CFT8/Sources/CFT8"
binary = root / "build/ft8-benchmark.dylib"
binary.parent.mkdir(exist_ok=True)
files = sorted(source.glob("*.c")) + sorted((source/"vendor/ft8").glob("*.c")) + sorted((source/"vendor/fft").glob("*.c"))
subprocess.run(["rtk", "proxy", "clang", "-O2", "-dynamiclib", "-DCORONA_FT8_NO_LOG",
                "-I"+str(source/"include"), *map(str,files), "-o", str(binary)], check=True)
lib = c.CDLL(str(binary))

class Result(c.Structure):
    _fields_ = [("text",c.c_char*35),("payload",c.c_uint8*10),("hz",c.c_float),
                ("seconds",c.c_float),("kind",c.c_int),("supported",c.c_int)]

lib.corona_ft8_create.restype = c.c_void_p
lib.corona_ft8_decode.argtypes = [c.c_void_p,c.POINTER(c.c_float),c.c_int,c.POINTER(Result),c.c_int]
lib.corona_ft8_destroy.argtypes = [c.c_void_p]
decoder = lib.corona_ft8_create()
if not decoder:
    raise MemoryError("Decoder allocation failed")
recordings = {}
for name in ["191111_110115","191111_110130","websdr_test1"]:
    with wave.open(str(root/"Tests/DecoderTests/Fixtures"/(name+".wav"))) as wav:
        assert (wav.getframerate(),wav.getnchannels(),wav.getsampwidth()) == (12000,1,2)
        raw = wav.readframes(wav.getnframes())
    pcm = (c.c_int16*(len(raw)//2)).from_buffer_copy(raw)
    samples = (c.c_float*216000)()
    for i, value in enumerate(pcm):
        samples[i] = value/32768
    recordings[name] = samples
results = (Result*160)()
timings = {name:[] for name in recordings}
cpu_timings = {name:[] for name in recordings}
baseline = {}
rss_after_warmup = None
try:
    for cycle in range(args.cycles+1):
        for name, samples in recordings.items():
            start = time.perf_counter()
            cpu_start = time.process_time()
            count = lib.corona_ft8_decode(decoder,samples,216000,results,160)
            elapsed = time.perf_counter()-start
            cpu_elapsed = time.process_time()-cpu_start
            assert count >= 0, (name,count)
            output = sorted(r.text.decode() for r in results[:count])
            if cycle == 0:
                baseline[name] = output
            else:
                assert output == baseline[name], (cycle,name,output)
                timings[name].append(elapsed)
                cpu_timings[name].append(cpu_elapsed)
        if cycle == 0:
            rss_after_warmup = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
finally:
    lib.corona_ft8_destroy(decoder)
report = {
    "host":platform.platform(), "cycles_after_warmup":args.cycles,
    "windows_after_warmup":args.cycles*len(recordings),
    "peak_rss_bytes_after_warmup":rss_after_warmup,
    "peak_rss_bytes_final":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
    "recordings":{name:{"messages":baseline[name], "median_seconds":statistics.median(values),
                        "max_seconds":max(values), "median_cpu_seconds":statistics.median(cpu_timings[name])} for name,values in timings.items()},
}
print(json.dumps(report,indent=2))
