import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/windows_backend.dart';

class ProbeApi extends DaemonApi {
  ProbeApi(this.failures)
    : super(r'C:\Users\Test\AppData\Local\Narad\state', 45700);
  int failures;
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    if (failures-- > 0) throw StateError('not ready');
    return {'ok': true};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.narad/windows');
  final calls = <String>[];
  var running = true;
  setUp(() {
    calls.clear();
    running = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return switch (call.method) {
            'configuration' => {
              'stateDirectory': r'C:\Users\Test\AppData\Local\Narad\state',
              'apiPort': 45700,
            },
            'start' => null,
            'running' => running,
            _ => throw MissingPluginException(),
          };
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  WindowsBackend backend(ProbeApi api) => WindowsBackend(
    channel: channel,
    apiFactory: (_, _) => api,
    attempts: 3,
    pollInterval: Duration.zero,
  );
  test(
    'reuses an authenticated daemon without starting or owning another',
    () async {
      final api = ProbeApi(0);
      expect(await backend(api).start(), same(api));
      expect(calls, ['configuration']);
    },
  );
  test(
    'starts packaged backend and waits through stale token/readiness errors',
    () async {
      final api = ProbeApi(2);
      expect(await backend(api).start(), same(api));
      expect(calls, ['configuration', 'start', 'running']);
    },
  );
  test(
    'reports a daemon exit instead of silently recreating identity',
    () async {
      running = false;
      await expectLater(
        backend(ProbeApi(99)).start(),
        throwsA(isA<StateError>()),
      );
      expect(calls.where((c) => c == 'start').length, 1);
    },
  );
  test(
    'bounds startup when the process lives but never becomes ready',
    () async {
      await expectLater(
        backend(ProbeApi(99)).start(),
        throwsA(isA<StateError>()),
      );
      expect(calls.where((c) => c == 'running').length, 3);
    },
  );
}
