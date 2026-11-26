import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library.dart';
import 'render.dart';
import 'theme.dart';

/// 15 s of a song's backing track from 0:30, one song at a time. [playing] = the song id, or null.
/// Plays [Song.audio] (its render when ready), or [file] when given.
class Preview {
  final _player = AudioPlayer();
  final playing = ValueNotifier<String?>(null);
  Timer? _timer;

  Future<void> toggle(Song s, {File? file}) async {
    final was = playing.value;
    await stop();
    if (was == s.id) return;
    playing.value = s.id;
    await _player.play(DeviceFileSource((file ?? s.audio).path), position: const Duration(seconds: 30));
    _timer = Timer(const Duration(seconds: 15), stop);
  }

  Future<void> stop() async {
    _timer?.cancel();
    if (playing.value == null) return; // nothing playing: no plugin round trip
    playing.value = null;
    await _player.stop();
  }

  void dispose() {
    _timer?.cancel();
    _player.dispose();
    playing.dispose();
  }
}

/// How the details dialog was closed (null = cancelled).
enum DetailsResult { saved, savedNext }

Future<DetailsResult?> showSongDetails(BuildContext context, Song song, Preview preview) =>
    showDialog<DetailsResult>(context: context, builder: (_) => SongDetailsDialog(song: song, preview: preview));

/// "1.0" -> "1", "129.94" -> "129.9".
String formatBpm(double? v) {
  if (v == null) return '';
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Song details (docs/stage-manager-plan.md WP-B, C2): fix the name, artist, language and BPM; set the
/// key and tempo. Saving a new key/tempo queues its render (the caller does that, see main.dart).
/// Enter saves, Esc cancels, Ctrl+Enter saves and moves to the next song that still needs a name.
class SongDetailsDialog extends StatefulWidget {
  final Song song;
  final Preview preview;
  const SongDetailsDialog({super.key, required this.song, required this.preview});

  @override
  State<SongDetailsDialog> createState() => _SongDetailsDialogState();
}

class _SongDetailsDialogState extends State<SongDetailsDialog> {
  static const _languages = ['english', 'hindi', 'konkani', 'spanish', 'other'];

  Song get _s => widget.song;
  late final _title = TextEditingController(text: _s.title)
    ..selection = TextSelection(baseOffset: 0, extentOffset: _s.title.length); // type straight over the guess
  late final _artist = TextEditingController(text: _s.artist);
  late final _bpm = TextEditingController(text: formatBpm(_s.bpm));
  late final String? _origLang = _s.language.isEmpty ? null : _s.language.toLowerCase();
  late String? _lang = _origLang;
  // SPEC §4 ranges; the engine takes more, the UI doesn't. Nothing renders until Save.
  late int _shift = _s.keyShift.clamp(-6, 6);
  late double _tempo = (_s.tempo.clamp(0.8, 1.2) * 100).round() / 100;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {})); // Save is disabled while the title is empty
    _bpm.addListener(() => setState(() {})); // the reset link follows the field
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _bpm.dispose();
    super.dispose();
  }

  /// The override the field stands for: null when empty or equal to Studio's detected value.
  double? get _override {
    final v = double.tryParse(_bpm.text.trim());
    if (v == null || v <= 0) return null;
    final det = _s.detectedBpm;
    if (det != null && (v - det).abs() < 0.05) return null;
    return (v * 10).round() / 10;
  }

  Map<String, Object?> get _changes {
    final title = _title.text.trim(), artist = _artist.text.trim(), bpm = _override;
    return {
      if (title != _s.title) 'title': title,
      if (artist != _s.artist) 'artist': artist,
      if (_lang != _origLang) 'language': _lang,
      if (bpm != (_s.json['bpm_override'] as num?)?.toDouble()) 'bpm_override': bpm,
      if (_shift != _s.keyShift) 'key_shift': _shift,
      if ((_tempo - _s.tempo).abs() > 0.001) 'tempo': _tempo,
    };
  }

  bool get _canSave => !_saving && _title.text.trim().isNotEmpty;

  Future<void> _save(DetailsResult how) async {
    if (!_canSave) return;
    setState(() => _saving = true);
    try {
      final c = _changes;
      if (c.isNotEmpty) await saveSongFields(_s, c);
      if (mounted) Navigator.pop(context, how);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save: $e';
        });
      }
    }
  }

  void _scaleBpm(double by) {
    final v = double.tryParse(_bpm.text.trim()) ?? _s.detectedBpm;
    if (v != null) _bpm.text = formatBpm(v * by);
  }

  Widget _keyRow(Song s) {
    final sign = _shift > 0 ? '+' : '';
    final key = s.originalKey.isEmpty || _shift == 0 ? s.originalKey : '${s.originalKey} → ${shiftKey(s.originalKey, _shift)}';
    return Row(children: [
      const SizedBox(width: 64, child: Text('Key', style: TextStyle(color: K.muted))),
      IconButton(
        tooltip: 'Key down',
        onPressed: _shift > -6 ? () => setState(() => _shift--) : null,
        icon: const Icon(Icons.remove),
      ),
      SizedBox(
        width: 48,
        child: Text('$sign$_shift', textAlign: TextAlign.center, style: const TextStyle(fontFeatures: K.tabular)),
      ),
      IconButton(
        tooltip: 'Key up',
        onPressed: _shift < 6 ? () => setState(() => _shift++) : null,
        icon: const Icon(Icons.add),
      ),
      const SizedBox(width: 12),
      Text(key, style: const TextStyle(fontWeight: FontWeight.w600)),
    ]);
  }

  Widget _tempoRow(Song s) {
    final bpm = double.tryParse(_bpm.text.trim()) ?? s.bpm;
    return Row(children: [
      const SizedBox(width: 64, child: Text('Tempo', style: TextStyle(color: K.muted))),
      Expanded(
        child: Slider(
          value: _tempo,
          min: 0.8,
          max: 1.2,
          divisions: 40, // 0.01 steps
          onChanged: (v) => setState(() => _tempo = (v * 100).round() / 100),
        ),
      ),
      SizedBox(
        width: 190,
        child: Text(
          [
            '${_tempo.toStringAsFixed(2)}x',
            if (s.duration != null) mss(s.playedDurationAt(_tempo)),
            if (bpm != null) '${formatBpm(bpm * _tempo)} BPM',
          ].join(' · '),
          style: const TextStyle(fontFeatures: K.tabular),
        ),
      ),
    ]);
  }

  /// Plays the render for the key/tempo shown when it's on disk, else the original with a note.
  Widget _preview(Song s) => ValueListenableBuilder(
        valueListenable: renderQueue.jobs, // a finished render switches the preview over
        builder: (_, jobs, _) {
          final play = playbackFor(s, _shift, _tempo);
          final note = !play.fallback
              ? null
              : jobs.containsKey(RenderQueue.keyOf(s, _shift, _tempo))
                  ? "Rendering… the preview plays the original until it's ready."
                  : 'Not rendered yet: Save renders it. The preview plays the original.';
          return Row(children: [
            ValueListenableBuilder(
              valueListenable: widget.preview.playing,
              builder: (_, playing, _) => OutlinedButton.icon(
                onPressed: s.playable ? () => widget.preview.toggle(s, file: play.file) : null,
                icon: Icon(playing == s.id ? Icons.stop : Icons.play_arrow),
                label: const Text('Play 15 s'),
              ),
            ),
            if (note != null) ...[
              const SizedBox(width: 12),
              Expanded(child: Text(note, style: const TextStyle(color: K.muted, fontSize: 13))),
            ],
          ]);
        },
      );

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final source = [
      s.sourceFile.isEmpty ? s.id : s.sourceFile,
      if (s.originalKey.isNotEmpty) s.originalKey,
      if (s.duration != null) mss(s.duration),
    ].join(' · ');
    final save = _canSave ? () => _save(DetailsResult.saved) : null;
    final langs = [..._languages, if (_origLang != null && !_languages.contains(_origLang)) _origLang];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _save(DetailsResult.savedNext),
      },
      child: AlertDialog(
        backgroundColor: K.surface1,
        title: const Text('Song details'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Source file: $source', style: const TextStyle(color: K.muted, fontFeatures: K.tabular)),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Title'),
              onSubmitted: (_) => save?.call(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _artist,
              decoration: const InputDecoration(labelText: 'Artist'),
              onSubmitted: (_) => save?.call(),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _lang,
              dropdownColor: K.surface2,
              decoration: const InputDecoration(labelText: 'Language'),
              items: [
                for (final l in langs) DropdownMenuItem(value: l, child: Text(l[0].toUpperCase() + l.substring(1))),
              ],
              onChanged: (v) => setState(() => _lang = v),
            ),
            const SizedBox(height: 12),
            Row(children: [
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _bpm,
                  decoration: const InputDecoration(labelText: 'BPM'),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  onSubmitted: (_) => save?.call(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => _scaleBpm(0.5), child: const Text('½×')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => _scaleBpm(2), child: const Text('2×')),
              const SizedBox(width: 12),
              if (s.detectedBpm != null)
                Text('Detected ${formatBpm(s.detectedBpm)}', style: const TextStyle(color: K.muted)),
              if (_override != null && s.detectedBpm != null)
                TextButton(onPressed: () => _bpm.text = formatBpm(s.detectedBpm), child: const Text('Reset')),
            ]),
            const SizedBox(height: 12),
            _keyRow(s),
            _tempoRow(s),
            const SizedBox(height: 8),
            _preview(s),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: K.status(SongStatus.needsLyrics))),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          OutlinedButton(
            onPressed: _canSave ? () => _save(DetailsResult.savedNext) : null,
            child: const Text('Save & next unnamed  (Ctrl+Enter)'),
          ),
          FilledButton(onPressed: save, child: const Text('Save')),
        ],
      ),
    );
  }
}
