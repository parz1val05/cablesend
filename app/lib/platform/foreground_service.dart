import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Android only: keeps the receiver alive in the background through a foreground service.
/// Everywhere else every call is a harmless no-op.
class ForegroundService {
  static const _channel = MethodChannel('cablesend/service');

  static bool get supported => Platform.isAndroid;

  static Future<void> start(String text) => _call('start', text);
  static Future<void> update(String text) => _call('update', text);
  static Future<void> stop() => _call('stop', '');

  static Future<void> _call(String method, String text) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method, {'text': text});
    } catch (_) {
      // channel missing (tools/apply_android.sh not run) - the app still works in the foreground
    }
  }
}
