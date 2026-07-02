import 'dart:math';

import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';

class CloudDriveFile {
  final String fileId;
  final String name;
  final String? size;
  final String? shareId;
  final String? shareToken;
  final String? shareFileToken;
  final String? parent;
  final bool isDir;
  /// Subtitle file ID for LCS-matched subtitle, encoded into [getEpisodeUrl].
  String? subtitleUrl;
  final int shareIndex;
  final CloudDriveType driveType;

  CloudDriveFile({
    required this.fileId,
    required this.name,
    this.size,
    this.shareId,
    this.shareToken,
    this.shareFileToken,
    this.parent,
    this.isDir = false,
    this.subtitleUrl,
    this.shareIndex = 0,
    required this.driveType,
  });

  factory CloudDriveFile.fromJson(
    Map<String, dynamic> json,
    String shareId,
    int shareIndex,
    CloudDriveType driveType,
  ) {
    return CloudDriveFile(
      fileId: json['fid']?.toString() ?? '',
      name: json['file_name']?.toString() ?? '',
      size: (json['size'] ?? 0).toString(),
      shareId: shareId,
      shareToken: json['stoken']?.toString(),
      shareFileToken: json['share_fid_token']?.toString(),
      parent: json['pdir_fid']?.toString(),
      isDir: json['obj_category']?.toString() == 'dir' ||
          (json['dir'] ?? false) == true,
      subtitleUrl: json['subtitle_url']?.toString(),
      shareIndex: shareIndex,
      driveType: driveType,
    );
  }

  String getDisplayName(String typeName) {
    final drivePrefix = '[${driveType.key}]';
    var displayName = name;
    if (typeName == '电视剧') {
      displayName = displayName.replaceAll('.${_getFileExtension()}', '');
      displayName = displayName.replaceAll(' ', '').replaceAll(' ', '');
      final replaceNameList = ['4k', '4K'];
      for (final r in replaceNameList) {
        displayName = displayName.replaceAll(r, '');
      }
      displayName = RegExp(r'\.S01E(.*?)\.')
              .firstMatch(displayName)
              ?.group(1) ??
          displayName;
      final numbers =
          RegExp(r'\d+').allMatches(displayName).map((m) => m.group(0)).toList();
      if (numbers.isNotEmpty) {
        displayName = numbers[0]!;
      }
    }
    final sizeStr = size == null || size == '0'
        ? ''
        : '[${getHumanReadableSize(int.parse(size!))}]';
    return '$drivePrefix $displayName $sizeStr';
  }

  String getEpisodeUrl(String typeName) {
    var url = '${getDisplayName(typeName)}\$${driveType.key}++$fileId++${shareFileToken ?? ''}++$shareId++${shareToken ?? ''}';
    // Append subtitle info if available — use ++ separator so it
    // becomes a distinct part when the URL is split on '++'.
    if (subtitleUrl != null && subtitleUrl!.isNotEmpty) {
      url = '$url++$subtitleUrl';
    }
    return url;
  }

  String _getFileExtension() {
    final parts = name.split('.');
    return parts.length > 1 ? parts.last : '';
  }

  static String getHumanReadableSize(int bytes) {
    if (bytes <= 0) return '';
    final units = ['B', 'KB', 'MB', 'GB', 'TB'];
    final digitGroups = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, digitGroups)).toStringAsFixed(2)} ${units[digitGroups]}';
  }
}
