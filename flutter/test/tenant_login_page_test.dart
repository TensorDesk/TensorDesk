import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/tenant_device_list.dart';
import 'package:flutter_hbb/desktop/pages/tenant_login_page.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/native_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Only `translate`, `isCustomClient`, the stored options and the system user
/// name are reached; password checks go through the injected callbacks.
class _FakeBind implements RustdeskImpl {
  static bool custom = false;

  @override
  String translate({required String name, required String locale, dynamic hint}) =>
      name;

  @override
  bool isCustomClient({dynamic hint}) => custom;

  @override
  String mainGetOptionSync({required String key, dynamic hint}) => '';

  @override
  Future<String> mainGetSystemUsername({dynamic hint}) async => 'alice';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _enterPassword(WidgetTester tester, String password) async {
  await tester.enterText(find.byType(TextField).at(1), password);
}

Future<void> _tapLogin(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ElevatedButton, 'Login'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    PlatformFFI.instance.setBindingForTesting(_FakeBind());
  });

  setUp(() => _FakeBind.custom = false);

  testWidgets('managed build guards the device list behind a login entry',
      (tester) async {
    _FakeBind.custom = true;
    await tester.pumpWidget(_app(const TenantDeviceGate()));
    await tester.pumpAndSettle();

    expect(find.byType(TenantDeviceList), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.lock_outline));
    await tester.pumpAndSettle();

    expect(find.byType(TenantLoginPage), findsOneWidget);
  });

  testWidgets('unmanaged build keeps the device list without a login entry',
      (tester) async {
    await tester.pumpWidget(_app(const TenantDeviceGate()));
    await tester.pumpAndSettle();

    expect(find.byType(TenantDeviceList), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
    expect(find.byType(TenantLoginPage), findsNothing);
  });

  testWidgets('wrong password shows one generic error and clears it',
      (tester) async {
    var calls = 0;
    var unlocked = false;
    await tester.pumpWidget(_app(TenantLoginPage(
      onUnlocked: () => unlocked = true,
      loadUsername: () async => 'alice',
      verify: (u, p) async {
        calls++;
        return false;
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('alice'), findsOneWidget);

    await _enterPassword(tester, 'wrong');
    await _tapLogin(tester);

    expect(calls, 1);
    expect(unlocked, isFalse);
    expect(find.text('Incorrect username or password'), findsOneWidget);
    final password = tester.widgetList<TextField>(find.byType(TextField)).last;
    expect(password.controller!.text, isEmpty);
  });

  testWidgets('correct password unlocks for this run', (tester) async {
    var unlocked = false;
    await tester.pumpWidget(_app(TenantLoginPage(
      onUnlocked: () => unlocked = true,
      loadUsername: () async => 'alice',
      verify: (u, p) async => true,
    )));
    await tester.pumpAndSettle();

    await _enterPassword(tester, 'secret');
    await _tapLogin(tester);

    expect(unlocked, isTrue);
  });

  testWidgets('empty password never reaches the verifier', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_app(TenantLoginPage(
      onUnlocked: () {},
      loadUsername: () async => 'alice',
      verify: (u, p) async {
        calls++;
        return true;
      },
    )));
    await tester.pumpAndSettle();

    await _tapLogin(tester);

    expect(calls, 0);
    expect(find.text('Incorrect username or password'), findsOneWidget);
  });
}
