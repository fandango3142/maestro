@TestOn('windows')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/render.dart';

// Synthetic audio only (sine waves / noise generated here). The native lib is built with CMake
// in setUpAll (incremental, a few seconds once built); see native/README.md.

void writeWav(File f, List<Float32List> ch, int rate) {
  final frames = ch[0].length, n = ch.length, dataLen = frames * n * 2;
  final b = ByteData(44 + dataLen);
  void tag(int o, String s) => s.codeUnits.asMap().forEach((i, c) => b.setUint8(o + i, c));
  tag(0, 'RIFF');
  b.setUint32(4, 36 + dataLen, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, n, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * n * 2, Endian.little);
  b.setUint16(32, n * 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, dataLen, Endian.little);
  var o = 44;
  for (var i = 0; i < frames; i++) {
    for (var c = 0; c < n; c++) {
      b.setInt16(o, (ch[c][i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
      o += 2;
    }
  }
  f.writeAsBytesSync(b.buffer.asUint8List());
}

({int rate, List<Float32List> ch}) readWav(File f) {
  final b = ByteData.sublistView(f.readAsBytesSync());
  String tag(int o) => String.fromCharCodes(List.generate(4, (i) => b.getUint8(o + i)));
  expect(tag(0), 'RIFF');
  var o = 12, n = 0, rate = 0;
  while (o + 8 <= b.lengthInBytes) {
    final id = tag(o), len = b.getUint32(o + 4, Endian.little);
    if (id == 'fmt ') {
      expect(b.getUint16(o + 8, Endian.little), 1, reason: 'PCM');
      n = b.getUint16(o + 10, Endian.little);
      rate = b.getUint32(o + 12, Endian.little);
      expect(b.getUint16(o + 22, Endian.little), 16, reason: '16-bit');
    } else if (id == 'data') {
      final frames = len ~/ (2 * n);
      final ch = List.generate(n, (_) => Float32List(frames));
      for (var i = 0; i < frames; i++) {
        for (var c = 0; c < n; c++) {
          ch[c][i] = b.getInt16(o + 8 + (i * n + c) * 2, Endian.little) / 32767;
        }
      }
      return (rate: rate, ch: ch);
    }
    o += 8 + len + (len & 1);
  }
  throw StateError('no data chunk');
}

Float32List sine(int frames, int rate, double hz, double amp, {int startAt = 0}) => Float32List.fromList(
    List.generate(frames, (i) => i < startAt ? 0.0 : amp * sin(2 * pi * hz * (i - startAt) / rate)));

/// Frequency from rising zero crossings over the middle of the signal (skips edge effects).
double frequency(Float32List x, int rate) {
  final a = x.length ~/ 4, z = 3 * x.length ~/ 4;
  var first = -1, last = -1, count = 0;
  for (var i = a + 1; i < z; i++) {
    if (x[i - 1] < 0 && x[i] >= 0) {
      if (first < 0) {
        first = i;
      } else {
        count++;
      }
      last = i;
    }
  }
  return count * rate / (last - first);
}

int onset(Float32List x, double threshold) => x.indexWhere((v) => v.abs() > threshold);

double peak(List<Float32List> ch) => ch.expand((c) => c).fold(0.0, (m, v) => max(m, v.abs()));

String? _cmake() {
  final where = Process.runSync('where', ['cmake']);
  if (where.exitCode == 0) return (where.stdout as String).split('\n').first.trim();
  const vswhere = r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe';
  if (!File(vswhere).existsSync()) return null;
  final r = Process.runSync(vswhere, ['-latest', '-products', '*', '-find', r'**\CMake\bin\cmake.exe']);
  final path = (r.stdout as String).split('\n').first.trim();
  return path.isEmpty ? null : path;
}

const _minute = Duration(minutes: 1);

void main() {
  late Directory tmp;

  setUpAll(() {
    final cmake = _cmake();
    if (cmake == null) fail('CMake not found (install VS Build Tools with C++). See native/README.md.');
    final native = Directory('native').absolute.path;
    if (!File('$native/build/CMakeCache.txt').existsSync()) {
      final cfg = Process.runSync(cmake, ['-S', '$native/maestro_render', '-B', '$native/build', '-A', 'x64']);
      if (cfg.exitCode != 0) fail('cmake configure failed:\n${cfg.stdout}\n${cfg.stderr}');
    }
    final build = Process.runSync(cmake, ['--build', '$native/build', '--config', 'Release']);
    if (build.exitCode != 0) fail('cmake build failed:\n${build.stdout}\n${build.stderr}');
    renderLibraryPath = '$native/build/Release/maestro_render.dll';
  });

  setUp(() => tmp = Directory.systemTemp.createTempSync('maestro_render_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File input(List<Float32List> ch, int rate) {
    final f = File('${tmp.path}/in.wav');
    writeWav(f, ch, rate);
    return f;
  }

  test('renderFileName', () {
    expect(renderFileName(0, 1.0), isNull);
    expect(renderFileName(0, 1.004), isNull);
    expect(renderFileName(2, 1.0), 'k2_t100_v1.wav');
    expect(renderFileName(-1, 0.85), 'k-1_t85_v1.wav');
    expect(renderFileName(0, 1.15), 'k0_t115_v1.wav');
  });

  test('+12 semitones doubles 440 Hz to 880 Hz (mono)', () async {
    final out = await renderFile(input([sine(5 * 44100, 44100, 440, 0.5)], 44100), File('${tmp.path}/o.wav'), 12, 1.0);
    final w = readWav(out);
    expect(w.ch.length, 1);
    final hz = frequency(w.ch[0], w.rate);
    expect(hz, closeTo(880, 880 * 0.02), reason: 'measured $hz Hz');
  });

  test('tempo 1.25 shortens by 1.25 and keeps lyric alignment (pos × tempo)', () async {
    const rate = 44100;
    final src = sine(5 * rate, rate, 440, 0.5, startAt: rate); // silent 1 s, then tone
    final out = await renderFile(input([src, src], rate), File('${tmp.path}/o.wav'), 0, 1.25);
    final w = readWav(out);
    expect(w.ch.length, 2);
    expect(w.ch[0].length, closeTo(5 * rate / 1.25, 5 * rate / 1.25 * 0.01));
    final ms = (onset(w.ch[0], 0.25) * 1.25 - onset(src, 0.25)) / rate * 1000;
    expect(ms.abs(), lessThan(15), reason: 'onset offset $ms ms in original time');
  });

  test('0 semitones / tempo 1.0: same length, same rate, same channels, 0 offset', () async {
    const rate = 48000;
    final src = sine(5 * rate, rate, 440, 0.5, startAt: rate);
    final out = await renderFile(input([src, src], rate), File('${tmp.path}/o.wav'), 0, 1.0);
    final w = readWav(out);
    expect(w.rate, rate);
    expect(w.ch.length, 2);
    expect((w.ch[0].length - src.length).abs(), lessThanOrEqualTo(1));
    final ms = (onset(w.ch[0], 0.25) - onset(src, 0.25)) / rate * 1000;
    expect(ms.abs(), lessThan(15), reason: 'onset offset $ms ms');
  });

  test('full-scale input shifted +3 peaks at most 0.98', () async {
    final s = sine(5 * 44100, 44100, 440, 1.0);
    final out = await renderFile(input([s, s], 44100), File('${tmp.path}/o.wav'), 3, 1.0);
    expect(peak(readWav(out).ch), lessThanOrEqualTo(0.98 + 1 / 32767));
  });

  test('quiet input is not boosted (and non-ASCII paths work)', () async {
    final s = sine(5 * 44100, 44100, 440, 0.1);
    final out = await renderFile(input([s], 44100), File('${tmp.path}/गाना/o.wav'), 2, 1.0);
    expect(peak(readWav(out).ch), lessThan(0.2));
  });

  test('concurrent calls share one job; a finished render is reused', () async {
    final src = input([sine(3 * 44100, 44100, 440, 0.5)], 44100);
    final o = File('${tmp.path}/render/k1_t100_v1.wav');
    final a = renderFile(src, o, 1, 1.0);
    final b = renderFile(src, o, 1, 1.0);
    expect(identical(a, b), isTrue);
    await renderFile(src, o, 1, 1.0, onProgress: (_) {});
    await a;
    expect(File('${o.path}.tmp').existsSync(), isFalse);
    final mtime = o.lastModifiedSync();
    await renderFile(src, o, 1, 1.0);
    expect(o.lastModifiedSync(), mtime);
  });

  test('errors: missing input, bad args; no .tmp left, retry allowed', () async {
    final o = File('${tmp.path}/o.wav');
    await expectLater(renderFile(File('${tmp.path}/nope.flac'), o, 2, 1.0),
        throwsA(isA<RenderException>().having((e) => e.code, 'code', -2)));
    await expectLater(renderFile(File('${tmp.path}/nope.wav'), o, 2, 1.0),
        throwsA(isA<RenderException>().having((e) => e.code, 'code', -2)));
    final src = input([sine(44100, 44100, 440, 0.5)], 44100);
    await expectLater(
        renderFile(src, o, 2, 0.0), throwsA(isA<RenderException>().having((e) => e.code, 'code', -1)));
    expect(o.existsSync() || File('${o.path}.tmp').existsSync(), isFalse);
    expect(readWav(await renderFile(src, o, 2, 1.0)).ch[0].length, 44100);
  });

  test('ensureRender: shift 0 / tempo 1.0 plays instrumental.flac, no render', () async {
    final song = Song(tmp, {'id': 'x', 'key_shift': 0, 'tempo': 1.0}, const [], File('${tmp.path}/l.lrc'));
    expect((await ensureRender(song)).path, '${tmp.path}/instrumental.flac');
    expect(Directory('${tmp.path}/render').existsSync(), isFalse);
  });

  File wav(String name, List<Float32List> ch, int rate) {
    final f = File('${tmp.path}/$name');
    writeWav(f, ch, rate);
    return f;
  }

  Float32List samples(List<double> v) => Float32List.fromList(v);

  test('mix: sample-exact sum from 0, as long as the longer input, shorter padded with silence', () async {
    final a = wav('a.wav', [samples([0.1, 0.2, -0.3, 0.4, 0.5]), samples([0.0, 0.1, 0.1, 0.1, 0.1])], 44100);
    final b = wav('b.wav', [samples([0.2, -0.1, 0.1]), samples([0.3, 0.3, 0.3])], 44100);
    final w = readWav(await mixFile(b, a, File('${tmp.path}/render/m.wav'))); // shorter first: either order
    expect(w.rate, 44100);
    expect(w.ch.length, 2);
    expect(w.ch[0].length, 5);
    const q = 2 / 32767; // two 16-bit roundings
    expect(w.ch[0], pairwiseCompare([0.3, 0.1, -0.2, 0.4, 0.5], (double x, double y) => (x - y).abs() < q, '≈'));
    expect(w.ch[1], pairwiseCompare([0.3, 0.4, 0.4, 0.1, 0.1], (double x, double y) => (x - y).abs() < q, '≈'));
  });

  test('mix: clipping sum is normalised to ≤ 0.98, a quiet sum is not boosted', () async {
    final loud = sine(44100, 44100, 440, 0.9);
    final w = readWav(await mixFile(wav('a.wav', [loud], 44100), wav('b.wav', [loud], 44100), File('${tmp.path}/l.wav')));
    expect(peak(w.ch), lessThanOrEqualTo(0.98 + 1 / 32767));
    expect(peak(w.ch), greaterThan(0.97));
    final quiet = sine(44100, 44100, 440, 0.1);
    final w2 =
        readWav(await mixFile(wav('c.wav', [quiet], 44100), wav('d.wav', [quiet], 44100), File('${tmp.path}/q.wav')));
    expect(peak(w2.ch), closeTo(0.2, 0.002));
  });

  test('mix: different sample rates are refused', () async {
    final s = sine(4410, 44100, 440, 0.1);
    await expectLater(mixFile(wav('a.wav', [s], 44100), wav('b.wav', [s], 48000), File('${tmp.path}/x.wav')),
        throwsA(isA<RenderException>().having((e) => e.code, 'code', -2)));
  });

  test('ensureGuideMix: null without vocals; reuses a fresh cache; re-makes a stale one', () async {
    final song = Song(tmp, {'id': 'x'}, const [], File('${tmp.path}/l.lrc'));
    expect(await ensureGuideMix(song), isNull);
    // No FLAC encoder here, so the stems are WAV bytes under FLAC names: any real mix attempt fails
    // with an input error. That makes "reused the cache" (no attempt) and "re-made it" (attempt) visible.
    final stamp = DateTime(2026, 1, 1);
    for (final n in ['instrumental.flac', 'vocals.flac']) {
      wav(n, [sine(4410, 44100, 440, 0.1)], 44100).setLastModifiedSync(stamp);
    }
    final cached = wav('render_guide.wav', [sine(10, 44100, 440, 0.1)], 44100);
    Directory('${tmp.path}/render').createSync();
    final guide = cached.renameSync('${tmp.path}/render/guide_v1.wav')..setLastModifiedSync(stamp.add(_minute));
    expect((await ensureGuideMix(song))!.path, guide.path);
    File('${tmp.path}/vocals.flac').setLastModifiedSync(stamp.add(_minute * 2)); // Studio re-ran
    await expectLater(ensureGuideMix(song), throwsA(isA<RenderException>().having((e) => e.code, 'code', -2)));
    expect(guide.existsSync() || File('${guide.path}.tmp').existsSync(), isFalse);
  });

  // WP-E: cuts with crossfaded joins, and the trimmer's waveform data.
  double maxStep(Float32List x) {
    var m = 0.0;
    for (var i = 1; i < x.length; i++) {
      m = max(m, (x[i] - x[i - 1]).abs());
    }
    return m;
  }

  test('cut join is crossfaded: no sample jump; audio away from the join is untouched; exact length', () async {
    const rate = 44100, hz = 440.0;
    final src = sine(4 * rate, rate, hz, 0.5);
    const a = 1.0 + 1 / (4 * hz), b = 2.0; // from a peak (+0.5) to a zero crossing: a hard cut jumps 0.5
    final fa = (a * rate).round(), fb = b * rate ~/ 1;
    final hardJump = (src[fa - 1] - src[fb]).abs();
    final out = await renderFile(input([src], rate), File('${tmp.path}/o.wav'), 0, 1.0, cuts: const [(a, b)]);
    final w = readWav(out).ch[0];
    expect(w.length, src.length - (fb - fa));
    final step = maxStep(w), natural = maxStep(src);
    // ignore: avoid_print
    print('cut join: max sample step ${step.toStringAsFixed(4)} (sine alone ${natural.toStringAsFixed(4)}, '
        'hard cut ${hardJump.toStringAsFixed(4)})');
    expect(hardJump, greaterThan(0.4)); // the test would catch a missing crossfade
    expect(step, lessThan(natural + 0.01));
    const q = 1.5 / 32767, h = rate * 25 ~/ 1000;
    for (final i in [0, fa - h - 1]) {
      expect(w[i], closeTo(src[i], q));
    }
    for (final k in [h + 1, 10000]) {
      expect(w[fa + k], closeTo(src[fb + k], q));
    }
  });

  test('cuts + tempo: length is (original − cuts) / tempo and a tone lands where fromOriginal says', () async {
    const rate = 44100, tempo = 1.25;
    final src = sine(6 * rate, rate, 440, 0.5, startAt: 3 * rate); // silent 3 s, then tone
    final out = await renderFile(input([src, src], rate), File('${tmp.path}/o.wav'), 2, tempo,
        cuts: const [(0.5, 1.5), (5.0, 5.5)]);
    final w = readWav(out);
    expect(w.ch[0].length, ((6 * rate - 1.5 * rate) / tempo).round());
    final expected = (3.0 - 1.0) / tempo; // 3 s original, 1 s cut before it
    final ms = (onset(w.ch[0], 0.25) / rate - expected) * 1000;
    expect(ms.abs(), lessThan(15), reason: 'onset offset $ms ms');
  });

  test('cut at the start fades in, cut at the end fades out; cutting everything or bad cuts fail', () async {
    const rate = 44100;
    final src = sine(3 * rate, rate, 440, 0.5);
    final w = readWav(await renderFile(input([src], rate), File('${tmp.path}/o.wav'), 0, 1.0,
            cuts: const [(0.0, 1.0 + 1 / 1760), (2.5, 3.0)]))
        .ch[0];
    expect(w.first.abs(), lessThan(0.05));
    expect(w.last.abs(), lessThan(0.05));
    expect(maxStep(w), lessThan(maxStep(src) + 0.01));
    final f = input([src], rate);
    await expectLater(renderFile(f, File('${tmp.path}/all.wav'), 0, 1.0, cuts: const [(0.0, 3.0)]),
        throwsA(isA<RenderException>().having((e) => e.code, 'code', -2)));
    await expectLater(renderFile(f, File('${tmp.path}/bad.wav'), 0, 1.0, cuts: const [(2.0, 2.5), (1.0, 1.5)]),
        throwsA(isA<RenderException>().having((e) => e.code, 'code', -1)));
  });

  test('peaks: RMS per 1/50 s of backing and vocals, vocals padded; cached file reused', () async {
    const rate = 44100;
    final tone = Float32List.fromList([...sine(rate, rate, 441, 0.5), ...Float32List(rate)]); // 1 s tone, 1 s quiet
    final a = wav('a.wav', [tone, tone], rate), v = wav('v.wav', [Float32List.fromList(List.filled(rate ~/ 2, 0.25))], rate);
    final out = File('${tmp.path}/render/peaks_v1.bin');
    final p = await peaksFile(a, v, out);
    expect(p.backing.length, 100);
    expect(p.vocals.length, 100);
    expect(p.backing[10], closeTo(0.5 / sqrt2, 0.01));
    expect(p.backing[80], lessThan(0.001));
    expect(p.vocals[5], closeTo(0.25, 0.001));
    expect(p.vocals[60], 0); // past the end of the shorter stem
    final mtime = out.lastModifiedSync();
    expect((await peaksFile(a, null, out)).backing.length, 100);
    expect(out.lastModifiedSync(), mtime);
    final noVocals = await peaksFile(a, null, File('${tmp.path}/p2.bin'));
    expect(noVocals.vocals.every((x) => x == 0), isTrue);
  });

  test('timing: 4-minute stereo 44.1 kHz render', () async {
    const rate = 44100, frames = 240 * rate;
    final r = Random(1);
    final ch = List.generate(2, (_) => Float32List.fromList(List.generate(frames, (_) => r.nextDouble() - 0.5)));
    final src = input(ch, rate);
    final seen = <double>[];
    final sw = Stopwatch()..start();
    final out = await renderFile(src, File('${tmp.path}/o.wav'), 2, 1.0, onProgress: seen.add);
    sw.stop();
    // ignore: avoid_print
    print('4-min stereo render (+2 semitones, tempo 1.0): ${sw.elapsedMilliseconds} ms');
    expect(readWav(out).ch[0].length, frames);
    expect(sw.elapsed.inSeconds, lessThan(60));
    expect(seen, isNotEmpty);
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
