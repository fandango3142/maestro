import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the audioplayers plugin: every call succeeds, and a set source reports "prepared"
/// so nothing waits on its 30s timeout.
void fakeAudio(WidgetTester tester) {
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
