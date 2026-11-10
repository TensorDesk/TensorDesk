import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
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

  /// Shows the activation entry when this build has no credential yet. Only
  /// mobile and web pass `true`; the desktop gates the whole UI already.
  final bool showActivation;

  @override
  State<TenantDeviceList> createState() => _TenantDeviceListState();
}

class _TenantDeviceListState extends State<TenantDeviceList> {
  List<TenantDevice>? _devices;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await fetchTenantDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
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
            translate('Devices'),
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
    final platformImage = getPlatformImage(
      tenantPeerPlatform(device.platform),
      size: 20,
    );
    return ListTile(
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
          platformImage,
        ],
      ),
      title: Text(label, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        formatID(device.rustdeskId),
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
    );
  }
}
