# Native render engine (WP-C1)

`maestro_render/` builds `maestro_render.dll`: FLAC/WAV in, key/tempo shifted 16-bit WAV out
(Signalsmith Stretch + dr_libs, vendored in `third_party/`). Dart calls it from `lib/render.dart`.

- **App builds:** automatic. `flutter build windows` builds the DLL and installs it next to the exe.
- **Tests:** automatic. `flutter test` (from `app/`) builds the DLL into `native/build/` with CMake
  in `setUpAll` (found on PATH or via `vswhere`, i.e. VS Build Tools with the C++ workload).
  To build it by hand, the one command from `app/` is:

  ```
  cmake -S native/maestro_render -B native/build -A x64 && cmake --build native/build --config Release
  ```

The library is always compiled optimised, even in Debug app builds (unoptimised is ~15x slower).
