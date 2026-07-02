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

class UCDriveService implements CloudDriveService {
  // ── Constants ──────────────────────────────────────────────────────

  static const String _apiBase = 'https://pc-api.uc.cn/1/clouddrive/';
  static const String _pr = 'pr=UCBrowser&fr=pc';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
  static const String _refererUrl = 'https://drive.uc.cn/';
  static const String _host = 'https://uc.cn';
  static const String _cookieKey = 'https://uccookie.last';

  /// OAuth / TV login config (from drpy-node uc.js) — reserved for QR login.
  // ignore: unused_field
  static const String _oauthApi = 'https://open-api-drive.uc.cn';
  // ignore: unused_field
  static const String _oauthClientId = '5acf882d27b74502b7040b0c65519aa7';
  // ignore: unused_field
  static const String _oauthSignKey = 'l3srvtd7p42l0d0x1u8d7yc8ye9kki4d';
  // ignore: unused_field
  static const String _oauthAppVer = '1.6.8';
  // ignore: unused_field
  static const String _oauthChannel = 'UCTVOFFICIALWEB';
  // ignore: unused_field
  static const String _tokenRefreshApi = 'http://api.extscreen.com/ucdrive';

  static const List<String> _subtitleExts = [
    '.srt',
    '.ass',
    '.scc',
    '.stl',
    '.ttml',
  ];

  static const String _saveDirName = 'TV';

  // ── State ──────────────────────────────────────────────────────────

  CloudDriveAccount _account = CloudDriveAccount(
    type: CloudDriveType.uc,
  );

  /// Cache of share tokens keyed by shareId.
  final Map<String, Map<String, dynamic>> _shareTokenCache = {};

  /// Cache of saved file IDs keyed by source fileId.
  final Map<String, String> _saveFileIdCache = {};

  /// The save directory fid (lazy-created).
  String? _saveDirId;

  /// Last cookie value we set — avoids redundant MClient.setCookie calls.
  String _lastCookie = '';

  // ── Interface: getters ─────────────────────────────────────────────

  @override
  CloudDriveType get type => CloudDriveType.uc;

  @override
  CloudDriveAccount get account => _account;

  @override
  bool get isLoggedIn => _account.isLoggedIn;

  // ── Interface: lifecycle ───────────────────────────────────────────

  @override
  Future<void> initialize() async {
    final saved = await CloudCookieManager.getAccount(CloudDriveType.uc);
    if (saved != null) {
      _account = saved;
    }

    final cookie = _account.cookie;
    if (cookie != null && cookie.isNotEmpty) {
      _setCookiesIfChanged(cookie);
    }
  }

  @override
  Future<bool> loginByCookie(String cookie) async {
    if (cookie.isEmpty) return false;

    _setCookiesIfChanged(cookie);

    // Verify by hitting a simple API endpoint.
    try {
      await _api(
        'file/sort?$_pr&pdir_fid=0&_page=1&_size=1&_sort=file_type:asc,updated_at:desc',
        {},
        'get',
      );
    } catch (_) {
      return false;
    }

    _account.cookie = cookie;
    _account.isLoggedIn = true;
    _account.lastLoginAt = DateTime.now();
    await CloudCookieManager.saveAccount(_account);

    return true;
  }

  @override
  Future<bool> loginByQR() async {
    throw UnimplementedError(
      'QR login is not yet supported for UCDrive.',
    );
  }

  @override
  Future<void> logout() async {
    _account = CloudDriveAccount(type: CloudDriveType.uc);
    _lastCookie = '';
    _shareTokenCache.clear();
    _saveFileIdCache.clear();
    _saveDirId = null;

    await MClient.deleteAllCookies(_host);
    await MClient.deleteAllCookies(_cookieKey);
    await CloudCookieManager.clear(CloudDriveType.uc);
  }

  @override
  void dispose() {
    _shareTokenCache.clear();
    _saveFileIdCache.clear();
  }

  // ── Interface: share parsing & token ───────────────────────────────

  @override
  ShareData? parseShareUrl(String url) {
    final regex = RegExp(r'https://drive\.uc\.cn/s/([^?]+)');
    final match = regex.firstMatch(url);
    if (match == null) return null;
    // Strip query params from the captured shareId if present.
    final raw = match.group(1)!;
    final qIndex = raw.indexOf('?');
    final shareId = qIndex > 0 ? raw.substring(0, qIndex) : raw;
    return ShareData(shareId: shareId, folderId: '0');
  }

  @override
  Future<bool> getShareToken(ShareData shareData) async {
    if (_shareTokenCache.containsKey(shareData.shareId)) return true;

    // Remove any stale entry.
    _shareTokenCache.remove(shareData.shareId);

    final result = await _api(
      'share/sharepage/token?$_pr',
      {
        'pwd_id': shareData.shareId,
        'passcode': shareData.sharePwd ?? '',
      },
      'post',
    );

    if (result['data'] != null && result['data']['stoken'] != null) {
      _shareTokenCache[shareData.shareId] =
          Map<String, dynamic>.from(result['data']);
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
      folderId: shareData.folderId ?? '0',
    );

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
    return _save(shareId, stoken, fileId, fileToken, clean);
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
      final savedId = await _save(shareId, stoken, fileId, fileToken, true);
      if (savedId == null) return [];
      _saveFileIdCache[fileId] = savedId;
    }

    final result = await _api(
      'file/v2/play?$_pr',
      {
        'fid': _saveFileIdCache[fileId],
        'resolutions': 'normal,low,high,super,2k,4k',
        'supports': 'fmp4',
      },
      'post',
    );

    if (result['data'] == null || result['data']['video_list'] == null) {
      return [];
    }

    final list = result['data']['video_list'] as List;
    return list.map((v) {
      final info = v['video_info'] as Map<String, dynamic>;
      return QualityOption(
        url: info['url']?.toString() ?? '',
        quality: v['resolution']?.toString() ?? '',
      );
    }).toList();
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
      final savedId = await _save(shareId, stoken, fileId, fileToken, clean);
      if (savedId == null) return null;
      _saveFileIdCache[fileId] = savedId;
    }

    final result = await _api(
      'file/download?$_pr&uc_param_str=',
      {'fids': [_saveFileIdCache[fileId]]},
      'post',
    );

    if (result['data'] != null && (result['data'] as List).isNotEmpty) {
      return Map<String, dynamic>.from((result['data'] as List)[0]);
    }
    return null;
  }

  /// No-save download: acquire a direct download token for a shared file
  /// without first saving it to personal drive.
  Future<Map<String, dynamic>?> getUrl({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
  }) async {
    if (!_shareTokenCache.containsKey(shareId)) {
      await getShareToken(ShareData(shareId: shareId));
    }

    final effectiveStoken =
        stoken.isNotEmpty ? stoken : _shareTokenCache[shareId]?['stoken'] ?? '';
    if (effectiveStoken.isEmpty) return null;

    final result = await _api(
      'share/sharepage/acquire_dl_token?$_pr&pwd_id=$shareId',
      {
        'fid_list': [fileId],
        'fid_token_list': [fileToken],
        'stoken': effectiveStoken,
      },
      'post',
    );

    if (result['data'] != null) {
      final data = result['data'];
      if (data is List && data.isNotEmpty) {
        return Map<String, dynamic>.from(data[0]);
      }
      if (data is Map<String, dynamic> && data.containsKey('download_url')) {
        return data;
      }
    }
    return null;
  }

  // ── Interface: videos ──────────────────────────────────────────────

  @override
  Future<List<Video>> getVideos(String encodedUrl) async {
    // Format: [uc] displayName$uc++fileId++shareFileToken++shareId++shareToken[+subtitleInfo]
    final parts = encodedUrl.split('++');
    if (parts.length < 5) return [];

    final fileId = parts[1];
    final shareFileToken = parts[2];
    final shareId = parts[3];
    final stoken = parts[4];

    // Subtitle info: each sub is name@@@ext@@@fileId, joined with '+'
    final subtitlePart = parts.length > 5 ? parts[5] : '';
    final subtitleInfos =
        subtitlePart.isNotEmpty ? subtitlePart.split('+') : <String>[];

    final videos = <Video>[];

    // Try live transcoding first.
    final qualityOptions = await getLiveTranscoding(
      shareId: shareId,
      stoken: stoken,
      fileId: fileId,
      fileToken: shareFileToken,
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
      // Fallback: try no-save download URL.
      final dlResult = await getUrl(
        shareId: shareId,
        stoken: stoken,
        fileId: fileId,
        fileToken: shareFileToken,
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
          stoken: stoken,
          fileId: subFileId,
          fileToken: '',
          clean: false,
        );
        final subUrl = dl?['download_url']?.toString();
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
      final result = await _api(
        'file/sort?$_pr&pdir_fid=0&_page=1&_size=1&_sort=file_type:asc,updated_at:desc',
        <String, dynamic>{},
        'get',
      );

      // Check for updated __puus in current cookie and save.
      final current = _getCurrentCookie();
      if (current.isNotEmpty && current != _account.cookie) {
        _account.cookie = current;
        _account.lastLoginAt = DateTime.now();
        await CloudCookieManager.saveAccount(_account);
      }

      return result['data'] != null;
    } catch (_) {
      return false;
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

  // ── Internal: recursive file listing ───────────────────────────────

  Future<void> _listFilesRecursive({
    required ShareData shareData,
    required List<CloudDriveFile> videos,
    required List<CloudDriveFile> subtitles,
    required String folderId,
    int page = 1,
  }) async {
    const int prePage = 200;
    final shareId = shareData.shareId;
    final stoken = _shareTokenCache[shareId]?['stoken'] ?? '';

    final listData = await _api(
      'share/sharepage/detail?$_pr&pwd_id=$shareId'
      '&stoken=${Uri.encodeComponent(stoken)}'
      '&pdir_fid=$folderId&force=0'
      '&_page=$page&_size=$prePage'
      '&_sort=file_type:asc,file_name:desc',
      null,
      'get',
    );

    if (listData['data'] == null) return;
    final items = listData['data']['list'];
    if (items == null || items is! List) return;

    final subDirs = <Map<String, dynamic>>[];

    for (final item in items) {
      final itemMap = item as Map<String, dynamic>;
      final isDir = itemMap['dir'] == true ||
          itemMap['obj_category']?.toString() == 'dir';
      final isVideo = itemMap['file'] == true &&
          itemMap['obj_category']?.toString() == 'video';
      final fileName = itemMap['file_name']?.toString() ?? '';
      final isSubtitle =
          itemMap['type']?.toString() == 'file' &&
          _subtitleExts.any((ext) => fileName.toLowerCase().endsWith(ext));

      if (isDir) {
        subDirs.add(itemMap);
      } else if (isVideo) {
        final size = (itemMap['size'] ?? 0);
        if (size < 5 * 1024 * 1024) continue; // skip < 5 MB
        videos.add(CloudDriveFile.fromJson(
          itemMap,
          shareId,
          0,
          CloudDriveType.uc,
        ));
      } else if (isSubtitle) {
        subtitles.add(CloudDriveFile.fromJson(
          itemMap,
          shareId,
          0,
          CloudDriveType.uc,
        ));
      }
    }

    // Handle pagination.
    final total = (listData['metadata']?['_total'] ?? 0);
    final totalPages = (total / prePage).ceil();
    if (page < totalPages) {
      await _listFilesRecursive(
        shareData: shareData,
        videos: videos,
        subtitles: subtitles,
        folderId: folderId,
        page: page + 1,
      );
    }

    // Recursively list subdirectories.
    for (final dir in subDirs) {
      await _listFilesRecursive(
        shareData: shareData,
        videos: videos,
        subtitles: subtitles,
        folderId: dir['fid']?.toString() ?? '',
      );
    }
  }

  // ── Internal: save / download helpers ──────────────────────────────

  Future<void> _clearSaveDir() async {
    if (_saveDirId == null) return;
    final listData = await _api(
      'file/sort?$_pr&pdir_fid=$_saveDirId&_page=1&_size=200'
      '&_sort=file_type:asc,updated_at:desc',
      <String, dynamic>{},
      'get',
    );
    if (listData['data'] != null &&
        listData['data']['list'] != null &&
        (listData['data']['list'] as List).isNotEmpty) {
      await _api('file/delete?$_pr', {
        'action_type': 2,
        'filelist': (listData['data']['list'] as List)
            .map((v) => (v as Map)['fid'].toString())
            .toList(),
        'exclude_fids': [],
      }, 'post');
    }
  }

  Future<void> _createSaveDir({bool clean = false}) async {
    if (_saveDirId != null) {
      if (clean) await _clearSaveDir();
      return;
    }

    final listData = await _api(
      'file/sort?$_pr&pdir_fid=0&_page=1&_size=200'
      '&_sort=file_type:asc,updated_at:desc',
      <String, dynamic>{},
      'get',
    );

    if (listData['data'] != null && listData['data']['list'] != null) {
      for (final item in listData['data']['list']) {
        final itemMap = item as Map<String, dynamic>;
        if (itemMap['file_name'] == _saveDirName) {
          _saveDirId = itemMap['fid']?.toString();
          if (clean) await _clearSaveDir();
          break;
        }
      }
    }

    if (_saveDirId == null) {
      final created = await _api('file?$_pr', {
        'pdir_fid': '0',
        'file_name': _saveDirName,
        'dir_path': '',
        'dir_init_lock': false,
      }, 'post');
      if (created['data'] != null && created['data']['fid'] != null) {
        _saveDirId = created['data']['fid']?.toString();
      }
    }
  }

  Future<String?> _save(
    String shareId,
    String stoken,
    String fileId,
    String fileToken,
    bool clean,
  ) async {
    await _createSaveDir(clean: clean);
    if (clean) {
      _saveFileIdCache.clear();
    }
    if (_saveDirId == null) return null;

    var effectiveStoken = stoken;
    if (effectiveStoken.isEmpty) {
      await getShareToken(ShareData(shareId: shareId));
      effectiveStoken = _shareTokenCache[shareId]?['stoken'] ?? '';
      if (effectiveStoken.isEmpty) return null;
    }

    final saveResult = await _api('share/sharepage/save?$_pr', {
      'fid_list': [fileId],
      'fid_token_list': [fileToken],
      'to_pdir_fid': _saveDirId,
      'pwd_id': shareId,
      'stoken': effectiveStoken,
      'pdir_fid': '0',
      'scene': 'link',
    }, 'post');

    if (saveResult['data'] != null &&
        saveResult['data']['task_id'] != null) {
      var retry = 0;
      while (retry <= 2) {
        final taskResult = await _api(
          'task?$_pr&task_id=${saveResult['data']['task_id']}&retry_index=$retry',
          <String, dynamic>{},
          'get',
        );
        if (taskResult['data'] != null &&
            taskResult['data']['save_as'] != null &&
            taskResult['data']['save_as']['save_as_top_fids'] != null &&
            (taskResult['data']['save_as']['save_as_top_fids'] as List)
                .isNotEmpty) {
          return (taskResult['data']['save_as']['save_as_top_fids'] as List)
              .first
              .toString();
        }
        retry++;
        if (retry <= 2) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    }
    return null;
  }

  // ── Internal: cookie helpers ───────────────────────────────────────

  String _getCurrentCookie() {
    final cookieMap = MClient.getCookiesPref(_host);
    return cookieMap.isNotEmpty ? cookieMap.values.first : '';
  }

  Map<String, String> _getHeaders() {
    return {
      'User-Agent': _userAgent,
      'Referer': _refererUrl,
      'Content-Type': 'application/json',
      'Cookie': _getCurrentCookie(),
    };
  }

  void _setCookiesIfChanged(String cookie) {
    if (cookie.isEmpty) return;
    if (_lastCookie == cookie) return;
    MClient.setCookie(_host, _userAgent, null, cookie: cookie);
    MClient.setCookie(_cookieKey, _userAgent, null, cookie: cookie);
    _lastCookie = cookie;
  }

  // ── Internal: HTTP client ──────────────────────────────────────────

  /// Make an API request to the UC drive backend.
  ///
  /// Automatically sets cookies and handles `__puus` refresh from
  /// `set-cookie` response headers.
  Future<Map<String, dynamic>> _api(
    String url,
    dynamic data,
    String method,
  ) async {
    final client = MClient.init(
      reqcopyWith: {'useDartHttpClient': true},
    );

    late Response resp;

    if (method != 'get') {
      resp = await client.post(
        Uri.parse(_apiBase + url),
        body: data != null ? jsonEncode(data) : null,
        headers: _getHeaders(),
      );
    } else {
      resp = await client.get(
        Uri.parse(_apiBase + url),
        headers: _getHeaders(),
      );
    }

    // Handle set-cookie: refresh __puus if the server sends an updated value.
    if (resp.headers['set-cookie'] != null) {
      final cookiesHeader = resp.headers['set-cookie']!;
      final cookieParts = cookiesHeader.split(';;;');
      for (final part in cookieParts) {
        if (part.contains('__puus=')) {
          final newPuus = part.split(';')[0]; // e.g. "__puus=xxxx"
          var currentCookie = _getCurrentCookie();
          if (currentCookie.isNotEmpty) {
            if (currentCookie.contains('__puus=')) {
              currentCookie = currentCookie.replaceFirst(
                RegExp(r'__puus=[^;]+'),
                newPuus,
              );
            } else {
              currentCookie = '$currentCookie; $newPuus';
            }
            MClient.setCookie(_host, _userAgent, null, cookie: currentCookie);
          }
          break;
        }
      }
    }

    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ── Internal: string helpers ───────────────────────────────────────

  String _removeExt(String text) {
    final dot = text.lastIndexOf('.');
    return dot > 0 ? text.substring(0, dot) : text;
  }
}
