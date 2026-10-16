import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:narad_client/camera_tools.dart';

/// Run only under a disposable Xvfb display. Captures generated UI, no real camera.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native desktop repeated frames, loopback feed and video finalization',
    (tester) async {
      expect(
        Platform.environment['NARAD_GENERATED_DISPLAY'],
        '1',
        reason: 'Use an isolated Xvfb display',
      );
      await tester.pumpWidget(const MaterialApp(home: _GeneratedDisplay()));
      await tester.pump();
      final screens = await desktopCapturer.getSources(
        types: [SourceType.Screen],
      );
      expect(screens, isNotEmpty);
      final stream = await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': {
          'deviceId': {'exact': screens.first.id},
          'mandatory': {'frameRate': 15.0},
        },
      });
      final errors = <Object>[];
      final tools = CameraTools(
        () => stream.getVideoTracks().first,
        errors.add,
      );
      final client = HttpClient();
      try {
        for (var i = 0; i < 12; i++) {
          final png = await tools.photo();
          expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
          final codec = await ui.instantiateImageCodec(png);
          final image = (await codec.getNextFrame()).image;
          expect(image.width, greaterThan(0));
          image.dispose();
          codec.dispose();
        }
        final url = await tools.startFeed();
        await tools.startRecording();
        await Future<void>.delayed(const Duration(seconds: 3));
        final response = await (await client.getUrl(
          Uri.parse('${url}frame.png'),
        )).close();
        expect(response.statusCode, 200);
        await response.drain<void>();
        await tools.stop();
        expect(tools.completed, hasLength(1));
        expect(errors, isEmpty);
        final verify = await Process.run('ffmpeg', [
          '-v',
          'error',
          '-i',
          tools.completed.single,
          '-f',
          'null',
          '-',
        ]);
        expect(verify.exitCode, 0, reason: verify.stderr.toString());
        expect(tools.feed.url, isNull);
      } finally {
        client.close(force: true);
        await tools.dispose();
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
      }
    },
  );
}

class _GeneratedDisplay extends StatefulWidget {
  const _GeneratedDisplay();
  @override
  State<_GeneratedDisplay> createState() => _GeneratedDisplayState();
}

class _GeneratedDisplayState extends State<_GeneratedDisplay> {
  Timer? timer;
  bool alternate = false;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() => alternate = !alternate);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: alternate ? Colors.teal : Colors.indigo,
    body: const Center(child: Text('Narad generated camera fixture')),
  );
}
