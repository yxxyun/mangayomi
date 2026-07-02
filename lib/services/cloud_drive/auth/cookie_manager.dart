import 'dart:convert';

import 'package:hive_flutter/adapters.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_account.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';

/// Manages cookie/token persistence for cloud drives.
///
/// Uses a Hive box (`cloud_drive_accounts`) to persist account credentials.
/// The box stores a JSON-encoded map keyed by [CloudDriveType.key].
///
/// Utility methods for merging `Set-Cookie` headers and extracting
/// individual cookie values are also provided.
class CloudCookieManager {
  static const boxName = 'cloud_drive_accounts';

  static Box<String>? _box;

  /// Internal helper to open the Hive box lazily.
  static Future<Box<String>> _getBox() async {
    if (_box == null || !_box!.isOpen) {
      _box = await Hive.openBox<String>(boxName);
    }
    return _box!;
  }

  /// ---------- Account-level persistence ----------

  /// Save (or update) the entire [CloudDriveAccount] for [type].
  ///
  /// The account is serialised to JSON and persisted under the drive's key.
  static Future<void> saveAccount(CloudDriveAccount account) async {
    final box = await _getBox();
    await box.put(account.type.key, jsonEncode(account.toJson()));
  }

  /// Retrieve the persisted [CloudDriveAccount] for [type], or `null`.
  static Future<CloudDriveAccount?> getAccount(CloudDriveType type) async {
    final box = await _getBox();
    final raw = box.get(type.key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return CloudDriveAccount.fromJson(json, type);
    } catch (_) {
      return null;
    }
  }

  /// Remove all persisted data for [type].
  static Future<void> deleteAccount(CloudDriveType type) async {
    final box = await _getBox();
    await box.delete(type.key);
  }

  /// ---------- Convenience cookie / token helpers ----------

  /// Save a cookie string for [type].
  ///
  /// Loads the existing account (or creates a new one), updates its
  /// [CloudDriveAccount.cookie] and persists it.
  static Future<void> saveCookie(CloudDriveType type, String cookie) async {
    final existing = await getAccount(type);
    final account = existing ??
        CloudDriveAccount(
          type: type,
          lastLoginAt: DateTime.now(),
        );
    account.cookie = cookie;
    account.lastLoginAt = DateTime.now();
    await saveAccount(account);
  }

  /// Retrieve the saved cookie for [type], or `null`.
  static Future<String?> getCookie(CloudDriveType type) async {
    final account = await getAccount(type);
    return account?.cookie;
  }

  /// Save a token for [type].
  static Future<void> saveToken(CloudDriveType type, String token) async {
    final existing = await getAccount(type);
    final account = existing ??
        CloudDriveAccount(
          type: type,
          lastLoginAt: DateTime.now(),
        );
    account.token = token;
    account.lastLoginAt = DateTime.now();
    await saveAccount(account);
  }

  /// Retrieve the saved token for [type], or `null`.
  static Future<String?> getToken(CloudDriveType type) async {
    final account = await getAccount(type);
    return account?.token;
  }

  /// Save a refresh token for [type].
  static Future<void> saveRefreshToken(
    CloudDriveType type,
    String refreshToken,
  ) async {
    final existing = await getAccount(type);
    final account = existing ??
        CloudDriveAccount(
          type: type,
          lastLoginAt: DateTime.now(),
        );
    account.refreshToken = refreshToken;
    account.lastLoginAt = DateTime.now();
    await saveAccount(account);
  }

  /// Retrieve the saved refresh token for [type], or `null`.
  static Future<String?> getRefreshToken(CloudDriveType type) async {
    final account = await getAccount(type);
    return account?.refreshToken;
  }

  /// Clear all credentials (cookie, token, refresh token) for [type].
  static Future<void> clear(CloudDriveType type) async {
    await deleteAccount(type);
  }

  /// Returns `true` if [type] has a stored account that is logged in.
  static Future<bool> isLoggedIn(CloudDriveType type) async {
    final account = await getAccount(type);
    return account?.isLoggedIn ?? false;
  }

  /// Mark [type] as logged in / logged out.
  static Future<void> setLoggedIn(
    CloudDriveType type,
    bool value,
  ) async {
    final existing = await getAccount(type);
    final account = existing ??
        CloudDriveAccount(
          type: type,
          lastLoginAt: DateTime.now(),
        );
    account.isLoggedIn = value;
    if (value) account.lastLoginAt = DateTime.now();
    await saveAccount(account);
  }

  /// ---------- Cookie string utilities ----------

  /// Parse a `Set-Cookie` header and merge it into an existing cookie string.
  ///
  /// Existing cookie name-value pairs are kept unless the `Set-Cookie` header
  /// provides a newer value for the same name or explicitly expires it.
  ///
  /// The [setCookieHeader] can be a single `Set-Cookie` value or a
  /// multi-cookie string (e.g. from a concatenated header).
  static String mergeSetCookie(
    String existingCookie,
    String setCookieHeader,
  ) {
    // Split on ';;;' (Quark/UC convention) or standard ';' boundaries
    final setCookies = setCookieHeader
        .split(';;;')
        .expand((part) => part.split(RegExp(r',(?=[^;]+=)')))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);

    // Parse existing into a map
    final cookieMap = <String, String>{};
    for (final pair in existingCookie.split(';')) {
      final trimmed = pair.trim();
      final eqIndex = trimmed.indexOf('=');
      if (eqIndex > 0) {
        cookieMap[trimmed.substring(0, eqIndex).trim()] =
            trimmed.substring(eqIndex + 1).trim();
      }
    }

    // Apply Set-Cookie directives
    for (final setCookie in setCookies) {
      // The first name=value pair is the actual cookie
      final parts = setCookie.split(';');
      if (parts.isEmpty) continue;
      final first = parts.first.trim();
      final eqIndex = first.indexOf('=');
      if (eqIndex <= 0) continue;
      final name = first.substring(0, eqIndex).trim();
      final value = first.substring(eqIndex + 1).trim();

      if (value.isEmpty ||
          value == '""' ||
          parts.any((p) => p.trim().toLowerCase() == 'max-age=0')) {
        // Expired / deletion signal
        cookieMap.remove(name);
      } else {
        cookieMap[name] = value;
      }
    }

    return cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// Extract the value of a specific cookie by [name] from [cookieString].
  ///
  /// Returns `null` if the cookie is not present.
  ///
  /// Example:
  /// ```dart
  /// CloudCookieManager.extractCookieValue('session=abc; theme=dark', 'theme')
  /// // → 'dark'
  /// ```
  static String? extractCookieValue(
    String cookieString,
    String name,
  ) {
    for (final pair in cookieString.split(';')) {
      final trimmed = pair.trim();
      final eqIndex = trimmed.indexOf('=');
      if (eqIndex > 0 &&
          trimmed.substring(0, eqIndex).trim() == name) {
        return trimmed.substring(eqIndex + 1).trim();
      }
    }
    return null;
  }
}
