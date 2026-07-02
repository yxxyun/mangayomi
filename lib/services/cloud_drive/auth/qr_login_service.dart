import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';

/// URL endpoints for QR-code-based login flows on supported cloud drive
/// platforms.
///
/// Each platform has a [generateUrl] that returns the QR challenge data,
/// and a [pollUrl] that is polled to detect when the user has scanned
/// the QR code.
class QrLoginUrls {
  /// Map of known QR login endpoints per [CloudDriveType].
  ///
  /// Platforms without public QR endpoints (pan123, cloud189, yun139, xunlei)
  /// use their mobile-web login page as a fallback; the actual QR flow is
  /// handled by the WebView UI layer.
  static const Map<CloudDriveType, QrEndpoint> endpoints = {
    CloudDriveType.quark: QrEndpoint(
      generateUrl: 'https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin',
      pollUrl: 'https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin',
      method: 'getTokenForQrcodeLogin',
    ),
    CloudDriveType.uc: QrEndpoint(
      generateUrl: 'https://uop.uc.cn/cas/ajax/getTokenForQrcodeLogin',
      pollUrl: 'https://uop.uc.cn/cas/ajax/getTokenForQrcodeLogin',
      method: 'getTokenForQrcodeLogin',
    ),
    CloudDriveType.ali: QrEndpoint(
      generateUrl: 'https://auth.alipan.com/v2/oauth/authorize/qrcode',
      pollUrl: 'https://auth.alipan.com/v2/oauth/authorize/qrcode/scan',
      method: 'qrcode',
    ),
    CloudDriveType.baidu: QrEndpoint(
      generateUrl: 'https://pan.baidu.com/api/getqrcode',
      pollUrl: 'https://pan.baidu.com/api/qrscan',
      method: 'qrcode',
    ),
    // 123 Cloud — no public QR endpoint; uses password + SMS login
    CloudDriveType.pan123: QrEndpoint(
      generateUrl: 'https://www.123684.com/api/v2/login',
      pollUrl: 'https://www.123684.com/api/v2/login/check',
      method: 'login',
    ),
    // Tianyi Cloud 189 — no public QR endpoint
    CloudDriveType.cloud189: QrEndpoint(
      generateUrl: 'https://cloud.189.cn/api/portal/loginUrl.action',
      pollUrl: 'https://cloud.189.cn/api/portal/getLoginStatus.action',
      method: 'login',
    ),
    // 139 Cloud — no public QR endpoint
    CloudDriveType.yun139: QrEndpoint(
      generateUrl: 'https://yun.139.com/api/oauth/v1/qrcode',
      pollUrl: 'https://yun.139.com/api/oauth/v1/qrcode/check',
      method: 'qrcode',
    ),
    // Xunlei — uses WebView page login
    CloudDriveType.xunlei: QrEndpoint(
      generateUrl: 'https://pan.xunlei.com/api/v1/qrcode',
      pollUrl: 'https://pan.xunlei.com/api/v1/qrcode/check',
      method: 'qrcode',
    ),
  };

  /// Get the QR endpoint configuration for [type], or `null` if unknown.
  static QrEndpoint? forType(CloudDriveType type) => endpoints[type];
}

/// QR login endpoint configuration for a single cloud drive platform.
class QrEndpoint {
  /// URL that generates the QR code challenge.
  final String generateUrl;

  /// URL polled to check whether the QR code has been scanned and confirmed.
  final String pollUrl;

  /// The API method / action name used by the platform (for logging/metrics).
  final String method;

  const QrEndpoint({
    required this.generateUrl,
    required this.pollUrl,
    required this.method,
  });
}

/// High-level QR login service.
///
/// Provides the login flow definition. The actual WebView rendering and
/// polling loop lives in the UI layer ([QrLoginScreen] or similar),
/// because it requires a [BuildContext] and native WebView integration.
///
/// Usage:
/// ```dart
/// final endpoint = QrLoginUrls.forType(CloudDriveType.quark);
/// // Open generateUrl in a WebView, poll pollUrl, extract cookie on success.
/// ```
class QrLoginService {
  /// Returns the login page URL for [type].
  ///
  /// For platforms that support QR-code login, this is the URL that shows
  /// the QR code. For others it may be a regular login page that the user
  /// fills in manually inside a WebView.
  static String? getLoginUrl(CloudDriveType type) {
    return QrLoginUrls.forType(type)?.generateUrl;
  }

  /// Returns the URL to poll for QR scan status.
  static String? getPollUrl(CloudDriveType type) {
    return QrLoginUrls.forType(type)?.pollUrl;
  }

  /// Returns `true` if the platform has a known QR login endpoint.
  static bool supportsQrLogin(CloudDriveType type) {
    final endpoint = QrLoginUrls.forType(type);
    if (endpoint == null) return false;
    return endpoint.method == 'qrcode';
  }
}
