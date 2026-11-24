import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library.dart';
import 'lrc.dart';
import 'theme.dart';

/// Lyrics timing editor (SPEC.md §5.2, sync tools). Main tool is "tap": the selected line
/// snaps to the playhead and every later line moves by the same amount, so one tap fixes
/// a whole-song offset and further taps fix drift.
class EditorScreen extends StatefulWidget {
  final Song song;
  const EditorScreen({super.key, required this.song});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  static const _rowHeight = 48.0;

  final _player = AudioPlayer();
  final _scroll = ScrollController();
  final _paste = TextEditingController();
  final _keys = FocusNode();
  late List<LyricLine> _lines = [...widget.song.lyrics];
  int _sel = 0;
  int? _lastTap; // for Backspace undo
  bool _dirty = false, _playing = false;
  Duration _pos = Duration.zero, _length = Duration.zero;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _player.setSource(DeviceFileSource(widget.song.audio.path)).then((_) async {
      final d = await _player.getDuration();
      if (mounted) setState(() => _length = d ?? Duration.zero);
    });
    _player.onPlayerComplete.listen((_) => setState(() => _playing = false));
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      final p = await _player.getCurrentPosition();
      if (mounted && p != null && p != _pos) setState(() => _pos = p);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _player.dispose();
    _scroll.dispose();
    _paste.dispose();
    _keys.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    _playing ? await _player.pause() : await _player.resume();
    setState(() => _playing = !_playing);
  }

  Future<void> _seek(Duration d) async {
    final t = d < Duration.zero ? Duration.zero : (d > _length ? _length : d);
    await _player.seek(t);
    setState(() => _pos = t);
  }

  /// Move line [from] and every later timed line by [delta].
  void _shift(int from, Duration delta, {int? to}) {
    setState(() {
      for (var j = from; j <= (to ?? _lines.length - 1); j++) {
        final t = _lines[j].time;
        if (t == null) continue;
        final n = t + delta;
        _lines[j] = LyricLine(n < Duration.zero ? Duration.zero : n, _lines[j].text);
      }
      _dirty = true;
    });
  }

  /// Selected line starts now, then move on. [follow]: later lines keep their spacing (offset fix).
  void _tap({bool follow = false}) {
    if (_lines.isEmpty) return;
    final old = _lines[_sel].time;
    setState(() {
      _lines[_sel] = LyricLine(_pos, _lines[_sel].text);
      _lastTap = _sel;
      _dirty = true;
    });
    if (follow && old != null && _sel + 1 < _lines.length) _shift(_sel + 1, _pos - old);
    _select(_sel + 1);
  }

  /// An instrumental break starts now: insert a marker before the selected line.
  void _breakNow() {
    setState(() {
      _lines.insert(_sel, LyricLine(_pos, ''));
      _lastTap = _sel;
      _dirty = true;
    });
    _select(_sel + 1);
  }

  /// Missed a tap: clear the last tapped line, select it, rewind 3s.
  void _undo() {
    final i = _lastTap;
    if (i == null) return;
    setState(() {
      _lines[i].isBreak ? _lines.removeAt(i) : _lines[i] = LyricLine(null, _lines[i].text);
      _lastTap = i > 0 ? i - 1 : null;
    });
    _select(i);
    _seek(_pos - const Duration(seconds: 3));
  }

  /// Clear timing from the selected line on, and jump to just before it to tap fresh.
  void _resyncFromHere() {
    setState(() {
      for (var j = _sel; j < _lines.length; j++) {
        _lines[j] = LyricLine(null, _lines[j].text);
      }
      _lastTap = null;
      _dirty = true;
    });
    final prev = _sel > 0 ? _lines[_sel - 1].time : null;
    _seek(prev == null ? Duration.zero : prev + const Duration(milliseconds: 500));
  }

  void _select(int i) {
    setState(() => _sel = i.clamp(0, _lines.isEmpty ? 0 : _lines.length - 1));
    if (_scroll.hasClients) {
      _scroll.animateTo((_sel * _rowHeight - 200).clamp(0, _scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    }
  }

  Future<void> _save() async {
    await widget.song.lyricsFile.writeAsString(formatLrc(_lines));
    setState(() => _dirty = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${widget.song.lyricsFile.uri.pathSegments.last}')));
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final big = HardwareKeyboard.instance.isShiftPressed;
    final step = Duration(milliseconds: big ? 1000 : 100);
    switch (e.logicalKey) {
      case LogicalKeyboardKey.space when e is KeyDownEvent:
        _toggle();
      case LogicalKeyboardKey.enter when e is KeyDownEvent:
        _tap(follow: big);
      case LogicalKeyboardKey.backspace when e is KeyDownEvent:
        _undo();
      case LogicalKeyboardKey.keyB when e is KeyDownEvent:
        _breakNow();
      case LogicalKeyboardKey.delete when e is KeyDownEvent && _lines.isNotEmpty && _lines[_sel].isBreak:
        setState(() {
          _lines.removeAt(_sel);
          _dirty = true;
        });
        _select(_sel);
      case LogicalKeyboardKey.arrowUp:
        _select(_sel - 1);
      case LogicalKeyboardKey.arrowDown:
        _select(_sel + 1);
      case LogicalKeyboardKey.arrowLeft:
        _shift(_sel, -step, to: _sel);
      case LogicalKeyboardKey.arrowRight:
        _shift(_sel, step, to: _sel);
      case LogicalKeyboardKey.keyS when ctrl:
        _save();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<bool> _confirmLeave() async =>
      !_dirty ||
      await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('Discard timing changes?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
              ],
            ),
          ) ==
          true;

  @override
  Widget build(BuildContext context) {
    final s = widget.song;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
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
                    Text(s.title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
                    Text([s.artist, s.originalKey, if (s.bpm != null) '${s.bpm!.round()} BPM']
                        .where((x) => x.isNotEmpty).join('  •  '),
                        style: const TextStyle(color: K.muted)),
                  ]),
                ),
                if (_dirty) const Text('Unsaved changes  ', style: TextStyle(color: K.accent)),
                FilledButton.icon(
                    onPressed: _dirty ? _save : null, icon: const Icon(Icons.save), label: const Text('Save')),
              ]),
              const SizedBox(height: 24),
              _transport(),
              const SizedBox(height: 16),
              if (_lines.isNotEmpty) _tools(),
              const SizedBox(height: 16),
              Expanded(child: _lines.isEmpty ? _pasteBox() : _list()),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _transport() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          FilledButton(
            onPressed: _toggle,
            child: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          const SizedBox(width: 16),
          Text('${_fmt(_pos)} / ${_fmt(_length)}', style: const TextStyle(fontFeatures: K.tabular)),
          Expanded(
            child: Slider(
              value: _pos.inMilliseconds.clamp(0, _length.inMilliseconds).toDouble(),
              max: _length.inMilliseconds.toDouble().clamp(1, double.infinity),
              onChanged: (v) => _seek(Duration(milliseconds: v.round())),
            ),
          ),
        ]),
      );

  Widget _tools() {
    Widget shiftBtn(String label, int ms) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: OutlinedButton(
              onPressed: () => _shift(0, Duration(milliseconds: ms)), child: Text(label)),
        );
    return Row(children: [
      const Text('Shift all  ', style: TextStyle(color: K.muted)),
      shiftBtn('−1s', -1000),
      shiftBtn('−0.1s', -100),
      shiftBtn('+0.1s', 100),
      shiftBtn('+1s', 1000),
      const SizedBox(width: 16),
      OutlinedButton.icon(
          onPressed: _resyncFromHere, icon: const Icon(Icons.restart_alt), label: const Text('Re-sync from here')),
      const Spacer(),
      OutlinedButton.icon(onPressed: _breakNow, icon: const Icon(Icons.music_note), label: const Text('Instrumental now  (B)')),
      const SizedBox(width: 12),
      SizedBox(
        height: 52,
        child: FilledButton.icon(
          onPressed: _tap,
          icon: const Icon(Icons.skip_next),
          label: const Text('NEXT LINE NOW  (Enter)'),
        ),
      ),
    ]);
  }

  Widget _list() {
    final playing = currentLine(_lines, _pos);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text(
          'Space play/pause  •  Enter = selected line starts now  •  Backspace undo tap  •  Shift+Enter tap + later lines follow'
          '  •  B instrumental starts now (Del removes a break)  •  ↑ ↓ select  •  ← → nudge 0.1s (Shift 1s)  •  Click a line to hear it  •  Ctrl+S save',
          style: TextStyle(color: K.muted, fontSize: 12)),
      const SizedBox(height: 8),
      Expanded(
        child: Container(
          decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
          clipBehavior: Clip.antiAlias,
          child: ListView.builder(
            controller: _scroll,
            itemCount: _lines.length,
            itemExtent: _rowHeight,
            itemBuilder: (_, i) {
              final l = _lines[i];
              final isPlaying = i == playing;
              return InkWell(
                onTap: () {
                  _select(i);
                  if (l.time != null) _seek(l.time! - const Duration(seconds: 2));
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: i == _sel ? K.surface2 : null,
                    border: Border(left: BorderSide(color: i == _sel ? K.accent : Colors.transparent, width: 3)),
                  ),
                  child: Row(children: [
                    SizedBox(
                      width: 90,
                      child: Text(l.time == null ? '--:--.--' : _fmt(l.time!, cs: true),
                          style: const TextStyle(color: K.muted, fontFeatures: K.tabular)),
                    ),
                    Expanded(
                      child: Text(l.isBreak ? '♪  Instrumental' : l.text,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontStyle: l.isBreak ? FontStyle.italic : null,
                            color: isPlaying ? K.accent : (l.isBreak ? K.muted : K.text),
                            fontWeight: isPlaying ? FontWeight.w700 : FontWeight.w400,
                          )),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
      ),
    ]);
  }

  Widget _pasteBox() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('No lyrics yet. Paste them below, one line per lyric line, then tap-sync.',
            style: TextStyle(color: K.muted)),
        const SizedBox(height: 8),
        Expanded(
          child: TextField(controller: _paste, maxLines: null, expands: true, textAlignVertical: TextAlignVertical.top),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => setState(() {
            _lines = [
              for (final t in _paste.text.split(RegExp(r'\r?\n')).map((t) => t.trim()).where((t) => t.isNotEmpty))
                LyricLine(null, t),
            ];
            _sel = 0;
            _dirty = _lines.isNotEmpty;
            _keys.requestFocus(); // back to Space/Enter shortcuts
          }),
          child: const Text('Use these lyrics'),
        ),
      ]);
}

String _fmt(Duration d, {bool cs = false}) {
  final s = '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  return cs ? '$s.${(d.inMilliseconds % 1000 ~/ 10).toString().padLeft(2, '0')}' : s;
}
