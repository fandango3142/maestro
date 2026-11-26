import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'library.dart';

/// Bump when the render output changes (engine settings, normalisation); old cache files are then ignored.
/// Renders with cuts (WP-E) are version 2; renders without keep 1, so existing caches stay valid.
const renderEngineVersion = 1, cutRenderVersion = 2;

/// `k{shift}_t{tempo×100}_v1.wav` (SPEC §4), or `k{shift}_t{tempo×100}_c{hash8}_v2.wav` with [cuts]
/// (normalized). Null when shift 0 / tempo 1.00 / no cuts needs no render.
String? renderFileName(int shift, double tempo, [List<Cut> cuts = const []]) {
  final t = (tempo * 100).round();
  if (cuts.isEmpty) return shift == 0 && t == 100 ? null : 'k${shift}_t${t}_v$renderEngineVersion.wav';
  return 'k${shift}_t${t}_c${cutsHash(cuts)}_v$cutRenderVersion.wav';
}

/// 8 hex digits naming a cut list (FNV-1a over the cuts in whole milliseconds): new cuts, new file.
// ponytail: renders for old cuts (like old keys) stay in render/ until deleted by hand; add a sweep if disk use bites.
String cutsHash(List<Cut> cuts) {
  var h = 0x811c9dc5;
  for (final u in cuts.map((c) => '${(c.$1 * 1000).round()}-${(c.$2 * 1000).round()};').join().codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0xFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(8, '0');
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

/// The song's backing track at [keyShift]/[tempo] (default: the song's own settings), with its cuts.
/// Returns `instrumental.flac` when nothing needs rendering, else the cached or newly rendered WAV.
Future<File> ensureRender(Song s, {int? keyShift, double? tempo, void Function(double)? onProgress}) {
  final shift = keyShift ?? s.keyShift;
  final t = tempo ?? s.tempo;
  final cuts = s.cuts;
  final source = File('${s.dir.path}/instrumental.flac');
  final name = renderFileName(shift, t, cuts);
  if (name == null) return Future.value(source);
  // A song deleted (or moved) before its job starts: fail here, before renderFile re-creates its folder.
  if (!source.existsSync()) return Future.error(RenderException(-2, source.path));
  return renderFile(source, File('${s.dir.path}/render/$name'), shift, t, cuts: cuts, onProgress: onProgress);
}

class _Job {
  final Pointer<Float> progress = calloc<Float>();
  bool finished = false;
  late final Future<File> future;
}

final _jobs = <String, _Job>{};

/// Renders [input] (FLAC, or WAV by extension) to [output] unless [output] already exists, leaving out
/// [cuts] (normalized) with crossfaded joins. Concurrent calls for the same output share one render.
/// [onProgress] gets 0..1 about 6× a second.
Future<File> renderFile(File input, File output, int semitones, double tempo,
    {List<Cut> cuts = const [], void Function(double)? onProgress}) {
  final lib = renderLibraryPath, inPath = input.absolute.path, outPath = output.absolute.path;
  // Use the rounded tempo so the file content always matches its name.
  final t = (tempo * 100).round() / 100;
  final flat = [for (final c in cuts) ...[c.$1, c.$2]];
  return _shared(
      output, input.path, (p) => _spawn(lib, inPath, outPath, semitones.toDouble(), t, flat, p), onProgress);
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

/// Bump when the peaks file layout or bin rate changes.
const peaksName = 'peaks_v1.bin', peaksPerSecond = 50;

/// RMS per 1/[peaksPerSecond] s of the backing track and of the vocal stem (zeros without one).
typedef Peaks = ({Float32List backing, Float32List vocals});

/// The trimmer's waveform, cached at `render/peaks_v1.bin` (see `maestro_peaks`). Re-made if a stem is
/// newer than the cache (Studio re-ran). Throws [RenderException] if the backing track can't be read.
Future<Peaks> ensurePeaks(Song s) async {
  final a = s.original, b = File('${s.dir.path}/vocals.flac');
  final out = File('${s.dir.path}/render/$peaksName');
  final key = out.absolute.path.toLowerCase();
  if (!_jobs.containsKey(key) && out.existsSync()) {
    final made = out.lastModifiedSync();
    if (a.lastModifiedSync().isAfter(made) || (b.existsSync() && b.lastModifiedSync().isAfter(made))) {
      out.deleteSync();
    }
  }
  return peaksFile(a, b.existsSync() ? b : null, out);
}

/// Writes the RMS bins of [a] and [b] to [output] (see `maestro_peaks`) unless it exists, and reads them.
Future<Peaks> peaksFile(File a, File? b, File output) async {
  final lib = renderLibraryPath, pa = a.absolute.path, pb = b?.absolute.path, po = output.absolute.path;
  final f = await _shared(output, a.path, (_) => Isolate.run(() => _peaksSync(lib, pa, pb, po)), null);
  final bytes = ByteData.sublistView(await f.readAsBytes());
  final n = bytes.getUint32(0, Endian.host);
  final all = Float32List.sublistView(bytes, 4, 4 + 8 * n); // byte offsets; a fresh buffer is aligned
  return (backing: Float32List.sublistView(all, 0, n), vocals: Float32List.sublistView(all, n));
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
Future<int> _spawn(String lib, String inPath, String outPath, double semitones, double tempo, List<double> cuts,
        int progress) =>
    Isolate.run(() => _renderSync(lib, inPath, outPath, semitones, tempo, cuts, progress));

typedef _RenderC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Float, Float, Pointer<Double>, Int32, Pointer<Float>);
typedef _RenderDart = int Function(Pointer<Utf8>, Pointer<Utf8>, double, double, Pointer<Double>, int, Pointer<Float>);

int _renderSync(
    String lib, String inPath, String outPath, double semitones, double tempo, List<double> cuts, int progress) {
  final render = DynamicLibrary.open(lib).lookupFunction<_RenderC, _RenderDart>('maestro_render');
  final a = inPath.toNativeUtf8(), b = outPath.toNativeUtf8();
  final c = malloc<Double>(cuts.length + 1); // +1: never a zero-byte allocation
  c.asTypedList(cuts.length).setAll(0, cuts);
  try {
    return render(a, b, semitones, tempo, c, cuts.length ~/ 2, Pointer.fromAddress(progress));
  } finally {
    malloc.free(a);
    malloc.free(b);
    malloc.free(c);
  }
}

typedef _PeaksC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Float);
typedef _PeaksDart = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, double);

int _peaksSync(String lib, String aPath, String? bPath, String outPath) {
  final peaks = DynamicLibrary.open(lib).lookupFunction<_PeaksC, _PeaksDart>('maestro_peaks');
  final a = aPath.toNativeUtf8(), o = outPath.toNativeUtf8();
  final b = bPath?.toNativeUtf8() ?? nullptr;
  try {
    return peaks(a, b, o, peaksPerSecond.toDouble());
  } finally {
    malloc.free(a);
    malloc.free(o);
    if (b != nullptr) malloc.free(b);
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

  /// The cache key of [s] at [shift]/[tempo] with its current cuts, or null when that needs no render.
  static String? keyOf(Song s, int shift, double tempo) {
    final name = renderFileName(shift, tempo, s.cuts);
    return name == null ? null : File('${s.dir.path}/render/$name').absolute.path.toLowerCase();
  }

  /// Queues a render of [s] at [shift]/[tempo] behind any others. Already on disk, already queued or
  /// no render needed: no new job. Completes with the file, or null if the render failed (never throws).
  Future<File?> add(Song s, int shift, double tempo) {
    final key = keyOf(s, shift, tempo);
    if (key == null) return Future.value(s.original);
    final queued = _futures[key];
    if (queued != null) return queued;
    final out = File('${s.dir.path}/render/${renderFileName(shift, tempo, s.cuts)}');
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
