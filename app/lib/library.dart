import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'lrc.dart';
import 'render.dart';

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
  String get notes => json['notes'] is String ? json['notes'] as String : '';

  /// Free-form tags (genre, occasion…): trimmed, de-duplicated ignoring case. A malformed field reads as none.
  List<String> get tags {
    final raw = json['tags'] is List ? json['tags'] as List : const [];
    final seen = <String>{};
    return [
      for (final t in raw)
        if (t is String && t.trim().isNotEmpty && seen.add(t.trim().toLowerCase())) t.trim(),
    ];
  }

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

  /// What plays at the song's own tempo: (original − cuts) / tempo. Null if the length is unknown.
  Duration? get playedDuration => playedDurationAt(tempo);

  /// (original − [cuts]) / [tempo]: the length of a file that plays at [tempo] with [cuts] (default:
  /// the song's) taken out. A fallback to the original has no cuts: pass its [Playback.cuts].
  Duration? playedDurationAt(double tempo, {List<Cut>? cuts}) {
    final d = duration;
    if (d == null) return null;
    final cut = (cuts ?? this.cuts).fold<double>(0, (sum, c) => sum + c.$2 - c.$1);
    final secs = max(0, d.inMicroseconds / 1e6 - cut) / (tempo > 0 ? tempo : 1);
    return Duration(microseconds: (secs * 1e6).round());
  }

  /// `cuts` (seconds of the original to skip), cleaned: valid pairs only, clamped to the track, sorted,
  /// overlapping or touching ones merged. A malformed field reads as none.
  List<Cut> get cuts {
    final end = duration == null ? double.infinity : duration!.inMicroseconds / 1e6;
    return normalizeCuts([
      for (final c in json['cuts'] is List ? json['cuts'] as List : const [])
        if (c is List && c.length == 2 && c[0] is num && c[1] is num)
          ((c[0] as num).toDouble(), min((c[1] as num).toDouble(), end)),
    ]);
  }

  /// Studio's `cut_suggestions`, or null when Studio hasn't written any (the app then flags on its own).
  List<Flag>? get suggestions {
    final raw = json['cut_suggestions'];
    if (raw is! List) return null;
    return [for (final f in raw) ?flagFrom(f)];
  }

  /// `dismissed_suggestions`: flags Ryan dismissed. Malformed entries read as none.
  List<Flag> get dismissed => [
        if (json['dismissed_suggestions'] is List)
          for (final f in json['dismissed_suggestions'] as List) ?flagFrom(f),
      ];

  bool get playable => status != SongStatus.processing && original.existsSync();

  /// Studio's backing track at the original key and tempo. Lyric times are stored against this file.
  File get original => File('${dir.path}/instrumental.flac');

  /// The backing track at the song's own key/tempo: its render when that exists, else [original].
  File get audio => playbackFor(this, keyShift).file;

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

/// [tags] plus [tag] (trimmed), unless it's empty or already there in any casing. A tag already used in
/// the library ([known]) keeps that casing, so "goan" joins "Goan".
List<String> addTag(List<String> tags, String tag, {Iterable<String> known = const []}) {
  final t = tag.trim(), low = t.toLowerCase();
  if (t.isEmpty || tags.any((x) => x.toLowerCase() == low)) return tags;
  return [...tags, known.firstWhere((k) => k.toLowerCase() == low, orElse: () => t)];
}

/// Every tag in [songs] with how many songs have it, A-Z. Casing ignored; the first-seen casing is shown.
Map<String, int> tagCounts(Iterable<Song> songs) {
  final names = <String, String>{}, counts = <String, int>{};
  for (final s in songs) {
    for (final t in s.tags) {
      final low = t.toLowerCase();
      names.putIfAbsent(low, () => t);
      counts[low] = (counts[low] ?? 0) + 1;
    }
  }
  final keys = names.keys.toList()..sort();
  return {for (final k in keys) names[k]!: counts[k]!};
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

/// A file to play, the tempo and key shift it really plays at, the cuts baked into it, and whether it
/// stands in for a missing render.
typedef Playback = ({File file, double tempo, int shift, List<Cut> cuts, bool fallback});

/// What plays for [s] at [shift] semitones and [tempo] (default: the song's tempo): the render when its
/// file exists, else the original. [tempo] and [cuts] are then what the chosen file really has (1.0 and
/// none for the original), and [fallback] says a render was wanted but isn't on disk yet. Lyric timing
/// and lengths must use these, or a song playing the original would drift.
Playback playbackFor(Song s, int shift, [double? tempo]) {
  final t = ((tempo ?? s.tempo) * 100).round() / 100; // same rounding as the render's file name
  final cuts = s.cuts;
  final name = renderFileName(shift, t, cuts);
  final render = name == null ? null : File('${s.dir.path}/render/$name');
  if (render != null && render.existsSync()) {
    return (file: render, tempo: t, shift: shift, cuts: cuts, fallback: false);
  }
  return (file: s.original, tempo: 1.0, shift: 0, cuts: const <Cut>[], fallback: render != null);
}

/// Maps a playback position to the original-audio position lyrics are stored against: undo the tempo,
/// then step over each cut before it. [playing] is what's really playing (see [playbackFor]); default:
/// the song's own render (its tempo and cuts).
Duration toOriginal(Duration playbackPos, Song s, {Playback? playing}) => _secs(
    cutToOriginal(playbackPos.inMicroseconds / 1e6 * (playing?.tempo ?? s.tempo), playing?.cuts ?? s.cuts));

/// The inverse: where a lyric at original time [original] is heard in what's playing. A time inside a
/// cut is heard at the join.
Duration fromOriginal(Duration original, Song s, {Playback? playing}) => _secs(
    originalToCut(original.inMicroseconds / 1e6, playing?.cuts ?? s.cuts) / (playing?.tempo ?? s.tempo));

Duration _secs(double s) => Duration(microseconds: (s * 1e6).round());

/// A span of the original audio in seconds, (start, end).
typedef Cut = (double, double);

/// Sorted, merged (overlapping or touching), start clamped at 0, empty ones dropped.
List<Cut> normalizeCuts(Iterable<Cut> cuts) {
  final sorted = [for (final c in cuts) (max(0.0, c.$1), c.$2)].where((c) => c.$2 > c.$1).toList()
    ..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <Cut>[];
  for (final c in sorted) {
    if (out.isNotEmpty && c.$1 <= out.last.$2) {
      out.last = (out.last.$1, max(out.last.$2, c.$2));
    } else {
      out.add(c);
    }
  }
  return out;
}

/// Seconds into the cut audio -> seconds into the original. [cuts] must be normalized.
double cutToOriginal(double t, List<Cut> cuts) {
  for (final (a, b) in cuts) {
    if (t < a) break;
    t += b - a; // a join plays the audio after the cut
  }
  return t;
}

/// Seconds into the original -> seconds into the cut audio; inside a cut -> the join.
double originalToCut(double t, List<Cut> cuts) {
  var removed = 0.0;
  for (final (a, b) in cuts) {
    if (t <= a) break;
    removed += min(t, b) - a;
  }
  return t - removed;
}

/// A flagged section: Studio's `cut_suggestions` entry, the app's own fallback, or a dismissal.
/// [kind] is `speech` or `silence`; [confidence] is null when unknown (the app's fallback flags).
typedef Flag = ({String kind, double start, double end, double? confidence});

/// A flag from a JSON map, or null when it isn't one.
Flag? flagFrom(Object? m) {
  if (m is! Map) return null;
  final (k, a, b, c) = (m['kind'], m['start'], m['end'], m['confidence']);
  if (k is! String || a is! num || b is! num || b <= a) return null;
  return (kind: k, start: a.toDouble(), end: b.toDouble(), confidence: c is num ? c.toDouble() : null);
}

/// True when [a] and [b] overlap by at least half of the shorter one (docs/stage-manager-plan.md WP-E:
/// Studio's re-runs can shift a boundary by a rounding step, so exact matching would resurface flags).
bool overlapsHalf(double a0, double a1, double b0, double b1) =>
    min(a1, b1) - max(a0, b0) >= 0.5 * min(a1 - a0, b1 - b0);

/// [flags] that still need Ryan: not already a cut (accepted) and not dismissed (same kind).
List<Flag> pendingFlags(List<Flag> flags, List<Cut> cuts, List<Flag> dismissed) => [
      for (final f in flags)
        if (!cuts.any((c) => overlapsHalf(f.start, f.end, c.$1, c.$2)) &&
            !dismissed.any((d) => d.kind == f.kind && overlapsHalf(f.start, f.end, d.start, d.end)))
          f,
    ];

/// Library filter "Needs trim review": Studio flagged sections Ryan hasn't accepted or dismissed.
// ponytail: the app's own fallback flags need the waveform, so they only show in the trimmer, not here.
bool needsTrimReview(Song s) => pendingFlags(s.suggestions ?? const [], s.cuts, s.dismissed).isNotEmpty;

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
