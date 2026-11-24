import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/lrc.dart';

void main() {
  test('parseLrc: timestamps, metadata, multi-tag, sorting', () {
    final lines = parseLrc('[ti:Song]\n[00:12.50]second\n[00:01.00][00:20]chorus\n\n');
    expect(lines.map((l) => l.text), ['chorus', 'second', 'chorus']);
    expect(lines.map((l) => l.time!.inMilliseconds), [1000, 12500, 20000]);
  });

  test('parseLrc: untimed lines kept in order with null time', () {
    final lines = parseLrc('line one\r\nline two');
    expect(lines.map((l) => l.text), ['line one', 'line two']);
    expect(lines.every((l) => l.time == null), isTrue);
  });

  test('currentLine', () {
    final lines = parseLrc('[00:05]a\n[00:10]b');
    expect(currentLine(lines, const Duration(seconds: 1)), -1);
    expect(currentLine(lines, const Duration(seconds: 5)), 0);
    expect(currentLine(lines, const Duration(seconds: 99)), 1);
  });

  test('shiftKey', () {
    expect(shiftKey('Gm', 2), 'Am');
    expect(shiftKey('B', 1), 'C');
    expect(shiftKey('C', -1), 'B');
    expect(shiftKey('??', 3), '??');
  });

  test('status derived from files on disk', () {
    final root = Directory.systemTemp.createTempSync('karaoke_test');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory mk(String id, {String? json, String? lrc}) {
      final d = Directory('${root.path}/library/$id')..createSync(recursive: true);
      if (json != null) File('${d.path}/song.json').writeAsStringSync(json);
      if (lrc != null) File('${d.path}/lyrics.roman.lrc').writeAsStringSync(lrc);
      return d;
    }

    mk('a', json: '{"id":"a","title":"A"}', lrc: '[00:01]x');
    mk('b', json: '{"id":"b","title":"B"}', lrc: 'x');
    mk('c', json: '{"id":"c","title":"C"}');
    mk('d');
    final byId = {for (final s in loadLibrary(root)) s.id: s.status};
    expect(byId, {
      'a': SongStatus.ready,
      'b': SongStatus.needsSync,
      'c': SongStatus.needsLyrics,
      'd': SongStatus.processing,
    });
  });
}
