import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/library.dart';
import 'package:karaoke_manager/setlist.dart';

const _s = Duration(seconds: 1);

/// A FLAC file that is only the header: "fLaC" + a last-block STREAMINFO with [rate] and [samples].
List<int> _flacHeader(int rate, int samples) {
  final info = Uint8List(34);
  info[10] = rate >> 12;
  info[11] = (rate >> 4) & 0xFF;
  info[12] = ((rate & 0x0F) << 4) | 0x02; // low bits: channels/bps, irrelevant to the length
  info[13] = (samples >> 32) & 0x0F;
  info[14] = (samples >> 24) & 0xFF;
  info[15] = (samples >> 16) & 0xFF;
  info[16] = (samples >> 8) & 0xFF;
  info[17] = samples & 0xFF;
  return [...'fLaC'.codeUnits, 0x80, 0, 0, 34, ...info];
}

void main() {
  final lengths = {'a': _s * 222, 'b': _s * 258, 'c': _s * 195}; // 3:42, 4:18, 3:15
  Duration? len(String id) => lengths[id];

  test('planTimes: 3 songs + break, start 20:00, changeover 30s (exit criterion)', () {
    final items = [SetItem.song('a'), SetItem.song('b'), SetItem.pause(minutes: 15), SetItem.song('c')];
    final p = planTimes(items, len, const Duration(hours: 20), _s * 30);
    // a 20:00:00 (3:42) + 0:30 changeover -> b 20:04:12 (4:18) -> break 20:08:30 (15:00) -> c 20:23:30 (3:15)
    expect(p.starts, [
      const Duration(hours: 20),
      const Duration(hours: 20, minutes: 4, seconds: 12),
      const Duration(hours: 20, minutes: 8, seconds: 30),
      const Duration(hours: 20, minutes: 23, seconds: 30),
    ]);
    expect(p.total, const Duration(minutes: 26, seconds: 45));
    expect(p.starts.map(formatClock), ['8:00 pm', '8:04 pm', '8:08 pm', '8:23 pm']);
    expect(formatClock(const Duration(hours: 20) + p.total), '8:26 pm');
    expect(mss(p.total), '26:45');
  });

  test('planTimes: changeover only between consecutive songs', () {
    final p = planTimes([SetItem.song('a'), SetItem.song('b')], len, Duration.zero, _s * 30);
    expect(p.starts, [Duration.zero, _s * 252]);
    expect(p.total, _s * 510); // 222 + 30 + 258, nothing after the last song
  });

  test('planTimes: break first and last, empty set, missing song = 0', () {
    final p = planTimes(
      [SetItem.pause(minutes: 10), SetItem.song('a'), SetItem.pause(minutes: 5)],
      len,
      Duration.zero,
      _s * 30,
    );
    expect(p.starts, [Duration.zero, _s * 600, _s * 822]);
    expect(p.total, _s * 1122);

    final empty = planTimes([], len, const Duration(hours: 20), _s * 30);
    expect(empty.starts, isEmpty);
    expect(empty.total, Duration.zero);

    final m = planTimes([SetItem.song('a'), SetItem.song('gone'), SetItem.song('c')], len, Duration.zero, _s * 30);
    expect(m.starts, [Duration.zero, _s * 252, _s * 282]); // missing song is 0:00 but keeps its changeover
    expect(m.total, _s * 477);
  });

  test('parseClock / formatClock edges', () {
    expect(parseClock(''), isNull);
    expect(parseClock('8pm'), isNull);
    expect(parseClock('24:00'), isNull);
    expect(parseClock('9:05'), const Duration(hours: 9, minutes: 5));
    expect(formatClock(Duration.zero), '12:00 am');
    expect(formatClock(const Duration(hours: 12, minutes: 1)), '12:01 pm');
    expect(formatClock(const Duration(hours: 25, minutes: 30)), '1:30 am'); // past midnight wraps
  });

  group('files', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('setlist_test'));
    tearDown(() => root.deleteSync(recursive: true));

    test('round-trip keeps unknown fields (top level and per item), no .tmp left', () {
      final s = createSetlist(root, 'Friday Konkani & Retro');
      s.json['future_field'] = {'x': 1};
      s.items.add(SetItem({'id': 'a', 'key_shift': -1, 'notes': 'hi', 'future_item': true}));
      s.save();

      final again = Setlist.load(s.file);
      again.items.add(SetItem.pause());
      again.json['venue'] = 'Club Tivoli';
      again.save(); // second save renames over an existing file

      final raw = jsonDecode(s.file.readAsStringSync()) as Map<String, dynamic>;
      expect(raw['future_field'], {'x': 1});
      expect(raw['venue'], 'Club Tivoli');
      expect(raw['items'], [
        {'id': 'a', 'key_shift': -1, 'notes': 'hi', 'future_item': true},
        {'break': true, 'minutes': 15, 'label': 'Break'},
      ]);
      expect(File('${s.file.path}.tmp').existsSync(), isFalse);
    });

    test('id is a slug of the name; collisions get -2, -3; rename keeps the file', () {
      expect(createSetlist(root, 'Friday Konkani & Retro').id, 'friday-konkani-retro');
      expect(createSetlist(root, 'Friday konkani retro!').id, 'friday-konkani-retro-2');
      expect(createSetlist(root, 'friday-konkani-retro').id, 'friday-konkani-retro-3');
      expect(createSetlist(root, '!!!').id, 'setlist');

      final s = listSetlists(root).firstWhere((x) => x.id == 'setlist');
      s.json['name'] = 'Renamed';
      s.save();
      expect(listSetlists(root).firstWhere((x) => x.id == 'setlist').name, 'Renamed');
    });

    test('duplicate is a deep copy; delete; corrupt file skipped', () {
      final s = createSetlist(root, 'Gig')..items.add(SetItem.song('a'));
      s.save();
      final copy = createSetlist(root, 'Gig copy', from: s);
      copy.items.first.json['notes'] = 'changed';
      copy.save();
      expect(Setlist.load(s.file).items.first.notes, '');
      expect(Setlist.load(copy.file).items.single.songId, 'a');

      File('${root.path}/setlists/broken.json').writeAsStringSync('{not json');
      expect(listSetlists(root).map((x) => x.name), ['Gig', 'Gig copy']);

      s.file.deleteSync();
      expect(listSetlists(root).map((x) => x.name), ['Gig copy']);
    });

    test('flacDuration reads STREAMINFO; null for missing or non-FLAC', () {
      final f = File('${root.path}/x.flac')..writeAsBytesSync(_flacHeader(44100, 441000));
      expect(flacDuration(f), const Duration(seconds: 10));
      // Over 2^32 samples exercises the top 4 bits of the 36-bit count.
      final big = File('${root.path}/big.flac')..writeAsBytesSync(_flacHeader(48000, 48000 * 100000));
      expect(flacDuration(big), _s * 100000);
      expect(flacDuration(File('${root.path}/nope.flac')), isNull);
      final bad = File('${root.path}/bad.flac')..writeAsStringSync('not a flac file at all, just some text....');
      expect(flacDuration(bad), isNull);
      final short = File('${root.path}/short.flac')..writeAsBytesSync('fLaC'.codeUnits);
      expect(flacDuration(short), isNull);
    });

    test('Song.playedDuration applies cuts and tempo; toOriginal undoes both', () {
      final d = Directory('${root.path}/library/s')..createSync(recursive: true);
      File('${d.path}/instrumental.flac').writeAsBytesSync(_flacHeader(48000, 48000 * 100)); // 100 s
      File('${d.path}/song.json').writeAsStringSync('{"id":"s","tempo":1.25,"cuts":[[0,5],[50,55]]}');
      final song = Song.load(d);
      expect(song.duration, _s * 100);
      expect(song.playedDuration, _s * 72); // (100 - 10) / 1.25
      expect(toOriginal(_s * 8, song), _s * 15); // 8 × 1.25 = 10 s of cut audio, + the 5 s cut at 0
      expect(Song.load(Directory('${root.path}/library/none')).playedDuration, isNull);
    });
  });
}
