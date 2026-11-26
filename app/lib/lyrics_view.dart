import 'package:flutter/material.dart';

import 'library.dart';
import 'lrc.dart';
import 'theme.dart';

/// Everything the lyrics screen needs, and the message the presenter sends the lyrics window ~20x a second.
/// Positions are already mapped to the original audio (`toOriginal`), so the lyrics side needs no tempo.
class LyricsState {
  final String? song; // the song's folder (its id is the folder name); null during a break
  final Duration pos; // original-audio position
  final bool blackout;
  final String breakLabel;
  final Duration? breakLeft; // non-null while a break item is on

  const LyricsState({this.song, this.pos = Duration.zero, this.blackout = false, this.breakLabel = '', this.breakLeft});

  Map<String, Object?> encode() => {
        'song': song,
        'pos_ms': pos.inMilliseconds,
        'blackout': blackout,
        'break_label': breakLabel,
        'break_left_ms': breakLeft?.inMilliseconds,
      };

  static LyricsState decode(Map<Object?, Object?> m) => LyricsState(
        song: m['song'] as String?,
        pos: Duration(milliseconds: (m['pos_ms'] as num?)?.toInt() ?? 0),
        blackout: m['blackout'] == true,
        breakLabel: m['break_label'] as String? ?? '',
        breakLeft: m['break_left_ms'] == null ? null : Duration(milliseconds: (m['break_left_ms'] as num).toInt()),
      );
}

const _breakGap = Duration(seconds: 8); // a gap this long counts as an instrumental break
const _countdown = 4; // seconds of dots before the next line

/// The line being sung at original-time [pos] (-1 before the first), and how many countdown dots
/// to show (0 = none; 4..1 in the last seconds of an instrumental gap).
({int cur, int dots}) lyricCursor(List<LyricLine> lines, Duration pos) {
  final cur = currentLine(lines, pos);
  final next = cur + 1 < lines.length ? lines[cur + 1] : null;
  final since = cur < 0 ? Duration.zero : lines[cur].time!;
  final toNext = next == null ? null : next.time! - pos;
  final inBreak = next != null && next.time! - since >= _breakGap;
  return (cur: cur, dots: inBreak && toNext! <= const Duration(seconds: _countdown) ? toNext.inSeconds + 1 : 0);
}

/// Break countdown, rounded up so it reads 15:00 at the start and only hits 0:00 when time is really up.
String breakCountdown(Duration left) => 'Break: back in ${mss(Duration(seconds: (left.inMilliseconds / 1000).ceil()))}';

/// The lyrics layout (SPEC §5.4): current line huge, next two dimmed. Used by one-screen stage mode and
/// by the lyrics window. [song] must be the song [state] names (null during a break).
class LyricsView extends StatelessWidget {
  final LyricsState state;
  final Song? song;
  const LyricsView({super.key, required this.state, required this.song});

  @override
  Widget build(BuildContext context) {
    if (state.blackout) return const SizedBox.shrink();
    final big = (MediaQuery.sizeOf(context).width / 22).clamp(36.0, 96.0);
    final style = TextStyle(fontSize: big, fontWeight: FontWeight.w700, height: 1.2, letterSpacing: -0.5);
    final s = song;
    if (state.breakLeft != null) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text(state.breakLabel, style: style.copyWith(fontSize: big * 0.5, color: K.muted)),
        const SizedBox(height: 16),
        Text(breakCountdown(state.breakLeft ?? Duration.zero),
            style: style.copyWith(color: K.accent, fontFeatures: K.tabular), textAlign: TextAlign.center),
      ]);
    }
    if (s == null) return const SizedBox.shrink(); // lyrics window: song not loaded (or unreadable)
    final lines = s.lyrics;
    // Partially synced lyrics would mis-time, so anything not fully synced shows the title instead.
    if (s.status != SongStatus.ready) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text(s.title, style: style.copyWith(color: K.accent), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Text('No synced lyrics yet', style: style.copyWith(fontSize: big * 0.4, color: K.muted)),
      ]);
    }
    final (:cur, :dots) = lyricCursor(lines, state.pos);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 24, child: dots > 0 ? Dots(dots) : null),
        const SizedBox(height: 24),
        if (cur >= 0 && lines[cur].isBreak)
          Text('♪  Instrumental', style: style.copyWith(color: K.muted, fontSize: big * 0.6))
        else
          Text(cur < 0 ? '' : lines[cur].text, style: style.copyWith(color: K.accent), textAlign: TextAlign.center),
        const SizedBox(height: 24),
        for (final (i, off) in [(cur + 1, 0.75), (cur + 2, 0.45)])
          if (i < lines.length && !lines[i].isBreak)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(lines[i].text,
                  textAlign: TextAlign.center,
                  style: style.copyWith(fontSize: big * 0.55, color: K.muted.withValues(alpha: off))),
            ),
      ]),
    );
  }
}

/// Countdown dots: [remaining] of 4 lit.
class Dots extends StatelessWidget {
  final int remaining; // 1..4
  final double size;
  const Dots(this.remaining, {super.key, this.size = 14});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              width: size,
              height: size,
              margin: EdgeInsets.symmetric(horizontal: size * 0.43),
              decoration: BoxDecoration(shape: BoxShape.circle, color: i < remaining ? K.accent : K.surface2),
            ),
        ],
      );
}
