import 'dart:async';
import 'package:flutter/services.dart';
import 'api.dart';

/// Android owns the runtime, identity vault and foreground service.
class AndroidBackend {
  static const channel = MethodChannel('dev.narad/android');
  Future<DaemonApi> start() async {
    final configuration = await channel.invokeMapMethod<String, dynamic>(
      'start',
    );
    if (configuration == null) {
      throw StateError('Android backend did not return its configuration');
    }
    final api = DaemonApi(
      configuration['stateDirectory'] as String,
      configuration['apiPort'] as int,
    );
    Object? lastError;
    for (var attempt = 0; attempt < 100; attempt++) {
      final state = await channel.invokeMapMethod<String, dynamic>('status');
      if (state?['error'] != null) throw StateError(state!['error'] as String);
      if (state?['state'] == 'running') {
        try {
          await api.call({'op': 'status'});
          return api;
        } catch (error) {
          lastError = error;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw StateError(
      'Narad could not start. ${lastError ?? 'Try restarting the connection.'}',
    );
  }

  Future<void> stop() async {
    await channel.invokeMethod<void>('stop');
    for (var attempt = 0; attempt < 100; attempt++) {
      final state = await channel.invokeMapMethod<String, dynamic>('status');
      if (state?['state'] == 'stopped' || state?['state'] == 'error') return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Android backend did not stop');
  }

  Future<void> setDeviceName(String name) async {
    await channel.invokeMethod<void>('setDeviceName', {'name': name});
  }

  Future<bool> saveFile(String id, String name) async =>
      await channel.invokeMethod<bool>('saveReceivedFile', {
        'id': id,
        'name': name,
      }) ??
      false;
}
