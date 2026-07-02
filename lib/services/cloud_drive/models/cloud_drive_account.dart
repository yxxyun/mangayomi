import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';

class CloudDriveAccount {
  final CloudDriveType type;
  String? cookie;
  String? token;
  String? refreshToken;
  String? username;
  String? password;
  DateTime? lastLoginAt;
  DateTime? expiresAt;
  bool isLoggedIn;

  CloudDriveAccount({
    required this.type,
    this.cookie,
    this.token,
    this.refreshToken,
    this.username,
    this.password,
    this.lastLoginAt,
    this.expiresAt,
    this.isLoggedIn = false,
  });

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  Map<String, dynamic> toJson() {
    return {
      'type': type.key,
      'cookie': cookie,
      'token': token,
      'refreshToken': refreshToken,
      'username': username,
      'password': password,
      'lastLoginAt': lastLoginAt?.millisecondsSinceEpoch,
      'expiresAt': expiresAt?.millisecondsSinceEpoch,
      'isLoggedIn': isLoggedIn,
    };
  }

  factory CloudDriveAccount.fromJson(
    Map<String, dynamic> json,
    CloudDriveType type,
  ) {
    return CloudDriveAccount(
      type: type,
      cookie: json['cookie']?.toString(),
      token: json['token']?.toString(),
      refreshToken: json['refreshToken']?.toString(),
      username: json['username']?.toString(),
      password: json['password']?.toString(),
      lastLoginAt: json['lastLoginAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              int.parse(json['lastLoginAt'].toString()),
            )
          : null,
      expiresAt: json['expiresAt'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              int.parse(json['expiresAt'].toString()),
            )
          : null,
      isLoggedIn: json['isLoggedIn'] == true,
    );
  }
}
