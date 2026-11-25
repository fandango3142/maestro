import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/setlist.dart';
import 'package:karaoke_manager/setlists_screen.dart';
import 'package:karaoke_manager/theme.dart';

void main() {
  testWidgets('Setlists screen fits a 1366x768 laptop and autosaves edits', (tester) async {
    // Real font, so widths match the app (the default test font is much wider).
    final bytes = File('assets/fonts/NotoSans-Regular.ttf').readAsBytesSync();
    await (FontLoader('NotoSans')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    tester.view.physicalSize = const Size(1366 - 240, 768); // the sidebar takes 240
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final root = Directory.systemTemp.createTempSync('setlists_screen_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final d = Directory('${root.path}/library/godacho-panv')..createSync(recursive: true);
    File('${d.path}/song.json').writeAsStringSync(
      '{"id":"godacho-panv","title":"A rather long Konkani song title","language":"konkani","original_key":"Gm"}',
    );
    final s = createSetlist(root, 'Friday Konkani & Retro')
      ..json['start_time'] = '20:00'
      ..items.addAll([SetItem.song('godacho-panv'), SetItem.pause(), SetItem.song('gone')]);
    s.save();

    await tester.pumpWidget(
      MaterialApp(
        theme: K.theme(),
        home: Scaffold(
          body: SetlistsScreen(root: root, songs: loadLibrary(root)),
        ),
      ),
    );
    expect(tester.takeException(), isNull); // no RenderFlex overflow
    // The song has no audio (unknown length = 0), so: song 8:00, break 8:00, missing song 8:15.
    expect(find.text('8:00 pm'), findsNWidgets(2));
    expect(find.text('8:15 pm'), findsOneWidget);
    expect(find.text('Ends at 8:15 pm'), findsOneWidget);
    expect(find.textContaining('gone (missing)'), findsOneWidget); // warning banner

    await tester.tap(find.text('Add break'));
    await tester.pump(const Duration(milliseconds: 600)); // past the autosave debounce
    expect(Setlist.load(s.file).items.where((i) => i.isBreak).length, 2);
    expect(tester.takeException(), isNull);
  });
}
