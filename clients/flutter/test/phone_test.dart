import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/phone_page.dart';
import 'package:narad_client/phone_sync.dart';

class PhoneApi implements NaradApi {
  final commands = <Map<String, dynamic>>[];
  bool denied = false, logsDenied = false;
  List<Map<String, dynamic>> notifications = [
    {
      'key': 'old',
      'app': 'Generated app',
      'title': 'Private fixture',
      'text': 'fixture body',
      'time': 1,
    },
  ];
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    commands.add(command);
    if (denied) throw StateError('permission denied');
    switch (command['kind']) {
      case 'support':
        return {
          'ok': true,
          'support': {'enabled': true, 'call_control': true},
        };
      case 'notifications':
        return {'ok': true, 'items': notifications};
      case 'sms_list':
        return {'ok': true, 'items': <dynamic>[]};
      case 'calls_list':
        if (logsDenied) throw StateError('call log access denied');
        return {'ok': true, 'items': <dynamic>[]};
      case 'call_state':
        return {
          'ok': true,
          'items': [
            {
              'id': 'fixture-call',
              'number': 'Generated caller',
              'state': 'ringing',
            },
          ],
        };
      default:
        return {'ok': true};
    }
  }
}

const peer = {
  'device_id': 'phone',
  'device_name': 'Test phone',
  'platform': 'android',
};
void main() {
  testWidgets('SMS is sent only after explicit compose confirmation', (
    tester,
  ) async {
    final api = PhoneApi();
    await tester.pumpWidget(
      MaterialApp(
        home: PhonePage(api: api, peer: peer),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('SMS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New SMS'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '1234567890');
    await tester.enterText(find.byType(TextField).last, 'Generated test only');
    expect(api.commands.where((c) => c['kind'] == 'sms_send'), isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.commands.where((c) => c['kind'] == 'sms_send'), isEmpty);
    await tester.tap(find.text('New SMS'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '1234567890');
    await tester.enterText(find.byType(TextField).last, 'Generated test only');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(api.commands.where((c) => c['kind'] == 'sms_send'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('revocation clears displayed phone content', (tester) async {
    final api = PhoneApi();
    await tester.pumpWidget(
      MaterialApp(
        home: PhonePage(api: api, peer: peer),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('fixture body'), findsOneWidget);
    api.denied = true;
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('fixture body'), findsNothing);
    expect(find.textContaining('permission denied'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('live answer controls work when call log OS access is denied', (
    tester,
  ) async {
    final api = PhoneApi()..logsDenied = true;
    await tester.pumpWidget(
      MaterialApp(
        home: PhonePage(api: api, peer: peer),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Calls'));
    await tester.pumpAndSettle();
    expect(find.text('Answer'), findsOneWidget);
    await tester.tap(find.text('Answer'));
    await tester.pumpAndSettle();
    expect(api.commands.where((c) => c['kind'] == 'answer'), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'desktop mirrors full content, updates, actions and withdrawal',
    () async {
      final api = PhoneApi();
      var now = DateTime(2026);
      final banners = <PhoneNotice>[];
      final removed = <int>[];
      final sync = PhoneSync(
        api,
        (n) async {
          banners.add(n);
        },
        cancel: (id) async {
          removed.add(id);
        },
        clock: () => now,
      );
      final status = {
        'paired': {
          'phone': {'peer': peer},
        },
        'presence': {
          'phone': {'online': true},
        },
      };
      Future<void> tick() async {
        now = now.add(const Duration(seconds: 11));
        await sync.tick(status);
      }

      await tick();
      expect(banners.first.title, 'Generated app');
      expect(banners.first.deviceName, 'Test phone');
      expect(banners.first.body, 'Private fixture\nfixture body');
      final id = banners.first.id;
      banners.clear();
      api.notifications.first['text'] = 'Updated full content';
      api.notifications.first['dismissible'] = true;
      api.notifications.first['reply'] = true;
      api.notifications.first['actions'] = [
        {'id': 'opaque', 'title': 'Archive'},
      ];
      await tick();
      expect(banners.single.id, id);
      expect(banners.single.body, contains('Updated full content'));
      expect(banners.single.actions, {
        'reply': 'Reply',
        'opaque': 'Archive',
        'dismiss': 'Dismiss',
      });
      await tick();
      expect(banners, hasLength(1));
      expect(
        api.commands.where((c) => c['kind'] == 'notification_action'),
        isEmpty,
      );
      await sync.act(id, 'unknown');
      expect(
        api.commands.where((c) => c['kind'] == 'notification_action'),
        isEmpty,
      );
      await sync.act(id, 'opaque');
      expect(api.commands.last['kind'], 'notification_action');
      expect(api.commands.last['args'], {'key': 'old', 'action': 'opaque'});
      await sync.act(id, 'opaque');
      expect(
        api.commands.where((c) => c['kind'] == 'notification_action'),
        hasLength(1),
      );
      expect(removed, contains(id));
      api.notifications.first['text'] = 'Another update';
      await tick();
      final updated = banners.last;
      await sync.act(updated.id, 'reply', reply: 'Generated reply');
      expect(api.commands.last['args'], {
        'key': 'old',
        'text': 'Generated reply',
      });
      api.notifications.first['text'] = 'Before revocation';
      await tick();
      final stale = banners.last.id;
      api.denied = true;
      await tick();
      expect(removed, contains(stale));
      final calls = api.commands.length;
      await sync.act(stale, 'dismiss');
      expect(api.commands, hasLength(calls));
      sync.dispose();
    },
  );
  test(
    'offline devices withdraw their notifications and disable buttons',
    () async {
      final api = PhoneApi();
      var now = DateTime(2026);
      final notices = <PhoneNotice>[];
      final removed = <int>[];
      final sync = PhoneSync(
        api,
        (n) async {
          notices.add(n);
        },
        cancel: (id) async {
          removed.add(id);
        },
        clock: () => now,
      );
      await sync.tick({
        'paired': {
          'phone': {'peer': peer},
        },
        'presence': {
          'phone': {'online': true},
        },
      });
      now = now.add(const Duration(seconds: 11));
      await sync.tick({'paired': {}, 'presence': {}});
      expect(removed, containsAll(notices.map((n) => n.id)));
      sync.dispose();
    },
  );
}
