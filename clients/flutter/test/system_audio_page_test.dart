import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:narad_client/audio.dart';
import 'package:narad_client/desktop_audio_routes.dart';
import 'package:narad_client/system_audio_page.dart';
import 'audio_test.dart' show MultiMediaApi;

void main() {
  testWidgets(
    'add a second laptop listener and stop the first without unloading capture',
    (tester) async {
      final api = MultiMediaApi();
      final audio = AudioController(api, (e) => fail('$e'));
      final commands = <List<String>>[];
      final route = LinuxAudioRoutes(
        token: 'test',
        command: (args) async {
          commands.add(args);
          return args.first == 'get-default-sink'
              ? 'speakers'
              : args.first == 'load-module'
              ? '123'
              : '';
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SystemAudioPage(
            audio: audio,
            peer: 'phone',
            name: 'Phone',
            recipients: const {'tablet': 'Tablet'},
            routeFactory: () => route,
            enumerateDevices: () async => [
              MediaDeviceInfo(
                deviceId: route.speakerCapture,
                label: route.captureLabel,
                kind: 'audioinput',
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.text('Prepare / refresh audio capture'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Play on selected devices'));
      await tester.tap(find.text('Play on selected devices'));
      await tester.pumpAndSettle();
      expect(audio.links.values.map((l) => l.peer), ['phone']);
      await tester.tap(find.text('Tablet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play on selected devices'));
      await tester.pumpAndSettle();
      expect(audio.links.values.map((l) => l.peer), ['phone', 'tablet']);
      await tester.tap(find.byTooltip('Stop audio on Phone'));
      await tester.pumpAndSettle();
      expect(audio.links.values.map((l) => l.peer), ['tablet']);
      expect(commands.where((c) => c.first == 'unload-module'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(audio.links, isEmpty);
      expect(commands.where((c) => c.first == 'unload-module').single, [
        'unload-module',
        '123',
      ]);
    },
  );
}
