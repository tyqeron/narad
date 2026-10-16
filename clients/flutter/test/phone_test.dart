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
    'desktop sync deduplicates alerts and keeps bodies out of banners',
    () async {
      final api = PhoneApi();
      var now = DateTime(2026);
      final banners = <String>[];
      final sync = PhoneSync(api, (title, text) async {
        banners.add('$title $text');
      }, clock: () => now);
      final status = {
        'paired': {
          'phone': {'peer': peer},
        },
        'presence': {
          'phone': {'online': true},
        },
      };
      await sync.tick(status);
      banners.clear();
      api.notifications.add({
        'key': 'new',
        'app': 'Generated app',
        'text': 'SECRET',
      });
      now = now.add(const Duration(seconds: 11));
      await sync.tick(status);
      expect(banners, hasLength(1));
      expect(banners.single, contains('Generated app'));
      expect(banners.single, isNot(contains('SECRET')));
      now = now.add(const Duration(seconds: 11));
      await sync.tick(status);
      expect(banners, hasLength(1));
      sync.dispose();
    },
  );
}
