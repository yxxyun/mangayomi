import 'dart:convert';
import 'dart:math';

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
import 'package:encrypt/encrypt.dart' as encrypt;

class Cloud189DriveService implements CloudDriveService {
  // ── Constants ──────────────────────────────────────────────────────

  static const String _apiBase = 'https://cloud.189.cn/api';
  static const String _openApiBase = 'https://open.e.189.cn/api';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const String _referer =
      'https://m.cloud.189.cn/zhuanti/2016/sign/index.jsp?albumBackupOpened=1';
  static const String _host = 'cloud.189.cn';

  // ── State ──────────────────────────────────────────────────────────

  CloudDriveAccount _account = CloudDriveAccount(type: CloudDriveType.cloud189);

  // Share session state – populated by getShareToken / getShareInfo.
  String _shareCode = '';
  String _accessCode = '';
  String _shareId = '';
  String _shareMode = '';
  bool _isFolder = false;

  // ── Interface: getters ─────────────────────────────────────────────

  @override
  CloudDriveType get type => CloudDriveType.cloud189;

  @override
  CloudDriveAccount get account => _account;

  @override
  bool get isLoggedIn => _account.isLoggedIn;

  // ── Interface: lifecycle ───────────────────────────────────────────

  @override
  Future<void> initialize() async {
    final saved = await CloudCookieManager.getAccount(CloudDriveType.cloud189);
    if (saved != null) {
      _account = saved;
    }

    // Auto-login with stored credentials if no cookie is available.
    if (!isLoggedIn &&
        _account.username != null &&
        _account.username!.isNotEmpty &&
        _account.password != null &&
        _account.password!.isNotEmpty) {
      try {
        final cookie = await _login(_account.username!, _account.password!);
        if (cookie.isNotEmpty) {
          _account.cookie = cookie;
          _account.isLoggedIn = true;
          _account.lastLoginAt = DateTime.now();
          await CloudCookieManager.saveAccount(_account);
        }
      } catch (_) {
        // Login failed; continue without cookie.
      }
    }
  }

  @override
  Future<bool> loginByCookie(String cookie) async {
    if (cookie.isEmpty) return false;
    _account.cookie = cookie;
    _account.isLoggedIn = true;
    _account.lastLoginAt = DateTime.now();
    await CloudCookieManager.saveAccount(_account);
    return true;
  }

  @override
  Future<bool> loginByQR() async {
    throw UnimplementedError('QR login is not supported for Cloud189Drive.');
  }

  @override
  Future<void> logout() async {
    _account = CloudDriveAccount(type: CloudDriveType.cloud189);
    await CloudCookieManager.clear(CloudDriveType.cloud189);
    await MClient.deleteAllCookies(_host);
  }

  @override
  void dispose() {
    _shareCode = '';
    _accessCode = '';
    _shareId = '';
    _shareMode = '';
    _isFolder = false;
  }

  // ── Interface: share parsing & token ───────────────────────────────

  @override
  ShareData? parseShareUrl(String url) {
    final regex = RegExp(r'https://cloud\.189\.cn/web/share\?code=([^&]+)');
    final match = regex.firstMatch(url);
    if (match != null) {
      return ShareData(shareId: match.group(1)!);
    }
    // Alternative short format: cloud.189.cn/t/{code}
    final altRegex = RegExp(r'https://cloud\.189\.cn/t/([^&]+)');
    final altMatch = altRegex.firstMatch(url);
    if (altMatch != null) {
      return ShareData(shareId: altMatch.group(1)!);
    }
    return null;
  }

  @override
  Future<bool> getShareToken(ShareData shareData) async {
    _shareCode = shareData.shareId;
    _accessCode = shareData.sharePwd ?? '';
    try {
      final info = await _getShareInfo();
      if (info == null) return false;
      _shareId = info['shareId']?.toString() ?? '';
      _shareMode = info['shareMode']?.toString() ?? '';
      _isFolder = info['isFolder'] == true || info['isFolder'] == 1;
      return _shareId.isNotEmpty;
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

    // Resolve the root fileId from share info.
    final info = await _getShareInfo();
    final rootFileId = info?['fileId']?.toString() ?? '';
    if (rootFileId.isEmpty) return [];

    final videos = <CloudDriveFile>[];
    await _collectVideos(rootFileId, videos);
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
    // Cloud189 does not support save-to-drive via this interface.
    return null;
  }

  // ── Interface: transcoding / download ──────────────────────────────

  @override
  Future<List<QualityOption>> getLiveTranscoding({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
  }) async {
    // Not supported; the play URL from _getPlayUrl is already the final URL.
    return [];
  }

  @override
  Future<Map<String, dynamic>?> getDownload({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
    bool clean = false,
  }) async {
    // Use getVideos for playback.
    return null;
  }

  // ── Interface: videos ──────────────────────────────────────────────

  @override
  Future<List<Video>> getVideos(String encodedUrl) async {
    // Format: displayName$cloud189++fileId++++shareId
    final parts = encodedUrl.split('++');
    if (parts.length < 4) return [];
    final fileId = parts[1];
    final shareId =
        parts.length > 3 && parts[3].isNotEmpty ? parts[3] : _shareId;
    if (fileId.isEmpty || shareId.isEmpty) return [];

    final playUrl = await _getPlayUrl(fileId, shareId);
    if (playUrl == null || playUrl.isEmpty) return [];

    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Referer': _referer,
      if (_account.cookie != null && _account.cookie!.isNotEmpty)
        'Cookie': _account.cookie!,
    };

    return [
      Video(
        playUrl,
        'original',
        playUrl,
        headers: headers,
      ),
    ];
  }

  // ── Interface: auth refresh ────────────────────────────────────────

  @override
  Future<bool> refreshAuth() async {
    if (_account.cookie == null || _account.cookie!.isEmpty) return false;
    try {
      final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
      final resp = await client.get(
        Uri.parse(
          '$_apiBase/portal/loginUrl.action'
          '?redirectURL=https://cloud.189.cn/web/redirect.html'
          '?returnURL=/main.action',
        ),
        headers: {'User-Agent': _userAgent},
      );
      return resp.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  // ── Internal: RSA encryption ───────────────────────────────────────

  /// RSA-encrypt [plaintext] with the given raw-base64 [pubKeyPem]
  /// and return the hex-encoded ciphertext (matching cloud.js behaviour).
  String _rsaEncryptToHex(String plaintext, String pubKeyPem) {
    final pem =
        '-----BEGIN PUBLIC KEY-----\n$pubKeyPem\n-----END PUBLIC KEY-----';
    final parser = encrypt.RSAKeyParser();
    // ignore: implicit_dynamic_type
    final dynamic publicKey = parser.parse(pem);
    final encrypter = encrypt.Encrypter(
      encrypt.RSA(
        publicKey: publicKey,
        encoding: encrypt.RSAEncoding.PKCS1,
      ),
    );
    final encrypted = encrypter.encryptBytes(utf8.encode(plaintext));
    return encrypted.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  // ── Internal: login via account/password ───────────────────────────

  /// Perform RSA-encrypted login at open.e.189.cn and return the
  /// resulting cookie string.
  Future<String> _login(String uname, String passwd) async {
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});

    // 1. Obtain RSA public key.
    var resp = await client.post(
      Uri.parse('$_openApiBase/logbox/config/encryptConf.do?appId=cloud'),
      headers: {
        'User-Agent': _userAgent,
        'Referer': 'https://open.e.189.cn/',
      },
    );
    final configJson = jsonDecode(resp.body) as Map<String, dynamic>;
    final pubKey = configJson['data']?['pubKey']?.toString() ?? '';
    if (pubKey.isEmpty) {
      throw Exception('Failed to retrieve RSA public key from encryptConf');
    }

    // 2. Fetch loginUrl to obtain reqId and lt.
    resp = await client.get(
      Uri.parse(
        '$_apiBase/portal/loginUrl.action'
        '?redirectURL=https://cloud.189.cn/web/redirect.html?returnURL=/main.action',
      ),
      headers: {'User-Agent': _userAgent},
    );
    final finalUrl = resp.request?.url.toString() ?? '';
    final reqIdMatch = RegExp(r'reqId=(\w+)').firstMatch(finalUrl);
    final ltMatch = RegExp(r'lt=(\w+)').firstMatch(finalUrl);
    final reqId = reqIdMatch?.group(1) ?? '';
    final lt = ltMatch?.group(1) ?? '';

    // 3. Get app configuration (returnUrl / paramId).
    final tHeaders = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:74.0) Gecko/20100101 Firefox/76.0',
      'Referer': 'https://open.e.189.cn/',
      if (lt.isNotEmpty) 'lt': lt,
      if (reqId.isNotEmpty) 'Reqid': reqId,
    };

    resp = await client.post(
      Uri.parse('$_openApiBase/logbox/oauth2/appConf.do'),
      body: 'version=2.0&appKey=cloud',
      headers: tHeaders,
    );
    final appConf = jsonDecode(resp.body) as Map<String, dynamic>;
    final returnUrl = appConf['data']?['returnUrl']?.toString() ?? '';
    final paramId = appConf['data']?['paramId']?.toString() ?? '';

    // 4. RSA-encrypt credentials → hex.
    final enUnameHex = _rsaEncryptToHex(uname, pubKey);
    final enPasswdHex = _rsaEncryptToHex(passwd, pubKey);

    // 5. Submit login form.
    final loginBody = Uri(queryParameters: {
      'appKey': 'cloud',
      'version': '2.0',
      'accountType': '01',
      'mailSuffix': '@189.cn',
      'validateCode': '',
      'returnUrl': returnUrl,
      'paramId': paramId,
      'captchaToken': '',
      'dynamicCheck': 'FALSE',
      'clientType': '1',
      'cb_SaveName': '0',
      'isOauth2': 'false',
      'userName': '{NRP}$enUnameHex',
      'password': '{NRP}$enPasswdHex',
    }).query;

    resp = await client.post(
      Uri.parse('$_openApiBase/logbox/oauth2/loginSubmit.do'),
      body: loginBody,
      headers: tHeaders,
    );

    final loginResult = jsonDecode(resp.body) as Map<String, dynamic>;
    final toUrl = loginResult['toUrl']?.toString();
    if (toUrl == null || toUrl.isEmpty) {
      throw Exception('Cloud189 login failed: ${resp.body}');
    }

    // 6. Follow the redirect to finalise session and collect cookies.
    var cookies = '';
    if (resp.headers['set-cookie'] != null) {
      cookies = resp.headers['set-cookie']!
          .split(';')
          .map((s) => s.split(';')[0])
          .join(';');
    }

    resp = await client.get(
      Uri.parse(toUrl),
      headers: {
        'User-Agent': _userAgent,
        'Cookie': cookies,
      },
    );

    if (resp.headers['set-cookie'] != null) {
      final extra = resp.headers['set-cookie']!
          .split(';')
          .map((s) => s.split(';')[0])
          .join(';');
      cookies += '; $extra';
    }

    return cookies;
  }

  // ── Internal: share API helpers ────────────────────────────────────

  /// Call the getShareInfoByCodeV2 endpoint (and checkAccessCode if
  /// [_accessCode] is set), returning the full response map.
  Future<Map<String, dynamic>?> _getShareInfo() async {
    // If an access code was provided, validate it first.
    if (_accessCode.isNotEmpty) {
      try {
        await _api(
          'open/share/checkAccessCode.action'
          '?shareCode=$_shareCode&accessCode=$_accessCode',
          null,
          'get',
        );
      } catch (_) {
        // checkAccessCode may fail; proceed to getShareInfoByCodeV2 anyway.
      }
    }

    return _api(
      'open/share/getShareInfoByCodeV2.action'
      '?key=noCache&shareCode=$_shareCode',
      null,
      'get',
    );
  }

  /// Recursively list all video files (mediaType === 3) under [fileId].
  Future<void> _collectVideos(
    String fileId,
    List<CloudDriveFile> videos,
  ) async {
    int pageNum = 1;
    while (true) {
      final dirResp = await _listShareDir(fileId, pageNum: pageNum);
      if (dirResp == null) break;

      final data = dirResp['fileListAO'] as Map<String, dynamic>?;
      if (data == null) break;

      // Process files at the current level.
      final fileList = data['fileList'] as List?;
      if (fileList != null) {
        for (final item in fileList) {
          final itemMap = item as Map<String, dynamic>;
          if (itemMap['mediaType'] == 3) {
            videos.add(CloudDriveFile(
              fileId: itemMap['id']?.toString() ?? '',
              name: itemMap['name']?.toString() ?? '',
              shareId: _shareId,
              shareToken: _shareId,
              driveType: CloudDriveType.cloud189,
            ));
          }
        }
      }

      // Recurse into sub-folders (only on the first page to avoid
      // revisiting the same directories on subsequent pages).
      if (pageNum == 1) {
        final folderList = data['folderList'] as List?;
        if (folderList != null) {
          for (final folder in folderList) {
            final folderMap = folder as Map<String, dynamic>;
            final folderFileId = folderMap['id']?.toString() ?? '';
            if (folderFileId.isNotEmpty) {
              await _collectVideos(folderFileId, videos);
            }
          }
        }
      }

      // Determine whether more pages exist.
      final totalCount = dirResp['recordCount'] as int? ?? 0;
      const pageSize = 120;
      if (pageNum * pageSize >= totalCount) break;
      pageNum++;
    }
  }

  /// Call the listShareDir endpoint for [fileId].
  Future<Map<String, dynamic>?> _listShareDir(String fileId, {int pageNum = 1}) async {
    try {
      final noCache = Random().nextDouble().toString();
      return _api(
        'open/share/listShareDir.action'
        '?key=noCache'
        '&pageNum=$pageNum'
        '&pageSize=120'
        '&fileId=$fileId'
        '&shareDirFileId=$fileId'
        '&isFolder=$_isFolder'
        '&shareId=$_shareId'
        '&shareMode=$_shareMode'
        '&iconOption=5'
        '&orderBy=filename'
        '&descending=false'
        '&accessCode=$_accessCode'
        '&noCache=$noCache',
        null,
        'get',
      );
    } catch (_) {
      return null;
    }
  }

  /// Obtain the play URL for a shared video file.
  Future<String?> _getPlayUrl(String fileId, String shareId) async {
    // Ensure we have a valid cookie.
    var cookie = _account.cookie ?? '';
    if (cookie.isEmpty) {
      if (_account.username != null &&
          _account.username!.isNotEmpty &&
          _account.password != null &&
          _account.password!.isNotEmpty) {
        try {
          cookie = await _login(_account.username!, _account.password!);
          _account.cookie = cookie;
          _account.isLoggedIn = true;
          await CloudCookieManager.saveAccount(_account);
        } catch (_) {
          return null;
        }
      } else {
        return null;
      }
    }

    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    try {
      final resp = await client.get(
        Uri.parse(
          '$_apiBase/portal/getNewVlcVideoPlayUrl.action'
          '?shareId=$shareId&dt=1&fileId=$fileId&type=4&key=noCache',
        ),
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/json;charset=UTF-8',
          'Cookie': cookie,
        },
      );

      if (resp.statusCode != 200) return null;

      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final normalUrl = json['normal']?['url']?.toString();
      if (normalUrl == null || normalUrl.isEmpty) return null;

      // Follow redirect to obtain the final play URL.
      final redirectResp = await client.get(
        Uri.parse(normalUrl),
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/json;charset=UTF-8',
          'Cookie': cookie,
        },
      );

      if (redirectResp.statusCode >= 300 &&
          redirectResp.statusCode < 400 &&
          redirectResp.headers['location'] != null) {
        return redirectResp.headers['location'];
      }
      return normalUrl;
    } catch (_) {
      return null;
    }
  }

  // ── Internal: HTTP client ──────────────────────────────────────────

  Map<String, String> _getHeaders() {
    return {
      'User-Agent': _userAgent,
      'Accept': 'application/json;charset=UTF-8',
    };
  }

  /// Make an API request to the Cloud189 backend.
  Future<Map<String, dynamic>?> _api(
    String url,
    dynamic data,
    String method,
  ) async {
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    final fullUrl = '$_apiBase/$url';
    final headers = _getHeaders();

    late Response resp;
    if (method != 'get') {
      resp = await client.post(
        Uri.parse(fullUrl),
        body: data != null ? jsonEncode(data) : null,
        headers: headers,
      );
    } else {
      resp = await client.get(
        Uri.parse(fullUrl),
        headers: headers,
      );
    }

    if (resp.statusCode != 200) return null;
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
