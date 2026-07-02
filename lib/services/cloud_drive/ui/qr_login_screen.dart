import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
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
  String? _qrStatus;
  Map<String, dynamic>? _stateData;
  Timer? _pollTimer;
  bool _isLoading = true;
  bool _isSuccess = false;

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

  String _statusLabel(String status, AppLocalizations l10n) {
    switch (status) {
      case 'NEW':
        return l10n.cloud_drive_qr_scan_with_app;
      case 'SCANED':
        return l10n.cloud_drive_qr_scanned_confirm;
      case 'CONFIRMED':
        return l10n.cloud_drive_qr_login_success_msg;
      case 'CANCELED':
        return l10n.canceled;
      case 'EXPIRED':
        return l10n.cloud_drive_qr_expired;
      default:
        return l10n.cloud_drive_qr_waiting;
    }
  }

  Future<void> _startScan() async {
    final l10n = l10nLocalizations(context)!;
    setState(() {
      _isLoading = true;
      _errorText = null;
      _statusText = l10n.cloud_drive_qr_getting_code;
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
        _qrStatus = 'NEW';
        _statusText = _statusLabel('NEW', l10n);
        _isLoading = false;
      });

      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = l10n.cloud_drive_qr_get_failed;
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
    final l10n = l10nLocalizations(context)!;

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
          _statusText = l10n.cloud_drive_qr_login_success_msg;
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
          _qrStatus = status;
          _statusText = l10n.cloud_drive_qr_expired;
          _errorText = l10n.cloud_drive_expired;
        });
      } else if (status == 'CANCELED') {
        _pollTimer?.cancel();
        setState(() {
          _qrStatus = status;
          _statusText = l10n.canceled;
          _errorText = l10n.canceled;
        });
      } else {
        setState(() {
          _qrStatus = status;
          _statusText = _statusLabel(status ?? '', l10n);
        });
      }
    } catch (e) {
      // Polling error — just retry next cycle
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.cloud_drive_qr_login_title(widget.driveType.displayName)),
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
                          child: Center(
                            child: Text(l10n.cloud_drive_qr_load_failed_desc,
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
                if (_qrStatus == 'NEW')
                  Text(
                    l10n.cloud_drive_qr_scan_hint(widget.driveType.displayName),
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
                    l10n.cloud_drive_qr_waiting,
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
                  label: Text(l10n.cloud_drive_qr_regenerate),
                ),
                const SizedBox(height: 12),
              ],
              TextButton.icon(
                onPressed: () => _showManualInputDialog(context),
                icon: const Icon(Icons.edit),
                label: Text(l10n.cloud_drive_enter_cookie_manually),
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
    final l10n = l10nLocalizations(context)!;
    return Column(
      children: [
        Icon(Icons.error_outline, size: 80, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 16),
        Text(
          _errorText ?? l10n.cloud_drive_qr_get_failed,
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
          label: Text(l10n.retry),
        ),
      ],
    );
  }

  void _showManualInputDialog(BuildContext context) {
    final l10n = l10nLocalizations(context)!;
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.cloud_drive_enter_cookie_manually),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: l10n.cloud_drive_paste_cookie,
            border: const OutlineInputBorder(),
          ),
          maxLines: 5,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              final cookie = controller.text.trim();
              if (cookie.isNotEmpty) {
                Navigator.pop(ctx);
                _useManualCookie(cookie);
              }
            },
            child: Text(l10n.login),
          ),
        ],
      ),
    );
  }

  Future<void> _useManualCookie(String cookie) async {
    final l10n = l10nLocalizations(context)!;
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
        _errorText = l10n.cloud_drive_qr_login_failed;
        _isLoading = false;
      });
    }
  }
}
