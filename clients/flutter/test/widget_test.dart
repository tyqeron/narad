import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/main.dart';
import 'package:narad_client/app_settings.dart';

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
    'automatic_permissions': {},
    'presence': {
      'peer': {
        'online': true,
        'last_seen': 1792044000,
        'checked_at': 1792044000,
      },
    },
    'commands': [],
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
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  testWidgets('paired device actions and empty discovery are visible', (
    tester,
  ) async {
    final api = FakeApi();
    await tester.pumpWidget(NaradApp(api: api));
    await tester.pumpAndSettle();
    expect(find.text('My laptop'), findsOneWidget);
    expect(find.text('Looking on your local network'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('My phone'), 150);
    await tester.pumpAndSettle();
    expect(find.text('My phone'), findsOneWidget);
    expect(find.text('Send file'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('actions-peer')));
    await tester.pumpAndSettle();
    expect(find.text('Send file'), findsOneWidget);
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

  testWidgets('nearby device sends a request without an invitation', (
    tester,
  ) async {
    final api = FakeApi();
    final peer = {
      'device_id': 'new-phone',
      'device_name': 'Nearby phone',
      'platform': 'android',
      'address': '192.168.1.20',
      'port': 45678,
    };
    api.status['discovered'] = [peer];
    await tester.pumpWidget(NaradApp(api: api));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Send pairing request'), 200);
    await Scrollable.ensureVisible(
      tester.element(find.text('Send pairing request')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send pairing request'));
    await tester.pumpAndSettle();
    expect(
      api.calls.where((c) => c['op'] == 'pair_nearby').single['peer'],
      peer,
    );
    expect(
      api.calls.any((c) => c['op'] == 'invite' || c['op'] == 'pair'),
      isFalse,
    );
    expect(find.textContaining('Accept it in their Inbox'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'incoming nearby request has a notice and accepts without typing a code',
    (tester) async {
      final api = FakeApi();
      api.status['pairings'] = [
        {
          'id': 'nearby',
          'peer': {'device_id': 'new-phone', 'device_name': 'Nearby phone'},
          'code': '123456',
          'status': 'pending',
          'outgoing': false,
          'nearby': true,
        },
      ];
      await tester.pumpWidget(NaradApp(api: api));
      await tester.pumpAndSettle();
      expect(find.text('Pairing request from Nearby phone'), findsOneWidget);
      expect(find.byType(Badge), findsOneWidget);
      expect(api.calls.any((c) => c['op'] == 'pair_approve'), isFalse);
      await tester.tap(find.text('Review request'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept request'));
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c['op'] == 'pair_approve').single, {
        'op': 'pair_approve',
        'id': 'nearby',
        'code': '123456',
      });
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'outgoing nearby request waits for receiver and can be cancelled',
    (tester) async {
      final api = FakeApi();
      api.status['pairings'] = [
        {
          'id': 'nearby',
          'peer': {'device_id': 'new-phone', 'device_name': 'Nearby phone'},
          'code': '123456',
          'status': 'pending',
          'outgoing': true,
          'nearby': true,
        },
      ];
      await tester.pumpWidget(NaradApp(api: api));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inbox'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Waiting for acceptance'), findsOneWidget);
      expect(find.text('Confirm both devices'), findsNothing);
      expect(api.calls.any((c) => c['op'] == 'pair_confirm'), isFalse);
      await tester.tap(find.text('Cancel request'));
      await tester.pumpAndSettle();
      expect(
        api.calls.any((c) => c['op'] == 'pair_deny' && c['id'] == 'nearby'),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'paired online and offline devices are separated and offline controls are disabled',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeApi();
      (api.status['paired'] as Map)['offline'] = {
        'peer': {
          'device_id': 'offline',
          'device_name': 'Sleeping laptop',
          'platform': 'linux',
        },
      };
      (api.status['presence'] as Map)['offline'] = {
        'online': false,
        'last_seen': 1792044000,
        'checked_at': 1792044001,
      };
      await tester.pumpWidget(NaradApp(api: api));
      await tester.pumpAndSettle();
      expect(find.text('Online (1)'), findsOneWidget);
      expect(find.text('Offline (1)'), findsOneWidget);
      expect(find.text('Sleeping laptop'), findsNothing);
      await tester.scrollUntilVisible(find.text('Offline (1)'), 150);
      await tester.tap(find.text('Offline (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Sleeping laptop'), findsOneWidget);
      await tester.tap(find.text('Offline (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Sleeping laptop'), findsNothing);
      await tester.tap(find.text('Offline (1)'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Sleeping laptop'), 150);
      await tester.pumpAndSettle();
      final settings = find.byKey(const ValueKey('settings-offline'));
      expect(tester.widget<IconButton>(settings).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('actions-offline')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.ancestor(
                of: find.text('Send file'),
                matching: find.byType(PopupMenuItem<String>),
              ),
            )
            .enabled,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('theme defaults to device appearance and saves a user override', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final preferences = MemoryThemePreferences();
    await tester.pumpWidget(NaradApp(api: FakeApi(), preferences: preferences));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
    expect(
      Theme.of(tester.element(find.text('Narad'))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(preferences.mode, ThemeMode.light);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(NaradApp(api: FakeApi(), preferences: preferences));
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'device settings expose all capability grants and save them per peer',
    (tester) async {
      final api = FakeApi();
      await tester.pumpWidget(NaradApp(api: api));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byTooltip('Device settings'), 150);
      await Scrollable.ensureVisible(
        tester.element(find.byTooltip('Device settings')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Device settings'));
      await tester.pumpAndSettle();
      expect(find.byType(SwitchListTile), findsNWidgets(8));
      expect(find.text('Share this device’s camera'), findsOneWidget);
      await tester.tap(find.text('Receive files automatically'));
      await tester.pumpAndSettle();
      expect(
        api.calls.any(
          (c) =>
              c['op'] == 'permission' &&
              c['peer_id'] == 'peer' &&
              c['capability'] == 'file.transfer' &&
              c['allow'] == true,
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'activity groups friendly summaries and collapses repeated transfer progress',
    (tester) async {
      final api = FakeApi();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      api.status['events'] = [
        {
          'type': 'file.completed',
          'timestamp': now,
          'detail': {'id': 'transfer'},
        },
        {
          'type': 'file.progress',
          'timestamp': now,
          'detail': {'id': 'transfer', 'sent': 20000, 'total': 30000},
        },
        {
          'type': 'file.progress',
          'timestamp': now,
          'detail': {'id': 'transfer', 'sent': 10000, 'total': 30000},
        },
        {
          'type': 'clipboard.applied',
          'timestamp': now,
          'detail': {'peer_id': 'peer'},
        },
      ];
      await tester.pumpWidget(NaradApp(api: api));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activity'));
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Clipboard'), findsOneWidget);
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      expect(find.text('File transfer completed'), findsOneWidget);
      expect(find.textContaining('Transferring'), findsOneWidget);
      expect(find.textContaining('{"'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Windows peers do not offer remote unlock', (tester) async {
    final api = FakeApi();
    ((api.status['paired'] as Map)['peer']['peer'] as Map)['platform'] =
        'windows';
    await tester.pumpWidget(NaradApp(api: api));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('My phone'), 150);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('actions-peer')));
    await tester.pumpAndSettle();
    expect(find.text('Lock'), findsOneWidget);
    expect(find.text('Request unlock'), findsNothing);
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
