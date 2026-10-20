import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';
import 'phone_sync.dart';

class DesktopIntegration {
  DesktopIntegration({MethodChannel? channel})
    : channel =
          channel ??
          MethodChannel(
            Platform.isWindows ? 'dev.narad/windows' : 'dev.narad/desktop',
          );
  final MethodChannel channel;
  late final _windows = FlutterLocalNotificationsWindows();
  Future<bool>? _ready;
  Future<void> Function(int, String, String?)? onNotificationAction;
  Future<void> Function(List<String>)? onSharedContent;

  void onPrepareQuit(Future<void> Function() shutdown) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'prepareQuit') await shutdown();
      if (call.method == 'notificationAction') {
        final args = call.arguments as Map;
        await onNotificationAction?.call(
          args['id'] as int,
          args['action'] as String,
          null,
        );
      }
      if (call.method == 'sharedContent') {
        await onSharedContent?.call((call.arguments as List).cast<String>());
      }
    });
  }

  final Map<String, String> _transferStates = {};
  bool _transfersInitialized = false;
  Future<void> transferStatus(Map<String, dynamic> snapshot) async {
    for (final direction in ['transfers', 'outbound', 'shared_transfers']) {
      for (final item in (snapshot[direction] as List? ?? const [])) {
        final transfer = item as Map;
        final key = '$direction:${transfer['id']}';
        final state = transfer['status'] as String;
        final total = (transfer['total'] ?? transfer['file_size'] ?? 0) as int;
        final done = (transfer['sent'] ?? transfer['received'] ?? 0) as int;
        final percent = total == 0 ? 0 : (100 * done ~/ total).clamp(0, 100);
        final signature = '$state:$percent';
        final previous = _transferStates[key];
        _transferStates[key] = signature;
        if (previous == signature ||
            (!_transfersInitialized &&
                previous == null &&
                ['completed', 'cancelled'].contains(state))) {
          continue;
        }
        final name =
            transfer['file_name'] ??
            (transfer['path'] as String? ?? 'File')
                .split(RegExp(r'[/\\]'))
                .last;
        await phoneNotification(
          PhoneNotice(
            id: 100000 + (key.hashCode & 0x3fffffff),
            peer: transfer['peer_id'] as String,
            key: key,
            progress: ['completed', 'cancelled'].contains(state)
                ? null
                : percent,
            title:
                '${direction == 'outbound' || transfer['outgoing'] == true ? 'Sending' : 'Receiving'} $name',
            body: state == 'completed'
                ? (direction == 'shared_transfers'
                      ? 'Transfer complete · Shared folder'
                      : 'Transfer complete · Downloads/Narad on the receiving device')
                : '$percent% · $done / $total bytes · $state',
            actions: const {},
          ),
        );
      }
    }
    _transfersInitialized = true;
  }

  Future<bool> autostart() async =>
      (await channel.invokeMapMethod<String, dynamic>(
        'desktopStatus',
      ))?['autostart'] ==
      true;
  Future<void> setAutostart(bool enabled) =>
      channel.invokeMethod<void>('setAutostart', {'enabled': enabled});
  Future<void> phoneNotification(PhoneNotice n) async {
    if (Platform.isWindows) {
      _ready ??= _windows.initialize(
        settings: const WindowsInitializationSettings(
          appName: 'Narad',
          appUserModelId: 'dev.narad.narad_client',
          guid: 'cb747b62-a84c-45fb-b748-a3fd223460c8',
        ),
        onDidReceiveNotificationResponse: (r) async {
          final parts = (r.actionId ?? '').split(':');
          if (parts.length < 2) return;
          final id = int.tryParse(parts.first);
          if (id == null) return;
          await onNotificationAction?.call(
            id,
            parts.sublist(1).join(':'),
            r.data['reply']?.toString(),
          );
        },
      );
      if (!await _ready!) throw StateError('Windows notifications unavailable');
      await _windows.show(
        id: n.id,
        title: n.title,
        body: n.body,
        notificationDetails: WindowsNotificationDetails(
          header: n.deviceName == null
              ? null
              : WindowsHeader(
                  id: n.peer,
                  title: 'Narad · ${n.deviceName}',
                  arguments: 'device:${n.peer}',
                ),
          progressBars: [
            if (n.progress != null)
              WindowsProgressBar(
                id: 'transfer',
                status: n.body,
                value: n.progress! / 100,
              ),
          ],
          actions: [
            for (final a in n.actions.entries)
              WindowsAction(
                content: a.value,
                arguments: '${n.id}:${a.key}',
                inputId: a.key == 'reply' ? 'reply' : null,
              ),
          ],
          inputs: [
            if (n.actions.containsKey('reply'))
              const WindowsTextInput(id: 'reply', placeHolderContent: 'Reply'),
          ],
        ),
      );
    } else {
      await channel.invokeMethod<void>('phoneNotification', {
        'id': n.id,
        'title': n.title,
        'deviceName': n.deviceName,
        'text': n.body,
        'actions': n.actions,
      });
    }
  }

  Future<void> cancelPhoneNotification(int id) async {
    if (Platform.isWindows) {
      if (_ready != null && await _ready!) await _windows.cancel(id: id);
    } else {
      await channel.invokeMethod<void>('cancelPhoneNotification', {'id': id});
    }
  }

  Future<void> show() => channel.invokeMethod<void>('show');
  Future<void> quit() => channel.invokeMethod<void>('quit');
}
