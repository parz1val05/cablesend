import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'backend/backend.dart';
import 'format.dart';
import 'models.dart';
import 'platform/foreground_service.dart';

enum SendPhase { idle, sending, done, failed }

class HistoryItem {
  HistoryItem({required this.title, required this.subtitle, required this.incoming, required this.ok})
      : time = DateTime.now();
  final String title;
  final String subtitle;
  final bool incoming;
  final bool ok;
  final DateTime time;
}

class PendingOffer {
  const PendingOffer(this.peer, this.platform, this.files);
  final String peer;
  final String platform;
  final List<FileOffer> files;
  int get totalSize => files.fold(0, (a, f) => a + f.size);
}

class AppController extends ChangeNotifier {
  AppController(this.backend, {String? deviceName, String? saveDir}) {
    this.deviceName = deviceName ?? _defaultName();
    this.saveDir = saveDir ?? _defaultDir();
    _sub = backend.events.listen(_onEvent);
    scan();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (phase != SendPhase.sending) scan(silent: true);
    });
  }

  static const _historyLimit = 100;

  final Backend backend;
  StreamSubscription<BackendEvent>? _sub;
  Timer? _timer;
  bool _disposed = false;

  // --- devices
  ScanResult scanResult = const ScanResult();

  /// True only for a scan the person asked for, which is the one that shows a spinner.
  bool scanning = false;

  /// The scan currently running, if any. Keeps the 5-second poll from stacking up
  /// scans (on desktop each one spawns child processes) when a scan runs long,
  /// while still letting a tap on "Обновить" wait for the answer.
  Future<ScanResult>? _scanFuture;

  Peer? selected;

  // --- sending
  final List<PickedFile> files = [];
  SendPhase phase = SendPhase.idle;
  String currentFile = '';
  int fileIndex = 0;
  int fileDone = 0;
  int fileTotal = 0;
  String? sendError;
  int sentCount = 0;

  // --- receiving
  bool receiving = false;
  bool receivingBusy = false;
  late String deviceName;
  late String saveDir;

  /// The offer waiting for the person's answer. The core handles one incoming
  /// connection at a time, so there is never more than one.
  PendingOffer? offer;
  String? receiveError;
  ({String name, int done, int total})? incomingProgress;

  final List<HistoryItem> history = [];

  List<Peer> get peers => scanResult.peers;
  int get totalSize => files.fold(0, (a, f) => a + f.size);
  bool get canSend => files.isNotEmpty && selected != null && phase != SendPhase.sending;

  /// Safe after an await: the controller may have been disposed in the meantime.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _addHistory(HistoryItem item) {
    history.insert(0, item);
    if (history.length > _historyLimit) history.removeRange(_historyLimit, history.length);
  }

  static String _defaultName() =>
      Platform.environment['COMPUTERNAME'] ?? Platform.environment['HOSTNAME'] ?? 'Это устройство';

  static String _defaultDir() {
    final sep = Platform.pathSeparator;
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
    return '$home${sep}Downloads${sep}CableSend';
  }

  // ---------------------------------------------------------------- devices

  Future<void> scan({bool silent = false}) async {
    if (!silent) {
      scanning = true;
      _notify();
    }
    try {
      // A scan already running is awaited instead of started twice: pressing
      // "Обновить" during the background poll should still show its result.
      final result = await (_scanFuture ??= backend.scan());
      scanResult = result;
      // Never change the chosen device while a transfer is running: the send is
      // already under way and the history entry names this peer when it finishes.
      if (phase != SendPhase.sending) {
        if (selected != null && !peers.any((p) => p.id == selected!.id)) selected = null;
        selected ??= peers.length == 1 ? peers.first : null;
      }
    } catch (_) {
      // A failed or timed-out scan keeps the previous device list rather than
      // blanking the screen and dropping the chosen device.
    } finally {
      _scanFuture = null;
      if (scanning) scanning = false;
      _notify();
    }
  }

  void select(Peer p) {
    selected = p;
    _notify();
  }

  // ---------------------------------------------------------------- files

  void addFiles(Iterable<PickedFile> items) {
    // After a finished send the list still holds what was sent; adding to it would
    // quietly send everything again.
    if (phase == SendPhase.done) files.clear();
    for (final f in items) {
      if (!files.any((x) => x.path == f.path)) files.add(f);
    }
    if (phase == SendPhase.done || phase == SendPhase.failed) phase = SendPhase.idle;
    _notify();
  }

  void removeFile(PickedFile f) {
    if (phase == SendPhase.sending) return;
    files.remove(f);
    _notify();
  }

  void clearFiles() {
    if (phase == SendPhase.sending) return;
    files.clear();
    _notify();
  }

  // ---------------------------------------------------------------- send

  Future<void> send() async {
    final peer = selected;
    if (peer == null || files.isEmpty || phase == SendPhase.sending) return;
    phase = SendPhase.sending;
    sendError = null;
    currentFile = '';
    fileIndex = 0;
    fileDone = 0;
    fileTotal = 0;
    _notify();
    try {
      await backend.send(peer: peer, paths: [for (final f in files) f.path], name: deviceName);
    } catch (e) {
      if (phase == SendPhase.sending) {
        phase = SendPhase.failed;
        sendError = friendlyError(e.toString());
        _notify();
      }
    }
  }

  void resetSend() {
    phase = SendPhase.idle;
    files.clear();
    sendError = null;
    currentFile = '';
    fileIndex = 0;
    fileDone = 0;
    fileTotal = 0;
    sentCount = 0;
    _notify();
  }

  // ---------------------------------------------------------------- receive

  Future<void> setReceiving(bool on) async {
    if (receivingBusy) return;
    receivingBusy = true;
    receiveError = null;
    _notify();
    try {
      if (on) {
        await backend.startReceiving(dir: saveDir, name: deviceName);
        receiving = true;
        unawaited(ForegroundService.start(_idleNotice));
      } else {
        _declinePendingOffer();
        await backend.stopReceiving();
        receiving = false;
        incomingProgress = null;
        unawaited(ForegroundService.stop());
      }
    } catch (e) {
      receiving = false;
      receiveError = friendlyError(e.toString());
      unawaited(ForegroundService.stop());
    } finally {
      receivingBusy = false;
      _notify();
    }
  }

  Future<void> rename(String name) async {
    final n = name.trim();
    if (n.isEmpty || n == deviceName) return;
    deviceName = n;
    _notify();
    await _restartReceiving();
  }

  Future<void> setSaveDir(String dir) async {
    if (dir == saveDir) return;
    saveDir = dir;
    _notify();
    await _restartReceiving();
  }

  /// Re-announces the receiver under the new name or folder. Waits for any toggle
  /// already in flight, otherwise the change would be dropped without a word.
  Future<void> _restartReceiving() async {
    for (var i = 0; receivingBusy && i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_disposed || !receiving) return;
    if (receivingBusy) {
      receiveError = 'Не удалось переобъявить устройство: приём занят. '
          'Выключите и снова включите приём.';
      _notify();
      return;
    }
    await setReceiving(false);
    if (_disposed) return;
    await setReceiving(true);
  }

  String get _idleNotice => 'Приём включён: устройство видно как «$deviceName»';

  /// Lets the core stop waiting on an offer the person can no longer answer.
  /// Answering twice is harmless: the core keeps one pending answer and drops the rest.
  void _declinePendingOffer() {
    if (offer == null) return;
    offer = null;
    backend.answerOffer(false);
  }

  void answerOffer(bool accept) {
    final o = offer;
    offer = null;
    if (!accept) unawaited(ForegroundService.update(_idleNotice));
    if (o != null && !accept) {
      _addHistory(HistoryItem(
        title: 'Отклонено: ${pluralFiles(o.files.length)}',
        subtitle: 'от ${o.peer}',
        incoming: true,
        ok: false,
      ));
    }
    backend.answerOffer(accept);
    // Reachable after an await (the dialog returning), so the disposed check matters.
    _notify();
  }

  // ---------------------------------------------------------------- events

  void _onEvent(BackendEvent e) {
    switch (e) {
      case ReceivingStarted():
        receiving = true;
      case OfferReceived():
        offer = PendingOffer(e.peer, e.platform, e.files);
        unawaited(ForegroundService.update(
            '${e.peer} хочет отправить ${pluralFiles(e.files.length)}. Откройте приложение.'));
      case Progress():
        if (e.incoming) {
          if (receiving) incomingProgress = (name: e.name, done: e.done, total: e.total);
        } else {
          if (e.name != currentFile) {
            currentFile = e.name;
            fileIndex++;
          }
          fileDone = e.done;
          fileTotal = e.total;
        }
      case Finished():
        if (e.incoming) {
          incomingProgress = null;
          _addHistory(HistoryItem(
            title: 'Получено: ${pluralFiles(e.files)}',
            subtitle: 'сохранено в $saveDir',
            incoming: true,
            ok: true,
          ));
        } else {
          phase = SendPhase.done;
          sentCount = e.files;
          _addHistory(HistoryItem(
            title: 'Отправлено: ${pluralFiles(e.files)}',
            subtitle: selected == null ? '' : 'на ${selected!.name}',
            incoming: false,
            ok: true,
          ));
        }
      case Failed():
        final msg = friendlyError(e.message);
        if (e.incoming) {
          incomingProgress = null;
          // The sender may have given up while the dialog was still open.
          _declinePendingOffer();
          if (e.fatal) {
            receiving = false;
            receiveError = msg;
            unawaited(ForegroundService.stop());
          } else {
            _addHistory(HistoryItem(title: 'Ошибка приёма', subtitle: msg, incoming: true, ok: false));
          }
        } else {
          phase = SendPhase.failed;
          sendError = msg;
          _addHistory(HistoryItem(title: 'Ошибка отправки', subtitle: msg, incoming: false, ok: false));
        }
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _sub?.cancel();
    // Otherwise Android keeps a notification claiming the receiver is still on.
    unawaited(ForegroundService.stop());
    backend.dispose();
    super.dispose();
  }
}
