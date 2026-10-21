import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'backend/backend.dart';
import 'backend/cli_backend.dart';
import 'backend/demo_backend.dart';
import 'backend/ffi_backend.dart';
import 'controller.dart';
import 'screens/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Backend? backend;
  String? deviceName;
  String? saveDir;

  if (Platform.isAndroid || Platform.isIOS) {
    // The core is linked into the app and called through the C ABI.
    backend = FfiBackend.tryLoad();
    // A discriminator matters: two phones both called "Android" are impossible to
    // tell apart in the device list.
    final host = Platform.localHostname.trim();
    final base = Platform.isAndroid ? 'Android' : 'iPhone';
    deviceName = host.isEmpty || host == 'localhost' ? base : '$base ($host)';
    try {
      final dir = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
          await getApplicationDocumentsDirectory();
      saveDir = '${dir.path}${Platform.pathSeparator}CableSend';
    } catch (_) {}
  } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    // Desktop drives the `cablesend` executable, which also handles adb and usbmuxd.
    backend = await CliBackend.locate();
  }
  backend ??= DemoBackend();

  runApp(CableSendApp(controller: AppController(backend, deviceName: deviceName, saveDir: saveDir)));
}

/// Owns the controller so that a hot restart (or the app closing) stops the
/// receiver and kills any child process instead of leaving it running.
class CableSendApp extends StatefulWidget {
  const CableSendApp({super.key, required this.controller});
  final AppController controller;

  @override
  State<CableSendApp> createState() => _CableSendAppState();
}

class _CableSendAppState extends State<CableSendApp> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF0F766E),
          brightness: b,
          cardTheme: const CardThemeData(margin: EdgeInsets.zero),
        );
    return MaterialApp(
      title: 'CableSend',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: HomeShell(controller: widget.controller),
    );
  }
}
