import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/android_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(AndroidBackend.channel, null),
  );

  test(
    'waits for native readiness and authenticates the embedded API',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'narad-bootstrap-',
      );
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      await File('${directory.path}/api-token').writeAsString('test-token');
      var requests = 0;
      final subscription = server.listen((socket) async {
        final line = await utf8.decoder
            .bind(socket)
            .transform(const LineSplitter())
            .first;
        final request = jsonDecode(line);
        expect(request['token'], 'test-token');
        expect(request['command']['op'], 'status');
        requests++;
        socket.write('${jsonEncode({'ok': true})}\n');
        await socket.flush();
        socket.destroy();
      });
      var polls = 0;
      messenger.setMockMethodCallHandler(AndroidBackend.channel, (call) async {
        switch (call.method) {
          case 'start':
            return {'stateDirectory': directory.path, 'apiPort': server.port};
          case 'status':
            return {'state': ++polls < 2 ? 'starting' : 'running'};
          default:
            throw PlatformException(code: 'unexpected');
        }
      });
      try {
        final api = await AndroidBackend().start();
        expect(api.port, server.port);
        expect(polls, 2);
        expect(requests, 1);
      } finally {
        await subscription.cancel();
        await server.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('surfaces vault errors without regenerating an identity', () async {
    var starts = 0;
    messenger.setMockMethodCallHandler(AndroidBackend.channel, (call) async {
      if (call.method == 'start') {
        starts++;
        return {'stateDirectory': '/unused', 'apiPort': 45700};
      }
      return {'state': 'error', 'error': 'Identity authentication failed'};
    });
    await expectLater(
      AndroidBackend().start(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('authentication failed'),
        ),
      ),
    );
    expect(starts, 1);
  });

  test('stop waits until native shutdown has released the runtime', () async {
    var polls = 0;
    messenger.setMockMethodCallHandler(AndroidBackend.channel, (call) async {
      if (call.method == 'stop') return null;
      return {'state': ++polls < 2 ? 'stopping' : 'stopped'};
    });
    await AndroidBackend().stop();
    expect(polls, 2);
  });
}
