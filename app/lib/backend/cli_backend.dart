import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models.dart';
import 'backend.dart';
import 'event_parser.dart';

/// Drives the `cablesend` executable on Windows / macOS / Linux.
///
/// The core runs as child processes: one long-lived `receive`, and a short
/// `devices` / `peers` / `send` per action. `receive` and `peers` are separate
/// processes, so they are both given the same `--id`; without it this device
/// would find its own beacon (a broadcast comes back on the machine's own address)
/// and list itself as a peer.
class CliBackend implements Backend {
  CliBackend(this._bin);

  final String _bin;
  final _ctrl = StreamController<BackendEvent>.broadcast();

  /// This device's beacon identity, shared by every child process we spawn.
  final String _instanceId = _newInstanceId();

  Process? _rx;
  final _rxSubs = <StreamSubscription<void>>[];

  static String _newInstanceId() {
    final r = Random.secure();
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final salt = List.generate(4, (_) => r.nextInt(1 << 16).toRadixString(16)).join();
    return '$now-$salt';
  }

  @override
  bool get isDemo => false;

  @override
  Stream<BackendEvent> get events => _ctrl.stream;

  void _emit(BackendEvent e) {
    if (!_ctrl.isClosed) _ctrl.add(e);
  }

  /// Looks for the core: $CABLESEND_BIN, next to the app, then PATH.
  static Future<CliBackend?> locate() async {
    final name = Platform.isWindows ? 'cablesend.exe' : 'cablesend';
    final candidates = <String>[
      if ((Platform.environment['CABLESEND_BIN'] ?? '').isNotEmpty) Platform.environment['CABLESEND_BIN']!,
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$name',
      name,
    ];
    for (final c in candidates) {
      try {
        final r = await Process.run(c, ['--help']);
        if (r.exitCode == 0) return CliBackend(c);
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<ScanResult> scan() async {
    final peers = <Peer>[];
    final usb = await _scanUsbDevices(peers);
    await _scanNetworkPeers(peers);
    return ScanResult(
      peers: peers,
      androidError: usb.androidError,
      iosError: usb.iosError,
      androidUnauthorized: usb.unauthorized,
      adbMissing: usb.adbMissing,
      iosServiceMissing: usb.iosServiceMissing,
    );
  }

  /// Phones attached over USB, via `adb` and `usbmuxd`. Each half is read
  /// independently so a missing adb cannot also hide the iPhone half.
  Future<_UsbScan> _scanUsbDevices(List<Peer> into) async {
    Map<String, dynamic>? json;
    String? spawnError;
    try {
      final r = await Process.run(_bin, ['devices', '--json']);
      json = jsonDecode((r.stdout as String).trim()) as Map<String, dynamic>;
    } catch (e) {
      spawnError = 'не удалось запустить ядро cablesend: $e';
    }

    var out = _UsbScan(androidError: spawnError, iosError: spawnError);
    if (json == null) return out;

    try {
      final a = json['android'] as Map<String, dynamic>? ?? const {};
      final err = a['error'] as String?;
      var unauthorized = false;
      for (final d in (a['devices'] as List? ?? const [])) {
        final m = d as Map<String, dynamic>;
        final id = m['id'] as String? ?? '';
        if (id.isEmpty) continue;
        if (m['state'] == 'device') {
          into.add(Peer(id: 'adb:$id', name: 'Android ($id)', platform: 'android', kind: CableKind.android, address: id));
        } else if (m['state'] == 'unauthorized') {
          unauthorized = true;
        }
      }
      out = out.copyWith(
        androidError: err,
        unauthorized: unauthorized,
        // The core words this exactly; map it to a flag so the UI never greps text.
        adbMissing: err != null && err.contains('cannot run `adb`'),
      );
    } catch (e) {
      out = out.copyWith(androidError: 'непонятный ответ ядра: $e');
    }

    try {
      final i = json['ios'] as Map<String, dynamic>? ?? const {};
      final err = i['error'] as String?;
      for (final d in (i['devices'] as List? ?? const [])) {
        final m = d as Map<String, dynamic>;
        final id = m['id'] as String? ?? '';
        if (id.isEmpty) continue;
        into.add(Peer(id: 'ios:$id', name: 'iPhone / iPad', platform: 'ios', kind: CableKind.ios, address: id));
      }
      out = out.copyWith(
        iosError: err,
        iosServiceMissing: err != null && err.contains('usbmuxd not reachable'),
      );
    } catch (e) {
      out = out.copyWith(iosError: 'непонятный ответ ядра: $e');
    }
    return out;
  }

  /// Computers reachable over a network cable, found by their UDP beacon.
  Future<void> _scanNetworkPeers(List<Peer> into) async {
    try {
      final r = await Process.run(_bin, ['peers', '--json', '--id', _instanceId]);
      final j = jsonDecode((r.stdout as String).trim()) as Map<String, dynamic>;
      for (final d in (j['peers'] as List? ?? const [])) {
        final m = d as Map<String, dynamic>;
        final addr = m['addr'] as String? ?? '';
        if (addr.isEmpty) continue;
        // The core already drops our own beacon by its id; this only skips the
        // loopback copy, which no other device could ever reach anyway.
        if (addr.startsWith('127.') || addr.startsWith('[::1]')) continue;
        final id = m['id'] as String?;
        into.add(Peer(
          id: id == null || id.isEmpty ? 'net:$addr' : 'dev:$id',
          name: m['name'] as String? ?? 'Устройство',
          platform: m['platform'] as String? ?? '',
          kind: CableKind.network,
          address: addr,
        ));
      }
    } catch (_) {
      // A failed peer scan leaves the USB devices found above intact.
    }
  }

  void _handle(String line, {required bool incoming}) {
    try {
      final e = parseEvent(jsonDecode(line) as Map<String, dynamic>, incoming: incoming);
      if (e != null) _emit(e);
    } catch (_) {}
  }

  @override
  Future<void> startReceiving({required String dir, required String name}) async {
    await stopReceiving();
    final p = await Process.start(
      _bin,
      [
        'receive', '--json', '--dir', dir, '--name', name, '--id', _instanceId,
        // Opens and keeps open the phone -> PC USB tunnel for every attached
        // Android device. Without it a phone can never reach this computer,
        // because iOS and Android cannot dial out over the cable themselves.
        '--adb-reverse',
      ],
    );
    _rx = p;
    final err = StringBuffer();
    _rxSubs.add(p.stderr.transform(utf8.decoder).listen(err.write, onError: (_) {}));
    _rxSubs.add(p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) {
          // Lines buffered by a process we have already replaced would otherwise
          // surface as errors of the new receiver.
          if (identical(_rx, p)) _handle(l, incoming: true);
        }, onError: (_) {}));
    unawaited(p.exitCode.then((code) {
      // Only the process that is still the current receiver may report a failure:
      // one we killed on purpose (restart, stop, dispose) must stay quiet.
      if (!identical(_rx, p)) return;
      _rx = null;
      final text = err.toString().trim();
      _emit(Failed(
        text.isEmpty ? 'Приём остановился (код $code).' : text,
        incoming: true,
        fatal: true,
      ));
    }));
  }

  @override
  Future<void> stopReceiving() async {
    final p = _rx;
    if (p == null) return;
    _rx = null; // clears first, so the exit handler above knows this was deliberate
    await _cancelRxSubs();
    p.kill();
    // Waits for the port to be free again, otherwise an immediate restart
    // (rename, change of folder) races the dying process for port 53317.
    // Bounded: a core that ignores SIGTERM must not freeze the receive switch.
    await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      return -1;
    });
  }

  Future<void> _cancelRxSubs() async {
    final subs = List<StreamSubscription<void>>.of(_rxSubs);
    _rxSubs.clear();
    for (final s in subs) {
      await s.cancel();
    }
  }

  @override
  void answerOffer(bool accept) {
    try {
      _rx?.stdin.writeln(accept ? 'y' : 'n');
    } catch (_) {}
  }

  @override
  Future<void> send({required Peer peer, required List<String> paths, required String name}) async {
    final args = <String>['send'];
    switch (peer.kind) {
      case CableKind.network:
      case CableKind.usbHost:
        args.addAll(['--to', peer.address]);
      case CableKind.android:
        args.addAll(['--adb', peer.address, '--remote-port', '53317']);
      case CableKind.ios:
        args.addAll(['--ios', peer.address, '--remote-port', '53317']);
    }
    args.addAll(['--json', '--name', name, ...paths]);

    final p = await Process.start(_bin, args);
    var terminal = false;
    final err = StringBuffer();
    p.stderr.transform(utf8.decoder).listen(err.write);
    final done = Completer<void>();
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (l) {
        if (l.contains('"event":"done"') || l.contains('"event":"error"')) terminal = true;
        _handle(l, incoming: false);
      },
      onDone: done.complete,
    );
    final code = await p.exitCode;
    await done.future;
    if (!terminal) {
      final text = err.toString().trim();
      _emit(Failed(text.isEmpty ? 'Передача прервана (код $code).' : text, incoming: false));
    }
  }

  @override
  void dispose() {
    final p = _rx;
    _rx = null; // stops the exit handler from adding to a closed controller
    unawaited(_cancelRxSubs());
    p?.kill();
    _ctrl.close();
  }
}

class _UsbScan {
  const _UsbScan({
    this.androidError,
    this.iosError,
    this.unauthorized = false,
    this.adbMissing = false,
    this.iosServiceMissing = false,
  });

  final String? androidError;
  final String? iosError;
  final bool unauthorized;
  final bool adbMissing;
  final bool iosServiceMissing;

  _UsbScan copyWith({
    String? androidError,
    String? iosError,
    bool? unauthorized,
    bool? adbMissing,
    bool? iosServiceMissing,
  }) =>
      _UsbScan(
        androidError: androidError ?? this.androidError,
        iosError: iosError ?? this.iosError,
        unauthorized: unauthorized ?? this.unauthorized,
        adbMissing: adbMissing ?? this.adbMissing,
        iosServiceMissing: iosServiceMissing ?? this.iosServiceMissing,
      );
}
