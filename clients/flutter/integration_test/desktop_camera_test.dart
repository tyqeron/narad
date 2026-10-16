import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/audio.dart';

/// Run via tests/android_e2e.py --desktop-camera with a temporary paired source.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'desktop renders a paired Android camera through Narad signaling',
    (tester) async {
      final state = Platform.environment['NARAD_CAMERA_STATE'] ?? '';
      final port =
          int.tryParse(Platform.environment['NARAD_CAMERA_PORT'] ?? '') ?? 0;
      final peer = Platform.environment['NARAD_CAMERA_PEER'] ?? '';
      expect(state, isNotEmpty, reason: 'Use the physical fixture harness');
      expect(peer, isNotEmpty);
      final api = DaemonApi(state, port);
      final errors = <Object>[];
      final controller = AudioController(api, errors.add);
      try {
        final id = await controller.startCamera(peer);
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        RTCVideoRenderer? renderer;
        while (DateTime.now().isBefore(deadline)) {
          final status = await api.call({'op': 'status'});
          await controller.tick(status);
          expect(errors, isEmpty);
          expect(
            controller.links.containsKey(id),
            isTrue,
            reason: 'Camera session ended before video arrived',
          );
          renderer = controller.links[id]?.renderer;
          if (renderer != null) {
            await tester.pumpWidget(
              MaterialApp(home: Scaffold(body: RTCVideoView(renderer))),
            );
            if (renderer.videoWidth > 0 && renderer.videoHeight > 0) break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        expect(renderer, isNotNull);
        expect(renderer!.videoWidth, greaterThan(0));
        expect(renderer.videoHeight, greaterThan(0));
        expect(errors, isEmpty);
        await controller.stop(id);
        expect(controller.links, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await controller.dispose();
      }
    },
  );
}
