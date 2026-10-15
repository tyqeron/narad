import 'dart:async';
import 'package:flutter/services.dart';
import 'api.dart';

/// Starts the adjacent backend, supervised by the native window's Windows Job.
class WindowsBackend {
  WindowsBackend({
    MethodChannel? channel,
    DaemonApi Function(String, int)? apiFactory,
    this.pollInterval = const Duration(milliseconds: 200),
    this.attempts = 100,
  }) : channel = channel ?? const MethodChannel('dev.narad/windows'),
       apiFactory = apiFactory ?? DaemonApi.new;
  final MethodChannel channel;
  final DaemonApi Function(String, int) apiFactory;
  final Duration pollInterval;
  final int attempts;

  Future<DaemonApi> start() async {
    final config = await channel.invokeMapMethod<String, dynamic>(
      'configuration',
    );
    if (config == null ||
        config['stateDirectory'] is! String ||
        config['apiPort'] is! int) {
      throw StateError('Windows backend configuration is unavailable');
    }
    final api = apiFactory(
      config['stateDirectory'] as String,
      config['apiPort'] as int,
    );
    try {
      await api.call({'op': 'status'});
      return api;
    } catch (_) {
      // A stale token or absent listener is normal on first launch.
    }
    await channel.invokeMethod<void>('start');
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        await api.call({'op': 'status'});
        return api;
      } catch (error) {
        lastError = error;
      }
      if (await channel.invokeMethod<bool>('running') != true) {
        throw StateError(
          'The Windows backend exited. Check that no other Narad instance owns this state folder or ports 45678–45700. $lastError',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
    throw StateError('Windows backend startup timed out: $lastError');
  }
}
