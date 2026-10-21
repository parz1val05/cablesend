import '../models.dart';

/// Turns one JSON event from the core (CLI line or FFI event) into a [BackendEvent].
/// Returns null for events the UI does not care about.
BackendEvent? parseEvent(Map<String, dynamic> j, {required bool incoming}) {
  switch (j['event']) {
    case 'listening':
      return ReceivingStarted(j['port'] as int);
    case 'offer':
      return OfferReceived(
        j['peer'] as String,
        j['platform'] as String,
        [for (final f in (j['files'] as List)) FileOffer((f as Map)['name'] as String, f['size'] as int)],
      );
    case 'progress':
      return Progress(j['name'] as String, j['done'] as int, j['total'] as int, incoming: incoming);
    case 'done':
      return Finished(j['files'] as int, incoming: incoming);
    case 'error':
      return Failed(j['message'] as String, incoming: incoming);
  }
  return null;
}
