import 'package:flutter/material.dart';

import '../ui/common.dart';
import 'controllers.dart';
import 'strings.dart';

/// Shows the consent prompt once, on first launch, to users registered by a doctor who have not yet
/// answered (F10-5). Until they do, the server sends nothing outside the app. Any failure to
/// check is ignored: the prompt is retried on the next launch.
Future<void> maybePromptForNotificationConsent(BuildContext context, NotificationsKit kit) async {
  try {
    final c = await kit.repository.consent();
    if (!c.needsPrompt || !context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => NotificationConsentPrompt(kit: kit)));
  } catch (_) {}
}

class NotificationConsentPrompt extends StatefulWidget {
  const NotificationConsentPrompt({super.key, required this.kit});
  final NotificationsKit kit;

  @override
  State<NotificationConsentPrompt> createState() => _NotificationConsentPromptState();
}

class _NotificationConsentPromptState extends State<NotificationConsentPrompt> {
  bool _push = true;
  bool _sms = true;
  bool _busy = false;

  Future<void> _submit(bool push, bool sms) async {
    setState(() => _busy = true);
    try {
      await widget.kit.repository.saveConsent(push: push, sms: sms);
      await widget.kit.push.sync(pushConsented: push);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showSnack(context, errorMessage(e), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = CareStrings.of(context);
    return PopScope(
      canPop: false, // answer explicitly: "No thanks" is a recorded choice, not a dismissal
      child: Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(24), children: [
            const SizedBox(height: 24),
            Icon(Icons.notifications_active_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(s.consentTitle, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(s.consentBody),
            const SizedBox(height: 16),
            SwitchListTile(key: const ValueKey('consent-push'), title: Text(s.consentPush), value: _push, onChanged: _busy ? null : (v) => setState(() => _push = v)),
            SwitchListTile(key: const ValueKey('consent-sms'), title: Text(s.consentSms), value: _sms, onChanged: _busy ? null : (v) => setState(() => _sms = v)),
            const SizedBox(height: 8),
            Text(s.consentPrivacyNote, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 24),
            FilledButton(key: const ValueKey('consent-save'), onPressed: _busy ? null : () => _submit(_push, _sms), child: Text(s.consentAllow)),
            const SizedBox(height: 8),
            TextButton(key: const ValueKey('consent-decline'), onPressed: _busy ? null : () => _submit(false, false), child: Text(s.consentLater)),
          ]),
        ),
      ),
    );
  }
}
