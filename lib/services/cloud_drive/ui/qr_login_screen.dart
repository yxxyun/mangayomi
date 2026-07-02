import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';
import 'package:mangayomi/services/cloud_drive/auth/qr_login_flow.dart';
import 'package:mangayomi/services/cloud_drive/auth/cookie_manager.dart';
import 'package:mangayomi/services/cloud_drive/cloud_drive_manager.dart';

/// Full-screen QR code login for cloud drives.
///
/// Flow:
/// 1. Calls QrLoginFlow.startScan() to get QR image URL + state
/// 2. Shows QR code image
/// 3. Polls QrLoginFlow.checkStatus() every 3s
/// 4. On success → saves cookie/token → pops with true
/// 5. On failure → shows retry option
class QrLoginScreen extends StatefulWidget {
  final CloudDriveType driveType;

  const QrLoginScreen({super.key, required this.driveType});

  @override
  State<QrLoginScreen> createState() => _QrLoginScreenState();
}

class _QrLoginScreenState extends State<QrLoginScreen> {
  String _statusText = '';
  String? _qrImageUrl;
  String? _errorText;
  Map<String, dynamic>? _stateData;
  Timer? _pollTimer;
  bool _isLoading = true;
  bool _isSuccess = false;

  static const _statusLabels = <String, String>{
    'NEW': '请用手机扫码登录',
    'SCANED': '已扫码，请在手机上确认',
    'CONFIRMED': '登录成功!',
    'CANCELED': '已取消',
    'EXPIRED': '二维码已过期',
  };

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
      _statusText = '正在获取二维码...';
    });

    try {
      final result = await QrLoginFlow.startScan(widget.driveType);
      if (!mounted) return;

      if (result.error != null) {
        setState(() {
          _errorText = result.error;
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _qrImageUrl = result.qrImageUrl;
        _stateData = result.stateData;
        _statusText = _statusLabels['NEW'] ?? '请用手机扫码登录';
        _isLoading = false;
      });

      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = '获取二维码失败';
        _isLoading = false;
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _checkStatus());
  }

  Future<void> _checkStatus() async {
    if (_stateData == null) return;

    try {
      final result = await QrLoginFlow.checkStatus(widget.driveType, _stateData!);
      if (!mounted) return;

      if (result.isSuccess) {
        _pollTimer?.cancel();
        // Reinitialize the service — loginByCookie handles persistence internally
        final service = CloudDriveManager.instance.get(widget.driveType);
        if (service != null) {
          if (result.cookie != null) {
            await service.loginByCookie(result.cookie!);
          } else if (result.token != null) {
            // Token-based auth (e.g. AliDrive) — save token then init
            await CloudCookieManager.saveToken(widget.driveType, result.token!);
            await service.initialize();
          }
        }
        if (!mounted) return;
        setState(() {
          _isSuccess = true;
          _statusText = '登录成功!';
        });
        // Auto-close after brief delay
        await Future.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }

      final status = result.status;
      if (status == 'EXPIRED') {
        _pollTimer?.cancel();
        setState(() {
          _statusText = '二维码已过期，请重新扫码';
          _errorText = '已过期';
        });
      } else if (status == 'CANCELED') {
        _pollTimer?.cancel();
        setState(() {
          _statusText = '已取消';
          _errorText = '已取消';
        });
      } else {
        setState(() {
          _statusText = _statusLabels[status] ?? '等待扫码...';
        });
      }
    } catch (e) {
      // Polling error — just retry next cycle
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.driveType.displayName} 扫码登录'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // QR code image
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator(),
                )
              else if (_errorText != null && _qrImageUrl == null)
                _buildErrorState()
              else if (_isSuccess)
                const Icon(Icons.check_circle, color: Colors.green, size: 100)
              else ...[
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      _qrImageUrl ?? '',
                      width: 280,
                      height: 280,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stack) => Container(
                        width: 280,
                        height: 280,
                        color: Colors.grey.shade100,
                        child: const Center(
                          child: Text('无法加载二维码\n请检查网络连接',
                            textAlign: TextAlign.center),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Status text
                Text(
                  _statusText,
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (_statusText == 'NEW')
                  Text(
                    '请使用${widget.driveType.displayName}手机App扫描二维码',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
                    textAlign: TextAlign.center,
                  ),
                if (_pollTimer != null && _errorText == null) ...[
                  const SizedBox(height: 12),
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '等待扫码...',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
              const SizedBox(height: 32),
              // Bottom actions
              if (_errorText != null) ...[
                ElevatedButton.icon(
                  onPressed: () {
                    _pollTimer?.cancel();
                    _startScan();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新获取二维码'),
                ),
                const SizedBox(height: 12),
              ],
              TextButton.icon(
                onPressed: () => _showManualInputDialog(context),
                icon: const Icon(Icons.edit),
                label: const Text('手动输入Cookie'),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorText!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Column(
      children: [
        Icon(Icons.error_outline, size: 80, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 16),
        Text(
          _errorText ?? '获取二维码失败',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: () {
            _pollTimer?.cancel();
            _startScan();
          },
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      ],
    );
  }

  void _showManualInputDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动输入Cookie'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '粘贴Cookie字符串...',
            border: OutlineInputBorder(),
          ),
          maxLines: 5,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final cookie = controller.text.trim();
              if (cookie.isNotEmpty) {
                Navigator.pop(ctx);
                _useManualCookie(cookie);
              }
            },
            child: const Text('登录'),
          ),
        ],
      ),
    );
  }

  Future<void> _useManualCookie(String cookie) async {
    setState(() => _isLoading = true);
    try {
      // loginByCookie handles persistence internally via saveAccount
      final service = CloudDriveManager.instance.get(widget.driveType);
      if (service != null) {
        await service.loginByCookie(cookie);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = '登录失败，请检查Cookie是否正确';
        _isLoading = false;
      });
    }
  }
}
