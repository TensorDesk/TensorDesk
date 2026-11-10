import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/tenant_device_list.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/native_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// An unactivated build: no credential is stored and no network is reached.
class _FakeBind implements RustdeskImpl {
  @override
  String translate({required String name, required String locale, dynamic hint}) =>
      name;

  @override
  String mainGetOptionSync({required String key, dynamic hint}) => '';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  setUpAll(() {
    PlatformFFI.instance.setBindingForTesting(_FakeBind());
  });

  testWidgets('mobile and web show the activation entry before activation',
      (tester) async {
    await tester.pumpWidget(_app(const TenantDeviceList(showActivation: true)));
    await tester.pumpAndSettle();

    expect(find.text('Activate TensorDesk'), findsOneWidget);
    expect(find.text('Use an activation code'), findsOneWidget);
  });

  testWidgets('desktop keeps hiding the list before activation',
      (tester) async {
    await tester.pumpWidget(_app(const TenantDeviceList(compact: true)));
    await tester.pumpAndSettle();

    expect(find.text('Activate TensorDesk'), findsNothing);
    expect(find.text('Use an activation code'), findsNothing);
  });
}
