import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/l10n/generated/app_localizations.dart';
import 'package:mangayomi/services/cloud_drive/auth/cookie_manager.dart';
import 'package:mangayomi/services/cloud_drive/cloud_drive_manager.dart';
import 'package:mangayomi/services/cloud_drive/ui/qr_login_screen.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_account.dart';
import 'package:mangayomi/services/cloud_drive/models/cloud_drive_type.dart';
import 'package:mangayomi/services/cloud_drive/ui/cloud_file_browser_screen.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';

class CloudDriveDetailScreen extends ConsumerStatefulWidget {
  final CloudDriveType driveType;
  const CloudDriveDetailScreen({required this.driveType, super.key});

  @override
  ConsumerState<CloudDriveDetailScreen> createState() =>
      _CloudDriveDetailScreenState();
}

class _CloudDriveDetailScreenState extends ConsumerState<CloudDriveDetailScreen> {
  CloudDriveAccount? _account;
  bool _loading = true;
  bool _showTokenValues = false;

  @override
  void initState() {
    super.initState();
    _loadAccount();
  }

  Future<void> _loadAccount() async {
    setState(() => _loading = true);
    final account = await CloudCookieManager.getAccount(widget.driveType);
    if (mounted) {
      setState(() {
        _account = account;
        _loading = false;
      });
    }
  }

  String _maskString(String? value, {int prefixLen = 20, int suffixLen = 10}) {
    if (value == null || value.isEmpty) return '';
    if (value.length <= prefixLen + suffixLen + 3) {
      return '••••••••••';
    }
    return '${value.substring(0, prefixLen)}...${value.substring(value.length - suffixLen)}';
  }

  String? _formatDateTime(DateTime? dt) {
    if (dt == null) return null;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _loginByCookie() async {
    final l10n = l10nLocalizations(context)!;
    final cookieController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.cloud_drive_cookie_login_title),
        content: TextField(
          controller: cookieController,
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
            onPressed: () => Navigator.pop(ctx, cookieController.text.trim()),
            child: Text(l10n.login),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty) return;

    final service = CloudDriveManager.instance.get(widget.driveType);
    if (service == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.cloud_drive_service_not_registered)),
        );
      }
      return;
    }

    try {
      final success = await service.loginByCookie(result);
      if (mounted) {
        if (success) {
          await CloudCookieManager.setLoggedIn(widget.driveType, true);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.cloud_drive_login_success)),
          );
          _loadAccount();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.cloud_drive_login_failed_cookie)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.cloud_drive_login_failed_cookie)),
      );
      }
    }
  }

  Future<void> _loginByQR() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => QrLoginScreen(driveType: widget.driveType),
      ),
    );
    if (result == true && mounted) {
      _loadAccount();
      setState(() {});
    }
  }

  Future<void> _logout() async {
    final l10n = l10nLocalizations(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.cloud_drive_confirm_logout),
        content: Text(l10n.cloud_drive_confirm_logout_msg(widget.driveType.displayName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.cloud_drive_logout),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final service = CloudDriveManager.instance.get(widget.driveType);
      await service?.logout();
      await CloudCookieManager.clear(widget.driveType);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.cloud_drive_logged_out)),
        );
        _loadAccount();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.cloud_drive_logout_failed)),
        );
      }
    }
  }

  Future<void> _refreshAuth() async {
    final l10n = l10nLocalizations(context)!;
    try {
      final service = CloudDriveManager.instance.get(widget.driveType);
      if (service == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.cloud_drive_service_not_registered)),
          );
        }
        return;
      }
      final success = await service.refreshAuth();
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.cloud_drive_auth_refresh_success)),
          );
          _loadAccount();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.cloud_drive_auth_refresh_failed)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.cloud_drive_refresh_failed)),
        );
      }
    }
  }

  void _navigateToFileBrowser() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CloudFileBrowserScreen(driveType: widget.driveType),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isLoggedIn = _account?.isLoggedIn ?? false;
    final isExpired = _account?.isExpired ?? false;

    return Scaffold(
      appBar: AppBar(title: Text(widget.driveType.displayName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildAccountCard(l10n, isLoggedIn, isExpired),
                  const SizedBox(height: 16),
                  _buildCookieSection(l10n),
                  if (_account?.token != null) ...[
                    const SizedBox(height: 16),
                    _buildTokenSection(l10n),
                  ],
                  const SizedBox(height: 24),
                  _buildActionButtons(l10n),
                  const SizedBox(height: 16),
                  _buildFileBrowserButton(l10n),
                ],
              ),
            ),
    );
  }

  Widget _buildAccountCard(AppLocalizations l10n, bool isLoggedIn, bool isExpired) {
    String statusText;
    IconData statusIcon;
    Color statusColor;
    if (!isLoggedIn) {
      statusText = l10n.cloud_drive_not_logged_in;
      statusIcon = Icons.logout;
      statusColor = context.secondaryColor;
    } else if (isExpired) {
      statusText = l10n.cloud_drive_expired;
      statusIcon = Icons.warning_amber_rounded;
      statusColor = Colors.orange;
    } else {
      statusText = l10n.cloud_drive_logged_in;
      statusIcon = Icons.check_circle;
      statusColor = Colors.green;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(widget.driveType.icon, size: 32, color: context.primaryColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.driveType.displayName,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Row(
                        children: [
                          Icon(statusIcon, size: 14, color: statusColor),
                          const SizedBox(width: 4),
                          Text(
                            statusText,
                            style: TextStyle(
                              fontSize: 13,
                              color: statusColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(),
            if (isLoggedIn && _account?.username != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _infoRow(l10n.cloud_drive_username, _account!.username!),
              ),
            _infoRow(l10n.cloud_drive_login_status, isExpired ? l10n.cloud_drive_expired : l10n.cloud_drive_valid),
            if (_account?.lastLoginAt != null) ...[
              const SizedBox(height: 8),
              _infoRow(l10n.cloud_drive_last_login, _formatDateTime(_account!.lastLoginAt)!),
            ],
            if (_account?.expiresAt != null) ...[
              const SizedBox(height: 8),
              _infoRow(l10n.cloud_drive_expires_at, _formatDateTime(_account!.expiresAt)!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCookieSection(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Cookie',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_account?.cookie != null)
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: l10n.cloud_drive_copy_cookie,
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: _account!.cookie!),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.cloud_drive_cookie_copied)),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, size: 18),
                        tooltip: l10n.cloud_drive_update_cookie,
                        onPressed: _loginByCookie,
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.secondaryColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _account?.cookie != null
                    ? _maskString(_account!.cookie!)
                    : l10n.cloud_drive_cookie_not_set,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: context.secondaryColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTokenSection(AppLocalizations l10n) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Token',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _showTokenValues ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                      ),
                      tooltip: _showTokenValues
                          ? l10n.cloud_drive_hide_tokens
                          : l10n.cloud_drive_show_tokens,
                      onPressed: () => setState(() => _showTokenValues = !_showTokenValues),
                    ),
                    if (_account?.token != null)
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: l10n.cloud_drive_copy_token,
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: _account!.token!),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(l10n.cloud_drive_token_copied)),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.secondaryColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _account!.token != null
                    ? (_showTokenValues
                        ? _account!.token!
                        : '••••••••••••••••••••')
                    : l10n.cloud_drive_none,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: context.secondaryColor,
                ),
              ),
            ),
            if (_account?.refreshToken != null) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Refresh Token',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: l10n.cloud_drive_refresh_token_copied,
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: _account!.refreshToken!),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.cloud_drive_refresh_token_copied)),
                      );
                    },
                  ),
                ],
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.secondaryColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _showTokenValues
                      ? _account!.refreshToken!
                      : '••••••••••••••••••••',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: context.secondaryColor,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(AppLocalizations l10n) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          icon: const Icon(Icons.login),
          label: Text(l10n.cloud_drive_cookie_login),
          onPressed: _loginByCookie,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.qr_code),
          label: Text(l10n.cloud_drive_qr_login),
          onPressed: _loginByQR,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.logout),
          label: Text(l10n.cloud_drive_logout),
          onPressed: _logout,
        ),
        FilledButton.icon(
          icon: const Icon(Icons.refresh),
          label: Text(l10n.refresh),
          onPressed: _refreshAuth,
        ),
      ],
    );
  }

  Widget _buildFileBrowserButton(AppLocalizations l10n) {
    return OutlinedButton.icon(
      onPressed: _navigateToFileBrowser,
      icon: const Icon(Icons.folder_open),
      label: Text(l10n.cloud_drive_browse_files),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(double.infinity, 48),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: context.secondaryColor,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }
}
