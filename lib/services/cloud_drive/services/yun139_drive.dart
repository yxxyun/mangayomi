import 'dart:convert';
import 'dart:typed_data';

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

class Yun139DriveService implements CloudDriveService {
  // ── Constants ──────────────────────────────────────────────────────

  static const String _baseUrl =
      'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const String _host = 'yun.139.com';

  /// AES key from the yun.js source.
  static final encrypt.Key _aesKey = encrypt.Key.fromUtf8('PVGDwmcvfs1uV3d1');

  // ── State ──────────────────────────────────────────────────────────

  CloudDriveAccount _account = CloudDriveAccount(type: CloudDriveType.yun139);

  /// Share link ID extracted from the share URL.
  String _linkID = '';

  /// `authorization` token extracted from the cookie.
  String _authorization = '';

  /// Response cache keyed by `${linkID}-${pCaID}`.
  final Map<String, dynamic> _cache = {};

  // ── Interface: getters ─────────────────────────────────────────────

  @override
  CloudDriveType get type => CloudDriveType.yun139;

  @override
  CloudDriveAccount get account => _account;

  @override
  bool get isLoggedIn => _account.isLoggedIn;

  // ── Interface: lifecycle ───────────────────────────────────────────

  @override
  Future<void> initialize() async {
    final saved = await CloudCookieManager.getAccount(CloudDriveType.yun139);
    if (saved != null) {
      _account = saved;
    }
    _extractAuthorization();
  }

  @override
  Future<bool> loginByCookie(String cookie) async {
    if (cookie.isEmpty) return false;
    _account.cookie = cookie;
    _account.isLoggedIn = true;
    _account.lastLoginAt = DateTime.now();
    await CloudCookieManager.saveAccount(_account);
    _extractAuthorization();
    return true;
  }

  @override
  Future<bool> loginByQR() async {
    throw UnimplementedError('QR login is not supported for Yun139Drive.');
  }

  @override
  Future<void> logout() async {
    _account = CloudDriveAccount(type: CloudDriveType.yun139);
    _authorization = '';
    _cache.clear();
    _linkID = '';
    await CloudCookieManager.clear(CloudDriveType.yun139);
    await MClient.deleteAllCookies(_host);
  }

  @override
  void dispose() {
    _cache.clear();
    _linkID = '';
    _authorization = '';
  }

  // ── Interface: share parsing & token ───────────────────────────────

  @override
  ShareData? parseShareUrl(String url) {
    // yun.139.com/w/i/{linkId} or caiyun.139.com/w/i/{linkId}
    final regex = RegExp(
      r'https://(yun|caiyun)\.139\.com/(shareweb/)?(sharewap/)?#?/?w/i/([^&\?]+)',
    );
    final match = regex.firstMatch(url);
    if (match != null) {
      return ShareData(shareId: match.group(4)!);
    }
    // /m/i?{linkId} format
    final altRegex = RegExp(
      r'https://(yun|caiyun)\.139\.com/(sharewap/)?#?/?m/i\?([^&]+)',
    );
    final altMatch = altRegex.firstMatch(url);
    if (altMatch != null) {
      return ShareData(shareId: altMatch.group(3)!);
    }
    return null;
  }

  @override
  Future<bool> getShareToken(ShareData shareData) async {
    _linkID = shareData.shareId;
    // Verify by calling getShareInfo for the root.
    try {
      final info = await _getShareInfo('root');
      return info != null;
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

    final fileNodes = await _getShareFile('root');
    if (fileNodes == null) return [];

    // Map nodes to CloudDriveFile instances, filtering out directories.
    return fileNodes
        .where((node) => !node.isDir)
        .map((node) => CloudDriveFile(
              fileId: node.path,
              name: node.name,
              shareId: _linkID,
              shareToken: _linkID,
              driveType: CloudDriveType.yun139,
            ))
        .toList();
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
    // Yun139 does not support save-to-drive via this interface.
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
    // Not supported; getVideos returns the direct play URL.
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
    // Requires a valid authorization token from the cookie.
    if (_authorization.isEmpty) return null;
    try {
      final contentId = fileId;
      final payload = {
        'dlFromOutLinkReqV3': {
          'linkID': shareId.isNotEmpty ? shareId : _linkID,
          'account': _account.username ?? '',
          'coIDLst': {'item': [contentId]},
        },
        'commonAccountInfo': {
          'account': _account.username ?? '',
          'accountType': 1,
        },
      };
      final encrypted = _encrypt(jsonEncode(payload));
      final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
      final resp = await client.post(
        Uri.parse('${_baseUrl}dlFromOutLinkV3'),
        body: encrypted,
        headers: _buildHeaders(withAuth: true),
      );
      if (resp.statusCode != 200) return null;
      final responseStr = jsonDecode(resp.body) as String;
      final decrypted = _decrypt(responseStr);
      final result = jsonDecode(decrypted) as Map<String, dynamic>;
      final redrUrl = result['data']?['redrUrl']?.toString();
      if (redrUrl != null && redrUrl.isNotEmpty) {
        return {'download_url': redrUrl};
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Interface: videos ──────────────────────────────────────────────

  @override
  Future<List<Video>> getVideos(String encodedUrl) async {
    // Format: displayName$yun139++contentId++++linkID
    final parts = encodedUrl.split('++');
    if (parts.length < 4) return [];
    final contentId = parts[1];
    final linkID = parts.length > 3 && parts[3].isNotEmpty ? parts[3] : _linkID;
    if (contentId.isEmpty || linkID.isEmpty) return [];

    final playUrl = await _getPlayUrl(contentId, linkID);
    if (playUrl == null || playUrl.isEmpty) return [];

    final headers = <String, String>{
      'User-Agent': _userAgent,
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
    _extractAuthorization();
    return _authorization.isNotEmpty;
  }

  // ── Internal: cookie / auth helpers ────────────────────────────────

  /// Extract the `authorization` value from the stored cookie string.
  void _extractAuthorization() {
    final cookie = _account.cookie;
    if (cookie == null || cookie.isEmpty) {
      _authorization = '';
      return;
    }
    for (final pair in cookie.split(';')) {
      final trimmed = pair.trim();
      if (trimmed.startsWith('authorization=')) {
        _authorization = trimmed.substring('authorization='.length);
        return;
      }
    }
    _authorization = '';
  }

  // ── Internal: AES-CBC encryption / decryption ──────────────────────

  /// AES-CBC encrypt [data] (string or object) with a random IV and
  /// return `base64(IV || ciphertext)`, matching yun.js encrypt().
  String _encrypt(dynamic data) {
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(_aesKey, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
    );

    String plaintext;
    if (data is String) {
      plaintext = data;
    } else {
      plaintext = jsonEncode(data);
    }

    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    final combined = Uint8List(16 + encrypted.bytes.length)
      ..setRange(0, 16, iv.bytes)
      ..setRange(16, 16 + encrypted.bytes.length, encrypted.bytes);
    return base64Encode(combined);
  }

  /// Decrypt a `base64(IV || ciphertext)` string, matching yun.js decrypt().
  String _decrypt(String data) {
    final combined = base64Decode(data);
    final iv = encrypt.IV(Uint8List.fromList(combined.sublist(0, 16)));
    final ciphertext = combined.sublist(16);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(_aesKey, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
    );
    return encrypter.decrypt(
      encrypt.Encrypted(Uint8List.fromList(ciphertext)),
      iv: iv,
    );
  }

  // ── Internal: share API ────────────────────────────────────────────

  /// Fetch directory info for [pCaID] ('root' for the top-level).
  ///
  /// Returns the parsed response data map, or `null` on failure.
  /// Results are cached under `${linkID}-${pCaID}`.
  Future<Map<String, dynamic>?> _getShareInfo(String pCaID) async {
    if (_linkID.isEmpty) return null;

    final cacheKey = '$_linkID-$pCaID';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey] as Map<String, dynamic>?;
    }

    final payload = {
      'getOutLinkInfoReq': {
        'account': '',
        'linkID': _linkID,
        'passwd': '',
        'caSrt': 1,
        'coSrt': 1,
        'srtDr': 0,
        'bNum': 1,
        'pCaID': pCaID,
        'eNum': 200,
      },
      'commonAccountInfo': {'account': '', 'accountType': 1},
    };

    try {
      final encryptedPayload = _encrypt(jsonEncode(payload));
      // The request body is a JSON string containing the base64 ciphertext.
      final body = jsonEncode(encryptedPayload);

      final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
      final resp = await client.post(
        Uri.parse('${_baseUrl}getOutLinkInfoV6'),
        body: body,
        headers: _buildHeaders(),
      );

      if (resp.statusCode != 200) return null;

      // Response is a JSON string containing base64 encrypted data.
      final responseStr = jsonDecode(resp.body) as String;
      final decrypted = _decrypt(responseStr);
      final result = jsonDecode(decrypted) as Map<String, dynamic>;
      final data = result['data'] as Map<String, dynamic>?;

      if (data != null) {
        _cache[cacheKey] = data;
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  /// Recursively list video files (coType === 3) under [pCaID].
  ///
  /// Returns a flat list of [_YunFileNode] entries, or `null` on failure.
  Future<List<_YunFileNode>?> _getShareFile(String pCaID) async {
    if (pCaID.isEmpty) return null;

    final effectiveId = pCaID.startsWith('http') ? 'root' : pCaID;
    final json = await _getShareInfo(effectiveId);
    if (json == null) return null;

    final results = <_YunFileNode>[];

    // Process sub-directories (caLst) — skip filtered names.
    final caLst = json['caLst'] as List?;
    if (caLst != null) {
      const filterRegex = r'App|活动中心|免费|1T空间|免流';
      for (final item in caLst) {
        final itemMap = item as Map<String, dynamic>;
        final name = itemMap['caName']?.toString() ?? '';
        if (RegExp(filterRegex).hasMatch(name)) continue;
        final path = itemMap['path']?.toString() ?? '';
        if (path.isNotEmpty) {
          results.add(_YunFileNode(name: name, path: path, isDir: true));
        }
      }
      // Recurse into sub-directories.
      final subFutures = results.map((node) => _getShareFile(node.path));
      final subResults = await Future.wait(subFutures);
      for (final sub in subResults) {
        if (sub != null) results.addAll(sub);
      }
    }

    // Process video files (coLst) — filter coType === 3.
    final coLst = json['coLst'] as List?;
    if (coLst != null) {
      for (final item in coLst) {
        final itemMap = item as Map<String, dynamic>;
        if (itemMap['coType'] == 3) {
          results.add(_YunFileNode(
            name: itemMap['coName']?.toString() ?? '',
            path: itemMap['path']?.toString() ?? '',
          ));
        }
      }
    }

    return results;
  }

  /// Obtain the play URL for a video via the unencrypted content info API.
  Future<String?> _getPlayUrl(String contentId, String linkID) async {
    // The contentId path is like "xxx/yyy"; the API expects the second segment.
    final parts = contentId.split('/');
    final actualContentId = parts.length > 1 ? parts[1] : parts[0];

    final payload = {
      'getContentInfoFromOutLinkReq': {
        'contentId': actualContentId,
        'linkID': linkID,
        'account': '',
      },
      'commonAccountInfo': {'account': '', 'accountType': 1},
    };

    try {
      final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
      final resp = await client.post(
        Uri.parse('${_baseUrl}getContentInfoFromOutLink'),
        body: jsonEncode(payload),
        headers: _buildHeaders(),
      );

      if (resp.statusCode != 200) return null;

      final result = jsonDecode(resp.body) as Map<String, dynamic>;
      return result['data']?['contentInfo']?['presentURL']?.toString();
    } catch (_) {
      return null;
    }
  }

  // ── Internal: HTTP helpers ─────────────────────────────────────────

  Map<String, String> _buildHeaders({bool withAuth = false}) {
    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Accept': 'application/json, text/plain, */*',
      'Content-Type': 'application/json',
      'hcy-cool-flag': '1',
      'x-deviceinfo':
          '||3|12.27.0|chrome|131.0.0.0|5c7c68368f048245e1ce47f1c0f8f2d0||windows 10|1536X695|zh-CN|||',
    };
    if (withAuth && _authorization.isNotEmpty) {
      headers['authorization'] = _authorization;
    }
    return headers;
  }
}

/// Lightweight data class for a file/folder node in the Yun139 response.
class _YunFileNode {
  final String name;
  final String path;
  final bool isDir;

  const _YunFileNode({
    required this.name,
    required this.path,
    this.isDir = false,
  });
}
