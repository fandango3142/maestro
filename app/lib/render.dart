import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'library.dart';

/// Bump when the render output changes (engine settings, normalisation); old cache files are then ignored.
const renderEngineVersion = 1;

/// `k{shift}_t{tempo×100}_v{n}.wav` (SPEC §4), or null when shift 0 / tempo 1.00 needs no render.
String? renderFileName(int shift, double tempo) {
  final t = (tempo * 100).round();
  if (shift == 0 && t == 100) return null;
  return 'k${shift}_t${t}_v$renderEngineVersion.wav';
}

// ponytail: Windows only. On iPad the lib is linked into the app, so this becomes DynamicLibrary.process().
/// The native render library. Next to the exe in a built app; tests point it at the CMake build output.
String renderLibraryPath = 'maestro_render.dll';

class RenderException implements Exception {
  final int code;
  final String input;
  RenderException(this.code, this.input);

  static const _reasons = {
    -1: 'bad arguments',
    -2: "can't read input (missing, corrupt, or too short)",
    -3: "can't write output",
    -4: 'out of memory',
    -5: 'internal error',
  };

  @override
  String toString() => 'Render failed ($code: ${_reasons[code] ?? 'unknown'}) for $input';
}

/// The song's backing track at [keyShift]/[tempo] (default: the song's own settings).
/// Returns `instrumental.flac` when nothing needs rendering, else the cached or newly rendered WAV.
Future<File> ensureRender(Song s, {int? keyShift, double? tempo, void Function(double)? onProgress}) {
  final shift = keyShift ?? s.keyShift;
  final t = tempo ?? s.tempo;
  final source = File('${s.dir.path}/instrumental.flac');
  final name = renderFileName(shift, t);
  if (name == null) return Future.value(source);
  return renderFile(source, File('${s.dir.path}/render/$name'), shift, t, onProgress: onProgress);
}

class _Job {
  final Pointer<Float> progress = calloc<Float>();
  bool finished = false;
  late final Future<File> future;
}

final _jobs = <String, _Job>{};

/// Renders [input] (FLAC, or WAV by extension) to [output] unless [output] already exists.
/// Concurrent calls for the same output share one render. [onProgress] gets 0..1 about 6× a second.
Future<File> renderFile(File input, File output, int semitones, double tempo,
    {void Function(double)? onProgress}) {
  final key = output.absolute.path.toLowerCase(); // Windows paths are case-insensitive
  var job = _jobs[key];
  if (job == null) {
    if (output.existsSync()) return Future.value(output); // complete: renders land via rename
    final j = job = _jobs[key] = _Job();
    // Use the rounded tempo so the file content always matches its name.
    j.future = _run(j, input, output, semitones, (tempo * 100).round() / 100).whenComplete(() {
      j.finished = true;
      calloc.free(j.progress);
      _jobs.remove(key);
    });
  }
  if (onProgress == null) return job.future;
  final j = job;
  final timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
    if (!j.finished) onProgress(j.progress.value);
  });
  return j.future.whenComplete(timer.cancel);
}

Future<File> _run(_Job job, File input, File output, int semitones, double tempo) async {
  await output.parent.create(recursive: true);
  final code = await _spawn(
      renderLibraryPath, input.absolute.path, output.absolute.path, semitones.toDouble(), tempo, job.progress.address);
  if (code != 0) throw RenderException(code, input.path);
  return output;
}

// Separate function so the Isolate.run closure captures only these sendable values.
Future<int> _spawn(String lib, String inPath, String outPath, double semitones, double tempo, int progress) =>
    Isolate.run(() => _renderSync(lib, inPath, outPath, semitones, tempo, progress));

typedef _RenderC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Float, Float, Pointer<Float>);
typedef _RenderDart = int Function(Pointer<Utf8>, Pointer<Utf8>, double, double, Pointer<Float>);

int _renderSync(String lib, String inPath, String outPath, double semitones, double tempo, int progress) {
  final render = DynamicLibrary.open(lib).lookupFunction<_RenderC, _RenderDart>('maestro_render');
  final a = inPath.toNativeUtf8(), b = outPath.toNativeUtf8();
  try {
    return render(a, b, semitones, tempo, Pointer.fromAddress(progress));
  } finally {
    malloc.free(a);
    malloc.free(b);
  }
}
