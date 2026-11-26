import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'editor.dart';
import 'library.dart';
import 'preshow.dart';
import 'render.dart';
import 'setlist.dart';
import 'setlists_screen.dart';
import 'song_details.dart';
import 'song_panel.dart';
import 'stage.dart';
import 'theme.dart';
import 'trim.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  // ponytail: data folder is fixed to Documents/Karaoke until the Settings screen exists.
  final docs = await getApplicationDocumentsDirectory();
  final root = Directory('${docs.path}${Platform.pathSeparator}Karaoke');
  await Directory('${root.path}/library').create(recursive: true);
  runApp(MaterialApp(
    title: 'Maestro',
    debugShowCheckedModeBanner: false,
    theme: K.theme(),
    home: LibraryScreen(root: root),
  ));
}

class LibraryScreen extends StatefulWidget {
  final Directory root;
  const LibraryScreen({super.key, required this.root});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _preview = Preview();
  List<Song> _songs = [];
  String _language = 'All';
  Object? _status; // null = all, a SongStatus, _needsName or _needsTrim
  static const _needsName = 'needs-name', _needsTrim = 'needs-trim';
  bool _setlists = false; // sidebar page: Library or Setlists
  String? _showSetlist; // the setlist the Setlists page opens on (from a panel's "In setlists")
  String? _open; // id of the song whose detail panel is open; one at a time
  String? _tag; // tag filter, null = all
  Map<String, List<Membership>> _inSetlists = {};

  @override
  void initState() {
    super.initState();
    _reload();
    _search.addListener(() => setState(() {}));
    _preview.playing.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _preview.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _reload() => setState(() {
        _songs = loadLibrary(widget.root);
        _inSetlists = setlistMembership(listSetlists(widget.root));
      });

  List<Song> get _shown {
    final q = _search.text.toLowerCase();
    final tag = _tag?.toLowerCase();
    return _songs
        .where((s) => q.isEmpty || '${s.title} ${s.artist} ${s.tags.join(' ')}'.toLowerCase().contains(q))
        .where((s) => _language == 'All' || s.language.toLowerCase() == _language.toLowerCase())
        .where((s) => switch (_status) {
              null => true,
              _needsName => s.needsName,
              _needsTrim => needsTrimReview(s),
              final st => s.status == st,
            })
        .where((s) => tag == null || s.tags.any((t) => t.toLowerCase() == tag))
        .toList();
  }

  void _toggle(Song s) => setState(() => _open = _open == s.id ? null : s.id);

  void _openSetlist(String id) {
    _preview.stop();
    setState(() {
      _showSetlist = id;
      _setlists = true;
    });
  }

  /// Song details; "Save & next unnamed" walks on through every song that still needs a name.
  Future<void> _details(Song s) async {
    await _preview.stop();
    Song? cur = s;
    while (cur != null) {
      if (!mounted) return;
      final how = await showSongDetails(context, cur, _preview);
      await _preview.stop();
      if (!mounted) return;
      setState(() {}); // saveSongFields updated the song in place: no rescan, no flicker
      if (how != null) _render(cur);
      if (how != DetailsResult.savedNext) return;
      final skipped = cur.needsName; // saved without a name (Ryan didn't know it yet)
      cur = nextUnnamed(_songs, cur);
      if (cur == null) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(skipped ? 'No other songs need a name' : 'Every song has a name now')));
      }
    }
  }

  /// Queues the render for [s]'s saved key/tempo in the background (nothing if cached or not needed).
  /// The row's chip shows progress; the dialog may already be closed.
  void _render(Song s) {
    final title = s.title;
    renderQueue.add(s, s.keyShift, s.tempo).then((f) {
      if (f == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not render "$title". It plays at the original key and tempo.')));
      }
    });
  }

  Future<void> _stage(Song? from) async {
    final queue = _shown.where((s) => s.playable).toList();
    if (queue.isEmpty) return;
    await _preview.stop();
    if (!mounted) return;
    final songs = {for (final s in queue) s.id: s};
    if (!await preShowCheck(context, missingRenders([for (final s in queue) SetItem.song(s.id)], songs))) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StageScreen.queue(queue, start: from == null ? 0 : queue.indexOf(from).clamp(0, queue.length)),
    ));
    _reload();
  }

  Future<void> _edit(Song s) async {
    await _preview.stop();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorScreen(song: s)));
    _reload();
  }

  /// The trimmer saves cuts as it goes; on the way out, render them at the song's key/tempo.
  Future<void> _trim(Song s) async {
    await _preview.stop();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TrimScreen(song: s)));
    if (!mounted) return;
    setState(() {}); // new length; the song was updated in place
    _render(s);
  }

  @override
  Widget build(BuildContext context) {
    final tags = tagCounts(_songs);
    if (_tag != null && !tags.containsKey(_tag)) _tag = null; // its last song lost the tag
    final shown = _shown;
    return CallbackShortcuts(
      // Only on Library, so '/' still types in the setlist note fields; and not while a song panel is
      // open, so it types in the panel's notes and tags.
      // ponytail: '/' doesn't jump to search while a panel is open; Esc closes the panel first.
      bindings: {
        if (!_setlists && !shown.any((s) => s.id == _open))
          const SingleActivator(LogicalKeyboardKey.slash): _searchFocus.requestFocus,
      },
      child: Scaffold(
        body: Row(children: [
          _sidebar(),
          Expanded(
            child: _setlists ? SetlistsScreen(root: widget.root, songs: _songs, select: _showSetlist) : Padding(
              padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _toolbar(tags),
                const SizedBox(height: 16),
                _readiness(),
                const SizedBox(height: 16),
                Expanded(child: _songs.isEmpty ? _empty() : _table(shown, tags.keys.toList())),
                const SizedBox(height: 12),
                Text('/ search  •  ↑ ↓ / Tab move  •  Enter show details  •  Esc close  •  E edit details  •  Mic = stage  •  Showing ${shown.length} of ${_songs.length}',
                    style: const TextStyle(color: K.muted, fontSize: 12)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _sidebar() => Container(
        width: 240,
        color: K.surface1,
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Maestro',
              style: TextStyle(color: K.accent, fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Offline  •  ${widget.root.path}',
              style: const TextStyle(color: K.muted, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 28),
          _nav(Icons.library_music_outlined, 'Library', !_setlists, () {
            setState(() => _setlists = false);
            // After this frame: the Setlists page saves its pending edit as it goes away.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _inSetlists = setlistMembership(listSetlists(widget.root)));
            });
          }),
          const SizedBox(height: 4),
          _nav(Icons.queue_music, 'Setlists', _setlists, () {
            _preview.stop(); // so a preview can't play over a stage launched from Setlists
            setState(() {
              _showSetlist = null;
              _setlists = true;
            });
          }),
          const Spacer(),
          // Stage is an action, not a page: one solid button so it never competes with the nav.
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _stage(null),
              icon: const Icon(Icons.play_circle_fill),
              label: const Text('Start stage'),
            ),
          ),
        ]),
      );

  Widget _nav(IconData icon, String label, bool selected, VoidCallback onTap) => Material(
        color: selected ? K.surface2 : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Icon(icon, color: selected ? K.accent : K.muted, size: 20),
              const SizedBox(width: 12),
              Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: selected ? K.text : K.muted)),
            ]),
          ),
        ),
      );

  Widget _toolbar(Map<String, int> tags) {
    final languages = {'All', ..._songs.map((s) => s.language).where((l) => l.isNotEmpty)};
    return Row(children: [
      Expanded(
        child: TextField(
          controller: _search,
          focusNode: _searchFocus,
          decoration: const InputDecoration(
            hintText: 'Search title, artist or tag   ( / )',
            prefixIcon: Icon(Icons.search, color: K.muted),
          ),
        ),
      ),
      const SizedBox(width: 12),
      _dropdown<String>(_language, {for (final l in languages) l: 'Language: ${_cap(l)}'},
          (v) => setState(() => _language = v ?? 'All')),
      const SizedBox(width: 12),
      _dropdown<Object?>(_status, {
        null: 'Status: All',
        for (final s in SongStatus.values) s: K.statusLabel(s),
        _needsName: 'Needs name (${_songs.where((s) => s.needsName).length})',
        _needsTrim: 'Needs trim review (${_songs.where(needsTrimReview).length})',
      }, (v) => setState(() => _status = v)),
      const SizedBox(width: 12),
      _dropdown<String?>(_tag, {null: 'Tag: All', for (final e in tags.entries) e.key: '${e.key} (${e.value})'},
          (v) => setState(() => _tag = v), width: 180),
      const SizedBox(width: 12),
      IconButton(
          tooltip: 'Rescan library folder', onPressed: _reload, icon: const Icon(Icons.refresh, color: K.muted)),
    ]);
  }

  Widget _dropdown<T>(T value, Map<T, String> items, ValueChanged<T?> onChanged, {double? width}) => Container(
        height: 46,
        width: width, // fixed (with ellipsis) for free-form text like tags
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
            color: K.surface1, border: Border.all(color: K.border), borderRadius: BorderRadius.circular(4)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: width != null,
            dropdownColor: K.surface2,
            items: [
              for (final e in items.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: onChanged,
          ),
        ),
      );

  Widget _readiness() {
    final counts = {for (final s in SongStatus.values) s: _songs.where((x) => x.status == s).length};
    final pct = _songs.isEmpty ? 0.0 : counts[SongStatus.ready]! / _songs.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        const Text('STAGE READINESS',
            style: TextStyle(color: K.muted, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1)),
        const SizedBox(width: 12),
        Text('${(pct * 100).round()}%',
            style: const TextStyle(color: K.accent, fontWeight: FontWeight.w700, fontFeatures: K.tabular)),
        const SizedBox(width: 16),
        SizedBox(
          width: 220,
          child: LinearProgressIndicator(
              value: pct, minHeight: 6, color: K.accent, backgroundColor: K.surface2,
              borderRadius: BorderRadius.circular(3)),
        ),
        const Spacer(),
        for (final s in SongStatus.values) ...[
          Container(width: 6, height: 6, decoration: BoxDecoration(color: K.status(s), shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text('${counts[s]} ${K.statusLabel(s)}', style: const TextStyle(color: K.muted, fontSize: 13)),
          const SizedBox(width: 16),
        ],
      ]),
    );
  }

  static const _cols = [4, 3, 3, 2, 1, 2, 3]; // title, artist, language, key, bpm, duration, status (flex)

  Widget _table(List<Song> songs, List<String> allTags) => Container(
        decoration: BoxDecoration(color: K.surface1, borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          _row(const ['TITLE', 'ARTIST', 'LANGUAGE', 'KEY', 'BPM', 'DURATION', 'STATUS'], header: true),
          Expanded(
            child: songs.isEmpty
                ? const Center(child: Text('No songs match', style: TextStyle(color: K.muted)))
                : ListView.separated(
                    itemCount: songs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, color: K.divider),
                    itemBuilder: (_, i) => _songRow(songs[i], allTags),
                  ),
          ),
        ]),
      );

  Widget _row(List<Object> cells, {bool header = false, bool selected = false, List<Widget> actions = const []}) {
    final style = header
        ? const TextStyle(color: K.muted, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1)
        : const TextStyle(fontSize: 14);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      color: header || selected ? K.surface2 : null,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(children: [
        for (final (i, c) in cells.indexed)
          Expanded(
            flex: _cols[i],
            child: Padding(
              padding: const EdgeInsets.only(right: 12), // gap so a long title can't touch the next column
              child: c is Widget && i == 0
                  ? c // the title cell lays itself out (ellipsis), it must not be scaled
                  : c is Widget
                  // scaleDown: a chip shrinks rather than overflowing a narrow window
                  ? Align(alignment: Alignment.centerLeft, child: FittedBox(fit: BoxFit.scaleDown, child: c))
                  : Text('$c', style: i == 0 && !header ? style.copyWith(fontWeight: FontWeight.w600) : style,
                      overflow: TextOverflow.ellipsis),
            ),
          ),
        SizedBox(width: 248, child: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions)),
      ]),
    );
  }

  Widget _songRow(Song s, List<String> allTags) {
    final playable = s.playable;
    final hasJson = s.json.isNotEmpty; // no song.json yet = Studio still processing: nothing to edit
    final open = _open == s.id;
    // The panel sits outside the row's shortcuts, so E still types in its fields.
    final row = CallbackShortcuts(
      bindings: {
        if (hasJson) const SingleActivator(LogicalKeyboardKey.keyE): () => _details(s),
        if (open) const SingleActivator(LogicalKeyboardKey.escape): () => _toggle(s),
      },
      child: InkWell(
        onTap: () => _toggle(s), // Enter too. Stage opens only from the mic button and Start stage.
        hoverColor: K.surface2,
        focusColor: K.surface2,
        child: _row([
          s.isDraft
              ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  DraftBadge(s),
                ])
              : s.title,
          s.artist.isEmpty ? '—' : s.artist,
          s.language.isEmpty ? '—' : _cap(s.language),
          s.key.isEmpty ? '—' : s.key,
          s.bpm?.round() ?? '—',
          mss(s.playedDuration),
          Row(mainAxisSize: MainAxisSize.min, children: [StatusChip(s.status), RenderChip(s)]),
        ], actions: [
          if (hasJson)
            IconButton(tooltip: 'Song details  (E)', onPressed: () => _details(s), icon: const Icon(Icons.edit)),
          if (playable)
            IconButton(tooltip: 'Edit lyrics timing', onPressed: () => _edit(s), icon: const Icon(Icons.edit_note)),
          if (playable) ...[
            TextButton.icon(
              onPressed: () => _preview.toggle(s),
              icon: Icon(_preview.playing.value == s.id ? Icons.stop : Icons.play_arrow, size: 18),
              label: const Text('15s'),
            ),
            IconButton(
                tooltip: 'Open in stage', onPressed: () => _stage(s), icon: const Icon(Icons.mic_external_on)),
          ],
        ], selected: open),
      ),
    );
    if (!open) return KeyedSubtree(key: ValueKey(s.id), child: row);
    return Column(key: ValueKey(s.id), mainAxisSize: MainAxisSize.min, children: [
      row,
      SongPanel(
        song: s,
        allTags: allTags,
        setlists: _inSetlists[s.id] ?? const [],
        preview: _preview,
        onTagsChanged: () => setState(() {}),
        onClose: () => _toggle(s),
        onDetails: () => _details(s),
        onEdit: () => _edit(s),
        onTrim: () => _trim(s),
        onStage: () => _stage(s),
        onOpenSetlist: _openSetlist,
      ),
    ]);
  }

  Widget _empty() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.library_music_outlined, size: 48, color: K.muted),
          const SizedBox(height: 12),
          const Text('No songs yet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SelectableText('Copy processed song folders from Studio into\n${widget.root.path}${Platform.pathSeparator}library',
              textAlign: TextAlign.center, style: const TextStyle(color: K.muted)),
        ]),
      );
}

/// "Rendering 42 %" while the render for [song]'s own key/tempo is queued or running; nothing otherwise.
class RenderChip extends StatelessWidget {
  final Song song;
  const RenderChip(this.song, {super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: renderQueue.jobs,
        builder: (_, jobs, _) {
          final progress = jobs[RenderQueue.keyOf(song, song.keyShift, song.tempo)];
          if (progress == null) return const SizedBox.shrink();
          return ValueListenableBuilder(
            valueListenable: progress,
            builder: (_, p, _) => Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: K.surface2, borderRadius: BorderRadius.circular(12)),
              child: Text('Rendering ${(p * 100).round()} %',
                  style: const TextStyle(color: K.accent, fontSize: 12, fontFeatures: K.tabular)),
            ),
          );
        },
      );
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
