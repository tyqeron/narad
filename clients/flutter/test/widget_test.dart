import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/main.dart';

class FakeApi implements NaradApi {
  final calls = <Map<String, dynamic>>[];
  final status = <String, dynamic>{
    'ok': true,
    'device': {
      'device_id': 'local123',
      'device_name': 'My laptop',
      'platform': 'linux',
      'port': 45678,
      'address': '192.168.1.10',
      'protocol_version': 1,
    },
    'paired': {
      'peer': {
        'peer': {
          'device_id': 'peer',
          'device_name': 'My phone',
          'platform': 'android',
        },
      },
    },
    'permissions': {},
    'discovered': [],
    'pairings': [],
    'transfers': [],
    'outbound': [],
    'sessions': [],
    'clipboard': [],
    'events': [],
    'media_ready': false,
  };
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    calls.add(command);
    if (command['op'] == 'status') return status;
    if (command['op'] == 'clipboard_accept') {
      status['clipboard'] = [];
      return {'ok': true, 'text': 'approved text'};
    }
    return {'ok': true};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,(call) async => null);});
  tearDown(() {TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,null);});
  testWidgets('paired device actions and empty discovery are visible', (
    tester,
  ) async {
    final api = FakeApi();
    await tester.pumpWidget(NaradApp(api: api));
    await tester.pumpAndSettle();
    expect(find.text('My laptop'), findsOneWidget);
    expect(find.text('My phone'), findsOneWidget);
    expect(find.text('Send file'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Looking on your local network'), 200);
    expect(find.text('Looking on your local network'), findsOneWidget);
    expect(
      api.calls.any((c) => c['op'] == 'media_ready' && c['ready'] == true),
      false,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('clipboard remains pending until explicit acceptance', (
    tester,
  ) async {
    final api = FakeApi();
    api.status['clipboard'] = [
      {
        'id': 'clip',
        'peer_id': 'peer',
        'status': 'pending',
        'preview': 'approved text',
      },
    ];
    await tester.pumpWidget(NaradApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(find.text('approved text'), findsOneWidget);
    expect(api.calls.any((c) => c['op'] == 'clipboard_accept'), false);
    await tester.tap(find.text('Copy to clipboard'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.calls.where((c) => c['op'] == 'clipboard_accept').length, 1);
    expect(find.text('You’re all caught up'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('pairing approval requires comparing codes and confirming', (
    tester,
  ) async {
    final api = FakeApi();
    api.status['pairings'] = [
      {
        'id': 'pair',
        'peer': {'device_name': 'My phone'},
        'code': '123456',
        'status': 'pending',
        'outgoing': false,
      },
    ];
    await tester.pumpWidget(NaradApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codes match · approve'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Do both devices show 123456?'), findsOneWidget);
    expect(api.calls.any((c) => c['op'] == 'pair_approve'), false);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(
      api.calls.any((c) => c['op'] == 'pair_approve' && c['code'] == '123456'),
      true,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('phone-sized navigation and inbox layout do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(NaradApp(api: FakeApi()));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(find.text('You’re all caught up'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
