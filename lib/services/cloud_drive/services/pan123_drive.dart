import 'dart:convert';

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

/// 123云盘 (Pan123) cloud drive service.
///
/// Auth: Bearer token obtained via passport/password login.
/// Share URLs use one of four supported domains:
///   www.123684.com, www.123865.com, www.123912.com, www.123pan.com,
///   www.123pan.cn, www.123592.com
/// Share URL format: https://www.123684.com/s/{shareKey}
///
/// Download and live-transcoding endpoints require the Bearer token;
/// share listing does not.
class Pan123DriveService implements CloudDriveService {
  // ── Constants ──────────────────────────────────────────────────────

  static const String _apiBase = 'https://www.123684.com/b/api/share/';
  static const String _loginUrl = 'https://login.123pan.com/api/user/sign_in';
  static const String _videoPlayInfoUrl =
      'https://www.123684.com/b/api/video/play/info';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
  static const String _refererUrl = 'https://www.123684.com/';

  /// All six domains accepted by the Pan123 share URL parser.
  static final RegExp _shareUrlRegex = RegExp(
    r'https://(www\.123684\.com|www\.123865\.com|www\.123912\.com|'
    r'www\.123pan\.com|www\.123pan\.cn|www\.123592\.com)/s/([^/?]+)',
  );

  // ── State ──────────────────────────────────────────────────────────

  CloudDriveAccount _account = CloudDriveAccount(
    type: CloudDriveType.pan123,
  );

  /// Cache of share passwords keyed by shareKey.
  ///
  /// Populated during `getShareToken` and consumed by subsequent
  /// `getLiveTranscoding` / `getDownload` calls.
  final Map<String, String> _sharePwdByShareKey = {};

  // ── Interface: getters ─────────────────────────────────────────────

  @override
  CloudDriveType get type => CloudDriveType.pan123;

  @override
  CloudDriveAccount get account => _account;

  @override
  bool get isLoggedIn => _account.isLoggedIn;

  // ── Interface: lifecycle ───────────────────────────────────────────

  @override
  Future<void> initialize() async {
    final saved = await CloudCookieManager.getAccount(CloudDriveType.pan123);
    if (saved != null) {
      _account = saved;
    }
  }

  @override
  Future<bool> loginByCookie(String cookie) async {
    if (cookie.isEmpty) return false;

    // For Pan123 the "cookie" is actually a Bearer token.
    _account.token = cookie;
    _account.isLoggedIn = true;
    _account.lastLoginAt = DateTime.now();
    await CloudCookieManager.saveAccount(_account);
    return true;
  }

  @override
  Future<bool> loginByQR() async {
    throw UnimplementedError(
      'QR login is not yet supported for Pan123Drive.',
    );
  }

  @override
  Future<void> logout() async {
    _account = CloudDriveAccount(type: CloudDriveType.pan123);
    _sharePwdByShareKey.clear();
    await CloudCookieManager.clear(CloudDriveType.pan123);
  }

  @override
  void dispose() {
    _sharePwdByShareKey.clear();
  }

  // ── Interface: share parsing & token ───────────────────────────────

  @override
  ShareData? parseShareUrl(String url) {
    // Strip backticks (common in copy-pasted text).
    url = url.replaceAll('`', '');

    final match = _shareUrlRegex.firstMatch(url);
    if (match == null) return null;

    final shareKey = match.group(2)!;

    // Extract optional share password from query string.
    String? sharePwd;
    final uri = Uri.tryParse(url);
    if (uri != null && uri.queryParameters.isNotEmpty) {
      sharePwd = uri.queryParameters['pwd'];
    }

    return ShareData(
      shareId: shareKey,
      sharePwd: sharePwd,
      folderId: '0',
    );
  }

  @override
  Future<bool> getShareToken(ShareData shareData) async {
    // Validate share access and cache the share password.
    try {
      final result = await _api(
        'get_share_info',
        {
          'ShareKey': shareData.shareId,
          'SharePwd': shareData.sharePwd ?? '',
        },
        'post',
      );

      if (result['code'] == 0 && result['data'] != null) {
        _sharePwdByShareKey[shareData.shareId] = shareData.sharePwd ?? '';
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
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
      shareKey: shareData.shareId,
      sharePwd: _sharePwdByShareKey[shareData.shareId] ?? '',
      videos: videos,
      parentFileId: 0,
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
    // 123云盘 does not require saving to personal drive for playback.
    throw UnsupportedError('Pan123Drive does not support saveToDrive.');
  }

  // ── Interface: transcoding / download ──────────────────────────────

  @override
  Future<List<QualityOption>> getLiveTranscoding({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
  }) async {
    // fileToken carries the per-file extras as a JSON string:
    // {"s3KeyFlag":"...", "size":N, "etag":"..."}
    Map<String, dynamic> extra;
    try {
      extra = jsonDecode(fileToken) as Map<String, dynamic>;
    } catch (_) {
      return [];
    }

    final s3KeyFlag = extra['s3KeyFlag']?.toString() ?? '';
    final size = extra['size'] ?? 0;
    final etag = extra['etag']?.toString() ?? '';
    final sharePwd = _sharePwdByShareKey[shareId] ?? '';

    final videos = <QualityOption>[];

    // Try get_share_download_info (returns VideoInfoList with resolutions).
    try {
      final result = await _api(
        'get_share_download_info',
        {
          'ShareKey': shareId,
          'SharePwd': sharePwd,
          'FileId': fileId,
          'S3KeyFlag': s3KeyFlag,
          'Size': size,
          'Etag': etag,
        },
        'post',
      );

      if (result['code'] == 0 &&
          result['data'] != null &&
          result['data']['VideoInfoList'] != null) {
        final videoInfoList = result['data']['VideoInfoList'] as List;
        for (final v in videoInfoList) {
          final info = v as Map<String, dynamic>;
          final url = info['Url']?.toString() ?? '';
          final resolution = info['Resolution']?.toString() ?? '';
          if (url.isNotEmpty) {
            videos.add(QualityOption(url: url, quality: resolution));
          }
        }
        if (videos.isNotEmpty) return videos;
      }
    } catch (_) {
      // Fall through to alternative endpoint.
    }

    // Fallback: video/play/info endpoint (from pan123.js reference).
    try {
      await _ensureAuth();
      final result = await _apiGet(
        _videoPlayInfoUrl,
        {
          'etag': etag,
          'size': size.toString(),
          'from': '1',
          'shareKey': shareId,
        },
      );

      final data = result['data'];
      if (data != null && data['video_play_info'] != null) {
        final playInfoList = data['video_play_info'] as List;
        for (final v in playInfoList) {
          final info = v as Map<String, dynamic>;
          final url = info['url']?.toString() ?? '';
          final resolution = info['resolution']?.toString() ?? '';
          if (url.isNotEmpty) {
            videos.add(QualityOption(url: url, quality: resolution));
          }
        }
      }
    } catch (_) {
      // Fall through — return whatever we have (possibly empty).
    }

    return videos;
  }

  @override
  Future<Map<String, dynamic>?> getDownload({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
    bool clean = false,
  }) async {
    // fileToken carries the per-file extras as a JSON string.
    Map<String, dynamic> extra;
    try {
      extra = jsonDecode(fileToken) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }

    final s3KeyFlag = extra['s3KeyFlag']?.toString() ?? '';
    final size = extra['size'] ?? 0;
    final etag = extra['etag']?.toString() ?? '';

    try {
      await _ensureAuth();

      final result = await _api(
        'download/info',
        {
          'ShareKey': shareId,
          'FileID': fileId,
          'S3KeyFlag': s3KeyFlag,
          'Size': size,
          'Etag': etag,
        },
        'post',
        useAuth: true,
      );

      if (result['code'] == 0 &&
          result['data'] != null &&
          result['data']['DownloadURL'] != null) {
        final downloadUrl = result['data']['DownloadURL'].toString();

        // The DownloadURL may contain a 'params' query parameter whose
        // value is a base64-encoded real download URL.
        final uri = Uri.tryParse(downloadUrl);
        if (uri != null) {
          final params = uri.queryParameters['params'];
          if (params != null && params.isNotEmpty) {
            try {
              final decoded = utf8.decode(base64Decode(params));
              return {'download_url': decoded};
            } catch (_) {
              // Fall through to return the original DownloadURL.
            }
          }
        }

        return {'download_url': downloadUrl};
      }
    } catch (_) {
      // Fall through.
    }

    return null;
  }

  // ── Interface: videos ──────────────────────────────────────────────

  @override
  Future<List<Video>> getVideos(String encodedUrl) async {
    // Encoded URL format:
    //   [pan123] displayName$pan123++fileId++fileTokenJSON++shareKey++
    //
    // Where fileTokenJSON = {"s3KeyFlag":"...", "size":N, "etag":"..."}
    final parts = encodedUrl.split('++');
    if (parts.length < 4) return [];

    final fileId = parts[1];
    final fileToken = parts[2];
    final shareKey = parts[3];

    final videos = <Video>[];

    // Try live transcoding first.
    final qualityOptions = await getLiveTranscoding(
      shareId: shareKey,
      stoken: '',
      fileId: fileId,
      fileToken: fileToken,
    );

    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Referer': _refererUrl,
    };

    if (qualityOptions.isNotEmpty) {
      final originalUrl = qualityOptions.first.url;

      for (final q in qualityOptions) {
        videos.add(Video(
          q.url,
          q.quality,
          originalUrl,
          headers: Map<String, String>.from(headers),
        ));
      }
    } else {
      // Fallback: direct download URL.
      final dlResult = await getDownload(
        shareId: shareKey,
        stoken: '',
        fileId: fileId,
        fileToken: fileToken,
      );
      if (dlResult != null && dlResult['download_url'] != null) {
        final url = dlResult['download_url'].toString();
        videos.add(Video(
          url,
          'original',
          url,
          headers: Map<String, String>.from(headers),
        ));
      }
    }

    return videos;
  }

  // ── Interface: auth refresh ────────────────────────────────────────

  @override
  Future<bool> refreshAuth() async {
    if (_account.username != null && _account.password != null) {
      return _loginWithCredentials();
    }
    // Token-based auth: just verify token exists
    return _account.token != null && _account.token!.isNotEmpty;
  }

  // ── Internal: auth ─────────────────────────────────────────────────

  /// Ensure a valid Bearer token is available; re-login if needed.
  Future<void> _ensureAuth() async {
    if (!isLoggedIn || (_account.token ?? '').isEmpty) {
      await _loginWithCredentials();
    }
  }

  /// Login to 123云盘 using stored passport/password credentials.
  ///
  /// On success, stores the Bearer token in `_account.token` and persists.
  Future<bool> _loginWithCredentials() async {
    final passport = _account.username;
    final password = _account.password;

    if (passport == null ||
        passport.isEmpty ||
        password == null ||
        password.isEmpty) {
      return false;
    }

    try {
      final result = await _apiRaw(
        _loginUrl,
        {
          'passport': passport,
          'password': password,
          'remember': true,
        },
        'post',
        headers: {
          'User-Agent': _userAgent,
          'Content-Type': 'application/json',
          'App-Version': '43',
          'Referer':
              'https://login.123pan.com/centerlogin'
              '?redirect_url=https%3A%2F%2Fwww.123684.com&source_page=website',
        },
      );

      if (result['code'] == 0 &&
          result['data'] != null &&
          result['data']['token'] != null) {
        _account.token = result['data']['token'].toString();
        _account.isLoggedIn = true;
        _account.lastLoginAt = DateTime.now();
        await CloudCookieManager.saveAccount(_account);
        return true;
      }
    } catch (_) {
      // Fall through.
    }

    return false;
  }

  // ── Internal: recursive file listing ───────────────────────────────

  /// Recursively list all video files from a Pan123 share.
  ///
  /// Walks directories (Category === 0) and collects videos
  /// (Category === 2). Supports pagination via `Page`/`PageSize`.
  Future<void> _listFilesRecursive({
    required String shareKey,
    required String sharePwd,
    required List<CloudDriveFile> videos,
    required int parentFileId,
    int page = 1,
  }) async {
    const int pageSize = 100;

    final listData = await _api(
      'get_share_list',
      {
        'ShareKey': shareKey,
        'SharePwd': sharePwd,
        'ParentFileId': parentFileId,
        'Page': page,
        'PageSize': pageSize,
      },
      'post',
    );

    if (listData['code'] != 0 || listData['data'] == null) return;

    final data = listData['data'];
    final items = data['InfoList'] as List?;
    if (items == null || items.isEmpty) return;

    final subDirs = <Map<String, dynamic>>[];
    final total = data['Count'] ?? items.length;

    for (final item in items) {
      final itemMap = item as Map<String, dynamic>;
      final category = itemMap['Category'];

      if (category == 0) {
        // Directory — recurse after processing siblings.
        subDirs.add(itemMap);
      } else if (category == 2) {
        // Video file.
        final fileId = itemMap['FileId']?.toString() ?? '';
        final fileName = itemMap['FileName']?.toString() ?? '';
        final s3KeyFlag = itemMap['S3KeyFlag']?.toString() ?? '';
        final size = itemMap['Size'] ?? 0;
        final etag = itemMap['Etag']?.toString() ?? '';

        // Encode per-file extras as JSON so getLiveTranscoding / getDownload
        // can reconstruct them without maintaining state.
        final fileToken = jsonEncode({
          's3KeyFlag': s3KeyFlag,
          'size': size,
          'etag': etag,
        });

        // Build a CloudDriveFile with the extras carried in shareFileToken.
        // shareToken is left empty because Pan123 does not use an stoken.
        // The default getEpisodeUrl() produces the correct encoded URL:
        //   [pan123] name$pan123++fileId++JSON++shareKey++
        videos.add(CloudDriveFile(
          fileId: fileId,
          name: fileName,
          size: size.toString(),
          shareId: shareKey,
          shareToken: '',
          shareFileToken: fileToken,
          parent: parentFileId.toString(),
          isDir: false,
          shareIndex: 0,
          driveType: CloudDriveType.pan123,
        ));
      }
    }

    // Handle pagination.
    final totalPages = (total / pageSize).ceil();
    if (page < totalPages) {
      await _listFilesRecursive(
        shareKey: shareKey,
        sharePwd: sharePwd,
        videos: videos,
        parentFileId: parentFileId,
        page: page + 1,
      );
    }

    // Recurse into subdirectories.
    for (final dir in subDirs) {
      final dirId = dir['FileId'] ?? 0;
      await _listFilesRecursive(
        shareKey: shareKey,
        sharePwd: sharePwd,
        videos: videos,
        parentFileId: dirId as int,
      );
    }
  }

  // ── Internal: HTTP helpers ─────────────────────────────────────────

  /// Build common request headers.
  Map<String, String> _getHeaders({bool useAuth = false}) {
    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Referer': _refererUrl,
      'Content-Type': 'application/json',
    };
    if (useAuth && _account.token != null && _account.token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${_account.token}';
    }
    return headers;
  }

  /// POST request to the Pan123 share API base.
  Future<Map<String, dynamic>> _api(
    String endpoint,
    Map<String, dynamic> body,
    String method, {
    bool useAuth = false,
  }) async {
    return _apiRaw(
      _apiBase + endpoint,
      body,
      method,
      headers: _getHeaders(useAuth: useAuth),
    );
  }

  /// GET request to an arbitrary URL with query parameters.
  Future<Map<String, dynamic>> _apiGet(
    String url,
    Map<String, String> params,
  ) async {
    final client = MClient.init(
      reqcopyWith: {'useDartHttpClient': true},
    );

    final uri = Uri.parse(url).replace(queryParameters: params);
    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Referer': _refererUrl,
    };
    if (_account.token != null && _account.token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${_account.token}';
      headers['platform'] = 'android';
    }

    final resp = await client.get(uri, headers: headers);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Raw HTTP request to any URL.
  Future<Map<String, dynamic>> _apiRaw(
    String url,
    Map<String, dynamic> body,
    String method, {
    required Map<String, String> headers,
  }) async {
    final client = MClient.init(
      reqcopyWith: {'useDartHttpClient': true},
    );

    late Response resp;

    if (method != 'get') {
      resp = await client.post(
        Uri.parse(url),
        body: body.isNotEmpty ? jsonEncode(body) : null,
        headers: headers,
      );
    } else {
      resp = await client.get(
        Uri.parse(url),
        headers: headers,
      );
    }

    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
