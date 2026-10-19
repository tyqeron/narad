import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/screen_share.dart';
import 'package:narad_client/screen_panel.dart';

class ScreenApi implements NaradApi {
  final calls = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> signals = [];
  List<Map<String, dynamic>> sessions = [];
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    calls.add(command);
    return {'ok': true, 'signals': signals, 'sessions': sessions};
  }
}

void main() {
  test('a signal arriving after dashboard status is not discarded', () async {
    final api = ScreenApi()
      ..signals = [
        {
          'session_id': 'new-screen',
          'peer_id': 'phone',
          'data': {'type': 'candidate', 'candidate': 'candidate:fixture'},
        },
      ]
      ..sessions = [
        {
          'id': 'new-screen',
          'capability': 'screen.view',
          'state': 'authorized',
        },
      ];
    final errors = <Object>[];
    final screens = ScreenController(api, errors.add);
    await screens.tick({'sessions': <Object>[]});
    expect(api.calls, contains(equals({'op': 'status'})));
    expect(screens.links['new-screen']!.candidates, hasLength(1));
    expect(errors, isEmpty);
    await screens.shutdown();
  });
  test(
    'screen polling uses its own signal consumer and shuts down idempotently',
    () async {
      final api = ScreenApi();
      final errors = <Object>[];
      final screens = ScreenController(api, errors.add);
      await screens.tick({'sessions': <Object>[]});
      expect(
        api.calls,
        contains(equals({'op': 'media_events', 'kind': 'screen'})),
      );
      expect(
        api.calls,
        contains(equals({'op': 'screen_ready', 'ready': true})),
      );
      await screens.shutdown();
      await screens.shutdown();
      expect(
        api.calls
            .where((c) => c['op'] == 'screen_ready' && c['ready'] == false)
            .length,
        1,
      );
      expect(errors, isEmpty);
    },
  );
  test(
    'stopping one extended display releases only its own virtual monitor',
    () async {
      final api = ScreenApi();
      final screens = ScreenController(api, (_) {});
      var releasedOne = 0, releasedTwo = 0;
      screens.links['one'] = ScreenLink(
        'one',
        'phone',
        true,
        extended: true,
        releaseDisplay: () async {
          releasedOne++;
        },
      );
      screens.links['two'] = ScreenLink(
        'two',
        'tablet',
        true,
        extended: true,
        releaseDisplay: () async {
          releasedTwo++;
        },
      );
      await screens.stop('one');
      expect(releasedOne, 1);
      expect(releasedTwo, 0);
      expect(screens.links.keys, ['two']);
      await screens.shutdown();
      expect(releasedOne, 1);
      expect(releasedTwo, 1);
    },
  );

  testWidgets('incoming screens require an explicit accept or decline', (
    tester,
  ) async {
    final api = ScreenApi();
    final screens = ScreenController(api, (_) {});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScreenPanel(
            controller: screens,
            api: api,
            onError: (_) {},
            status: {
              'sessions': [
                {
                  'id': 'fixture',
                  'peer_id': 'peer',
                  'capability': 'screen.view',
                  'state': 'requested',
                },
              ],
              'paired': {
                'peer': {
                  'peer': {'device_name': 'Laptop'},
                },
              },
            },
          ),
        ),
      ),
    );
    expect(find.text('Screen from Laptop'), findsOneWidget);
    expect(api.calls, isEmpty);
    await tester.tap(find.text('Accept'));
    await tester.pump();
    expect(
      api.calls,
      contains(equals({'op': 'media_accept', 'id': 'fixture'})),
    );
    await tester.tap(find.text('Decline'));
    await tester.pump();
    expect(api.calls, contains(equals({'op': 'media_deny', 'id': 'fixture'})));
    await tester.pumpWidget(const SizedBox());
    await screens.shutdown();
  });
  testWidgets('ending a viewed session presents an ended message', (
    tester,
  ) async {
    final screens = ScreenController(ScreenApi(), (_) {});
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenViewer(controller: screens, id: 'closed', name: 'Laptop'),
      ),
    );
    expect(find.text('Screen session ended'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await screens.shutdown();
  });
}
