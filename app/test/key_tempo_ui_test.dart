import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/main.dart';
import 'package:karaoke_manager/theme.dart';

import 'helpers.dart';

// WP-C2 at Ryan's 1280x720: Key/Tempo in Song details, the Library render chip.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('key_tempo_ui_test'));
  tearDown(() => root.deleteSync(recursive: true));

  Map<String, dynamic> onDisk(String id) =>
      jsonDecode(File('${root.path}/library/$id/song.json').readAsStringSync()) as Map<String, dynamic>;

  testWidgets('Key/Tempo in Song details: renders only on Save, chip shows progress, then goes', (tester) async {
    fakeAudio(tester);
    final r = FakeRenders();
    await appWindow(tester);
    tempSong(root, 'gm', {
      'title': 'A rather long Konkani song title for the dialog',
      'artist': 'Someone',
      'original_key': 'Gm',
      'bpm': 120.0,
    });
    await tester.pumpWidget(MaterialApp(theme: K.theme(), home: LibraryScreen(root: root)));

    await tester.tap(find.byTooltip('Song details  (E)'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('1.00x · 1:40 · 120 BPM'), findsOneWidget);

    await tester.tap(find.byTooltip('Key up'));
    await tester.tap(find.byTooltip('Key up'));
    await tester.pump();
    expect(find.text('Gm → Am'), findsOneWidget);
    // Drag the tempo slider about: nothing renders while it moves.
    final slider = find.byType(Slider);
    await tester.drag(slider, const Offset(-80, 0));
    await tester.drag(slider, const Offset(40, 0));
    for (final v in [0.83, 0.9, 0.951]) {
      tester.widget<Slider>(slider).onChanged!(v);
      await tester.pump();
    }
    expect(find.text('0.95x · 1:45 · 114 BPM'), findsOneWidget); // 100 s / 0.95, 120 × 0.95
    expect(find.textContaining('Not rendered yet'), findsOneWidget);
    expect(r.started, isEmpty);
    expect(tester.takeException(), isNull);

    // Keys are capped at ±6.
    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byTooltip('Key up'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('+6'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byTooltip('Key down'));
      await tester.pump(const Duration(milliseconds: 300));
    }

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(onDisk('gm')['key_shift'], 2);
    expect(onDisk('gm')['tempo'], 0.95);
    expect(r.started, [('gm', 2, 0.95)]); // one render, for the saved settings only
    expect(find.text('Gm → Am'), findsOneWidget); // Library key column
    expect(find.text('Rendering 0 %'), findsOneWidget);
    r.progress['gm']!(0.42);
    await tester.pump();
    expect(find.text('Rendering 42 %'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Reopen while it renders: the preview says so. Save again with the same settings: no second job.
    await tester.tap(find.byTooltip('Song details  (E)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Rendering… the preview plays the original'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(r.started.length, 1);

    r.finish('gm');
    await tester.pumpAndSettle();
    expect(find.textContaining('Rendering'), findsNothing);
    expect(File('${root.path}/library/gm/render/k2_t95_v1.wav').existsSync(), isTrue);
  });
}
