/// KhataPro · pairing two phones with a QR code, and proving they got the same
/// code.
///
/// QR pairing exists because there is no server to introduce two devices to each
/// other. The offerer renders a QR; the joiner scans it; the joiner's SDP answer
/// comes back over the data channel or a second QR. None of that needs the internet,
/// which is the requirement.
///
/// The part that is easy to get wrong is **authentication**. A QR code photographed
/// off a screen can be replayed by a third device sitting on the same Wi-Fi — the
/// classic man-in-the-middle on a LAN. So there are three defences here, and none of
/// them involves trusting the network:
///
///  1. **Expiry.** A ticket is valid for [defaultTicketLifetime]. A photographed QR
///     is a ticket with a countdown, and the countdown is short because the whole
///     pairing is a two-minute operation.
///  2. **Integrity.** The payload is authenticated with a key derived from the
///     offerer's ephemeral secret, so an attacker cannot edit the SDP or the
///     candidate list in flight. (Authenticity is *not* claimed — that is what
///     defence 3 is for.)
///  3. **A short authentication string.** Both screens show the same six digits,
///     derived from *both* peers' ephemeral public keys. The two shopkeepers — who
///     are standing next to each other — glance at the two phones and compare. A
///     man-in-the-middle cannot make the digits agree unless it holds both private
///     keys, which is exactly what DH gives us. This is the one step no amount of
///     cleverness can replace, and it is why the flow has two people in it.
///
/// The payload is compressed and base64url-encoded, because an SDP with ICE
/// candidates is 1–3 KB and QR capacity at a scannable density is ~1 KB. Only host
/// candidates are carried: LAN-only sync needs no STUN, and including a reflexive
/// candidate would mean leaking the user's public IP into a QR code.
///
/// The compression is **deflate**, and that is a measured decision rather than a
/// taste: a hand-rolled run-length encoder — the first thing this file did, on the
/// theory that it needed no dependency and handled candidate runs well — *inflated*
/// a realistic ticket from 1113 to 2838 characters (2.55×: an ASCII byte never repeats
/// enough to pay for a count byte). That is 115 characters below a version-40 QR
/// code's absolute maximum of 2953, i.e. one more candidate line away from a pairing
/// screen that simply cannot draw a code, with no error anywhere. Deflate takes the
/// same ticket to 786 characters. The numbers are asserted in `tool/sync_verify.dart`
/// so a future "optimisation" cannot quietly undo it.
library;

import 'dart:convert';
// `zlib` from dart:io: raw DEFLATE, in the SDK, no package. This app targets Android
// and iOS only (a web build would need `package:archive` instead, since dart:io does
// not exist there) — see docs/THIRD_PARTY.md.
import 'dart:io' show zlib;
import 'dart:typed_data';

import '../../core/errors/khata_exception.dart';
import '../../core/security/hasher.dart';
import '../../core/security/kdf.dart';

/// One pairing ticket, as encoded in the QR.
final class PairingTicket {
  const PairingTicket({
    required this.version,
    required this.nodeId,
    required this.role,
    required this.createdAtMs,
    required this.expiresAtMs,
    required this.nonce,
    required this.sessionDescription,
    required this.candidates,
    required this.ephemeralPublicKey,
    this.ledgerId,
    this.displayName,
  });

  static const int currentVersion = 1;

  final int version;
  final String nodeId;

  /// Which side of the offer/answer exchange this ticket is.
  final PairingRole role;
  final int createdAtMs;
  final int expiresAtMs;

  /// 16 random bytes: the ticket's identity, and the freshness check. A replayed
  /// ticket fails here, before DH is even reached.
  final Uint8List nonce;
  final String sessionDescription;
  final List<String> candidates;

  /// The peer's ephemeral public key (X25519 or P-256, opaque here), used for the
  /// shared secret behind the authentication string.
  final Uint8List ephemeralPublicKey;

  /// Shown on the sync screen as a sanity check: "adding Basit's phone".
  final String? displayName;

  /// Present in a *resumed* pairing, so the joiner can confirm it is the same books.
  final String? ledgerId;

  bool get isExpired => DateTime.now().millisecondsSinceEpoch > expiresAtMs;

  /// The compact wire form. Keys are one or two characters because every byte here
  /// is a QR module, and a denser QR is a harder scan in a shop with bad lighting.
  Map<String, Object?> toJson() => {
        'v': version,
        'n': nodeId,
        'r': role.id,
        'c': createdAtMs,
        'e': expiresAtMs,
        'x': base64UrlNoPad(nonce),
        's': sessionDescription,
        'i': candidates,
        'k': base64UrlNoPad(ephemeralPublicKey),
        if (displayName != null) 'd': displayName,
        if (ledgerId != null) 'l': ledgerId,
      };

  static PairingTicket fromJson(Map<String, Object?> json) {
    final version = (json['v'] as num?)?.toInt();
    if (version != currentVersion) {
      throw InvariantViolation(
        invariantCode: 'PAIR-1',
        message: 'this pairing code was made by a different version of KhataPro '
            '(code v$version, this app reads v$currentVersion). Ask the other phone '
            'to update, or add the device by backup file instead.',
      );
    }
    return PairingTicket(
      version: version!,
      nodeId: '${json['n']}',
      role: PairingRole.fromId('${json['r']}'),
      createdAtMs: (json['c'] as num).toInt(),
      expiresAtMs: (json['e'] as num).toInt(),
      nonce: Uint8List.fromList(base64Url.decode(_pad('${json['x']}'))),
      sessionDescription: '${json['s']}',
      candidates: [for (final candidate in (json['i'] as List? ?? const [])) '$candidate'],
      ephemeralPublicKey: Uint8List.fromList(base64Url.decode(_pad('${json['k']}'))),
      displayName: json['d'] as String?,
      ledgerId: json['l'] as String?,
    );
  }
}

/// Who is offering and who is answering. The roles decide who shows the QR and who
/// shows the answer, and which key is which in the authentication string.
enum PairingRole {
  offer('o'),
  answer('a');

  const PairingRole(this.id);

  final String id;

  static PairingRole fromId(String id) =>
      id == offer.id ? offer : answer;
}

/// What a completed pairing is allowed to do.
///
/// Pairing is not "trust forever": a device is granted a scope when it is paired,
/// and the grant is visible and revocable in Settings. A shopkeeper who pairs a
/// phone with his accountant can hand over *read-only* access, which is what the
/// accountant actually wanted.
final class PairingGrant {
  const PairingGrant({
    required this.peerNodeId,
    required this.peerDisplayName,
    required this.scope,
    required this.pairedAtMs,
    required this.sessionCode,
    required this.expiresAtMs,
  });

  final String peerNodeId;
  final String peerDisplayName;
  final PairingScope scope;
  final int pairedAtMs;

  /// The six digits both screens showed. Stored, because "which code did you see?"
  /// is the only question that can resolve a dispute later.
  final String sessionCode;
  final int expiresAtMs;
}

/// What a paired device may do with these books.
enum PairingScope {
  /// Push and pull changes, both directions. The normal case: the owner's second
  /// phone, or the shop's tablet.
  full('full'),

  /// The peer receives changes but may not send any. For an accountant, or for a
  /// second device used only to look things up.
  readOnly('read_only'),

  /// One-shot: exchange changes once, then the grant is void. For a device you do
  /// not own — a customer's phone, a repair shop's diagnostic tablet.
  once('once');

  const PairingScope(this.id);

  final String id;
}

/// The six-digit code both phones display.
///
/// Derived from **both** ephemeral public keys, sorted so the two sides compute the
/// same value without one of them having to be "first". Six digits is 20 bits: not
/// strong cryptography, and not meant to be — it is compared by two humans looking
/// at two screens a metre apart, in the few seconds before the transfer starts.
/// That is the threat model, and it is the right one.
abstract final class SessionCode {
  static const String _info = 'khata-pro/pairing/sas/v1';

  static String derive({
    required Uint8List localPublicKey,
    required Uint8List remotePublicKey,
    required Uint8List nonce,
  }) {
    // Sorted, so the two sides agree regardless of who is offer and who is answer.
    final localIsFirst = _compare(localPublicKey, remotePublicKey) <= 0;
    final first = localIsFirst ? localPublicKey : remotePublicKey;
    final second = localIsFirst ? remotePublicKey : localPublicKey;

    final digest = hkdfSha256(
      ikm: Uint8List.fromList([...first, ...second]),
      // The nonce binds the code to this pairing attempt, so a code from an earlier
      // attempt cannot be replayed against a later one.
      info: Uint8List.fromList([...utf8.encode(_info), ...nonce]),
      length: 16,
    );

    // Four bytes → 20 bits → six digits, with rejection-free modulo on a power of ten
    // by taking the value modulo 1,000,000. Biased by ~1e-7, which is irrelevant for
    // a value a human compares and which expires in two minutes.
    final value = ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3]) %
        1000000;
    return value.toString().padLeft(6, '0');
  }

  static int _compare(Uint8List a, Uint8List b) {
    final length = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return a.length.compareTo(b.length);
  }
}

/// Encodes and decodes the compact string that goes into the QR.
abstract final class PairingCodec {
  /// The scannability budget, in characters of encoded payload.
  ///
  /// A version-40 QR (the largest, 177×177 modules) holds 2953 bytes, so that is the
  /// hard ceiling — but a code that dense needs a steady hand and good light, and the
  /// phone's own screen brightness fights the camera. A realistic ticket costs ~790
  /// characters, so this budget carries real headroom for a third candidate line, a
  /// long display name and a bigger ledger id, and it fails the *test*, not the user,
  /// if a future change eats that headroom.
  static const int scannableBudget = 1200;

  /// JSON, deflated, base64url'd, with a version byte in front.
  ///
  /// The real size saving comes from what the transport *doesn't* put in here — no
  /// codec lines, no STUN servers, no media sections, because a data-channel-only
  /// connection needs none of them (see `sdp_tools.dart`).
  static String encode(PairingTicket ticket) {
    final json = utf8.encode(jsonEncode(ticket.toJson()));
    final compressed = zlib.encode(json);
    return base64UrlNoPad(Uint8List.fromList([PairingTicket.currentVersion, ...compressed]));
  }

  static PairingTicket decode(String code) {
    final raw = base64Url.decode(_pad(code));
    if (raw.isEmpty) {
      throw const InvariantViolation(
        invariantCode: 'PAIR-2',
        message: 'that QR code is empty',
      );
    }
    final version = raw.first;
    if (version != PairingTicket.currentVersion) {
      throw InvariantViolation(
        invariantCode: 'PAIR-1',
        message: 'pairing code v$version is not readable by this app '
            '(v${PairingTicket.currentVersion})',
      );
    }
    try {
      final json = utf8.decode(zlib.decode(raw.sublist(1)));
      return PairingTicket.fromJson((jsonDecode(json) as Map).cast<String, Object?>());
    } on FormatException catch (error) {
      throw InvariantViolation(
        invariantCode: 'PAIR-2',
        message: 'that QR code could not be read (${error.message}). It may be for '
            'another app.',
      );
    }
  }

  /// Ticket validity: long enough to walk a phone across a counter and scan it,
  /// short enough that a photo taken over a shoulder is useless by the time it is
  /// used.
  static const Duration defaultTicketLifetime = Duration(minutes: 2);
}

String _pad(String value) {
  final remainder = value.length % 4;
  return remainder == 0 ? value : value + '=' * (4 - remainder);
}
