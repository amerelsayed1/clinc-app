import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../ui/common.dart';
import 'controllers.dart';
import 'models.dart';
import 'strings.dart';

/// In-app inbox (F10-1). Titles and bodies come localized from the server and are non-clinical;
/// the detail a user acts on lives behind the authenticated screens the item points to.
/// Embed as a tab body; the host provides the app bar.
class NotificationInboxView extends StatefulWidget {
  const NotificationInboxView({super.key, required this.kit, this.onOpen});
  final NotificationsKit kit;

  /// Called after an item is marked read, so the host can navigate (using [AppNotification.type] / `data`).
  final void Function(AppNotification n)? onOpen;

  @override
  State<NotificationInboxView> createState() => NotificationInboxViewState();
}

class NotificationInboxViewState extends State<NotificationInboxView> {
  final List<AppNotification> _items = [];
  String? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Hosts call this when the tab becomes visible.
  Future<void> reload() async {
    if (mounted) setState(() => _error = null);
    try {
      final page = await widget.kit.repository.inbox();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = page.nextCursor;
        _loading = false;
      });
      widget.kit.unread.refresh();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorMessage(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _more() async {
    if (_cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.kit.repository.inbox(cursor: _cursor);
      if (mounted) {
        setState(() {
          _items.addAll(page.items);
          _cursor = page.nextCursor;
        });
      }
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _open(int i) async {
    final n = _items[i];
    if (!n.read) {
      setState(() => _items[i] = n.asRead());
      widget.kit.unread.set((widget.kit.unread.count - 1).clamp(0, 1 << 30));
      try {
        await widget.kit.repository.markRead(n.id);
      } catch (_) {
        widget.kit.unread.refresh();
      }
    }
    widget.onOpen?.call(n);
  }

  Future<void> _markAll() async {
    try {
      await widget.kit.repository.markAllRead();
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < _items.length; i++) {
          _items[i] = _items[i].asRead();
        }
      });
      widget.kit.unread.set(0);
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = CareStrings.of(context);
    if (_loading) return const LoadingView();
    if (_error != null && _items.isEmpty) return ErrorView(message: _error!, onRetry: reload);
    final df = DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag()).add_jm();
    final hasUnread = _items.any((n) => !n.read);
    return RefreshIndicator(
      onRefresh: reload,
      child: _items.isEmpty
          ? ListView(children: [
              const SizedBox(height: 120),
              Icon(Icons.notifications_none, size: 56, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Center(child: Text(s.emptyInbox)),
            ])
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: _items.length + 2,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(onPressed: hasUnread ? _markAll : null, icon: const Icon(Icons.done_all), label: Text(s.markAllRead)),
                  );
                }
                if (i == _items.length + 1) {
                  return _cursor == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.all(8),
                          child: OutlinedButton(onPressed: _loadingMore ? null : _more, child: Text(s.loadMore)),
                        );
                }
                final n = _items[i - 1];
                final scheme = Theme.of(context).colorScheme;
                return Card(
                  child: ListTile(
                    key: ValueKey('notification-${n.id}'),
                    leading: Icon(_iconFor(n.type), color: n.read ? scheme.outline : scheme.primary),
                    title: Text(n.title, style: TextStyle(fontWeight: n.read ? FontWeight.normal : FontWeight.w700)),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(n.body),
                      if (n.createdAt != null) Text(df.format(n.createdAt!.toLocal()), style: Theme.of(context).textTheme.bodySmall),
                    ]),
                    trailing: n.read ? null : Icon(Icons.circle, size: 10, color: scheme.primary, semanticLabel: 'unread'),
                    onTap: () => _open(i - 1),
                  ),
                );
              },
            ),
    );
  }
}

IconData _iconFor(String type) {
  if (type.startsWith('security_')) return Icons.shield_outlined;
  if (type.startsWith('appointment_')) return Icons.event_outlined;
  if (type.startsWith('document_') || type.startsWith('encounter_')) return Icons.description_outlined;
  if (type.startsWith('access_') || type.startsWith('grant_')) return Icons.share_outlined;
  if (type.startsWith('followup_')) return Icons.monitor_heart_outlined;
  return Icons.notifications_outlined;
}

/// Bell/tab icon with the unread count.
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.unread, required this.child});
  final UnreadController unread;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: unread,
        builder: (context, _) => Semantics(
          label: CareStrings.of(context).unreadSemantics(unread.count),
          child: Badge(isLabelVisible: unread.count > 0, label: Text(unread.count > 99 ? '99+' : '${unread.count}'), child: child),
        ),
      );
}
