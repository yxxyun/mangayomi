import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
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
    final cookieController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('登录 - 粘贴Cookie'),
        content: TextField(
          controller: cookieController,
          decoration: const InputDecoration(
            hintText: '在此粘贴Cookie字符串...',
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
            onPressed: () => Navigator.pop(ctx, cookieController.text.trim()),
            child: const Text('登录'),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty) return;

    final service = CloudDriveManager.instance.get(widget.driveType);
    if (service == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该网盘服务尚未注册')),
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
            const SnackBar(content: Text('登录成功')),
          );
          _loadAccount();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('登录失败，请检查Cookie是否正确')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('登录失败，请检查凭据是否正确')),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认退出'),
        content: Text('确定要退出${widget.driveType.displayName}的登录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
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
          const SnackBar(content: Text('已退出登录')),
        );
        _loadAccount();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('退出失败')),
        );
      }
    }
  }

  Future<void> _refreshAuth() async {
    try {
      final service = CloudDriveManager.instance.get(widget.driveType);
      if (service == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该网盘服务尚未注册')),
          );
        }
        return;
      }
      final success = await service.refreshAuth();
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('认证刷新成功')),
          );
          _loadAccount();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('认证刷新失败')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('刷新失败')),
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
                  _buildStatusCard(isLoggedIn, isExpired),
                  const SizedBox(height: 16),
                  if (isLoggedIn) _buildLoginInfoSection(),
                  if (isLoggedIn) const SizedBox(height: 16),
                  _buildCookieSection(),
                  if (_account?.token != null) ...[
                    const SizedBox(height: 16),
                    _buildTokenSection(),
                  ],
                  const SizedBox(height: 24),
                  _buildActionButtons(),
                  const SizedBox(height: 16),
                  _buildFileBrowserButton(),
                ],
              ),
            ),
    );
  }

  Widget _buildStatusCard(bool isLoggedIn, bool isExpired) {
    String statusText;
    IconData statusIcon;
    Color statusColor;
    if (!isLoggedIn) {
      statusText = '未登录';
      statusIcon = Icons.logout;
      statusColor = context.secondaryColor;
    } else if (isExpired) {
      statusText = '已过期';
      statusIcon = Icons.warning_amber_rounded;
      statusColor = Colors.orange;
    } else {
      statusText = '已登录';
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
            if (isLoggedIn && _account?.username != null) ...[
              const Divider(),
              _infoRow('用户名', _account!.username!),
            ],
            if (_account?.lastLoginAt != null) ...[
              const SizedBox(height: 8),
              _infoRow('最后登录', _formatDateTime(_account!.lastLoginAt)!),
            ],
            if (_account?.expiresAt != null) ...[
              const SizedBox(height: 8),
              _infoRow('过期时间', _formatDateTime(_account!.expiresAt)!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLoginInfoSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '登录信息',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            _infoRow(
              '登录状态',
              _account?.isExpired ?? false ? '已过期' : '有效',
            ),
            if (_account?.lastLoginAt != null) ...[
              const SizedBox(height: 8),
              _infoRow('登录时间', _formatDateTime(_account!.lastLoginAt)!),
            ],
            if (_account?.expiresAt != null) ...[
              const SizedBox(height: 8),
              _infoRow('过期时间', _formatDateTime(_account!.expiresAt)!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCookieSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Cookie',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_account?.cookie != null)
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: '复制Cookie',
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: _account!.cookie!),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Cookie已复制到剪贴板')),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, size: 18),
                        tooltip: '更新Cookie',
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
                    : '未设置Cookie',
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

  Widget _buildTokenSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Token',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_account?.token != null)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '复制Token',
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: _account!.token!),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Token已复制到剪贴板')),
                      );
                    },
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
                    ? _maskString(_account!.token!, prefixLen: 15, suffixLen: 8)
                    : '无',
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
                  const Text(
                    'Refresh Token',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '复制Refresh Token',
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: _account!.refreshToken!),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Refresh Token已复制到剪贴板')),
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
                  _maskString(_account!.refreshToken!, prefixLen: 15, suffixLen: 8),
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

  Widget _buildActionButtons() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        ActionChip(
          avatar: const Icon(Icons.login),
          label: const Text('Cookie登录'),
          onPressed: _loginByCookie,
        ),
        ActionChip(
          avatar: const Icon(Icons.qr_code),
          label: const Text('QR登录'),
          onPressed: _loginByQR,
        ),
        ActionChip(
          avatar: const Icon(Icons.logout),
          label: const Text('退出登录'),
          onPressed: _logout,
        ),
        ActionChip(
          avatar: const Icon(Icons.refresh),
          label: const Text('刷新'),
          onPressed: _refreshAuth,
        ),
      ],
    );
  }

  Widget _buildFileBrowserButton() {
    return OutlinedButton.icon(
      onPressed: _navigateToFileBrowser,
      icon: const Icon(Icons.folder_open),
      label: const Text('浏览文件'),
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
