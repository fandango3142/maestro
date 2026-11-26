import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'library.dart';
import 'lyrics_view.dart';
import 'theme.dart';

// All multi-window code lives here behind open / send / close (docs/d0-spike-report.md), so it can move
// to Flutter's own windowing once that reaches stable. The lyrics window is a second engine in the same
// process: it only renders the LyricsState it is sent, and audio never leaves the presenter.

const _arg = 'lyrics';
const _channel = WindowMethodChannel('maestro/lyrics', mode: ChannelMode.unidirectional);

/// Debug smoke test without a TV: `flutter run -d windows --dart-define=LYRICS_ON_PRIMARY=true` pretends a
/// second display exists and opens the lyrics window framed (not fullscreen) on the only screen.
const _onPrimary = bool.fromEnvironment('LYRICS_ON_PRIMARY');

/// True in the engine `main()` starts for the lyrics window.
Future<bool> isLyricsWindow() async => (await WindowController.fromCurrentEngine()).arguments == _arg;

/// Displays attached right now. Swappable for tests.
Future<int> Function() countDisplays = () async => _onPrimary ? 2 : (await screenRetriever.getAllDisplays()).length;

/// Opens the lyrics window fullscreen on the external display. Swappable for tests.
Future<LyricsWindow> Function() openLyricsWindow = LyricsWindow._open;

/// The presenter's handle on the lyrics window.
class LyricsWindow {
  final Future<Object?> Function(String method, [Object? args]) invoke;
  bool _alive = true;
  LyricsWindow(this.invoke);

  /// Fire-and-forget. [onDead] runs once, when the window turns out to be gone (closed by hand, crashed,
  /// display removed); the presenter then falls back to one screen and the music never notices.
  void send(LyricsState s, VoidCallback onDead) {
    if (!_alive) return;
    invoke('state', s.encode()).catchError((Object _) {
      if (_alive) {
        _alive = false;
        onDead();
      }
      return null;
    });
  }

  void close() {
    _alive = false;
    invoke('close').catchError((Object _) => null); // already gone is fine
  }

  static Future<LyricsWindow> _open() async {
    final displays = await screenRetriever.getAllDisplays();
    final primary = await screenRetriever.getPrimaryDisplay();
    // ponytail: assumes the presenter sits on the primary display (the laptop). Choosing the display is
    // a Settings item (out of scope for D1).
    final target = displays.where((d) => d.id != primary.id).firstOrNull ?? primary;
    await WindowController.create(const WindowConfiguration(arguments: _arg, hiddenAtLaunch: true));
    final w = LyricsWindow(_channel.invokeMethod);
    // Physical pixels: screen_retriever divides by the target's scale, window_manager multiplies by the
    // window's current one, so mixed-DPI screens would land wrong (spike report). The window converts.
    final scale = target.scaleFactor ?? 1, at = target.visiblePosition ?? Offset.zero;
    final place = {'x': (at.dx + 100) * scale, 'y': (at.dy + 100) * scale, 'fullscreen': !_onPrimary};
    // The new engine needs ~130 ms to register its handler; retry until it answers (10 s max).
    for (var i = 0;; i++) {
      try {
        await w.invoke('place', place);
        break;
      } on Object {
        // ponytail: a window that never answers stays hidden in the background; nothing can close it in 0.3.1.
        if (i >= 100) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    // Showing the lyrics window steals focus; the pedal must reach the presenter. The wait matches the
    // spike's verified sequence (show, settle, refocus). One D1 smoke run without it ended unfocused.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await windowManager.focus();
    return w;
  }
}

/// Entry point of the lyrics window's engine.
void runLyricsWindow() => runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: K.theme(), home: const _Lyrics()));

class _Lyrics extends StatefulWidget {
  const _Lyrics();

  @override
  State<_Lyrics> createState() => _LyricsState();
}

class _LyricsState extends State<_Lyrics> {
  LyricsState _state = const LyricsState();
  Song? _song;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      final a = call.arguments as Map<Object?, Object?>?;
      switch (call.method) {
        case 'state':
          if (!mounted) return null;
          final s = LyricsState.decode(a!);
          if (s.song != _state.song) _song = _load(s.song);
          setState(() => _state = s);
        case 'place':
          // A small framed window well inside the target display, then fullscreen covers that monitor in
          // its real pixels whatever its scale. Never frameless first (window_manager 0.5.2 then skips the resize).
          final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
          await windowManager.setBounds(
              Rect.fromLTWH((a!['x'] as num) / dpr, (a['y'] as num) / dpr, 640, 360));
          if (a['fullscreen'] == true) await windowManager.setFullScreen(true);
          await windowManager.show();
        case 'close':
          Timer(const Duration(milliseconds: 50), windowManager.close); // answer first, then go
      }
      return null;
    });
  }

  static Song? _load(String? dir) {
    if (dir == null) return null;
    try {
      return Song.load(Directory(dir));
    } on Object {
      return null; // unreadable: show nothing rather than kill the window
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: K.bg,
        body: MouseRegion(
          cursor: SystemMouseCursors.none, // zero chrome: no pointer on the audience screen
          child: Center(child: LyricsView(state: _state, song: _song)),
        ),
      );
}
