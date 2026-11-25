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
