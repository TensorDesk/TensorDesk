import 'dart:convert';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/http_service.dart' as http;

/// One device of the workspace this build is activated in, as reported by the
/// control plane. Read-only view: connecting is handled elsewhere.
class TenantDevice {
  TenantDevice({
    required this.deviceId,
    required this.rustdeskId,
    required this.name,
    required this.platform,
    required this.online,
    this.lastSeenAt,
  });

  final String deviceId;
  final String rustdeskId;
  final String name;
  final String platform;
  final bool online;
  final DateTime? lastSeenAt;

  factory TenantDevice.fromJson(Map<String, dynamic> json) {
    final lastSeenAt = DateTime.tryParse('${json['last_seen_at'] ?? ''}');
    return TenantDevice(
      deviceId: '${json['device_id'] ?? ''}',
      rustdeskId: '${json['rustdesk_id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      platform: '${json['platform'] ?? ''}',
      online: json['online'] == true,
      lastSeenAt: lastSeenAt?.toLocal(),
    );
  }
}

/// Maps the OS string reported in sysinfo (e.g. `Ubuntu / 24.04`) onto the
/// platform names [getPlatformImage] understands; unknown values get no icon.
String tenantPeerPlatform(String os) {
  final value = os.toLowerCase();
  if (value.contains('windows')) return kPeerPlatformWindows;
  if (value.contains('mac')) return kPeerPlatformMacOS;
  if (value.contains('android')) return kPeerPlatformAndroid;
  if (value.contains('linux') ||
      value.contains('ubuntu') ||
      value.contains('debian') ||
      value.contains('centos') ||
      value.contains('fedora') ||
      value.contains('rhel')) {
    return kPeerPlatformLinux;
  }
  return '';
}

/// Fetches the device list of the credential's workspace. Returns an empty
/// list when this build has not been activated yet (no stored credential).
Future<List<TenantDevice>> fetchTenantDevices() async {
  final proof = bind.mainGetOptionSync(key: 'tenant-proof').trim();
  if (proof.isEmpty) {
    return [];
  }
  final base = kTenantApiBase.endsWith('/')
      ? kTenantApiBase.substring(0, kTenantApiBase.length - 1)
      : kTenantApiBase;
  final response = await http.get(
    Uri.parse('$base/api/client/devices'),
    headers: {
      'Accept': 'application/json',
      'Authorization': 'Bearer $proof',
    },
  );
  if (response.statusCode != 200) {
    throw Exception('device list returned HTTP ${response.statusCode}');
  }
  final decoded = jsonDecode(response.body);
  if (decoded is! List) {
    throw Exception('invalid device list response');
  }
  return decoded
      .whereType<Map<String, dynamic>>()
      .map(TenantDevice.fromJson)
      .toList();
}
