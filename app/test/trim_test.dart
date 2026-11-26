import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/lrc.dart';
import 'package:karaoke_manager/preshow.dart';
import 'package:karaoke_manager/render.dart';
import 'package:karaoke_manager/setlist.dart';
import 'package:karaoke_manager/trim.dart';

import 'helpers.dart';

// WP-E: cut mapping, flags (accept / dismiss / Studio re-runs), fallback detector, cut render naming.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('trim_test'));
  tearDown(() => root.deleteSync(recursive: true));

  Song mk(Map<String, Object?> json, {List<String> renders = const []}) {
    final d = tempSong(root, 'a', {'key_shift': 0, 'tempo': 1.0, ...json}); // 100 s
    for (final r in renders) {
      File('${d.path}/render/$r')
        ..createSync(recursive: true)
        ..writeAsStringSync('wav');
    }
    return Song.load(d);
  }

  Duration secs(num s) => Duration(microseconds: (s * 1e6).round());
  Map<String, dynamic> onDisk() =>
      jsonDecode(File('${root.path}/library/a/song.json').readAsStringSync()) as Map<String, dynamic>;

  group('cut mapping (toOriginal / fromOriginal)', () {
    // (cuts, tempo, [(playback s, original s)]): round trips both ways.
    final cases = <(List<List<double>>, double, List<(double, double)>)>[
      ([], 1.0, [(0, 0), (42, 42), (99, 99)]),
      ([], 1.25, [(8, 10), (40, 50)]),
      ([[10, 20]], 1.0, [(0, 0), (9.5, 9.5), (10, 20), (15, 25), (80, 90)]),
      ([[10, 20]], 0.8, [(12.5, 20), (25, 30)]), // 12.5 × 0.8 = 10 s cut audio = the join
      ([[0, 5], [30, 35.5], [90, 100]], 1.0, [(0, 5), (24, 29), (25, 35.5), (54.5, 65), (79.5, 100)]),
      ([[0, 5], [30, 35.5], [90, 100]], 1.2, [(20, 29), (25, 40.5)]),
    ];
    for (final (cuts, tempo, points) in cases) {
      test('${cuts.length} cuts at ${tempo}x', () {
        final s = mk({'cuts': cuts, 'tempo': tempo});
        for (final (play, orig) in points) {
          expect(toOriginal(secs(play), s).inMicroseconds / 1e6, closeTo(orig, 1e-6), reason: 'play $play');
          expect(fromOriginal(secs(orig), s).inMicroseconds / 1e6, closeTo(play, 1e-6), reason: 'orig $orig');
        }
      });
    }

    test('a lyric inside a cut is heard at the join; out-of-order, overlapping and stray cuts are cleaned', () {
      final s = mk({
        'cuts': [[30, 35], [10, 20], [15, 25], [25, 26], [-3, 1], [50, 50], 'junk', [1], [95, 400]],
      });
      expect(s.cuts, [(0.0, 1.0), (10.0, 26.0), (30.0, 35.0), (95.0, 100.0)]); // touching ones merge, end at the track
      expect(fromOriginal(secs(22), s), fromOriginal(secs(10), s));
      expect(s.playedDuration, secs(100 - 1 - 16 - 5 - 5));
      expect(mk({'cuts': 'bad'}).cuts, isEmpty);
    });
  });

  test('accepting a flag shortens the played length by exactly cut / tempo (exit criterion)', () async {
    final s = mk({
      'tempo': 0.9,
      'cut_suggestions': [
        {'id': 'speech-40.0-52.5', 'start': 40.0, 'end': 52.5, 'kind': 'speech', 'confidence': 0.91},
      ],
    });
    final before = s.playedDuration!;
    final f = pendingFlags(s.suggestions!, s.cuts, s.dismissed).single;
    await saveSongFields(s, {'cuts': [[f.start, f.end]]}); // what the trimmer's Accept writes
    expect((before - s.playedDuration!).inMicroseconds, closeTo(12.5 / 0.9 * 1e6, 1));
    expect(pendingFlags(s.suggestions!, s.cuts, s.dismissed), isEmpty); // accepted = no longer pending
    expect(needsTrimReview(s), isFalse);
  });

  test('dismissed flags stay dismissed after Studio rewrites cut_suggestions (exit criterion)', () async {
    final s = mk({
      'cut_suggestions': [
        {'id': 'speech-0.0-6.5', 'start': 0.0, 'end': 6.5, 'kind': 'speech', 'confidence': 0.91},
        {'id': 'silence-97.0-100.0', 'start': 97.0, 'end': 100.0, 'kind': 'silence', 'confidence': 0.99},
      ],
    });
    expect(needsTrimReview(s), isTrue);
    await saveSongFields(s, {
      'dismissed_suggestions': [{'kind': 'speech', 'start': 0.0, 'end': 6.5}],
    });
    expect([for (final f in pendingFlags(s.suggestions!, s.cuts, s.dismissed)) f.kind], ['silence']);

    // Studio re-runs: boundaries shift by a rounding step, ids change, the file is rewritten from scratch
    // apart from the app's keys (Studio patches; it keeps keys it doesn't own).
    final json = onDisk()
      ..['cut_suggestions'] = [
        {'id': 'speech-0.5-6.0', 'start': 0.5, 'end': 6.0, 'kind': 'speech', 'confidence': 0.88}, // same flag
        {'id': 'silence-2.0-5.0', 'start': 2.0, 'end': 5.0, 'kind': 'silence', 'confidence': 0.7}, // other kind
        {'id': 'speech-5.0-30.0', 'start': 5.0, 'end': 30.0, 'kind': 'speech', 'confidence': 0.8}, // < 50 % overlap
      ];
    File('${root.path}/library/a/song.json').writeAsStringSync(jsonEncode(json));
    final again = Song.load(Directory('${root.path}/library/a'));
    expect([for (final f in pendingFlags(again.suggestions!, again.cuts, again.dismissed)) (f.kind, f.start)],
        [('silence', 2.0), ('speech', 5.0)]);
    expect(again.json['dismissed_suggestions'], hasLength(1));
  });

  test('overlapsHalf: at least half of the shorter span', () {
    expect(overlapsHalf(0, 10, 5, 10), isTrue); // all of the shorter
    expect(overlapsHalf(0, 10, 5, 20), isTrue); // exactly half of the shorter
    expect(overlapsHalf(0, 10, 6, 20), isFalse);
    expect(overlapsHalf(0, 10, 10, 20), isFalse); // touching
    expect(overlapsHalf(0, 100, 40, 41), isTrue); // a small flag inside a big dismissal
  });

  test('no Studio scan: no suggestions (fallback applies); Studio found nothing: an empty list', () {
    expect(mk({}).suggestions, isNull);
    expect(mk({'cut_suggestions': []}).suggestions, isEmpty);
    expect(mk({'cut_suggestions': [{'kind': 'speech', 'start': 5, 'end': 1}, 7]}).suggestions, isEmpty);
  });

  group('fallback flags (synthetic RMS at 50 bins/s)', () {
    const r = peaksPerSecond;
    Float32List level(int seconds, double Function(double t) f) =>
        Float32List.fromList(List.generate(seconds * r, (i) => f(i / r)));
    LyricLine line(double t, String text) => LyricLine(secs(t), text);

    test('silent lead-in and tail >= 1.5 s, shorter ones not', () {
      final backing = level(60, (t) => t < 3 || t >= 58 ? 0.001 : 0.2);
      final vocals = level(60, (_) => 0.0);
      expect(fallbackFlags(backing, vocals, const []).map((f) => (f.kind, f.start, f.end)),
          [('silence', 0.0, 3.0), ('silence', 58.0, 60.0)]);
      final short = level(60, (t) => t < 1 || t >= 59 ? 0.001 : 0.2);
      expect(fallbackFlags(short, vocals, const []), isEmpty);
    });

    test('vocals outside every synced line >= 2 s are possible speech; sung lines and short bits are not', () {
      final backing = level(60, (_) => 0.2);
      // Talking 0-5 s, singing 10-30 s (synced), an ad-lib 40-41 s, talking again 50-54 s with a 0.3 s pause.
      final vocals = level(60, (t) {
        if (t < 5 || (t >= 10 && t < 30) || (t >= 40 && t < 41)) return 0.1;
        if (t >= 50 && t < 54 && (t < 52 || t >= 52.3)) return 0.1;
        return 0.0005; // stem bleed
      });
      final lyrics = [for (var t = 10.0; t < 30; t += 4) line(t, 'sung $t'), line(30, '')]; // break marker at 30
      final flags = fallbackFlags(backing, vocals, lyrics);
      expect(flags.map((f) => (f.kind, f.start, f.end, f.confidence)),
          [('speech', 0.0, 5.0, null), ('speech', 50.0, 54.0, null)]);
      expect(fallbackFlags(backing, vocals, [LyricLine(null, 'untimed')]), isEmpty); // no sync: no guesses
    });
  });

  group('render naming with cuts', () {
    test('no cuts keeps v1 names (existing caches stay valid); cuts add a hash and v2, even at 0 / 1.00', () {
      expect(renderFileName(0, 1.0), isNull);
      expect(renderFileName(2, 1.0, const []), 'k2_t100_v1.wav');
      final a = renderFileName(0, 1.0, const [(0.0, 6.5)])!;
      expect(a, matches(RegExp(r'^k0_t100_c[0-9a-f]{8}_v2\.wav$')));
      expect(renderFileName(0, 1.0, const [(0.0, 6.5)]), a); // stable
      expect(renderFileName(0, 1.0, const [(0.0, 6.6)]), isNot(a)); // new cuts, new file
      expect(renderFileName(0, 1.0, const [(0.0, 6.5), (90.0, 100.0)]), isNot(a));
    });

    test('cuts changed: the old render no longer plays; fallback to the original has no cuts', () {
      final s = mk({'cuts': [[0, 10]]});
      final first = renderFileName(0, 1.0, s.cuts)!;
      File('${s.dir.path}/render/$first')
        ..createSync(recursive: true)
        ..writeAsStringSync('wav');
      final p = playbackFor(s, 0);
      expect((p.file.uri.pathSegments.last, p.fallback), (first, false));
      expect(p.cuts, [(0.0, 10.0)]);
      expect(toOriginal(secs(5), s, playing: p), secs(15));
      expect(s.playedDurationAt(p.tempo, cuts: p.cuts), secs(90));

      s.json['cuts'] = [[0, 12]]; // Ryan moved a handle
      final q = playbackFor(s, 0);
      expect((q.file.uri.pathSegments.last, q.fallback), ('instrumental.flac', true));
      expect(q.cuts, isEmpty);
      expect(toOriginal(secs(5), s, playing: q), secs(5)); // the original plays: no cut mapping
      expect(s.playedDurationAt(q.tempo, cuts: q.cuts), secs(100)); // and the full length
      expect(RenderQueue.keyOf(s, 0, 1.0), endsWith(renderFileName(0, 1.0, s.cuts)!.toLowerCase()));
    });

    test('pre-show check asks for a cut render at key 0 / tempo 1.00', () {
      final s = mk({'cuts': [[0, 10]]});
      expect(missingRenders([SetItem.song('a')], {'a': s}).map((n) => n.shift), [0]);
      File('${s.dir.path}/render/${renderFileName(0, 1.0, s.cuts)}')
        ..createSync(recursive: true)
        ..writeAsStringSync('wav');
      expect(missingRenders([SetItem.song('a')], {'a': s}), isEmpty);
    });
  });

  test('linesInCuts counts sung lines starting inside a cut', () {
    final lyrics = [LyricLine(secs(5), 'a'), LyricLine(secs(12), 'b'), LyricLine(secs(14), ''), LyricLine(null, 'c')];
    expect(linesInCuts(lyrics, const [(10.0, 20.0)]), 1);
    expect(linesInCuts(lyrics, const [(0.0, 5.0)]), 0); // ends at 5: the line at 5 is heard
    expect(linesInCuts(lyrics, const []), 0);
  });
}
