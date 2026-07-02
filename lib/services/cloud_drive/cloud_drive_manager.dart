import 'package:mangayomi/services/cloud_drive/cloud_drive_service.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_file.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';

/// Singleton central manager for all cloud drive services.
///
/// Acts as the registry (barrel export) for all [CloudDriveService]
/// implementations. Use [CloudDriveManager.instance] to access the
/// global instance.
///
/// Example:
/// ```dart
/// final manager = CloudDriveManager.instance;
/// final service = manager.get(CloudDriveType.quark);
/// final files = await manager.getFilesFromUrl('https://pan.quark.cn/s/abc123');
/// ```
class CloudDriveManager {
  CloudDriveManager._();

  static final CloudDriveManager _instance = CloudDriveManager._();

  /// Global singleton instance.
  static CloudDriveManager get instance => _instance;

  final Map<CloudDriveType, CloudDriveService> _services = {};

  /// Register a [CloudDriveService] implementation.
  ///
  /// Only one service per [CloudDriveType] is allowed; registering a
  /// second service for the same type silently replaces the previous one.
  void register(CloudDriveService service) {
    _services[service.type] = service;
  }

  /// Retrieve a registered service by [type], or `null` if not registered.
  CloudDriveService? get(CloudDriveType type) => _services[type];

  /// Unregister the service for [type], if any.
  void unregister(CloudDriveType type) {
    _services.remove(type);
  }

  /// List of all registered services.
  List<CloudDriveService> get all => _services.values.toList();

  /// List of all registered [CloudDriveType] values.
  List<CloudDriveType> get registeredTypes => _services.keys.toList();

  /// Initialize every registered service.
  ///
  /// Calls [CloudDriveService.initialize] on each service. Errors from
  /// individual services are caught and logged so a single failure does
  /// not prevent the remaining services from initialising.
  Future<void> initializeAll() async {
    for (final service in _services.values) {
      try {
        await service.initialize();
      } catch (e) {
        // Log but continue – one failing init should not block others.
        // ignore: avoid_print
        print('CloudDriveManager: failed to initialize ${service.type.key}: $e');
      }
    }
  }

  /// ---------- URL detection ----------

  /// Auto-detect [CloudDriveType] from a share [url].
  ///
  /// Matching is done by checking known domain patterns:
  /// - quark:  `pan.quark.cn/s/`
  /// - uc:     `drive.uc.cn/s/`
  /// - ali:    `aliyundrive.com/s/` or `alipan.com/s/`
  /// - baidu:  `pan.baidu.com/s/`
  /// - pan123: `123684.com`, `123pan.com`, `123pan.cn`
  /// - cloud189: `cloud.189.cn`
  /// - yun139: `yun.139.com`
  /// - xunlei: `pan.xunlei.com`
  static CloudDriveType? detectType(String url) {
    final lower = url.toLowerCase();

    if (lower.contains('pan.quark.cn/s/')) return CloudDriveType.quark;
    if (lower.contains('drive.uc.cn/s/')) return CloudDriveType.uc;
    if (lower.contains('aliyundrive.com/s/') ||
        lower.contains('alipan.com/s/')) {
      return CloudDriveType.ali;
    }
    if (lower.contains('pan.baidu.com/s/')) return CloudDriveType.baidu;
    if (lower.contains('123684.com') ||
        lower.contains('123865.com') ||
        lower.contains('123912.com') ||
        lower.contains('123pan.com') ||
        lower.contains('123pan.cn') ||
        lower.contains('123592.com')) {
      return CloudDriveType.pan123;
    }
    if (lower.contains('cloud.189.cn')) return CloudDriveType.cloud189;
    if (lower.contains('yun.139.com')) return CloudDriveType.yun139;
    if (lower.contains('pan.xunlei.com')) return CloudDriveType.xunlei;

    return null;
  }

  /// ---------- High-level operations ----------

  /// Find the right service for [url] and return its files.
  ///
  /// 1. Detects the drive type from [url] using [detectType].
  /// 2. Looks up the registered service.
  /// 3. Calls [CloudDriveService.getFilesByShareUrl] if the service is
  ///    registered.
  ///
  /// Returns an empty list when the type cannot be detected or no service
  /// is registered.
  Future<List<CloudDriveFile>> getFilesFromUrl(String url) async {
    final type = detectType(url);
    if (type == null) return [];
    final service = get(type);
    if (service == null) return [];
    return service.getFilesByShareUrl(url);
  }

  /// Login for [type] using a cookie string.
  ///
  /// Delegates to [CloudDriveService.loginByCookie] if the service is
  /// registered. Returns `false` if the service is not found.
  Future<bool> loginByCookie(CloudDriveType type, String cookie) async {
    final service = get(type);
    if (service == null) return false;
    return service.loginByCookie(cookie);
  }

  /// Logout from [type].
  ///
  /// Delegates to [CloudDriveService.logout] if the service is registered.
  Future<void> logout(CloudDriveType type) async {
    final service = get(type);
    await service?.logout();
  }

  /// Returns `true` if [type] has a registered service that is logged in.
  bool isLoggedIn(CloudDriveType type) {
    return get(type)?.isLoggedIn ?? false;
  }

  /// Dispose all registered services.
  Future<void> disposeAll() async {
    for (final service in _services.values) {
      try {
        service.dispose();
      } catch (_) {
        // Best-effort cleanup.
      }
    }
    _services.clear();
  }
}
