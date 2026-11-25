import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'library.dart';
import 'setlist.dart';
import 'stage.dart';
import 'theme.dart';

/// Setlists (SPEC.md §5.3, design/setlists/screen.png). Every edit autosaves ~500 ms later.
class SetlistsScreen extends StatefulWidget {
  final Directory root;
  final List<Song> songs;
  const SetlistsScreen({super.key, required this.root, required this.songs});

  @override
  State<SetlistsScreen> createState() => _SetlistsScreenState();
}

class _SetlistsScreenState extends State<SetlistsScreen> {
  List<Setlist> _lists = [];
  Setlist? _sel;
  Setlist? _dirty; // has an unsaved change
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _flush();
    super.dispose();
  }

  void _load({String? select}) {
    _lists = listSetlists(widget.root);
    final id = select ?? _sel?.id;
    _sel = _lists.where((s) => s.id == id).firstOrNull ?? _lists.firstOrNull;
  }

  // ponytail: an edit made in the last 500 ms before the window is closed is lost; flush on exit if that bites.
  void _changed() {
    setState(() {});
    _dirty = _sel;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _flush);
  }

  void _flush() {
    _saveTimer?.cancel();
    _dirty?.save();
    _dirty = null;
  }

  Map<String, Song> get _byId => {for (final s in widget.songs) s.id: s};

  ({List<Duration> starts, Duration total}) _plan(Setlist s, Map<String, Song> byId) => planTimes(
    s.items,
    (id) => byId[id]?.playedDuration,
    parseClock(s.startTime) ?? Duration.zero,
    Duration(seconds: s.changeoverS),
  );

  Future<String?> _askName(String title, String initial) async {
    final c = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: K.surface1,
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    c.dispose();
    final t = name?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  Future<void> _new() async {
    final name = await _askName('New setlist', '');
    if (name == null) return;
    _flush();
    final s = createSetlist(widget.root, name);
    setState(() => _load(select: s.id));
  }

  Future<void> _rename(Setlist s) async {
    final name = await _askName('Rename setlist', s.name);
    if (name == null) return;
    s.json['name'] = name; // the file name stays the same
    _changed();
  }

  void _duplicate(Setlist s) {
    _flush();
    final copy = createSetlist(widget.root, '${s.name} copy', from: s);
    setState(() => _load(select: copy.id));
  }

  Future<void> _delete(Setlist s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: K.surface1,
        title: Text('Delete "${s.name}"?'),
        content: const Text('This removes the setlist file. Songs in the library are not touched.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    if (_dirty == s) {
      _saveTimer?.cancel();
      _dirty = null;
    }
    _flush();
    if (s.file.existsSync()) s.file.deleteSync();
    setState(() {
      _sel = null;
      _load();
    });
  }

  Future<void> _addSongs(Setlist s) async {
    final q = TextEditingController();
    var added = 0;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) {
          final text = q.text.toLowerCase();
          final shown = widget.songs.where((x) => '${x.title} ${x.artist}'.toLowerCase().contains(text)).toList();
          return AlertDialog(
            backgroundColor: K.surface1,
            title: Text(added == 0 ? 'Add songs' : 'Add songs  •  $added added'),
            content: SizedBox(
              width: 560,
              height: 480,
              child: Column(
                children: [
                  TextField(
                    controller: q,
                    autofocus: true,
                    onChanged: (_) => setDialog(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Search title or artist',
                      prefixIcon: Icon(Icons.search, color: K.muted),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: shown.isEmpty
                        ? const Center(
                            child: Text('No songs match', style: TextStyle(color: K.muted)),
                          )
                        : ListView.builder(
                            itemCount: shown.length,
                            itemBuilder: (_, i) {
                              final song = shown[i];
                              return ListTile(
                                title: Text(song.title, overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  [
                                    song.artist,
                                    _cap(song.language),
                                    mss(song.playedDuration),
                                  ].where((x) => x.isNotEmpty).join('  •  '),
                                  style: const TextStyle(color: K.muted),
                                ),
                                trailing: StatusChip(song.status),
                                hoverColor: K.surface2,
                                onTap: () {
                                  s.items.add(SetItem.song(song.id));
                                  _changed();
                                  setDialog(() => added++);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
          );
        },
      ),
    );
    q.dispose();
  }

  Future<void> _launch(Setlist s, Map<String, Song> byId) async {
    _flush();
    // Missing and unplayable songs are skipped; the banner already warned about them.
    final items = s.items.where((i) => i.isBreak || (byId[i.songId]?.playable ?? false)).toList();
    if (!items.any((i) => !i.isBreak)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No playable songs in this setlist')));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StageScreen(
          items: items,
          songs: byId,
          changeover: Duration(seconds: s.changeoverS),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final byId = _byId;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 280, child: _listColumn(byId)),
          const SizedBox(width: 24),
          Expanded(child: _sel == null ? _empty() : _editor(_sel!, byId)),
        ],
      ),
    );
  }

  Widget _listColumn(Map<String, Song> byId) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.queue_music, color: K.muted, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Setlists', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            Text('${_lists.length} saved', style: const TextStyle(color: K.muted, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _new, icon: const Icon(Icons.add), label: const Text('New setlist')),
        const SizedBox(height: 12),
        Expanded(child: ListView(children: [for (final s in _lists) _tile(s, byId)])),
        if (_sel != null)
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: () => _rename(_sel!),
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('Rename'),
              ),
              TextButton.icon(
                onPressed: () => _duplicate(_sel!),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Duplicate'),
              ),
              TextButton.icon(
                onPressed: () => _delete(_sel!),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Delete'),
              ),
            ],
          ),
      ],
    ),
  );

  Widget _tile(Setlist s, Map<String, Song> byId) {
    final selected = s == _sel;
    final songs = s.items.where((i) => !i.isBreak).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? K.surface2 : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            _flush();
            setState(() => _sel = s);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w600, color: selected ? K.accent : K.text),
                ),
                const SizedBox(height: 4),
                Text(
                  '$songs song${songs == 1 ? '' : 's'}  •  ${mss(_plan(s, byId).total)}',
                  style: const TextStyle(color: K.muted, fontSize: 13, fontFeatures: K.tabular),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty() => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.queue_music, size: 48, color: K.muted),
        SizedBox(height: 12),
        Text('No setlists yet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        SizedBox(height: 6),
        Text('Press "New setlist" to build one.', style: TextStyle(color: K.muted)),
      ],
    ),
  );

  Widget _editor(Setlist s, Map<String, Song> byId) {
    final plan = _plan(s, byId);
    final start = parseClock(s.startTime);
    final problems = <String>{
      for (final i in s.items)
        if (!i.isBreak && byId[i.songId]?.status != SongStatus.ready)
          byId[i.songId] == null ? '${i.songId} (missing)' : byId[i.songId]!.title,
    };
    var no = 0;
    final numbers = [for (final i in s.items) i.isBreak ? 0 : ++no];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(s, plan.total, start),
        if (problems.isNotEmpty) ...[const SizedBox(height: 16), _banner(problems)],
        const SizedBox(height: 20),
        Row(
          children: [
            const Text('Setlist order', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Drag the handle to reorder',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: K.muted, fontSize: 12),
              ),
            ),
            OutlinedButton.icon(
              onPressed: () {
                s.items.add(SetItem.pause());
                _changed();
              },
              icon: const Icon(Icons.coffee, size: 18),
              label: const Text('Add break'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _addSongs(s),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add songs'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: s.items.isEmpty
              ? const Center(
                  child: Text('No songs yet. Use "Add songs" or "Add break".', style: TextStyle(color: K.muted)),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: s.items.length,
                  onReorderItem: (from, to) {
                    s.items.insert(to, s.items.removeAt(from));
                    _changed();
                  },
                  itemBuilder: (_, i) {
                    final item = s.items[i];
                    final clock = start == null ? null : formatClock(plan.starts[i]);
                    return item.isBreak
                        ? _breakRow(s, item, i, clock)
                        : _songRow(s, item, i, numbers[i], clock, byId[item.songId]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _header(Setlist s, Duration total, Duration? start) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                s.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(color: K.bg, borderRadius: BorderRadius.circular(8)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'TOTAL RUNNING TIME',
                    style: TextStyle(color: K.muted, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1),
                  ),
                  Text(
                    mss(total),
                    style: const TextStyle(
                      color: K.accent,
                      fontSize: 40,
                      fontWeight: FontWeight.w700,
                      fontFeatures: K.tabular,
                    ),
                  ),
                  if (start != null)
                    Text('Ends at ${formatClock(start + total)}', style: const TextStyle(color: K.muted, fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 24),
            FilledButton.icon(
              onPressed: () => _launch(s, _byId),
              icon: const Icon(Icons.mic_external_on),
              label: const Text('Launch Stage Mode'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _field(s, 'date', s.date, 'Date', 'YYYY-MM-DD', 150),
            _field(s, 'venue', s.venue, 'Venue', '', 220),
            _field(s, 'start_time', s.startTime, 'Start time', '20:00', 110),
            _field(s, 'changeover_s', '${s.changeoverS}', 'Changeover (s)', '30', 130, digits: true),
          ],
        ),
      ],
    ),
  );

  /// A header field written straight into the setlist JSON under [key].
  Widget _field(
    Setlist s,
    String key,
    String initial,
    String label,
    String hint,
    double width, {
    bool digits = false,
  }) => SizedBox(
    width: width,
    child: TextFormField(
      key: ValueKey((s, key)), // fresh field per setlist
      initialValue: initial,
      decoration: InputDecoration(labelText: label, hintText: hint),
      inputFormatters: digits ? [FilteringTextInputFormatter.digitsOnly] : null,
      onChanged: (v) {
        if (digits) {
          final n = int.tryParse(v);
          if (n == null) return; // half-typed: keep the last good number
          s.json[key] = n;
        } else {
          s.json[key] = v;
        }
        _changed();
      },
    ),
  );

  Widget _banner(Set<String> names) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    decoration: BoxDecoration(
      color: K.accent.withValues(alpha: 0.08),
      border: Border.all(color: K.accent.withValues(alpha: 0.3)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.warning_amber_rounded, color: K.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '${names.length} song${names.length == 1 ? ' is' : 's are'} not ready: ${names.join(', ')}. '
            'Sync lyrics before stage mode; missing songs are skipped.',
          ),
        ),
      ],
    ),
  );

  Widget _handle(int i) => ReorderableDragStartListener(
    index: i,
    child: const MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: SizedBox(width: 44, height: 44, child: Icon(Icons.drag_indicator, color: K.muted)),
    ),
  );

  Widget _remove(Setlist s, SetItem item) => IconButton(
    tooltip: 'Remove from setlist',
    onPressed: () {
      s.items.remove(item);
      _changed();
    },
    icon: const Icon(Icons.close),
  );

  Widget _clock(String? clock) => SizedBox(
    width: 72,
    child: Text(
      clock ?? '',
      style: const TextStyle(color: K.muted, fontFeatures: K.tabular),
    ),
  );

  Widget _songRow(Setlist s, SetItem item, int i, int no, String? clock, Song? song) {
    final missing = song == null;
    final language = missing ? '' : _cap(song.language);
    return Container(
      key: ObjectKey(item),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
      child: Row(
        children: [
          _handle(i),
          SizedBox(
            width: 32,
            child: Text('$no', style: const TextStyle(color: K.muted)),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        missing ? item.songId : song.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: missing ? K.muted : K.text,
                          decoration: missing ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ),
                    if (language.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: K.surface2, borderRadius: BorderRadius.circular(4)),
                        child: Text(language, style: const TextStyle(fontSize: 12, color: K.muted)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (missing)
                      Text(
                        'Missing from library',
                        style: TextStyle(color: K.status(SongStatus.needsLyrics), fontSize: 12),
                      )
                    else
                      StatusChip(song.status),
                    Text(
                      missing ? mss(Duration.zero) : mss(song.playedDuration),
                      style: const TextStyle(color: K.muted, fontFeatures: K.tabular),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _clock(clock),
          if (!missing) _keyDropdown(item, song),
          const SizedBox(width: 12),
          Expanded(
            flex: 2, // flexes with the window so the song name keeps room
            child: TextFormField(
              initialValue: item.notes,
              decoration: const InputDecoration(hintText: 'Add gig note…'),
              onChanged: (v) {
                item.json['notes'] = v;
                _changed();
              },
            ),
          ),
          const SizedBox(width: 4),
          _remove(s, item),
        ],
      ),
    );
  }

  Widget _keyDropdown(SetItem item, Song song) {
    final orig = song.originalKey;
    String shifted(int n) => orig.isEmpty || n == 0 ? orig : '$orig → ${shiftKey(orig, n)}';
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: K.bg,
        border: Border.all(color: K.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int?>(
          value: item.keyShift?.clamp(-6, 6),
          dropdownColor: K.surface2,
          items: [
            DropdownMenuItem(value: null, child: Text('Default${song.key.isEmpty ? '' : '  ${song.key}'}')),
            for (var n = -6; n <= 6; n++)
              DropdownMenuItem(value: n, child: Text('${n > 0 ? '+' : ''}$n  ${shifted(n)}')),
          ],
          // Closed button shows just the resulting key, so the row stays narrow.
          selectedItemBuilder: (_) => [
            Center(child: Text('Key: ${song.key.isEmpty ? 'default' : song.key}')),
            for (var n = -6; n <= 6; n++) Center(child: Text('Key: ${orig.isEmpty ? n : shifted(n)}')),
          ],
          onChanged: (v) {
            item.json['key_shift'] = v;
            _changed();
          },
        ),
      ),
    );
  }

  Widget _breakRow(Setlist s, SetItem item, int i, String? clock) => Container(
    key: ObjectKey(item),
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: K.bg,
      border: Border.all(color: K.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        _handle(i),
        const SizedBox(width: 32, child: Icon(Icons.coffee, color: K.muted, size: 20)),
        Expanded(
          child: TextFormField(
            initialValue: item.label,
            decoration: const InputDecoration(hintText: 'Break label'),
            onChanged: (v) {
              item.json['label'] = v;
              _changed();
            },
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 100,
          child: TextFormField(
            initialValue: '${item.minutes}',
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(suffixText: 'min'),
            onChanged: (v) {
              final n = int.tryParse(v);
              if (n == null) return;
              item.json['minutes'] = n;
              _changed();
            },
          ),
        ),
        const SizedBox(width: 12),
        _clock(clock),
        _remove(s, item),
      ],
    ),
  );
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
