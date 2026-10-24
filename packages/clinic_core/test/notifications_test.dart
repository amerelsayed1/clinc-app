import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeApi extends ApiClient {
  FakeApi(this.routes) : super(baseUrl: 'http://fake', tokenStore: MemoryTokenStore(const TokenPair('a', 'r')));
  final Map<String, Object? Function(Object? body, Map<String, String>? query)> routes;
  final List<String> calls = [];
  final List<Object?> bodies = [];

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, bool auth = true}) async {
    final key = '$method $path';
    calls.add(key);
    bodies.add(body);
    final h = routes[key];
    if (h == null) throw ApiException(status: 404, code: 'not_found', message: 'No fake for $key');
    return h(body, query);
  }
}

const serverTypes = [
  'appointment_reminder', 'appointment_rescheduled', 'appointment_cancelled', 'document_published', 'encounter_published', 'followup_reminder',
  'staff_invited', 'staff_joined', 'access_request_received', 'access_request_approved', 'access_request_denied', 'grant_received', 'grant_expiring',
  'security_phone_changed', 'security_mfa_enabled', 'security_mfa_disabled', 'security_new_login',
];

Map<String, dynamic> n(String id, {bool read = false, String type = 'appointment_cancelled'}) =>
    {'id': id, 'type': type, 'title': 'Title $id', 'body': 'Body $id', 'data': {}, 'createdAt': '2026-10-01T10:00:00Z', 'readAt': null, 'read': read};

Map<String, dynamic> prefsJson({String locale = 'en', bool explicit = true, List<String> disabled = const [], Map<String, dynamic>? quiet}) => {
      'locale': locale,
      'localeExplicit': explicit,
      'channels': ['push', 'sms'],
      'quietHours': quiet,
      'timezone': 'Africa/Cairo',
      'disabledTypes': disabled,
      'types': [
        {'type': 'appointment_reminder', 'mandatory': false},
        {'type': 'document_published', 'mandatory': false},
        {'type': 'security_new_login', 'mandatory': true},
      ],
      'consent': {'required': true, 'push': null, 'sms': null},
    };

Future<void> pumpScreen(WidgetTester tester, Widget child, {Locale locale = const Locale('en')}) => tester.pumpWidget(MaterialApp(
      locale: locale,
      supportedLocales: CareStrings.supportedLocales,
      localizationsDelegates: CareStrings.delegates,
      home: Scaffold(body: child),
    ));

class FakeRegistrar implements PushRegistrar {
  int requested = 0;
  int deleted = 0;
  PushToken? token = const PushToken('tok-1', 'android');
  @override
  Future<PushToken?> requestToken() async {
    requested++;
    return token;
  }

  @override
  Stream<String> get onTokenRefresh => const Stream.empty();
  @override
  Future<void> deleteToken() async => deleted++;
}

void main() {
  group('models', () {
    test('consent prompt is needed only when required and never answered', () {
      expect(const ConsentState(required: true).needsPrompt, isTrue);
      expect(const ConsentState(required: true, push: false, sms: false).needsPrompt, isFalse);
      expect(const ConsentState(required: false).needsPrompt, isFalse);
    });

    test('preferences parse quiet hours, locked types and consent', () {
      final p = NotificationPreferences.fromJson(prefsJson(quiet: {'start': '22:00', 'end': '07:00', 'timezone': 'Africa/Cairo'}, disabled: ['document_published']));
      expect(p.quietHours!.start, '22:00');
      expect(p.types.where((t) => t.mandatory).map((t) => t.type), ['security_new_login']);
      expect(p.disabledTypes, ['document_published']);
      expect(p.consent.needsPrompt, isTrue);
    });
  });

  group('strings (F10-7)', () {
    test('every server notification type has a non-fallback label in Arabic and English', () {
      for (final l in CareStrings.supportedLocales) {
        final s = CareStrings(l);
        for (final t in serverTypes) {
          expect(s.typeLabel(t), isNot('type_$t'), reason: '$t in ${l.languageCode}');
        }
      }
    });

    test('Arabic differs from English for UI strings and unknown keys fall back to the key', () {
      final en = CareStrings(const Locale('en'));
      final ar = CareStrings(const Locale('ar'));
      expect(ar.inbox, isNot(en.inbox));
      expect(ar.consentTitle, isNot(en.consentTitle));
      expect(en.get('nope'), 'nope');
      expect(ar.unreadSemantics(3), contains('3'));
    });

    test('delegates include widgets/material localizations so Arabic flips to RTL', () {
      expect(CareStrings.delegates.length, greaterThanOrEqualTo(3));
    });
  });

  group('push registration (F10-5, no provider dependency)', () {
    test('the default registrar never produces a token and nothing is posted', () async {
      final api = FakeApi({});
      final reg = PushRegistration(NotificationsRepository(api));
      await reg.sync(pushConsented: true);
      expect(api.calls, isEmpty);
      expect(reg.registeredToken, isNull);
    });

    test('does not even ask the OS before the user consents', () async {
      final api = FakeApi({});
      final r = FakeRegistrar();
      await PushRegistration(NotificationsRepository(api), r).sync(pushConsented: false);
      expect(r.requested, 0);
      expect(api.calls, isEmpty);
    });

    test('registers once after consent, and unregisters on sign-out', () async {
      final api = FakeApi({'POST /devices': (_, _) => {'id': 'd1'}, 'DELETE /devices': (_, _) => null});
      final r = FakeRegistrar();
      final reg = PushRegistration(NotificationsRepository(api), r);
      await reg.sync(pushConsented: true);
      await reg.sync(pushConsented: true);
      expect(api.calls.where((c) => c == 'POST /devices'), hasLength(1));
      expect(api.bodies.first, {'token': 'tok-1', 'platform': 'android'});
      await reg.unregister();
      expect(api.calls, contains('DELETE /devices'));
      expect(r.deleted, 1);
    });

    test('a failing server never throws into the app', () async {
      final api = FakeApi({});
      await PushRegistration(NotificationsRepository(api), FakeRegistrar()).sync(pushConsented: true);
    });
  });

  group('inbox view', () {
    testWidgets('lists items, marks one read and updates the badge, then marks all read', (tester) async {
      final api = FakeApi({
        'GET /notifications': (_, q) => {'items': [n('a'), n('b'), n('c', read: true)], 'nextCursor': null},
        'GET /notifications/unread-count': (_, _) => {'count': 2},
        'POST /notifications/a/read': (_, _) => {'ok': true},
        'POST /notifications/read-all': (_, _) => {'updated': 1},
      });
      final kit = NotificationsKit(api);
      kit.unread.set(2);
      await pumpScreen(tester, NotificationInboxView(kit: kit));
      await tester.pumpAndSettle();
      expect(find.text('Title a'), findsOneWidget);
      expect(find.text('Body b'), findsOneWidget);
      await tester.tap(find.text('Title a'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('POST /notifications/a/read'));
      expect(kit.unread.count, 1);
      await tester.tap(find.text('Mark all as read'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('POST /notifications/read-all'));
      expect(kit.unread.count, 0);
    });

    testWidgets('pages with the cursor', (tester) async {
      final api = FakeApi({
        'GET /notifications': (_, q) => q?['cursor'] == null
            ? {'items': [n('a')], 'nextCursor': 'cur1'}
            : {'items': [n('z')], 'nextCursor': null},
        'GET /notifications/unread-count': (_, _) => {'count': 0},
      });
      await pumpScreen(tester, NotificationInboxView(kit: NotificationsKit(api)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(find.text('Title z'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('empty state and Arabic RTL', (tester) async {
      final api = FakeApi({'GET /notifications': (_, _) => {'items': [], 'nextCursor': null}, 'GET /notifications/unread-count': (_, _) => {'count': 0}});
      await pumpScreen(tester, NotificationInboxView(kit: NotificationsKit(api)), locale: const Locale('ar'));
      await tester.pumpAndSettle();
      expect(find.text('لا توجد إشعارات بعد'), findsOneWidget);
      expect(Directionality.of(tester.element(find.text('لا توجد إشعارات بعد'))), TextDirection.rtl);
    });

    testWidgets('shows an error with retry', (tester) async {
      var fail = true;
      final api = FakeApi({
        'GET /notifications': (_, _) => fail ? throw ApiException(status: 500, code: 'x', message: 'Boom') : {'items': [n('a')], 'nextCursor': null},
        'GET /notifications/unread-count': (_, _) => {'count': 1},
      });
      await pumpScreen(tester, NotificationInboxView(kit: NotificationsKit(api)));
      await tester.pumpAndSettle();
      expect(find.text('Boom'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Title a'), findsOneWidget);
    });
  });

  group('preferences screen', () {
    testWidgets('security row is locked; opting out of a type and switching language call the API', (tester) async {
      Map<String, dynamic> current = prefsJson();
      final api = FakeApi({
        'GET /notification-preferences': (_, _) => current,
        'PUT /notification-preferences': (body, _) {
          final b = body as Map<String, dynamic>;
          current = prefsJson(locale: (b['locale'] as String?) ?? 'en', disabled: ((b['disabledTypes'] as List?) ?? const []).cast<String>());
          return current;
        },
      });
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final kit = NotificationsKit(api);
      await pumpScreen(tester, NotificationPreferencesScreen(kit: kit));
      await tester.pumpAndSettle();
      // Locked security notice: a plain tile with no switch.
      final locked = find.byKey(const ValueKey('type-security_new_login'));
      expect(locked, findsOneWidget);
      expect(find.descendant(of: locked, matching: find.byType(Switch)), findsNothing);
      expect(find.text('Always on'), findsOneWidget);
      // Opt out of document notices.
      await tester.tap(find.byKey(const ValueKey('type-document_published')));
      await tester.pumpAndSettle();
      expect(api.bodies.last, {'disabledTypes': ['document_published']});
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('type-document_published'))).value, isFalse);
      // Language switch updates the app locale controller and the server.
      await tester.tap(find.text('العربية'));
      await tester.pumpAndSettle();
      expect(api.bodies.last, {'locale': 'ar'});
      expect(kit.locale.locale, const Locale('ar'));
    });

    testWidgets('quiet hours toggle sends the window; turning it off sends null', (tester) async {
      Map<String, dynamic> current = prefsJson();
      final api = FakeApi({
        'GET /notification-preferences': (_, _) => current,
        'PUT /notification-preferences': (body, _) {
          final q = (body as Map<String, dynamic>)['quietHours'];
          current = prefsJson(quiet: q as Map<String, dynamic>?);
          return current;
        },
      });
      await pumpScreen(tester, NotificationPreferencesScreen(kit: NotificationsKit(api)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('quiet-switch')));
      await tester.pumpAndSettle();
      expect(api.bodies.last, {'quietHours': {'start': '22:00', 'end': '07:00', 'timezone': 'Africa/Cairo'}});
      expect(find.byKey(const ValueKey('quiet-start')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('quiet-switch')));
      await tester.pumpAndSettle();
      expect(api.bodies.last, {'quietHours': null});
    });
  });

  group('consent prompt (F10-5)', () {
    testWidgets('is shown when consent is required and unanswered, and records the choice then registers the token', (tester) async {
      final api = FakeApi({
        'GET /notification-consent': (_, _) => {'required': true, 'push': null, 'sms': null},
        'PUT /notification-consent': (body, _) => {'required': true, ...(body as Map<String, dynamic>)},
        'POST /devices': (_, _) => {'id': 'd1'},
      });
      final registrar = FakeRegistrar();
      final kit = NotificationsKit(api, registrar: registrar);
      late BuildContext ctx;
      await pumpScreen(tester, Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }));
      // Open the prompt through the public entry point.
      maybePromptForNotificationConsent(ctx, kit);
      await tester.pumpAndSettle();
      expect(find.text('Stay informed?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('consent-sms'))); // turn SMS off
      await tester.tap(find.byKey(const ValueKey('consent-save')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('PUT /notification-consent'));
      expect(api.bodies[api.calls.indexOf('PUT /notification-consent')], {'push': true, 'sms': false});
      expect(api.calls, contains('POST /devices'));
      expect(find.text('Stay informed?'), findsNothing);
    });

    testWidgets('declining records an explicit "no" and never touches the OS push permission', (tester) async {
      final api = FakeApi({
        'GET /notification-consent': (_, _) => {'required': true, 'push': null, 'sms': null},
        'PUT /notification-consent': (body, _) => {'required': true, ...(body as Map<String, dynamic>)},
      });
      final registrar = FakeRegistrar();
      final kit = NotificationsKit(api, registrar: registrar);
      late BuildContext ctx;
      await pumpScreen(tester, Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }));
      maybePromptForNotificationConsent(ctx, kit);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('consent-decline')));
      await tester.pumpAndSettle();
      expect(api.bodies[api.calls.indexOf('PUT /notification-consent')], {'push': false, 'sms': false});
      expect(registrar.requested, 0);
    });

    testWidgets('is not shown when already answered, not required, or the check fails', (tester) async {
      for (final routes in <Map<String, Object? Function(Object?, Map<String, String>?)>>[
        {'GET /notification-consent': (_, _) => {'required': true, 'push': true, 'sms': false}},
        {'GET /notification-consent': (_, _) => {'required': false, 'push': null, 'sms': null}},
        <String, Object? Function(Object?, Map<String, String>?)>{},
      ]) {
        late BuildContext ctx;
        await pumpScreen(tester, Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }));
        maybePromptForNotificationConsent(ctx, NotificationsKit(FakeApi(routes)));
        await tester.pumpAndSettle();
        expect(find.text('Stay informed?'), findsNothing);
      }
    });
  });

  group('kit startup', () {
    test('adopts an explicit saved language but not the server default', () async {
      final explicit = NotificationsKit(FakeApi({
        'GET /notification-preferences': (_, _) => prefsJson(locale: 'ar'),
        'GET /notifications/unread-count': (_, _) => {'count': 4},
      }));
      await explicit.start();
      expect(explicit.locale.locale, const Locale('ar'));
      expect(explicit.unread.count, 4);

      final implicit = NotificationsKit(FakeApi({
        'GET /notification-preferences': (_, _) => prefsJson(locale: 'ar', explicit: false),
        'GET /notifications/unread-count': (_, _) => {'count': 0},
      }));
      await implicit.start();
      expect(implicit.locale.locale, isNull);
    });

    test('survives every endpoint failing', () async {
      await NotificationsKit(FakeApi({})).start();
    });
  });
}
