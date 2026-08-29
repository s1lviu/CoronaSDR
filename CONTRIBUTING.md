# Contributing

Thanks for improving CoronaSDR.

1. Open an issue for bugs or substantial changes.
2. Create a focused branch from `main`.
3. Keep changes small and include a regression test for non-trivial logic.
4. Run a local build:

   ```bash
   cd SDRApp
   xcodebuild -project CoronaSDR.xcodeproj -scheme CoronaSDR -sdk iphoneos CODE_SIGNING_ALLOWED=NO -configuration Debug build
   ```

5. Open a pull request describing the problem, the change, and how it was verified.

Contributions are accepted under GPL-3.0-only. By submitting a contribution, you confirm that you have the right to license it under those terms.
