import 'dart:io';
import 'package:flutter/services.dart';

class DesktopIntegration {
  DesktopIntegration({MethodChannel? channel})
    : channel =
          channel ??
          MethodChannel(
            Platform.isWindows ? 'dev.narad/windows' : 'dev.narad/desktop',
          );
  final MethodChannel channel;
  Future<bool> autostart() async =>
      (await channel.invokeMapMethod<String, dynamic>(
        'desktopStatus',
      ))?['autostart'] ==
      true;
  Future<void> setAutostart(bool enabled) =>
      channel.invokeMethod<void>('setAutostart', {'enabled': enabled});
  Future<void> phoneNotification(String title, String text) => channel
      .invokeMethod<void>('phoneNotification', {'title': title, 'text': text});
  Future<void> quit() => channel.invokeMethod<void>('quit');
}
