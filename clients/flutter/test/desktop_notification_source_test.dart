import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/desktop_notification_source.dart';

class SourceApi implements NaradApi {
  final commands = <Map<String, dynamic>>[];
  bool revoked = false;
  List<Map<String, dynamic>> jobs = [];
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    commands.add(command);
    if (command['op'] == 'phone_validate' && revoked) {
      throw StateError('permission revoked');
    }
    return {'ok': true, if (command['op'] == 'phone_jobs') 'jobs': jobs};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/desktop-source');
  final native = <MethodCall>[];
  var enabled = false;
  var items = <Map<String, dynamic>>[];
  setUp(() {
    native.clear();
    enabled = false;
    items = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          native.add(call);
          switch (call.method) {
            case 'notificationSourceStatus':
              return {'supported': true, 'enabled': enabled};
            case 'setNotificationSharing':
              enabled = (call.arguments as Map)['enabled'] == true;
              return null;
            case 'desktopNotifications':
              return items;
            default:
              return null;
          }
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'opt-out advertises no notification access and never reads content',
    () async {
      final api = SourceApi();
      final source = DesktopNotificationSource(api, channel);
      await source.tick();
      expect((api.commands.single['support'] as Map)['enabled'], false);
      expect(native.where((c) => c.method == 'desktopNotifications'), isEmpty);
    },
  );
  test(
    'serves only validated jobs and advertises only supported operations',
    () async {
      enabled = true;
      items = [
        {
          'key': 'linux:1',
          'app': 'Fixture',
          'title': 'Generated',
          'text': 'Body',
        },
      ];
      final api = SourceApi()
        ..jobs = [
          {'id': 'read', 'kind': 'notifications', 'args': {}},
          {
            'id': 'dismiss',
            'kind': 'notification_dismiss',
            'args': {'key': 'linux:1'},
          },
        ];
      final source = DesktopNotificationSource(api, channel);
      await source.tick();
      final support = api.commands.first['support'] as Map;
      expect(support['notifications'], true);
      expect(support['notification_manage'], true);
      expect(support['notification_reply'], false);
      expect(support['notification_action'], false);
      final results = api.commands
          .where((c) => c['op'] == 'phone_result')
          .toList();
      expect((results.first['result'] as Map)['items'], items);
      expect(native.last.method, 'dismissDesktopNotification');
      expect(native.last.arguments, {'key': 'linux:1'});
      expect(api.commands.where((c) => c['op'] == 'phone_validate').length, 2);
    },
  );
  test(
    'revocation prevents native content access and native dismissal',
    () async {
      enabled = true;
      final api = SourceApi()
        ..revoked = true
        ..jobs = [
          {'id': 'read', 'kind': 'notifications', 'args': {}},
          {
            'id': 'dismiss',
            'kind': 'notification_dismiss',
            'args': {'key': 'linux:1'},
          },
        ];
      final source = DesktopNotificationSource(api, channel);
      await source.tick();
      expect(native.map((c) => c.method), ['notificationSourceStatus']);
      expect(api.commands.where((c) => c['op'] == 'phone_result'), isEmpty);
    },
  );
  test('turning off sharing withdraws capabilities immediately', () async {
    enabled = true;
    final api = SourceApi();
    final source = DesktopNotificationSource(api, channel);
    await source.tick();
    await source.setEnabled(false);
    expect(source.enabled, false);
    expect((api.commands.last['support'] as Map)['enabled'], false);
  });
}
