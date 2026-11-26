import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/main.dart';
import 'package:karaoke_manager/setlist.dart';
import 'package:karaoke_manager/stage.dart';
import 'package:karaoke_manager/theme.dart';

import 'helpers.dart';

// WP-B3: the Library row accordion, tags and notes, setlist membership.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('accordion_test'));
  tearDown(() => root.deleteSync(recursive: true));

  Map<String, dynamic> onDisk(String id) =>
      jsonDecode(File('${root.path}/library/$id/song.json').readAsStringSync()) as Map<String, dynamic>;

  test('tags: malformed fields read as none, duplicates in any casing drop, library casing wins', () {
    Song song(Object? tags) => Song(Directory('x'), {'id': 'x', 'tags': tags}, const [], File('x'));
    expect(song('Goan').tags, isEmpty);
    expect(song(7).tags, isEmpty);
    expect(Song(Directory('x'), {'id': 'x'}, const [], File('x')).tags, isEmpty);
    expect(song([' Goan ', 3, '', 'goan', null, 'Slow dance']).tags, ['Goan', 'Slow dance']);

    expect(addTag(['Goan'], '  wedding ', known: ['Wedding', 'Goan']), ['Goan', 'Wedding']);
    expect(addTag(['Goan'], 'GOAN'), ['Goan']);
    expect(addTag(['Goan'], '   '), ['Goan']);
    expect(addTag([], 'New one'), ['New one']);

    expect(tagCounts([song(['Wedding', 'goan']), song(['Goan']), song('bad')]), {'goan': 2, 'Wedding': 1});
  });

  test('setlist membership: one pass, positions skip breaks, a song listed twice shows twice', () {
    final a = createSetlist(root, 'A')
      ..items.addAll([SetItem.song('x'), SetItem.pause(), SetItem.song('gone'), SetItem.song('x')]);
    final b = createSetlist(root, 'B')..items.add(SetItem.song('y'));
    final m = setlistMembership([a, b]);
    expect([for (final e in m['x']!) '${e.list.name} #${e.position} of ${e.count}'], ['A #1 of 3', 'A #3 of 3']);
    expect(m['gone']!.single.position, 2); // a missing song is still a slot
    expect(m['y']!.single.list, b);
    expect(m['z'], isNull);
  });

  test('tags and notes persist via saveSongFields, keep unknown fields and survive a rescan', () async {
    tempSong(root, 's', {'title': 'S', 'studio_future': {'a': 1}, 'tags': 'malformed'});
    final s = loadLibrary(root).single;
    await saveSongFields(s, {'tags': addTag(s.tags, 'Goan'), 'notes': 'Count in 4'});
    final again = loadLibrary(root).single;
    expect(again.tags, ['Goan']);
    expect(again.notes, 'Count in 4');
    expect(onDisk('s')['studio_future'], {'a': 1});
    expect(onDisk('s')['title'], 'S');
  });

  testWidgets('accordion at 1280x720: row click expands (no stage), notes/tags save, filter, setlist link',
      (tester) async {
    fakeAudio(tester);
    fakeWindow(tester);
    await appWindow(tester);
    const tags = ['Goan', 'Slow dance', 'Retro', 'Konkani', 'Party', 'Wedding', 'Fast', 'Classic', 'Duet', 'Encore'];
    tempSong(root, 'gm', {
      'title': 'A rather long Konkani song title for the accordion',
      'original_key': 'Gm',
      'key_shift': 2,
      'tempo': 0.95,
      'bpm': 120.0,
      'notes': 'Long note. ' * 60,
      'tags': tags,
      'studio_future': 7,
    }, lrc: '[00:01.00]one\n');
    tempSong(root, 'other', {'title': 'Other', 'tags': ['Anniversary', 'wedding', 'Carnival']});
    tempSong(root, 'bad', {'title': 'Bad tags', 'tags': 'Goan'});
    Directory('${root.path}/library/zz-processing').createSync(); // no song.json yet
    createSetlist(root, 'Gig A')
      ..json['date'] = '2026-12-05'
      ..json['venue'] = 'Club Tivoli'
      ..items.addAll([
        SetItem.song('other'),
        SetItem.pause(),
        SetItem.song('gm')..json.addAll({'key_shift': -1, 'notes': 'Talk to crowd before intro'}),
        SetItem.song('gone'),
        SetItem.song('gm'),
      ])
      ..save();
    createSetlist(root, 'Gig B')..items.add(SetItem.song('gm'))..save();
    createSetlist(root, 'Gig C')..items.addAll([SetItem.song('other'), SetItem.song('gm')])..save();

    await tester.pumpWidget(MaterialApp(theme: K.theme(), home: LibraryScreen(root: root)));
    expect(tester.takeException(), isNull);
    final title = find.text('A rather long Konkani song title for the accordion');

    // A song Studio is still processing opens read-only.
    await tester.tap(find.text('zz-processing'));
    await tester.pumpAndSettle();
    expect(find.text('Studio is still processing this song: nothing to edit yet.'), findsOneWidget);
    expect(find.text('Not in any setlist'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull); // no overflow with long notes, 10 tags, 4 setlist slots
    expect(find.textContaining('Studio is still processing'), findsNothing); // one panel at a time
    expect(find.byType(StageScreen), findsNothing);
    expect(find.text('Gm → Am · 0.95x'), findsOneWidget);
    expect(find.text('1:45'), findsNWidgets(2)); // row + panel: 100 s / 0.95
    expect(find.text('#2 of 4'), findsOneWidget); // Gig A, gig override and note
    expect(find.text('Gig key F#m'), findsOneWidget);
    expect(find.text('Talk to crowd before intro'), findsOneWidget);
    expect(find.text('#4 of 4'), findsOneWidget); // listed twice in Gig A
    expect(find.text('Key Am'), findsNWidgets(3)); // the other slots use the song's own key
    expect(find.byTooltip('Remove tag'), findsNWidgets(10));

    // Notes save after the debounce, and on collapse even inside it.
    final notes = find.widgetWithText(TextField, 'Notes');
    await tester.enterText(notes, 'First');
    await tester.pump(const Duration(milliseconds: 300));
    expect(onDisk('gm')['notes'], startsWith('Long note.'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(onDisk('gm')['notes'], 'First');
    await tester.enterText(notes, 'Second');
    await tester.tap(title); // collapse at once
    await tester.pump();
    expect(find.text('Notes'), findsNothing);
    expect(onDisk('gm')['notes'], 'Second');

    // Tags: remove one, add with the library's casing, a duplicate in other casing is ignored.
    await tester.tap(title);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove tag').first);
    await tester.pump();
    expect(onDisk('gm')['tags'], tags.sublist(1));
    final tagField = find.byWidgetPredicate(
        (w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('genre, occasion'));
    for (final t in ['anniversary', 'RETRO', '  ']) {
      await tester.enterText(tagField, t);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }
    expect(onDisk('gm')['tags'], [...tags.sublist(1), 'Anniversary']);
    // Autocomplete: suggestions come from the whole library; clicking one adds it and clears the field.
    await tester.enterText(tagField, 'carn');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Carnival'));
    await tester.pumpAndSettle();
    expect(onDisk('gm')['tags'], [...tags.sublist(1), 'Anniversary', 'Carnival']);
    expect(tester.widget<TextField>(tagField).controller!.text, isEmpty);
    expect(onDisk('gm')['studio_future'], 7);
    expect(tester.takeException(), isNull);

    // Tag filter (counts ignore casing), then search by tag. Collapsed, so every row fits on screen.
    await tester.tap(title);
    await tester.pump();
    await tester.tap(find.text('Tag: All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wedding (2)').last);
    await tester.pumpAndSettle();
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Bad tags'), findsNothing);
    await tester.tap(find.text('Wedding (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tag: All').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'slow dance');
    await tester.pump();
    expect(find.text('Other'), findsNothing);
    expect(find.text('Bad tags'), findsNothing);
    expect(title, findsOneWidget);

    // Esc in the notes closes; Enter on the focused row opens again.
    await tester.tap(title);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextField, 'Notes'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Notes'), findsNothing);
    Focus.of(tester.element(title)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Notes'), findsOneWidget);
    expect(find.byType(StageScreen), findsNothing);

    // A setlist slot opens that setlist in the Setlists screen.
    final gigC = find.text('Gig C');
    await tester.ensureVisible(gigC);
    await tester.pumpAndSettle();
    await tester.tap(gigC);
    await tester.pumpAndSettle();
    expect(find.text('Setlist order'), findsOneWidget);
    expect(find.text('Gig C'), findsNWidgets(2)); // its tile + the open editor's header
    expect(find.byType(StageScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
