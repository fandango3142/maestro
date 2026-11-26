import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/library.dart';

// WP-B: saveSongFields, the needs-name rule, Studio lyric drafts, bpm_override.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('song_fields_test'));
  tearDown(() => root.deleteSync(recursive: true));

  Directory mk(String id, {Map<String, Object?>? json, Map<String, String> files = const {}}) {
    final d = Directory('${root.path}/library/$id')..createSync(recursive: true);
    if (json != null) File('${d.path}/song.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    files.forEach((name, text) => File('${d.path}/$name').writeAsStringSync(text));
    return d;
  }

  Map<String, dynamic> onDisk(Directory d) =>
      jsonDecode(File('${d.path}/song.json').readAsStringSync()) as Map<String, dynamic>;

  const studio = {
    'schema_version': 1,
    'id': 'godacho-panv',
    'title': 'godacho-panv',
    'source_file': 'godacho-panv.mp3',
    'original_key': 'Gm',
    'bpm': 129.9,
    'separation_model': 'model_bs_roformer.ckpt',
    'lyrics_draft': {'source': 'whisper-large-v3-turbo', 'confidence': 'low'},
    'future_studio_field': {'nested': [1, 2.5, 'x']},
    'language': 'konkani',
  };

  group('saveSongFields', () {
    test('changes only the given keys; every other value identical; atomic over an existing file', () async {
      final d = mk('godacho-panv', json: studio);
      final s = Song.load(d);
      await saveSongFields(s, {'title': 'Godacho Panv', 'artist': 'Trad.', 'language': 'konkani'});
      await saveSongFields(s, {'bpm_override': 65.0}); // second save renames over the file again

      final after = onDisk(d);
      expect(after['title'], 'Godacho Panv');
      expect(after['artist'], 'Trad.');
      expect(after['bpm_override'], 65.0);
      for (final k in studio.keys.where((k) => k != 'title')) {
        expect(after[k], studio[k], reason: k);
      }
      expect(after.keys.toSet(), {...studio.keys, 'artist', 'bpm_override'});
      expect(File('${d.path}/song.json.tmp').existsSync(), isFalse);
      // The in-memory song follows, so the Library row and search see it without a rescan.
      expect(s.title, 'Godacho Panv');
      expect(s.bpm, 65.0);
    });

    test('re-reads the file, so a Studio patch made after load survives', () async {
      final d = mk('a', json: {'id': 'a', 'bpm': 60.0});
      final s = Song.load(d);
      File('${d.path}/song.json').writeAsStringSync('{"id":"a","bpm":61.0,"original_key":"D"}'); // Studio re-ran
      await saveSongFields(s, {'artist': 'X'});
      expect(onDisk(d), {'id': 'a', 'bpm': 61.0, 'original_key': 'D', 'artist': 'X'});
      expect(s.detectedBpm, 61.0);
    });

    test('a null value removes the key (bpm_override reset)', () async {
      final d = mk('a', json: {'id': 'a', 'bpm': 60.0, 'bpm_override': 120.0});
      final s = Song.load(d);
      expect(s.bpm, 120.0);
      await saveSongFields(s, {'bpm_override': null});
      expect(onDisk(d).containsKey('bpm_override'), isFalse);
      expect(s.bpm, 60.0);
    });

    test('refuses Studio-owned keys and leaves the file alone', () async {
      final d = mk('godacho-panv', json: studio);
      final before = File('${d.path}/song.json').readAsStringSync();
      final s = Song.load(d);
      for (final k in [
        'original_key', 'bpm', 'id', 'source_file', 'schema_version', 'lyrics_draft', 'cut_suggestions', //
        'separation_model', 'backing_model',
      ]) {
        await expectLater(saveSongFields(s, {'title': 'ok', k: 'x'}), throwsArgumentError, reason: k);
      }
      expect(File('${d.path}/song.json').readAsStringSync(), before);
      expect(s.title, 'godacho-panv');
    });

    test('never creates a song.json (Studio would then skip the folder)', () async {
      final d = mk('processing');
      await expectLater(saveSongFields(Song.load(d), {'title': 'x'}), throwsStateError);
      expect(File('${d.path}/song.json').existsSync(), isFalse);
    });
  });

  test('needs a name: no artist and title = source file stem or id', () {
    Song song(Map<String, Object?> j) => Song.load(mk(j['id'] as String, json: j));
    expect(song({'id': 'a', 'title': 'a', 'source_file': 'Other.mp3'}).needsName, isTrue); // title = id
    expect(song({'id': 'b', 'title': 'Los-Lobos', 'source_file': 'Los-Lobos.mp3'}).needsName, isTrue); // = stem
    expect(song({'id': 'c', 'title': 'My.Song.v2', 'source_file': 'My.Song.v2.flac'}).needsName, isTrue);
    expect(song({'id': 'd', 'title': 'Los-Lobos', 'source_file': 'Los-Lobos.mp3', 'artist': 'Los Lobos'}).needsName,
        isFalse);
    expect(song({'id': 'e', 'title': 'La Bamba', 'source_file': 'Los-Lobos.mp3'}).needsName, isFalse);
    // No source_file: only the id rule applies.
    expect(song({'id': 'f'}).needsName, isTrue); // title falls back to the id
    expect(song({'id': 'g', 'title': 'g'}).needsName, isTrue);
    expect(song({'id': 'h', 'title': 'Proper Name'}).needsName, isFalse);
    expect(song({'id': 'i', 'title': '  '}).needsName, isTrue);
    expect(Song.load(mk('processing')).needsName, isFalse); // no song.json yet: nothing to name
  });

  test('nextUnnamed walks forward, wraps at the end of the list, skips the current one', () {
    final a = Song.load(mk('a', json: {'id': 'a'}));
    final b = Song.load(mk('b', json: {'id': 'b', 'title': 'Named'}));
    final c = Song.load(mk('c', json: {'id': 'c'}));
    final list = [a, b, c];
    expect(nextUnnamed(list, a), c);
    expect(nextUnnamed(list, c), a); // last in the list: back to the top
    expect(nextUnnamed(list, b), c);
    expect(nextUnnamed([a, b], a), isNull); // only the current one left
    expect(nextUnnamed(const [], a), isNull);
  });

  group('lyric drafts', () {
    const timed = '[00:01.00]one\n[00:04.00]two\n';
    const draftJson = {
      'id': 'x',
      'lyrics_draft': {'source': 'ctc-forced-aligner-mms + ryan-text', 'confidence': 'medium', 'script': 'deva'},
    };

    test('falls back to the draft; fully timed but still needs sync; saves to the script target', () {
      final s = Song.load(mk('x', json: draftJson, files: {'lyrics.draft.lrc': timed}));
      expect(s.isDraft, isTrue);
      expect(s.lyrics.map((l) => l.text), ['one', 'two']);
      expect(s.status, SongStatus.needsSync);
      expect(s.lyricsFile.uri.pathSegments.last, 'lyrics.deva.lrc');

      final latin = Song.load(mk('y', json: {
        'id': 'y',
        'lyrics_draft': {'script': 'latin'},
      }, files: {'lyrics.draft.lrc': timed}));
      expect(latin.lyricsFile.uri.pathSegments.last, 'lyrics.roman.lrc');
      final bare = Song.load(mk('z', json: {'id': 'z'}, files: {'lyrics.draft.lrc': timed})); // no lyrics_draft
      expect(bare.lyricsFile.uri.pathSegments.last, 'lyrics.roman.lrc');
      expect(bare.isDraft, isTrue);
    });

    test('a real lyrics file wins over the draft', () {
      final s = Song.load(
          mk('x', json: draftJson, files: {'lyrics.draft.lrc': timed, 'lyrics.roman.lrc': '[00:02.00]real\n'}));
      expect(s.isDraft, isFalse);
      expect(s.lyrics.single.text, 'real');
      expect(s.status, SongStatus.ready);
      expect(s.lyricsFile.uri.pathSegments.last, 'lyrics.roman.lrc');
    });

    test('once the draft was saved as deva, that file is found even with lyrics_script roman', () {
      final s = Song.load(mk('x', json: draftJson, files: {'lyrics.draft.lrc': timed, 'lyrics.deva.lrc': timed}));
      expect(s.isDraft, isFalse);
      expect(s.status, SongStatus.ready);
      expect(s.lyricsFile.uri.pathSegments.last, 'lyrics.deva.lrc');
    });
  });
}
