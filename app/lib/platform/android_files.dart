import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../models.dart';

/// Android only: picks files with the system document picker and opens them for the
/// core without copying (see `MainActivity.kt.tmpl`). file_picker copies every picked
/// file into the app cache first, which for big videos costs minutes and gigabytes.
class AndroidFiles {
  static const _channel = MethodChannel('cablesend/files');

  static bool get supported => Platform.isAndroid;

  /// Picked documents as [PickedFile]s whose `path` is a `content://` URI, or null when
  /// the picker was closed. Throws [MissingPluginException] when the Android part is
  /// missing (tools/apply_android.sh not run), so the caller can fall back.
  static Future<List<PickedFile>?> pick() async {
    final r = await _channel.invokeMethod<List<Object?>>('pick');
    if (r == null) return null;
    return [
      for (final o in r)
        if (o is Map)
          PickedFile(
            path: o['uri'] as String,
            name: o['name'] as String? ?? 'file',
            // -1 means the provider does not say; the core measures it when sending
            size: _nonNegative(o['size']),
          ),
    ];
  }

  static int _nonNegative(Object? v) {
    final n = (v as num?)?.toInt() ?? -1;
    return n < 0 ? 0 : n;
  }

  static bool isContentUri(String path) => path.startsWith('content://');

  /// Turns `content://` URIs into lines of the core's file list (`fd:N<TAB>name`).
  /// Call right before sending: every returned descriptor is owned by the core from then on.
  static Future<List<String>> openForSend(List<String> uris) async {
    final r = await _channel.invokeMethod<List<Object?>>('open', {'uris': uris});
    return [for (final o in r ?? const []) o as String];
  }
}
