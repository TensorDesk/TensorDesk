import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/state_model.dart';

/// Opens a remote desktop session for a workspace device.
///
/// Mobile keeps a single session: while one is running the user is asked to
/// close it first. Desktop opens the usual window per session.
void openTenantDeviceSession(BuildContext context, String id) {
  if (id.isEmpty) {
    return;
  }
  if (isMobile && !stateGlobal.isInMainPage) {
    showToast(translate('Please close the current remote desktop first'));
    return;
  }
  connect(context, id);
}
