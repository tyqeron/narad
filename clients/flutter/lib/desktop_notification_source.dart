import 'dart:convert';
import 'package:flutter/services.dart';
import 'api.dart';

/// Ephemeral native notification access behind the existing authenticated RPC.
class DesktopNotificationSource {
  DesktopNotificationSource(this.api, this.channel);
  final NaradApi api;
  final MethodChannel channel;
  bool enabled = false, supported = false, _busy = false, _disposed = false;
  String error = '';

  Future<void> setEnabled(bool value) async {
    await channel.invokeMethod<void>('setNotificationSharing', {
      'enabled': value,
    });
    await tick();
  }

  Future<void> tick() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      final status =
          await channel.invokeMapMethod<String, dynamic>(
            'notificationSourceStatus',
          ) ??
          {};
      supported = status['supported'] == true;
      enabled = status['enabled'] == true;
      error = status['error']?.toString() ?? '';
      if (_disposed) return;
      await api.call({
        'op': 'phone_bridge_ready',
        'support': {
          'enabled': enabled,
          'notifications': enabled,
          'notification_manage': enabled,
          'notification_reply': false,
          'notification_action': false,
        },
      });
      if (!enabled || _disposed) return;
      final jobs =
          (await api.call({'op': 'phone_jobs'}))['jobs'] as List? ?? [];
      for (final raw in jobs) {
        if (_disposed) return;
        final job = Map<String, dynamic>.from(raw as Map);
        final id = job['id'];
        try {
          await api.call({'op': 'phone_validate', 'id': id});
          Map<String, dynamic> result;
          try {
            switch (job['kind']) {
              case 'notifications':
                final raw =
                    await channel.invokeListMethod<dynamic>(
                      'desktopNotifications',
                    ) ??
                    [];
                final items = <Map<String, dynamic>>[];
                final icons = <String, Object?>{};
                var budget = 37998;
                for (final value in raw) {
                  final item = Map<String, dynamic>.from(value as Map);
                  icons[item['key'].toString()] = item.remove('icon');
                  final size = utf8.encode(jsonEncode(item)).length + 1;
                  if (size > budget || items.length >= 30) break;
                  budget -= size;
                  items.add(item);
                }
                for (final item in items) {
                  final icon = icons[item['key']];
                  if (icon is String &&
                      icon.length <= 8192 &&
                      icon.length + 10 <= budget) {
                    item['icon'] = icon;
                    budget -= icon.length + 10;
                  }
                }
                result = {'ok': true, 'items': items};
              case 'notification_dismiss':
                await channel.invokeMethod<void>('dismissDesktopNotification', {
                  'key': (job['args'] as Map)['key'],
                });
                result = {'ok': true};
              default:
                throw UnsupportedError(
                  'This desktop does not support that notification action',
                );
            }
          } catch (e) {
            result = {'ok': false, 'error': e.toString()};
          }
          if (!_disposed) {
            await api.call({'op': 'phone_result', 'id': id, 'result': result});
          }
        } catch (_) {
          /* Revoked or expired jobs must never be executed again. */
        }
      }
    } on MissingPluginException {
      enabled = false;
      supported = false;
      error = 'Desktop notification capture is unavailable in this build.';
    } catch (e) {
      error = e.toString();
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _disposed = true;
  }
}
