import 'package:flutter/services.dart';
import 'android_backend.dart';

/// Foreground embedded host backed by iOS Keychain, using the same mobile API.
class IosBackend extends AndroidBackend {
  IosBackend() : super(platformChannel: const MethodChannel('dev.narad/ios'));
}
