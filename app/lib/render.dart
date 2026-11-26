import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

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
  // A song deleted (or moved) before its job starts: fail here, before renderFile re-creates its folder.
  if (!source.existsSync()) return Future.error(RenderException(-2, source.path));
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
  final lib = renderLibraryPath, inPath = input.absolute.path, outPath = output.absolute.path;
  // Use the rounded tempo so the file content always matches its name.
  final t = (tempo * 100).round() / 100;
  return _shared(output, input.path, (p) => _spawn(lib, inPath, outPath, semitones.toDouble(), t, p), onProgress);
}

/// Bump when the guide mix output changes; the old file is then ignored.
const guideMixName = 'guide_v1.wav';

/// The editor's guide mix: instrumental + vocals summed (sounds like the record), cached at
/// `render/guide_v1.wav`. Null when either stem is missing. Re-made if a stem is newer than the cache
/// (Studio re-ran). Concurrent calls share one job.
Future<File?> ensureGuideMix(Song s) async {
  final a = File('${s.dir.path}/instrumental.flac'), b = File('${s.dir.path}/vocals.flac');
  if (!a.existsSync() || !b.existsSync()) return null;
  final out = File('${s.dir.path}/render/$guideMixName');
  final key = out.absolute.path.toLowerCase();
  if (!_jobs.containsKey(key) && out.existsSync()) {
    final made = out.lastModifiedSync();
    if (a.lastModifiedSync().isAfter(made) || b.lastModifiedSync().isAfter(made)) out.deleteSync();
  }
  return mixFile(a, b, out);
}

/// Sums [a] and [b] into [output] (see `maestro_mix`) unless [output] already exists.
Future<File> mixFile(File a, File b, File output) {
  final lib = renderLibraryPath, pa = a.absolute.path, pb = b.absolute.path, po = output.absolute.path;
  return _shared(output, a.path, (p) => Isolate.run(() => _mixSync(lib, pa, pb, po, p)), null);
}

/// One native job per output file: an existing output is reused, concurrent callers share the job.
Future<File> _shared(File output, String input, Future<int> Function(int progressAddress) native,
    void Function(double)? onProgress) {
  final key = output.absolute.path.toLowerCase(); // Windows paths are case-insensitive
  var job = _jobs[key];
  if (job == null) {
    if (output.existsSync()) return Future.value(output); // complete: renders land via rename
    final j = job = _jobs[key] = _Job();
    j.future = _run(j, input, output, native).whenComplete(() {
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

Future<File> _run(_Job job, String input, File output, Future<int> Function(int) native) async {
  await output.parent.create(recursive: true);
  final code = await native(job.progress.address);
  if (code != 0) throw RenderException(code, input);
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

typedef _MixC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Float>);
typedef _MixDart = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Float>);

int _mixSync(String lib, String aPath, String bPath, String outPath, int progress) {
  final mix = DynamicLibrary.open(lib).lookupFunction<_MixC, _MixDart>('maestro_mix');
  final a = aPath.toNativeUtf8(), b = bPath.toNativeUtf8(), o = outPath.toNativeUtf8();
  try {
    return mix(a, b, o, Pointer.fromAddress(progress));
  } finally {
    malloc.free(a);
    malloc.free(b);
    malloc.free(o);
  }
}

/// Background renders, strictly one at a time (each holds ~170 MB while it runs). New jobs wait while
/// stage mode is on ([pause]/[resume]); a job already running can't be stopped and finishes.
class RenderQueue {
  /// Output path (lower case) -> progress 0..1 of each render queued or running. A new map is set on
  /// every add/finish, so listeners hear jobs come and go; each progress is its own notifier.
  final jobs = ValueNotifier<Map<String, ValueNotifier<double>>>(const {});

  /// The renderer; tests swap in a fake.
  Future<File> Function(Song s, int shift, double tempo, void Function(double) onProgress) run =
      (s, shift, tempo, onProgress) => ensureRender(s, keyShift: shift, tempo: tempo, onProgress: onProgress);

  final _futures = <String, Future<File?>>{};
  Future<void> _tail = Future.value();
  Completer<void>? _paused;

  /// The cache key of [s] at [shift]/[tempo], or null when that needs no render.
  static String? keyOf(Song s, int shift, double tempo) {
    final name = renderFileName(shift, tempo);
    return name == null ? null : File('${s.dir.path}/render/$name').absolute.path.toLowerCase();
  }

  /// Queues a render of [s] at [shift]/[tempo] behind any others. Already on disk, already queued or
  /// no render needed: no new job. Completes with the file, or null if the render failed (never throws).
  Future<File?> add(Song s, int shift, double tempo) {
    final key = keyOf(s, shift, tempo);
    if (key == null) return Future.value(s.original);
    final queued = _futures[key];
    if (queued != null) return queued;
    final out = File('${s.dir.path}/render/${renderFileName(shift, tempo)}');
    if (out.existsSync()) return Future.value(out);
    final progress = ValueNotifier(0.0);
    jobs.value = {...jobs.value, key: progress};
    final f = _futures[key] = _tail.then((_) => _one(s, shift, tempo, progress)).whenComplete(() {
      _futures.remove(key);
      jobs.value = Map.of(jobs.value)..remove(key);
    });
    _tail = f;
    return f;
  }

  Future<File?> _one(Song s, int shift, double tempo, ValueNotifier<double> progress) async {
    while (_paused != null) {
      await _paused!.future;
    }
    try {
      return await run(s, shift, tempo, (v) => progress.value = v);
    } on Object catch (e) {
      debugPrint('Render failed: $e');
      return null;
    }
  }

  /// Stage mode is on: start no new render until [resume].
  void pause() => _paused ??= Completer<void>();

  void resume() {
    _paused?.complete();
    _paused = null;
  }
}

/// The app's one render queue (Library chip, Song details, pre-show check, stage pause).
/// Not final only so a widget test can give each test a fresh queue inside its own zone.
RenderQueue renderQueue = RenderQueue();
