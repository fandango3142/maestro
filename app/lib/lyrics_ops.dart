import 'lrc.dart';

/// Pure lyric-list edits for the editor (SPEC.md §5.2). Each returns a new list and never
/// changes the time of any line it doesn't name. New lines are untimed until tapped.

/// Set line [i]'s text, keeping its time. An untimed line left empty is removed
/// (e.g. an inserted line that was never typed into).
List<LyricLine> setText(List<LyricLine> lines, int i, String text) {
  final out = [...lines];
  if (text.isEmpty && out[i].time == null) return out..removeAt(i);
  out[i] = LyricLine(out[i].time, text);
  return out;
}

/// Insert an untimed line with [text] at index [at].
List<LyricLine> insertAt(List<LyricLine> lines, int at, [String text = '']) =>
    [...lines]..insert(at, LyricLine(null, text));

/// Remove lines [a]..[b] inclusive.
List<LyricLine> deleteRange(List<LyricLine> lines, int a, int b) => [...lines]..removeRange(a, b + 1);

/// Split line [i] at character [at]: the first half keeps the time, the second is untimed.
/// No-op if either half would be empty.
List<LyricLine> splitLine(List<LyricLine> lines, int i, int at) {
  final t = lines[i].text;
  final first = t.substring(0, at).trim(), second = t.substring(at).trim();
  if (first.isEmpty || second.isEmpty) return lines;
  return [...lines]
    ..[i] = LyricLine(lines[i].time, first)
    ..insert(i + 1, LyricLine(null, second));
}

/// Join line [i] with the next one, keeping line [i]'s time. No-op on the last line or
/// when either is a break marker (words would jump to the break's time).
List<LyricLine> mergeNext(List<LyricLine> lines, int i) {
  if (i + 1 >= lines.length || lines[i].isBreak || lines[i + 1].isBreak) return lines;
  final text = '${lines[i].text} ${lines[i + 1].text}'.trim();
  return [...lines]
    ..[i] = LyricLine(lines[i].time, text)
    ..removeAt(i + 1);
}

/// Copies of lines [a]..[b], untimed, inserted right after [b] (a repeated chorus).
/// Break markers aren't copied: an untimed break has no meaning, press B while tapping instead.
List<LyricLine> duplicateRange(List<LyricLine> lines, int a, int b) => [...lines]
  ..insertAll(b + 1, [
    for (final l in lines.sublist(a, b + 1))
      if (!l.isBreak) LyricLine(null, l.text),
  ]);

/// Words of [text], one per non-blank line, as "Replace all text" sees them.
List<String> textLines(String text) =>
    text.split(RegExp(r'\r?\n')).map((t) => t.trim()).where((t) => t.isNotEmpty).toList();

/// Replace every lyric's words with [texts], matched in order: the first N lyric lines keep
/// their times, extra texts are appended untimed, and leftover old lyric lines are removed.
/// Break markers stay where they are (they have no words to replace).
List<LyricLine> replaceAllText(List<LyricLine> lines, List<String> texts) {
  final out = <LyricLine>[];
  var k = 0;
  for (final l in lines) {
    if (l.isBreak) {
      out.add(l);
    } else if (k < texts.length) {
      out.add(LyricLine(l.time, texts[k++]));
    }
  }
  return out..addAll([for (; k < texts.length; k++) LyricLine(null, texts[k])]);
}
