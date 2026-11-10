import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/tenant_device_list.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// Desktop entry to the workspace device list.
///
/// Opening the app, showing this machine's ID/password and being controlled do
/// not require it: signing in only guards viewing and connecting the workspace
/// devices, and the unlock lasts for the current run.
class TenantDeviceGate extends StatefulWidget {
  const TenantDeviceGate({Key? key, this.compact = true}) : super(key: key);

  final bool compact;

  @override
  State<TenantDeviceGate> createState() => _TenantDeviceGateState();
}

class _TenantDeviceGateState extends State<TenantDeviceGate> {
  bool _unlocked = false;

  @override
  Widget build(BuildContext context) {
    if (!bind.isCustomClient()) {
      return TenantDeviceList(compact: widget.compact);
    }
    if (_unlocked) {
      return TenantDeviceList(compact: widget.compact, showActivation: true);
    }
    final color = Theme.of(context).textTheme.titleLarge?.color?.withOpacity(0.6);
    return InkWell(
      onTap: _login,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 32, color: color),
          const SizedBox(height: 8),
          Text(
            translate('Login'),
            style: TextStyle(fontSize: 13, color: color),
          ),
        ],
      ),
    );
  }

  Future<void> _login() async {
    final unlocked = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (ctx) => TenantLoginPage(
        onUnlocked: () => Navigator.of(ctx).pop(true),
      ),
    ));
    if (unlocked == true && mounted) {
      setState(() => _unlocked = true);
    }
  }
}

class TenantLoginPage extends StatefulWidget {
  const TenantLoginPage({
    Key? key,
    required this.onUnlocked,
    this.verify,
    this.loadUsername,
  }) : super(key: key);

  final VoidCallback onUnlocked;
  final Future<bool> Function(String username, String password)? verify;
  final Future<String> Function()? loadUsername;

  @override
  State<TenantLoginPage> createState() => _TenantLoginPageState();
}

class _TenantLoginPageState extends State<TenantLoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;
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
    final load = widget.loadUsername ?? () => bind.mainGetSystemUsername();
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
    setState(() => _busy = false);
    widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    return Scaffold(
      appBar: AppBar(title: Text(translate('Login'))),
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
                translate('Sign in with your system account'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 15,
                    color: textColor?.withOpacity(0.7)),
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
            ],
          ),
        ),
      ),
    );
  }
}
