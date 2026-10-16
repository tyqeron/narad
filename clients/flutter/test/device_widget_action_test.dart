import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/device_widget_action.dart';

void main() {
  Map<String, dynamic> status({
    bool online = true,
    String platform = 'linux',
  }) => {
    'paired': {
      'peer': {
        'peer': {'device_id': 'peer', 'platform': platform},
      },
    },
    'presence': {
      'peer': {'online': online},
    },
  };
  test('all device actions route to the selected paired device', () {
    expect(DeviceWidgetAction.actions.length, 10);
    for (final action in DeviceWidgetAction.actions) {
      final request = DeviceWidgetAction.parse({
        'peer_id': 'peer',
        'action': action,
      });
      expect(request.peerFrom(status())['device_id'], 'peer');
    }
  });
  test(
    'offline device blocks communication but retains settings and unpair',
    () {
      for (final action in DeviceWidgetAction.actions) {
        final request = DeviceWidgetAction('peer', action);
        if (action == 'settings' || action == 'unpair') {
          expect(request.peerFrom(status(online: false))['device_id'], 'peer');
        } else {
          expect(
            () => request.peerFrom(status(online: false)),
            throwsStateError,
          );
        }
      }
    },
  );
  test('removed pairing never becomes an executable widget action', () {
    expect(
      () => DeviceWidgetAction('gone', 'lock').peerFrom(status()),
      throwsStateError,
    );
  });
  test('malformed or unknown actions are rejected', () {
    for (final input in [
      <String, dynamic>{},
      {'peer_id': '', 'action': 'file'},
      {'peer_id': 'peer', 'action': 'shell'},
      {'peer_id': 123, 'action': 'lock'},
    ]) {
      expect(() => DeviceWidgetAction.parse(input), throwsFormatException);
    }
  });
  test('Windows unlock remains unsupported', () {
    expect(
      () => DeviceWidgetAction(
        'peer',
        'unlock',
      ).peerFrom(status(platform: 'windows')),
      throwsStateError,
    );
  });
}
