/// Minimal LRC parser: `[mm:ss.xx]text` lines. Multiple tags per line allowed.
/// Lines without a timestamp are kept with time = null (lyrics typed but not yet synced).
class LyricLine {
  final Duration? time;
  final String text;
  const LyricLine(this.time, this.text);
}

final _tag = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');
final _meta = RegExp(r'^\[[a-z]+:.*\]$', caseSensitive: false); // [ar:..] [ti:..] etc.

List<LyricLine> parseLrc(String source) {
  final out = <LyricLine>[];
  for (final raw in source.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || _meta.hasMatch(line)) continue;
    final tags = _tag.allMatches(line).toList();
    final text = line.replaceAll(_tag, '').trim();
    if (tags.isEmpty) {
      out.add(LyricLine(null, text));
      continue;
    }
    for (final m in tags) {
      final ms = (int.parse(m[1]!) * 60 + double.parse(m[2]!)) * 1000;
      out.add(LyricLine(Duration(milliseconds: ms.round()), text));
    }
  }
  if (out.every((l) => l.time != null)) out.sort((a, b) => a.time!.compareTo(b.time!));
  return out;
}

/// Index of the line being sung at [pos], or -1 before the first line.
int currentLine(List<LyricLine> lines, Duration pos) {
  var i = -1;
  for (var j = 0; j < lines.length; j++) {
    final t = lines[j].time;
    if (t == null || t > pos) break;
    i = j;
  }
  return i;
}

String _stamp(Duration d) {
  final cs = (d.inMilliseconds / 10).round();
  return '[${(cs ~/ 6000).toString().padLeft(2, '0')}:'
      '${(cs ~/ 100 % 60).toString().padLeft(2, '0')}.${(cs % 100).toString().padLeft(2, '0')}]';
}

String formatLrc(List<LyricLine> lines) =>
    '${lines.map((l) => l.time == null ? l.text : '${_stamp(l.time!)}${l.text}').join('\n')}\n';
