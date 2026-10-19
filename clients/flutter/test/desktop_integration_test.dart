import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/desktop_integration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/narad/desktop');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'desktopStatus') return {'autostart': true};
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'transfer notification updates one ID as bytes advance and completes',
    () async {
      final desktop = DesktopIntegration(channel: channel);
      Map<String, dynamic> snapshot(int done, String state) => {
        'transfers': [
          {
            'id': 'fixture',
            'peer_id': 'peer',
            'file_name': 'photo.jpg',
            'file_size': 100,
            'received': done,
            'status': state,
          },
        ],
      };
      await desktop.transferStatus(snapshot(20, 'receiving'));
      await desktop.transferStatus(snapshot(20, 'receiving'));
      await desktop.transferStatus(snapshot(70, 'receiving'));
      await desktop.transferStatus(snapshot(100, 'completed'));
      expect(calls.length, 3);
      final notices = calls.map((call) => call.arguments as Map).toList();
      expect(notices.map((n) => n['id']).toSet().length, 1);
      expect(notices[0]['text'], contains('20%'));
      expect(notices[1]['text'], contains('70%'));
      expect(notices[2]['text'], contains('Transfer complete'));
    },
  );

  test(
    'reads login preference and forwards explicit enable and disable changes',
    () async {
      final desktop = DesktopIntegration(channel: channel);
      expect(await desktop.autostart(), isTrue);
      await desktop.setAutostart(false);
      await desktop.setAutostart(true);
      expect(calls.map((c) => c.method), [
        'desktopStatus',
        'setAutostart',
        'setAutostart',
      ]);
      expect(calls[1].arguments, {'enabled': false});
      expect(calls[2].arguments, {'enabled': true});
    },
  );
  test('native tray quit waits for Dart media cleanup', () async {
    final desktop = DesktopIntegration(channel: channel);
    final events = <String>[];
    desktop.onPrepareQuit(() async {
      events.add('stop-media');
      await Future<void>.delayed(Duration.zero);
      events.add('unload-owned-routes');
      await desktop.quit();
    });
    final result = await TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('prepareQuit'),
          ),
          (_) {},
        );
    expect(const StandardMethodCodec().decodeEnvelope(result!), isNull);
    expect(events, ['stop-media', 'unload-owned-routes']);
    expect(calls.single.method, 'quit');
    channel.setMethodCallHandler(null);
  });
  test('quit uses the native exit path instead of hiding the window', () async {
    await DesktopIntegration(channel: channel).quit();
    expect(calls.single.method, 'quit');
  });
}
