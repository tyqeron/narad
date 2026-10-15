import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract class ThemePreferences {
  Future<ThemeMode> read();
  Future<void> write(ThemeMode mode);
}

class MemoryThemePreferences implements ThemePreferences {
  MemoryThemePreferences([this.mode = ThemeMode.system]);
  ThemeMode mode;
  @override
  Future<ThemeMode> read() async => mode;
  @override
  Future<void> write(ThemeMode value) async {
    mode = value;
  }
}

class DeviceThemePreferences implements ThemePreferences {
  static const channel = MethodChannel('dev.narad/android');
  File get file {
    final env = Platform.environment;
    final root = Platform.isWindows
        ? env['APPDATA']
        : env['XDG_CONFIG_HOME'] ??
              (env['HOME'] == null ? null : '${env['HOME']}/.config');
    if (root == null) {
      throw StateError('Application settings directory unavailable');
    }
    return File('$root/narad/client.json');
  }

  @override
  Future<ThemeMode> read() async {
    final value = Platform.isAndroid
        ? await channel.invokeMethod<String>('getTheme')
        : await file.exists()
        ? (jsonDecode(await file.readAsString()) as Map)['theme']
        : 'system';
    return ThemeMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => ThemeMode.system,
    );
  }

  @override
  Future<void> write(ThemeMode mode) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('setTheme', {'theme': mode.name});
      return;
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'theme': mode.name}),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

class AppSettingsScope extends InheritedWidget {
  const AppSettingsScope({
    super.key,
    required this.mode,
    required this.change,
    required super.child,
  });
  final ThemeMode mode;
  final Future<void> Function(ThemeMode) change;
  static AppSettingsScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppSettingsScope>()!;
  @override
  bool updateShouldNotify(AppSettingsScope oldWidget) => oldWidget.mode != mode;
}
