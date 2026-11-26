import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/lrc.dart';
import 'package:karaoke_manager/lyrics_view.dart';
import 'package:karaoke_manager/lyrics_window.dart';
import 'package:karaoke_manager/presenter.dart';
import 'package:karaoke_manager/setlist.dart';
import 'package:karaoke_manager/stage.dart';
import 'package:karaoke_manager/theme.dart';

import 'helpers.dart';

const _s = Duration(seconds: 1);

/// Stands in for the lyrics window: records what it is sent; [dead] makes every call fail like a closed window.
class FakeLyrics {
  final sent = <LyricsState>[];
  var closes = 0;
  var dead = false;
  late final w = LyricsWindow((method, [args]) async {
    if (dead) throw StateError('window gone');
    if (method == 'state') sent.add(LyricsState.decode(args as Map<Object?, Object?>));
    if (method == 'close') closes++;
    return null;
  });
}

void main() {
  test('ahead/behind: counts from the first play, against the plan for the current item', () {
    // First play on item 0 (planned 0:00). Now on item 2 (planned 8:30), 1:00 into it -> planned 9:30 in.
    Duration behind(Duration real) =>
        behindPlan(sinceFirstPlay: real, firstStart: Duration.zero, currentStart: _s * 510, progress: _s * 60);
    expect(behind(_s * 570), Duration.zero);
    expect(driftLabel(behind(_s * 570)), 'on time');
    expect(driftLabel(behind(_s * 750)), '3 min behind');
    expect(driftLabel(behind(_s * 450)), '2 min ahead');
    expect(driftLabel(behind(_s * 595)), 'on time'); // 25 s late rounds to on time
    expect(driftLabel(behind(_s * 600)), '1 min behind'); // 30 s rounds up
    // Started the show from item 1 (planned 4:12): plan time counts from there.
    expect(behindPlan(sinceFirstPlay: _s * 318, firstStart: _s * 252, currentStart: _s * 510, progress: _s * 60),
        Duration.zero);
  });

  test('lyrics state survives encode -> platform channel codec -> decode', () {
    const codec = StandardMessageCodec();
    for (final s in const [
      LyricsState(song: r'C:\Karaoke\library\godacho-panv', pos: Duration(milliseconds: 83456), blackout: true),
      LyricsState(breakLabel: 'Dinner break', breakLeft: Duration(minutes: 14, seconds: 59, milliseconds: 500)),
      LyricsState(),
    ]) {
      final back = LyricsState.decode(codec.decodeMessage(codec.encodeMessage(s.encode())) as Map<Object?, Object?>);
      expect(back.encode(), s.encode());
      expect((back.song, back.pos, back.blackout, back.breakLabel, back.breakLeft),
          (s.song, s.pos, s.blackout, s.breakLabel, s.breakLeft));
    }
  });

  test('lyric cursor: current line and countdown dots in a long gap', () {
    final lines = parseLrc('[00:05.00]one\n[00:20.00]two\n[00:22.00]three\n');
    expect(lyricCursor(lines, _s * 2), (cur: -1, dots: 0)); // intro shorter than the 8 s gap rule
    expect(lyricCursor(lines, _s * 6), (cur: 0, dots: 0));
    expect(lyricCursor(lines, _s * 17), (cur: 0, dots: 4)); // 15 s gap: dots in its last 4 s
    expect(lyricCursor(lines, _s * 21), (cur: 1, dots: 0));
  });

  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('presenter_test'));
  tearDown(() => root.deleteSync(recursive: true));

  // One audio widget test per file (see FakeRenders in helpers.dart).
  testWidgets('Two screens at 1280x720: presenter, state to the lyrics window, fade needs a hold, falls back safely',
      (tester) async {
    fakeAudio(tester, position: _s * 10);
    fakeWindow(tester);
    await appWindow(tester);
    var displays = 2;
    countDisplays = () async => displays;
    final wins = <FakeLyrics>[];
    openLyricsWindow = () async => (wins..add(FakeLyrics())).last.w;

    const lrc = '[00:08.00]eight\n[00:09.50]nine-half\n[00:12.00]twelve\n';
    tempSong(root, 'a', {'title': 'Song a', 'original_key': 'Gm'}, lrc: lrc);
    tempSong(root, 'b', {'title': 'Song b'});
    final songs = {for (final s in loadLibrary(root)) s.id: s};
    final items = [
      SetItem.song('a')..json['notes'] = 'Talk to crowd before intro',
      SetItem.pause(minutes: 15, label: 'Dinner'),
      SetItem.song('b'),
    ];
    Widget stage() => MaterialApp(theme: K.theme(), home: StageScreen(items: items, songs: songs, changeover: _s * 30));
    await tester.pumpWidget(stage());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Presenter on the laptop, no overflow at 1280x720.
    expect(wins, hasLength(1));
    expect(tester.takeException(), isNull);
    expect(find.text('SETLIST QUEUE'), findsOneWidget);
    expect(find.text('Item 1 of 3'), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('Dinner'), findsOneWidget);
    expect(find.text('15:00'), findsOneWidget); // the break's length in the queue
    expect(find.text('Talk to crowd before intro'), findsOneWidget);
    expect(find.text('Gm  •  1.00x'), findsOneWidget);
    expect(find.text('nine-half'), findsOneWidget); // current lyric line at 0:10
    expect(find.text('twelve'), findsOneWidget); // next
    expect(find.text('0:10 / 18:20'), findsOneWidget); // set elapsed / planned total (no changeover around a break)
    // The lyrics window gets song + original-time position, ~20x a second.
    final first = wins[0].sent.length;
    await tester.pump(const Duration(milliseconds: 500));
    expect(wins[0].sent.length - first, greaterThanOrEqualTo(9));
    expect(wins[0].sent.last.song, endsWith('a'));
    expect(wins[0].sent.last.pos, _s * 10);

    await tester.tap(find.text('Blackout'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(wins[0].sent.last.blackout, isTrue);
    await tester.tap(find.text('Show lyrics'));
    await tester.tap(find.text('Play'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('on time'), findsOneWidget);

    // Fade out: a tap on the button or a short F does nothing.
    await tester.tap(find.text('Fade out'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Item 1 of 3'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    // Held 1 s: 3 s fade, then the next item is cued (here the break).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('Item 1 of 3'), findsOneWidget); // still fading
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Item 2 of 3'), findsOneWidget);
    expect(find.text('Next song'), findsOneWidget);
    expect(wins[0].sent.last.breakLabel, 'Dinner');
    expect(wins[0].sent.last.breakLeft, isNotNull);

    // The lyrics window dies (closed by hand): one-screen layout, nothing thrown.
    wins[0].dead = true;
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('SETLIST QUEUE'), findsNothing);
    expect(find.textContaining('Break: back in'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(wins, hasLength(1)); // not reopened while the same two displays stay

    // Replug: lyrics window back. Unplug mid-song: it's closed, one-screen layout, no crash.
    displays = 1;
    await tester.pump(const Duration(milliseconds: 1100));
    displays = 2;
    await tester.pump(const Duration(milliseconds: 1100));
    expect(wins, hasLength(2));
    expect(find.text('SETLIST QUEUE'), findsOneWidget);
    displays = 1;
    await tester.pump(const Duration(milliseconds: 1100));
    expect(wins[1].closes, 1);
    expect(find.text('SETLIST QUEUE'), findsNothing);
    expect(tester.takeException(), isNull);

    // Stage exited while the lyrics window was still opening: it's closed as soon as it arrives.
    await tester.pumpWidget(const SizedBox());
    final pending = Completer<LyricsWindow>();
    openLyricsWindow = () => pending.future;
    displays = 2;
    await tester.pumpWidget(stage());
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    final late = FakeLyrics();
    pending.complete(late.w);
    await tester.pump();
    expect(late.closes, 1);
    expect(tester.takeException(), isNull);
  });
}
