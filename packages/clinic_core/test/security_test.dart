import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAuthenticator implements DeviceAuthenticator {
  FakeAuthenticator({this.available = true, this.succeed = true});
  bool available;
  bool succeed;
  int prompts = 0;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return succeed;
  }
}

AppLockController makeLock(FakeAuthenticator auth, {bool enabled = false, Duration grace = Duration.zero, DateTime Function()? clock}) =>
    AppLockController(authenticator: auth, store: MemoryLockSettingsStore(enabled), gracePeriod: grace, clock: clock);

void main() {
  group('AppLockController', () {
    test('turning the lock on requires a successful authentication and device support', () async {
      final auth = FakeAuthenticator(succeed: false);
      final lock = makeLock(auth);
      await lock.load();
      expect(await lock.enable(), isFalse);
      expect(lock.enabled, isFalse);
      auth.succeed = true;
      auth.available = false;
      expect(await lock.enable(), isFalse); // no screen lock on the device
      auth.available = true;
      expect(await lock.enable(), isTrue);
      expect(lock.enabled, isTrue);
      expect(lock.locked, isFalse);
    });

    test('locks when the app is backgrounded and unlocks only after authentication', () async {
      final auth = FakeAuthenticator();
      final lock = makeLock(auth);
      await lock.load();
      await lock.enable();
      lock.onLifecycle(AppLifecycleState.inactive);
      expect(lock.locked, isFalse, reason: 'inactive also fires for the biometric prompt itself');
      lock.onLifecycle(AppLifecycleState.paused);
      expect(lock.locked, isTrue);
      auth.succeed = false;
      expect(await lock.unlock(), isFalse);
      expect(lock.locked, isTrue);
      auth.succeed = true;
      expect(await lock.unlock(), isTrue);
      expect(lock.locked, isFalse);
    });

    test('a grace period delays the lock until the app returns after too long', () async {
      var now = DateTime(2026, 1, 1, 12);
      final lock = makeLock(FakeAuthenticator(), grace: const Duration(minutes: 1), clock: () => now);
      await lock.load();
      await lock.enable();
      lock.onLifecycle(AppLifecycleState.paused);
      expect(lock.locked, isFalse);
      now = now.add(const Duration(seconds: 20));
      lock.onLifecycle(AppLifecycleState.resumed);
      expect(lock.locked, isFalse);
      lock.onLifecycle(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 2));
      lock.onLifecycle(AppLifecycleState.resumed);
      expect(lock.locked, isTrue);
    });

    test('a saved setting makes a cold start begin locked; disabling needs authentication', () async {
      final auth = FakeAuthenticator();
      final lock = makeLock(auth, enabled: true);
      await lock.load();
      expect(lock.locked, isTrue);
      await lock.unlock();
      auth.succeed = false;
      expect(await lock.disable(), isFalse);
      expect(lock.enabled, isTrue);
      auth.succeed = true;
      expect(await lock.disable(), isTrue);
      expect(lock.enabled, isFalse);
      lock.onLifecycle(AppLifecycleState.paused);
      expect(lock.locked, isFalse);
    });
  });

  group('widgets', () {
    testWidgets('AppLockGate hides the content while locked and prompts to unlock', (tester) async {
      final auth = FakeAuthenticator(succeed: false);
      final lock = makeLock(auth, enabled: true);
      await tester.pumpWidget(MaterialApp(home: AppLockGate(controller: lock, child: const Scaffold(body: Text('Patient record')))));
      await tester.pumpAndSettle();
      expect(find.text('CareLink is locked'), findsOneWidget);
      expect(find.text('Patient record'), findsNothing, reason: 'locked content must not be painted');
      expect(auth.prompts, greaterThan(0));
      auth.succeed = true;
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(find.text('Patient record'), findsOneWidget);
      expect(find.text('CareLink is locked'), findsNothing);
    });

    testWidgets('AppLockGate locks on the background event but keeps the screen state', (tester) async {
      final auth = FakeAuthenticator();
      final lock = makeLock(auth);
      await tester.pumpWidget(MaterialApp(home: AppLockGate(controller: lock, child: const Scaffold(body: TextField(key: Key('f'))))));
      await tester.pumpAndSettle();
      await lock.enable();
      await tester.enterText(find.byKey(const Key('f')), 'draft note');
      expect(find.text('draft note'), findsOneWidget);
      auth.succeed = false;
      for (final st in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(st);
      }
      await tester.pumpAndSettle();
      expect(find.text('CareLink is locked'), findsOneWidget);
      expect(find.byKey(const Key('f')), findsNothing);
      for (final st in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(st);
      }
      auth.succeed = true;
      await lock.unlock();
      await tester.pumpAndSettle();
      expect(find.text('draft note'), findsOneWidget);
    });

    testWidgets('PrivacyShield covers the content whenever the app is not in the foreground', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: PrivacyShield(child: Scaffold(body: Text('Diagnosis: asthma')))));
      expect(find.byKey(const ValueKey('privacy-cover')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byKey(const ValueKey('privacy-cover')), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(const ValueKey('privacy-cover')), findsNothing);
    });

    testWidgets('AppLockTile asks to authenticate and explains failures', (tester) async {
      final auth = FakeAuthenticator(available: false);
      final lock = makeLock(auth);
      await lock.load();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: AppLockTile(controller: lock))));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.textContaining('needs a screen lock'), findsOneWidget);
      auth.available = true;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(lock.enabled, isTrue);
    });
  });

  group('SecureScreen', () {
    testWidgets('sets and clears the Android secure flag, reference counted', (tester) async {
      final calls = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SecureScreen.channel, (call) async {
        calls.add((call.arguments as Map)['secure'] as bool);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SecureScreen.channel, null));
      await tester.pumpWidget(const MaterialApp(home: SecureScreenScope(child: SecureScreenScope(child: Text('x')))));
      expect(calls, [true], reason: 'nested scopes share one flag');
      await tester.pumpWidget(const MaterialApp(home: Text('gone')));
      expect(calls, [true, false]);
      expect(SecureScreen.holders, 0);
    });

    testWidgets('is a silent no-op where the channel does not exist', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SecureScreenScope(child: Text('x'))));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const MaterialApp(home: Text('y')));
      expect(SecureScreen.holders, 0);
    });
  });
}
