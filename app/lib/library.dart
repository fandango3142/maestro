import 'dart:convert';
import 'dart:io';

import 'lrc.dart';

enum SongStatus { processing, needsLyrics, needsSync, ready }

const _notes = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

/// "Gm" shifted +2 -> "Am". Returns the input unchanged if it isn't a key we know.
String shiftKey(String key, int semitones) {
  final minor = key.endsWith('m');
  final root = minor ? key.substring(0, key.length - 1) : key;
  final i = _notes.indexOf(root);
  if (i < 0) return key;
  return _notes[(i + semitones) % 12] + (minor ? 'm' : '');
}

/// One folder in library/. Reads song.json (written by Studio + the app); see SPEC.md §4.
class Song {
  final Directory dir;
  final Map<String, dynamic> json;
  final List<LyricLine> lyrics;
  final File lyricsFile; // where lyrics were read from, or where new ones get written

  Song(this.dir, this.json, this.lyrics, this.lyricsFile);

  String get id => json['id'] as String? ?? dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
  String get title => json['title'] as String? ?? id;
  String get artist => json['artist'] as String? ?? '';
  String get language => json['language'] as String? ?? '';
  String get originalKey => json['original_key'] as String? ?? '';
  int get keyShift => (json['key_shift'] as num?)?.toInt() ?? 0;
  double get tempo => (json['tempo'] as num?)?.toDouble() ?? 1.0;
  double? get bpm => (json['bpm'] as num?)?.toDouble();
  String get key => keyShift == 0 ? originalKey : '$originalKey → ${shiftKey(originalKey, keyShift)}';

  // ponytail: plays the raw instrumental until the key/tempo render step (Studio step 5) exists.
  File get audio => File('${dir.path}/instrumental.flac');

  SongStatus get status {
    if (json.isEmpty) return SongStatus.processing;
    if (lyrics.isEmpty) return SongStatus.needsLyrics;
    if (lyrics.any((l) => l.time == null)) return SongStatus.needsSync;
    return SongStatus.ready;
  }

  static Song load(Directory dir) {
    final meta = File('${dir.path}/song.json');
    final json = meta.existsSync()
        ? jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};
    final script = json['lyrics_script'] as String? ?? 'roman';
    final wanted = File('${dir.path}/lyrics.$script.lrc');
    final lrc = [wanted, File('${dir.path}/lyrics.roman.lrc')].where((f) => f.existsSync()).firstOrNull;
    return Song(dir, json, lrc == null ? const [] : parseLrc(lrc.readAsStringSync()), lrc ?? wanted);
  }
}

List<Song> loadLibrary(Directory root) {
  final lib = Directory('${root.path}/library');
  if (!lib.existsSync()) return [];
  final songs = lib.listSync().whereType<Directory>().map(Song.load).toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return songs;
}
