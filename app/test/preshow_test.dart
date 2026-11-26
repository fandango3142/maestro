import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/preshow.dart';
import 'package:karaoke_manager/render.dart';
import 'package:karaoke_manager/setlist.dart';
import 'package:karaoke_manager/setlists_screen.dart';
import 'package:karaoke_manager/theme.dart';

import 'helpers.dart';

// WP-C2 at Ryan's 1280x720: pre-show check (sequential, Launch anyway), stage plays/maps the file it has.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('preshow_test'));
  tearDown(() => root.deleteSync(recursive: true));

  testWidgets('Pre-show check renders one at a time; Launch anyway; stage maps lyrics by the file playing',
      (tester) async {
    fakeAudio(tester, position: const Duration(seconds: 10));
    fakeWindow(tester);
    final r = FakeRenders();
    await appWindow(tester, width: 1280 - 240); // the sidebar takes 240
    const lrc = '[00:08.00]eight\n[00:09.50]nine-half\n[00:12.00]twelve\n';
    for (final id in ['a', 'b', 'c']) {
      tempSong(root, id, {'title': 'Song $id', 'tempo': 0.85}, lrc: lrc);
    }
    final s = createSetlist(root, 'Gig')..items.addAll([SetItem.song('a'), SetItem.song('b'), SetItem.song('c')]);
    s.save();
    await tester.pumpWidget(
        MaterialApp(theme: K.theme(), home: Scaffold(body: SetlistsScreen(root: root, songs: loadLibrary(root)))));

    await tester.tap(find.text('Launch Stage Mode'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Pre-show check'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('Waiting'), findsNWidgets(3));
    expect(r.ids, ['a']); // sequential: only one render in memory
    r.progress['a']!(0.5);
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('50 %'), findsOneWidget);
    r.finish('a');
    await tester.pump();
    await tester.pump();
    expect(find.text('Done'), findsOneWidget);
    expect(r.ids, ['a', 'b']);

    await tester.tap(find.text('Launch anyway (originals for the rest)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    // Song a is rendered at 0.85x: 10 s heard = 8.5 s of the original -> "eight".
    expect(find.textContaining('Song a  •    •  0.85x'), findsOneWidget);
    expect(find.text('eight'), findsOneWidget);

    r.finish('b'); // b was already running and finishes; c must not start during the show
    await tester.pump(const Duration(milliseconds: 100));
    expect(r.ids, ['a', 'b']);

    Future<void> next() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 200));
    }

    await next(); // b: its render landed before it was cued
    expect(find.textContaining('Song b  •    •  0.85x'), findsOneWidget);
    await next(); // c: not rendered -> the original at 1.00x, lyrics 1:1 (10 s = 10 s) -> "nine-half"
    expect(find.textContaining('Song c  •    •  1.00x  •  original (not rendered)'), findsOneWidget);
    expect(find.text('eight'), findsNothing);
    expect(find.text('nine-half'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox()); // leave stage: rendering resumes
    await tester.pump();
    expect(r.ids, ['a', 'b', 'c']);
    r.finish('c');
    await tester.pump();
  });

  // No audio in this one (see FakeRenders on why only one audio test per file).
  testWidgets('Pre-show check: everything rendered -> goes on stage by itself; failures are shown', (tester) async {
    final r = FakeRenders();
    await appWindow(tester);
    tempSong(root, 'a', {'title': 'Song a', 'key_shift': 2});
    tempSong(root, 'b', {'title': 'Song b', 'key_shift': -3, 'original_key': 'Gm'});
    final songs = {for (final s in loadLibrary(root)) s.id: s};
    bool? go;
    await tester.pumpWidget(MaterialApp(
      theme: K.theme(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => go = await preShowCheck(context, missingRenders([SetItem.song('a'), SetItem.song('b')], songs)),
          child: const Text('launch'),
        ),
      ),
    ));
    await tester.tap(find.text('launch'));
    await tester.pump();
    expect(find.text('Gm → Em · 1.00x'), findsOneWidget);
    r.finish('a');
    await tester.pump();
    r.finish('b');
    await tester.pumpAndSettle();
    expect(go, isTrue);
    expect(find.text('Pre-show check'), findsNothing);
    expect(r.ids, ['a', 'b']);
    expect(missingRenders([SetItem.song('a'), SetItem.song('b')], songs), isEmpty); // cached now

    // A render that fails keeps the dialog open and says so; Launch goes on with the original.
    tempSong(root, 'c', {'title': 'Song c', 'tempo': 1.1});
    final c = loadLibrary(root).firstWhere((s) => s.id == 'c');
    renderQueue.run = (s, shift, tempo, _) async => throw StateError('disk full');
    go = null;
    await tester.pumpWidget(MaterialApp(
      theme: K.theme(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => go = await preShowCheck(context, [(song: c, shift: 0)]),
          child: const Text('launch'),
        ),
      ),
    ));
    await tester.tap(find.text('launch'));
    await tester.pumpAndSettle();
    expect(find.text('Failed'), findsOneWidget);
    expect(find.textContaining('1 render failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Launch'));
    await tester.pumpAndSettle();
    expect(go, isTrue);
  });
}
