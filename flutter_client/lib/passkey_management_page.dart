import 'package:flutter/material.dart';

import 'api.dart';
import 'passkey_login.dart';

class PasskeyManagementPage extends StatefulWidget {
  const PasskeyManagementPage({
    super.key,
    required this.api,
    required this.onUnauthorized,
    this.registrationProvider = requestPasskeyRegistration,
  });

  final ApiClient api;
  final VoidCallback onUnauthorized;
  final PasskeyRegistrationProvider registrationProvider;

  @override
  State<PasskeyManagementPage> createState() => _PasskeyManagementPageState();
}

class _PasskeyManagementPageState extends State<PasskeyManagementPage> {
  List<PasskeyCredentialInfo>? credentials;
  String? error;
  bool loading = true;
  int requestNumber = 0;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final currentRequest = ++requestNumber;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.listPasskeys();
      if (!mounted || currentRequest != requestNumber) return;
      setState(() => credentials = result);
    } on ApiFailure catch (failure) {
      if (!mounted || currentRequest != requestNumber) return;
      if (failure.unauthorized) {
        setState(() => error = '登录状态已失效，请重新登录。');
        widget.onUnauthorized();
        return;
      }
      setState(() => error = failure.message);
    } catch (_) {
      if (mounted && currentRequest == requestNumber) {
        setState(() => error = '读取通行密钥失败，请稍后重试。');
      }
    } finally {
      if (mounted && currentRequest == requestNumber) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> addPasskey() async {
    final created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RegisterDialog(
        api: widget.api,
        onUnauthorized: widget.onUnauthorized,
        registrationProvider: widget.registrationProvider,
      ),
    );
    if (created == true && mounted) await reload();
  }

  Future<void> removePasskey(PasskeyCredentialInfo credential) async {
    final removed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RemoveDialog(
        api: widget.api,
        credential: credential,
        onUnauthorized: widget.onUnauthorized,
      ),
    );
    if (removed == true && mounted) await reload();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: dark ? Colors.black : const Color(0xfff4f7fb),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            18,
            19,
            18,
            24 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('passkey-management-back'),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.chevron_left),
                label: const Text('账号安全'),
              ),
            ),
            const Text(
              '通行密钥管理',
              style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 7),
            const Text(
              '使用设备生物识别或屏幕锁验证身份；添加和移除时仍需确认当前密码。',
              style: TextStyle(fontSize: 13, color: Color(0xff64748b)),
            ),
            const SizedBox(height: 14),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null) ...[
              Text(error!, style: const TextStyle(color: Color(0xffdc2626))),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('passkey-retry'),
                  onPressed: reload,
                  child: const Text('重试'),
                ),
              ),
            ] else
              _group(dark, [
                if (credentials!.isEmpty)
                  const ListTile(
                    title: Text('尚未添加通行密钥'),
                    subtitle: Text('添加后可使用设备生物识别或屏幕锁登录。'),
                  )
                else
                  for (final credential in credentials!)
                    ListTile(
                      key: Key('passkey-item-${credential.id}'),
                      leading: const Icon(
                        Icons.key_outlined,
                        color: Color(0xff2563eb),
                      ),
                      title: Text(
                        credential.label,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '${credential.deviceType == 'multi_device' ? '可同步通行密钥' : '设备通行密钥'} · 添加于 ${_date(credential.createdAt)}'
                        '${credential.lastUsedAt == null ? '' : '\n最近使用 ${_date(credential.lastUsedAt!)}'}',
                      ),
                      isThreeLine: credential.lastUsedAt != null,
                      trailing: TextButton(
                        key: Key('passkey-remove-${credential.id}'),
                        onPressed: () => removePasskey(credential),
                        child: const Text(
                          '移除',
                          style: TextStyle(color: Color(0xffdc2626)),
                        ),
                      ),
                    ),
                ListTile(
                  key: const Key('passkey-add-button'),
                  leading: const Icon(Icons.add, color: Color(0xff2563eb)),
                  title: const Text(
                    '添加通行密钥',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 19),
                  onTap: addPasskey,
                ),
              ]),
          ],
        ),
      ),
    );
  }
}

String _date(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}

Widget _group(bool dark, List<Widget> children) => Container(
  clipBehavior: Clip.antiAlias,
  decoration: BoxDecoration(
    color: dark ? const Color(0xe5222630) : const Color(0xf5ffffff),
    borderRadius: BorderRadius.circular(18),
    border: Border.all(color: dark ? Colors.white12 : const Color(0xffe5eaf0)),
    boxShadow: const [BoxShadow(color: Color(0x100f172a), blurRadius: 9)],
  ),
  child: Material(
    type: MaterialType.transparency,
    child: Column(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0)
            Divider(
              height: 1,
              indent: 16,
              color: dark ? Colors.white12 : const Color(0xffe8ecf1),
            ),
          children[index],
        ],
      ],
    ),
  ),
);

class _RegisterDialog extends StatefulWidget {
  const _RegisterDialog({
    required this.api,
    required this.onUnauthorized,
    required this.registrationProvider,
  });

  final ApiClient api;
  final VoidCallback onUnauthorized;
  final PasskeyRegistrationProvider registrationProvider;

  @override
  State<_RegisterDialog> createState() => _RegisterDialogState();
}

class _RegisterDialogState extends State<_RegisterDialog> {
  final label = TextEditingController(text: '此设备');
  final password = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    label.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    if (password.text.isEmpty) {
      setState(() => error = '请输入当前密码。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.registerPasskey(
        label: label.text,
        password: password.text,
        createCredential: widget.registrationProvider,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on PasskeyRegistrationCancelled {
      if (mounted) setState(() => error = '已取消创建通行密钥。');
    } on PasskeyRegistrationFailure catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      if (failure.unauthorized) {
        Navigator.of(context).pop();
        widget.onUnauthorized();
      } else {
        setState(() => error = failure.message);
      }
    } catch (_) {
      if (mounted) setState(() => error = '添加通行密钥失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('添加通行密钥'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('为这台设备创建可用于登录的通行密钥。'),
          const SizedBox(height: 14),
          TextField(
            key: const Key('passkey-label-field'),
            controller: label,
            enabled: !busy,
            maxLength: 64,
            decoration: const InputDecoration(labelText: '设备名称'),
          ),
          TextField(
            key: const Key('passkey-register-password'),
            controller: password,
            enabled: !busy,
            obscureText: true,
            maxLength: 512,
            decoration: const InputDecoration(labelText: '当前密码'),
          ),
          const SizedBox(height: 8),
          const Text(
            '为防止已解锁设备被他人绑定凭据，添加时需再次验证当前密码。',
            style: TextStyle(fontSize: 12, color: Color(0xff64748b)),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                error!,
                style: const TextStyle(color: Color(0xffdc2626)),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('passkey-register-confirm'),
          onPressed: busy ? null : submit,
          child: Text(busy ? '正在验证…' : '继续并验证'),
        ),
      ],
    ),
  );
}

class _RemoveDialog extends StatefulWidget {
  const _RemoveDialog({
    required this.api,
    required this.credential,
    required this.onUnauthorized,
  });

  final ApiClient api;
  final PasskeyCredentialInfo credential;
  final VoidCallback onUnauthorized;

  @override
  State<_RemoveDialog> createState() => _RemoveDialogState();
}

class _RemoveDialogState extends State<_RemoveDialog> {
  final password = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    if (password.text.isEmpty) {
      setState(() => error = '请输入当前密码。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.deletePasskey(widget.credential.id, password.text);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      if (failure.unauthorized) {
        Navigator.of(context).pop();
        widget.onUnauthorized();
      } else {
        setState(() => error = failure.message);
      }
    } catch (_) {
      if (mounted) setState(() => error = '移除通行密钥失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text('移除“${widget.credential.label}”？'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('移除后，将无法再使用此通行密钥登录。此操作需要再次验证当前密码。'),
          const SizedBox(height: 12),
          TextField(
            key: const Key('passkey-remove-password'),
            controller: password,
            enabled: !busy,
            obscureText: true,
            maxLength: 512,
            decoration: const InputDecoration(labelText: '当前密码'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                error!,
                style: const TextStyle(color: Color(0xffdc2626)),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('passkey-remove-confirm'),
          onPressed: busy ? null : submit,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xffdc2626),
          ),
          child: Text(busy ? '正在移除…' : '确认移除'),
        ),
      ],
    ),
  );
}
