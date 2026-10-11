/// KhataPro · finding the other phone without a server.
///
/// mDNS/DNS-SD is how LAN sync starts: each device advertises
/// `_khata-sync._tcp.local` with a few TXT records, and listens for the same.
/// Nothing leaves the local network — mDNS is link-local multicast, which is
/// precisely why it needs no infrastructure and no account.
///
/// Two design choices worth stating, because both are about *not* leaking:
///
///  * **The TXT records carry no ledger content.** A node id, the protocol version,
///    a truncated hash of the ledger id, and a display name the user chose. Not the
///    business name, not the balance, not the file name. Anyone on the café Wi-Fi can
///    see these records, and a ledger's existence is nobody's business but the
///    owner's.
///  * **Discovery is not trust.** Seeing a peer means it exists. Connecting requires
///    the QR exchange and the six-digit comparison in `qr_pairing.dart`, because a
///    stranger on the same Wi-Fi can advertise the service too.
///
/// `nsd` is used for advertising and discovery because it handles the platform
/// differences (NSNetService on iOS, NsdManager on Android) and gives us
/// `ServiceListener` callbacks for free.
///
/// **TXT values are bytes.** `nsd` 5.0.1 types them as `Map<String, Uint8List?>`
/// because that is what DNS-SD is: Android insists the payload be convertible to
/// UTF-8, iOS treats it as opaque `NSData`. So everything written here is UTF-8
/// encoded on the way out and decoded on the way in. The obvious-looking
/// `txt: {'nid': nodeId}` does not compile; the subtly wrong version (reading
/// `service.txt?['nid']` and comparing it to a `String`) *does* compile, runs, and
/// matches no peer ever, because a `Uint8List` is never equal to a `String`. That is
/// the bug this file shipped with, and no harness can see it — mDNS needs a radio.
/// See docs/SYNC.md §6.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nsd/nsd.dart' as nsd;

/// The service type. A single label, registered under `.local`.
const String kSyncServiceType = '_khata-sync._tcp';

/// The port advertised with the service. There is no socket behind it: signalling
/// travels inside the pairing ticket (a QR code, or a second ticket handed back over
/// the data channel), so there is nothing to dial. A port is still required by the
/// DNS-SD record, and this value is a marker rather than a service.
const int kUnusedAdvertisedPort = 9;

/// A peer that is visible on this network right now.
final class DiscoveredPeer {
  const DiscoveredPeer({
    required this.nodeId,
    required this.displayName,
    required this.protocolVersion,
    required this.ledgerFingerprint,
    required this.host,
    required this.port,
    required this.lastSeenMs,
    this.requiresPairing = true,
  });

  final String nodeId;
  final String displayName;
  final int protocolVersion;

  /// The first 8 hex characters of the ledger id's hash. Two phones showing the same
  /// fingerprint are holding the same books; a mismatch is worth a warning before
  /// anything is transferred.
  final String ledgerFingerprint;

  final String host;
  final int port;
  final int lastSeenMs;

  /// Always true, and it must stay that way: discovery never implies authorisation,
  /// so the field is stated rather than omitted so no future caller can mistake a
  /// peer for a trusted device. (Protocol compatibility is a *filter* —
  /// [PeerFilter.isCompatible] — not a shortcut past pairing.)
  final bool requiresPairing;
}

/// Advertises this device and watches for others.
final class MdnsSyncDiscovery {
  MdnsSyncDiscovery({
    required this.nodeId,
    required this.displayName,
    required this.ledgerFingerprint,
    this.protocolVersion = 1,
    this.staleAfter = const Duration(minutes: 2),
  });

  final String nodeId;
  final String displayName;
  final String ledgerFingerprint;
  final int protocolVersion;
  final Duration staleAfter;

  nsd.Registration? _registration;
  nsd.Discovery? _discovery;
  final _peers = <String, DiscoveredPeer>{};
  final _controller = StreamController<List<DiscoveredPeer>>.broadcast();
  Timer? _sweeper;
  void Function()? _listener;

  /// The current peer list, updated as services appear, resolve and disappear.
  Stream<List<DiscoveredPeer>> get peers => _controller.stream;

  /// Advertising asks for an IP lookup, so [DiscoveredPeer.host] is an address rather
  /// than a hostname: resolving `.local` names is unreliable from a sandboxed app on
  /// iOS, and the ticket has to carry something the other phone can reach.
  static const nsd.IpLookupType _ipLookup = nsd.IpLookupType.any;

  /// Starts advertising and discovering. Safe to call once per app run; calling it
  /// again while running is a no-op rather than a second registration (two
  /// registrations of the same type on one device confuse some Android stacks).
  Future<void> start() async {
    if (_registration != null || _discovery != null) return;

    _registration = await nsd.register(
      nsd.Service(
        name: 'KhataPro-${_shortName(nodeId)}',
        type: kSyncServiceType,
        port: kUnusedAdvertisedPort,
        txt: {
          'nid': _txt(nodeId),
          'name': _txt(displayName),
          'v': _txt('$protocolVersion'),
          'led': _txt(ledgerFingerprint),
        },
      ),
    );

    // `autoResolve` (the default) resolves discovered services; `ipLookupType` is what
    // fills in `Service.addresses`, and IP lookup requires auto-resolve to be on.
    _discovery = await nsd.startDiscovery(kSyncServiceType, ipLookupType: _ipLookup);
    _listener = _refresh;
    _discovery!.addListener(_listener!);

    // A peer that stopped advertising never sends a goodbye on a phone that was
    // killed, so staleness is time-based rather than event-based.
    _sweeper = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  Future<void> stop() async {
    _sweeper?.cancel();
    _sweeper = null;
    final discovery = _discovery;
    if (discovery != null) {
      // Removing the listener matters: `nsd.Discovery` is a `ChangeNotifier`, so a
      // forgotten closure keeps this object (and its stream) alive for the life of the
      // app — and a plugin that leaks one discovery per visit to the sync screen leaks
      // an `NsdManager` registration with it.
      final listener = _listener;
      if (listener != null) discovery.removeListener(listener);
      await nsd.stopDiscovery(discovery);
    }
    final registration = _registration;
    if (registration != null) await nsd.unregister(registration);
    _discovery = null;
    _registration = null;
    _listener = null;
  }

  /// The peers seen in the last [staleAfter], newest first.
  List<DiscoveredPeer> current() {
    final cutoff = DateTime.now().subtract(staleAfter).millisecondsSinceEpoch;
    final live = _peers.values.where((peer) => peer.lastSeenMs >= cutoff).toList()
      ..sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));
    return live;
  }

  void _refresh() {
    final discovery = _discovery;
    if (discovery == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final service in discovery.services) {
      final nodeId = _text(service.txt?['nid']);
      // Our own advertisement is not a peer.
      if (nodeId == null || nodeId == this.nodeId) continue;
      // Without an address there is nothing to show and nothing to dial.
      final host = service.addresses?.isNotEmpty == true
          ? service.addresses!.first.address
          : service.host ?? '';
      if (host.isEmpty) continue;
      final version = int.tryParse(_text(service.txt?['v']) ?? '1') ?? 1;
      _peers[nodeId] = DiscoveredPeer(
        nodeId: nodeId,
        displayName: _text(service.txt?['name']) ?? 'Another device',
        protocolVersion: version,
        ledgerFingerprint: _text(service.txt?['led']) ?? '',
        host: host,
        port: service.port ?? kUnusedAdvertisedPort,
        lastSeenMs: now,
        // Always true — see [DiscoveredPeer.requiresPairing]. An earlier version of
        // this line read `version == protocolVersion`, i.e. it claimed "no pairing
        // required" for the one class of peer worth trusting least: a device whose
        // protocol this build does not understand.
        requiresPairing: true,
      );
    }
    _controller.add(current());
  }

  /// Closes the stream. Call after [stop] when the sync screen goes away.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  /// Writes a TXT value as DNS-SD wants it: UTF-8 bytes.
  static Uint8List _txt(String value) => Uint8List.fromList(utf8.encode(value));

  /// Reads one back, tolerating a record from something else entirely (a device that
  /// advertises the same service type but was not written by this app) with bytes that
  /// are not UTF-8.
  static String? _text(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  static String _shortName(String nodeId) =>
      nodeId.length > 6 ? nodeId.substring(nodeId.length - 6) : nodeId;
}

/// Whether a discovered peer is worth showing. Split out so the UI logic is
/// testable without an mDNS stack.
abstract final class PeerFilter {
  /// True when the peer speaks the same protocol version. This is a *filter*, not a
  /// trust decision: a version mismatch means the two phones disagree about what a
  /// frame means, so no pairing should be offered at all. Protocol versions
  /// deliberately travel in the TXT record so this can be answered before a ticket is
  /// ever rendered.
  static bool isCompatible(DiscoveredPeer peer, {required int protocolVersion}) =>
      peer.protocolVersion == protocolVersion;

  /// True when both devices report the same ledger fingerprint: they are holding the
  /// same books, so a merge makes sense. Used to warn *before* pairing rather than
  /// after.
  static bool sameLedger(DiscoveredPeer peer, {required String fingerprint}) =>
      peer.ledgerFingerprint.isNotEmpty &&
      fingerprint.isNotEmpty &&
      peer.ledgerFingerprint == fingerprint;
}
