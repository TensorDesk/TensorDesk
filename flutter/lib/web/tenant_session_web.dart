import 'dart:html' as html;

import 'package:flutter/widgets.dart';

/// Opens the device in a new browser tab.
///
/// The web client keeps one session per tab, so a second device gets its own
/// tab instead of replacing the session in the current one. `WebHomePage`
/// handles the `#/connect/<id>` deep link on startup.
void openTenantDeviceSession(BuildContext context, String id) {
  if (id.isEmpty) {
    return;
  }
  final base = html.window.location.href.split('#').first;
  html.window.open('$base#/connect/$id', '_blank');
}
