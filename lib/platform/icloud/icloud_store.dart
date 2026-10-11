/// KhataPro · iCloud Drive as the iOS bring-your-own-cloud target.
///
/// iCloud has no OAuth, no token and no quota API in the app's reach: the app gets
/// a **ubiquity container** the OS keeps in sync with the user's Apple Account, and
/// writes files into it. That makes the implementation simpler than Drive's in one
/// way — files are files — and harder in another: there is no resumable-upload
/// session and no partial upload at all, so resumption is [BlobStore]'s job: bytes
/// accumulate in a local staging file named `*.part` and only a *whole* file is
/// uploaded. A half-uploaded pack therefore cannot exist, which is also what keeps
/// it out of `list()`: nothing is a candidate for restore until it is whole.
///
/// Metadata queries go through `NSMetadataQuery`, which is why the adapter takes a
/// [UbiqContainer] rather than doing file I/O directly: the container is the part
/// that needs a platform channel, and everything above it is ordinary Dart that the
/// harness can run against a temporary directory.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/security/hasher.dart';
import '../../sync/backup/resumable_transfer.dart';

/// The filesystem-plus-metadata operations iCloud needs.
///
/// One implementation talks to `package:icloud_storage`; the tests implement it over
/// `Directory.systemTemp`.
///
/// The shape of this interface is dictated by what the plugin can actually do, which
/// is *not* "here is a directory, do file I/O in it". `icloud_storage` exposes
/// **whole-file operations in a container**: it lists a container, uploads a local
/// file to a relative path, downloads a relative path to a local file, deletes and
/// moves. So there is no container path to hand out, appended writes must be staged
/// locally, and a file only becomes visible to the cloud when it is uploaded
/// wholesale. The interface says exactly that:
///
///  * [writeBytes] writes into a **local staging area** keyed by the relative path.
///    It is where an interrupted upload resumes from — [stagedBytes] is the resume
///    offset, and a crash mid-append costs nothing.
///  * [commit] makes a staged file visible in the container (iCloud: uploads it).
///    Until that call, nothing cloud-side knows the file exists — which is why a
///    half-written pack can never be listed as restorable.
///  * [list] reports only committed files, plus the `uploaded` flag for the ones the
///    OS has not pushed to the cloud yet.
abstract interface class UbiqContainer {
  /// Whether the container can be reached at all: signed in to an Apple Account
  /// with iCloud Drive enabled, and the entitlement present. False is normal
  /// (plenty of people never sign in) and the UI says "iCloud is off", not "error".
  Future<bool> isAvailable();

  /// Committed files in [relativeDirectory], with sizes and dates. A file still
  /// uploading is reported with `isUploaded == false` and must be treated as absent
  /// by callers that care about durability.
  Future<List<UbiqEntry>> list(String relativeDirectory);

  /// Bytes of the *staged* file at [relativePath] on this device, or 0 if there is
  /// none. This is the resume offset, and it is a local question with a local
  /// answer — no round trip, no server to disagree with.
  Future<int> stagedBytes(String relativePath);

  /// Appends [bytes] to the staged file at [relativePath], or starts it when
  /// [append] is false.
  Future<void> writeBytes(String relativePath, Uint8List bytes, {bool append = false});

  /// Promotes a staged file to a committed one (iCloud: uploads it).
  Future<void> commit(String relativePath);

  Future<Uint8List> readBytes(String relativePath, {int? offset, int? length});

  Future<void> delete(String relativePath);

  Future<void> rename(String fromRelativePath, String toRelativePath);

  /// Free space, or null when the platform will not say. iOS does not expose iCloud
  /// quota to apps; null is the honest answer and the UI shows "unknown".
  Future<int?> freeBytes();
}

/// One entry in the container.
final class UbiqEntry {
  const UbiqEntry({
    required this.relativePath,
    required this.bytes,
    required this.modifiedAtMs,
    required this.uploaded,
  });

  final String relativePath;
  final int bytes;
  final int modifiedAtMs;

  /// False while iCloud is still pushing the file up. An un-uploaded file is *not*
  /// a backup: treating it as one would let a phone report "backed up" while the
  /// only copy sits on the device it just fell out of.
  final bool uploaded;

  String get name => relativePath.split('/').last;
}

/// iCloud Drive, as a [BlobStore].
final class IcloudBlobStore implements BlobStore {
  IcloudBlobStore({
    required this.container,
    this.directory = 'Backups',
  });

  final UbiqContainer container;

  /// Relative to the container root. `Documents/` exists by default on iOS, but the
  /// store keeps its own folder so a user who browses the Files app sees one tidy
  /// directory rather than a pile of packs.
  final String directory;

  static const String partialSuffix = '.part';
  static const String completedSuffix = '.kpb1';

  String _path(String name) => '$directory/$name$completedSuffix';
  String _partialPath(String name) => '$directory/$name$partialSuffix';

  @override
  Future<int?> availableBytes() => container.freeBytes();

  @override
  Future<List<RemoteBlob>> list({String prefix = ''}) async {
    final entries = await container.list(directory);
    return [
      for (final entry in entries)
        if (entry.uploaded && entry.name.endsWith(completedSuffix))
          if (prefix.isEmpty || entry.name.startsWith(prefix))
            RemoteBlob(
              name: entry.name.substring(0, entry.name.length - completedSuffix.length),
              bytes: entry.bytes,
              modifiedAtMs: entry.modifiedAtMs,
            ),
    ]..sort((a, b) => b.modifiedAtMs.compareTo(a.modifiedAtMs));
  }

  @override
  Future<UploadSession> beginUpload(
    String name, {
    required int totalBytes,
    String? resumeToken,
  }) async {
    if (!await container.isAvailable()) {
      throw const TransferFailure(
        kind: TransferFailureKind.permanent,
        message: 'iCloud Drive is switched off, or this device is not signed in to '
            'an Apple Account with iCloud',
      );
    }
    // The staged file's current size *is* the resume offset: a local question with a
    // local answer, so no token to expire and no server to disagree with. Asking for
    // the size rather than reading the file matters — a 52 MB partial that is 49 MB
    // done would otherwise be read into memory to learn one integer.
    final committed = await container.stagedBytes(_partialPath(name));
    return UploadSession(
      name: name,
      totalBytes: totalBytes,
      resumeToken: _partialPath(name),
      committedBytes: committed,
    );
  }

  @override
  Future<int> uploadChunk(UploadSession session, int offset, Uint8List bytes) async {
    // Append-only. Writing a random-access range into a file the OS is also syncing
    // is a good way to lose the tail of an upload; appending is not.
    if (offset == 0) {
      await container.writeBytes(session.resumeToken, bytes);
    } else {
      await container.writeBytes(session.resumeToken, bytes, append: true);
    }
    return offset + bytes.length;
  }

  @override
  Future<RemoteBlob> completeUpload(UploadSession session) async {
    // Two steps on purpose: `commit` is the point of no return (iCloud uploads the
    // whole staged file), and the rename is a cheap metadata move afterwards. An app
    // killed between them leaves a committed `*.part`, which is swept by
    // [sweepPartials] rather than restored — a whole file that says it is a partial
    // is not a backup.
    await container.commit(session.resumeToken);
    await container.rename(
      session.resumeToken,
      _path(session.name),
    );
    return RemoteBlob(
      name: session.name,
      bytes: session.totalBytes,
      modifiedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<Uint8List> download(String name, {int offset = 0, int? length}) =>
      container.readBytes(_path(name), offset: offset, length: length);

  @override
  Future<void> delete(String name) async {
    try {
      await container.delete(_path(name));
    } on TransferFailure {
      // Already gone.
    }
  }

  /// The retention pass must also sweep abandoned `.part` files: they are invisible
  /// to `list()` (so they can never be restored) but they do count against the
  /// user's iCloud quota, which is the one thing this layer must never quietly eat.
  Future<int> sweepPartials() async {
    final entries = await container.list(directory);
    var swept = 0;
    for (final entry in entries) {
      if (!entry.name.endsWith(partialSuffix)) continue;
      final ageMs = DateTime.now().millisecondsSinceEpoch - entry.modifiedAtMs;
      // A `.part` from the last few minutes is probably a live upload; an older one
      // is debris from a crash or a killed app.
      if (ageMs > const Duration(hours: 6).inMilliseconds) {
        try {
          await container.delete(entry.relativePath);
          swept += entry.bytes;
        } on TransferFailure {
          // Another sweep got there first.
        }
      }
    }
    return swept;
  }
}

/// A [UbiqContainer] over a plain directory: used by the harness, and by desktop
/// builds where iCloud does not exist but the file layout still has to work.
///
/// It implements the *staging* semantics too, in the simplest possible way: the
/// staging area is a sibling directory (`.staging`) to the container, so a test can
/// see committed and uncommitted files apart — which is exactly the property that
/// keeps a half-written pack out of a restore.
final class DirectoryUbiqContainer implements UbiqContainer {
  DirectoryUbiqContainer(this.root, {this.uploadedImmediately = true});

  final String root;
  final bool uploadedImmediately;

  @override
  Future<bool> isAvailable() async => Directory(root).existsSync();

  @override
  Future<List<UbiqEntry>> list(String relativeDirectory) async {
    final directory = Directory('$root/$relativeDirectory');
    if (!directory.existsSync()) return const [];
    final entries = <UbiqEntry>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final stat = entity.statSync();
      entries.add(
        UbiqEntry(
          // Relative to the container root, matching what the plugin-backed
          // container reports, so both implementations agree about paths.
          relativePath: '$relativeDirectory/${_basename(entity.path)}',
          bytes: stat.size,
          modifiedAtMs: stat.modified.millisecondsSinceEpoch,
          uploaded: uploadedImmediately,
        ),
      );
    }
    return entries;
  }

  @override
  Future<int> stagedBytes(String relativePath) async {
    final staged = _staged(relativePath);
    if (staged.existsSync()) return staged.statSync().size;
    // A file that was committed but never renamed still counts as resumable data:
    // the bytes are there, and pretending otherwise would re-upload 52 MB.
    final committed = _file(relativePath);
    return committed.existsSync() ? committed.statSync().size : 0;
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes, {bool append = false}) async {
    final file = _staged(relativePath);
    file.parent.createSync(recursive: true);
    if (append) {
      file.writeAsBytesSync(bytes, mode: FileMode.append, flush: true);
    } else {
      file.writeAsBytesSync(bytes, flush: true);
    }
  }

  @override
  Future<void> commit(String relativePath) async {
    final staged = _staged(relativePath);
    if (!staged.existsSync()) return;
    final destination = _file(relativePath);
    destination.parent.createSync(recursive: true);
    // Copy-then-delete, not rename: the platform containers are copy semantics (the
    // plugin copies the file into the ubiquity container), and a test that models
    // rename would pass while a real device's copy semantics were never exercised.
    staged.copySync(destination.path);
    staged.deleteSync();
  }

  @override
  Future<Uint8List> readBytes(String relativePath, {int? offset, int? length}) async {
    // Staged first: an upload in progress reads back its own bytes, exactly like the
    // plugin-backed container reads the local staging file before it is committed.
    final staged = _staged(relativePath);
    final file = staged.existsSync() ? staged : _file(relativePath);
    if (!file.existsSync()) {
      throw TransferFailure(
        kind: TransferFailureKind.permanent,
        message: '$relativePath is not in the container',
      );
    }
    final all = file.readAsBytesSync();
    final start = offset ?? 0;
    final end = length == null ? all.length : (start + length).clamp(0, all.length);
    return Uint8List.sublistView(all, start.clamp(0, all.length), end);
  }

  @override
  Future<void> delete(String relativePath) async {
    final staged = _staged(relativePath);
    if (staged.existsSync()) staged.deleteSync();
    final file = _file(relativePath);
    if (file.existsSync()) file.deleteSync();
  }

  @override
  Future<void> rename(String fromRelativePath, String toRelativePath) async {
    final source = _file(fromRelativePath);
    if (source.existsSync()) {
      final destination = _file(toRelativePath);
      destination.parent.createSync(recursive: true);
      source.renameSync(destination.path);
      return;
    }
    // Renaming something still staged is a legitimate sequence (commit, rename) that
    // a crash can interrupt; move the staged bytes so the retry is a no-op.
    _staged(fromRelativePath).renameSync(_staged(toRelativePath).path);
  }

  @override
  Future<int?> freeBytes() async => null;

  File _file(String relativePath) => File('$root/$relativePath');

  File _staged(String relativePath) => File('$root/.staging/$relativePath');

  static String _basename(String path) => path.split('/').last;
}

/// JSON sidecar for the pack header, so a restore can list packs and their roots
/// without downloading 52 MB to find out what is inside.
Uint8List encodePackSidecar(String name, String merkleRootB64, int totalBytes) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'pack': name,
          'merkle': merkleRootB64,
          'bytes': totalBytes,
          'app': 'KhataPro',
        }),
      ),
    );

String packSidecarName(String name) => '$name.json';

/// A tiny hash of the pack bytes for a "did the cloud mangle it" check that does
/// not need the pack key.
String quickDigest(Uint8List bytes) => '${sha256Hex(bytes).substring(0, 16)}/${bytes.length}';

// ── placeholder for the plugin-backed container ──────────────────────────────
//
// `IcloudPluginContainer` (which talks to package:icloud_storage) lives in
// `icloud_plugin_container.dart` so that *this* file stays importable by the
// verification harness, which has no Flutter.
