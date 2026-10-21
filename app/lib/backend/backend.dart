import '../models.dart';

/// What the UI needs from the transfer core. Implementations:
///  * CliBackend  - drives the Rust `cablesend` binary (desktop).
///  * DemoBackend - simulated devices, used when no core is available.
/// A flutter_rust_bridge implementation for Android/iOS plugs in here later.
abstract class Backend {
  bool get isDemo;
  Stream<BackendEvent> get events;

  Future<ScanResult> scan();
  Future<void> startReceiving({required String dir, required String name});
  Future<void> stopReceiving();
  void answerOffer(bool accept);
  Future<void> send({required Peer peer, required List<String> paths, required String name});
  void dispose();
}
