import 'package:carelink_clinic/src/feature.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ClinicFeature f(String id, {bool bottom = false, int order = 100}) =>
    ClinicFeature(id: id, label: id, icon: Icons.circle, inBottomBar: bottom, order: order, builder: (_, _) => const SizedBox());

void main() {
  test('no More when everything fits in five bottom slots', () {
    final l = NavLayout.compute([for (var i = 0; i < 5; i++) f('b$i', bottom: true, order: i)]);
    expect(l.bottom.length, 5);
    expect(l.hasMore, isFalse);
  });

  test('More takes non-bottom features and bottom overflow, bottom is capped at 4 + More', () {
    final l = NavLayout.compute([for (var i = 0; i < 6; i++) f('b$i', bottom: true, order: i), f('x', order: 3)]);
    expect(l.bottom.map((e) => e.id), ['b0', 'b1', 'b2', 'b3']);
    expect(l.more.map((e) => e.id), ['x', 'b4', 'b5'].toList()..sort((a, b) => (a == 'x' ? 3 : int.parse(a.substring(1))).compareTo(b == 'x' ? 3 : int.parse(b.substring(1)))));
  });

  test('registry replaces a feature with the same id and sorts by order', () {
    final r = FeatureRegistry()
      ..add(f('a', order: 2))
      ..add(f('b', order: 1))
      ..add(f('a', order: 0));
    expect(r.all.map((e) => e.id), ['a', 'b']);
  });
}
