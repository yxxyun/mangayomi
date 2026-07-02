import 'package:mangayomi/models/video.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_file.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_account.dart';
import 'package:mangayomi/services/cloud_drive/models/share_data.dart';
import 'package:mangayomi/services/cloud_drive/models/quality_option.dart';

abstract class CloudDriveService {
  CloudDriveType get type;
  CloudDriveAccount get account;

  bool get isLoggedIn;

  Future<void> initialize();

  Future<bool> loginByCookie(String cookie);

  /// WebView-based QR login
  Future<bool> loginByQR();

  Future<void> logout();

  /// Parse a share URL (e.g. https://pan.quark.cn/s/abc123)
  ShareData? parseShareUrl(String url);

  /// Get auth token for a share
  Future<bool> getShareToken(ShareData shareData);

  /// List all video files from a share URL
  Future<List<CloudDriveFile>> getFilesByShareUrl(String url);

  /// Save a file to personal drive
  /// (needed for transcoding/download on some platforms)
  Future<String?> saveToDrive({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
    bool clean = false,
  });

  /// Get transcoded video play info (multiple resolutions)
  Future<List<QualityOption>> getLiveTranscoding({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
  });

  /// Get download URL for a file
  Future<Map<String, dynamic>?> getDownload({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
    bool clean = false,
  });

  /// Get video play info (returns List<Video> for player)
  Future<List<Video>> getVideos(String encodedUrl);

  /// Refresh cookie/token if expired
  Future<bool> refreshAuth();

  /// Clean up resources
  void dispose();
}
