import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import 'push.dart';
import 'repository.dart';

/// App language, switchable at runtime. Wire it into `MaterialApp(locale: ...)`.
class LocaleController extends ChangeNotifier {
  LocaleController([Locale? initial]) : _locale = initial;
  Locale? _locale; // null = follow the device

  Locale? get locale => _locale;
  bool get isRtl => _locale?.languageCode == 'ar';

  void set(Locale? l) {
    if (l?.languageCode == _locale?.languageCode) return;
    _locale = l;
    notifyListeners();
  }
}

/// Unread count for the inbox badge. Errors keep the previous count.
class UnreadController extends ChangeNotifier {
  UnreadController(this._repo);
  final NotificationsRepository _repo;
  int _count = 0;
  int get count => _count;

  Future<void> refresh() async {
    try {
      final n = await _repo.unreadCount();
      if (n != _count) {
        _count = n;
        notifyListeners();
      }
    } catch (_) {}
  }

  void set(int n) {
    if (n == _count) return;
    _count = n;
    notifyListeners();
  }
}

/// Everything an app needs for spec 10, built from its [ApiClient]. Apps keep one instance.
class NotificationsKit {
  NotificationsKit(ApiClient api, {PushRegistrar? registrar, LocaleController? locale})
      : repository = NotificationsRepository(api),
        locale = locale ?? LocaleController() {
    unread = UnreadController(repository);
    push = PushRegistration(repository, registrar);
  }

  final NotificationsRepository repository;
  final LocaleController locale;
  late final UnreadController unread;
  late final PushRegistration push;

  /// Call once after sign-in: adopts the language the user saved on the server, registers the push
  /// token if they already consented, and loads the unread badge. Safe to call repeatedly.
  Future<void> start() async {
    try {
      final p = await repository.preferences();
      if (p.localeExplicit) locale.set(Locale(p.locale));
      await push.sync(pushConsented: p.consent.push == true);
    } catch (_) {}
    await unread.refresh();
  }
}
