import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_bms/features/monitoring/monitoring_demo_screen.dart';

void main() {
  testWidgets('monitoring demo opens with the BMS-003 sample', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MonitoringDemoScreen()));

    expect(find.text('Monitoring Device'), findsOneWidget);
    expect(find.text('BMS-003'), findsOneWidget);
    expect(find.text('52%'), findsOneWidget);
    expect(find.text('Live demo data'), findsOneWidget);

    await tester.tap(find.text('Simulate fault'));
    await tester.pump();

    expect(find.text('Clear fault'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('FAULT'), 200);
    expect(find.text('FAULT'), findsOneWidget);
  });

  testWidgets('monitoring demo can simulate a low battery', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MonitoringDemoScreen()));

    await tester.tap(find.text('Simulate low battery'));
    await tester.pump();

    expect(find.text('12%'), findsOneWidget);
    // Shown in both the badge and the Status row of the charge card.
    expect(find.text('Low'), findsNWidgets(2));
    expect(find.text('Charging'), findsNothing);
    expect(find.text('Clear low battery'), findsOneWidget);

    await tester.tap(find.text('Clear low battery'));
    await tester.pump();

    expect(find.text('52%'), findsOneWidget);
    expect(find.text('Charging'), findsNWidgets(2));
  });

  testWidgets('device settings opens safely from monitoring demo', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MonitoringDemoScreen()));

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text('BMS Setting'), findsOneWidget);
    expect(find.text('Battery Type'), findsOneWidget);
  });
}
