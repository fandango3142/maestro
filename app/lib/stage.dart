import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import 'library.dart';
import 'lyrics_view.dart';
import 'lyrics_window.dart';
import 'presenter.dart';
import 'render.dart';
import 'setlist.dart';
import 'theme.dart';

/// Stage mode (SPEC.md §5.4). Plays [items] (songs and breaks) from [start]; songs are cued paused.
/// Every song item's id must be in [songs]. One display: the one-screen lyrics layout. Two: lyrics go
/// fullscreen on the external display (lyrics_window.dart) and this window shows the presenter view.
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

  final _player = AudioPlayer();
  final _holds = <LogicalKeyboardKey, Timer>{};
  late int _index = widget.start;
  Duration _pos = Duration.zero, _length = Duration.zero;
  bool _playing = false, _blackout = false, _overlay = true;
  Timer? _poll, _overlayTimer, _screens, _fade;
  DateTime? _breakEnds; // set while a break item is cued
  LyricsWindow? _win; // non-null = two-screen layout
  bool _opening = false;
  int _displays = 1;
  DateTime? _firstPlay; // when Ryan first pressed play in this show (ahead/behind counts from here)
  int _firstIndex = 0;

  SetItem get _item => widget.items[_index];
  Song get _song => widget.songs[_item.songId]!; // only valid when !_item.isBreak
  int _shiftOf(SetItem i) => i.keyShift ?? widget.songs[i.songId]!.keyShift; // gig override, else the song's
  late Playback _play; // what the player has loaded (set in _cue)
  // Lengths of what will really play: a song falling back to its original runs at 1.0x.
  // ponytail: one song twice in a set with different gig keys, only one rendered, uses the first's length.
  late final _plan = planTimes(widget.items,
      (id) => _played(widget.songs[id], widget.items.firstWhere((i) => i.songId == id)), Duration.zero, widget.changeover);
  Duration? _played(Song? s, SetItem i) {
    if (s == null) return null;
    final p = playbackFor(s, _shiftOf(i));
    return s.playedDurationAt(p.tempo, cuts: p.cuts);
  }

  late final _lengths = [
    for (final i in widget.items)
      i.isBreak
          ? Duration(minutes: i.minutes)
          : _played(widget.songs[i.songId], i),
  ];

  @override
  void initState() {
    super.initState();
    windowManager.setFullScreen(true);
    renderQueue.pause(); // no new render starts during the show
    _player.setReleaseMode(ReleaseMode.stop); // keep the file loaded so restart works after the end
    _player.onPlayerComplete.listen((_) {
      setState(() => _playing = false); // last song: stay on it, paused
      _cue(_index + 1);
    });
    // Poll position (~20 fps) so the highlight tracks the audio, not a separate clock.
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      final p = await _player.getCurrentPosition();
      if (mounted && p != null && p != _pos) setState(() => _pos = p);
      if (mounted && (_item.isBreak || _win != null)) setState(() {}); // tick the countdown / clock
      final w = _win;
      w?.send(_lyricsState, () => _lost(w));
    });
    _checkDisplays();
    _screens = Timer.periodic(const Duration(seconds: 1), (_) => _checkDisplays());
    WakelockPlus.enable().catchError((Object _) {}); // no sleep on stage; a failure must not stop the show
    if (!_item.isBreak) _play = playbackFor(_song, _shiftOf(_item)); // before the first build
    _cue(_index);
    _wake();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _overlayTimer?.cancel();
    _screens?.cancel();
    _fade?.cancel();
    _win?.close();
    WakelockPlus.disable().catchError((Object _) {});
    for (final t in _holds.values) {
      t.cancel();
    }
    _player.dispose();
    renderQueue.resume();
    windowManager.setFullScreen(false);
    super.dispose();
  }

  /// Polled once a second: a display plugged in opens the lyrics window, one pulled out closes it
  /// (Windows would otherwise drop it over the presenter). Audio is never touched.
  Future<void> _checkDisplays() async {
    var n = 1;
    try {
      n = await countDisplays();
    } on Object {
      // can't tell: stay as we are on one screen
    }
    if (!mounted) return;
    final was = _displays;
    _displays = n;
    if (n < 2) {
      _lost(_win);
    } else if (was < 2 && _win == null && !_opening) {
      // Only on a change, so a lyrics window Ryan closed by hand stays closed until the next replug.
      _opening = true;
      LyricsWindow? w;
      try {
        w = await openLyricsWindow();
      } on Object {
        // ponytail: a failed open stays one-screen until the next replug; no retry loop.
      }
      _opening = false;
      if (w == null) return;
      if (!mounted || _displays < 2) return w.close(); // stage exited or display pulled while opening
      setState(() => _win = w);
    }
  }

  /// Back to one screen if [w] is still the lyrics window. Safe to call twice.
  void _lost(LyricsWindow? w) {
    if (w == null || w != _win || !mounted) return;
    w.close();
    setState(() => _win = null);
    windowManager.focus().catchError((Object _) {});
  }

  LyricsState get _lyricsState => _item.isBreak
      ? LyricsState(blackout: _blackout, breakLabel: _item.label, breakLeft: _breakLeft)
      : LyricsState(song: _song.dir.path, pos: toOriginal(_pos, _song, playing: _play), blackout: _blackout);

  Future<void> _cue(int i) async {
    if (i < 0 || i >= widget.items.length) return;
    _fade?.cancel();
    _fade = null;
    await _player.stop();
    await _player.setVolume(1); // after a fade-out
    if (!mounted) return;
    setState(() {
      _index = i;
      _pos = Duration.zero;
      _playing = false;
      _breakEnds = _item.isBreak ? DateTime.now().add(Duration(minutes: _item.minutes)) : null;
      if (_item.isBreak) _length = Duration(minutes: _item.minutes);
      if (!_item.isBreak) _play = playbackFor(_song, _shiftOf(_item));
    });
    if (_item.isBreak) return; // audio stays stopped through a break
    await _player.setSource(DeviceFileSource(_play.file.path));
    final d = await _player.getDuration();
    if (mounted) setState(() => _length = d ?? Duration.zero);
  }

  Future<void> _toggle() async {
    if (_item.isBreak) return _cue(_index + 1); // pedal tap during a break = bring on the next song
    _playing ? await _player.pause() : await _player.resume();
    await _cancelFade();
    if (!_playing && _firstPlay == null) {
      _firstPlay = DateTime.now();
      _firstIndex = _index;
    }
    setState(() => _playing = !_playing);
  }

  /// Hold F (or the button) 1 s: fade out over 3 s, then cue the next song paused.
  void _fadeOut() {
    if (_item.isBreak || _fade != null) return;
    if (!_playing) return unawaited(_cue(_index + 1)); // nothing to fade
    var v = 1.0;
    _fade = Timer.periodic(const Duration(milliseconds: 100), (t) async {
      v -= 1 / 30;
      if (v > 0) return unawaited(_player.setVolume(v));
      if (_index + 1 < widget.items.length) return unawaited(_cue(_index + 1));
      _fade?.cancel(); // last song: stop at the top, paused
      _fade = null;
      await _player.stop();
      await _player.setVolume(1);
      if (mounted) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      }
    });
  }

  void _setBlackout(bool on) => setState(() => _blackout = on);

  Future<void> _cancelFade() async {
    if (_fade == null) return;
    _fade!.cancel();
    _fade = null;
    await _player.setVolume(1);
  }

  Future<void> _back() async {
    if (_item.isBreak) return _cue(_index == 0 ? 0 : _index - 1);
    if (_pos > const Duration(seconds: 3) || _index == 0) {
      await _cancelFade();
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
          _setBlackout(!_blackout);
        case LogicalKeyboardKey.keyF:
          hold(_fadeOut);
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
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: K.bg,
        body: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: _win != null
              ? _presenter()
              : MouseRegion(
                  onHover: (_) => _wake(),
                  child: Stack(children: [
                    Center(child: LyricsView(state: _lyricsState, song: _item.isBreak ? null : _song)),
                    AnimatedOpacity(
                      opacity: (_overlay || _item.isBreak) && !_blackout ? 1 : 0, // breaks keep "Up next" visible
                      duration: const Duration(milliseconds: 300),
                      child: _chrome(),
                    ),
                  ]),
                ),
        ),
      );

  Duration get _breakLeft {
    final left = _breakEnds?.difference(DateTime.now()) ?? Duration.zero;
    return left.isNegative ? Duration.zero : left;
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
          Expanded(
            child: Text(
                brk
                    ? _item.label
                    : '${_song.title}  •  ${shiftKey(_song.originalKey, _play.shift)}'
                        '  •  ${_play.tempo.toStringAsFixed(2)}x${_play.fallback ? '  •  original (not rendered)' : ''}',
                overflow: TextOverflow.ellipsis,
                style: dim.copyWith(color: K.text)),
          ),
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
          const Text('Hold → next  •  Hold ← restart  •  Hold F fade out  •  B blackout', style: dim),
          const Spacer(),
          const Icon(Icons.queue_music, color: K.muted, size: 18),
          const SizedBox(width: 8),
          Text('Up next: $upNext', style: dim),
        ]),
      ]),
    );
  }
}

extension on _StageScreenState {
  /// Two-screen presenter view (design/stage_mode_two_screen). Fits Ryan's 1280x720 laptop window.
  Widget _presenter() {
    final brk = _item.isBreak;
    final elapsed = brk ? _length - _breakLeft : _pos;
    final now = DateTime.now();
    final first = _firstPlay;
    final behind = first == null
        ? null
        : behindPlan(
            sinceFirstPlay: now.difference(first),
            firstStart: _plan.starts[_firstIndex],
            currentStart: _plan.starts[_index],
            progress: elapsed);
    double ratio(Duration a, Duration b) => b.inMilliseconds == 0 ? 0 : a.inMilliseconds / b.inMilliseconds;
    final setElapsed = _plan.starts[_index] + elapsed;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Text('STAGE MODE',
              style: TextStyle(color: K.accent, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(brk ? _item.label : _song.title,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          if (behind != null)
            Text(driftLabel(behind),
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: behind.inSeconds >= 30 ? K.accent : K.status(SongStatus.ready))),
          const SizedBox(width: 24),
          Text(formatClock(Duration(hours: now.hour, minutes: now.minute)),
              style: const TextStyle(fontSize: 16, fontFeatures: K.tabular)),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          height: 100,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: statCard(brk ? 'BREAK' : 'SONG', '${mss(elapsed)} / ${mss(_length)}',
                    bar: ratio(elapsed, _length))),
            const SizedBox(width: 12),
            Expanded(
                child: statCard('SET', '${mss(setElapsed)} / ${mss(_plan.total)}',
                    bar: ratio(setElapsed, _plan.total))),
            const SizedBox(width: 12),
            Expanded(
              child: statCard('KEY / TEMPO',
                  brk ? '—' : '${shiftKey(_song.originalKey, _play.shift)}  •  ${_play.tempo.toStringAsFixed(2)}x',
                  sub: !brk && _play.fallback
                      ? const Text('original (not rendered)', style: TextStyle(color: K.accent, fontSize: 12))
                      : null),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              flex: 3,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (!brk && _item.notes.trim().isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                        color: K.accent.withValues(alpha: 0.12),
                        border: Border.all(color: K.accent.withValues(alpha: 0.6)),
                        borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      const Icon(Icons.sticky_note_2_outlined, color: K.accent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(_item.notes.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
                Expanded(child: _presenterLyrics()),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: _queue()),
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 64,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            HoldButton(icon: Icons.skip_previous, onHeld: _back),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _toggle,
                icon: Icon(brk ? Icons.skip_next : (_playing ? Icons.pause : Icons.play_arrow), size: 28),
                label: Text(brk ? 'Next song' : (_playing ? 'Pause' : 'Play'), style: const TextStyle(fontSize: 18)),
              ),
            ),
            const SizedBox(width: 12),
            HoldButton(icon: Icons.skip_next, onHeld: () => _cue(_index + 1)),
            const SizedBox(width: 12),
            HoldButton(icon: Icons.volume_down, label: 'Fade out', onHeld: _fadeOut),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => _setBlackout(!_blackout),
              style: OutlinedButton.styleFrom(
                foregroundColor: _blackout ? K.bg : K.text,
                backgroundColor: _blackout ? K.accent : K.surface2,
                side: BorderSide.none,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              icon: Icon(_blackout ? Icons.visibility : Icons.visibility_off),
              label: Text(_blackout ? 'Show lyrics' : 'Blackout'),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        const Text(
          'Space / pedal: play/pause  •  Hold → next  •  Hold ← restart / previous  •  Hold F fade out  •  B blackout  •  Hold Esc exit',
          textAlign: TextAlign.center,
          style: TextStyle(color: K.muted, fontSize: 12),
        ),
      ]),
    );
  }

  /// Current + next 2 lines (SPEC §9: no full-lyrics scroll), or the break countdown.
  Widget _presenterLyrics() {
    var dots = 0;
    final Widget body;
    if (_item.isBreak) {
      body = Text(breakCountdown(_breakLeft),
          style: const TextStyle(color: K.accent, fontSize: 28, fontWeight: FontWeight.w700, fontFeatures: K.tabular));
    } else if (_song.status != SongStatus.ready) {
      body = const Text('No synced lyrics yet', style: TextStyle(color: K.muted, fontSize: 20));
    } else {
      final lines = _song.lyrics;
      final c = lyricCursor(lines, _lyricsState.pos);
      dots = c.dots;
      String text(int i) => i < 0 || i >= lines.length ? '' : (lines[i].isBreak ? '♪  Instrumental' : lines[i].text);
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text(c.cur),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: K.accent, fontSize: 28, fontWeight: FontWeight.w700, height: 1.25)),
        const SizedBox(height: 10),
        Text(text(c.cur + 1),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: K.text, fontSize: 20)),
        const SizedBox(height: 6),
        Text(text(c.cur + 2),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: K.muted, fontSize: 20)),
      ]);
    }
    return panel(
      header: Row(children: [
        Text(_blackout ? 'CURRENT & NEXT LYRICS  •  BLACKOUT ON' : 'CURRENT & NEXT LYRICS'),
        const Spacer(),
        if (dots > 0) Dots(dots, size: 8),
      ]),
      child: body,
    );
  }

  /// Previous, current (ACTIVE) and the next few items, breaks included, each with its length.
  Widget _queue() {
    final n = widget.items.length;
    final from = max(0, _index - 1), to = min(n, from + 5);
    return panel(
      header: Row(children: [const Text('SETLIST QUEUE'), const Spacer(), Text('Item ${_index + 1} of $n')]),
      child: Column(children: [
        for (var i = from; i < to; i++)
          Container(
            height: 44,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: i == _index
                ? BoxDecoration(
                    color: K.surface2,
                    border: const Border(left: BorderSide(color: K.accent, width: 4)),
                    borderRadius: BorderRadius.circular(4))
                : null,
            child: Row(children: [
              SizedBox(
                  width: 28,
                  child: Text('${i + 1}'.padLeft(2, '0'),
                      style: const TextStyle(color: K.muted, fontSize: 13, fontFeatures: K.tabular))),
              if (widget.items[i].isBreak) ...[
                const Icon(Icons.coffee, size: 16, color: K.muted),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(_title(widget.items[i]),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: i < _index ? K.muted : K.text, fontWeight: i == _index ? FontWeight.w600 : null)),
              ),
              if (i == _index)
                Container(
                  margin: const EdgeInsets.only(left: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration:
                      BoxDecoration(color: K.accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
                  child: const Text('ACTIVE',
                      style: TextStyle(color: K.accent, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1)),
                ),
              const SizedBox(width: 12),
              Text(mss(_lengths[i]), style: const TextStyle(color: K.muted, fontFeatures: K.tabular)),
            ]),
          ),
      ]),
    );
  }
}
