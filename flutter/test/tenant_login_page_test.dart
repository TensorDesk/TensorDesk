import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/tenant_login_page.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/native_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Only `translate` is reached by the page; everything else goes through the
/// injected callbacks.
class _FakeBind implements RustdeskImpl {
  static bool custom = false;

  @override
  String translate({required String name, required String locale, dynamic hint}) =>
      name;

  @override
  bool isCustomClient({dynamic hint}) => custom;

  @override
  Future<String> mainGetSystemUsername({dynamic hint}) async => 'alice';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(Widget child) => MaterialApp(home: child);

Future<void> _enterPassword(WidgetTester tester, String password) async {
  await tester.enterText(find.byType(TextField).at(1), password);
}

Future<void> _tapLogin(WidgetTester tester) async {
  await tester.tap(find.byType(ElevatedButton));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    PlatformFFI.instance.setBindingForTesting(_FakeBind());
  });

  setUp(() => _FakeBind.custom = false);

  testWidgets('managed build shows the login page instead of the app',
      (tester) async {
    _FakeBind.custom = true;
    await tester.pumpWidget(_app(const TenantLoginGate(child: Text('home'))));
    await tester.pumpAndSettle();

    expect(find.text('home'), findsNothing);
    expect(find.text('Login'), findsWidgets);
  });

  testWidgets('unmanaged build shows the app without a login page',
      (tester) async {
    await tester.pumpWidget(_app(const TenantLoginGate(child: Text('home'))));
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget);
    expect(find.text('Login'), findsNothing);
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
      readOption: (_) => '',
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

  testWidgets('existing device credential unlocks without enrolling',
      (tester) async {
    var unlocked = false;
    var activated = 0;
    await tester.pumpWidget(_app(TenantLoginPage(
      onUnlocked: () => unlocked = true,
      loadUsername: () async => 'alice',
      verify: (u, p) async => true,
      activate: (token) async {
        activated++;
        return const TenantActivationResult(true, '');
      },
      readOption: (key) => key == 'tenant-proof' ? 'tdk_x' : '',
    )));
    await tester.pumpAndSettle();

    await _enterPassword(tester, 'secret');
    await _tapLogin(tester);

    expect(unlocked, isTrue);
    expect(activated, 0);
  });

  testWidgets('no credential and no token reports an unprovisioned device',
      (tester) async {
    var unlocked = false;
    await tester.pumpWidget(_app(TenantLoginPage(
      onUnlocked: () => unlocked = true,
      loadUsername: () async => 'alice',
      verify: (u, p) async => true,
      readOption: (_) => '',
    )));
    await tester.pumpAndSettle();

    await _enterPassword(tester, 'secret');
    await _tapLogin(tester);

    expect(unlocked, isFalse);
    expect(
        find.text(
            'This device is not provisioned. Please contact your administrator.'),
        findsOneWidget);
    expect(find.text('Use an activation code'), findsOneWidget);
  });

  testWidgets('provisioned token enrolls and unlocks',
      (tester) async {
    var unlocked = false;
    String? usedToken;
    await tester.pumpWidget(_app(TenantLoginPage(
      onUnlocked: () => unlocked = true,
      loadUsername: () async => 'alice',
      verify: (u, p) async => true,
      activate: (token) async {
        usedToken = token;
        return const TenantActivationResult(true, '');
      },
      readOption: (key) => key == 'tenant-enroll-token' ? ' td1_abc ' : '',
    )));
    await tester.pumpAndSettle();

    await _enterPassword(tester, 'secret');
    await _tapLogin(tester);

    expect(usedToken, 'td1_abc');
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
      readOption: (_) => 'tdk_x',
    )));
    await tester.pumpAndSettle();

    await _tapLogin(tester);

    expect(calls, 0);
    expect(find.text('Incorrect username or password'), findsOneWidget);
  });
}
