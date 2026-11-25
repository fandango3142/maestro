import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'library.dart';
import 'lrc.dart';
import 'setlist.dart';
import 'theme.dart';

/// One-screen stage mode (SPEC.md §5.4). Plays [items] (songs and breaks) from [start];
/// songs are cued paused. Every song item's id must be in [songs].
class StageScreen extends StatefulWidget {
  final List<SetItem> items;
  final Map<String, Song> songs;
  final int start;
  final Duration changeover;
  const StageScreen(
      {super.key, required this.items, required this.songs, this.start = 0, this.changeover = Duration.zero});

  /// Library launch: a plain song queue, no breaks or overrides.
  StageScreen.queue(List<Song> queue, {Key? key, int start = 0})
      : this(key: key, items: [for (final s in queue) SetItem.song(s.id)], songs: {for (final s in queue) s.id: s}, start: start);

  @override
  State<StageScreen> createState() => _StageScreenState();
}

class _StageScreenState extends State<StageScreen> {
  static const _hold = Duration(seconds: 1);
  static const _breakGap = Duration(seconds: 8); // a gap this long counts as an instrumental break
  static const _countdown = 4; // seconds of dots before the next line

  final _player = AudioPlayer();
  final _holds = <LogicalKeyboardKey, Timer>{};
  late int _index = widget.start;
  Duration _pos = Duration.zero, _length = Duration.zero;
  bool _playing = false, _blackout = false, _overlay = true;
  Timer? _poll, _overlayTimer;
  DateTime? _breakEnds; // set while a break item is cued

  SetItem get _item => widget.items[_index];
  Song get _song => widget.songs[_item.songId]!; // only valid when !_item.isBreak
  int get _keyShift => _item.keyShift ?? _song.keyShift; // ponytail: shown only; WP-C plays the override
  late final _plan = planTimes(widget.items, (id) => widget.songs[id]?.playedDuration, Duration.zero, widget.changeover);

  @override
  void initState() {
    super.initState();
    windowManager.setFullScreen(true);
    _player.setReleaseMode(ReleaseMode.stop); // keep the file loaded so restart works after the end
    _player.onPlayerComplete.listen((_) {
      setState(() => _playing = false); // last song: stay on it, paused
      _cue(_index + 1);
    });
    // Poll position (~20 fps) so the highlight tracks the audio, not a separate clock.
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      final p = await _player.getCurrentPosition();
      if (mounted && p != null && p != _pos) setState(() => _pos = p);
      if (mounted && _item.isBreak) setState(() {}); // tick the break countdown
    });
    _cue(_index);
    _wake();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _overlayTimer?.cancel();
    for (final t in _holds.values) {
      t.cancel();
    }
    _player.dispose();
    windowManager.setFullScreen(false);
    super.dispose();
  }

  Future<void> _cue(int i) async {
    if (i < 0 || i >= widget.items.length) return;
    await _player.stop();
    if (!mounted) return;
    setState(() {
      _index = i;
      _pos = Duration.zero;
      _playing = false;
      _breakEnds = _item.isBreak ? DateTime.now().add(Duration(minutes: _item.minutes)) : null;
      if (_item.isBreak) _length = Duration(minutes: _item.minutes);
    });
    if (_item.isBreak) return; // audio stays stopped through a break
    await _player.setSource(DeviceFileSource(_song.audio.path));
    final d = await _player.getDuration();
    if (mounted) setState(() => _length = d ?? Duration.zero);
  }

  Future<void> _toggle() async {
    if (_item.isBreak) return _cue(_index + 1); // pedal tap during a break = bring on the next song
    _playing ? await _player.pause() : await _player.resume();
    setState(() => _playing = !_playing);
  }

  Future<void> _back() async {
    if (_item.isBreak) return _cue(_index == 0 ? 0 : _index - 1);
    if (_pos > const Duration(seconds: 3) || _index == 0) {
      await _player.seek(Duration.zero);
      setState(() => _pos = Duration.zero);
    } else {
      await _cue(_index - 1);
    }
  }

  void _wake() {
    setState(() => _overlay = true);
    _overlayTimer?.cancel();
    _overlayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _overlay = false);
    });
  }

  /// Taps act at once; skip/back/exit need a 1s hold so a stray press can't wreck a song.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyRepeatEvent) return KeyEventResult.handled;
    final k = e.logicalKey;
    if (e is KeyDownEvent) {
      _wake();
      void hold(VoidCallback action) => _holds[k] = Timer(_hold, action);
      switch (k) {
        case LogicalKeyboardKey.space:
          _toggle();
        case LogicalKeyboardKey.keyB:
          setState(() => _blackout = !_blackout);
        case LogicalKeyboardKey.pageDown || LogicalKeyboardKey.arrowRight:
          hold(() => _cue(_index + 1));
        case LogicalKeyboardKey.pageUp || LogicalKeyboardKey.arrowLeft:
          hold(_back);
        case LogicalKeyboardKey.escape:
          hold(() => Navigator.of(context).pop());
        default:
          return KeyEventResult.ignored;
      }
    } else if (e is KeyUpEvent) {
      final t = _holds.remove(k);
      // A short PageDown press is the pedal's play/pause.
      if (t != null && t.isActive) {
        t.cancel();
        if (k == LogicalKeyboardKey.pageDown) _toggle();
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final big = (size.width / 22).clamp(36.0, 96.0);
    return Scaffold(
      backgroundColor: K.bg,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _wake(),
          child: Stack(children: [
            if (!_blackout) Center(child: _lyrics(big)),
            AnimatedOpacity(
              opacity: _overlay && !_blackout ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: _chrome(),
            ),
          ]),
        ),
      ),
    );
  }

  Duration get _breakLeft {
    final left = _breakEnds?.difference(DateTime.now()) ?? Duration.zero;
    return left.isNegative ? Duration.zero : left;
  }

  Widget _lyrics(double big) {
    final style = TextStyle(fontSize: big, fontWeight: FontWeight.w700, height: 1.2, letterSpacing: -0.5);
    if (_item.isBreak) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_item.label, style: style.copyWith(fontSize: big * 0.5, color: K.muted)),
        const SizedBox(height: 16),
        // Round up so it reads 15:00 at the start and only hits 0:00 when time is really up.
        Text('Break: back in ${mss(Duration(seconds: (_breakLeft.inMilliseconds / 1000).ceil()))}',
            style: style.copyWith(color: K.accent, fontFeatures: K.tabular), textAlign: TextAlign.center),
      ]);
    }
    final lines = _song.lyrics;
    // Partially synced lyrics would mis-time, so anything not fully synced shows the title instead.
    if (_song.status != SongStatus.ready) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_song.title, style: style.copyWith(color: K.accent), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Text('No synced lyrics yet', style: style.copyWith(fontSize: big * 0.4, color: K.muted)),
      ]);
    }
    final pos = toOriginal(_pos, _song); // lyric times are stored against the original audio
    final cur = currentLine(lines, pos);
    final next = cur + 1 < lines.length ? lines[cur + 1] : null;
    final since = cur < 0 ? Duration.zero : lines[cur].time!;
    final toNext = next == null ? null : next.time! - pos;
    final inBreak = next != null && next.time! - since >= _breakGap;
    final dots = inBreak && toNext! <= const Duration(seconds: _countdown) ? toNext.inSeconds + 1 : 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 24, child: dots > 0 ? _Dots(dots) : null),
        const SizedBox(height: 24),
        if (cur >= 0 && lines[cur].isBreak)
          Text('♪  Instrumental', style: style.copyWith(color: K.muted, fontSize: big * 0.6))
        else
          Text(cur < 0 ? '' : lines[cur].text,
              style: style.copyWith(color: K.accent), textAlign: TextAlign.center),
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

  String _title(SetItem i) => i.isBreak ? i.label : widget.songs[i.songId]!.title;

  Widget _chrome() {
    final brk = _item.isBreak;
    final elapsed = brk ? _length - _breakLeft : _pos;
    final left = _length - elapsed;
    final setLeft = _plan.total - _plan.starts[_index] - elapsed;
    final upNext = _index + 1 < widget.items.length ? _title(widget.items[_index + 1]) : 'End of set';
    const dim = TextStyle(color: K.muted, fontSize: 14);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(children: [
        Row(children: [
          Icon(brk ? Icons.coffee : (_playing ? Icons.graphic_eq : Icons.pause_circle_outline),
              color: K.accent, size: 20),
          const SizedBox(width: 10),
          Text(
              brk
                  ? _item.label
                  : '${_song.title}  •  ${shiftKey(_song.originalKey, _keyShift)}'
                      '  •  ${_song.tempo.toStringAsFixed(2)}x',
              style: dim.copyWith(color: K.text)),
          const Spacer(),
          Text('-${mss(left.isNegative ? Duration.zero : left)}',
              style: const TextStyle(color: K.accent, fontSize: 16, fontWeight: FontWeight.w600, fontFeatures: K.tabular)),
          const SizedBox(width: 16),
          Text('Set -${mss(setLeft.isNegative ? Duration.zero : setLeft)}',
              style: dim.copyWith(fontFeatures: K.tabular)),
          const SizedBox(width: 24),
          const Text('Hold Esc to exit', style: dim),
        ]),
        const Spacer(),
        Row(children: [
          Text(brk ? 'Space / pedal: next song' : (_playing ? 'Space / pedal: pause' : 'Space / pedal: play'),
              style: dim),
          const SizedBox(width: 24),
          const Text('Hold → next  •  Hold ← restart  •  B blackout', style: dim),
          const Spacer(),
          const Icon(Icons.queue_music, color: K.muted, size: 18),
          const SizedBox(width: 8),
          Text('Up next: $upNext', style: dim),
        ]),
      ]),
    );
  }
}

class _Dots extends StatelessWidget {
  final int remaining; // 1..4
  const _Dots(this.remaining);

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              width: 14,
              height: 14,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < remaining ? K.accent : K.surface2,
              ),
            ),
        ],
      );
}
