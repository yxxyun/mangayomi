import 'package:flutter/material.dart';

/// Supported cloud drive types.
enum CloudDriveType {
  quark('quark', '夸克网盘', Icons.cloud_outlined),
  uc('uc', 'UC网盘', Icons.cloud_outlined),
  ali('ali', '阿里云盘', Icons.cloud_outlined),
  baidu('baidu', '百度网盘', Icons.cloud_outlined),
  pan123('pan123', '123云盘', Icons.cloud_outlined),
  cloud189('cloud189', '天翼云盘', Icons.cloud_outlined),
  yun139('yun139', '移动云盘', Icons.cloud_outlined),
  xunlei('xunlei', '迅雷网盘', Icons.cloud_outlined);

  final String key;
  final String displayName;
  final IconData icon;
  const CloudDriveType(this.key, this.displayName, this.icon);

  static CloudDriveType? fromKey(String key) {
    for (final type in CloudDriveType.values) {
      if (type.key == key) return type;
    }
    return null;
  }
}
