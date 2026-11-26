import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library.dart';
import 'preshow.dart';
import 'setlist.dart';
import 'song_details.dart';
import 'theme.dart';

/// The Library row's accordion (docs/stage-manager-plan.md WP-B3): what Ryan knows about one song,
/// with notes and tags editable in place. Notes save ~500 ms after typing stops, and on close.
class SongPanel extends StatefulWidget {
  final Song song;
  final List<String> allTags; // every tag in the library, for autocomplete
  final List<Membership> setlists;
  final Preview preview;
  final VoidCallback onTagsChanged, onClose, onDetails, onEdit, onStage;
  final ValueChanged<String> onOpenSetlist;

  const SongPanel({
    super.key,
    required this.song,
    required this.allTags,
    required this.setlists,
    required this.preview,
    required this.onTagsChanged,
    required this.onClose,
    required this.onDetails,
    required this.onEdit,
    required this.onStage,
    required this.onOpenSetlist,
  });

  @override
  State<SongPanel> createState() => _SongPanelState();
}

class _SongPanelState extends State<SongPanel> {
  Song get _s => widget.song;
  late final _notes = TextEditingController(text: _s.notes);
  final _tag = TextEditingController();
  final _tagFocus = FocusNode();
  Timer? _timer;
  bool _dirty = false;
  ScaffoldMessengerState? _messenger; // kept, so a save failing during dispose can still say so

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void dispose() {
    _flush(); // collapsing (or scrolling away) never loses the last keystrokes
    _notes.dispose();
    _tag.dispose();
    _tagFocus.dispose();
    super.dispose();
  }

  Future<void> _save(Map<String, Object?> changes) async {
    try {
      await saveSongFields(_s, changes);
    } on Object catch (e) {
      _messenger?.showSnackBar(SnackBar(content: Text('Could not save "${_s.title}": $e')));
    }
  }

  // ponytail: like setlists, a note typed in the last 500 ms before the window closes is lost.
  void _notesChanged(String _) {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), _flush);
  }

  void _flush() {
    _timer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    _save({'notes': _notes.text});
  }

  void _setTags(List<String> tags) {
    _save({'tags': tags}); // saveSongFields has no await inside: _s.json is updated before this returns
    widget.onTagsChanged(); // the Library rebuilds (tag counts) and this panel with it
  }

  void _addTag(String text) {
    final before = _s.tags;
    final next = addTag(before, text, known: widget.allTags);
    _tag.clear();
    if (next.length != before.length) _setTags(next);
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): widget.onClose},
      child: Container(
        color: K.bg,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _facts(s),
          const SizedBox(height: 16),
          if (s.json.isEmpty)
            const Text('Studio is still processing this song: nothing to edit yet.', style: TextStyle(color: K.muted))
          else
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextField(
                  controller: _notes,
                  minLines: 3,
                  maxLines: 5, // longer notes scroll inside the field
                  onChanged: _notesChanged,
                  decoration: const InputDecoration(labelText: 'Notes', alignLabelWithHint: true),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(child: _tags(s)),
            ]),
          const SizedBox(height: 16),
          _label('IN SETLISTS'),
          const SizedBox(height: 4),
          if (widget.setlists.isEmpty)
            const Text('Not in any setlist', style: TextStyle(color: K.muted))
          else
            for (final m in widget.setlists) _setlistRow(s, m),
          const SizedBox(height: 16),
          _buttons(s),
        ]),
      ),
    );
  }

  Widget _label(String t) =>
      Text(t, style: const TextStyle(color: K.muted, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1));

  Widget _fact(String label, Widget value) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_label(label), const SizedBox(height: 4), value],
      );

  Widget _facts(Song s) {
    const v = TextStyle(fontWeight: FontWeight.w600, fontFeatures: K.tabular);
    return Wrap(spacing: 32, runSpacing: 12, children: [
      _fact('KEY · TEMPO', Text(renderLabel(s, s.keyShift), style: v)),
      _fact('BPM', Text(s.bpm == null ? '—' : formatBpm(s.bpm), style: v)),
      _fact('LENGTH', Text(mss(s.playedDuration), style: v)),
      _fact('LANGUAGE', Text(s.language.isEmpty ? '—' : s.language[0].toUpperCase() + s.language.substring(1), style: v)),
      _fact('LYRICS', Row(mainAxisSize: MainAxisSize.min, children: [
        StatusChip(s.status),
        if (s.isDraft) ...[const SizedBox(width: 8), DraftBadge(s)],
      ])),
    ]);
  }

  Widget _tags(Song s) {
    final tags = s.tags;
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final t in tags)
        Chip(
          label: Text(t),
          backgroundColor: K.surface2,
          side: BorderSide.none,
          deleteButtonTooltipMessage: 'Remove tag',
          onDeleted: () => _setTags([...tags]..remove(t)),
        ),
      SizedBox(
        width: 340,
        child: Autocomplete<String>(
          textEditingController: _tag,
          focusNode: _tagFocus,
          optionsBuilder: (v) {
            final q = v.text.trim().toLowerCase();
            if (q.isEmpty) return const [];
            final have = {for (final t in s.tags) t.toLowerCase()};
            return widget.allTags.where((t) => t.toLowerCase().contains(q) && !have.contains(t.toLowerCase()));
          },
          onSelected: _addTag,
          fieldViewBuilder: (_, c, focus, _) => TextField(
            controller: c,
            focusNode: focus,
            // ponytail: Enter adds what's typed (in the library's casing), not the highlighted suggestion;
            // click a suggestion to pick it. Wire RawAutocomplete's onFieldSubmitted if arrow+Enter is missed.
            onSubmitted: _addTag,
            onEditingComplete: () {}, // keep focus for the next tag
            decoration: const InputDecoration(
                hintText: 'genre, occasion… e.g. Goan, Wedding, Slow dance', prefixIcon: Icon(Icons.sell_outlined)),
          ),
        ),
      ),
    ]);
  }

  Widget _setlistRow(Song s, Membership m) {
    final shift = m.item.keyShift ?? s.keyShift;
    final key = s.originalKey.isEmpty ? '${shift > 0 ? '+' : ''}$shift st' : shiftKey(s.originalKey, shift);
    final where = [m.list.date, m.list.venue].where((x) => x.isNotEmpty).join(' · ');
    return InkWell(
      onTap: () => widget.onOpenSetlist(m.list.id),
      hoverColor: K.surface2,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(children: [
          const Icon(Icons.queue_music, size: 16, color: K.muted),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: m.list.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (where.isNotEmpty) TextSpan(text: '  $where', style: const TextStyle(color: K.muted)),
              ]),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
              width: 90,
              child: Text('#${m.position} of ${m.count}', style: const TextStyle(fontFeatures: K.tabular))),
          SizedBox(
            width: 150,
            child: Text(m.item.keyShift == null ? 'Key $key' : 'Gig key $key',
                style: TextStyle(color: m.item.keyShift == null ? K.text : K.accent)),
          ),
          Expanded(
            flex: 4,
            child: Text(m.item.notes.isEmpty ? '—' : m.item.notes,
                overflow: TextOverflow.ellipsis, style: const TextStyle(color: K.muted)),
          ),
        ]),
      ),
    );
  }

  Widget _buttons(Song s) {
    final playable = s.playable;
    final playing = widget.preview.playing.value == s.id;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      OutlinedButton.icon(
          onPressed: s.json.isEmpty ? null : widget.onDetails, icon: const Icon(Icons.edit, size: 18),
          label: const Text('Details…')),
      OutlinedButton.icon(
          onPressed: playable ? widget.onEdit : null, icon: const Icon(Icons.edit_note, size: 18),
          label: const Text('Edit lyrics')),
      OutlinedButton.icon(
          onPressed: playable ? () => widget.preview.toggle(s) : null,
          icon: Icon(playing ? Icons.stop : Icons.play_arrow, size: 18),
          label: const Text('Preview 15 s')),
      FilledButton.icon(
          onPressed: playable ? widget.onStage : null, icon: const Icon(Icons.mic_external_on, size: 18),
          label: const Text('Open in stage')),
    ]);
  }
}
