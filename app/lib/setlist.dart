import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// One row of a setlist: a song (`id`) or a timed break (`break: true`). Wraps the raw JSON map,
/// so fields this version doesn't know about survive a save.
class SetItem {
  final Map<String, dynamic> json;
  SetItem(this.json);
  SetItem.song(String id) : json = {'id': id, 'key_shift': null, 'notes': ''};
  SetItem.pause({int minutes = 15, String label = 'Break'})
      : json = {'break': true, 'minutes': minutes, 'label': label};

  bool get isBreak => json['break'] == true;
  String get songId => json['id'] as String? ?? '';
  int get minutes => max(0, (json['minutes'] as num?)?.toInt() ?? 0);
  String get label => json['label'] as String? ?? 'Break';
  int? get keyShift => (json['key_shift'] as num?)?.toInt(); // null = the song's default
  String get notes => json['notes'] as String? ?? '';
}

/// `setlists/<id>.json` (docs/stage-manager-plan.md, Shared contracts).
class Setlist {
  final File file;
  final Map<String, dynamic> json;
  final List<SetItem> items;
  Setlist(this.file, this.json)
      : items = [for (final i in json['items'] as List? ?? const []) SetItem(Map<String, dynamic>.from(i as Map))];

  String get id => file.uri.pathSegments.last.replaceAll(RegExp(r'\.json$'), '');
  String get name => json['name'] as String? ?? id;
  String get date => json['date'] as String? ?? '';
  String get venue => json['venue'] as String? ?? '';
  String get startTime => json['start_time'] as String? ?? '';
  int get changeoverS => (json['changeover_s'] as num?)?.toInt() ?? 30;

  static Setlist load(File f) => Setlist(f, jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);

  /// Atomic: write `<file>.tmp`, then rename over the original.
  void save() {
    json['items'] = [for (final i in items) i.json];
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    tmp.renameSync(file.path);
  }
}

Directory _dir(Directory root) => Directory('${root.path}/setlists');

/// All readable setlists, by name. A corrupt file is skipped, not fatal.
List<Setlist> listSetlists(Directory root) {
  final d = _dir(root);
  if (!d.existsSync()) return [];
  final out = <Setlist>[];
  for (final f in d.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
    try {
      out.add(Setlist.load(f));
    } on Object {
      // ponytail: a broken setlist file is silently hidden; surface it if that ever happens for real.
    }
  }
  return out..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// "Friday Konkani & Retro" -> "friday-konkani-retro".
String slug(String name) {
  final s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return s.isEmpty ? 'setlist' : s;
}

/// New file named after [name] (with -2, -3… if taken). [from] copies another setlist's contents.
Setlist createSetlist(Directory root, String name, {Setlist? from}) {
  final d = _dir(root)..createSync(recursive: true);
  final base = slug(name);
  var id = base;
  for (var n = 2; File('${d.path}/$id.json').existsSync(); n++) {
    id = '$base-$n';
  }
  final json = from == null
      ? <String, dynamic>{
          'schema_version': 1, 'name': name, 'date': '', 'venue': '',
          'start_time': '', 'changeover_s': 30, 'items': <Object>[],
        }
      : jsonDecode(jsonEncode({...from.json, 'items': [for (final i in from.items) i.json]})) as Map<String, dynamic>;
  json['name'] = name;
  return Setlist(File('${d.path}/$id.json'), json)..save();
}

/// "20:00" -> 20h. Null when empty or not a valid 24h time.
Duration? parseClock(String s) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(s.trim());
  if (m == null) return null;
  final h = int.parse(m[1]!), min = int.parse(m[2]!);
  if (h > 23 || min > 59) return null;
  return Duration(hours: h, minutes: min);
}

/// Time of day (wraps past midnight) -> "8:14 pm".
String formatClock(Duration t) {
  final mins = t.inMinutes % (24 * 60);
  final h = mins ~/ 60, m = mins % 60;
  return '${h % 12 == 0 ? 12 : h % 12}:${m.toString().padLeft(2, '0')} ${h < 12 ? 'am' : 'pm'}';
}

/// Start of each item (= [start] + offset) and the set's total length.
/// A song lasts `durationOf(id)` (null/missing = 0). Changeover follows a song only when the
/// next item is also a song. A break lasts its minutes, with no changeover either side.
({List<Duration> starts, Duration total}) planTimes(
    List<SetItem> items, Duration? Function(String id) durationOf, Duration start, Duration changeover) {
  final starts = <Duration>[];
  var t = Duration.zero;
  for (final (i, item) in items.indexed) {
    starts.add(start + t);
    if (item.isBreak) {
      t += Duration(minutes: item.minutes);
    } else {
      t += durationOf(item.songId) ?? Duration.zero;
      if (i + 1 < items.length && !items[i + 1].isBreak) t += changeover;
    }
  }
  return (starts: starts, total: t);
}
