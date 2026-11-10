import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/mobile/widgets/dialog.dart';

const _kOptionTenantProof = 'tenant-proof';
const _kOptionTenantEnrollToken = 'tenant-enroll-token';

/// Gates the desktop UI behind the local OS account.
///
/// Only managed desktop builds are gated. The service and any existing remote
/// session keep running; this only controls what the local user can see.
class TenantLoginGate extends StatefulWidget {
  const TenantLoginGate({Key? key, required this.child}) : super(key: key);

  final Widget child;

  @override
  State<TenantLoginGate> createState() => _TenantLoginGateState();
}

class _TenantLoginGateState extends State<TenantLoginGate> {
  bool _unlocked = false;

  @override
  Widget build(BuildContext context) {
    if (!isDesktop || isWeb || !bind.isCustomClient()) {
      return widget.child;
    }
    return _unlocked
        ? widget.child
        : TenantLoginPage(
            onUnlocked: () => setState(() => _unlocked = true),
          );
  }
}

class TenantLoginPage extends StatefulWidget {
  const TenantLoginPage({
    Key? key,
    required this.onUnlocked,
    this.verify,
    this.activate,
    this.loadUsername,
    this.readOption,
  }) : super(key: key);

  final VoidCallback onUnlocked;
  final Future<bool> Function(String username, String password)? verify;
  final Future<TenantActivationResult> Function(String token)? activate;
  final Future<String> Function()? loadUsername;
  final String Function(String key)? readOption;

  @override
  State<TenantLoginPage> createState() => _TenantLoginPageState();
}

class _TenantLoginPageState extends State<TenantLoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
  bool _showActivationFallback = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _fillUsername();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _fillUsername() async {
    final load = widget.loadUsername ??
        () => bind.mainGetSystemUsername();
    final name = await load();
    if (!mounted) return;
    setState(() => _usernameController.text = name);
  }

  Future<bool> _verify(String username, String password) {
    final verify = widget.verify;
    if (verify != null) return verify(username, password);
    return bind.mainVerifySystemCredentials(
        username: username, password: password);
  }

  String _option(String key) =>
      widget.readOption?.call(key) ?? bind.mainGetOptionSync(key: key);

  Future<void> _submit() async {
    if (_busy) return;
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = translate('Incorrect username or password'));
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _showActivationFallback = false;
    });
    var verified = false;
    try {
      verified = await _verify(username, password);
    } catch (_) {
      verified = false;
    }
    // The password is not needed after the local check.
    _passwordController.clear();
    if (!mounted) return;
    if (!verified) {
      setState(() {
        _busy = false;
        _error = translate('Incorrect username or password');
      });
      return;
    }
    await _afterVerified();
  }

  Future<void> _afterVerified() async {
    if (_option(_kOptionTenantProof).trim().isNotEmpty) {
      _unlock();
      return;
    }
    final token = _option(_kOptionTenantEnrollToken).trim();
    if (token.isEmpty) {
      _notProvisioned();
      return;
    }
    final activate = widget.activate ?? activateTenant;
    final result = await activate(token);
    if (!mounted) return;
    if (result.ok) {
      _unlock();
      return;
    }
    _notProvisioned(result.message);
  }

  void _notProvisioned([String message = '']) {
    setState(() {
      _busy = false;
      _showActivationFallback = true;
      _error = message.isNotEmpty
          ? message
          : translate(
              'This device is not provisioned. Please contact your administrator.');
    });
  }

  void _unlock() {
    setState(() => _busy = false);
    widget.onUnlocked();
  }

  void _showActivationCode() {
    showActivationDialog(gFFI.dialogManager, () {
      if (!mounted) return;
      if (_option(_kOptionTenantProof).trim().isNotEmpty) {
        widget.onUnlocked();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.desktop_windows_outlined,
                  size: 56, color: MyTheme.accent),
              const SizedBox(height: 16),
              Text(
                translate('Login'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: textColor),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _usernameController,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: translate('Username'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                enabled: !_busy,
                obscureText: true,
                autofocus: true,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: translate('Password'),
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _error,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(translate('Login')),
              ),
              if (_showActivationFallback)
                TextButton(
                  onPressed: _busy ? null : _showActivationCode,
                  child: Text(translate('Use an activation code')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
