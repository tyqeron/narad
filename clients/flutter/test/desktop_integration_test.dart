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
  test('quit uses the native exit path instead of hiding the window', () async {
    await DesktopIntegration(channel: channel).quit();
    expect(calls.single.method, 'quit');
  });
}
