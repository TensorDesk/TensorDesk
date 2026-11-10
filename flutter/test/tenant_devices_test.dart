import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/tenant_devices_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a device reported by the control plane', () {
    final device = TenantDevice.fromJson({
      'device_id': 'd1',
      'rustdesk_id': '123456789',
      'name': 'office-pc',
      'platform': 'Ubuntu / 24.04',
      'online': true,
      'last_seen_at': '2026-11-10T06:00:00Z',
    });
    expect(device.deviceId, 'd1');
    expect(device.rustdeskId, '123456789');
    expect(device.name, 'office-pc');
    expect(device.online, isTrue);
    expect(device.platform, 'Ubuntu / 24.04');
    expect(device.lastSeenAt?.isUtc, isFalse);
  });

  test('keeps rows usable when optional fields are missing', () {
    final device = TenantDevice.fromJson({
      'rustdesk_id': '123456789',
      'online': false,
    });
    expect(device.name, '');
    expect(device.platform, '');
    expect(device.online, isFalse);
    expect(device.lastSeenAt, isNull);
  });

  test('maps sysinfo OS strings onto peer platform icons', () {
    expect(tenantPeerPlatform('Windows 11 - 22631'), kPeerPlatformWindows);
    expect(tenantPeerPlatform('macOS / 15.0'), kPeerPlatformMacOS);
    expect(tenantPeerPlatform('Ubuntu / 24.04'), kPeerPlatformLinux);
    expect(tenantPeerPlatform('Android 14'), kPeerPlatformAndroid);
    expect(tenantPeerPlatform('FreeBSD 14'), '');
  });
}
