import 'package:narad_client/notification_icon.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';
import 'package:narad_client/phone_sync.dart';
import 'fixtures/notification_icon.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/desktop_integration.dart';

class FakeWindowsNotifications implements FlutterLocalNotificationsWindows {
  int initialized = 0;
  final shown = <int>[];
  final details = <WindowsNotificationDetails?>[];
  final cancelled = <int>[];
  @override
  Future<bool> initialize({
    required WindowsInitializationSettings settings,
    Function? onDidReceiveNotificationResponse,
  }) async {
    initialized++;
    return true;
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    String? payload,
    WindowsNotificationDetails? notificationDetails,
  }) async {
    shown.add(id);
    details.add(notificationDetails);
  }

  @override
  Future<void> cancel({required int id}) async {
    cancelled.add(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
    'incoming pairing alerts are deduplicated and removed after resolution',
    () async {
      final desktop = DesktopIntegration(
        channel: channel,
        useWindowsNotifications: false,
      );
      final request = {
        'id': 'pairing',
        'outgoing': false,
        'status': 'pending',
        'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300,
        'peer': {'device_name': 'Nearby phone'},
      };
      final status = {
        'pairings': [request],
      };
      await desktop.pairingStatus(status);
      await desktop.pairingStatus(status);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'phoneNotification');
      final notice = calls.single.arguments as Map;
      expect(notice['title'], 'Pairing request · Nearby phone');
      expect(notice['actions'], {'pairing-review': 'Review request'});
      request['status'] = 'approved';
      await desktop.pairingStatus(status);
      expect(calls.last.method, 'cancelPhoneNotification');
      expect((calls.last.arguments as Map)['id'], notice['id']);
      calls.clear();
      request['status'] = 'pending';
      request['outgoing'] = true;
      await desktop.pairingStatus(status);
      request['outgoing'] = false;
      request['expires_at'] = 1;
      await desktop.pairingStatus(status);
      expect(calls, isEmpty);
    },
  );

  test(
    'Windows notifications use an injected backend without loading a DLL',
    () async {
      final windows = FakeWindowsNotifications();
      var constructed = 0;
      final desktop = DesktopIntegration(
        channel: channel,
        useWindowsNotifications: true,
        windowsFactory: () {
          constructed++;
          return windows;
        },
      );
      await desktop.cancelPhoneNotification(7);
      expect(constructed, 0, reason: 'Unused Windows backend stays lazy');
      for (final value in [20, 75]) {
        await desktop.phoneNotification(
          PhoneNotice(
            id: 7,
            peer: 'phone',
            key: 'live',
            title: 'Phone · App',
            body: 'Downloading',
            actions: {'dismiss': 'Dismiss'},
            progress: value,
          ),
        );
      }
      expect(constructed, 1);
      expect(windows.initialized, 1);
      expect(windows.shown, [7, 7]);
      expect(windows.details.map((d) => d!.progressBars.single.value), [
        .2,
        .75,
      ]);
      expect(windows.details.last!.actions.single.arguments, '7:dismiss');
      await desktop.cancelPhoneNotification(7);
      expect(windows.cancelled, [7]);
      expect(calls, isEmpty);
    },
  );

  test(
    'forwards validated source icon bytes with the device notification',
    () async {
      final desktop = DesktopIntegration(
        channel: channel,
        useWindowsNotifications: false,
      );
      final icon = notificationIcon(sampleNotificationIcon)!;
      await desktop.phoneNotification(
        PhoneNotice(
          id: 1,
          peer: 'phone',
          key: 'key',
          title: 'Test app',
          body: 'Test content',
          actions: {'dismiss': 'Dismiss'},
          deviceName: 'Test phone',
          icon: icon,
        ),
      );
      final args = calls.single.arguments as Map;
      expect(args['icon'], orderedEquals(icon));
      expect(args['title'], 'Test app');
      expect(args['deviceName'], 'Test phone');
      expect(args['actions'], {'dismiss': 'Dismiss'});
    },
  );

  test(
    'transfer notification updates one ID as bytes advance and completes',
    () async {
      final desktop = DesktopIntegration(
        channel: channel,
        useWindowsNotifications: false,
      );
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
      final desktop = DesktopIntegration(
        channel: channel,
        useWindowsNotifications: false,
      );
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
    final desktop = DesktopIntegration(
      channel: channel,
      useWindowsNotifications: false,
    );
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
    await DesktopIntegration(
      channel: channel,
      useWindowsNotifications: false,
    ).quit();
    expect(calls.single.method, 'quit');
  });
}
