import 'dart:async';
import 'package:flutter/services.dart';
import 'api.dart';

/// Android owns the runtime, identity vault and foreground service.
class AndroidBackend {
  AndroidBackend({MethodChannel? platformChannel})
    : _platformChannel = platformChannel ?? channel;
  final MethodChannel _platformChannel;
  static const channel = MethodChannel('dev.narad/android');
  Future<DaemonApi> start() async {
    final configuration = await _platformChannel
        .invokeMapMethod<String, dynamic>('start');
    if (configuration == null) {
      throw StateError('Android backend did not return its configuration');
    }
    final api = DaemonApi(
      configuration['stateDirectory'] as String,
      configuration['apiPort'] as int,
    );
    Object? lastError;
    for (var attempt = 0; attempt < 100; attempt++) {
      final state = await _platformChannel.invokeMapMethod<String, dynamic>(
        'status',
      );
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

  Future<void> phoneSetup() =>
      _platformChannel.invokeMethod<void>('phoneSetup');

  Future<Map<String, dynamic>?> takeDeviceAction() =>
      _platformChannel.invokeMapMethod<String, dynamic>('takeDeviceAction');

  Future<void> stop() async {
    await _platformChannel.invokeMethod<void>('stop');
    for (var attempt = 0; attempt < 100; attempt++) {
      final state = await _platformChannel.invokeMapMethod<String, dynamic>(
        'status',
      );
      if (state?['state'] == 'stopped' || state?['state'] == 'error') return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Android backend did not stop');
  }

  Future<void> setDeviceName(String name) async {
    await _platformChannel.invokeMethod<void>('setDeviceName', {'name': name});
  }

  Future<bool> ensureCameraPermission() async =>
      await _platformChannel.invokeMethod<bool>('ensureCameraPermission') ??
      false;

  Future<bool> ensureDeviceAdmin() async =>
      await _platformChannel.invokeMethod<bool>('ensureDeviceAdmin') ?? false;

  Future<bool> saveFile(String id, String name) async =>
      await _platformChannel.invokeMethod<bool>('saveReceivedFile', {
        'id': id,
        'name': name,
      }) ??
      false;
}
