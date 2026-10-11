/// Analyzer stub for `package:icloud_storage` 2.2.0. Signatures only — never run.
///
/// The shape of the real API is what forced the iCloud adapter's design: whole-file
/// operations on relative paths, no container path, and `upload` returning before the
/// file reaches iCloud.
library;

typedef StreamHandler<T> = void Function(Stream<T>);

enum DownloadStatus { notDownloaded, downloaded, current }

class ICloudFile {
  ICloudFile.fromMap(Map<dynamic, dynamic> map)
      : relativePath = map['relativePath'] as String,
        sizeInBytes = (map['sizeInBytes'] as num?)?.toInt() ?? 0,
        creationDate = DateTime.fromMillisecondsSinceEpoch(
            ((map['creationDate'] as num?)?.toDouble() ?? 0 * 1000).round()),
        contentChangeDate = DateTime.fromMillisecondsSinceEpoch(
            ((map['contentChangeDate'] as num?)?.toDouble() ?? 0 * 1000).round()),
        isDownloading = map['isDownloading'] as bool? ?? false,
        downloadStatus = DownloadStatus.current,
        isUploading = map['isUploading'] as bool? ?? false,
        isUploaded = map['isUploaded'] as bool? ?? false,
        hasUnresolvedConflicts = map['hasUnresolvedConflicts'] as bool? ?? false;

  final String relativePath;
  final int sizeInBytes;
  final DateTime creationDate;
  final DateTime contentChangeDate;
  final bool isDownloading;
  final DownloadStatus downloadStatus;
  final bool isUploading;
  final bool isUploaded;
  final bool hasUnresolvedConflicts;
}

abstract final class PlatformExceptionCode {
  static const String iCloudConnectionOrPermission = 'E_CTR';
  static const String fileNotFound = 'E_FNF';
  static const String nativeCodeError = 'E_NAT';
}

class InvalidArgumentException implements Exception {
  InvalidArgumentException(this.message);

  final String message;
}

class ICloudStorage {
  static Future<List<ICloudFile>> gather({
    required String containerId,
    StreamHandler<List<ICloudFile>>? onUpdate,
  }) =>
      throw UnimplementedError('stub');

  static Future<void> upload({
    required String containerId,
    required String filePath,
    String? destinationRelativePath,
    StreamHandler<double>? onProgress,
  }) =>
      throw UnimplementedError('stub');

  static Future<void> download({
    required String containerId,
    required String relativePath,
    required String destinationFilePath,
    StreamHandler<double>? onProgress,
  }) =>
      throw UnimplementedError('stub');

  static Future<void> delete({
    required String containerId,
    required String relativePath,
  }) =>
      throw UnimplementedError('stub');

  static Future<void> move({
    required String containerId,
    required String fromRelativePath,
    required String toRelativePath,
  }) =>
      throw UnimplementedError('stub');

  static Future<void> rename({
    required String containerId,
    required String relativePath,
    required String newName,
  }) =>
      throw UnimplementedError('stub');
}
