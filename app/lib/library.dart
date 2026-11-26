import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  /// [lyrics] came from Studio's `lyrics.draft.lrc` (no real file yet); [lyricsFile] is then the save target.
  final bool isDraft;

  Song(this.dir, this.json, this.lyrics, this.lyricsFile, {this.isDraft = false});

  String get id => json['id'] as String? ?? dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
  String get title => json['title'] as String? ?? id;
  String get artist => json['artist'] as String? ?? '';
  String get language => json['language'] as String? ?? '';
  String get originalKey => json['original_key'] as String? ?? '';
  int get keyShift => (json['key_shift'] as num?)?.toInt() ?? 0;
  double get tempo => (json['tempo'] as num?)?.toDouble() ?? 1.0;
  /// The BPM to show everywhere: Ryan's correction if set, else Studio's detection.
  double? get bpm => (json['bpm_override'] as num?)?.toDouble() ?? detectedBpm;
  double? get detectedBpm => (json['bpm'] as num?)?.toDouble();
  String get sourceFile => json['source_file'] as String? ?? '';

  /// Studio's `lyrics_draft` info (source, confidence, script…), or empty.
  Map<String, dynamic> get draftInfo =>
      json['lyrics_draft'] is Map ? Map<String, dynamic>.from(json['lyrics_draft'] as Map) : const {};

  /// Still has Studio's first-guess name: no artist, and the title is the source file's stem or the id.
  bool get needsName {
    if (json.isEmpty || artist.trim().isNotEmpty) return false;
    final t = title.trim();
    final src = sourceFile;
    final stem = src.contains('.') ? src.substring(0, src.lastIndexOf('.')) : src;
    return t.isEmpty || t == id || (stem.isNotEmpty && t == stem);
  }
  String get key => keyShift == 0 ? originalKey : '$originalKey → ${shiftKey(originalKey, keyShift)}';

  /// Length of the original backing track, read once per load from the FLAC header.
  late final Duration? duration = flacDuration(File('${dir.path}/instrumental.flac'));

  /// What actually plays: (original − cuts) / tempo. Null if the length is unknown.
  Duration? get playedDuration {
    final d = duration;
    if (d == null) return null;
    final cut = (json['cuts'] as List? ?? const [])
        .whereType<List>()
        .where((c) => c.length == 2 && c[0] is num && c[1] is num)
        .fold<double>(0, (sum, c) => sum + max(0, (c[1] as num) - (c[0] as num)));
    final secs = max(0, d.inMicroseconds / 1e6 - cut) / (tempo > 0 ? tempo : 1);
    return Duration(microseconds: (secs * 1e6).round());
  }

  bool get playable => status != SongStatus.processing && audio.existsSync();

  // ponytail: plays the raw instrumental until the key/tempo render step (Studio step 5) exists.
  File get audio => File('${dir.path}/instrumental.flac');

  SongStatus get status {
    if (json.isEmpty) return SongStatus.processing;
    if (lyrics.isEmpty) return SongStatus.needsLyrics;
    if (isDraft) return SongStatus.needsSync; // timed, but nobody has checked it yet (SPEC §4)
    if (lyrics.any((l) => l.time == null)) return SongStatus.needsSync;
    return SongStatus.ready;
  }

  static Song load(Directory dir) {
    final meta = File('${dir.path}/song.json');
    final json = meta.existsSync()
        ? jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};
    final script = json['lyrics_script'] as String? ?? 'roman';
    File f(String name) => File('${dir.path}/lyrics.$name.lrc');
    final wanted = f(script);
    // Any real file wins over Studio's draft (deva last, so a draft saved as deva is still found).
    final lrc = [wanted, f('roman'), f('deva')].where((x) => x.existsSync()).firstOrNull;
    if (lrc != null) return Song(dir, json, parseLrc(lrc.readAsStringSync()), lrc);
    final draft = f('draft');
    if (draft.existsSync()) {
      final info = json['lyrics_draft'];
      final target = f(info is Map && info['script'] == 'deva' ? 'deva' : 'roman'); // never the draft itself
      return Song(dir, json, parseLrc(draft.readAsStringSync()), target, isDraft: true);
    }
    return Song(dir, json, const [], wanted);
  }
}

/// `song.json` keys the app may write (docs/stage-manager-plan.md, field ownership). Everything else
/// (schema_version, id, source_file, original_key, bpm, *_model, cut_suggestions, lyrics_draft…) is Studio's.
const appOwnedKeys = {
  'title', 'artist', 'language', 'tags', 'key_shift', 'tempo', 'backing_vocals', 'guide_vocal', //
  'lyrics_script', 'cuts', 'notes', 'bpm_override', 'dismissed_suggestions',
};

/// The one writer of `song.json`. Re-reads the file (Studio may have patched it since load), applies
/// [changes] (a null value removes the key), and writes `.tmp` then renames over the original, so
/// unknown fields survive and a crash never leaves half a file. Throws [ArgumentError] for any key the
/// app doesn't own, and [StateError] if there's no song.json (creating one would make Studio skip the folder).
// ponytail: a Studio patch landing between our read and rename is lost; the window is milliseconds.
Future<void> saveSongFields(Song s, Map<String, Object?> changes) async {
  final bad = changes.keys.where((k) => !appOwnedKeys.contains(k)).toList();
  if (bad.isNotEmpty) throw ArgumentError('song.json keys not owned by the app: ${bad.join(', ')}');
  final file = File('${s.dir.path}/song.json');
  if (!file.existsSync()) throw StateError('No song.json in ${s.dir.path}');
  final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>; // sync: a few hundred bytes
  for (final MapEntry(:key, :value) in changes.entries) {
    if (value == null) {
      map.remove(key);
    } else {
      map[key] = value;
    }
  }
  final tmp = File('${file.path}.tmp');
  tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(map), flush: true);
  tmp.renameSync(file.path); // replaces the existing file on Windows too (MoveFileEx REPLACE_EXISTING)
  s.json
    ..clear()
    ..addAll(map); // the Library row shows the new values without a rescan
}

/// The next song after [after] (wrapping round to the top) that still needs a name, or null.
Song? nextUnnamed(List<Song> songs, Song after) {
  final i = songs.indexOf(after);
  for (var k = 1; k <= songs.length; k++) {
    final s = songs[(i + k) % songs.length];
    if (s != after && s.needsName) return s;
  }
  return null;
}

/// Maps a playback position to the original-audio position lyrics are stored against.
// ponytail: cuts slot in here once the cuts editor exists; today it's tempo only.
Duration toOriginal(Duration playbackPos, Song s) => playbackPos * s.tempo;

/// Track length from the FLAC STREAMINFO block (sample rate + total samples). No decoding.
/// Null for a missing, non-FLAC or unknown-length file.
Duration? flacDuration(File f) {
  try {
    final raf = f.openSync();
    final b = raf.readSync(42);
    raf.closeSync();
    // "fLaC", then a block header whose type (low 7 bits) is 0 = STREAMINFO, then 34 bytes.
    if (b.length < 42 || String.fromCharCodes(b.sublist(0, 4)) != 'fLaC' || b[4] & 0x7F != 0) return null;
    final rate = (b[18] << 12) | (b[19] << 4) | (b[20] >> 4);
    final samples = ((b[21] & 0x0F) << 32) | (b[22] << 24) | (b[23] << 16) | (b[24] << 8) | b[25];
    if (rate == 0 || samples == 0) return null;
    return Duration(microseconds: samples * 1000000 ~/ rate);
  } on FileSystemException {
    return null;
  }
}

/// "3:42". Minutes keep counting past an hour ("62:05"), like the wireframe's running time.
String mss(Duration? d) =>
    d == null ? '—' : '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

List<Song> loadLibrary(Directory root) {
  final lib = Directory('${root.path}/library');
  if (!lib.existsSync()) return [];
  final songs = lib.listSync().whereType<Directory>().map(Song.load).toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  return songs;
}
