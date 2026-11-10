import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/tenant_device_list.dart';

import 'home_page.dart';

/// Mobile tab listing the devices of the workspace this build is activated in.
class DevicesPage extends StatefulWidget implements PageShape {
  @override
  final title = translate("Devices");

  @override
  final icon = const Icon(Icons.devices);

  @override
  final appBarActions = <Widget>[];

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(8),
      child: const TenantDeviceList(showActivation: true),
    );
  }
}
