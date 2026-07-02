import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http_interceptor/http_interceptor.dart';

import 'package:mangayomi/models/video.dart';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/cloud_drive/cloud_drive_service.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_file.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_account.dart';
import 'package:mangayomi/services/cloud_drive/models/share_data.dart';
import 'package:mangayomi/services/cloud_drive/models/quality_option.dart';
import 'package:mangayomi/services/cloud_drive/auth/cookie_manager.dart';

/// Xunlei (迅雷网盘) cloud drive service.
///
/// Specialises in share URL access. Auth is cookie/token-based (Bearer JWT).
/// The full login flow involves captcha chains and device signing; this
/// simplified implementation focuses on share URL parsing, recursive file
/// listing, and video streaming via the share file_info endpoint.
///
/// Share URL format:
///   https://pan.xunlei.com/s/{shareId}?pwd=xxx
///
/// API bases:
///   - Auth:   https://xluser-ssl.xunlei.com/
///   - Drive:  https://api-pan.xunlei.com/
class XunleiDriveService implements CloudDriveService {
  // ── Constants ──────────────────────────────────────────────────────

  static const String _authBase = 'https://xluser-ssl.xunlei.com/';
  static const String _apiBase = 'https://api-pan.xunlei.com/';

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
      ' (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

  /// Client ID used for share / web API endpoints.
  static const String _webClientId = 'Xqp0kJBXWhwaTpB6';

  /// Fixed device ID used for share / web API captcha (matches xun.js).
  static const String _webDeviceId =
      '1bf91caf40093318e8040916eb7ad16a';

  /// Proxy base for video streaming URLs returned by the file_info endpoint.
  static const String _vodProxyBase =
      'https://web-vod-xdrive.xunlei.com/ts_downloader?url=';

  // ── State ──────────────────────────────────────────────────────────

  CloudDriveAccount _account = CloudDriveAccount(
    type: CloudDriveType.xunlei,
  );

  /// The `pass_code_token` obtained from `getShareList`, used for
  /// subsequent share detail / file_info requests.
  String? _passCodeToken;

  /// Xunlei user ID (decoded from JWT or stored after login).
  String? _userId;

  /// Cached result of the last `getShareList` call so we avoid a duplicate
  /// request when `getFilesByShareUrl` follows `getShareToken`.
  Map<String, dynamic>? _lastShareListResult;

  /// The share ID that `_lastShareListResult` and `_passCodeToken` belong to.
  String? _lastShareId;

  // ── Interface: getters ─────────────────────────────────────────────

  @override
  CloudDriveType get type => CloudDriveType.xunlei;

  @override
  CloudDriveAccount get account => _account;

  @override
  bool get isLoggedIn => _account.isLoggedIn;

  // ── Interface: lifecycle ───────────────────────────────────────────

  @override
  Future<void> initialize() async {
    final saved = await CloudCookieManager.getAccount(CloudDriveType.xunlei);
    if (saved != null) {
      _account = saved;
      // The username field doubles as user_id storage for xunlei
      _userId = saved.username;
    }
  }

  @override
  Future<bool> loginByCookie(String cookie) async {
    if (cookie.isEmpty) return false;

    // Accept as-is (Bearer {token}) or prepend Bearer.
    _account.token = cookie.startsWith('Bearer ') ? cookie : 'Bearer $cookie';
    _account.isLoggedIn = true;
    _account.lastLoginAt = DateTime.now();
    await CloudCookieManager.saveAccount(_account);

    return true;
  }

  @override
  Future<bool> loginByQR() async {
    throw UnimplementedError(
      'QR login is not yet supported for XunleiDrive.',
    );
  }

  @override
  Future<void> logout() async {
    _account = CloudDriveAccount(type: CloudDriveType.xunlei);
    _passCodeToken = null;
    _userId = null;
    _lastShareListResult = null;
    _lastShareId = null;

    await CloudCookieManager.clear(CloudDriveType.xunlei);
  }

  @override
  void dispose() {
    _passCodeToken = null;
    _lastShareListResult = null;
    _lastShareId = null;
  }

  // ── Interface: share parsing & token ───────────────────────────────

  @override
  ShareData? parseShareUrl(String url) {
    final regex = RegExp(r'https://pan\.xunlei\.com/s/([^?#]+)');
    final match = regex.firstMatch(url);
    if (match == null) return null;

    final shareId = match.group(1)!;
    final pwdMatch = RegExp(r'[?&]pwd=([^&]+)').firstMatch(url);

    return ShareData(
      shareId: shareId,
      sharePwd: pwdMatch?.group(1),
      folderId: '0',
    );
  }

  @override
  Future<bool> getShareToken(ShareData shareData) async {
    // The Xunlei share API has no separate token endpoint; the
    // pass_code_token is returned as part of getShareList. We validate
    // the share by calling it and caching the result.
    if (_passCodeToken != null && _lastShareId == shareData.shareId) {
      return true;
    }

    try {
      final result = await _getShareList(
        shareData.shareId,
        shareData.sharePwd ?? '',
      );
      if (result['pass_code_token'] != null) {
        _passCodeToken = result['pass_code_token'].toString();
        _lastShareListResult = result;
        _lastShareId = shareData.shareId;
        return true;
      }
    } catch (_) {
      // non-fatal; downstream callers handle empty results
    }
    return false;
  }

  // ── Interface: file listing ────────────────────────────────────────

  @override
  Future<List<CloudDriveFile>> getFilesByShareUrl(String url) async {
    final shareData = parseShareUrl(url);
    if (shareData == null) return [];

    final ok = await getShareToken(shareData);
    if (!ok) return [];

    final videos = <CloudDriveFile>[];

    await _listFilesRecursive(
      shareId: shareData.shareId,
      videos: videos,
      parentId: '',
    );

    return videos;
  }

  // ── Interface: save to drive ───────────────────────────────────────

  @override
  Future<String?> saveToDrive({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
    bool clean = false,
  }) async {
    throw UnsupportedError(
      'saveToDrive is not supported for XunleiDrive in simplified mode.',
    );
  }

  // ── Interface: transcoding / download ──────────────────────────────

  @override
  Future<List<QualityOption>> getLiveTranscoding({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
  }) async {
    // Maps to xun.js getShareUrl → GET /drive/v1/share/file_info
    final result = await _api(
      _apiBase,
      'drive/v1/share/file_info',
      null,
      'get',
      queryParams: {
        'pass_code_token': stoken,
        'file_id': fileId,
        'share_id': shareId,
        'space': '',
      },
    );

    if (result['file_info'] == null ||
        result['file_info']['medias'] == null) {
      return [];
    }

    final medias = result['file_info']['medias'] as List;
    return medias.map((m) {
      final media = m as Map<String, dynamic>;
      final link = media['link'] as Map<String, dynamic>?;
      if (link == null || link['url'] == null) return null;

      final rawUrl = link['url'].toString();
      final proxiedUrl = '$_vodProxyBase${Uri.encodeComponent(rawUrl)}';

      return QualityOption(
        url: proxiedUrl,
        quality: media['media_name']?.toString() ?? 'unknown',
      );
    }).whereType<QualityOption>().toList();
  }

  @override
  Future<Map<String, dynamic>?> getDownload({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
    bool clean = false,
  }) async {
    // Simplified: acquire the first streaming URL via file_info.
    final qualities = await getLiveTranscoding(
      shareId: shareId,
      stoken: stoken,
      fileId: fileId,
      fileToken: fileToken,
    );
    if (qualities.isEmpty) return null;

    return {'download_url': qualities.first.url};
  }

  // ── Interface: videos ──────────────────────────────────────────────

  @override
  Future<List<Video>> getVideos(String encodedUrl) async {
    // Format: [xunlei] displayName$xunlei++fileId++passCodeToken++shareId++stoken
    final parts = encodedUrl.split('++');
    if (parts.length < 5) return [];

    final fileId = parts[1];
    final passCodeToken = parts[2];
    final shareId = parts[3];

    final qualityOptions = await getLiveTranscoding(
      shareId: shareId,
      stoken: passCodeToken,
      fileId: fileId,
      fileToken: '',
    );

    if (qualityOptions.isEmpty) return [];

    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Referer': 'https://pan.xunlei.com/',
    };

    final originalUrl = qualityOptions.first.url;
    return qualityOptions.map((q) {
      return Video(
        q.url,
        q.quality,
        originalUrl,
        headers: Map<String, String>.from(headers),
      );
    }).toList();
  }

  // ── Interface: auth refresh ────────────────────────────────────────

  @override
  Future<bool> refreshAuth() async {
    // Simplified: just check whether a token is present.
    // A production implementation would decode the JWT, check `exp`, and
    // use the refresh_token to acquire a new access_token when expired.
    return _account.token != null && _account.token!.isNotEmpty;
  }

  // ── Internal: recursive file listing ───────────────────────────────

  /// Recursively list video files from a Xunlei share.
  ///
  /// At the root level ([parentId] is empty) uses the cached result from
  /// [getShareToken] to avoid a duplicate `getShareList` call.
  Future<void> _listFilesRecursive({
    required String shareId,
    required List<CloudDriveFile> videos,
    required String parentId,
  }) async {
    Map<String, dynamic> result;

    if (parentId.isEmpty) {
      // Use the cached share-list result from getShareToken.
      result = _lastShareListResult ??
          await _getShareList(shareId, '');
    } else {
      result = await _getShareDetail(shareId, parentId);
    }

    final files = result['files'] as List? ?? [];

    // Capture pass_code_token if not already known.
    if ((_passCodeToken == null || _passCodeToken!.isEmpty) &&
        result['pass_code_token'] != null) {
      _passCodeToken = result['pass_code_token'].toString();
    }

    final subDirs = <Map<String, dynamic>>[];

    for (final file in files) {
      final f = file as Map<String, dynamic>;
      final mimeType = f['mime_type']?.toString() ?? '';
      final fileCategory = f['file_category']?.toString() ?? '';

      // Directories have empty mime_type and are not VIDEO.
      final isDir = mimeType.isEmpty && fileCategory != 'VIDEO';

      if (isDir) {
        subDirs.add(f);
      } else if (fileCategory == 'VIDEO') {
        final size = f['size'] ?? 0;
        // Skip files smaller than 5 MB.
        if (size is int && size < 5 * 1024 * 1024) continue;

        videos.add(
          CloudDriveFile.fromJson(
            _normalizeFile(f),
            shareId,
            0,
            CloudDriveType.xunlei,
          ),
        );
      }
    }

    // Recurse into subdirectories.
    for (final dir in subDirs) {
      await _listFilesRecursive(
        shareId: shareId,
        videos: videos,
        parentId: dir['id']?.toString() ?? '',
      );
    }
  }

  /// Map a Xunlei API file object to the field names expected by
  /// [CloudDriveFile.fromJson] (`fid`, `file_name`, `obj_category`, etc.).
  Map<String, dynamic> _normalizeFile(Map<String, dynamic> item) {
    final fileCategory = item['file_category']?.toString() ?? '';
    final mimeType = item['mime_type']?.toString() ?? '';

    String objCategory;
    bool isDir;
    if (fileCategory == 'VIDEO') {
      objCategory = 'video';
      isDir = false;
    } else if (mimeType.isEmpty) {
      objCategory = 'dir';
      isDir = true;
    } else {
      objCategory = 'file';
      isDir = false;
    }

    return {
      'fid': item['id'],
      'file_name': item['name'],
      'size': item['size'],
      'obj_category': objCategory,
      'dir': isDir,
      'pdir_fid': item['parent_id'],
      if (_passCodeToken != null) 'share_fid_token': _passCodeToken,
    };
  }

  // ── Internal: share API helpers ────────────────────────────────────

  /// GET /drive/v1/share — retrieve the root file list and pass_code_token.
  Future<Map<String, dynamic>> _getShareList(
    String shareId,
    String passCode,
  ) async {
    return _api(
      _apiBase,
      'drive/v1/share',
      null,
      'get',
      queryParams: {
        'share_id': shareId,
        'pass_code': passCode,
        'limit': '200',
        'page_token': '',
        'thumbnail_size': 'SIZE_SMALL',
      },
    );
  }

  /// GET /drive/v1/share/detail — list files inside a subdirectory.
  Future<Map<String, dynamic>> _getShareDetail(
    String shareId,
    String parentId,
  ) async {
    return _api(
      _apiBase,
      'drive/v1/share/detail',
      null,
      'get',
      queryParams: {
        'share_id': shareId,
        'parent_id': parentId,
        'pass_code_token': _passCodeToken ?? '',
        'limit': '200',
        'page_token': '',
        'thumbnail_size': 'SIZE_SMALL',
      },
    );
  }

  // ── Internal: captcha ──────────────────────────────────────────────

  /// Dynamically compute a captcha sign using SHA256 with a salt selected
  /// from the key array based on [userId] (mirrors `get_Captcha_Sign` in
  /// xun.js).
  String _getCaptchaSign(String userId) {
    final keys = <String>[
      'DPdLBvYvRkKewl6IvQTSKSV6ws7F9',
      '4ZnspAqakTEcghWtF9FRnZqtpxuACpAJq3jbiH',
      'GZ4iB0a30T1',
      'EjNYWJI/CQV4ovf',
      '042FPU6qgf94gDnNVeepvXIUZpOj7lltfg/I3T0wfbHKJPetx',
      'QFhWvh91aKcN3CvJUQ40HPxo',
      'jRxFmAZeiqg1Y',
      'qXF8/KOCx4/dTuz',
      'CMjDD2dxuV9touYldY2URt4vA7z47v1FcZ3k7DAr',
      'wN0P2x+N4BYQDS1fd',
    ];
    final uid = userId.isEmpty ? '0' : userId;
    final salt = keys[int.parse(uid) % keys.length];
    return sha256.convert(utf8.encode('$salt$uid')).toString();
  }

  /// Acquire a captcha token from the Xunlei shield service.
  ///
  /// Mirrors the `getCaptcha_token` function from xun.js. The
  /// `captcha_sign` field is dynamically computed via `_getCaptchaSign`.
  Future<String?> _getCaptchaToken({
    String action = 'get:/drive/v1/share',
  }) async {
    try {
      final client = MClient.init(
        reqcopyWith: {'useDartHttpClient': true},
      );

      final resp = await client.post(
        Uri.parse('${_authBase}v1/shield/captcha/init'),
        body: jsonEncode({
          'client_id': _webClientId,
          'action': action,
          'device_id': _webDeviceId,
          'captcha_token': '',
          'meta': {
            'username': '',
            'phone_number': '',
            'email': '',
            'package_name': 'pan.xunlei.com',
            'client_version': '1.92.9',
            'captcha_sign': '1.${_getCaptchaSign(_userId ?? '')}',
            'timestamp':
                DateTime.now().millisecondsSinceEpoch.toString(),
            'user_id': _userId ?? '',
          },
        }),
        headers: {
          'User-Agent': _userAgent,
          'Content-Type': 'application/json',
        },
      );

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        return body['captcha_token']?.toString();
      }
    } catch (_) {
      // Captcha failure is non-fatal; the request may still succeed
      // without a token or can be retried.
    }
    return null;
  }

  // ── Internal: HTTP client ──────────────────────────────────────────

  /// Make an API request to the Xunlei backend.
  ///
  /// Tries the request without a captcha token first; if the server responds
  /// with 403, a captcha token is acquired and the request is retried.
  Future<Map<String, dynamic>> _api(
    String baseUrl,
    String path,
    dynamic data,
    String method, {
    Map<String, String>? queryParams,
  }) async {
    final client = MClient.init(
      reqcopyWith: {'useDartHttpClient': true},
    );

    var uri = Uri.parse('$baseUrl$path');
    if (queryParams != null && queryParams.isNotEmpty) {
      uri = uri.replace(queryParameters: queryParams);
    }

    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Content-Type': 'application/json',
      'x-client-id': _webClientId,
      'x-device-id': _webDeviceId,
    };

    late Response resp;

    // First attempt without captcha.
    if (method != 'get') {
      resp = await client.post(
        uri,
        body: data != null ? jsonEncode(data) : null,
        headers: headers,
      );
    } else {
      resp = await client.get(
        uri,
        headers: headers,
      );
    }

    // If the server demands a captcha (403), fetch one and retry.
    if (resp.statusCode == 403) {
      final httpMethod = method == 'post' ? 'POST' : 'GET';
      final captchaToken = await _getCaptchaToken(
        action: '$httpMethod:/$path',
      );
      if (captchaToken != null && captchaToken.isNotEmpty) {
        headers['x-captcha-token'] = captchaToken;

        if (method != 'get') {
          resp = await client.post(
            uri,
            body: data != null ? jsonEncode(data) : null,
            headers: headers,
          );
        } else {
          resp = await client.get(
            uri,
            headers: headers,
          );
        }
      }
    }

    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
