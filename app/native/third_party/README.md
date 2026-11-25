# Vendored third-party code

Copied verbatim (no local edits). Update by re-copying the same files from a newer tag and
bumping `renderEngineVersion` in `lib/render.dart` if the output can change.

| Library | Files | Source, pinned | License |
|---|---|---|---|
| Signalsmith Stretch | `signalsmith-stretch/signalsmith-stretch.h` | https://github.com/Signalsmith-Audio/signalsmith-stretch tag `1.4.0` (commit `a670068d9aeb64913331d5cc29337b19a457a7df`). The header's own `version` constant says 1.3.2 | MIT, `signalsmith-stretch/LICENSE.txt` |
| Signalsmith Linear (Stretch's dependency at 1.4.0; it replaced the old `dsp` library) | `signalsmith-linear/stft.h`, `signalsmith-linear/fft.h` (the only two Stretch includes) | https://github.com/Signalsmith-Audio/linear tag `0.6.4` (commit `de55e6a50ffcf6f8f43f649692d94691c7025151`), the tag Stretch 1.4.0's CMakeLists pins | MIT, `signalsmith-linear/LICENSE.txt` |
| dr_flac 0.13.5, dr_wav 0.14.7 | `dr_libs/dr_flac.h`, `dr_libs/dr_wav.h` | https://github.com/mackron/dr_libs commit `e381981afa52800b9a3864df548353ff67252fbc` (master as of 2026-11-20; dr_libs has no tags) | Public domain (Unlicense) or MIT-0, `dr_libs/LICENSE` |
