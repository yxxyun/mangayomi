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
import 'package:mangayomi/services/cloud_drive/lcs_utils.dart';

class AliDriveService implements CloudDriveService {
  // ── Constants ──────────────────────────────────────────────────────

  static const String _apiBase = 'https://api.aliyundrive.com';
  static const String _authBase = 'https://auth.aliyundrive.com';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const String _refererUrl = 'https://www.aliyundrive.com/';
  static const String _saveDirName = 'TV';

  static const List<String> _subtitleExts = [
    '.srt',
    '.ass',
    '.scc',
    '.stl',
    '.ttml',
  ];

  // ── State ──────────────────────────────────────────────────────────

  CloudDriveAccount _account = CloudDriveAccount(
    type: CloudDriveType.ali,
  );

  /// Full user info from the auth response — includes drive_id, etc.
  Map<String, dynamic> _user = {};

  /// Cache of share tokens keyed by shareId.
  final Map<String, Map<String, dynamic>> _shareTokenCache = {};

  /// Cache of saved file IDs keyed by source fileId.
  final Map<String, String> _saveFileIdCache = {};

  /// The save directory ID (lazy-created).
  String? _saveDirId;

  // ── Interface: getters ─────────────────────────────────────────────

  @override
  CloudDriveType get type => CloudDriveType.ali;

  @override
  CloudDriveAccount get account => _account;

  @override
  bool get isLoggedIn => _account.isLoggedIn;

  // ── Interface: lifecycle ───────────────────────────────────────────

  @override
  Future<void> initialize() async {
    final saved = await CloudCookieManager.getAccount(CloudDriveType.ali);
    if (saved != null) {
      _account = saved;
    }

    // If we have a refresh token, attempt to restore the session.
    if (_account.refreshToken != null && _account.refreshToken!.isNotEmpty) {
      try {
        await _refreshAccessToken();
      } catch (_) {
        _account.isLoggedIn = false;
        _account.token = null;
      }
    }
  }

  @override
  Future<bool> loginByCookie(String cookie) async {
    if (cookie.isEmpty) return false;

    // Expected format: "refresh_token|||access_token" or just "refresh_token".
    String refreshToken;
    String? accessToken;

    if (cookie.contains('|||')) {
      final parts = cookie.split('|||');
      refreshToken = parts[0].trim();
      accessToken = parts.length > 1 ? parts[1].trim() : null;
    } else {
      refreshToken = cookie.trim();
    }

    if (refreshToken.isEmpty) return false;

    _account.refreshToken = refreshToken;
    if (accessToken != null && accessToken.isNotEmpty) {
      _account.token = accessToken;
    }

    // Verify by refreshing.
    try {
      await _refreshAccessToken();
    } catch (_) {
      return false;
    }

    _account.isLoggedIn = true;
    _account.lastLoginAt = DateTime.now();
    await CloudCookieManager.saveAccount(_account);

    return true;
  }

  @override
  Future<bool> loginByQR() async {
    throw UnimplementedError('QR login is not yet supported for AliDrive.');
  }

  @override
  Future<void> logout() async {
    _account = CloudDriveAccount(type: CloudDriveType.ali);
    _user.clear();
    _shareTokenCache.clear();
    _saveFileIdCache.clear();
    _saveDirId = null;
    await CloudCookieManager.clear(CloudDriveType.ali);
  }

  @override
  void dispose() {
    _shareTokenCache.clear();
    _saveFileIdCache.clear();
  }

  // ── Interface: share parsing & token ───────────────────────────────

  @override
  ShareData? parseShareUrl(String url) {
    // Match alipan.com/s/{shareId} or aliyundrive.com/s/{shareId}
    // Optionally followed by /folder/{folderId}.
    final regex = RegExp(
      r'https://www\.(?:alipan|aliyundrive)\.com/s/([^/?]+)(?:/folder/([^/?]+))?',
    );
    final match = regex.firstMatch(url);
    if (match == null) return null;
    return ShareData(
      shareId: match.group(1)!,
      folderId: match.group(2) ?? 'root',
    );
  }

  @override
  Future<bool> getShareToken(ShareData shareData) async {
    // Check cache with expiration guard.
    final cached = _shareTokenCache[shareData.shareId];
    if (cached != null) {
      final expire = cached['expire_time'];
      if (expire is int && expire > DateTime.now().millisecondsSinceEpoch ~/ 1000) {
        return true;
      }
      // Expired — remove so we re-fetch.
      _shareTokenCache.remove(shareData.shareId);
    }

    final result = await _api(
      'v2/share_link/get_share_token',
      {
        'share_id': shareData.shareId,
        'share_pwd': shareData.sharePwd ?? '',
      },
      'post',
    );

    if (result['share_token'] != null) {
      // Normalise expire_time to epoch seconds.
      int expireTime;
      if (result['expire_time'] != null) {
        expireTime = DateTime.parse(result['expire_time'] as String)
            .millisecondsSinceEpoch ~/ 1000;
      } else {
        expireTime = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200;
      }
      result['expire_time'] = expireTime;

      _shareTokenCache[shareData.shareId] = Map<String, dynamic>.from(result);
      return true;
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
    final subtitles = <CloudDriveFile>[];

    await _listFilesRecursive(
      shareData: shareData,
      videos: videos,
      subtitles: subtitles,
      folderId: shareData.folderId ?? 'root',
    );

    // Attach best-matching subtitles to each video.
    if (subtitles.isNotEmpty) {
      for (final video in videos) {
        final best = _findBestLCS(video, subtitles);
        if (best['bestMatch'] != null) {
          final matched = (best['bestMatch'] as Map)['target'] as CloudDriveFile;
          final ext = matched.name.split('.').last;
          video.subtitleUrl = '${matched.name}@@@$ext@@@${matched.fileId}';
        }
      }
    }

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
    return _save(shareId, fileId, clean, stoken: stoken, fileToken: fileToken);
  }

  // ── Interface: transcoding / download ──────────────────────────────

  @override
  Future<List<QualityOption>> getLiveTranscoding({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
  }) async {
    if (!_saveFileIdCache.containsKey(fileId)) {
      final savedId = await _save(shareId, fileId, true, stoken: stoken);
      if (savedId == null) return [];
      _saveFileIdCache[fileId] = savedId;
    }

    await _ensureAuth();

    final result = await _openApi(
      'v2/file/get_video_preview_play_info',
      {
        'file_id': _saveFileIdCache[fileId],
        'drive_id': _getDriveId(),
        'category': 'live_transcoding',
        'url_expire_sec': '14400',
      },
      'post',
    );

    final playInfo = result['video_preview_play_info'];
    if (playInfo != null && playInfo['live_transcoding_task_list'] != null) {
      final tasks = playInfo['live_transcoding_task_list'] as List;
      return tasks.map((t) {
        final task = t as Map<String, dynamic>;
        return QualityOption(
          url: task['url']?.toString() ?? '',
          quality: task['template_id']?.toString() ?? '',
        );
      }).toList();
    }
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
    if (!_saveFileIdCache.containsKey(fileId)) {
      final savedId = await _save(shareId, fileId, clean, stoken: stoken);
      if (savedId == null) return null;
      _saveFileIdCache[fileId] = savedId;
    }

    await _ensureAuth();

    final result = await _openApi(
      'https://open.aliyundrive.com/adrive/v1.0/openFile/getDownloadUrl',
      {
        'file_id': _saveFileIdCache[fileId],
        'drive_id': _getDriveId(),
      },
      'post',
      extraHeaders: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) aDrive/6.7.3 Chrome/112.0.5615.165 Electron/24.1.3.7 Safari/537.36',
        'x-canary': 'client=windows,app=adrive,version=v6.7.3',
      },
    );

    if (result['url'] != null) {
      return result;
    }
    return null;
  }

  // ── Interface: videos ──────────────────────────────────────────────

  @override
  Future<List<Video>> getVideos(String encodedUrl) async {
    // Expected format (from CloudDriveFile.getEpisodeUrl):
    //   [ali] displayName$ali++fileId++shareFileToken++shareId++shareToken
    // parts[1] = fileId, parts[2] = shareFileToken (unused for Ali),
    // parts[3] = shareId, parts[4] = shareToken.
    final parts = encodedUrl.split('++');
    if (parts.length < 5) return [];

    final fileId = parts[1];
    final shareId = parts[3];
    final shareToken = parts[4];

    // Subtitle info: each sub is name@@@ext@@@fileId, joined with '+'.
    final subtitlePart = parts.length > 5 ? parts[5] : '';
    final subtitleInfos =
        subtitlePart.isNotEmpty ? subtitlePart.split('+') : <String>[];

    final videos = <Video>[];

    // Try live transcoding first.
    final qualityOptions = await getLiveTranscoding(
      shareId: shareId,
      stoken: shareToken,
      fileId: fileId,
      fileToken: '',
    );

    final headers = _getHeaders();
    headers.remove('Content-Type');

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
      // Fallback: try direct download URL.
      final dlResult = await getDownload(
        shareId: shareId,
        stoken: shareToken,
        fileId: fileId,
        fileToken: '',
        clean: false,
      );
      if (dlResult != null && dlResult['url'] != null) {
        final url = dlResult['url'].toString();
        videos.add(Video(
          url,
          'original',
          url,
          headers: Map<String, String>.from(headers),
        ));
      }
    }

    // Attach subtitles to every video.
    if (subtitleInfos.isNotEmpty) {
      final tracks = <Track>[];
      for (final info in subtitleInfos) {
        if (info.isEmpty) continue;
        final subParts = info.split('@@@');
        if (subParts.length != 3) continue;

        final subName = subParts[0];
        final subFileId = subParts[2];

        final dl = await getDownload(
          shareId: shareId,
          stoken: shareToken,
          fileId: subFileId,
          fileToken: '',
          clean: false,
        );
        final subUrl = dl?['url']?.toString();
        if (subUrl != null) {
          tracks.add(Track(file: subUrl, label: subName));
        }
      }

      if (tracks.isNotEmpty) {
        for (final v in videos) {
          v.subtitles = List<Track>.from(tracks);
        }
      }
    }

    return videos;
  }

  // ── Interface: auth refresh ────────────────────────────────────────

  @override
  Future<bool> refreshAuth() async {
    try {
      await _refreshAccessToken();
      return _account.isLoggedIn;
    } catch (_) {
      return false;
    }
  }

  // ── Internal: OAuth token management ────────────────────────────────

  /// Ensure we have a fresh access_token before making authenticated calls.
  Future<void> _ensureAuth() async {
    if (_account.refreshToken == null || _account.refreshToken!.isEmpty) {
      throw Exception('No refresh token available for AliDrive');
    }
    await _refreshAccessToken();
  }

  /// Refresh the OAuth2 access_token using the stored refresh_token.
  ///
  /// POST to `https://auth.aliyundrive.com/v2/account/token` with
  /// `grant_type=refresh_token` and the saved refresh_token.
  ///
  /// On success the response contains a new `access_token`, `refresh_token`,
  /// `expire_time`, and optionally `drive` info which we cache in [_user].
  Future<void> _refreshAccessToken() async {
    // Decode the current access_token JWT to check expiration early.
    if (_account.token != null && _account.token!.isNotEmpty) {
      try {
        final jwtParts = _account.token!.split('.');
        if (jwtParts.length >= 2) {
          final payload = utf8.decode(
            base64Url.decode(base64Url.normalize(jwtParts[1])),
          );
          final payloadMap = jsonDecode(payload) as Map<String, dynamic>;
          final exp = payloadMap['exp'] as int?;
          if (exp != null &&
              exp > DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120) {
            // Token is still valid for more than 2 minutes.
            return;
          }
        }
      } catch (_) {
        // If we cannot decode the JWT, proceed with refresh anyway.
      }
    }

    if (_account.refreshToken == null || _account.refreshToken!.isEmpty) {
      throw Exception('No refresh token available');
    }

    final client = MClient.init(
      reqcopyWith: {'useDartHttpClient': true},
    );

    final resp = await client.post(
      Uri.parse('$_authBase/v2/account/token'),
      body: jsonEncode({
        'refresh_token': _account.refreshToken,
        'grant_type': 'refresh_token',
      }),
      headers: _getHeaders(),
    );

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      _user = Map<String, dynamic>.from(data);

      _account.token = data['access_token']?.toString() ?? '';
      _account.refreshToken = data['refresh_token']?.toString() ?? '';
      _account.isLoggedIn = true;
      _account.expiresAt = data['expire_time'] != null
          ? DateTime.tryParse(data['expire_time'] as String)
          : null;

      await CloudCookieManager.saveAccount(_account);
    } else {
      _account.isLoggedIn = false;
      throw Exception(
        'Failed to refresh access token: ${resp.statusCode}',
      );
    }
  }

  /// Return the resource drive ID (or default drive ID) from cached user info.
  String _getDriveId() {
    if (_user['drive'] != null && _user['drive'] is Map) {
      final drive = _user['drive'] as Map<String, dynamic>;
      final resourceId = drive['resource_drive_id']?.toString();
      if (resourceId != null && resourceId.isNotEmpty) return resourceId;
    }
    return _user['default_drive_id']?.toString() ?? '';
  }

  // ── Internal: directory management ─────────────────────────────────

  /// Remove all files inside the save directory.
  Future<void> _clearSaveDir() async {
    if (_saveDirId == null) return;
    await _ensureAuth();

    final listData = await _openApi(
      'adrive/v3/file/list',
      {
        'drive_id': _getDriveId(),
        'parent_file_id': _saveDirId,
        'limit': 100,
        'order_by': 'updated_at',
        'order_direction': 'DESC',
      },
      'post',
    );

    if (listData['items'] != null) {
      for (final item in listData['items'] as List) {
        final itemMap = item as Map<String, dynamic>;
        await _openApi(
          'v2/recyclebin/trash',
          {
            'drive_id': _getDriveId(),
            'file_id': itemMap['file_id'].toString(),
          },
          'post',
        );
      }
    }
  }

  /// Create (or find) the save directory in the user's resource drive.
  Future<void> _createSaveDir({bool clean = false}) async {
    if (_saveDirId != null) {
      if (clean) await _clearSaveDir();
      return;
    }

    await _ensureAuth();

    // Fetch user info to get the resource drive ID.
    final driveInfo = await _openApi(
      'v2/user/get',
      {},
      'post',
    );

    if (driveInfo['resource_drive_id'] == null) return;
    _user['drive'] = driveInfo;

    final driveId = driveInfo['resource_drive_id'].toString();

    // List root to see if _saveDirName already exists.
    final listData = await _openApi(
      'adrive/v3/file/list',
      {
        'drive_id': driveId,
        'parent_file_id': 'root',
        'limit': 100,
        'order_by': 'updated_at',
        'order_direction': 'DESC',
      },
      'post',
    );

    if (listData['items'] != null) {
      for (final item in listData['items'] as List) {
        final itemMap = item as Map<String, dynamic>;
        if (itemMap['name'] == _saveDirName &&
            itemMap['type'] == 'folder') {
          _saveDirId = itemMap['file_id'].toString();
          if (clean) await _clearSaveDir();
          return;
        }
      }

      // Create the directory.
      final createResult = await _openApi(
        'adrive/v2/file/createWithFolders',
        {
          'check_name_mode': 'refuse',
          'drive_id': driveId,
          'name': _saveDirName,
          'parent_file_id': 'root',
          'type': 'folder',
        },
        'post',
      );

      if (createResult['file_id'] != null) {
        _saveDirId = createResult['file_id'].toString();
      }
    }
  }

  /// Save a shared file to the personal resource drive so we can access
  /// transcoding / download endpoints that require a personal-drive file.
  Future<String?> _save(
    String shareId,
    String fileId,
    bool clean, {
    String? stoken,
    String? fileToken,
  }) async {
    await _ensureAuth();
    await _createSaveDir(clean: clean);

    if (clean) {
      _saveFileIdCache.clear();
    }

    if (_saveDirId == null) return null;

    // Ensure we have a share token – use the provided stoken when available.
    if (stoken == null && !_shareTokenCache.containsKey(shareId)) {
      await getShareToken(ShareData(shareId: shareId));
    }
    final shareTokenData = stoken != null
        ? <String, dynamic>{'share_token': stoken}
        : _shareTokenCache[shareId];
    if (shareTokenData == null) return null;

    final shareTokenStr = shareTokenData['share_token']?.toString() ?? '';

    final saveResult = await _api(
      'adrive/v2/file/copy',
      {
        'file_id': fileId,
        'share_id': shareId,
        'auto_rename': true,
        'to_parent_file_id': _saveDirId,
        'to_drive_id': _getDriveId(),
      },
      'post',
      extraHeaders: {
        'X-Share-Token': shareTokenStr,
      },
    );

    if (saveResult['file_id'] != null) {
      return saveResult['file_id'].toString();
    }
    return null;
  }

  // ── Internal: recursive file listing ───────────────────────────────

  /// Walk the share tree starting at [folderId], collecting video and
  /// subtitle entries into [videos] and [subtitles].
  Future<void> _listFilesRecursive({
    required ShareData shareData,
    required List<CloudDriveFile> videos,
    required List<CloudDriveFile> subtitles,
    required String folderId,
    String? marker,
  }) async {
    final shareId = shareData.shareId;
    final shareTokenData = _shareTokenCache[shareId];
    if (shareTokenData == null) return;
    final shareToken = shareTokenData['share_token']?.toString() ?? '';

    final listData = await _api(
      'adrive/v2/file/list_by_share',
      {
        'share_id': shareId,
        'parent_file_id': folderId,
        'limit': 200,
        'order_by': 'name',
        'order_direction': 'ASC',
        'marker': marker ?? '',
      },
      'post',
      extraHeaders: {
        'X-Share-Token': shareToken,
      },
    );

    final items = listData['items'] as List?;
    if (items == null) return;

    final subDirs = <Map<String, dynamic>>[];

    for (final item in items) {
      final itemMap = item as Map<String, dynamic>;
      final type = itemMap['type']?.toString() ?? '';
      final category = itemMap['category']?.toString() ?? '';
      final name = itemMap['name']?.toString() ?? '';
      final ext = itemMap['file_extension']?.toString() ?? '';

      if (type == 'folder') {
        subDirs.add(itemMap);
      } else if (type == 'file' && category == 'video') {
        final size = itemMap['size'] ?? 0;
        if (size is int && size < 5 * 1024 * 1024) continue;

        // Sanitise the file name as done in ali.js.
        final textRegex = RegExp("[#|'\"\\[\\]&<>]");
        var cleanName =
            name.replaceAll(RegExp(r'玩偶哥.*【神秘的哥哥们】'), '');
        cleanName = textRegex.hasMatch(cleanName)
            ? cleanName.replaceAll(textRegex, '')
            : cleanName;

        videos.add(CloudDriveFile(
          fileId: itemMap['file_id']?.toString() ?? '',
          name: cleanName,
          size: size.toString(),
          shareId: shareId,
          shareToken: shareToken,
          parent: folderId,
          driveType: CloudDriveType.ali,
        ));
      } else if (type == 'file' &&
          _subtitleExts.any((e) => ext.toLowerCase().endsWith(e))) {
        final size = itemMap['size'] ?? 0;
        subtitles.add(CloudDriveFile(
          fileId: itemMap['file_id']?.toString() ?? '',
          name: name,
          size: size.toString(),
          shareId: shareId,
          shareToken: shareToken,
          parent: folderId,
          driveType: CloudDriveType.ali,
        ));
      }
    }

    // Pagination.
    final nextMarker = listData['next_marker']?.toString();
    if (nextMarker != null && nextMarker.isNotEmpty) {
      await _listFilesRecursive(
        shareData: shareData,
        videos: videos,
        subtitles: subtitles,
        folderId: folderId,
        marker: nextMarker,
      );
    }

    // Recurse into subdirectories.
    for (final dir in subDirs) {
      await _listFilesRecursive(
        shareData: shareData,
        videos: videos,
        subtitles: subtitles,
        folderId: dir['file_id']?.toString() ?? '',
      );
    }
  }

  // ── Internal: LCS subtitle matching ────────────────────────────────

  /// Find the closest subtitle match for [mainItem] among [targetItems]
  /// using the LCS algorithm.
  Map<String, dynamic> _findBestLCS(
    CloudDriveFile mainItem,
    List<CloudDriveFile> targetItems,
  ) {
    final results = <Map<String, dynamic>>[];
    var bestMatchIndex = 0;

    for (var i = 0; i < targetItems.length; i++) {
      final currentLCS = LcsUtils.lcs(
        _removeExt(mainItem.name).toLowerCase(),
        _removeExt(targetItems[i].name).toLowerCase(),
      );
      results.add({'target': targetItems[i], 'lcs': currentLCS});
      if (currentLCS['length'] > results[bestMatchIndex]['lcs']['length']) {
        bestMatchIndex = i;
      }
    }

    return {
      'allLCS': results,
      'bestMatch': results.isNotEmpty ? results[bestMatchIndex] : null,
      'bestMatchIndex': bestMatchIndex,
    };
  }

  // ── Internal: HTTP client ──────────────────────────────────────────

  /// Build base headers common to every request.
  Map<String, String> _getHeaders() {
    return {
      'User-Agent': _userAgent,
      'Referer': _refererUrl,
      'Content-Type': 'application/json',
    };
  }

  /// Build headers with the Bearer Authorization token included.
  Map<String, String> _getAuthHeaders() {
    final headers = _getHeaders();
    if (_account.token != null && _account.token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${_account.token}';
    } else if (_user['token_type'] != null &&
        _user['access_token'] != null) {
      headers['Authorization'] =
          '${_user['token_type']} ${_user['access_token']}';
    }
    return headers;
  }

  /// Make an API request to `https://api.aliyundrive.com/{url}`.
  ///
  /// URLs starting with `adrive/` automatically include Bearer auth and
  /// trigger a token refresh if the current token is expired.
  Future<Map<String, dynamic>> _api(
    String url,
    dynamic data,
    String method, {
    Map<String, String>? extraHeaders,
  }) async {
    final needsAuth = url.startsWith('adrive/');
    if (needsAuth) {
      await _ensureAuth();
    }

    final client = MClient.init(
      reqcopyWith: {'useDartHttpClient': true},
    );

    final headers = needsAuth ? _getAuthHeaders() : _getHeaders();
    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }

    final uri = Uri.parse('$_apiBase/$url');

    late Response resp;

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

    // Retry once on 401 after refreshing the token.
    if (resp.statusCode == 401 && needsAuth) {
      await _refreshAccessToken();
      headers.addAll(_getAuthHeaders());
      if (extraHeaders != null) {
        headers.addAll(extraHeaders);
      }

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

    if (resp.body.isEmpty) return {};
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Make an API call that requires Bearer auth (open / personal drive).
  ///
  /// [url] can be a full URL (for open platform endpoints) or a path
  /// relative to [apiBase].
  Future<Map<String, dynamic>> _openApi(
    String url,
    dynamic data,
    String method, {
    Map<String, String>? extraHeaders,
  }) async {
    await _ensureAuth();

    final client = MClient.init(
      reqcopyWith: {'useDartHttpClient': true},
    );

    final headers = _getAuthHeaders();
    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }

    final uri = url.startsWith('http')
        ? Uri.parse(url)
        : Uri.parse('$_apiBase/$url');

    late Response resp;

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

    // Retry once on 401 after refreshing the token.
    if (resp.statusCode == 401) {
      await _refreshAccessToken();
      headers.addAll(_getAuthHeaders());
      if (extraHeaders != null) {
        headers.addAll(extraHeaders);
      }

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

    if (resp.body.isEmpty) return {};
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ── Internal: string helpers ───────────────────────────────────────

  /// Remove the file extension from [text].
  String _removeExt(String text) {
    final dot = text.lastIndexOf('.');
    return dot > 0 ? text.substring(0, dot) : text;
  }
}
