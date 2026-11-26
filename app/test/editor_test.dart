import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/editor.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/theme.dart';

import 'helpers.dart';

Future<void> _key(WidgetTester t, LogicalKeyboardKey k, {bool ctrl = false, bool shift = false}) async {
  if (ctrl) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyEvent(k);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (ctrl) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
}

/// Opens the editor on a temp song with [lrc] in [name]; returns that file.
Future<File> _open(WidgetTester tester, String lrc,
    {String json = '{"id":"x","title":"X"}', String name = 'lyrics.roman.lrc'}) async {
  fakeAudio(tester);
  await appWindow(tester);

  final root = Directory.systemTemp.createTempSync('editor_test');
  addTearDown(() => root.deleteSync(recursive: true));
  final dir = Directory('${root.path}/library/x')..createSync(recursive: true);
  File('${dir.path}/song.json').writeAsStringSync(json);
  final file = File('${dir.path}/$name')..writeAsStringSync(lrc);

  await tester.pumpWidget(MaterialApp(theme: K.theme(), home: EditorScreen(song: Song.load(dir))));
  await tester.pump();
  return file;
}

void main() {
  testWidgets('edit text keeps timing; shortcuts are off while typing and back after', (tester) async {
    final lrc = await _open(tester, '[00:01.00]alpha\n[00:05.00]beta\ngamma\n');
    final breaks = find.text('♪  Instrumental');

    // F2 opens the selected (first) line. B and Space must not act as shortcuts while it's open.
    await _key(tester, LogicalKeyboardKey.f2);
    expect(find.byType(TextField), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.keyB);
    await _key(tester, LogicalKeyboardKey.delete, ctrl: true);
    expect(breaks, findsNothing);
    expect(find.text('beta'), findsOneWidget);

    // Type, Enter saves: words change, time stays.
    await tester.enterText(find.byType(TextField), 'ALPHA');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('ALPHA'), findsOneWidget);
    expect(find.text('0:01.00'), findsOneWidget);

    // Esc cancels.
    await _key(tester, LogicalKeyboardKey.f2);
    await tester.enterText(find.byType(TextField), 'nope');
    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('ALPHA'), findsOneWidget);

    // Ctrl+Enter inserts an empty line and opens it; Esc on it removes it again.
    await _key(tester, LogicalKeyboardKey.enter, ctrl: true);
    expect(find.byType(TextField), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.byType(TextField), findsNothing);

    // Focus is back on the list: Shift+↓ selects ALPHA..beta, Ctrl+D copies them untimed.
    await _key(tester, LogicalKeyboardKey.arrowDown, shift: true);
    await _key(tester, LogicalKeyboardKey.keyD, ctrl: true);
    expect(find.text('ALPHA'), findsNWidgets(2));
    expect(find.text('beta'), findsNWidgets(2));
    // B works again: break inserted before the selected (first copied) line.
    await _key(tester, LogicalKeyboardKey.keyB);
    expect(breaks, findsOneWidget);

    await _key(tester, LogicalKeyboardKey.keyS, ctrl: true);
    for (var i = 0; i < 50 && find.text('Saved lyrics.roman.lrc').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20))); // real file IO
      await tester.pump();
    }
    expect(lrc.readAsStringSync(), '[00:01.00]ALPHA\n[00:05.00]beta\n[00:00.00]\nALPHA\nbeta\ngamma\n');

    await tester.pumpWidget(const SizedBox()); // dispose: stops the position poll timer
  });

  testWidgets('paused: click words to edit, "Add line here" under the playhead, Ctrl+Enter chains lines',
      (tester) async {
    final lrc = await _open(tester, '[00:01.00]alpha\n[00:05.00]beta\n');
    final add = find.text('Add line here  (Ctrl+Enter)');
    // Playhead 0:00 is before the first line, so the add row is at the top.
    expect(add, findsOneWidget);
    expect(tester.getTopLeft(add).dy, lessThan(tester.getTopLeft(find.text('alpha')).dy));

    // Clicking the time column only selects; clicking the words opens the field.
    await tester.tap(find.text('0:05.00'));
    await tester.pump(const Duration(milliseconds: 500)); // past the double-click window
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('beta'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.escape);

    // Add row: new line at the top, typed, then Ctrl+Enter keeps it and opens another below it.
    await tester.tap(add);
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'intro one');
    await _key(tester, LogicalKeyboardKey.enter, ctrl: true);
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'intro two');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    await _key(tester, LogicalKeyboardKey.keyS, ctrl: true);
    for (var i = 0; i < 50 && find.text('Saved lyrics.roman.lrc').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20))); // real file IO
      await tester.pump();
    }
    expect(lrc.readAsStringSync(), 'intro one\nintro two\n[00:01.00]alpha\n[00:05.00]beta\n');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Backspace undo still hits the tapped line after a line above it is deleted', (tester) async {
    await _open(tester, 'a\nb\nc\n');
    await _key(tester, LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.enter); // b starts at 0:00
    expect(find.text('0:00.00'), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.delete, ctrl: true); // remove a
    expect(find.text('a'), findsNothing);
    await _key(tester, LogicalKeyboardKey.backspace);
    expect(find.text('0:00.00'), findsNothing); // b untimed again
    expect(find.text('b'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a Whisper draft shows its badge, and the first save writes lyrics.deva.lrc, not the draft',
      (tester) async {
    const src = '[00:01.00]alpha\n[00:05.00]beta\n';
    final draft = await _open(tester, src,
        name: 'lyrics.draft.lrc',
        json: '{"id":"x","title":"X","lyrics_draft":{"source":"whisper-large-v3-turbo","confidence":"low","script":"deva"}}');
    expect(find.text('Whisper draft · low confidence · whisper-large-v3-turbo'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _key(tester, LogicalKeyboardKey.bracketRight); // nudge alpha +0.1s
    await _key(tester, LogicalKeyboardKey.keyS, ctrl: true);
    for (var i = 0; i < 50 && find.text('Saved lyrics.deva.lrc').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20))); // real file IO
      await tester.pump();
    }
    expect(File('${draft.parent.path}/lyrics.deva.lrc').readAsStringSync(), '[00:01.10]alpha\n[00:05.00]beta\n');
    expect(draft.readAsStringSync(), src); // Studio's file untouched
    expect(find.textContaining('Whisper draft'), findsNothing); // it's real lyrics now
    await tester.pumpWidget(const SizedBox());
  });
}
