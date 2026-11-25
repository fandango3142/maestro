import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/editor.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/theme.dart';

/// Stands in for the audioplayers plugin: every call succeeds, and a set source reports "prepared"
/// so nothing waits on its 30s timeout.
void _fakeAudio(WidgetTester tester) {
  final m = tester.binding.defaultBinaryMessenger;
  final sinks = <String, MockStreamHandlerEventSink>{};
  void stream(String name) => m.setMockStreamHandler(
      EventChannel(name), MockStreamHandler.inline(onListen: (_, sink) {
        sinks[name] = sink;
      }));
  stream('xyz.luan/audioplayers.global/events');
  m.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
  m.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
    final id = (call.arguments as Map)['playerId'] as String;
    if (call.method == 'create') stream('xyz.luan/audioplayers/events/$id');
    if (call.method == 'setSourceUrl') {
      sinks['xyz.luan/audioplayers/events/$id']?.success({'event': 'audio.onPrepared', 'value': true});
    }
    return null;
  });
}

Future<void> _key(WidgetTester t, LogicalKeyboardKey k, {bool ctrl = false, bool shift = false}) async {
  if (ctrl) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyEvent(k);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (ctrl) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
}

/// Opens the editor on a temp song with [lrc]; returns the lyrics file.
Future<File> _open(WidgetTester tester, String lrc) async {
  _fakeAudio(tester);
  // Real font, so widths match the app (the default test font is much wider).
  final bytes = File('assets/fonts/NotoSans-Regular.ttf').readAsBytesSync();
  await (FontLoader('NotoSans')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  tester.view.physicalSize = const Size(1366, 768);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final root = Directory.systemTemp.createTempSync('editor_test');
  addTearDown(() => root.deleteSync(recursive: true));
  final dir = Directory('${root.path}/library/x')..createSync(recursive: true);
  File('${dir.path}/song.json').writeAsStringSync('{"id":"x","title":"X"}');
  final file = File('${dir.path}/lyrics.roman.lrc')..writeAsStringSync(lrc);

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
}
