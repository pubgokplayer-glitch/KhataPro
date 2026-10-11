/// KhataPro · the `package:icloud_storage` implementation of [UbiqContainer].
///
/// This is the only file in the iCloud layer that imports Flutter, which is the
/// point: everything above it ([IcloudBlobStore], the resume logic, the sweep) is
/// plain Dart the harness runs against a temporary directory.
///
/// ## What the plugin actually offers, and what that forces
///
/// `icloud_storage` 2.2.0 is a **whole-file, relative-path, container** API — not a
/// directory you can do file I/O in:
///
///  * `gather(containerId:)` → `NSMetadataQuery` over the container, returning every
///    file with `relativePath` (which starts with `Documents/` on iOS),
///    `sizeInBytes`, `contentChangeDate`, `isUploaded`, `isUploading` and friends;
///  * `upload(filePath:, destinationRelativePath:)` → **copies** a local file into the
///    container and returns as soon as the *local* copy is made. The push to iCloud
///    continues in the background, which is why `isUploaded` has to be polled before
///    anything calls itself backed up;
///  * `download(relativePath:, destinationFilePath:)` → materialises a cloud file into
///    a local path of your choosing;
///  * `delete`, `move`, `rename`.
///
/// There is no container path to hand out, no append, and no partial upload. So:
///
///  * **staging is local.** Appended chunks accumulate in
///    `<app support>/icloud-staging/<logical path>`; [UbiqContainer.commit] is the
///    single upload of the finished file. A crash mid-transfer leaves that file
///    exactly as long as it got, and [UbiqContainer.stagedBytes] reads the resume
///    offset straight off its size.
///  * **reads go through a local cache.** A range read of a cloud file first
///    downloads it once into `<app support>/icloud-read/`, then `RandomAccessFile`
///    seeks. The resumable transfer reads sequentially, so this is one download per
///    pack, not one per chunk.
///  * **paths are mapped.** The store works in logical container paths
///    (`Backups/x.kpb1`); iOS container paths carry a `Documents/` prefix, so the
///    adapter adds it on the way out and strips it on the way in. The prefix is a
///    field because macOS containers do not always have it, and it is the one thing
///    here a wrong assumption would break loudly.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:icloud_storage/icloud_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../../sync/backup/resumable_transfer.dart';
import 'icloud_store.dart';

final class IcloudPluginContainer implements UbiqContainer {
  IcloudPluginContainer({
    required this.containerId,
    this.documentsPrefix = 'Documents',
  });

  /// `iCloud.<bundle-id>` from the app's entitlements. Must be non-empty: the plugin
  /// passes it to `FileManager.url(forUbiquityContainerIdentifier:)`, and an empty
  /// string is not "the first container" — it is a container that does not exist.
  final String containerId;

  /// The directory inside the container that iOS calls its Documents folder. Not a
  /// guess: `gather()` reports paths relative to the *container* root, so a file
  /// uploaded as `Backups/x.kpb1` comes back as `Documents/Backups/x.kpb1`.
  final String documentsPrefix;

  bool? _available;
  Directory? _stagingRoot;
  Directory? _readCacheRoot;

  @override
  Future<bool> isAvailable() async {
    if (_available == true) return true;
    try {
      await ICloudStorage.gather(containerId: containerId);
      // Cache the happy answer for the lifetime of this adapter: a metadata query is
      // not free, and "signed in to iCloud" is not a per-chunk question. A failure
      // anywhere below clears it, so a sign-out mid-session is noticed.
      _available = true;
      return true;
    } on PlatformException catch (error) {
      if (error.code == PlatformExceptionCode.iCloudConnectionOrPermission) {
        _available = false;
        return false;
      }
      rethrow;
    }
  }

  @override
  Future<List<UbiqEntry>> list(String relativeDirectory) async {
    final entries = await _gather();
    final prefix = _logical(relativeDirectory);
    final results = <UbiqEntry>[];
    for (final file in entries) {
      final logical = _stripPrefix(file.relativePath);
      // Direct children only: a nested file is not something [UbiqContainer.list]
      // promises, and the store's `sweepPartials` walks one directory.
      if (!logical.startsWith('$prefix/')) continue;
      final name = logical.substring(prefix.length + 1);
      if (name.contains('/')) continue;
      final modified = file.contentChangeDate.millisecondsSinceEpoch;
      results.add(
        UbiqEntry(
          relativePath: logical,
          bytes: file.sizeInBytes,
          modifiedAtMs: modified,
          // `isUploaded` is the only honest answer to "is this backed up". A file
          // that is merely *local* is not.
          uploaded: file.isUploaded && !file.isUploading,
        ),
      );
    }
    return results;
  }

  @override
  Future<int> stagedBytes(String relativePath) async {
    final staged = await _stagedFile(relativePath);
    return staged.existsSync() ? staged.statSync().size : 0;
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes, {bool append = false}) async {
    final staged = await _stagedFile(relativePath);
    staged.parent.createSync(recursive: true);
    await staged.writeAsBytes(bytes, mode: append ? FileMode.append : FileMode.write, flush: true);
  }

  @override
  Future<void> commit(String relativePath) async {
    final staged = await _stagedFile(relativePath);
    if (!staged.existsSync()) {
      throw TransferFailure(
        kind: TransferFailureKind.permanent,
        message: 'nothing staged at $relativePath to commit',
      );
    }
    try {
      await ICloudStorage.upload(
        containerId: containerId,
        filePath: staged.path,
        destinationRelativePath: _cloud(relativePath),
      );
    } on PlatformException catch (error) {
      // The staged file is deliberately left in place: the bytes are the resume
      // point, and throwing them away would mean re-uploading the whole pack.
      throw _transferFailure(error);
    }
    // The plugin copied (not moved) the file into the container, so the staging copy
    // is now a duplicate. Keeping it would double our disk usage and make
    // `stagedBytes` claim an upload was still in progress.
    staged.deleteSync();
  }

  @override
  Future<Uint8List> readBytes(String relativePath, {int? offset, int? length}) async {
    // Staged first: reading back an interrupted upload must not require it to be in
    // the cloud first.
    var local = await _stagedFile(relativePath);
    if (!local.existsSync()) {
      local = await _cachedCloudFile(relativePath);
    }
    final file = await local.open();
    try {
      final size = await file.length();
      final start = (offset ?? 0).clamp(0, size);
      final end = length == null ? size : (start + length).clamp(start, size);
      await file.setPosition(start);
      return await file.read(end - start);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> delete(String relativePath) async {
    final staged = await _stagedFile(relativePath);
    if (staged.existsSync()) staged.deleteSync();
    final cached = await _cachedCloudFile(relativePath);
    if (cached.existsSync()) cached.deleteSync();
    try {
      await ICloudStorage.delete(
        containerId: containerId,
        relativePath: _cloud(relativePath),
      );
    } on PlatformException catch (error) {
      // Already gone is not a failure: the sweep and a user-initiated delete race
      // each other by design.
      if (error.code != PlatformExceptionCode.fileNotFound) throw _transferFailure(error);
    }
  }

  @override
  Future<void> rename(String fromRelativePath, String toRelativePath) async {
    final staged = await _stagedFile(fromRelativePath);
    if (staged.existsSync()) {
      final destination = await _stagedFile(toRelativePath);
      destination.parent.createSync(recursive: true);
      staged.renameSync(destination.path);
      return;
    }
    try {
      await ICloudStorage.move(
        containerId: containerId,
        fromRelativePath: _cloud(fromRelativePath),
        toRelativePath: _cloud(toRelativePath),
      );
    } on PlatformException catch (error) {
      throw _transferFailure(error);
    }
  }

  @override
  Future<int?> freeBytes() async {
    // iOS does not expose iCloud quota to apps. Reporting a number here would be a
    // fabrication; the backup screen says "unknown" and a full account fails loudly
    // on the next upload instead.
    return null;
  }

  // ── internals ────────────────────────────────────────────────────────────

  Future<List<ICloudFile>> _gather() async {
    if (containerId.isEmpty) {
      throw const TransferFailure(
        kind: TransferFailureKind.permanent,
        message: 'no iCloud container id is configured for this build — see '
            'docs/PLATFORM_SETUP.md ("iCloud container")',
      );
    }
    try {
      return await ICloudStorage.gather(containerId: containerId);
    } on PlatformException catch (error) {
      _available = false;
      throw _transferFailure(error);
    }
  }

  Future<Directory> _stagingDirectory() async =>
      _stagingRoot ??= Directory('${(await getApplicationSupportDirectory()).path}/icloud-staging');

  Future<Directory> _readCacheDirectory() async =>
      _readCacheRoot ??= Directory('${(await getApplicationSupportDirectory()).path}/icloud-read');

  Future<File> _stagedFile(String relativePath) async =>
      File('${(await _stagingDirectory()).path}/$relativePath');

  /// A local copy of a committed cloud file, downloaded on first use.
  Future<File> _cachedCloudFile(String relativePath) async {
    final cached = File('${(await _readCacheDirectory()).path}/$relativePath');
    if (cached.existsSync()) return cached;
    cached.parent.createSync(recursive: true);
    try {
      await ICloudStorage.download(
        containerId: containerId,
        relativePath: _cloud(relativePath),
        destinationFilePath: cached.path,
      );
    } on PlatformException catch (error) {
      throw _transferFailure(error);
    }
    if (!cached.existsSync()) {
      throw TransferFailure(
        kind: TransferFailureKind.permanent,
        message: 'iCloud did not produce a local copy of $relativePath',
      );
    }
    return cached;
  }

  /// Logical path → iOS container path.
  String _cloud(String relativePath) => '$documentsPrefix/$relativePath';

  /// iOS container path → logical path.
  String _stripPrefix(String containerRelativePath) {
    final prefix = '$documentsPrefix/';
    return containerRelativePath.startsWith(prefix)
        ? containerRelativePath.substring(prefix.length)
        : containerRelativePath;
  }

  /// Callers may pass a directory with or without the container prefix; normalise.
  String _logical(String path) => _stripPrefix(path);

  /// One mapping for every plugin error, so the retry policy upstream stays simple:
  /// "iCloud is off" and "file is gone" are permanent (retrying a signed-out account
  /// forever is a battery bug), a full account is terminal for the session, and
  /// anything else native is transient because iCloud's own daemon is often the
  /// thing that is busy.
  TransferFailure _transferFailure(PlatformException error) {
    if (error.code == PlatformExceptionCode.iCloudConnectionOrPermission) {
      _available = false;
      return const TransferFailure(
        kind: TransferFailureKind.permanent,
        message: 'iCloud Drive is switched off, or this device is not signed in to '
            'an Apple Account with iCloud',
      );
    }
    if (error.code == PlatformExceptionCode.fileNotFound) {
      return const TransferFailure(
        kind: TransferFailureKind.permanent,
        message: 'that file is not in the iCloud container',
      );
    }
    final detail = '${error.message ?? ''}'.toLowerCase();
    if (detail.contains('space') || detail.contains('quota')) {
      return TransferFailure(
        kind: TransferFailureKind.quota,
        message: 'this Apple Account has no iCloud storage left (${error.message})',
      );
    }
    return TransferFailure(
      kind: TransferFailureKind.transient,
      message: 'iCloud reported a native error: ${error.message ?? error.code}',
    );
  }
}
