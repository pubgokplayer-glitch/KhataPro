/// KhataPro · KPB1 — the encrypted backup pack.
///
/// One pack is: a small plaintext **header**, a **chunk table**, and a stream of
/// independent encrypted **chunks**. The header is authenticated by an HMAC taken
/// under a key derived from the pack key, so a manifest cannot be edited to claim
/// different contents; every chunk is authenticated on its own, so a partially
/// uploaded pack is still verifiable chunk by chunk — which is what makes an
/// interrupted upload resumable instead of restartable.
///
/// Layout (all integers big-endian, so a truncated file is detectable):
///
/// ```
///   magic     8 bytes   "KPB1\0\0\0\0"
///   version   2 bytes   format version (1)
///   headerLen 4 bytes   length of the canonical-JSON header
///   header    n bytes   canonical JSON: ledger, node, schema version, key id,
///                       created-at, parent pack id, chunk count, total bytes,
///                       merkle root over chunk hashes, nonce, kdf label
///   headerMac 32 bytes  HMAC-SHA256(packMacKey, magic||version||headerLen||header)
///   chunks…             each: 4-byte length, 16-byte nonce, ciphertext, 32-byte MAC
/// ```
///
/// Why per-chunk MACs rather than one MAC over everything: a single MAC would make
/// every byte of a pack interdependent, so a network drop at 90 % would cost the
/// whole upload. Per-chunk MACs plus a **merkle root in the header** give both
/// properties at once — partial progress survives, and the finished pack still has
/// one value that commits to all of it.
///
/// The pack key is a fresh random 32-byte key per pack, wrapped by the device's
/// `khata/backup/v1` keystore key (see `lib/platform/security/platform_key_custody.dart`).
/// That is why a background upload never prompts: the *pack* key is what encrypts,
/// and the keystore only wraps 32 bytes once per run.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/crdt/stamp.dart' show canonicalJson;
import '../../core/errors/khata_exception.dart';
import '../../core/security/aes.dart';
import '../../core/security/hasher.dart';
import '../../core/security/kdf.dart';

/// Format constants. A reader rejects anything it does not recognise rather than
/// guessing: a backup restored by a future version must fail loudly, not subtly.
abstract final class Kpb1 {
  static const List<int> magic = [0x4b, 0x50, 0x42, 0x31, 0, 0, 0, 0]; // "KPB1"
  static const int version = 1;
  static const int headerMacLength = 32;
  static const int chunkNonceLength = 16;
  static const int chunkMacLength = 32;
  static const int chunkLengthPrefix = 4;

  /// Bytes a chunk occupies in the pack: length prefix + nonce + ciphertext + MAC.
  static int framedBytes(int plaintextBytes) =>
      chunkLengthPrefix + chunkNonceLength + plaintextBytes + chunkMacLength;

  /// 4 MiB payload chunks. Small enough that a dropped connection wastes at most
  /// one chunk, large enough that a 52 MB ledger is 13 chunks rather than 800.
  static const int defaultTargetChunkBytes = 4 * 1024 * 1024;

  /// Domain separators, so a pack key can never be confused with a chunk key, and
  /// neither with the database wrapping key.
  static const String macInfo = 'khata-pro/kpb1/mac/v1';

  /// Commitments live in the header, and the header is what the manifest on Drive
  /// or iCloud is checked against. A pack whose bytes were edited in the cloud
  /// fails here, before a single row is imported.
  static Uint8List macKeyFor(Uint8List packKey) =>
      hkdfSha256(ikm: packKey, info: utf8.encode(macInfo), length: 32);
}

/// Where the bytes in a pack came from. Two kinds, and the difference matters at
/// restore time: a snapshot restores a database, an op-log segment replays changes.
enum Kpb1PayloadKind {
  /// A consistent copy of the whole encrypted database file.
  snapshot('snapshot'),

  /// A contiguous range of `oplog` rows, already stamped with HLCs.
  oplog('oplog');

  const Kpb1PayloadKind(this.id);

  final String id;

  static Kpb1PayloadKind fromId(String id) {
    for (final value in Kpb1PayloadKind.values) {
      if (value.id == id) return value;
    }
    throw InvariantViolation(
      invariantCode: 'SYNC-1',
      message: 'unknown pack payload kind "$id"',
    );
  }
}

/// The plan for splitting a payload: deterministic, so the same input always
/// produces the same chunk boundaries and a resumed upload agrees with the
/// original about what chunk 7 contains.
final class ChunkPlan {
  const ChunkPlan({
    required this.totalBytes,
    required this.targetChunkBytes,
    required this.chunkCount,
    required this.lastChunkBytes,
  });

  factory ChunkPlan.forLength(
    int totalBytes, {
    int targetChunkBytes = Kpb1.defaultTargetChunkBytes,
  }) {
    if (totalBytes < 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', 'must not be negative');
    }
    if (targetChunkBytes < 1024) {
      throw ArgumentError.value(
        targetChunkBytes,
        'targetChunkBytes',
        'below 1 KiB the per-chunk MAC costs more than the payload',
      );
    }
    if (totalBytes == 0) {
      return const ChunkPlan(
        totalBytes: 0,
        targetChunkBytes: Kpb1.defaultTargetChunkBytes,
        chunkCount: 0,
        lastChunkBytes: 0,
      );
    }
    final count = (totalBytes + targetChunkBytes - 1) ~/ targetChunkBytes;
    final last = totalBytes - (count - 1) * targetChunkBytes;
    return ChunkPlan(
      totalBytes: totalBytes,
      targetChunkBytes: targetChunkBytes,
      chunkCount: count,
      lastChunkBytes: last,
    );
  }

  final int totalBytes;
  final int targetChunkBytes;
  final int chunkCount;
  final int lastChunkBytes;

  /// Byte range of [index], as a half-open interval.
  (int start, int end) rangeOf(int index) {
    if (index < 0 || index >= chunkCount) {
      throw RangeError.index(index, this, 'index', 'chunk outside the plan', chunkCount);
    }
    final start = index * targetChunkBytes;
    final end = index == chunkCount - 1 ? totalBytes : start + targetChunkBytes;
    return (start, end);
  }

  int lengthOf(int index) {
    final (start, end) = rangeOf(index);
    return end - start;
  }
}

/// One chunk's identity: enough to verify it without holding it in memory.
final class Kpb1ChunkRef {
  const Kpb1ChunkRef({
    required this.index,
    required this.plaintextBytes,
    required this.sealedBytes,
    required this.sha256,
  });

  final int index;
  final int plaintextBytes;
  final int sealedBytes;

  /// SHA-256 of the *plaintext* chunk. Stored in the header and combined into the
  /// merkle root, so the manifest commits to the real content even though the
  /// cloud only ever sees ciphertext.
  final Uint8List sha256;

  /// Base64 rather than hex: the same 32 bytes in 44 characters instead of 64, and
  /// the repository already has a tested base64 helper.
  String get hashB64 => base64Std(sha256);

  Map<String, Object?> toJson() => {
        'i': index,
        'b': plaintextBytes,
        's': sealedBytes,
        'h': hashB64,
      };

  static Kpb1ChunkRef fromJson(Map<String, Object?> json) => Kpb1ChunkRef(
        index: (json['i'] as num).toInt(),
        plaintextBytes: (json['b'] as num).toInt(),
        sealedBytes: (json['s'] as num).toInt(),
        sha256: Uint8List.fromList(base64Decode('${json['h']}')),
      );
}

/// The header. Canonical JSON, authenticated by [Kpb1.headerMac].
final class Kpb1Header {
  const Kpb1Header({
    required this.ledgerId,
    required this.nodeId,
    required this.schemaVersion,
    required this.keyId,
    required this.createdAtMs,
    required this.kind,
    required this.totalBytes,
    required this.nonce,
    required this.merkleRoot,
    required this.chunks,
    this.parentPackId,
    this.hlcFrom,
    this.hlcTo,
    this.opCount,
  });

  final String ledgerId;
  final String nodeId;
  final int schemaVersion;

  /// `key_material.key_id` of the wrapping key — a pack restored on a device whose
  /// keystore cannot unwrap this id fails with a sentence the user can act on.
  final String keyId;
  final int createdAtMs;
  final Kpb1PayloadKind kind;
  final int totalBytes;

  /// The pack's AEAD nonce base: chunk `i` uses `nonce` with its last 8 bytes
  /// replaced by a big-endian counter `i`. Deterministic, unique per chunk, and
  /// committed to by the header MAC.
  final Uint8List nonce;

  /// Merkle root over the plaintext chunk hashes.
  final Uint8List merkleRoot;
  final List<Kpb1ChunkRef> chunks;

  /// For an incremental pack: the pack it extends. A restore walks the chain from
  /// the newest full snapshot forward and refuses a chain with a hole in it.
  final String? parentPackId;

  final String? hlcFrom;
  final String? hlcTo;
  final int? opCount;

  Map<String, Object?> toJson() => {
        'v': Kpb1.version,
        'ledger': ledgerId,
        'node': nodeId,
        'schema': schemaVersion,
        'key': keyId,
        'at': createdAtMs,
        'kind': kind.id,
        'bytes': totalBytes,
        'nonce': base64Encode(nonce),
        'merkle': base64Std(merkleRoot),
        'chunks': [for (final chunk in chunks) chunk.toJson()],
        if (parentPackId != null) 'parent': parentPackId,
        if (hlcFrom != null) 'from': hlcFrom,
        if (hlcTo != null) 'to': hlcTo,
        if (opCount != null) 'ops': opCount,
      };

  static Kpb1Header fromJson(Map<String, Object?> json) {
    final version = (json['v'] as num?)?.toInt();
    if (version != Kpb1.version) {
      throw InvariantViolation(
        invariantCode: 'SYNC-2',
        message: 'pack format v$version is not readable by this build '
            '(which writes v${Kpb1.version}). Update the app before restoring.',
      );
    }
    return Kpb1Header(
      ledgerId: '${json['ledger']}',
      nodeId: '${json['node']}',
      schemaVersion: (json['schema'] as num).toInt(),
      keyId: '${json['key']}',
      createdAtMs: (json['at'] as num).toInt(),
      kind: Kpb1PayloadKind.fromId('${json['kind']}'),
      totalBytes: (json['bytes'] as num).toInt(),
      nonce: base64Decode('${json['nonce']}'),
      merkleRoot: Uint8List.fromList(base64Decode('${json['merkle']}')),
      chunks: [
        for (final chunk in (json['chunks'] as List))
          Kpb1ChunkRef.fromJson((chunk as Map).cast<String, Object?>()),
      ],
      parentPackId: json['parent'] as String?,
      hlcFrom: json['from'] as String?,
      hlcTo: json['to'] as String?,
      opCount: (json['ops'] as num?)?.toInt(),
    );
  }
}

/// Writes a pack: seal chunk by chunk, collect references, then write the header.
///
/// Streaming by construction — a 52 MB ledger never exists in memory twice, which
/// matters on a 3 GB phone that is also rendering a 120 fps list.
final class Kpb1Writer {
  Kpb1Writer({
    required this.packKey,
    required this.ledgerId,
    required this.nodeId,
    required this.schemaVersion,
    required this.keyId,
    required this.kind,
    required this.createdAtMs,
    int targetChunkBytes = Kpb1.defaultTargetChunkBytes,
    Uint8List? nonce,
    this.parentPackId,
    this.hlcFrom,
    this.hlcTo,
    this.opCount,
  })  : targetChunkBytes = targetChunkBytes,
        nonce = nonce ?? randomBytes(Kpb1.chunkNonceLength);

  final Uint8List packKey;
  final String ledgerId;
  final String nodeId;
  final int schemaVersion;
  final String keyId;
  final Kpb1PayloadKind kind;
  final int createdAtMs;
  final int targetChunkBytes;
  final Uint8List nonce;
  final String? parentPackId;
  final String? hlcFrom;
  final String? hlcTo;
  final int? opCount;

  final _chunks = <Kpb1ChunkRef>[];
  final _sealed = <Uint8List>[];
  final _plaintextBuffer = BytesBuilder(copy: false);

  int get chunkCount => _chunks.length;

  /// Feeds bytes. Chunks are emitted as soon as a full target is buffered, so the
  /// caller can drive this from a file read loop without planning sizes up front.
  void add(Uint8List bytes) {
    _plaintextBuffer.add(bytes);
    while (_plaintextBuffer.length >= targetChunkBytes) {
      final all = _plaintextBuffer.takeBytes();
      _seal(all.sublist(0, targetChunkBytes));
      if (all.length > targetChunkBytes) {
        _plaintextBuffer.add(all.sublist(targetChunkBytes));
      }
    }
  }

  /// Finishes the pack and returns the bytes to upload: header, MAC, chunks.
  Uint8List finish({int totalBytes = 0}) {
    final remainder = _plaintextBuffer.takeBytes();
    if (remainder.isNotEmpty) _seal(remainder);

    final header = Kpb1Header(
      ledgerId: ledgerId,
      nodeId: nodeId,
      schemaVersion: schemaVersion,
      keyId: keyId,
      createdAtMs: createdAtMs,
      kind: kind,
      totalBytes: totalBytes == 0
          ? _chunks.fold<int>(0, (sum, chunk) => sum + chunk.plaintextBytes)
          : totalBytes,
      nonce: nonce,
      merkleRoot: Kpb1Merkle.rootOf([for (final chunk in _chunks) chunk.sha256]),
      chunks: _chunks,
      parentPackId: parentPackId,
      hlcFrom: hlcFrom,
      hlcTo: hlcTo,
      opCount: opCount,
    );

    final headerBytes = utf8.encode(canonicalJson(header.toJson()));
    final builder = BytesBuilder(copy: false)
      ..add(Kpb1.magic)
      ..add(_uint16(Kpb1.version))
      ..add(_uint32(headerBytes.length))
      ..add(headerBytes)
      ..add(Kpb1Merkle.headerMac(
        packKey,
        headerBytes,
        // magic || version || headerLen — authenticated along with the header, so
        // the length field cannot be used to smuggle extra JSON past the MAC.
        Uint8List.fromList([
          ...Kpb1.magic,
          ..._uint16(Kpb1.version),
          ..._uint32(headerBytes.length),
        ]),
      ));
    for (final sealed in _sealed) {
      builder.add(sealed);
    }
    return builder.takeBytes();
  }

  void _seal(Uint8List plaintext) {
    final index = _chunks.length;
    final chunkNonce = Kpb1Merkle.chunkNonce(nonce, index);
    final ciphertext = Uint8List.fromList(plaintext);
    AesCtr(key: packKey, iv: chunkNonce).apply(ciphertext);
    final mac = HmacSha256(key: Kpb1.macKeyFor(packKey))
        .compute(_chunkMacInput(index, ciphertext, chunkNonce));

    final sealed = BytesBuilder(copy: false)
      ..add(_uint32(ciphertext.length))
      ..add(chunkNonce)
      ..add(ciphertext)
      ..add(mac);
    _sealed.add(sealed.takeBytes());

    _chunks.add(Kpb1ChunkRef(
      index: index,
      plaintextBytes: plaintext.length,
      sealedBytes: ciphertext.length,
      sha256: sha256(plaintext),
    ));
  }

  Uint8List _chunkMacInput(int index, Uint8List ciphertext, Uint8List chunkNonce) {
    final builder = BytesBuilder(copy: false)
      ..add(utf8.encode('kpb1/chunk'))
      ..add(_uint32(index))
      ..add(chunkNonce)
      ..add(_uint32(ciphertext.length))
      ..add(ciphertext);
    return builder.takeBytes();
  }
}

/// Reads a pack back, verifying everything before returning anything.
///
/// [openChunk] is deliberately narrow: it verifies one chunk's MAC and hash,
/// which is what a resumable downloader needs to make progress checkpoint by
/// checkpoint instead of all-or-nothing.
final class Kpb1Reader {
  Kpb1Reader({required this.packKey, required this.bytes});

  final Uint8List packKey;
  final Uint8List bytes;

  Kpb1Header? _header;
  int _chunkTableEnd = 0;

  /// Parses and authenticates the header. Throws [InvariantViolation] when the
  /// magic, version or header MAC is wrong — before any chunk is touched.
  Kpb1Header parseHeader() {
    final cached = _header;
    if (cached != null) return cached;

    if (bytes.length < Kpb1.magic.length + 2 + 4 + Kpb1.headerMacLength) {
      throw InvariantViolation(
        invariantCode: 'SYNC-3',
        message: 'the pack is ${bytes.length} bytes — too short to be a KPB1 pack. '
            'It is likely a partial download.',
      );
    }
    for (var i = 0; i < Kpb1.magic.length; i++) {
      if (bytes[i] != Kpb1.magic[i]) {
        throw InvariantViolation(
          invariantCode: 'SYNC-4',
          message: 'this file is not a KhataPro backup pack',
        );
      }
    }
    final version = (bytes[8] << 8) | bytes[9];
    if (version != Kpb1.version) {
      throw InvariantViolation(
        invariantCode: 'SYNC-2',
        message: 'pack format v$version is not readable by this build '
            '(which writes v${Kpb1.version}). Update the app before restoring.',
      );
    }
    final headerLength = _readUint32(bytes, 10);
    final headerStart = 14;
    final headerEnd = headerStart + headerLength;
    final macEnd = headerEnd + Kpb1.headerMacLength;
    if (macEnd > bytes.length) {
      throw InvariantViolation(
        invariantCode: 'SYNC-3',
        message: 'the pack header claims $headerLength bytes but the file ends '
            'before it does — this is a truncated upload.',
      );
    }

    final headerBytes = Uint8List.sublistView(bytes, headerStart, headerEnd);
    // The MAC covers magic || version || headerLen || header, exactly as the writer
    // computes it — including the length field, so the header cannot be extended.
    final expectedMac = HmacSha256(key: Kpb1.macKeyFor(packKey)).compute(
      Kpb1Merkle.headerMacInput(
        headerBytes,
        Uint8List.fromList(bytes.sublist(0, headerStart)),
      ),
    );
    final actualMac = Uint8List.sublistView(bytes, headerEnd, macEnd);
    if (!constantTimeEquals(expectedMac, actualMac)) {
      throw const InvariantViolation(
        invariantCode: 'SYNC-5',
        message: 'the pack header does not authenticate: either the wrong key is in '
            'use, or the manifest was edited after it was written',
      );
    }

    final header = Kpb1Header.fromJson(
      (jsonDecode(utf8.decode(headerBytes)) as Map).cast<String, Object?>(),
    );
    _header = header;
    _chunkTableEnd = macEnd;
    return header;
  }

  /// Reads chunk [index], verifying its MAC and its SHA-256 against the header.
  Uint8List openChunk(int index) {
    final header = parseHeader();
    if (index < 0 || index >= header.chunks.length) {
      throw RangeError.index(index, header.chunks, 'index', 'chunk not in pack');
    }

    // Walk the preceding chunks to find this one's offset. The per-chunk frame is
    // `length(4) || nonce(16) || ciphertext || mac(32)`, and `plaintextBytes` equals
    // the ciphertext length for a stream cipher — which is why the table can hold
    // one number for both.
    var offset = _chunkTableEnd;
    for (var i = 0; i < index; i++) {
      offset += Kpb1.framedBytes(header.chunks[i].plaintextBytes);
    }
    final length = _readUint32(bytes, offset);
    final nonceStart = offset + Kpb1.chunkLengthPrefix;
    final cipherStart = nonceStart + Kpb1.chunkNonceLength;
    final macStart = cipherStart + length;
    if (macStart + Kpb1.chunkMacLength > bytes.length) {
      throw InvariantViolation(
        invariantCode: 'SYNC-3',
        message: 'chunk $index runs past the end of the file: the upload stopped '
            'part way. Re-run the backup to finish it.',
      );
    }

    final chunkNonce = Uint8List.sublistView(bytes, nonceStart, cipherStart);
    final ciphertext = Uint8List.sublistView(bytes, cipherStart, macStart);
    final actualMac = Uint8List.sublistView(bytes, macStart, macStart + Kpb1.chunkMacLength);

    final expectedMac = HmacSha256(key: Kpb1.macKeyFor(packKey)).compute(
      Uint8List.fromList([
        ...utf8.encode('kpb1/chunk'),
        ..._uint32(index),
        ...chunkNonce,
        ..._uint32(ciphertext.length),
        ...ciphertext,
      ]),
    );
    if (!constantTimeEquals(expectedMac, actualMac)) {
      throw InvariantViolation(
        invariantCode: 'SYNC-5',
        message: 'chunk $index does not authenticate — the pack is corrupted or was '
            'altered in the cloud',
      );
    }

    final plaintext = Uint8List.fromList(ciphertext);
    AesCtr(key: packKey, iv: chunkNonce).apply(plaintext);

    final expectedHash = header.chunks[index].sha256;
    if (!constantTimeEquals(sha256(plaintext), expectedHash)) {
      throw InvariantViolation(
        invariantCode: 'SYNC-6',
        message: 'chunk $index authenticated but its content hash differs from the '
            'header: this pack mixes two different backups',
      );
    }
    return plaintext;
  }

  /// Verifies the whole pack and returns every chunk. Used by the restore drill,
  /// not by the incremental downloader.
  List<Uint8List> openAll() {
    final header = parseHeader();
    return [for (var i = 0; i < header.chunks.length; i++) openChunk(i)];
  }

  /// Recomputes the merkle root from the *header's* chunk hashes and compares it
  /// with the header's own root — cheap, and it catches a header that was edited
  /// without recomputing the root (the MAC would also catch it, but two checks
  /// disagreeing is a bug worth failing on).
  bool verifyMerkleRoot() {
    final header = parseHeader();
    return constantTimeEquals(
      Kpb1Merkle.rootOf([for (final chunk in header.chunks) chunk.sha256]),
      header.merkleRoot,
    );
  }
}

/// The merkle root, the header MAC and the per-chunk nonce derivation.
abstract final class Kpb1Merkle {
  /// Root over the leaves, in order. A single leaf is its own root; an empty pack
  /// hashes the domain separator, so "no chunks" is still a commitment rather than
  /// an absence that could be swapped for anything.
  static Uint8List rootOf(List<Uint8List> leaves) {
    if (leaves.isEmpty) return sha256(utf8.encode('kpb1/empty'));
    var level = [for (final leaf in leaves) Uint8List.fromList(leaf)];
    while (level.length > 1) {
      final next = <Uint8List>[];
      for (var i = 0; i < level.length; i += 2) {
        if (i + 1 == level.length) {
          // An odd node is carried up unchanged rather than duplicated: duplicating
          // it invites the classic second-preimage confusion between a 3-leaf and a
          // 4-leaf tree.
          next.add(level[i]);
        } else {
          next.add(_pairHash(level[i], level[i + 1]));
        }
      }
      level = next;
    }
    return level.first;
  }

  static Uint8List _pairHash(Uint8List left, Uint8List right) => sha256(
        Uint8List.fromList([...utf8.encode('kpb1/node'), ...left, ...right]),
      );

  static Uint8List headerMac(
    Uint8List packKey,
    Uint8List headerBytes,
    Uint8List prefixBytes,
  ) =>
      HmacSha256(key: Kpb1.macKeyFor(packKey)).compute(
        headerMacInput(headerBytes, prefixBytes),
      );

  /// `magic || version || headerLen || header` — the length is inside the MAC so a
  /// header cannot be extended with attacker-chosen JSON.
  static Uint8List headerMacInput(Uint8List headerBytes, Uint8List prefixBytes) =>
      Uint8List.fromList([...prefixBytes, ...headerBytes]);

  /// Chunk `index` uses the pack nonce with its trailing 8 bytes replaced by the
  /// big-endian counter. Deterministic so a resumed upload reconstructs the same
  /// nonce; unique so no two chunks share a counter block.
  static Uint8List chunkNonce(Uint8List packNonce, int index) {
    if (packNonce.length != Kpb1.chunkNonceLength) {
      throw ArgumentError.value(packNonce.length, 'packNonce.length', 'must be 16');
    }
    final nonce = Uint8List.fromList(packNonce);
    for (var i = 0; i < 8; i++) {
      nonce[8 + i] = (index >> (8 * (7 - i))) & 0xff;
    }
    return nonce;
  }
}

// ── small helpers ────────────────────────────────────────────────────────────

Uint8List _uint32(int value) => Uint8List(4)
  ..[0] = (value >> 24) & 0xff
  ..[1] = (value >> 16) & 0xff
  ..[2] = (value >> 8) & 0xff
  ..[3] = value & 0xff;

Uint8List _uint16(int value) => Uint8List(2)
  ..[0] = (value >> 8) & 0xff
  ..[1] = value & 0xff;

int _readUint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
