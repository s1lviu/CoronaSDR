WAV recordings and TXT annotations copied unchanged from kgoba/ft8_lib:
https://github.com/kgoba/ft8_lib/tree/9fec6ca39886edbf96f4f5e71edc76da5074e871/test/wav

The upstream repository uses the MIT license, retained in THIRD_PARTY_NOTICES.md.
The original TXT files are upstream annotations, not a complete ground-truth corpus.
Additional app outputs are checked separately against the reference runs documented
below. They are not counted as matches to the original annotations.

SHA-256:
aea482f19500a91cd85ef5441ae3b05dba949d7f51da4ed35efc1ccf3081f482  191111_110115.wav
f6bb1989793fd8f03e926845da7a91eb0ef43b75648f4362f9d0c24789285fd9  191111_110130.wav
d4428df08ae6f43429e68d8d3a263047656ff91d17ce182b246d45645531b953  websdr_test1.wav

See repository-root docs/DECODER-VALIDATION.md for measured results and limitations.

Independent reference run, 2026-11-06:
WSJT-X 3.0.2 official standalone jt9 arm64 release:
https://github.com/WSJTX/wsjtx/releases/tag/v3.0.2
jt9-arm64.tar.gz SHA-256:
8b96d5b17608cb3f9e35d03453ae4fe8f12fe5c67f4957811fa8addd1e2cc793
Command: jt9 -8 -d 3 -p 15 -L 200 -H 3000 -a OUTPUT_DIR -t OUTPUT_DIR INPUT.wav
The original recordings were decoded unchanged. An additional busy-band run
removed the first 12000 samples and appended 12000 zero samples (same length).
This puts the late-starting signals within the reference decoder's search range.
The seven additional app outputs are all reproduced in that shifted run.
The original LZ1CWK DC8VA RR73 annotation was not reproduced in the app,
WSJT-X 3.0.2 original/shifted runs, or the independent ft8mon comparison.
It remains unresolved; the original annotation has not been removed or changed.
No reference decoder implementation is linked into the app.
