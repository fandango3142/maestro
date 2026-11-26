import 'dart:io';

import 'package:flutter/material.dart';

import 'library.dart';
import 'render.dart';
import 'setlist.dart';
import 'theme.dart';

/// A render a stage launch needs: [song] at [shift] semitones, at the song's own tempo.
typedef RenderNeed = ({Song song, int shift});

/// Renders not on disk yet for the songs that will actually play (in [songs] and playable), each at
/// its gig key override or else its own key, and its own tempo. One entry per distinct file, in set order.
List<RenderNeed> missingRenders(List<SetItem> items, Map<String, Song> songs) {
  final out = <RenderNeed>[], seen = <String>{};
  for (final i in items) {
    final s = songs[i.songId];
    if (i.isBreak || s == null || !s.playable) continue;
    final shift = i.keyShift ?? s.keyShift;
    if (playbackFor(s, shift).fallback && seen.add(RenderQueue.keyOf(s, shift, s.tempo)!)) {
      out.add((song: s, shift: shift));
    }
  }
  return out;
}

/// "Gm → Am · 0.95x" (or "+1 st" without a known key).
String renderLabel(Song s, int shift) {
  final key = s.originalKey.isEmpty
      ? '${shift > 0 ? '+' : ''}$shift st'
      : (shift == 0 ? s.originalKey : '${s.originalKey} → ${shiftKey(s.originalKey, shift)}');
  return '$key · ${s.tempo.toStringAsFixed(2)}x';
}

/// Pre-show check before stage mode (docs/stage-manager-plan.md C2 item 4). True = go on stage.
/// Nothing missing: true at once, no dialog. Renders started here keep going if it's cancelled.
Future<bool> preShowCheck(BuildContext context, List<RenderNeed> needs) async {
  if (needs.isEmpty) return true;
  final go = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PreShowDialog(needs: needs),
  );
  return go ?? false;
}

class PreShowDialog extends StatefulWidget {
  final List<RenderNeed> needs;
  const PreShowDialog({super.key, required this.needs});

  @override
  State<PreShowDialog> createState() => _PreShowDialogState();
}

class _PreShowDialogState extends State<PreShowDialog> {
  late final List<String> _keys = [
    for (final n in widget.needs) RenderQueue.keyOf(n.song, n.shift, n.song.tempo)!,
  ];
  final _done = <int, bool>{}; // index -> rendered ok (false = failed)
  bool _closed = false;

  /// Pops once. The State stays mounted through the exit animation, so a render finishing right after
  /// a button press must not pop again (that would pop the screen underneath).
  void _close(bool go) {
    if (_closed) return;
    _closed = true;
    Navigator.pop(context, go);
  }

  @override
  void initState() {
    super.initState();
    // The queue runs them one at a time, in this order, behind anything already rendering.
    for (final (i, n) in widget.needs.indexed) {
      renderQueue.add(n.song, n.shift, n.song.tempo).then((File? f) {
        if (!mounted) return;
        setState(() => _done[i] = f != null);
        if (_done.length == _keys.length && !_done.containsValue(false)) _close(true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final failed = _done.values.where((ok) => !ok).length;
    final finished = _done.length == _keys.length;
    return AlertDialog(
      backgroundColor: K.surface1,
      title: const Text('Pre-show check'),
      content: SizedBox(
        width: 560,
        child: ValueListenableBuilder(
          valueListenable: renderQueue.jobs,
          builder: (_, jobs, _) => ListenableBuilder(
            // Rebuild on every progress tick of this setlist's renders.
            listenable: Listenable.merge([for (final k in _keys) jobs[k]]),
            builder: (_, _) {
              double p(int i) => _done.containsKey(i) ? 1 : (jobs[_keys[i]]?.value ?? 0);
              final overall = [for (var i = 0; i < _keys.length; i++) p(i)].fold(0.0, (a, b) => a + b) / _keys.length;
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  finished
                      ? '$failed render${failed == 1 ? '' : 's'} failed. Those songs will play at the original key and tempo.'
                      : 'Rendering ${_keys.length} song${_keys.length == 1 ? '' : 's'} at their key/tempo, one at a time.',
                ),
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  value: overall, minHeight: 8, color: K.accent, backgroundColor: K.surface2,
                  borderRadius: BorderRadius.circular(4)),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ListView(shrinkWrap: true, children: [
                    for (final (i, n) in widget.needs.indexed)
                      SizedBox(
                        height: 36,
                        child: Row(children: [
                          Expanded(child: Text(n.song.title, overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 12),
                          Text(renderLabel(n.song, n.shift), style: const TextStyle(color: K.muted)),
                          const SizedBox(width: 16),
                          SizedBox(
                            width: 96,
                            child: Text(
                              switch (_done[i]) {
                                true => 'Done',
                                false => 'Failed',
                                null => p(i) == 0 ? 'Waiting' : '${(p(i) * 100).round()} %',
                              },
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontFeatures: K.tabular,
                                  color: _done[i] == false ? K.status(SongStatus.needsLyrics) : K.muted),
                            ),
                          ),
                        ]),
                      ),
                  ]),
                ),
              ]);
            },
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => _close(false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => _close(true),
          child: Text(finished ? 'Launch' : 'Launch anyway (originals for the rest)'),
        ),
      ],
    );
  }
}
