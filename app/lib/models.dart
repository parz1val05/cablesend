/// How a peer is reached. This also decides how [Peer.address] is read, so the two
/// backends must never label a peer with a kind whose address format they don't use.
enum CableKind {
  /// Ethernet, Thunderbolt/USB4 bridge or a USB-Ethernet adapter. Address: `host:port`.
  network,

  /// This computer reaching an Android phone over USB. Address: adb serial.
  android,

  /// This computer reaching an iPhone/iPad over USB. Address: iPhone UDID.
  ios,

  /// A phone reaching the computer it is plugged into, through the `adb reverse`
  /// tunnel. Address: `host:port` on the phone's own loopback.
  usbHost,

  /// An Android phone reaching another Android phone on the same USB cable, through
  /// the Android Open Accessory bridge (`UsbBridge.kt`). Address: `host:port` on loopback.
  usbPhone,
}

String cableTitle(CableKind k) => switch (k) {
      CableKind.network => 'Сетевой кабель / Thunderbolt',
      CableKind.android => 'Android по USB',
      CableKind.ios => 'iPhone / iPad по USB',
      CableKind.usbHost => 'Компьютер по USB',
      CableKind.usbPhone => 'Телефон по USB',
    };

String cableShort(CableKind k) => switch (k) {
      CableKind.network => 'по сетевому кабелю',
      CableKind.android => 'по USB (Android)',
      CableKind.ios => 'по USB (iPhone)',
      CableKind.usbHost => 'по USB-кабелю',
      CableKind.usbPhone => 'по USB-кабелю (телефон)',
    };

class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.platform,
    required this.kind,
    required this.address,
  });

  final String id;
  final String name;
  final String platform;
  final CableKind kind;

  /// Meaning depends on [kind] - see [CableKind].
  final String address;
}

class FileOffer {
  const FileOffer(this.name, this.size);
  final String name;
  final int size;
}

class PickedFile {
  const PickedFile({required this.path, required this.name, required this.size});
  final String path;
  final String name;
  final int size;
}

class ScanResult {
  const ScanResult({
    this.peers = const [],
    this.androidError,
    this.iosError,
    this.androidUnauthorized = false,
    this.adbMissing = false,
    this.iosServiceMissing = false,
  });

  final List<Peer> peers;

  /// Non-null when ADB could not be used. Free text for the person to read.
  final String? androidError;

  /// Non-null when the iPhone service (usbmuxd) could not be used.
  final String? iosError;

  /// A phone is plugged in but USB debugging was not confirmed on its screen.
  final bool androidUnauthorized;

  /// `adb` is not installed or not on PATH. A flag rather than a text match,
  /// so the UI never has to guess a cause from an error message.
  final bool adbMissing;

  /// The Apple device service (usbmuxd) is not installed or not running.
  final bool iosServiceMissing;

  int count(CableKind k) => peers.where((p) => p.kind == k).length;
}

sealed class BackendEvent {
  const BackendEvent();
}

class ReceivingStarted extends BackendEvent {
  const ReceivingStarted(this.port);
  final int port;
}

class OfferReceived extends BackendEvent {
  const OfferReceived(this.peer, this.platform, this.files);
  final String peer;
  final String platform;
  final List<FileOffer> files;
}

class Progress extends BackendEvent {
  const Progress(this.name, this.done, this.total, {required this.incoming});
  final String name;
  final int done;
  final int total;
  final bool incoming;
}

class Finished extends BackendEvent {
  const Finished(this.files, {required this.incoming});
  final int files;
  final bool incoming;
}

class Failed extends BackendEvent {
  const Failed(this.message, {required this.incoming, this.fatal = false});
  final String message;
  final bool incoming;

  /// True when the receiver itself stopped and is no longer listening, as opposed to
  /// one transfer going wrong. Lets the UI tell the two apart without matching on text.
  final bool fatal;
}
