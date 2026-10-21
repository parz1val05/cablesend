import 'dart:async';

import '../models.dart';
import 'backend.dart';

/// Simulated devices so the interface can be tried without cables or the core.
class DemoBackend implements Backend {
  final _ctrl = StreamController<BackendEvent>.broadcast();
  Timer? _offerTimer;

  @override
  bool get isDemo => true;

  @override
  Stream<BackendEvent> get events => _ctrl.stream;

  /// The fake transfers run in detached loops that outlive [dispose], so every
  /// emit goes through here rather than straight at a possibly closed controller.
  void _emit(BackendEvent e) {
    if (!_ctrl.isClosed) _ctrl.add(e);
  }

  @override
  Future<ScanResult> scan() async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    return const ScanResult(
      peers: [
        Peer(id: 'demo:1', name: 'Рабочий ноутбук', platform: 'windows', kind: CableKind.network, address: 'demo'),
        Peer(id: 'demo:2', name: 'Pixel 8', platform: 'android', kind: CableKind.android, address: 'demo'),
        Peer(id: 'demo:3', name: 'iPhone Анны', platform: 'ios', kind: CableKind.ios, address: 'demo'),
      ],
    );
  }

  @override
  Future<void> startReceiving({required String dir, required String name}) async {
    _emit(const ReceivingStarted(53317));
    _offerTimer?.cancel();
    _offerTimer = Timer(const Duration(seconds: 6), () {
      _emit(const OfferReceived('Pixel 8', 'android', [
        FileOffer('Фото_отпуск.zip', 48 * 1024 * 1024),
        FileOffer('Заметки.txt', 3 * 1024),
      ]));
    });
  }

  @override
  Future<void> stopReceiving() async => _offerTimer?.cancel();

  @override
  void answerOffer(bool accept) {
    if (!accept) return;
    unawaited(() async {
      for (final f in const [('Фото_отпуск.zip', 48 * 1024 * 1024), ('Заметки.txt', 3 * 1024)]) {
        for (var i = 1; i <= 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          if (_ctrl.isClosed) return;
          _emit(Progress(f.$1, f.$2 * i ~/ 10, f.$2, incoming: true));
        }
      }
      _emit(const Finished(2, incoming: true));
    }());
  }

  @override
  Future<void> send({required Peer peer, required List<String> paths, required String name}) async {
    for (final p in paths) {
      final n = p.split(RegExp(r'[\\/]')).last;
      for (var i = 1; i <= 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (_ctrl.isClosed) return;
        _emit(Progress(n, i * 100, 1000, incoming: false));
      }
    }
    _emit(Finished(paths.length, incoming: false));
  }

  @override
  void dispose() {
    _offerTimer?.cancel();
    _ctrl.close();
  }
}
