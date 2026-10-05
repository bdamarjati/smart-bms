import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_bms/features/devices/saved_device.dart';
import 'package:smart_bms/features/monitoring/device_monitoring_screen.dart';
import 'package:smart_bms/features/settings/app_settings.dart';
import 'package:smart_bms/features/settings/app_settings_controller.dart';

void main() {
  testWidgets('monitoring dashboard shows the selected device and metrics', (
    tester,
  ) async {
    final device = SavedDevice(
      id: 'AA:BB:CC:DD:EE:03',
      name: 'BMS-003',
      savedAt: DateTime.utc(2026, 7, 29),
    );

    await tester.pumpWidget(
      MaterialApp(home: DeviceMonitoringScreen(device: device, demoMode: true)),
    );

    expect(find.text('Monitoring Device'), findsOneWidget);
    expect(find.text('BMS-003'), findsOneWidget);
    expect(find.text('Stage of Charge'), findsOneWidget);
    expect(find.text('52%'), findsOneWidget);
    // Shown in both the badge and the Status row of the charge card.
    expect(find.text('Charging'), findsNWidgets(2));
    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
    expect(find.text('Remaining Capacity'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('18.00 A'), 200);
    expect(find.text('54.60 V'), findsOneWidget);
    expect(find.text('18.00 A'), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pump();

    expect(find.text('Error Logs'), findsOneWidget);
    expect(find.text('No error code'), findsOneWidget);
  });

  testWidgets('cell tab shows voltage statistics and all demo cells', (
    tester,
  ) async {
    final device = SavedDevice(
      id: 'AA:BB:CC:DD:EE:03',
      name: 'BMS-003',
      savedAt: DateTime.utc(2026, 7, 29),
    );

    await tester.pumpWidget(
      MaterialApp(home: DeviceMonitoringScreen(device: device, demoMode: true)),
    );

    await tester.ensureVisible(find.text('Cell'));
    await tester.tap(find.text('Cell'));
    await tester.pump();

    expect(find.text('Statistic'), findsOneWidget);
    expect(find.text('VCell Max (V)'), findsOneWidget);
    expect(find.text('VCell Min (V)'), findsOneWidget);
    expect(find.text('Cell Voltage (V)'), findsOneWidget);
    expect(find.text('24 cells'), findsOneWidget);
    expect(find.text('3.881'), findsNWidgets(2));
    expect(find.text('24'), findsOneWidget);
    expect(find.text('Error Logs'), findsNothing);
  });

  testWidgets('monitoring temperature follows the app temperature unit', (
    tester,
  ) async {
    final controller = AppSettingsController();
    final device = SavedDevice(
      id: 'AA:BB:CC:DD:EE:03',
      name: 'BMS-003',
      savedAt: DateTime.utc(2026, 7, 29),
    );

    await tester.pumpWidget(
      AppSettingsScope(
        controller: controller,
        child: MaterialApp(
          home: DeviceMonitoringScreen(device: device, demoMode: true),
        ),
      ),
    );

    await tester.scrollUntilVisible(find.text('30.0°C'), 200);
    expect(find.text('30.0°C'), findsOneWidget);

    await controller.setTemperatureUnit(TemperatureUnit.fahrenheit);
    await tester.pump();

    expect(find.text('86.0°F'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('monitoring dashboard follows the Indonesian locale', (
    tester,
  ) async {
    final device = SavedDevice(
      id: 'AA:BB:CC:DD:EE:03',
      name: 'BMS-003',
      savedAt: DateTime.utc(2026, 7, 29),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('id'),
        supportedLocales: const [Locale('en'), Locale('id')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: DeviceMonitoringScreen(device: device, demoMode: true),
      ),
    );

    expect(find.text('Pemantauan Perangkat'), findsOneWidget);
    expect(find.text('Tingkat Daya'), findsOneWidget);
    expect(find.text('Mengisi daya'), findsNWidgets(2));
    await tester.scrollUntilVisible(find.text('Tegangan'), 200);
    expect(find.text('Tegangan'), findsOneWidget);
  });
}
