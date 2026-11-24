import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'library.dart';
import 'lrc.dart';
import 'theme.dart';

/// One-screen stage mode (SPEC.md §5.4). Plays [queue] from [start]; songs are cued paused.
class StageScreen extends StatefulWidget {
  final List<Song> queue;
  final int start;
  const StageScreen({super.key, required this.queue, this.start = 0});

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

  Song get _song => widget.queue[_index];

  @override
  void initState() {
    super.initState();
    windowManager.setFullScreen(true);
    _player.onPlayerComplete.listen((_) {
      setState(() => _playing = false); // last song: stay on it, paused
      _cue(_index + 1);
    });
    // Poll position (~20 fps) so the highlight tracks the audio, not a separate clock.
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      final p = await _player.getCurrentPosition();
      if (mounted && p != null && p != _pos) setState(() => _pos = p);
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
    if (i < 0 || i >= widget.queue.length) return;
    await _player.stop();
    if (!mounted) return;
    setState(() {
      _index = i;
      _pos = Duration.zero;
      _playing = false;
    });
    await _player.setSource(DeviceFileSource(_song.audio.path));
    final d = await _player.getDuration();
    if (mounted) setState(() => _length = d ?? Duration.zero);
  }

  Future<void> _toggle() async {
    _playing ? await _player.pause() : await _player.resume();
    setState(() => _playing = !_playing);
  }

  Future<void> _back() async {
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

  Widget _lyrics(double big) {
    final lines = _song.lyrics;
    final style = TextStyle(fontSize: big, fontWeight: FontWeight.w700, height: 1.2, letterSpacing: -0.5);
    // Partially synced lyrics would mis-time, so anything not fully synced shows the title instead.
    if (_song.status != SongStatus.ready) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_song.title, style: style.copyWith(color: K.accent), textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Text('No synced lyrics yet', style: style.copyWith(fontSize: big * 0.4, color: K.muted)),
      ]);
    }
    final cur = currentLine(lines, _pos);
    final next = cur + 1 < lines.length ? lines[cur + 1] : null;
    final since = cur < 0 ? Duration.zero : lines[cur].time!;
    final toNext = next == null ? null : next.time! - _pos;
    final inBreak = next != null && next.time! - since >= _breakGap;
    final dots = inBreak && toNext! <= const Duration(seconds: _countdown) ? toNext.inSeconds + 1 : 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(height: 24, child: dots > 0 ? _Dots(dots) : null),
        const SizedBox(height: 24),
        Text(cur < 0 ? '' : lines[cur].text,
            style: style.copyWith(color: K.accent), textAlign: TextAlign.center),
        const SizedBox(height: 24),
        for (final (i, off) in [(cur + 1, 0.75), (cur + 2, 0.45)])
          if (i < lines.length)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(lines[i].text,
                  textAlign: TextAlign.center,
                  style: style.copyWith(fontSize: big * 0.55, color: K.muted.withValues(alpha: off))),
            ),
      ]),
    );
  }

  Widget _chrome() {
    final s = _song;
    final left = _length - _pos;
    final upNext = _index + 1 < widget.queue.length ? widget.queue[_index + 1].title : 'End of set';
    const dim = TextStyle(color: K.muted, fontSize: 14);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(children: [
        Row(children: [
          Icon(_playing ? Icons.graphic_eq : Icons.pause_circle_outline, color: K.accent, size: 20),
          const SizedBox(width: 10),
          Text('${s.title}  •  ${s.keyShift == 0 ? s.originalKey : shiftKey(s.originalKey, s.keyShift)}'
              '  •  ${s.tempo.toStringAsFixed(2)}x', style: dim.copyWith(color: K.text)),
          const Spacer(),
          Text('-${_fmt(left.isNegative ? Duration.zero : left)}',
              style: const TextStyle(color: K.accent, fontSize: 16, fontWeight: FontWeight.w600, fontFeatures: K.tabular)),
          const SizedBox(width: 24),
          const Text('Hold Esc to exit', style: dim),
        ]),
        const Spacer(),
        Row(children: [
          Text(_playing ? 'Space / pedal: pause' : 'Space / pedal: play', style: dim),
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

String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

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
