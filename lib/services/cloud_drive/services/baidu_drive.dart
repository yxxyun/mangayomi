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

/// Baidu Drive (百度网盘) cloud drive service implementation.
///
/// ### Auth
/// Cookie-based. Required cookies: `BDUSS`, `STOKEN`, `BAIDUID`.
/// After share verification a `BDCLND` cookie (from `randsk`) is added.
///
/// ### Share URLs
/// `https://pan.baidu.com/s/{shareId}?pwd=xxxx`
/// or short form `https://pan.baidu.com/s/{surl}`
///
/// ### Encoded video URL format (passed to [getVideos])
/// ```text
/// displayName$baidu++fileId++++shareId++
/// ```
/// Additional data (`uk`, api `shareid`, `randsk`) is looked up from
/// the in-memory share-token cache. The cache is populated during
/// [getShareToken] / [getFilesByShareUrl].
class BaiduDriveService implements CloudDriveService {
  // ── Constants ───────────────────────────────────────────────────────

  static const String _apiBase = 'https://pan.baidu.com/';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const String _refererUrl = 'https://pan.baidu.com';
  static const String _host = 'https://pan.baidu.com';
  static const String _cookieKey = 'https://baiducookie.last';
  static const String _saveDirName = 'drpy';
  static const int _appId = 250528;

  static const List<String> _subtitleExts = [
    '.srt',
    '.ass',
    '.scc',
    '.stl',
    '.ttml',
  ];

  static const List<String> _videoExts = [
    '.mp4',
    '.mkv',
    '.avi',
    '.rmvb',
    '.mov',
    '.flv',
    '.wmv',
    '.webm',
    '.3gp',
    '.mpeg',
    '.mpg',
    '.ts',
    '.mts',
    '.m2ts',
    '.vob',
    '.divx',
    '.xvid',
    '.m4v',
    '.ogv',
    '.f4v',
    '.rm',
    '.asf',
    '.dat',
    '.dv',
    '.m2v',
  ];

  // ── State ──────────────────────────────────────────────────────────

  CloudDriveAccount _account = CloudDriveAccount(
    type: CloudDriveType.baidu,
  );

  /// Share-token cache keyed by URL shareId (the `surl`).
  /// Each entry holds `uk`, `shareid`, `randsk` and the initial file `list`.
  final Map<String, Map<String, dynamic>> _shareTokenCache = {};

  /// Mapping from file `fs_id` to original filename, populated during
  /// recursive listing. Used by [getDownload] to construct the full path.
  final Map<String, String> _fileNameCache = {};

  /// The `/drpy` save directory `fs_id` (lazy-created).
  String? _saveDirId;

  /// Last cookie value we set — avoids redundant MClient.setCookie calls.
  String _lastCookie = '';

  // ── Interface: getters ─────────────────────────────────────────────

  @override
  CloudDriveType get type => CloudDriveType.baidu;

  @override
  CloudDriveAccount get account => _account;

  @override
  bool get isLoggedIn => _account.isLoggedIn;

  // ── Interface: lifecycle ───────────────────────────────────────────

  @override
  Future<void> initialize() async {
    final saved = await CloudCookieManager.getAccount(CloudDriveType.baidu);
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

    // Verify by calling a lightweight endpoint that requires auth.
    try {
      await _api(
        'api/gettemplatevariable'
        '?clienttype=0&app_id=$_appId&web=1'
        '&fields=${Uri.encodeComponent('["bdstoken"]')}',
        <String, dynamic>{},
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
      'QR login is not yet supported for BaiduDrive.',
    );
  }

  @override
  Future<void> logout() async {
    _account = CloudDriveAccount(type: CloudDriveType.baidu);
    _lastCookie = '';
    _shareTokenCache.clear();
    _fileNameCache.clear();
    _saveDirId = null;

    await MClient.deleteAllCookies(_host);
    await MClient.deleteAllCookies(_cookieKey);
    await CloudCookieManager.clear(CloudDriveType.baidu);
  }

  @override
  void dispose() {
    _shareTokenCache.clear();
    _fileNameCache.clear();
  }

  // ── Interface: share parsing & token ───────────────────────────────

  @override
  ShareData? parseShareUrl(String url) {
    try {
      url = Uri.decodeComponent(url).replaceAll(RegExp(r'\s+'), '');
      final match =
          RegExp(r'pan\.baidu\.com\/(s\/|wap\/init\?surl=)([^?&#]+)')
              .firstMatch(url);
      if (match == null) return null;

      var shareId = match.group(2)!;
      // Strip leading `1` characters as seen in some short-url formats.
      shareId = shareId.replaceAll(RegExp(r'^1+'), '');
      shareId = shareId.split('?')[0].split('#')[0];
      if (shareId.isEmpty) return null;

      // Extract optional password: 提取码=xxxx, 密码=xxxx, or pwd=xxxx
      final pwdMatch =
          RegExp(r'(提取码|密码|pwd)=([^&\s]{4})', caseSensitive: false)
              .firstMatch(url);
      final sharePwd = pwdMatch?.group(2) ?? '';

      return ShareData(
        shareId: shareId,
        sharePwd: sharePwd.isNotEmpty ? sharePwd : null,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> getShareToken(ShareData shareData) async {
    if (_shareTokenCache.containsKey(shareData.shareId)) return true;

    // Remove any stale entry.
    _shareTokenCache.remove(shareData.shareId);

    try {
      // 1. Obtain sign from tplconfig.
      final sign = await _getSign(shareData.shareId);

      // 2. Verify share password (yields randsk / BDCLND).
      final shareVerify = await _api(
        'share/verify?$sign&channel=chunlei&clienttype=0&web=1',
        {'pwd': shareData.sharePwd ?? ''},
        'post',
      );

      if (shareVerify['errno'] != 0) return false;

      // 3. Persist BDCLND from randsk into the cookie.
      final randsk = shareVerify['randsk']?.toString();
      if (randsk != null && randsk.isNotEmpty) {
        _updateCookieWithBDCLND(randsk);
      }

      // 4. Fetch the root file list (provides uk, share_id, and items).
      //    Baidu's API uses `shorturl` = shareId with first char removed.
      final shorturl = shareData.shareId.isNotEmpty
          ? shareData.shareId.substring(1)
          : '';

      final listData = await _api(
        'share/list'
        '?$sign&channel=chunlei&clienttype=0&web=1'
        '&shorturl=$shorturl&root=1&page=1&num=100',
        <String, dynamic>{},
        'get',
      );

      if (listData['errno'] != 0) return false;

      _shareTokenCache[shareData.shareId] = {
        'uk': listData['uk'] ?? listData['share_uk'],
        'shareid': listData['share_id'] ?? shareVerify['share_id'],
        'randsk': randsk ?? '',
        'list': listData['list'] ?? [],
        'sharePwd': shareData.sharePwd ?? '',
      };

      return true;
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
    final subtitles = <CloudDriveFile>[];

    await _listFilesRecursive(
      shareData: shareData,
      videos: videos,
      subtitles: subtitles,
    );

    // Subtitle matching is deferred to getVideos time, where subtitles
    // are looked up by matching filenames against _fileNameCache.

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
    final saved = await _save(shareId, fileId);
    if (!saved) return null;
    return _saveDirId;
  }

  // ── Interface: transcoding / download ──────────────────────────────

  @override
  Future<List<QualityOption>> getLiveTranscoding({
    required String shareId,
    required String stoken,
    required String fileId,
    required String fileToken,
  }) async {
    // Baidu does not expose a straightforward DASH / HLS transcoding API
    // equivalent to Quark/UC. The `share/streaming` endpoint from baidu2.js
    // provides adaptive streaming for some file types. We return an empty
    // list so callers fall back to [getDownload].
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
    // Resolve the original filename.
    final filename = _fileNameCache[fileId];
    if (filename == null) return null;

    // Ensure the file is saved to personal drive first.
    final saved = await _save(shareId, fileId);
    if (!saved) return null;

    return _fetchDownloadLink(shareId, fileId, filename);
  }

  // ── Interface: videos ──────────────────────────────────────────────

  @override
  Future<List<Video>> getVideos(String encodedUrl) async {
    // Standard encoded URL format from getEpisodeUrl:
    //   displayName$baidu++fileId++++shareId++[subtitleData]
    final parts = encodedUrl.split('++');
    if (parts.length < 4) return [];

    final fileId = parts[1];
    final shareId = parts[3];

    // Subtitle info (optional, parts[4] when shareToken is set).
    final subtitlePart = parts.length > 4 ? parts[4] : '';
    final subtitleInfos =
        subtitlePart.isNotEmpty ? subtitlePart.split('+') : <String>[];

    // Look up cached share-token data.
    final cacheEntry = _shareTokenCache[shareId];
    if (cacheEntry == null) return [];

    // Save file to personal drive first.
    final saved = await _save(shareId, fileId);
    if (!saved) return [];

    // Resolve filename from cache.
    final filename = _fileNameCache[fileId];
    if (filename == null) return [];

    // Fetch download link.
    final dlResult = await _fetchDownloadLink(shareId, fileId, filename);
    if (dlResult == null || dlResult['dlink'] == null) return [];

    final dlink = dlResult['dlink'].toString();
    final headers = _getHeaders();

    final videos = <Video>[
      Video(
        dlink,
        'original',
        dlink,
        headers: Map<String, String>.from(headers),
      ),
    ];

    // Attach subtitles.
    if (subtitleInfos.isNotEmpty) {
      final tracks = <Track>[];
      for (final info in subtitleInfos) {
        if (info.isEmpty) continue;
        final subParts = info.split('@@@');
        if (subParts.length != 3) continue;
        final subName = subParts[0];
        final subFileId = subParts[2];

        final subDl = await _fetchDownloadLink(shareId, subFileId, subName);
        final subUrl = subDl?['dlink']?.toString();
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
        'api/gettemplatevariable'
        '?clienttype=0&app_id=$_appId&web=1'
        '&fields=${Uri.encodeComponent('["bdstoken"]')}',
        <String, dynamic>{},
        'get',
      );

      // Persist any cookie changes that occurred.
      final current = _getCurrentCookie();
      if (current.isNotEmpty && current != _account.cookie) {
        _account.cookie = current;
        _account.lastLoginAt = DateTime.now();
        await CloudCookieManager.saveAccount(_account);
      }

      return result['errno'] == 0;
    } catch (_) {
      return false;
    }
  }

  // ── Internal: sign ─────────────────────────────────────────────────

  /// Obtain a `sign` token from the Baidu tplconfig endpoint.
  ///
  /// The sign is needed for most share/* API calls.
  Future<String> _getSign(String surl) async {
    try {
      final result = await _api(
        'share/tplconfig'
        '?surl=$surl'
        '&fields=${Uri.encodeComponent('sign,timestamp')}'
        '&channel=chunlei&clienttype=0&web=1',
        <String, dynamic>{},
        'get',
      );
      if (result['data'] != null && result['data']['sign'] != null) {
        return 'sign=${result['data']['sign']}'
            '&timestamp=${result['data']['timestamp']}';
      }
    } catch (_) {
      // Fall through.
    }
    // Fallback: use a timestamp-based query (as seen in baidu.js).
    return 't=${DateTime.now().millisecondsSinceEpoch}';
  }

  // ── Internal: verify & share data ──────────────────────────────────

  /// Update the stored cookie so `BDCLND` is set to [randsk].
  ///
  /// `BDCLND` is required by Baidu's share/list and share/transfer APIs.
  void _updateCookieWithBDCLND(String randsk) {
    var current = _getCurrentCookie();
    if (current.isEmpty) return;

    // Remove any existing BDCLND, then append the new one.
    current = current.replaceAll(RegExp(r'BDCLND=[^;]*;?\s*'), '');
    current = current.trim();
    if (current.isNotEmpty && !current.endsWith(';')) {
      current = '$current; ';
    }
    current = '$current BDCLND=$randsk';

    _setCookiesIfChanged(current);

    // Also update the account object so it's persisted on next save.
    _account.cookie = current;
  }

  // ── Internal: recursive file listing ───────────────────────────────

  /// Walk the share directory tree recursively.
  ///
  /// The root-level file list comes from the share-token cache (populated
  /// during [getShareToken]). Sub-directories are fetched via the
  /// `share/list` API with a special `dir` path format:
  /// `/sharelink{api_shareid}-{dirFsId}{relativePath}`.
  Future<void> _listFilesRecursive({
    required ShareData shareData,
    required List<CloudDriveFile> videos,
    required List<CloudDriveFile> subtitles,
    String dirPath = '',
    String? dirFsId,
    String? parentDrpyPath,
  }) async {
    final shareId = shareData.shareId;
    final cacheEntry = _shareTokenCache[shareId];
    if (cacheEntry == null) return;

    final apiShareId = cacheEntry['shareid']?.toString() ?? '';
    final uk = cacheEntry['uk']?.toString() ?? '';
    final randsk = cacheEntry['randsk']?.toString() ?? '';

    // List of items to process: root-level comes from cache, sub-dirs
    // are fetched from the API.
    List<Map<String, dynamic>> items;

    if (dirPath.isEmpty) {
      // Root level — use the cached list from getShareToken.
      items = (cacheEntry['list'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    } else {
      // Sub-directory — fetch from API with the special dir format.
      final shareDir =
          '/sharelink$apiShareId-$dirFsId$dirPath';
      final listData = await _api(
        'share/list'
        '?channel=chunlei&clienttype=0&web=1'
        '&sekey=${Uri.encodeComponent(randsk)}'
        '&uk=$uk&shareid=$apiShareId'
        '&page=1&num=100'
        '&dir=${Uri.encodeComponent(shareDir)}',
        <String, dynamic>{},
        'get',
      );
      if (listData['errno'] != 0 || listData['list'] == null) return;
      items = (listData['list'] as List).cast<Map<String, dynamic>>();
    }

    final subDirs = <Map<String, dynamic>>[];

    for (final item in items) {
      final isDir = item['isdir'] == 1 || item['isdir'] == '1';
      final fileName = item['server_filename']?.toString() ?? '';
      final fsId = item['fs_id']?.toString() ?? '';

      if (isDir) {
        subDirs.add(item);
      } else {
        final ext = _getExt(fileName).toLowerCase();
        final fileInfo = CloudDriveFile(
          fileId: fsId,
          name: fileName,
          size: item['size']?.toString(),
          shareId: shareId,
          shareFileToken: '',
          shareToken: '',
          parent: parentDrpyPath,
          driveType: CloudDriveType.baidu,
        );

        // Track the filename for later download-link resolution.
        _fileNameCache[fsId] = fileName;

        if (_videoExts.contains(ext)) {
          videos.add(fileInfo);
        } else if (_subtitleExts.contains(ext)) {
          subtitles.add(fileInfo);
        }
      }
    }

    // Recurse into subdirectories.
    final effectiveParent = parentDrpyPath ?? '';
    for (final dir in subDirs) {
      final dirName = dir['server_filename']?.toString() ?? '';
      final subDirPath = dirPath.isEmpty
          ? '/$dirName'
          : '$dirPath/$dirName';
      final subDrpyPath = effectiveParent.isEmpty
          ? '/$dirName'
          : '$effectiveParent/$dirName';
      final subDirFsId = dir['fs_id']?.toString() ?? '';

      await _listFilesRecursive(
        shareData: shareData,
        videos: videos,
        subtitles: subtitles,
        dirPath: subDirPath,
        dirFsId: subDirFsId,
        parentDrpyPath: subDrpyPath,
      );
    }
  }

  // ── Internal: save dir ─────────────────────────────────────────────

  /// Ensure the `/drpy` save directory exists in the user's personal drive.
  ///
  /// Returns the directory's `fs_id` or `null` on failure.
  Future<String?> _createSaveDir() async {
    if (!_hasCookie()) return null;

    try {
      // List root directory to see if `/drpy` already exists.
      final listResp = await _api(
        'api/list',
        {
          'dir': '/',
          'order': 'name',
          'desc': 0,
          'showempty': 0,
          'web': 1,
          'app_id': _appId,
        },
        'get',
      );

      if (listResp['errno'] == 0 && listResp['list'] != null) {
        for (final item in listResp['list']) {
          final itemMap = item as Map<String, dynamic>;
          if (itemMap['isdir'] == 1 &&
              itemMap['server_filename'] == _saveDirName) {
            _saveDirId = itemMap['fs_id']?.toString();
            return _saveDirId;
          }
        }
      }

      // Create the directory.
      final createResp = await _api(
        'api/create?a=commit&channel=chunlei&clienttype=0&web=1',
        {
          'path': '/$_saveDirName',
          'isdir': 1,
          'block_list': '[]',
          'web': 1,
          'app_id': _appId,
        },
        'post',
      );

      if (createResp['errno'] == 0) {
        _saveDirId = createResp['fs_id']?.toString();
        return _saveDirId;
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  // ── Internal: transfer (save to drive) ─────────────────────────────

  /// Transfer (save) a shared file identified by [fileFsId] into the
  /// user's `/drpy` directory.
  ///
  /// Returns `true` on success. `errno 113` means the file already exists
  /// and is treated as success.
  Future<bool> _save(String shareId, String fileFsId) async {
    if (!_hasCookie()) return false;

    // Ensure save directory exists.
    if (_saveDirId == null) {
      await _createSaveDir();
      if (_saveDirId == null) return false;
    }

    // Ensure share token is available.
    if (!_shareTokenCache.containsKey(shareId)) {
      // Attempt to re-acquire.
      final ok = await getShareToken(ShareData(shareId: shareId));
      if (!ok) return false;
    }

    final tokenData = _shareTokenCache[shareId];
    if (tokenData == null) return false;

    final apiShareId = tokenData['shareid']?.toString() ?? '';
    final uk = tokenData['uk']?.toString() ?? '';
    final randsk = tokenData['randsk']?.toString() ?? '';

    if (apiShareId.isEmpty || uk.isEmpty || randsk.isEmpty) return false;

    try {
      final transferResp = await _api(
        'share/transfer'
        '?shareid=$apiShareId&from=$uk'
        '&sekey=${Uri.encodeComponent(randsk)}'
        '&ondup=newcopy&async=1'
        '&channel=chunlei&web=1&app_id=$_appId',
        {
          'path': '/$_saveDirName',
          'fsidlist': jsonEncode([fileFsId]),
        },
        'post',
      );

      final errno = transferResp['errno'];
      // 0 = success, 113 = file already exists (acceptable).
      return errno == 0 || errno == 113;
    } catch (_) {
      return false;
    }
  }

  // ── Internal: download link ────────────────────────────────────────

  /// Fetch a downloadable `dlink` for a file that has already been saved
  /// to the user's personal drive.
  Future<Map<String, dynamic>?> _fetchDownloadLink(
    String shareId,
    String fileId,
    String filename,
  ) async {
    if (!_hasCookie()) return null;

    final fullPath = '/$_saveDirName/$filename';
    final headers = _getHeaders();

    // Try api/mediainfo first (provides M3U8 dlink).
    try {
      final mediaInfo = await _api(
        'api/mediainfo',
        {
          'type': 'M3U8_FLV_264_480',
          'path': fullPath,
          'clienttype': 80,
          'origin': 'dlna',
        },
        'get',
      );
      if (mediaInfo['info']?['dlink'] != null) {
        return {
          'dlink': mediaInfo['info']['dlink'],
          'headers': headers,
          'full_path': fullPath,
        };
      }
    } catch (_) {
      // Fall through to api/download.
    }

    // Fallback: api/download.
    try {
      final downloadInfo = await _api(
        'api/download',
        {
          'type': 'download',
          'path': fullPath,
          'app_id': _appId,
        },
        'get',
      );
      if (downloadInfo['info']?['dlink'] != null) {
        return {
          'dlink': downloadInfo['info']['dlink'],
          'headers': headers,
          'is_direct': true,
          'full_path': fullPath,
        };
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  // ── Internal: cookie helpers ───────────────────────────────────────

  bool _hasCookie() =>
      _getCurrentCookie().isNotEmpty;

  String _getCurrentCookie() {
    final cookieMap = MClient.getCookiesPref(_host);
    return cookieMap.isNotEmpty ? cookieMap.values.first : '';
  }

  void _setCookiesIfChanged(String cookie) {
    if (cookie.isEmpty) return;
    if (_lastCookie == cookie) return;

    MClient.setCookie(_host, _userAgent, null, cookie: cookie);
    MClient.setCookie(_cookieKey, _userAgent, null, cookie: cookie);
    _lastCookie = cookie;
  }

  Map<String, String> _getHeaders() {
    return {
      'User-Agent': _userAgent,
      'Referer': _refererUrl,
      'Content-Type': 'application/x-www-form-urlencoded',
      'Cookie': _getCurrentCookie(),
    };
  }

  // ── Internal: HTTP client ──────────────────────────────────────────

  /// Build a query-string from [data]. Null/empty values are skipped.
  String _toQueryString(Map<String, dynamic> data) {
    return data.entries
        .where((e) =>
            e.value != null &&
            e.value.toString().isNotEmpty)
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
        .join('&');
  }

  /// Make an API request to the Baidu Drive backend.
  ///
  /// For `post` requests the body is sent as `application/x-www-form-urlencoded`.
  /// For `get` requests [data] is appended as query parameters.
  ///
  /// Automatically includes the stored cookie, user-agent, and referer.
  Future<Map<String, dynamic>> _api(
    String url,
    Map<String, dynamic> data,
    String method,
  ) async {
    final client = MClient.init(
      reqcopyWith: {'useDartHttpClient': true},
    );

    final baseUri = Uri.parse('$_apiBase$url');

    late Response resp;

    if (method != 'get') {
      resp = await client.post(
        baseUri,
        body: data.isNotEmpty ? _toQueryString(data) : null,
        headers: _getHeaders(),
      );
    } else {
      // Append query parameters from data.
      var finalUri = baseUri;
      if (data.isNotEmpty) {
        final queryStr = _toQueryString(data);
        final separator = baseUri.query.isNotEmpty ? '&' : '?';
        finalUri = Uri.parse('$baseUri$separator$queryStr');
      }
      resp = await client.get(
        finalUri,
        headers: _getHeaders(),
      );
    }

    // Handle set-cookie: persist any updated cookie values.
    if (resp.headers['set-cookie'] != null) {
      final setCookie = resp.headers['set-cookie']!;
      final current = _getCurrentCookie();
      if (current.isNotEmpty) {
        final merged = CloudCookieManager.mergeSetCookie(current, setCookie);
        if (merged != current) {
          _setCookiesIfChanged(merged);
        }
      }
    }

    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ── Internal: string helpers ───────────────────────────────────────

  String _getExt(String text) {
    final dot = text.lastIndexOf('.');
    return dot > 0 ? text.substring(dot) : '';
  }
}
