import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/preshow.dart';
import 'package:karaoke_manager/render.dart';
import 'package:karaoke_manager/setlist.dart';

import 'helpers.dart';

// WP-C2: which file plays, the tempo lyrics map with, what the pre-show check renders, the queue.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('key_tempo_test'));
  tearDown(() => root.deleteSync(recursive: true));

  Song mk(String id, {int shift = 0, double tempo = 1.0, bool audio = true, List<String> renders = const []}) {
    final d = Directory('${root.path}/library/$id')..createSync(recursive: true);
    File('${d.path}/song.json').writeAsStringSync(jsonEncode({'id': id, 'key_shift': shift, 'tempo': tempo}));
    if (audio) File('${d.path}/instrumental.flac').writeAsBytesSync(flacHeader(44100, 44100 * 100)); // 100 s
    for (final r in renders) {
      File('${d.path}/render/$r')
        ..createSync(recursive: true)
        ..writeAsStringSync('wav');
    }
    return Song.load(d);
  }

  String name(File f) => f.uri.pathSegments.last;

  group('playbackFor / Song.audio', () {
    test('render on disk: plays it at the song tempo; the gig override picks its own file', () {
      final s = mk('a', shift: 2, tempo: 0.85, renders: ['k2_t85_v1.wav', 'k-1_t85_v1.wav']);
      expect(name(s.audio), 'k2_t85_v1.wav');
      final own = playbackFor(s, s.keyShift);
      expect((name(own.file), own.tempo, own.shift, own.fallback), ('k2_t85_v1.wav', 0.85, 2, false));
      final gig = playbackFor(s, -1); // setlist key_shift -1 overrides the song's +2
      expect((name(gig.file), gig.tempo, gig.shift), ('k-1_t85_v1.wav', 0.85, -1));
    });

    test('render missing: the original at tempo 1.0, flagged as a fallback', () {
      final s = mk('a', shift: 2, tempo: 1.15);
      expect(name(s.audio), 'instrumental.flac');
      final p = playbackFor(s, 2);
      expect((name(p.file), p.tempo, p.shift, p.fallback), ('instrumental.flac', 1.0, 0, true));
      final gig = playbackFor(mk('b', shift: 0, tempo: 1.0, renders: ['k0_t115_v1.wav']), 3);
      expect(gig.fallback, isTrue); // a render for other settings doesn't count
    });

    test('key 0 / tempo 1.00: the original, no render needed', () {
      final p = playbackFor(mk('a'), 0);
      expect((name(p.file), p.tempo, p.fallback), ('instrumental.flac', 1.0, false));
    });
  });

  group('lyric timing (toOriginal) at tempo ≠ 1', () {
    // A lyric at 60 s of the original plays at 60 / tempo in the render; mapping back must give 60 s.
    for (final tempo in [0.85, 1.15]) {
      test('rendered at ${tempo}x: the lyric lands on its line', () {
        final s = mk('a', tempo: tempo, renders: ['k0_t${(tempo * 100).round()}_v1.wav']);
        final p = playbackFor(s, 0);
        final heard = Duration(microseconds: (60e6 / tempo).round());
        expect(toOriginal(heard, s, playing: p).inMilliseconds, closeTo(60000, 1));
        expect(s.playedDurationAt(p.tempo)!.inMilliseconds, closeTo(100000 / tempo, 1));
      });

      test('render missing at ${tempo}x ("Launch anyway"): the original plays, mapping is 1:1', () {
        final s = mk('a', tempo: tempo);
        final p = playbackFor(s, 0);
        expect(p.tempo, 1.0);
        expect(toOriginal(const Duration(seconds: 60), s, playing: p), const Duration(seconds: 60));
        expect(s.playedDurationAt(p.tempo), const Duration(seconds: 100)); // set times use the real length
      });
    }
  });

  test('missingRenders: only songs that will play, gig override first, one per file, cached skipped', () {
    final songs = {
      for (final s in [
        mk('own', shift: 1, tempo: 0.95), // needs k1_t95
        mk('gig', shift: 1, tempo: 1.0), // gig override -2 needs k-2_t100
        mk('done', shift: 2, tempo: 1.0, renders: ['k2_t100_v1.wav']), // cached
        mk('plain'), // 0 / 1.00: nothing to render
        mk('silent', shift: 3, audio: false), // not playable (no audio): skipped
      ])
        s.id: s,
    };
    final items = [
      SetItem.song('own'),
      SetItem.pause(),
      SetItem({'id': 'gig', 'key_shift': -2}),
      SetItem.song('done'),
      SetItem.song('plain'),
      SetItem.song('silent'),
      SetItem.song('gone'), // missing from the library
      SetItem.song('own'), // twice in the set: one render
      SetItem({'id': 'own', 'key_shift': 0}), // same song, gig key 0 at 0.95x: a second file
    ];
    final m = missingRenders(items, songs);
    expect([for (final n in m) (n.song.id, n.shift)], [('own', 1), ('gig', -2), ('own', 0)]);
    expect(m.map((n) => renderLabel(n.song, n.shift)), ['+1 st · 0.95x', '-2 st · 1.00x', '0 st · 0.95x']);
  });

  group('RenderQueue', () {
    late RenderQueue q;
    late List<(String, int, double)> started;
    late Map<String, Completer<void>> gates;
    late Map<String, void Function(double)> progress;

    setUp(() {
      q = RenderQueue();
      started = [];
      gates = {};
      progress = {};
      q.run = (s, shift, tempo, onProgress) async {
        started.add((s.id, shift, tempo));
        progress[s.id] = onProgress;
        await (gates[s.id] = Completer<void>()).future;
        final out = File('${s.dir.path}/render/${renderFileName(shift, tempo)}')..createSync(recursive: true);
        return out..writeAsStringSync('wav');
      };
    });

    test('one at a time, in order; duplicates share a job; progress and the jobs map follow', () async {
      final a = mk('a', shift: 1), b = mk('b', shift: 2);
      final fa = q.add(a, 1, 1.0), fb = q.add(b, 2, 1.0);
      expect(identical(q.add(a, 1, 1.0), fa), isTrue); // Save pressed twice: no second job
      expect(q.jobs.value.length, 2);
      await pumpEventQueue();
      expect(started, [('a', 1, 1.0)]); // b waits: only one render holds memory at a time
      progress['a']!(0.42);
      expect(q.jobs.value[RenderQueue.keyOf(a, 1, 1.0)]!.value, 0.42);
      gates['a']!.complete();
      expect(name((await fa)!), 'k1_t100_v1.wav');
      await pumpEventQueue();
      expect(started.length, 2);
      expect(q.jobs.value.keys, [RenderQueue.keyOf(b, 2, 1.0)]);
      gates['b']!.complete();
      await fb;
      expect(q.jobs.value, isEmpty);
    });

    test('a cached render is reused untouched (same mtime), no job', () async {
      final a = mk('a', shift: 1);
      final f = q.add(a, 1, 1.0);
      await pumpEventQueue();
      gates['a']!.complete();
      final out = (await f)!;
      final mtime = out.lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await q.add(a, 1, 1.0))!.path, out.path);
      expect(out.lastModifiedSync(), mtime);
      expect(started.length, 1);
      expect(q.jobs.value, isEmpty);
      expect(name((await q.add(a, 0, 1.0))!), 'instrumental.flac'); // nothing to render
    });

    test('paused (stage mode): new jobs wait; resume starts them', () async {
      final a = mk('a', shift: 1);
      q.pause();
      final f = q.add(a, 1, 1.0);
      await pumpEventQueue();
      expect(started, isEmpty);
      q.resume();
      await pumpEventQueue();
      expect(started.length, 1);
      gates['a']!.complete();
      expect(await f, isNotNull);
    });

    test('a failed render (e.g. song deleted) gives null and the next one still runs', () async {
      final a = mk('a', shift: 1), b = mk('b', shift: 1);
      q.run = (s, shift, tempo, _) async {
        started.add((s.id, shift, tempo));
        if (s.id == 'a') throw RenderException(-2, 'gone');
        return s.original;
      };
      final fa = q.add(a, 1, 1.0), fb = q.add(b, 1, 1.0);
      expect(await fa, isNull);
      expect(await fb, isNotNull);
      expect(q.jobs.value, isEmpty);
    });
  });

  test('ensureRender on a deleted song fails without re-creating its folder', () async {
    final s = mk('a', shift: 1);
    s.dir.deleteSync(recursive: true);
    await expectLater(ensureRender(s), throwsA(isA<RenderException>()));
    expect(s.dir.existsSync(), isFalse);
  });
}
