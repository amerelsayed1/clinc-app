import 'package:flutter/material.dart';

import 'session.dart';

/// Unread-style badge on a navigation destination.
class ClinicBadge {
  const ClinicBadge({required this.listenable, required this.count});
  final Listenable listenable;
  final int Function() count;
}

/// One screen of the clinic app. Register it from a `registerXxx` function (see features.dart).
class ClinicFeature {
  const ClinicFeature({
    required this.id,
    required this.label,
    required this.icon,
    required this.builder,
    this.selectedIcon,
    this.requiredPermission,
    this.alsoRequires = const [],
    this.inBottomBar = false,
    this.order = 100,
    this.badge,
  });

  /// Stable id (also the key for tests / `ClinicSession.selectedFeature`).
  final String id;
  final String label;
  final IconData icon;
  final IconData? selectedIcon;

  /// Feature is hidden unless the active membership has this permission (null = everyone).
  final String? requiredPermission;

  /// Further permissions that must all be present (e.g. data requests need staff.manage + clinical.read).
  final List<String> alsoRequires;

  /// Wants a bottom-bar slot. At most 4 (or 5 when nothing else is left for "More") are shown; the rest
  /// spill into More, ordered by [order].
  final bool inBottomBar;

  /// Lower comes first.
  final int order;

  /// The body. The shell supplies the AppBar (title = [label]) and the bottom bar; return the content
  /// only. A feature may wrap its body in its own `Scaffold` (no appBar) for a FAB. Push detail
  /// screens with `Navigator.push` and give them their own `Scaffold(appBar: ...)`.
  final Widget Function(BuildContext context, ClinicSession session) builder;

  final ClinicBadge? Function(ClinicSession session)? badge;

  bool visibleTo(ClinicSession s) =>
      (requiredPermission == null || s.can(requiredPermission!)) && s.canAll(alsoRequires);
}

typedef FeatureRegistrar = void Function(FeatureRegistry registry);

class FeatureRegistry {
  final Map<String, ClinicFeature> _features = {};

  /// Registers (or replaces, same id) a feature.
  void add(ClinicFeature feature) => _features[feature.id] = feature;

  List<ClinicFeature> get all => _features.values.toList()..sort((a, b) => a.order.compareTo(b.order));

  List<ClinicFeature> visibleFor(ClinicSession s) => all.where((f) => f.visibleTo(s)).toList();
}

/// Splits visible features into bottom-bar destinations and the "More" list.
class NavLayout {
  const NavLayout({required this.bottom, required this.more});
  final List<ClinicFeature> bottom;
  final List<ClinicFeature> more;
  bool get hasMore => more.isNotEmpty;

  factory NavLayout.compute(List<ClinicFeature> visible) {
    final wanted = visible.where((f) => f.inBottomBar).toList();
    final rest = visible.where((f) => !f.inBottomBar).toList();
    if (rest.isEmpty && wanted.length <= 5) return NavLayout(bottom: wanted, more: const []);
    final bottom = wanted.take(4).toList();
    final more = [...wanted.skip(4), ...rest]..sort((a, b) => a.order.compareTo(b.order));
    return NavLayout(bottom: bottom, more: more);
  }
}

/// Body for features that are registered but not built yet.
class ComingSoon extends StatelessWidget {
  const ComingSoon(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.construction_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Coming soon'),
          ]),
        ),
      );
}
