import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:narad_client/audio.dart';
import 'package:narad_client/desktop_audio_routes.dart';
import 'package:narad_client/system_audio_page.dart';
import 'audio_test.dart' show MultiMediaApi;

class TestAudioBackend implements RTCPeerConnection {
  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('failed discovery unloads its route before retrying', (
    tester,
  ) async {
    final audio = AudioController(MultiMediaApi(), (e) => fail('$e'));
    var created = 0, removed = 0;
    LinuxAudioRoutes? route;
    await tester.pumpWidget(
      MaterialApp(
        home: SystemAudioPage(
          createConnection: (_) async => TestAudioBackend(),
          audio: audio,
          peer: 'phone',
          name: 'Phone',
          routeFactory: () => route = LinuxAudioRoutes(
            token: 'retry_${++created}',
            command: (args) async {
              if (args.first == 'get-default-sink') return 'speakers';
              if (args.first == 'unload-module') removed++;
              return '123';
            },
          ),
          enumerateDevices: () async => created == 1
              ? []
              : [
                  MediaDeviceInfo(
                    deviceId: route!.speakerCapture,
                    label: route!.captureLabel,
                    kind: 'audioinput',
                  ),
                ],
        ),
      ),
    );
    await tester.tap(find.text('Prepare / refresh audio capture'));
    await tester.pump();
    for (var i = 0; i < 22; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(removed, 1);
    expect(
      find.textContaining('Audio capture did not become available'),
      findsOneWidget,
    );
    await tester.tap(find.text('Prepare / refresh audio capture'));
    await tester.pumpAndSettle();
    expect(created, 2);
    expect(
      find.textContaining('Audio capture did not become available'),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
    await audio.dispose();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'audio survives Back, reopens with listeners and stops explicitly',
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
            createConnection: (_) async => TestAudioBackend(),
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
      expect(audio.links.values.map((l) => l.peer), ['tablet']);
      expect(commands.where((c) => c.first == 'unload-module'), isEmpty);
      await tester.pumpWidget(
        MaterialApp(
          home: SystemAudioPage(
            audio: audio,
            peer: 'phone',
            name: 'Phone',
            recipients: const {'tablet': 'Tablet'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Stop audio on Tablet'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop all sharing'));
      await tester.pumpAndSettle();
      expect(audio.links, isEmpty);
      expect(commands.where((c) => c.first == 'unload-module').single, [
        'unload-module',
        '123',
      ]);
      await tester.pumpWidget(const SizedBox());
      await audio.dispose();
    },
  );
}
