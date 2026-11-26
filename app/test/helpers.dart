import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_manager/render.dart';

/// Stands in for the audioplayers plugin: every call succeeds, and a set source reports "prepared"
/// so nothing waits on its 30s timeout.
/// [position] is what the player reports as its current position (stage lyric tests).
void fakeAudio(WidgetTester tester, {Duration? position}) {
  final m = tester.binding.defaultBinaryMessenger;
  final sinks = <String, MockStreamHandlerEventSink>{};
  void stream(String name) => m.setMockStreamHandler(
      EventChannel(name), MockStreamHandler.inline(onListen: (_, sink) {
        sinks[name] = sink;
      }));
  stream('xyz.luan/audioplayers.global/events');
  m.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
  m.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (call) async {
    final id = (call.arguments as Map)['playerId'] as String;
    if (call.method == 'create') stream('xyz.luan/audioplayers/events/$id');
    if (call.method == 'setSourceUrl') {
      sinks['xyz.luan/audioplayers/events/$id']?.success({'event': 'audio.onPrepared', 'value': true});
    }
    if (call.method == 'getCurrentPosition') return position?.inMilliseconds;
    return null;
  });
}

/// Real font, so widths match the app (the default test font is much wider), in Ryan's
/// 1280x720 logical window (1600x900 at 125%).
Future<void> appWindow(WidgetTester tester, {double width = 1280}) async {
  final bytes = File('assets/fonts/NotoSans-Regular.ttf').readAsBytesSync();
  await (FontLoader('NotoSans')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  tester.view.physicalSize = Size(width, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Stands in for window_manager (stage mode goes fullscreen).
void fakeWindow(WidgetTester tester) => tester.binding.defaultBinaryMessenger
    .setMockMethodCallHandler(const MethodChannel('window_manager'), (_) async => null);

/// A FLAC file that is only the header: "fLaC" + a last-block STREAMINFO with [rate] and [samples].
List<int> flacHeader(int rate, int samples) {
  final info = List.filled(34, 0);
  info[10] = rate >> 12;
  info[11] = (rate >> 4) & 0xFF;
  info[12] = ((rate & 0x0F) << 4) | 0x02;
  info[13] = (samples >> 32) & 0x0F;
  info[14] = (samples >> 24) & 0xFF;
  info[15] = (samples >> 16) & 0xFF;
  info[16] = (samples >> 8) & 0xFF;
  info[17] = samples & 0xFF;
  return [...'fLaC'.codeUnits, 0x80, 0, 0, 34, ...info];
}

/// Swaps in a fresh app render queue with a fake renderer: each job waits on its gate, then writes a
/// stand-in file under the real name. Make it inside the test body, so its futures live in the test's
/// fake-time zone. One widget test per file that plays audio: audioplayers' global init future is
/// bound to the first test's zone and never completes in a second one.
class FakeRenders {
  final started = <(String, int, double)>[];
  final gates = <String, Completer<void>>{};
  final progress = <String, void Function(double)>{};

  FakeRenders() {
    renderQueue = RenderQueue()
      ..run = (s, shift, tempo, onProgress) async {
        started.add((s.id, shift, tempo));
        progress[s.id] = onProgress;
        await (gates[s.id] = Completer<void>()).future;
        return File('${s.dir.path}/render/${renderFileName(shift, tempo)}')
          ..createSync(recursive: true)
          ..writeAsStringSync('wav');
      };
  }

  Iterable<String> get ids => started.map((s) => s.$1);
  void finish(String id) => gates[id]!.complete();
}

/// A song folder in [root]/library with a 100 s instrumental (header only) and optional lyrics.
Directory tempSong(Directory root, String id, Map<String, Object?> json, {String? lrc}) {
  final d = Directory('${root.path}/library/$id')..createSync(recursive: true);
  File('${d.path}/song.json').writeAsStringSync(jsonEncode({'schema_version': 1, 'id': id, ...json}));
  File('${d.path}/instrumental.flac').writeAsBytesSync(flacHeader(44100, 44100 * 100));
  if (lrc != null) File('${d.path}/lyrics.roman.lrc').writeAsStringSync(lrc);
  return d;
}
