import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library.dart';
import 'lrc.dart';
import 'lyrics_ops.dart';
import 'render.dart';
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
  final _edit = TextEditingController();
  final _editFocus = FocusNode();
  late List<LyricLine> _lines = [...widget.song.lyrics];
  int _sel = 0;
  int? _anchor; // other end of a Shift-selected range, null = just _sel
  int? _editing; // line whose text field is open
  int? _lastTap; // for Backspace undo
  bool _dirty = false, _playing = false, _switching = false;
  Duration _pos = Duration.zero, _length = Duration.zero;
  Timer? _poll;
  (int, DateTime)? _lastClick; // for double-click without delaying single clicks
  double _tapX = 0; // where the last click landed in its row (time column vs words)
  bool _ignoreBlur = false; // the field is being moved to another line, not left
  String _hearing = 'Backing track';
  // Showing Studio's draft. Saving writes the song's real lyrics file (Song.lyricsFile), never the draft.
  late bool _draft = widget.song.isDraft;

  int get _from => min(_sel, _anchor ?? _sel);
  int get _to => max(_sel, _anchor ?? _sel);

  @override
  void initState() {
    super.initState();
    // ReleaseMode.stop keeps the file loaded after the track ends, so you can seek back and keep syncing.
    _player.setReleaseMode(ReleaseMode.stop);
    _startAudio();
    _player.onPlayerComplete.listen((_) => setState(() => _playing = false));
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) async {
      if (_switching) return;
      final p = await _player.getCurrentPosition();
      if (mounted && !_switching && p != null && p != _pos) setState(() => _pos = p);
    });
    _editFocus.addListener(() {
      if (!_editFocus.hasFocus && _editing != null && !_ignoreBlur) _endEdit(save: true);
    });
  }

  Future<void> _load(File f) async {
    await _player.setSource(DeviceFileSource(f.path));
    final d = await _player.getDuration();
    if (mounted) setState(() => _length = d ?? Duration.zero);
  }

  /// Plays the instrumental at once, then swaps to the guide mix (the song with vocals, so you can
  /// find your place) as soon as it's made, at the same position and play state. One player, so no drift.
  Future<void> _startAudio() async {
    await _load(widget.song.audio);
    File? mix;
    try {
      mix = await ensureGuideMix(widget.song);
    } catch (_) {
      mix = null;
    }
    if (!mounted) return;
    if (mix == null) return setState(() => _hearing = 'Backing track (no vocals to mix)');
    setState(() => _switching = true); // the poll would read the new file's 0:00 meanwhile
    try {
      final now = await _player.getCurrentPosition(); // the poll's value can be 50 ms old
      if (now != null && _playing) _pos = now;
      await _load(mix);
      await _player.seek(_pos); // _pos still follows seeks made during the swap
      if (_playing) await _player.resume();
      if (mounted) setState(() => _hearing = 'Song with vocals');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  void dispose() {
    _editing = null; // the text field unmounting must not try to save
    _poll?.cancel();
    _player.dispose();
    _scroll.dispose();
    _paste.dispose();
    _keys.dispose();
    _edit.dispose();
    _editFocus.dispose();
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
  /// Clear timing from the selected line on, rewind to just before the previous line and play,
  /// so you hear the lead-in and can tap the selected line on time.
  void _resyncFromHere() {
    final prev = _sel > 0 ? _lines[_sel - 1].time : null;
    final own = _lines.isEmpty ? null : _lines[_sel].time;
    setState(() {
      for (var j = _sel; j < _lines.length; j++) {
        _lines[j] = LyricLine(null, _lines[j].text);
      }
      _lastTap = null;
      _dirty = true;
    });
    const lead = Duration(seconds: 1);
    _seek(prev != null ? prev - lead : (own != null ? own - const Duration(seconds: 4) : Duration.zero));
    if (!_playing) _toggle();
  }

  /// Move the selection. [extend] (Shift) grows a range from where it was; any other move drops it,
  /// so a range never outlives a change to the list.
  void _select(int i, {bool extend = false}) {
    setState(() {
      _anchor = extend ? (_anchor ?? _sel) : null;
      _sel = i.clamp(0, _lines.isEmpty ? 0 : _lines.length - 1);
    });
    if (_scroll.hasClients) {
      final row = _sel + (_showAdd && _sel >= _addAt ? 1 : 0);
      _scroll.animateTo((row * _rowHeight - 200).clamp(0, _scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    }
  }

  /// Keep Backspace-undo pointing at the same line after [delta] lines were inserted
  /// (positive) or removed (negative) at index [at]. A removed tap can't be undone.
  void _reindex(int at, int delta) {
    final t = _lastTap;
    if (t == null || t < at) return;
    _lastTap = delta < 0 && t < at - delta ? null : t + delta;
  }

  void _edited(List<LyricLine> next) {
    _lines = next;
    _dirty = true;
  }

  /// F2 / double-click: open line [i]'s text for editing. Its time is kept.
  void _startEdit([int? i]) {
    if (_lines.isEmpty) return;
    final at = i ?? _sel;
    _ignoreBlur = _editFocus.hasFocus; // moving straight from one line's field to another's
    setState(() {
      _editing = at;
      _edit.text = _lines[at].text;
      _edit.selection = TextSelection.collapsed(offset: _edit.text.length);
    });
    _select(at);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ignoreBlur = false;
      if (_editing != null) _editFocus.requestFocus();
    });
  }

  /// Enter / click away saves, Esc cancels. Either way focus goes back to the tap-sync keys.
  void _endEdit({required bool save}) {
    final i = _editing;
    if (i == null || !mounted) return;
    _editing = null; // first, so the focus listener doesn't end it twice
    final old = _lines[i];
    final text = save ? _edit.text.trim() : old.text;
    setState(() {
      // An untimed line left empty (a new line never typed into) goes away, saved or not.
      if (text != old.text || (text.isEmpty && old.time == null)) {
        if (text.isEmpty && old.time == null) {
          _reindex(i, -1);
          if (i > 0) _sel = i - 1; // back to the line it was inserted below
        }
        _edited(setText(_lines, i, text));
      }
    });
    _select(_sel);
    _keys.requestFocus();
  }

  /// Ctrl+Shift+Enter while editing: split at the cursor; the second half is untimed.
  void _splitEdit() {
    final i = _editing!;
    final raw = _edit.text;
    final sel = _edit.selection;
    final at = sel.isValid ? sel.start.clamp(0, raw.length) : raw.length;
    final next = splitLine([..._lines]..[i] = LyricLine(_lines[i].time, raw), i, at);
    if (next.length == _lines.length) return; // cursor at an end: nothing to split, keep editing
    _editing = null;
    setState(() {
      _reindex(i + 1, 1);
      _edited(next);
    });
    _select(i + 1);
    _keys.requestFocus();
  }

  /// "+ Add line" sits under the line at the playhead. Before any line is timed the playhead
  /// can't place it, so it sits under the selected line instead. Paused only, so it doesn't
  /// jump around while you tap.
  bool get _showAdd => !_playing && _lines.isNotEmpty;
  int get _addAt {
    final c = currentLine(_lines, _pos);
    return c < 0 && _lines.first.time == null ? _sel + 1 : c + 1;
  }

  /// Ctrl+Enter: paused, insert at "+ Add line"; playing, below the selection. Opens it for typing.
  void _insertNew() => _insertAt(_showAdd ? _addAt : (_lines.isEmpty ? 0 : _sel + 1));

  /// Ctrl+Enter in the field: keep this line and open another new one right under it.
  void _saveAndAddBelow() {
    final i = _editing!;
    if (_edit.text.trim().isEmpty) return; // nothing typed yet: stay put
    _endEdit(save: true);
    _insertAt(i + 1);
  }

  void _insertAt(int at) {
    setState(() {
      _reindex(at, 1);
      _edited(insertAt(_lines, at));
    });
    _startEdit(at);
  }

  /// Ctrl+Delete: remove the selected line or range. Neighbours keep their times.
  void _deleteSel() => _deleteRange(_from, _to);

  void _deleteRange(int a, int b) {
    if (_lines.isEmpty) return;
    setState(() {
      _reindex(a, a - b - 1);
      _edited(deleteRange(_lines, a, b));
    });
    _select(a);
  }

  /// Ctrl+M: join the selected line with the next; it keeps the first line's time.
  void _mergeNext() {
    if (_sel + 1 >= _lines.length) return;
    setState(() {
      _reindex(_sel + 1, -1);
      _edited(mergeNext(_lines, _sel));
    });
    _select(_sel);
  }

  /// Ctrl+D: copy the selected range (a repeated chorus) right after it, untimed, ready to tap.
  void _duplicate() {
    if (_lines.isEmpty) return;
    final b = _to;
    final next = duplicateRange(_lines, _from, b);
    final n = next.length - _lines.length;
    if (n == 0) return; // only break markers selected
    setState(() {
      _reindex(b + 1, n);
      _edited(next);
    });
    _select(b + 1);
  }

  Future<void> _replaceAll() async {
    final words = [for (final l in _lines) if (!l.isBreak) l.text];
    // ponytail: not disposed; the dialog's closing animation still reads it, and nothing listens after.
    final c = TextEditingController(text: words.join('\n'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: c,
        builder: (ctx, _) {
          final after = textLines(c.text).length, before = words.length;
          final note = after == before
              ? 'Every line keeps its time.'
              : after > before
                  ? 'The first $before keep their times, ${after - before} new lines are untimed.'
                  : 'The first $after keep their times, the last ${before - after} old lines are removed.';
          return AlertDialog(
            title: const Text('Replace all text'),
            content: SizedBox(
              width: 640,
              height: 440,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text(
                    'Paste the new version, one line per lyric line. Lines are matched in order, '
                    'so the first lines keep their times. Instrumental markers stay where they are.',
                    style: TextStyle(color: K.muted)),
                const SizedBox(height: 8),
                Expanded(
                  child: TextField(
                      controller: c, maxLines: null, expands: true, textAlignVertical: TextAlignVertical.top),
                ),
                const SizedBox(height: 8),
                Text('Before: $before lines  ->  after: $after lines.  $note',
                    style: TextStyle(color: after == before ? K.muted : K.accent)),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(
                  onPressed: after == 0 ? null : () => Navigator.pop(ctx, true), child: const Text('Replace')),
            ],
          );
        },
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _edited(replaceAllText(_lines, textLines(c.text)));
        _lastTap = null;
      });
      _select(_sel);
    }
    _keys.requestFocus();
  }

  Future<void> _save() async {
    await widget.song.lyricsFile.writeAsString(formatLrc(_lines));
    setState(() => _dirty = _draft = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved ${widget.song.lyricsFile.uri.pathSegments.last}')));
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    // Typing in a text field (line edit or paste box): its keys are characters, not shortcuts.
    // The focused node belongs to a Focus *inside* EditableText, hence the ancestor lookup.
    if (_editing != null ||
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final big = HardwareKeyboard.instance.isShiftPressed;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.space when e is KeyDownEvent:
        _toggle();
      case LogicalKeyboardKey.enter when e is KeyDownEvent && ctrl:
        _insertNew();
      case LogicalKeyboardKey.enter when e is KeyDownEvent:
        _tap(follow: big);
      case LogicalKeyboardKey.backspace when e is KeyDownEvent:
        _undo();
      case LogicalKeyboardKey.keyB when e is KeyDownEvent:
        _breakNow();
      case LogicalKeyboardKey.delete when e is KeyDownEvent && ctrl:
        _deleteSel();
      case LogicalKeyboardKey.delete when e is KeyDownEvent && _lines.isNotEmpty && _lines[_sel].isBreak:
        _deleteRange(_sel, _sel);
      case LogicalKeyboardKey.f2 when e is KeyDownEvent:
        _startEdit();
      case LogicalKeyboardKey.keyM when e is KeyDownEvent && ctrl:
        _mergeNext();
      case LogicalKeyboardKey.keyD when e is KeyDownEvent && ctrl:
        _duplicate();
      case LogicalKeyboardKey.arrowUp:
        _select(_sel - 1, extend: big);
      case LogicalKeyboardKey.arrowDown:
        _select(_sel + 1, extend: big);
      case LogicalKeyboardKey.arrowLeft:
        _seek(_pos - Duration(seconds: big ? 1 : 5));
      case LogicalKeyboardKey.arrowRight:
        _seek(_pos + Duration(seconds: big ? 1 : 5));
      case LogicalKeyboardKey.bracketLeft:
        _shift(_sel, -const Duration(milliseconds: 100), to: _sel);
      case LogicalKeyboardKey.bracketRight:
        _shift(_sel, const Duration(milliseconds: 100), to: _sel);
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
              title: const Text('Discard unsaved changes?'),
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
                    if (_draft) ...[const SizedBox(height: 6), DraftBadge(s, full: true)],
                  ]),
                ),
                if (_dirty) const Text('Unsaved changes  ', style: TextStyle(color: K.accent)),
                if (_lines.isNotEmpty) ...[
                  OutlinedButton.icon(
                      onPressed: _replaceAll, icon: const Icon(Icons.edit_note), label: const Text('Replace all text…')),
                  const SizedBox(width: 12),
                ],
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
          IconButton(
              tooltip: 'Back 5s (←)',
              onPressed: () => _seek(_pos - const Duration(seconds: 5)),
              icon: const Icon(Icons.replay_5)),
          FilledButton(
            onPressed: _toggle,
            child: Icon(_playing ? Icons.pause : Icons.play_arrow),
          ),
          IconButton(
              tooltip: 'Forward 5s (→)',
              onPressed: () => _seek(_pos + const Duration(seconds: 5)),
              icon: const Icon(Icons.forward_5)),
          const SizedBox(width: 16),
          Text('${_fmt(_pos)} / ${_fmt(_length)}', style: const TextStyle(fontFeatures: K.tabular)),
          Expanded(
            child: Slider(
              value: _pos.inMilliseconds.clamp(0, _length.inMilliseconds).toDouble(),
              max: _length.inMilliseconds.toDouble().clamp(1, double.infinity),
              onChanged: (v) => _seek(Duration(milliseconds: v.round())),
            ),
          ),
          Text(_hearing, style: const TextStyle(color: K.muted)),
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
          '  •  B instrumental now  •  ← → rewind/forward 5s (Shift 1s)  •  ↑ ↓ select  •  [ ] nudge line 0.1s  •  Click a line to hear it  •  Ctrl+S save'
          '\nPaused: click the words to edit, click the time to hear the line  •  F2 / double-click edit'
          '  •  In the field: Enter save, Esc cancel, Ctrl+Enter save + new line below, Ctrl+Shift+Enter split at cursor'
          '\nCtrl+Enter add line (paused: at "Add line here", playing: below selection)  •  Ctrl+Delete delete'
          '  •  Ctrl+M merge with next  •  Shift+↑↓ / Shift+click select lines  •  Ctrl+D duplicate (untimed)',
          style: TextStyle(color: K.muted, fontSize: 12)),
      const SizedBox(height: 8),
      Expanded(
        child: Container(
          decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
          clipBehavior: Clip.antiAlias,
          child: ListView.builder(
            controller: _scroll,
            itemCount: _lines.length + (_showAdd ? 1 : 0),
            itemExtent: _rowHeight,
            itemBuilder: (_, row) {
              final add = _showAdd ? _addAt : -1;
              if (row == add) return _addRow();
              final i = add >= 0 && row > add ? row - 1 : row;
              final l = _lines[i];
              final isPlaying = i == playing;
              final inRange = i >= _from && i <= _to;
              return InkWell(
                onTapUp: (d) => _tapX = d.localPosition.dx,
                onTap: () {
                  // Look the line up again: ending an edit on pointer-down may have removed a line above.
                  final i = _lines.indexOf(l);
                  if (i < 0) return;
                  if (HardwareKeyboard.instance.isShiftPressed) return _select(i, extend: true);
                  if (!_playing && _tapX > 16 + 90) return _startEdit(i); // paused: click the words to fix them
                  // Double-click by hand, so a single click (select + hear) isn't delayed by onDoubleTap.
                  final now = DateTime.now(), last = _lastClick;
                  _lastClick = (i, now);
                  _select(i);
                  if (last != null && last.$1 == i && now.difference(last.$2) < const Duration(milliseconds: 400)) {
                    _lastClick = null;
                    return _startEdit(i);
                  }
                  if (l.time != null) _seek(l.time! - const Duration(seconds: 2));
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: inRange ? K.surface2 : null,
                    border: Border(left: BorderSide(color: i == _sel ? K.accent : Colors.transparent, width: 3)),
                  ),
                  child: Row(children: [
                    SizedBox(
                      width: 90,
                      child: Text(l.time == null ? '--:--.--' : _fmt(l.time!, cs: true),
                          style: const TextStyle(color: K.muted, fontFeatures: K.tabular)),
                    ),
                    Expanded(
                      child: i == _editing ? _lineField() : Text(l.isBreak ? '♪  Instrumental' : l.text,
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

  Widget _lineField() => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => _endEdit(save: false),
          const SingleActivator(LogicalKeyboardKey.enter, control: true, shift: true): _splitEdit,
          const SingleActivator(LogicalKeyboardKey.enter, control: true): _saveAndAddBelow,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            _endEdit(save: true);
            _save();
          },
        },
        child: TextField(
          controller: _edit,
          focusNode: _editFocus,
          autofocus: true,
          style: const TextStyle(fontSize: 16),
          decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
          onSubmitted: (_) => _endEdit(save: true),
          onTapOutside: (_) => _endEdit(save: true),
        ),
      );

  Widget _addRow() => InkWell(
        onTap: _insertNew,
        child: const Padding(
          padding: EdgeInsets.only(left: 16 + 90),
          child: Row(children: [
            Icon(Icons.add, size: 18, color: K.accent),
            SizedBox(width: 8),
            Text('Add line here  (Ctrl+Enter)', style: TextStyle(color: K.accent)),
          ]),
        ),
      );

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
