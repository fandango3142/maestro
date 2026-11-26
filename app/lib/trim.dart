import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library.dart';
import 'lrc.dart';
import 'render.dart';
import 'theme.dart';

// ponytail: thresholds are first guesses from the plan, not tuned on real songs yet.
const _quiet = 0.005623; // −45 dBFS RMS: "silent" lead-in / tail
const _voice = 0.01778; // −35 dBFS RMS on the vocal stem: someone is singing or talking
const _lineHold = 8.0; // a synced line covers at most this many seconds (stage's instrumental-break gap)

/// The app's own flags when Studio wrote none (SPEC §5.2), from [backing] and [vocals] RMS at [rate]
/// bins/s: a lead-in or tail where the full mix stays under −45 dBFS for ≥ 1.5 s is `silence`;
/// vocal-stem energy for ≥ 2 s (gaps under 0.5 s bridged) that no synced lyric line covers is `speech`.
/// No timed lyrics, no speech flags (everything would look like talk).
List<Flag> fallbackFlags(Float32List backing, Float32List vocals, List<LyricLine> lyrics, {int rate = peaksPerSecond}) {
  final n = backing.length;
  final out = <Flag>[];
  Flag flag(String kind, int a, int b) => (kind: kind, start: a / rate, end: b / rate, confidence: null);

  double v(int i) => i < vocals.length ? vocals[i] : 0;
  bool silent(int i) => sqrt(backing[i] * backing[i] + v(i) * v(i)) < _quiet; // uncorrelated stems
  var lead = 0, tail = n;
  while (lead < n && silent(lead)) {
    lead++;
  }
  while (tail > lead && silent(tail - 1)) {
    tail--;
  }
  if (lead >= 1.5 * rate) out.add(flag('silence', 0, lead));
  if (n - tail >= 1.5 * rate) out.add(flag('silence', tail, n));

  final timed = [for (final l in lyrics) if (l.time != null) l]..sort((a, b) => a.time!.compareTo(b.time!));
  if (!timed.any((l) => !l.isBreak)) return out;
  final covered = List.filled(n, false);
  for (final (i, l) in timed.indexed) {
    if (l.isBreak) continue;
    final t = l.time!.inMicroseconds / 1e6;
    final next = i + 1 < timed.length ? timed[i + 1].time!.inMicroseconds / 1e6 : double.infinity;
    for (var b = (t * rate).floor(); b < min(n, (min(next, t + _lineHold) * rate).ceil()); b++) {
      covered[max(0, b)] = true;
    }
  }
  final gap = rate ~/ 2;
  int? start;
  var last = -gap - 1;
  void close() {
    if (start != null && last + 1 - start >= 2 * rate) out.add(flag('speech', start, last + 1));
  }
  for (var i = 0; i < n; i++) {
    if (v(i) < _voice || covered[i]) continue;
    if (i - last > gap) {
      close();
      start = i;
    }
    last = i;
  }
  close();
  return out;
}

/// How many lyric lines start inside [cuts]: stage never reaches them.
int linesInCuts(List<LyricLine> lyrics, List<Cut> cuts) => lyrics.where((l) {
      final t = l.time == null ? null : l.time!.inMicroseconds / 1e6;
      return t != null && !l.isBreak && cuts.any((c) => t >= c.$1 && t < c.$2);
    }).length;

/// Where the trimmer gets its waveform. Not final only so widget tests can swap in synthetic peaks.
Future<Peaks> Function(Song) loadPeaks = ensurePeaks;

/// Audio trimmer (SPEC §5.2, docs/stage-manager-plan.md WP-E): the waveform with flagged sections to
/// accept or dismiss, and manual cuts. Every change saves at once (song.json `cuts` /
/// `dismissed_suggestions`); the caller queues the render when this closes.
class TrimScreen extends StatefulWidget {
  final Song song;
  const TrimScreen({super.key, required this.song});

  @override
  State<TrimScreen> createState() => _TrimScreenState();
}

class _TrimScreenState extends State<TrimScreen> {
  final _player = AudioPlayer();
  final _keys = FocusNode();
  Timer? _poll;
  Duration _pos = Duration.zero;
  bool _playing = false, _skipCuts = true, _loaded = false;
  Peaks? _peaks;
  String? _error;
  List<Flag> _fallback = const [];
  late List<Cut> _cuts = _s.cuts; // live while a handle is dragged; saved on release
  Cut? _sel; // dragged selection, seconds
  int? _picked; // selected cut
  (int, bool)? _edge; // cut being resized, and whether it's the start
  double? _anchor;

  Song get _s => widget.song;
  double get _len => _s.duration != null
      ? _s.duration!.inMicroseconds / 1e6
      : (_peaks == null ? 1 : max(1, _peaks!.backing.length / peaksPerSecond));
  double get _now => _pos.inMicroseconds / 1e6;
  List<Flag> get _flags => pendingFlags(_s.suggestions ?? _fallback, _cuts, _s.dismissed);

  @override
  void initState() {
    super.initState();
    _player.setReleaseMode(ReleaseMode.stop);
    _player.onPlayerComplete.listen((_) => setState(() => _playing = false));
    _load();
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      final p = await _player.getCurrentPosition();
      if (!mounted || p == null) return;
      if (p != _pos) setState(() => _pos = p);
      // ponytail: the preview skips a cut by seeking (no crossfade); the stage render crossfades.
      final t = _now;
      final c = _cuts.where((c) => t >= c.$1 && t < c.$2 - 0.05).firstOrNull;
      if (_skipCuts && _playing && c != null) _seek(c.$2);
    });
  }

  /// The song with vocals when it can be mixed (dialogue is in the vocal stem), else the backing track.
  Future<void> _load() async {
    try {
      _peaks = await loadPeaks(_s);
      if (_s.suggestions == null) _fallback = fallbackFlags(_peaks!.backing, _peaks!.vocals, _s.lyrics);
    } on Object catch (e) {
      _error = 'Could not read the audio: $e';
    }
    File? mix;
    try {
      mix = await ensureGuideMix(_s);
    } on Object catch (_) {
      mix = null;
    }
    if (!mounted) return;
    await _player.setSource(DeviceFileSource((mix ?? _s.original).path));
    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _player.dispose();
    _keys.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    _playing ? await _player.pause() : await _player.resume();
    if (mounted) setState(() => _playing = !_playing);
  }

  Future<void> _seek(double sec) async {
    final d = Duration(microseconds: (sec.clamp(0, _len) * 1e6).round());
    await _player.seek(d);
    if (mounted) setState(() => _pos = d);
  }

  Future<void> _playFrom(double sec) async {
    await _seek(sec);
    if (!_playing) await _toggle();
  }

  Future<void> _save(Map<String, Object?> changes) async {
    try {
      await saveSongFields(_s, changes);
    } on Object catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
    if (mounted) setState(() => _cuts = _s.cuts);
  }

  double _ms(double v) => (v * 1000).round() / 1000;

  void _setCuts(List<Cut> cuts) {
    final n = normalizeCuts(cuts);
    setState(() {
      _sel = null;
      _picked = null;
      _cuts = n;
    });
    _save({'cuts': [for (final c in n) [_ms(c.$1), _ms(c.$2)]]});
  }

  void _addCut(double a, double b) {
    final c = (max(0.0, min(a, b)), min(_len, max(a, b)));
    if (c.$2 - c.$1 < 0.05) return;
    // Never cut the whole song: the render would have nothing left.
    final left = _len - normalizeCuts([..._cuts, c]).fold(0.0, (s, c) => s + c.$2 - c.$1);
    if (left < 1) return;
    _setCuts([..._cuts, c]);
  }

  void _dismiss(Flag f) {
    final raw = _s.json['dismissed_suggestions'];
    _save({
      'dismissed_suggestions': [
        if (raw is List) ...raw,
        {'kind': f.kind, 'start': _ms(f.start), 'end': _ms(f.end)},
      ],
    });
  }

  void _removePicked() {
    final i = _picked;
    if (i != null && i < _cuts.length) _setCuts([..._cuts]..removeAt(i));
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.space:
        _toggle();
      case LogicalKeyboardKey.keyX when _sel != null:
        _addCut(_sel!.$1, _sel!.$2);
      case LogicalKeyboardKey.delete || LogicalKeyboardKey.backspace when _picked != null:
        _removePicked();
      case LogicalKeyboardKey.arrowLeft:
        _seek(_now - 5);
      case LogicalKeyboardKey.arrowRight:
        _seek(_now + 5);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // Waveform gestures. x in pixels across [w].
  double _sec(double x, double w) => (x / w).clamp(0.0, 1.0) * _len;

  void _dragStart(double x, double w) {
    final grab = 8 / w * _len; // 8 px
    final t = _sec(x, w);
    for (final (i, c) in _cuts.indexed) {
      final near = (t - c.$1).abs() < grab ? true : ((t - c.$2).abs() < grab ? false : null);
      if (near != null) {
        return setState(() {
          _edge = (i, near);
          _picked = i;
        });
      }
    }
    setState(() {
      _anchor = t;
      _sel = (t, t);
      _picked = null;
    });
  }

  void _dragUpdate(double x, double w) {
    final t = _sec(x, w);
    setState(() {
      if (_edge case (final i, final start)) {
        final c = _cuts[i];
        _cuts = [..._cuts]..[i] = start ? (min(t, c.$2 - 0.05), c.$2) : (c.$1, max(t, c.$1 + 0.05));
      } else if (_anchor != null) {
        _sel = (min(_anchor!, t), max(_anchor!, t));
      }
    });
  }

  void _dragEnd() {
    if (_edge != null) _setCuts(_cuts);
    _edge = null;
    _anchor = null;
    if (_sel != null && _sel!.$2 - _sel!.$1 < 0.05) setState(() => _sel = null);
  }

  void _tap(double x, double w) {
    final t = _sec(x, w);
    final i = _cuts.indexWhere((c) => t >= c.$1 && t <= c.$2);
    setState(() {
      _picked = i < 0 ? null : i;
      _sel = null;
    });
    final f = _flags.where((f) => t >= f.start && t <= f.end).firstOrNull;
    f != null ? _playFrom(f.start - 1) : _seek(t); // a flag plays from 1 s before it
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final flags = _flags;
    final inCuts = linesInCuts(s.lyrics, _cuts);
    return Scaffold(
      body: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconButton(onPressed: () => Navigator.maybePop(context), icon: const Icon(Icons.arrow_back)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Trim  ·  ${s.title}',
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
                  Text(
                      'Original ${mss(s.duration)}  →  plays ${mss(s.playedDurationAt(s.tempo, cuts: _cuts))} at '
                      '${s.tempo.toStringAsFixed(2)}x  •  ${s.suggestions == null ? 'Flags: app guesses (no Studio scan)' : 'Flags: Studio'}'
                      '  •  Changes save at once; stage plays them after the render',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: K.muted)),
                ]),
              ),
            ]),
            const SizedBox(height: 16),
            _transport(),
            const SizedBox(height: 12),
            SizedBox(height: 170, child: _waveform(flags)),
            const SizedBox(height: 12),
            _tools(),
            if (inCuts > 0) ...[
              const SizedBox(height: 8),
              Text('$inCuts lyric line${inCuts == 1 ? ' starts' : 's start'} inside a cut and won\'t be sung: '
                  'delete ${inCuts == 1 ? 'it' : 'them'} in the lyrics editor, or shorten the cut.',
                  style: const TextStyle(color: K.accent)),
            ],
            const SizedBox(height: 12),
            Expanded(child: _list(flags)),
          ]),
        ),
      ),
    );
  }

  Widget _transport() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          FilledButton(
              onPressed: _loaded ? _toggle : null, child: Icon(_playing ? Icons.pause : Icons.play_arrow)),
          const SizedBox(width: 16),
          Text('${_fmt(_now)} / ${_fmt(_len)}', style: const TextStyle(fontFeatures: K.tabular)),
          const SizedBox(width: 24),
          Checkbox(value: _skipCuts, onChanged: (v) => setState(() => _skipCuts = v ?? true)),
          const Text('Skip cuts while playing'),
          Expanded(
            child: Text(
                _loaded
                    ? 'Space play  •  ← → 5 s  •  Drag to select, X cut  •  Drag a cut edge to adjust  •  Click a cut, Delete removes'
                    : 'Loading audio…',
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: K.muted, fontSize: 12)),
          ),
        ]),
      );

  Widget _waveform(List<Flag> flags) {
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: K.muted)));
    if (_peaks == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(builder: (_, box) {
      final w = box.maxWidth;
      return GestureDetector(
        key: const Key('waveform'),
        dragStartBehavior: DragStartBehavior.down, // select from where the mouse went down, not after the slop
        onTapUp: (d) => _tap(d.localPosition.dx, w),
        onHorizontalDragStart: (d) => _dragStart(d.localPosition.dx, w),
        onHorizontalDragUpdate: (d) => _dragUpdate(d.localPosition.dx, w),
        onHorizontalDragEnd: (_) => _dragEnd(),
        child: CustomPaint(
          size: Size(w, box.maxHeight),
          painter: _Wave(_peaks!, _len, _cuts, flags, _sel, _picked, _now),
        ),
      );
    });
  }

  Widget _tools() => Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
            onPressed: _sel == null ? null : () => _addCut(_sel!.$1, _sel!.$2),
            icon: const Icon(Icons.content_cut, size: 18),
            label: Text(_sel == null ? 'Drag on the waveform to select' : 'Cut ${_span(_sel!.$1, _sel!.$2)}  (X)')),
        OutlinedButton.icon(
            onPressed: () => _addCut(0, _now),
            icon: const Icon(Icons.first_page, size: 18),
            label: const Text('Trim start to playhead')),
        OutlinedButton.icon(
            onPressed: () => _addCut(_now, _len),
            icon: const Icon(Icons.last_page, size: 18),
            label: const Text('Trim end from playhead')),
      ]);

  Widget _list(List<Flag> flags) {
    Widget row(IconData icon, Color color, String text, List<Widget> actions) => SizedBox(
          height: 44,
          child: Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFeatures: K.tabular))),
            ...actions,
          ]),
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
      child: flags.isEmpty && _cuts.isEmpty
          ? const Center(child: Text('Nothing flagged and no cuts.', style: TextStyle(color: K.muted)))
          : ListView(children: [
              for (final f in flags)
                row(Icons.flag, K.accent, '${_flagLabel(f)}  ·  ${_span(f.start, f.end)}  ·  flagged for review', [
                  TextButton(onPressed: () => _playFrom(f.start - 1), child: const Text('Play')),
                  TextButton(onPressed: () => _addCut(f.start, f.end), child: const Text('Accept (cut)')),
                  TextButton(onPressed: () => _dismiss(f), child: const Text('Dismiss')),
                ]),
              for (final (i, c) in _cuts.indexed)
                row(Icons.content_cut, i == _picked ? K.accent : K.muted, 'Cut  ·  ${_span(c.$1, c.$2)}', [
                  TextButton(onPressed: () => _playFrom(c.$1 - 3), child: const Text('Play across')),
                  TextButton(onPressed: () => _setCuts([..._cuts]..removeAt(i)), child: const Text('Remove')),
                ]),
            ]),
    );
  }
}

String _flagLabel(Flag f) {
  final what = f.kind == 'silence' ? 'Silence' : (f.confidence == null ? 'Possible speech' : 'Speech');
  return f.confidence == null ? what : '$what ${(f.confidence! * 100).round()}%';
}

String _span(double a, double b) => '${_fmt(a, cs: true)}–${_fmt(b, cs: true)} (${(b - a).toStringAsFixed(1)} s)';

String _fmt(double sec, {bool cs = false}) {
  final d = Duration(milliseconds: (sec * 1000).round());
  final s = '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  return cs ? '$s.${(d.inMilliseconds % 1000 ~/ 100)}' : s;
}

/// Backing track solid, vocal stem faint on top, cuts dimmed with handles, flags amber with a label.
class _Wave extends CustomPainter {
  final Peaks peaks;
  final double len, now;
  final List<Cut> cuts;
  final List<Flag> flags;
  final Cut? sel;
  final int? picked;
  _Wave(this.peaks, this.len, this.cuts, this.flags, this.sel, this.picked, this.now);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, mid = h / 2;
    double x(double sec) => sec / len * w;
    canvas.drawRect(Offset.zero & size, Paint()..color = K.surface1);
    // Loudest bin fills the height; one bar per pixel column (the max of its bins).
    final top = [...peaks.backing, ...peaks.vocals].fold(1e-6, max);
    void bars(Float32List v, Paint p) {
      for (var px = 0; px < w; px++) {
        final a = (px / w * len * peaksPerSecond).floor(), b = ((px + 1) / w * len * peaksPerSecond).ceil();
        var m = 0.0;
        for (var i = max(0, a); i < min(v.length, max(a + 1, b)); i++) {
          m = max(m, v[i]);
        }
        final y = m / top * mid * 0.95;
        canvas.drawLine(Offset(px + 0.5, mid - y), Offset(px + 0.5, mid + y), p);
      }
    }

    bars(peaks.backing, Paint()..color = K.muted);
    bars(peaks.vocals, Paint()..color = K.text.withValues(alpha: 0.35));
    for (final f in flags) {
      final r = Rect.fromLTRB(x(f.start), 0, x(f.end), h);
      canvas.drawRect(r, Paint()..color = K.accent.withValues(alpha: 0.22));
      canvas.drawRect(r, Paint()..color = K.accent..style = PaintingStyle.stroke);
      (TextPainter(
              text: TextSpan(
                  text: _flagLabel(f), style: const TextStyle(color: K.accent, fontSize: 11, fontWeight: FontWeight.w600)),
              textDirection: TextDirection.ltr)
            ..layout())
          .paint(canvas, Offset(r.left + 4, 4));
    }
    for (final (i, c) in cuts.indexed) {
      final r = Rect.fromLTRB(x(c.$1), 0, x(c.$2), h);
      canvas.drawRect(r, Paint()..color = K.bg.withValues(alpha: 0.75));
      final edge = Paint()
        ..color = i == picked ? K.accent : K.text
        ..strokeWidth = 3;
      canvas.drawLine(r.topLeft, r.bottomLeft, edge);
      canvas.drawLine(r.topRight, r.bottomRight, edge);
    }
    if (sel case final s?) {
      canvas.drawRect(Rect.fromLTRB(x(s.$1), 0, x(s.$2), h), Paint()..color = K.text.withValues(alpha: 0.15));
    }
    canvas.drawLine(Offset(x(now), 0), Offset(x(now), h), Paint()..color = K.accent..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_Wave o) =>
      o.peaks != peaks || o.len != len || o.now != now || o.cuts != cuts || o.flags != flags || o.sel != sel ||
      o.picked != picked;
}
