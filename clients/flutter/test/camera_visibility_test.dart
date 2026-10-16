import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/audio.dart';
import 'package:narad_client/camera_card.dart';

class CameraApi implements NaradApi {
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async => {
    'ok': true,
  };
}

void main() {
  testWidgets('source camera shows only sharing status and stop control', (
    tester,
  ) async {
    final controller = AudioController(CameraApi(), (e) => throw e);
    final source = AudioLink('source', 'viewer', false, camera: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CameraCard(
            controller: controller,
            link: source,
            name: 'Tablet',
          ),
        ),
      ),
    );
    expect(find.text('Sharing camera with Tablet'), findsOneWidget);
    expect(find.text('Stop sharing camera'), findsOneWidget);
    expect(find.byType(RTCVideoView), findsNothing);
    for (final label in [
      'Waiting for camera video…',
      'Switch camera',
      'Save image',
      'Record video',
      'Use in call apps',
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(source.tools, isNull);
    expect(() => controller.cameraTools(source), throwsStateError);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('requester retains camera view and capture controls', (
    tester,
  ) async {
    final controller = AudioController(CameraApi(), (e) => throw e);
    final viewer = AudioLink('viewer', 'source', true, camera: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CameraCard(controller: controller, link: viewer, name: 'Phone'),
        ),
      ),
    );
    expect(find.text('Camera from Phone'), findsOneWidget);
    expect(find.text('Waiting for camera video…'), findsOneWidget);
    expect(find.text('Save image'), findsOneWidget);
    expect(find.text('Record video'), findsOneWidget);
    expect(find.text('Switch camera'), findsOneWidget);
    expect(find.text('Stop sharing camera'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await viewer.tools?.dispose();
  });
}
