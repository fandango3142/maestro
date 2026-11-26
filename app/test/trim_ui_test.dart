import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/main.dart';
import 'package:karaoke_manager/render.dart';
import 'package:karaoke_manager/theme.dart';
import 'package:karaoke_manager/trim.dart';

import 'helpers.dart';

// WP-E at Ryan's 1280x720: "Needs trim review" filter, the trimmer (accept, dismiss, manual cut), and
// the render queued on the way out.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('trim_ui_test'));
  tearDown(() => root.deleteSync(recursive: true));

  Map<String, dynamic> onDisk(String id) =>
      jsonDecode(File('${root.path}/library/$id/song.json').readAsStringSync()) as Map<String, dynamic>;

  testWidgets('filter, accept, dismiss, drag + X, leave: cuts saved and rendered', (tester) async {
    fakeAudio(tester);
    final r = FakeRenders();
    await appWindow(tester);
    final n = 100 * peaksPerSecond; // synthetic waveform: no decoding in widget tests
    loadPeaks = (_) async => (
          backing: Float32List.fromList(List.generate(n, (i) => 0.1 + 0.1 * (i % 50) / 50)),
          vocals: Float32List.fromList(List.generate(n, (i) => i < 300 ? 0.2 : 0.0)),
        );
    addTearDown(() => loadPeaks = ensurePeaks);
    tempSong(root, 'talk', {
      'title': 'A song that opens with a long spoken dedication to the bride',
      'original_key': 'Gm',
      'cut_suggestions': [
        {'id': 'speech-0.0-6.5', 'start': 0.0, 'end': 6.5, 'kind': 'speech', 'confidence': 0.91},
        {'id': 'silence-97.0-100.0', 'start': 97.0, 'end': 100.0, 'kind': 'silence', 'confidence': 0.99},
      ],
      'studio_note': 'keep me',
    }, lrc: '[00:10.00]first line\n[00:45.00]inside the cut to come\n[00:60.00]later');
    tempSong(root, 'clean', {'title': 'Clean song'});
    await tester.pumpWidget(MaterialApp(theme: K.theme(), home: LibraryScreen(root: root)));

    await tester.tap(find.text('Status: All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Needs trim review (1)').last);
    await tester.pumpAndSettle();
    expect(find.text('Clean song'), findsNothing);

    await tester.tap(find.textContaining('A song that opens'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trim audio (flags to review)'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Speech 91%'), findsOneWidget);
    expect(find.textContaining('Silence 99%'), findsOneWidget);
    expect(find.textContaining('Flags: Studio'), findsOneWidget);

    await tester.tap(find.text('Accept (cut)').first); // the speech
    await tester.pumpAndSettle();
    expect(onDisk('talk')['cuts'], [[0.0, 6.5]]);
    expect(find.textContaining('plays 1:33'), findsOneWidget); // 100 − 6.5 s
    await tester.tap(find.text('Dismiss')); // the silence
    await tester.pumpAndSettle();
    expect(onDisk('talk')['dismissed_suggestions'], [{'kind': 'silence', 'start': 97.0, 'end': 100.0}]);
    expect(find.text('Accept (cut)'), findsNothing);

    // Drag 40 s -> 50 s on the waveform, X cuts it.
    final wave = tester.getRect(find.byKey(const Key('waveform')));
    double x(double sec) => wave.left + sec / 100 * wave.width;
    await tester.dragFrom(Offset(x(40), wave.center.dy), Offset(x(50) - x(40), 0));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pumpAndSettle();
    final cuts = (onDisk('talk')['cuts'] as List).cast<List>();
    expect(cuts, hasLength(2));
    expect(cuts[1][0] as num, closeTo(40, 0.5));
    expect(cuts[1][1] as num, closeTo(50, 0.5));
    expect(find.textContaining('inside a cut'), findsOneWidget); // the 0:45 lyric
    expect(onDisk('talk')['studio_note'], 'keep me');
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(r.started, [('talk', 0, 1.0)]); // cuts need a render even at key 0 / tempo 1.00
    await tester.tap(find.text('Needs trim review (0)')); // reviewed: the filter is empty now
    await tester.pumpAndSettle();
    await tester.tap(find.text('Status: All').last);
    await tester.pumpAndSettle();
    expect(find.text('Rendering 0 %'), findsOneWidget);
    expect(find.text('1:23'), findsNWidgets(2)); // row + open panel: 100 − 6.5 − ~10 s
    r.finish('talk');
    await tester.pumpAndSettle();
    expect(find.textContaining('Rendering'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
