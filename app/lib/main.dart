import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'editor.dart';
import 'library.dart';
import 'setlists_screen.dart';
import 'stage.dart';
import 'theme.dart';

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
  final _preview = AudioPlayer();
  Timer? _previewStop;
  String? _previewing;
  List<Song> _songs = [];
  String _language = 'All';
  SongStatus? _status;
  bool _setlists = false; // sidebar page: Library or Setlists

  @override
  void initState() {
    super.initState();
    _reload();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _previewStop?.cancel();
    _preview.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _reload() => setState(() => _songs = loadLibrary(widget.root));

  List<Song> get _shown {
    final q = _search.text.toLowerCase();
    return _songs
        .where((s) => q.isEmpty || '${s.title} ${s.artist}'.toLowerCase().contains(q))
        .where((s) => _language == 'All' || s.language.toLowerCase() == _language.toLowerCase())
        .where((s) => _status == null || s.status == _status)
        .toList();
  }

  Future<void> _togglePreview(Song s) async {
    _previewStop?.cancel();
    await _preview.stop();
    if (_previewing == s.id) return setState(() => _previewing = null);
    setState(() => _previewing = s.id);
    await _preview.play(DeviceFileSource(s.audio.path), position: const Duration(seconds: 30));
    _previewStop = Timer(const Duration(seconds: 15), () {
      _preview.stop();
      if (mounted) setState(() => _previewing = null);
    });
  }

  Future<void> _stage(Song? from) async {
    final queue = _shown.where((s) => s.playable).toList();
    if (queue.isEmpty) return;
    _previewStop?.cancel();
    await _preview.stop();
    setState(() => _previewing = null);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StageScreen.queue(queue, start: from == null ? 0 : queue.indexOf(from).clamp(0, queue.length)),
    ));
    _reload();
  }

  Future<void> _edit(Song s) async {
    _previewStop?.cancel();
    await _preview.stop();
    setState(() => _previewing = null);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorScreen(song: s)));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return CallbackShortcuts(
      // Only on Library, so '/' still types in the setlist note fields.
      bindings: {if (!_setlists) const SingleActivator(LogicalKeyboardKey.slash): _searchFocus.requestFocus},
      child: Scaffold(
        body: Row(children: [
          _sidebar(),
          Expanded(
            child: _setlists ? SetlistsScreen(root: widget.root, songs: _songs) : Padding(
              padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _toolbar(),
                const SizedBox(height: 16),
                _readiness(),
                const SizedBox(height: 16),
                Expanded(child: _songs.isEmpty ? _empty() : _table(shown)),
                const SizedBox(height: 12),
                Text('/ search  •  ↑ ↓ / Tab move  •  Enter open in stage  •  Showing ${shown.length} of ${_songs.length}',
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
          _nav(Icons.library_music_outlined, 'Library', !_setlists, () => setState(() => _setlists = false)),
          const SizedBox(height: 4),
          _nav(Icons.queue_music, 'Setlists', _setlists, () {
            _previewStop?.cancel();
            _preview.stop(); // so a preview can't play over a stage launched from Setlists
            setState(() {
              _previewing = null;
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

  Widget _toolbar() {
    final languages = {'All', ..._songs.map((s) => s.language).where((l) => l.isNotEmpty)};
    return Row(children: [
      Expanded(
        child: TextField(
          controller: _search,
          focusNode: _searchFocus,
          decoration: const InputDecoration(
            hintText: 'Search title or artist   ( / )',
            prefixIcon: Icon(Icons.search, color: K.muted),
          ),
        ),
      ),
      const SizedBox(width: 12),
      _dropdown<String>(_language, {for (final l in languages) l: 'Language: ${_cap(l)}'},
          (v) => setState(() => _language = v ?? 'All')),
      const SizedBox(width: 12),
      _dropdown<SongStatus?>(_status, {
        null: 'Status: All',
        for (final s in SongStatus.values) s: K.statusLabel(s),
      }, (v) => setState(() => _status = v)),
      const SizedBox(width: 12),
      IconButton(
          tooltip: 'Rescan library folder', onPressed: _reload, icon: const Icon(Icons.refresh, color: K.muted)),
    ]);
  }

  Widget _dropdown<T>(T value, Map<T, String> items, ValueChanged<T?> onChanged) => Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
            color: K.surface1, border: Border.all(color: K.border), borderRadius: BorderRadius.circular(4)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            dropdownColor: K.surface2,
            items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
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

  Widget _table(List<Song> songs) => Container(
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
                    itemBuilder: (_, i) => _songRow(songs[i]),
                  ),
          ),
        ]),
      );

  Widget _row(List<Object> cells, {bool header = false, List<Widget> actions = const []}) {
    final style = header
        ? const TextStyle(color: K.muted, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1)
        : const TextStyle(fontSize: 14);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      color: header ? K.surface2 : null,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(children: [
        for (final (i, c) in cells.indexed)
          Expanded(
            flex: _cols[i],
            child: Padding(
              padding: const EdgeInsets.only(right: 12), // gap so a long title can't touch the next column
              child: c is Widget
                  // scaleDown: a chip shrinks rather than overflowing a narrow window
                  ? Align(alignment: Alignment.centerLeft, child: FittedBox(fit: BoxFit.scaleDown, child: c))
                  : Text('$c', style: i == 0 && !header ? style.copyWith(fontWeight: FontWeight.w600) : style,
                      overflow: TextOverflow.ellipsis),
            ),
          ),
        SizedBox(width: 200, child: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions)),
      ]),
    );
  }

  Widget _songRow(Song s) {
    final playable = s.playable;
    return InkWell(
      onTap: playable ? () => _stage(s) : null,
      hoverColor: K.surface2,
      focusColor: K.surface2,
      child: _row([
        s.title,
        s.artist.isEmpty ? '—' : s.artist,
        s.language.isEmpty ? '—' : _cap(s.language),
        s.key.isEmpty ? '—' : s.key,
        s.bpm?.round() ?? '—',
        mss(s.playedDuration),
        StatusChip(s.status),
      ], actions: [
        if (playable)
          IconButton(tooltip: 'Edit lyrics timing', onPressed: () => _edit(s), icon: const Icon(Icons.edit_note)),
        if (playable) ...[
          TextButton.icon(
            onPressed: () => _togglePreview(s),
            icon: Icon(_previewing == s.id ? Icons.stop : Icons.play_arrow, size: 18),
            label: const Text('15s'),
          ),
          IconButton(
              tooltip: 'Open in stage', onPressed: () => _stage(s), icon: const Icon(Icons.mic_external_on)),
        ],
      ]),
    );
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

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
