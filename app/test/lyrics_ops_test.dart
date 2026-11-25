import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/lrc.dart';
import 'package:karaoke_manager/lyrics_ops.dart';

// Synthetic lyrics only (no real song words in the repo).
const _src = '[00:01.00]one two\n[00:05.50]three\n[00:09.00]\n[00:12.25]four\n[00:20.00]five\n';
List<LyricLine> get _l => parseLrc(_src);

List<String> _times(List<LyricLine> l) => [for (final x in l) x.time == null ? '-' : '${x.time!.inMilliseconds}'];
List<String> _texts(List<LyricLine> l) => [for (final x in l) x.text];

void main() {
  test('setText keeps the time and every other line', () {
    final out = setText(_l, 1, 'THREE');
    expect(_texts(out), ['one two', 'THREE', '', 'four', 'five']);
    expect(_times(out), _times(_l));
    expect(formatLrc(out), _src.replaceFirst('three', 'THREE'));
  });

  test('setText: empty untimed line is removed, empty timed line becomes a break', () {
    final ins = insertAt(_l, 2);
    expect(setText(ins, 2, '').length, _l.length);
    expect(setText(_l, 0, '').first.isBreak, isTrue);
    expect(setText(_l, 0, '').first.time, const Duration(seconds: 1));
  });

  test('insertAt adds an untimed line, neighbours unchanged; works at start and end', () {
    final out = insertAt(_l, 2, 'new');
    expect(_times(out), ['1000', '5500', '-', '9000', '12250', '20000']);
    expect(_texts(insertAt(_l, 0, 'a')).first, 'a');
    expect(_texts(insertAt(_l, 5, 'z')).last, 'z');
    expect(insertAt(const [], 0, 'only').single.time, isNull);
  });

  test('deleteRange: single, range, whole list', () {
    expect(_times(deleteRange(_l, 1, 1)), ['1000', '9000', '12250', '20000']);
    expect(_times(deleteRange(_l, 1, 3)), ['1000', '20000']);
    expect(_times(deleteRange(_l, 0, 0)), ['5500', '9000', '12250', '20000']);
    expect(_times(deleteRange(_l, 4, 4)), ['1000', '5500', '9000', '12250']);
    expect(deleteRange(_l, 0, 4), isEmpty);
  });

  test('splitLine: first half keeps time, second untimed; no-op at either end', () {
    final out = splitLine(_l, 0, 3);
    expect(_texts(out).take(2), ['one', 'two']);
    expect(_times(out), ['1000', '-', '5500', '9000', '12250', '20000']);
    final l = _l;
    expect(identical(splitLine(l, 0, 0), l), isTrue);
    expect(identical(splitLine(l, 0, 7), l), isTrue);
  });

  test('mergeNext keeps the first time and drops the second; no-op on the last line', () {
    final out = mergeNext(_l, 3);
    expect(_texts(out), ['one two', 'three', '', 'four five']);
    expect(_times(out), ['1000', '5500', '9000', '12250']);
    final l = _l;
    expect(identical(mergeNext(l, 4), l), isTrue);
  });

  test('duplicateRange copies untimed right after the block, skips break markers', () {
    final out = duplicateRange(_l, 1, 3);
    expect(_texts(out), ['one two', 'three', '', 'four', 'three', 'four', 'five']);
    expect(_times(out), ['1000', '5500', '9000', '12250', '-', '-', '20000']);
    expect(_texts(duplicateRange(_l, 4, 4)), [..._texts(_l), 'five']); // at the end
    expect(duplicateRange(_l, 2, 2).length, _l.length); // only a break: nothing to copy
  });

  test('replaceAllText: same, more, fewer lines; breaks stay put', () {
    expect(_times(replaceAllText(_l, ['a', 'b', 'c', 'd'])), _times(_l));
    expect(_texts(replaceAllText(_l, ['a', 'b', 'c', 'd'])), ['a', 'b', '', 'c', 'd']);
    final more = replaceAllText(_l, ['a', 'b', 'c', 'd', 'e', 'f']);
    expect(_times(more), [..._times(_l), '-', '-']);
    final fewer = replaceAllText(_l, ['a', 'b']);
    expect(_texts(fewer), ['a', 'b', '']);
    expect(_times(fewer), ['1000', '5500', '9000']);
    expect(textLines(' a \r\n\r\nb\n'), ['a', 'b']);
  });

  test('untimed lines from every op round-trip through formatLrc/parseLrc', () {
    final out = duplicateRange(insertAt(splitLine(_l, 0, 3), 6, 'added'), 0, 1);
    final back = parseLrc(formatLrc(out));
    expect(_texts(back), _texts(out));
    expect(_times(back), _times(out));
  });
}
