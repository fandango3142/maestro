import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/main.dart';
import 'package:karaoke_manager/theme.dart';

import 'helpers.dart';

/// A temp library: two unnamed songs (one without source_file), a named one, and a Whisper draft.
Directory _library() {
  final root = Directory.systemTemp.createTempSync('song_details_test');
  void song(String id, Map<String, Object?> json, [Map<String, String> files = const {}]) {
    final d = Directory('${root.path}/library/$id')..createSync(recursive: true);
    File('${d.path}/song.json').writeAsStringSync(jsonEncode({'schema_version': 1, 'id': id, ...json}));
    files.forEach((n, t) => File('${d.path}/$n').writeAsStringSync(t));
  }

  song('alpha', {'title': 'alpha', 'original_key': 'Gm', 'bpm': 64.0, 'studio_future': 7});
  song('b-song', {'title': 'B-Song', 'source_file': 'B-Song.mp3', 'language': 'konkani'});
  song('zed', {'title': 'Zed', 'artist': 'Someone', 'bpm': 64.0});
  song('draft', {
    'title': 'A draft with a rather long Konkani song title',
    'artist': 'X',
    'lyrics_draft': {'source': 'whisper-large-v3-turbo', 'confidence': 'low', 'script': 'latin'},
  }, {'lyrics.draft.lrc': '[00:01.00]one\n'});
  return root;
}

Map<String, dynamic> _json(Directory root, String id) =>
    jsonDecode(File('${root.path}/library/$id/song.json').readAsStringSync()) as Map<String, dynamic>;

Future<void> _pickStatus(WidgetTester t, String current, String pick) async {
  await t.tap(find.text(current));
  await t.pumpAndSettle();
  await t.tap(find.text(pick).last);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Library + Song details fit 1280x720; Save & next walks every unnamed song', (tester) async {
    fakeAudio(tester);
    await appWindow(tester);
    final root = _library();
    addTearDown(() => root.deleteSync(recursive: true));

    await tester.pumpWidget(MaterialApp(theme: K.theme(), home: LibraryScreen(root: root)));
    expect(tester.takeException(), isNull); // no RenderFlex overflow in the table
    expect(find.text('Whisper draft · low'), findsOneWidget);
    expect(find.text('Needs sync'), findsOneWidget); // the draft is timed but not ready

    await _pickStatus(tester, 'Status: All', 'Needs name (2)');
    expect(find.text('Zed'), findsNothing);

    // Open the first unnamed song with E on its focused row.
    await tester.tap(find.byTooltip('Song details  (E)').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull); // dialog fits
    expect(find.text('Source file: alpha · Gm'), findsOneWidget); // no source_file: falls back to the id
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Alpha Song');
    await tester.enterText(find.widgetWithText(TextField, 'Artist'), 'Ryan');
    await tester.tap(find.text('Save & next unnamed  (Ctrl+Enter)'));
    await tester.pumpAndSettle();

    final a = _json(root, 'alpha');
    expect([a['title'], a['artist'], a['studio_future'], a['bpm']], ['Alpha Song', 'Ryan', 7, 64.0]);
    expect(find.text('Source file: B-Song.mp3'), findsOneWidget); // the next unnamed one
    expect(find.text('Needs name (1)'), findsOneWidget); // the filter count dropped behind the dialog

    // Keyboard only: type over the selected title, Ctrl+Enter = save & next. Nothing left after it.
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Bee');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Every song has a name now'), findsOneWidget);
    expect(_json(root, 'b-song')['title'], 'Bee');
    expect(_json(root, 'b-song')['language'], 'konkani'); // untouched field kept

    // Search finds the new title straight away, no rescan.
    await _pickStatus(tester, 'Needs name (0)', 'Status: All');
    await tester.enterText(find.byType(TextField), 'bee');
    await tester.pump();
    expect(find.text('Bee'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // let the snackbar timer finish
  });

  testWidgets('BPM ½×/2× saves bpm_override, Reset clears it; Esc cancels', (tester) async {
    fakeAudio(tester);
    await appWindow(tester);
    final root = _library();
    addTearDown(() => root.deleteSync(recursive: true));
    await tester.pumpWidget(MaterialApp(theme: K.theme(), home: LibraryScreen(root: root)));

    Future<void> open() async {
      await tester.tap(find.byTooltip('Song details  (E)').last); // Zed is last by title
      await tester.pumpAndSettle();
    }

    TextField bpm() => tester.widget<TextField>(
        find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'BPM'));

    await open();
    expect(bpm().controller!.text, '64');
    expect(find.text('Detected 64'), findsOneWidget);
    expect(find.text('Reset'), findsNothing);
    await tester.tap(find.text('2×'));
    await tester.pump();
    expect(bpm().controller!.text, '128');
    expect(find.text('Reset'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_json(root, 'zed')['bpm_override'], 128.0);
    expect(_json(root, 'zed')['bpm'], 64.0); // Studio's value untouched
    expect(find.text('128'), findsOneWidget); // the Library row shows the override

    await open();
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(bpm().controller!.text, '64');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(_json(root, 'zed').containsKey('bpm_override'), isFalse);

    // Esc cancels without writing.
    final before = File('${root.path}/library/zed/song.json').readAsStringSync();
    await open();
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Nope');
    await tester.tap(find.text('½×'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(File('${root.path}/library/zed/song.json').readAsStringSync(), before);
    expect(find.text('Zed'), findsOneWidget);

    // E on a focused row opens its details.
    Focus.of(tester.element(find.byIcon(Icons.edit).last)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    expect(find.text('Source file: zed'), findsOneWidget);
  });
}
