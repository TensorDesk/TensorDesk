import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/tenant_devices_model.dart';
import 'package:flutter_hbb/models/tenant_session.dart'
    if (dart.library.html) 'package:flutter_hbb/web/tenant_session_web.dart';
import 'package:flutter_hbb/mobile/widgets/dialog.dart';
import 'package:get/get.dart';

/// List of the devices in the workspace this build is activated in.
/// Renders nothing when there is no stored credential, so non-managed builds
/// and not-yet-activated devices keep their previous home page.
class TenantDeviceList extends StatefulWidget {
  const TenantDeviceList({
    Key? key,
    this.compact = false,
    this.showActivation = false,
  }) : super(key: key);

  /// Compact mode is used inside the desktop home pane; otherwise the list
  /// fills the page it is placed on.
  final bool compact;

  /// Shows the activation entry when this build has no credential yet.
  final bool showActivation;

  @override
  State<TenantDeviceList> createState() => _TenantDeviceListState();
}

class _TenantDeviceListState extends State<TenantDeviceList>
    with WidgetsBindingObserver {
  List<TenantDevice>? _devices;
  String? _error;
  bool _loading = false;
  Timer? _refreshTimer;

  /// Devices report a heartbeat every 15 s, so polling at the same cadence
  /// keeps the online dots close to reality without extra load.
  static const _refreshInterval = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _refreshTimer =
        Timer.periodic(_refreshInterval, (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load(silent: true);
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (_loading) return;
    _loading = true;
    if (!silent) {
      setState(() {
        _error = null;
      });
    }
    try {
      final devices = await fetchTenantDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Keep the last known list on a failed background poll; only a
        // user-initiated load surfaces the failure.
        if (!silent) {
          _error = e.toString();
        }
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (bind.mainGetOptionSync(key: 'tenant-proof').trim().isEmpty) {
      return widget.showActivation
          ? _buildNotActivated(context)
          : const SizedBox.shrink();
    }
    final body = _buildBody(context);
    if (widget.compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: body,
          ),
        ],
      );
    }
    return Column(
      children: [
        _buildHeader(context),
        Expanded(child: body),
      ],
    );
  }

  Widget _buildNotActivated(BuildContext context) {
    final color = Theme.of(context).textTheme.titleLarge?.color?.withOpacity(0.6);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.devices_other, size: 40, color: color),
        const SizedBox(height: 8),
        Text(
          translate('Activate TensorDesk'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          translate('Enter the activation code from the console'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: color),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => showActivationDialog(gFFI.dialogManager, _load),
          child: Text(translate('Use an activation code')),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            translate('Desktops'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        _loading
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ).marginSymmetric(horizontal: 5)
            : IconButton(
                tooltip: translate('Refresh'),
                icon: const Icon(Icons.refresh, size: 16),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 24, height: 24),
                onPressed: _load,
              ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      return Text(
        _error!,
        style: TextStyle(
          fontSize: 11,
          color:
              Theme.of(context).textTheme.titleLarge?.color?.withOpacity(0.6),
        ),
      );
    }
    final devices = _devices;
    if (devices == null) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (devices.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          translate('No devices'),
          style: TextStyle(
            fontSize: 12,
            color:
                Theme.of(context).textTheme.titleLarge?.color?.withOpacity(0.6),
          ),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: devices.length,
      itemBuilder: (context, index) => _buildDevice(context, devices[index]),
    );
  }

  Widget _buildDevice(BuildContext context, TenantDevice device) {
    final label =
        device.name.isEmpty ? formatID(device.rustdeskId) : device.name;
    return GestureDetector(
      onSecondaryTapUp: (details) =>
          _showDeviceMenu(context, device, details.globalPosition),
      onLongPressStart: (details) =>
          _showDeviceMenu(context, device, details.globalPosition),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        onTap: () => openTenantDeviceSession(context, device.rustdeskId),
        contentPadding: widget.compact
            ? const EdgeInsets.symmetric(horizontal: 4, vertical: 0)
            : null,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: translate(device.online ? 'Online' : 'Offline'),
              child: CircleAvatar(
                radius: 3,
                backgroundColor: device.online ? Colors.green : kColorWarn,
              ).marginOnly(right: 6),
            ),
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: str2color('${device.rustdeskId}${device.platform}', 0x7f),
                borderRadius: BorderRadius.circular(4),
              ),
              child: getPlatformImage(
                tenantPeerPlatform(device.platform),
                size: 16,
              ),
            ),
          ],
        ),
        title: Text(label, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          formatID(device.rustdeskId),
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }

  void _showDeviceMenu(
      BuildContext context, TenantDevice device, Offset position) async {
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: [
        PopupMenuItem(value: 'rename', child: Text(translate('Rename'))),
      ],
    );
    if (value == 'rename' && mounted) {
      renameDialog(
        oldName: device.name,
        validator: (value) => (value == null || value.trim().isEmpty)
            ? translate('Can not be empty')
            : null,
        onSubmit: (name) async {
          try {
            await renameTenantDevice(device.deviceId, name);
            _load();
          } catch (e) {
            showToast(e.toString());
          }
        },
      );
    }
  }
}
