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
