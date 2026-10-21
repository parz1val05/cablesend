import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../models.dart';
import 'backend.dart';
import 'event_parser.dart';

typedef _NextEventC = Pointer<Utf8> Function();
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeD = void Function(Pointer<Utf8>);
typedef _ScanC = Void Function(Uint16);
typedef _ScanD = void Function(int);
typedef _StartC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint16, Uint16);
typedef _StartD = int Function(Pointer<Utf8>, Pointer<Utf8>, int, int);
typedef _VoidC = Void Function();
typedef _VoidD = void Function();
typedef _AnswerC = Void Function(Int32);
typedef _AnswerD = void Function(int);
typedef _SendC = Void Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SendD = void Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

/// Talks to the Rust core through its C ABI (src/ffi.rs). Used on Android and iOS,
/// where the core is linked into the app. The core never calls back: events are polled.
///
/// The core keeps its own device identity and uses it to drop this device's own
/// beacon, so there is no name-based self-filtering here (two phones both called
/// "Android" would otherwise hide each other).
class FfiBackend implements Backend {
  FfiBackend._(DynamicLibrary lib)
      : _nextEvent = lib.lookupFunction<_NextEventC, _NextEventC>('cs_next_event'),
        _free = lib.lookupFunction<_FreeC, _FreeD>('cs_free_string'),
        _scan = lib.lookupFunction<_ScanC, _ScanD>('cs_scan'),
        _start = lib.lookupFunction<_StartC, _StartD>('cs_receive_start'),
        _stop = lib.lookupFunction<_VoidC, _VoidD>('cs_receive_stop'),
        _answer = lib.lookupFunction<_AnswerC, _AnswerD>('cs_answer'),
        _send = lib.lookupFunction<_SendC, _SendD>('cs_send') {
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) => _drain());
  }

  static const _receivePort = 53317;
  static const _beaconPort = 53318;
  static const _scanTimeout = Duration(seconds: 6);

  final _NextEventC _nextEvent;
  final _FreeD _free;
  final _ScanD _scan;
  final _StartD _start;
  final _VoidD _stop;
  final _AnswerD _answer;
  final _SendD _send;

  final _ctrl = StreamController<BackendEvent>.broadcast();
  Timer? _poll;
  Completer<ScanResult>? _scanWaiter;
  Future<ScanResult>? _scanInFlight;

  /// Loads the native library; null when it is not bundled in this build.
  static FfiBackend? tryLoad() {
    try {
      final lib = Platform.isIOS
          ? DynamicLibrary.process() // static library linked into the app binary
          : DynamicLibrary.open(Platform.isWindows
              ? 'cablesend.dll'
              : Platform.isMacOS
                  ? 'libcablesend.dylib'
                  : 'libcablesend.so');
      return FfiBackend._(lib);
    } catch (_) {
      return null;
    }
  }

  @override
  bool get isDemo => false;

  @override
  Stream<BackendEvent> get events => _ctrl.stream;

  void _emit(BackendEvent e) {
    if (!_ctrl.isClosed) _ctrl.add(e);
  }

  void _drain() {
    for (var i = 0; i < 200; i++) {
      final p = _nextEvent();
      if (p == nullptr) return;
      try {
        final j = jsonDecode(p.toDartString()) as Map<String, dynamic>;
        if (j['event'] == 'scan') {
          _finishScan(j);
        } else {
          final e = parseEvent(j, incoming: j['dir'] == 'in');
          if (e != null) _emit(e);
        }
      } catch (_) {
        // Bad UTF-8 or bad JSON must not kill the event pump for this tick.
      } finally {
        _free(p);
      }
    }
  }

  void _finishScan(Map<String, dynamic> j) {
    final peers = <Peer>[];
    for (final d in (j['peers'] as List? ?? const [])) {
      final m = d as Map<String, dynamic>;
      final addr = m['addr'] as String? ?? '';
      if (addr.isEmpty) continue;
      final platform = m['platform'] as String? ?? '';
      final usb = m['via'] == 'usb';
      final id = m['id'] as String?;
      peers.add(Peer(
        id: id == null || id.isEmpty ? '${usb ? 'usb' : 'net'}:$addr' : 'dev:$id',
        name: m['name'] as String? ?? 'Устройство',
        platform: platform,
        // Over USB a phone reaches either the computer it is plugged into (adb reverse)
        // or another phone (the AOA bridge); the core tells them apart by id.
        kind: !usb
            ? CableKind.network
            : id == 'usb-phone'
                ? CableKind.usbPhone
                : CableKind.usbHost,
        address: addr,
      ));
    }
    final waiter = _scanWaiter;
    _scanWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(ScanResult(peers: peers));
  }

  @override
  Future<ScanResult> scan() {
    // Every caller gets the same timeout-wrapped future. Handing out the raw
    // completer future would leave later callers waiting forever when the first
    // one timed out and abandoned the completer.
    final running = _scanInFlight;
    if (running != null) return running;

    final waiter = Completer<ScanResult>();
    _scanWaiter = waiter;
    _scan(_beaconPort);
    // Deliberately lets the TimeoutException through: the caller keeps the device
    // list it already had. Returning an empty result here would blank the screen
    // and clear the chosen device while the cable is still plugged in.
    final wrapped = waiter.future.timeout(_scanTimeout).whenComplete(() {
      if (identical(_scanWaiter, waiter)) _scanWaiter = null;
      _scanInFlight = null;
    });
    _scanInFlight = wrapped;
    return wrapped;
  }

  @override
  Future<void> startReceiving({required String dir, required String name}) async {
    await Directory(dir).create(recursive: true);
    final d = dir.toNativeUtf8();
    final n = name.toNativeUtf8();
    try {
      final r = _start(d, n, _receivePort, _beaconPort);
      if (r == -2) throw StateError('Порт $_receivePort занят: приём уже запущен?');
      if (r < 0) throw StateError('Приём уже запущен.');
    } finally {
      malloc.free(d);
      malloc.free(n);
    }
  }

  @override
  Future<void> stopReceiving() async {
    _stop();
    // let the accept loop notice the stop flag before a restart binds the port again
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  @override
  void answerOffer(bool accept) => _answer(accept ? 1 : 0);

  @override
  Future<void> send({required Peer peer, required List<String> paths, required String name}) async {
    final to = peer.address.toNativeUtf8();
    final n = name.toNativeUtf8();
    final f = paths.join('\n').toNativeUtf8();
    try {
      _send(to, n, f); // returns at once; progress and result arrive as events
    } finally {
      malloc.free(to);
      malloc.free(n);
      malloc.free(f);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _stop();
    _ctrl.close();
  }
}
