import 'dart:convert';
import 'package:mangayomi/services/http/m_client.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';

/// Result of a QR login flow step.
class QrLoginResult {
  final String? qrImageUrl;
  final String? status;
  final String? cookie;
  final String? token;
  final Map<String, dynamic>? stateData;
  final String? error;

  const QrLoginResult({
    this.qrImageUrl,
    this.status,
    this.cookie,
    this.token,
    this.stateData,
    this.error,
  });

  bool get isSuccess => cookie != null || token != null;
}

/// Platform-specific QR login flows, ported from drpy-node's core.js.
class QrLoginFlow {
  static String generateUUID() {
    // Generate a proper UUID v4
    final r = DateTime.now().microsecondsSinceEpoch;
    final bytes = List<int>.generate(16, (i) => (r >> (i * 4)) & 0xff);
    // Set version (4) and variant bits
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    // Format as xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    return '${_hex(bytes, 0, 4)}-${_hex(bytes, 4, 2)}-${_hex(bytes, 6, 2)}-${_hex(bytes, 8, 2)}-${_hex(bytes, 10, 6)}';
  }

  static String _hex(List<int> bytes, int start, int count) {
    return bytes.sublist(start, start + count).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Start QR scan for the given platform.
  static Future<QrLoginResult> startScan(CloudDriveType type) async {
    switch (type) {
      case CloudDriveType.quark:
        return _startQuarkScan();
      case CloudDriveType.ali:
        return _startAliScan();
      case CloudDriveType.baidu:
        return _startBaiduScan();
      case CloudDriveType.uc:
        return _startUCScan();
      case CloudDriveType.pan123:
      case CloudDriveType.cloud189:
      case CloudDriveType.yun139:
      case CloudDriveType.xunlei:
        return const QrLoginResult(error: '此平台不支持扫码登录');
    }
  }

  /// Check QR scan status. Call periodically.
  static Future<QrLoginResult> checkStatus(
    CloudDriveType type,
    Map<String, dynamic> stateData,
  ) async {
    switch (type) {
      case CloudDriveType.quark:
        return _checkQuarkStatus(stateData);
      case CloudDriveType.ali:
        return _checkAliStatus(stateData);
      case CloudDriveType.baidu:
        return _checkBaiduStatus(stateData);
      case CloudDriveType.uc:
        return _checkUCStatus(stateData);
      default:
        return const QrLoginResult(error: '不支持此平台');
    }
  }

  // ── Quark ─────────────────────────────────────────────────────────

  static Future<QrLoginResult> _startQuarkScan() async {
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    final requestId = generateUUID();
    final res = await client.get(
      Uri.parse('https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?request_id=$requestId&client_id=532&v=1.2'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
    );
    final data = jsonDecode(res.body);
    final token = data['data']?['members']?['token'] as String?;
    if (token == null) {
      return const QrLoginResult(error: '获取二维码失败');
    }
    // Save cookies from start scan — these _UP_* cookies are needed
    // for subsequent requests in _checkQuarkStatus.
    final startCookies = _extractSetCookie(res.headers);
    final qrUrl = 'https://su.quark.cn/4_eMHBJ?token=$token&client_id=532&ssb=weblogin&uc_param_str=&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400';
    return QrLoginResult(
      qrImageUrl: 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${Uri.encodeComponent(qrUrl)}',
      status: 'NEW',
      stateData: {'token': token, 'request_id': requestId, 'startCookies': startCookies},
    );
  }

  static Future<QrLoginResult> _checkQuarkStatus(Map<String, dynamic> state) async {
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    final token = state['token'] as String;
    final requestId = state['request_id'] as String;
    // Cookies from the start scan (must be sent with subsequent requests)
    final startCookies = state['startCookies'] as String? ?? '';

    final res = await client.get(
      Uri.parse('https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?request_id=$requestId&client_id=532&v=1.2&token=$token'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36',
        'Accept': 'application/json, text/plain, */*',
        if (startCookies.isNotEmpty) 'Cookie': startCookies,
      },
    );
    final data = jsonDecode(res.body);
    final status = data['status'];
    if (status == 2000000) {
      // Scanned — exchange serviceTicket for cookies
      final ticket = data['data']?['members']?['service_ticket'] as String?;
      if (ticket == null) return const QrLoginResult(status: 'NEW');
      // Build combined cookie from all sources
      final combinedCookie = StringBuffer(startCookies.isNotEmpty ? '$startCookies; ' : '');
      final cookieRes = await client.get(
        Uri.parse('https://pan.quark.cn/account/info?st=$ticket&lw=scan'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36',
          'Accept': 'application/json, text/plain, */*',
          if (combinedCookie.isNotEmpty) 'Cookie': combinedCookie.toString(),
        },
      );
      final exchangeCookies = _extractSetCookie(cookieRes.headers);
      if (exchangeCookies != null) combinedCookie.write(exchangeCookies);
      // Second request to get drive-specific cookies
      final driveRes = await client.get(
        Uri.parse(
          'https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=0&_page=1&_size=50&_sort=file_type:asc,updated_at:desc',
        ),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36',
          'Accept': 'application/json, text/plain, */*',
          'Cookie': combinedCookie.toString(),
          'Origin': 'https://pan.quark.cn',
          'Referer': 'https://pan.quark.cn/',
        },
      );
      final driveCookies = _extractSetCookie(driveRes.headers);
      if (driveCookies != null) combinedCookie.write('; $driveCookies');
      return QrLoginResult(cookie: combinedCookie.toString(), status: 'CONFIRMED');
    } else if (status == 50004002) {
      return const QrLoginResult(status: 'EXPIRED');
    } else {
      return const QrLoginResult(status: 'NEW');
    }
  }

  // ── UC (same pattern as Quark, different URLs) ────────────────────

  static Future<QrLoginResult> _startUCScan() async {
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    final requestId = generateUUID();
    final res = await client.get(
      Uri.parse('https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin?v=1.2&request_id=$requestId&client_id=381'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
    );
    final data = jsonDecode(res.body);
    final token = data['data']?['members']?['token'] as String?;
    if (token == null) return const QrLoginResult(error: '获取二维码失败');
    final qrUrl = 'https://su.uc.cn/1_n0ZCv?token=$token&client_id=381&uc_param_str=&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix';
    return QrLoginResult(
      qrImageUrl: 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${Uri.encodeComponent(qrUrl)}',
      status: 'NEW',
      stateData: {'token': token, 'request_id': requestId},
    );
  }

  static Future<QrLoginResult> _checkUCStatus(Map<String, dynamic> state) async {
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    final token = state['token'] as String;
    final requestId = state['request_id'] as String;
    final res = await client.get(
      Uri.parse('https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken?request_id=$requestId&client_id=381&v=1.2&token=$token'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
    );
    final data = jsonDecode(res.body);
    final status = data['status'];
    if (status == 2000000) {
      final ticket = data['data']?['members']?['service_ticket'] as String?;
      if (ticket == null) return const QrLoginResult(status: 'NEW');
      final cookieRes = await client.get(
        Uri.parse('https://drive.uc.cn/account/info?st=$ticket&lw=scan'),
        headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36'},
      );
      final cookies = _extractSetCookie(cookieRes.headers);
      return QrLoginResult(cookie: cookies, status: 'CONFIRMED');
    } else if (status == 50004002) {
      return const QrLoginResult(status: 'EXPIRED');
    } else {
      return const QrLoginResult(status: 'NEW');
    }
  }

  // ── AliDrive ──────────────────────────────────────────────────────

  static Future<QrLoginResult> _startAliScan() async {
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    final res = await client.get(
      Uri.parse('https://passport.aliyundrive.com/newlogin/qrcode/generate.do?appName=aliyun_drive&fromSite=52&appEntrance=web&isMobile=false&lang=zh_CN'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
    );
    final data = jsonDecode(res.body);
    final content = data['data']?['content']?['data'];
    if (content == null) return const QrLoginResult(error: '获取二维码失败');
    final qrContent = content['codeContent'] as String?;
    final ck = content['ck'] as String?;
    final t = content['t'] as String?;
    if (qrContent == null || ck == null || t == null) {
      return const QrLoginResult(error: '获取二维码参数失败');
    }
    return QrLoginResult(
      qrImageUrl: 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${Uri.encodeComponent(qrContent)}',
      status: 'NEW',
      stateData: {'ck': ck, 't': t},
    );
  }

  static Future<QrLoginResult> _checkAliStatus(Map<String, dynamic> state) async {
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    final ck = state['ck'] as String;
    final t = state['t'] as String;
    final res = await client.get(
      Uri.parse('https://passport.aliyundrive.com/newlogin/qrcode/query.do?appName=aliyun_drive&fromSite=52&isMobile=false&lang=zh_CN&ck=$ck&t=$t'),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36',
        'Accept': 'application/json, text/plain, */*',
      },
    );
    final data = jsonDecode(res.body);
    final status = data['data']?['content']?['data']?['qrCodeStatus'] as String?;
    if (status == 'CONFIRMED') {
      final bizExtB64 = data['data']?['content']?['data']?['bizExt'] as String?;
      if (bizExtB64 != null) {
        try {
          final bizExt = jsonDecode(utf8.decode(base64Decode(bizExtB64)));
          final refreshToken = bizExt['pds_login_result']?['refreshToken'] as String?;
          if (refreshToken != null) {
            return QrLoginResult(token: refreshToken, status: 'CONFIRMED');
          }
        } catch (_) {}
      }
      return const QrLoginResult(status: 'EXPIRED');
    } else if (status == 'SCANED') {
      return const QrLoginResult(status: 'SCANED');
    } else if (status == 'CANCELED') {
      return const QrLoginResult(status: 'CANCELED');
    } else if (status == 'NEW') {
      return const QrLoginResult(status: 'NEW');
    }
    return const QrLoginResult(status: 'NEW');
  }

  // ── Baidu ─────────────────────────────────────────────────────────

  static Future<QrLoginResult> _startBaiduScan() async {
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    final requestId = generateUUID();
    final t3 = DateTime.now().millisecondsSinceEpoch.toString();
    final res = await client.get(
      Uri.parse(
        'https://passport.baidu.com/v2/api/getqrcode?lp=pc&qrloginfrom=pc&gid=$requestId&apiver=v3&tt=$t3&tpl=netdisk&_=$t3',
      ),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://pan.baidu.com/',
      },
    );
    final data = jsonDecode(res.body);
    final imgUrl = data['data']?['imgurl'] as String?;
    final channelId = data['data']?['sign'] as String?;
    if (imgUrl == null || channelId == null) {
      return const QrLoginResult(error: '获取二维码失败');
    }
    return QrLoginResult(
      qrImageUrl: 'https://$imgUrl',
      status: 'NEW',
      stateData: {'channel_id': channelId, 'request_id': requestId, 't3': t3},
    );
  }

  static Future<QrLoginResult> _checkBaiduStatus(Map<String, dynamic> state) async {
    final client = MClient.init(reqcopyWith: {'useDartHttpClient': true});
    final channelId = state['channel_id'] as String;
    final requestId = state['request_id'] as String;
    final t3 = state['t3'] as String;
    final res = await client.get(
      Uri.parse(
        'https://passport.baidu.com/channel/unicast?channel_id=$channelId&gid=$requestId&tpl=netdisk&apiver=v3&tt=$t3&_=$t3',
      ),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Referer': 'https://pan.baidu.com/',
      },
    );
    final data = jsonDecode(res.body);
    final channelV = data['data']?['channel_v'] as String?;
    if (channelV != null) {
      try {
        final bdData = jsonDecode(channelV);
        final bduss = bdData['v'] as String?;
        if (bduss != null) {
          // Exchange BDUSS for full cookies
          final cookieRes = await client.post(
            Uri.parse('https://passport.baidu.com/v3/login/main/qrbdusslogin'),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
              'Referer': 'https://pan.baidu.com/',
            },
            body: 'bduss=$bduss&u=https://pan.baidu.com/',
          );
          final cookies = _extractSetCookie(cookieRes.headers);
          return QrLoginResult(cookie: cookies, status: 'CONFIRMED');
        }
      } catch (_) {}
    }
    return const QrLoginResult(status: 'NEW');
  }

  // ── Helpers ───────────────────────────────────────────────────────

  /// Extract and format set-cookie headers from response headers.
  static String? _extractSetCookie(Map<String, String> headers) {
    final setCookie = headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) return null;
    // Dart http package joins duplicate headers with newline (\n)
    // Split on newline to get individual set-cookie entries
    final entries = setCookie.split('\n');
    final parts = entries
        .map((c) => c.trim().split(';')[0])
        .where((c) => c.contains('='))
        .toList();
    if (parts.isEmpty) return null;
    return parts.join('; ');
  }
}
