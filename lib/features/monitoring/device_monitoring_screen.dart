import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../devices/saved_device.dart';
import '../settings/app_settings.dart';
import '../settings/app_settings_controller.dart';
import '../settings/bms_settings.dart';
import '../settings/bms_settings_screen.dart';
import 'ble_debug_controller.dart';
import 'ble_debug_screen.dart';
import 'bms_csv_logger.dart';
import 'bms_error_catalog.dart';
import 'bms_telemetry.dart';

class DeviceMonitoringScreen extends StatefulWidget {
  const DeviceMonitoringScreen({
    required this.device,
    this.demoMode = false,
    super.key,
  });

  final SavedDevice device;
  final bool demoMode;

  @override
  State<DeviceMonitoringScreen> createState() => _DeviceMonitoringScreenState();
}

class _DeviceMonitoringScreenState extends State<DeviceMonitoringScreen> {
  static const _kConnectionTimeout = Duration(seconds: 12);
  static const _kDisconnectDelay = Duration(milliseconds: 300);
  static const _kDemoInterval = Duration(seconds: 2);
  static const _kTelemetryBufferSize = 32768;
  static const _kLowBatteryThreshold = 0.15;
  static const _kChargingCurrentThreshold = 0.5;
  static const _kDemoVoltageMin = 48.0;
  static const _kDemoVoltageMax = 58.0;
  static const _kDemoTempMin = 15.0;
  static const _kDemoTempMax = 65.0;
  static const _kDemoCellVoltageDelta = 15;
  static const _kDemoChargeMin = 0.05;
  static const _kDemoChargeMax = 0.98;
  static const _kDemoChargeLowMax = 0.14;
  static const _kDemoChargeDelta = 0.008;
  static const _kDemoChargeBias = 0.54;
  static const _kDemoChargeNormal = 0.52;
  static const _kDemoChargeLow = 0.12;
  static const _kDemoCellVoltageClampMin = 0;
  static const _kDemoCellVoltageClampMax = 5000;
  static const _kDemoVoltageRange = 0.8;
  static const _kDemoVoltageNormal = 54.6;
  static const _kDemoTempBase = 30.0;
  static const _kDemoTempVariance = 3.0;
  static const _kDemoCurrentNormal = 18.0;
  static const _kHistoryLength = 24;
  bool _showPackMetrics = true;
  bool _demoRunning = true;
  bool _demoFault = false;
  bool _demoLowBattery = false;
  bool _hasTelemetry = false;
  double _charge = 0.52;
  double _voltage = _kDemoVoltageNormal;
  double _current = _kDemoCurrentNormal;
  double _temperature = 30;
  List<int> _cellVoltageMillivolts = [
    3650,
    3156,
    2684,
    1650,
    516,
    2568,
    1165,
    1210,
    1256,
    3251,
    2785,
    3051,
    3120,
    2015,
    3551,
    2017,
    2320,
    3020,
    3881,
    3255,
    3210,
    2650,
    2054,
    3561,
  ];
  int _errorCode = 0;
  String? _serialNumber;
  DateTime? _lastTelemetryAt;
  BleDebugMessage? _lastTelemetryMessage;
  String _telemetryBuffer = '';
  String? _telemetryCharacteristicId;
  Timer? _demoTimer;
  final math.Random _random = math.Random(3);
  final List<double> _voltageHistory = [];
  final List<double> _currentHistory = [];
  final List<double> _temperatureHistory = [];
  late final List<_ErrorLogEntry> _errorLogs;

  FlutterReactiveBle? _ble;
  StreamSubscription<BleStatus>? _bleStatusSubscription;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  BleStatus _bleStatus = BleStatus.unknown;
  DeviceConnectionState _connectionState = DeviceConnectionState.disconnected;
  bool _connectionRequested = false;
  bool _connectionAttemptActive = false;
  bool _isClosing = false;
  bool _allowPop = false;
  int _connectionGeneration = 0;
  String? _connectionError;
  BleDebugController? _debugController;
  BmsCsvLogger? _csvLogger;
  BmsSettings? _deviceSettings;

  @override
  void initState() {
    super.initState();
    if (widget.demoMode) {
      _errorLogs = [];
      _deviceSettings = BmsSettings.defaults().applyBatteryTypePreset(
        BmsBatteryType.nmc,
      );
      _seedDemoHistory();
      _startDemo();
    } else {
      _errorLogs = [];
      _charge = 0;
      _initializeBluetoothConnection();
    }
  }

  @override
  void dispose() {
    _isClosing = true;
    _connectionRequested = false;
    _connectionGeneration++;
    _demoTimer?.cancel();
    unawaited(_finishDataRecording(notify: false));
    _debugController?.dispose();
    _bleStatusSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appSettings = AppSettingsScope.maybeOf(context);
    final temperatureUnit =
        appSettings?.temperatureUnit ?? TemperatureUnit.celsius;
    final hasData = _hasTelemetry || widget.demoMode;
    final packVoltage = hasData ? '${_voltage.toStringAsFixed(2)} V' : '--';
    final packCurrent = hasData ? '${_current.toStringAsFixed(2)} A' : '--';
    final temperature = hasData
        ? '${temperatureUnit.convertFromCelsius(_temperature).toStringAsFixed(1)}'
              '${temperatureUnit.symbol}'
        : '--';
    final status = widget.demoMode
        ? (_demoFault ? context.translate('FAULT', 'GANGGUAN') : 'OK')
        : !_hasTelemetry
        ? '--'
        : _errorCode == 0
        ? 'OK'
        : context.translate('ERROR', 'KESALAHAN');
    final statusTone = status == 'OK'
        ? AppColors.success
        : status == '--'
        ? AppColors.textMuted
        : AppColors.danger;
    final isCharging = hasData && _current > _kChargingCurrentThreshold;
    final isDischarging = hasData && _current < -_kChargingCurrentThreshold;
    final isLow = hasData && _charge < _kLowBatteryThreshold;
    final capacity = _deviceSettings?.valueFor(BmsSettingKey.batteryCapacity);
    final remainingCapacity = !hasData
        ? '--'
        : capacity == null
        ? '${(_charge * 100).round()}%'
        : '${(_charge * capacity).toStringAsFixed(1)} Ah';
    final (chargeStatus, chargeStatusColor) = !hasData
        ? ('--', AppColors.textMuted)
        : isLow
        ? (context.translate('Low', 'Lemah'), AppColors.danger)
        : isCharging
        ? (context.translate('Charging', 'Mengisi daya'), AppColors.info)
        : isDischarging
        ? (context.translate('Discharging', 'Mengosongkan'), AppColors.accent)
        : (context.translate('Normal', 'Normal'), AppColors.success);

    final metrics = [
      _MetricData(
        label: context.translate('Voltage', 'Tegangan'),
        value: packVoltage,
        icon: Icons.flash_on_rounded,
        tone: AppColors.info,
        history: hasData ? List.unmodifiable(_voltageHistory) : null,
      ),
      _MetricData(
        label: context.translate('Current', 'Arus'),
        value: packCurrent,
        icon: Icons.monitor_heart_outlined,
        tone: AppColors.success,
        history: hasData ? List.unmodifiable(_currentHistory) : null,
      ),
      _MetricData(
        label: context.translate('Temperature', 'Suhu'),
        value: temperature,
        icon: Icons.thermostat_rounded,
        tone: AppColors.warning,
        history: hasData ? List.unmodifiable(_temperatureHistory) : null,
      ),
      _MetricData(
        label: context.translate('Status', 'Status'),
        value: status,
        icon: Icons.shield_outlined,
        tone: statusTone,
        badge: status == '--'
            ? null
            : status == 'OK'
            ? Icons.check_rounded
            : Icons.priority_high_rounded,
      ),
    ];

    return PopScope(
      canPop: widget.demoMode || _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_closeAndPop());
      },
      child: Scaffold(
        floatingActionButton:
            !widget.demoMode &&
                (appSettings?.showRawJson ?? false) &&
                _connectionState == DeviceConnectionState.connected
            ? FloatingActionButton.extended(
                tooltip: context.translate(
                  'Open raw BLE debug',
                  'Buka debug BLE mentah',
                ),
                onPressed: _openDebugPage,
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                icon: const Icon(Icons.data_object_rounded),
                label: const Text(''),
              )
            : null,
        body: SafeArea(
          child: CustomScrollView(
            physics: const ClampingScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                sliver: SliverList.list(
                  children: [
                    _MonitoringHeader(
                      onBack: _closeAndPop,
                      onSettings: _showSettingsMessage,
                    ),
                    const SizedBox(height: 22),
                    _DeviceCard(
                      name: _serialNumber ?? widget.device.name,
                      onTap: _showSettingsMessage,
                    ),
                    const SizedBox(height: 14),
                    if (widget.demoMode) ...[
                      _ConnectionCard(
                        tone: _demoRunning
                            ? AppColors.success
                            : AppColors.textMuted,
                        icon: Icons.bluetooth_rounded,
                        title: _demoRunning
                            ? context.translate(
                                'Live demo data',
                                'Data demo langsung',
                              )
                            : context.translate('Demo paused', 'Demo dijeda'),
                        detail: widget.device.id,
                        actionLabel: _demoRunning
                            ? context.translate('Pause', 'Jeda')
                            : context.translate('Resume', 'Lanjutkan'),
                        onAction: _toggleDemo,
                      ),
                      const SizedBox(height: 10),
                      _DemoControls(
                        faultActive: _demoFault,
                        lowBatteryActive: _demoLowBattery,
                        onNewSample: _updateDemoData,
                        onToggleFault: _toggleDemoFault,
                        onToggleLowBattery: _toggleDemoLowBattery,
                      ),
                    ] else
                      _ConnectionPanel(
                        deviceId: widget.device.id,
                        bleStatus: _bleStatus,
                        connectionState: _connectionState,
                        errorMessage: _connectionError,
                        onRetry: _prepareConnection,
                        onDisconnect: _disconnect,
                      ),
                    const SizedBox(height: 14),
                    _StateOfChargeCard(
                      charge: _charge,
                      hasData: hasData,
                      isCharging: isCharging,
                      isLow: isLow,
                      subtitle: _chargeStatusLabel(context),
                      remainingCapacity: remainingCapacity,
                      status: chargeStatus,
                      statusColor: chargeStatusColor,
                    ),
                    const SizedBox(height: 22),
                    Center(
                      child: _PackCellToggle(
                        showPack: _showPackMetrics,
                        onChanged: (showPack) {
                          setState(() => _showPackMetrics = showPack);
                        },
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (_showPackMetrics) ...[
                      _MetricGrid(metrics: metrics),
                      const SizedBox(height: 14),
                      _ErrorLogTable(rows: _errorLogs),
                    ] else
                      _CellMonitoringSection(
                        cellVoltages: hasData
                            ? _cellVoltageMillivolts
                            : const [],
                      ),
                    const SizedBox(height: 24),
                    const Text(
                      AppTheme.brandName,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSettingsMessage() {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BmsSettingsScreen(
          device: widget.device,
          demoMode: widget.demoMode,
          initialSettings: _deviceSettings,
          onSendParameters:
              !widget.demoMode &&
                  _connectionState == DeviceConnectionState.connected
              ? _debugController?.writeJson
              : null,
        ),
      ),
    );
  }

  void _initializeBluetoothConnection() {
    final ble = FlutterReactiveBle();
    _ble = ble;
    _bleStatusSubscription = ble.statusStream.listen((status) {
      if (!mounted || _isClosing) return;
      setState(() => _bleStatus = status);

      if (status == BleStatus.ready &&
          _connectionRequested &&
          !_connectionAttemptActive &&
          _connectionState != DeviceConnectionState.connected) {
        _connect();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareConnection());
  }

  Future<void> _prepareConnection() async {
    if (widget.demoMode || _connectionAttemptActive || _isClosing) return;
    _connectionRequested = true;

    if (defaultTargetPlatform == TargetPlatform.android) {
      final permission = await Permission.bluetoothConnect.request();
      if (!mounted || _isClosing) return;
      if (!permission.isGranted) {
        setState(() {
          _connectionError = context.translate(
            'Nearby-device permission is required to connect.',
            'Izin perangkat terdekat diperlukan untuk menghubungkan.',
          );
          _connectionRequested = false;
        });
        return;
      }
    }

    final ble = _ble;
    if (ble == null) return;
    if (ble.status == BleStatus.ready) {
      await _connect();
    } else if (mounted) {
      setState(() {
        _connectionError = _messageForBleStatus(context, ble.status);
      });
    }
  }

  Future<void> _connect() async {
    final ble = _ble;
    if (ble == null || _connectionAttemptActive || _isClosing) return;

    final generation = ++_connectionGeneration;
    _connectionAttemptActive = true;
    await _connectionSubscription?.cancel();
    if (!mounted ||
        _isClosing ||
        generation != _connectionGeneration ||
        !_connectionRequested) {
      _connectionAttemptActive = false;
      return;
    }

    setState(() {
      _connectionState = DeviceConnectionState.connecting;
      _connectionError = null;
    });

    _connectionSubscription = ble
        .connectToDevice(
          id: widget.device.id,
          connectionTimeout: _kConnectionTimeout,
        )
        .listen(
          (update) {
            if (!mounted || _isClosing || generation != _connectionGeneration) {
              return;
            }
            if (update.connectionState == DeviceConnectionState.connected) {
              _startDataRecording();
              _startDebugCapture();
            }
            setState(() {
              _connectionState = update.connectionState;
              _connectionError = update.failure == null
                  ? null
                  : context.translate(
                      'The BMS reported a Bluetooth connection failure.',
                      'BMS melaporkan kegagalan koneksi Bluetooth.',
                    );
            });

            if (update.connectionState == DeviceConnectionState.disconnected) {
              _debugController?.stop();
              unawaited(_finishDataRecording());
              _connectionAttemptActive = false;
              _connectionRequested = false;
            }
          },
          onError: (Object error) {
            if (!mounted || _isClosing || generation != _connectionGeneration) {
              return;
            }
            setState(() {
              _connectionState = DeviceConnectionState.disconnected;
              _connectionError = context.translate(
                'Could not connect. Keep the BMS nearby and advertising.',
                'Tidak dapat terhubung. Pastikan BMS berada di dekat dan sedang mengirim sinyal.',
              );
            });
            _connectionAttemptActive = false;
            _connectionRequested = false;
            unawaited(_finishDataRecording());
          },
          onDone: () {
            if (generation != _connectionGeneration) return;
            _connectionAttemptActive = false;
          },
        );
  }

  Future<void> _disconnect() async {
    if (_isClosing) return;
    _connectionRequested = false;
    _connectionGeneration++;
    if (mounted) {
      setState(() {
        _connectionState = DeviceConnectionState.disconnecting;
        _connectionError = null;
      });
    }

    await _debugController?.stop();
    await _finishDataRecording();
    await Future<void>.delayed(_kDisconnectDelay);
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _connectionAttemptActive = false;
    if (!mounted) return;
    setState(() {
      _connectionState = DeviceConnectionState.disconnected;
    });
  }

  Future<void> _closeAndPop() async {
    if (widget.demoMode) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (_isClosing) return;

    _isClosing = true;
    _connectionRequested = false;
    _connectionGeneration++;
    _demoTimer?.cancel();

    await _debugController?.stop();
    await _finishDataRecording();
    await Future<void>.delayed(_kDisconnectDelay);
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    await _bleStatusSubscription?.cancel();
    _bleStatusSubscription = null;
    _connectionAttemptActive = false;

    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  String _messageForBleStatus(BuildContext context, BleStatus status) {
    return switch (status) {
      BleStatus.poweredOff => context.translate(
        'Turn on Bluetooth to connect to this BMS.',
        'Nyalakan Bluetooth untuk terhubung ke BMS ini.',
      ),
      BleStatus.unauthorized => context.translate(
        'Allow nearby-device access to connect to this BMS.',
        'Izinkan akses perangkat terdekat untuk terhubung ke BMS ini.',
      ),
      BleStatus.unsupported => context.translate(
        'Bluetooth LE is not supported on this device.',
        'Bluetooth LE tidak didukung pada perangkat ini.',
      ),
      BleStatus.locationServicesDisabled => context.translate(
        'Turn on location services to connect on this Android device.',
        'Nyalakan layanan lokasi untuk terhubung pada perangkat Android ini.',
      ),
      BleStatus.unknown => context.translate(
        'Preparing Bluetooth…',
        'Menyiapkan Bluetooth…',
      ),
      BleStatus.ready => context.translate(
        'Ready to connect.',
        'Siap terhubung.',
      ),
    };
  }

  void _startDebugCapture() {
    final ble = _ble;
    if (ble == null) return;
    final controller = _debugController ??= BleDebugController(
      ble: ble,
      deviceId: widget.device.id,
    );
    controller.removeListener(_handleDebugPackets);
    controller.addListener(_handleDebugPackets);
    controller.start();
  }

  void _handleDebugPackets() {
    final controller = _debugController;
    if (controller == null || controller.messages.isEmpty || !mounted) return;

    final message = controller.messages.first;
    if (identical(message, _lastTelemetryMessage)) return;
    _lastTelemetryMessage = message;

    final telemetry = _decodeTelemetryMessage(message);
    if (telemetry == null) return;

    final receivedAt = DateTime.now();
    _csvLogger?.record(telemetry, receivedAt);
    setState(() {
      _hasTelemetry = true;
      _serialNumber = telemetry.serialNumber;
      _charge = telemetry.soc / 100;
      _voltage = telemetry.voltage;
      _current = telemetry.current;
      _temperature = telemetry.temperature;
      _cellVoltageMillivolts = telemetry.monitoringCellVoltageMillivolts;
      _errorCode = telemetry.errorCode;
      _lastTelemetryAt = receivedAt;
      _recordHistory();
      if (telemetry.settings != null) {
        _deviceSettings = telemetry.settings;
      }

      if (!telemetry.hasError) {
        _errorLogs.clear();
      } else {
        _errorLogs.removeWhere((log) => log.liveTelemetry);
        final timestamp = _formatTimestamp(receivedAt);
        final decodedErrors = activeBmsErrors(telemetry.errorCode);
        final unknownBits = unknownBmsErrorBits(telemetry.errorCode);
        _errorLogs.insertAll(0, [
          for (final error in decodedErrors)
            _ErrorLogEntry(
              timestamp: timestamp,
              code: 'B${error.bit.toString().padLeft(2, '0')}',
              description: error.description(
                useIndonesian: context.usesIndonesian,
              ),
              liveTelemetry: true,
            ),
          for (final bit in unknownBits)
            _ErrorLogEntry(
              timestamp: timestamp,
              code: 'B${bit.toString().padLeft(2, '0')}',
              description: context.translate(
                'Unknown BMS error bit',
                'Bit kesalahan BMS tidak dikenal',
              ),
              liveTelemetry: true,
            ),
        ]);
        if (decodedErrors.isEmpty && unknownBits.isEmpty) {
          _errorLogs.insert(
            0,
            _ErrorLogEntry(
              timestamp: timestamp,
              code: 'F${telemetry.errorCode}',
              description: context.translate(
                'Invalid BMS error bitmask',
                'Bitmask kesalahan BMS tidak valid',
              ),
              liveTelemetry: true,
            ),
          );
        }
      }
    });
  }

  void _startDataRecording() {
    if (_csvLogger != null || widget.demoMode) return;
    final shouldRecord = AppSettingsScope.maybeOf(context)?.recordData ?? false;
    if (!shouldRecord) return;

    final logger = BmsCsvLogger(device: widget.device);
    _csvLogger = logger;
    unawaited(
      logger.ready.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (!identical(_csvLogger, logger)) return;
          _csvLogger = null;
          _showDataRecordingError();
        },
      ),
    );
  }

  Future<void> _finishDataRecording({bool notify = true}) async {
    final logger = _csvLogger;
    if (logger == null) return;
    _csvLogger = null;
    try {
      final location = await logger.finish();
      if (!notify || !mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              context.translate(
                'Data recording saved to $location',
                'Rekaman data disimpan di $location',
              ),
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
    } on Object {
      if (notify) _showDataRecordingError();
    }
  }

  void _showDataRecordingError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            context.translate(
              'Could not save the CSV data recording.',
              'Tidak dapat menyimpan rekaman data CSV.',
            ),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  BmsTelemetry? _decodeTelemetryMessage(BleDebugMessage message) {
    final direct = BmsTelemetry.tryParse(message.text);
    if (direct != null) {
      _telemetryBuffer = '';
      _telemetryCharacteristicId = message.characteristicId;
      return direct;
    }

    if (_telemetryCharacteristicId == message.characteristicId &&
        _telemetryBuffer.isNotEmpty) {
      _telemetryBuffer += message.text;
    } else {
      final objectStart = message.text.indexOf('{');
      if (objectStart < 0) return null;
      _telemetryBuffer = message.text.substring(objectStart);
      _telemetryCharacteristicId = message.characteristicId;
    }

    if (_telemetryBuffer.length > _kTelemetryBufferSize) {
      _telemetryBuffer = '';
      return null;
    }

    final buffered = BmsTelemetry.tryParse(_telemetryBuffer);
    if (buffered != null) _telemetryBuffer = '';
    return buffered;
  }

  String _chargeStatusLabel(BuildContext context) {
    if (widget.demoMode) {
      return context.translate('Live simulated data', 'Data simulasi langsung');
    }
    final lastTelemetryAt = _lastTelemetryAt;
    if (lastTelemetryAt == null) {
      return context.translate('Waiting for BMS data', 'Menunggu data BMS');
    }
    return '${context.translate('Updated', 'Diperbarui')} '
        '${lastTelemetryAt.hour.toString().padLeft(2, '0')}:'
        '${lastTelemetryAt.minute.toString().padLeft(2, '0')}:'
        '${lastTelemetryAt.second.toString().padLeft(2, '0')}';
  }

  String _formatTimestamp(DateTime timestamp) {
    return '${timestamp.day.toString().padLeft(2, '0')}-'
        '${timestamp.month.toString().padLeft(2, '0')}-'
        '${timestamp.year} '
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  Future<void> _openDebugPage() async {
    final controller = _debugController;
    if (controller == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            BleDebugScreen(device: widget.device, controller: controller),
      ),
    );
  }

  void _startDemo() {
    _demoTimer?.cancel();
    _demoTimer = Timer.periodic(_kDemoInterval, (_) => _updateDemoData());
  }

  void _toggleDemo() {
    setState(() => _demoRunning = !_demoRunning);
    if (_demoRunning) {
      _startDemo();
    } else {
      _demoTimer?.cancel();
    }
  }

  void _updateDemoData() {
    if (!mounted) return;
    setState(() {
      _charge =
          (_charge +
                  (_random.nextDouble() - _kDemoChargeBias) * _kDemoChargeDelta)
              .clamp(
                _kDemoChargeMin,
                _demoLowBattery ? _kDemoChargeLowMax : _kDemoChargeMax,
              );
      _voltage =
          (_kDemoVoltageNormal +
                  (_random.nextDouble() - 0.5) * _kDemoVoltageRange)
              .clamp(_kDemoVoltageMin, _kDemoVoltageMax);
      _current = -80 + (_random.nextDouble() * 110);
      _temperature =
          (_kDemoTempBase + (_random.nextDouble() - 0.5) * _kDemoTempVariance)
              .clamp(_kDemoTempMin, _kDemoTempMax);
      _cellVoltageMillivolts = [
        for (final voltage in _cellVoltageMillivolts)
          (voltage + _random.nextInt(_kDemoCellVoltageDelta) - 7).clamp(
            _kDemoCellVoltageClampMin,
            _kDemoCellVoltageClampMax,
          ),
      ];
      _recordHistory();
    });
  }

  void _recordHistory() {
    void push(List<double> history, double value) {
      history.add(value);
      if (history.length > _kHistoryLength) history.removeAt(0);
    }

    push(_voltageHistory, _voltage);
    push(_currentHistory, _current);
    push(_temperatureHistory, _temperature);
  }

  /// Gives the demo sparklines a short trail without disturbing the
  /// initial sample or the demo random sequence.
  void _seedDemoHistory() {
    final seed = math.Random(11);
    for (var i = 0; i < _kHistoryLength - 1; i++) {
      final phase = i / 3;
      _voltageHistory.add(
        _kDemoVoltageNormal +
            math.sin(phase) * 0.25 +
            (seed.nextDouble() - 0.5) * 0.1,
      );
      _currentHistory.add(
        _kDemoCurrentNormal +
            math.sin(phase + 1) * 4 +
            (seed.nextDouble() - 0.5) * 1.5,
      );
      _temperatureHistory.add(
        _kDemoTempBase + math.sin(phase + 2) * 0.8 + (seed.nextDouble() - 0.5),
      );
    }
    _recordHistory();
  }

  void _toggleDemoFault() {
    setState(() {
      _demoFault = !_demoFault;
      if (_demoFault) {
        final now = TimeOfDay.now();
        _errorLogs.insert(
          0,
          _ErrorLogEntry(
            timestamp:
                'Demo ${now.hour.toString().padLeft(2, '0')}:'
                '${now.minute.toString().padLeft(2, '0')}',
            code: 'DF',
            description: context.translate(
              'Demo pack fault injected',
              'Gangguan paket demo disimulasikan',
            ),
          ),
        );
      } else {
        _errorLogs.removeWhere((log) => log.code == 'DF');
      }
    });
  }

  void _toggleDemoLowBattery() {
    setState(() {
      _demoLowBattery = !_demoLowBattery;
      _charge = _demoLowBattery ? _kDemoChargeLow : _kDemoChargeNormal;
    });
  }
}

class _ConnectionPanel extends StatelessWidget {
  const _ConnectionPanel({
    required this.deviceId,
    required this.bleStatus,
    required this.connectionState,
    required this.errorMessage,
    required this.onRetry,
    required this.onDisconnect,
  });

  final String deviceId;
  final BleStatus bleStatus;
  final DeviceConnectionState connectionState;
  final String? errorMessage;
  final VoidCallback onRetry;
  final VoidCallback onDisconnect;

  bool get _isBusy =>
      connectionState == DeviceConnectionState.connecting ||
      connectionState == DeviceConnectionState.disconnecting;

  bool get _isConnected => connectionState == DeviceConnectionState.connected;

  @override
  Widget build(BuildContext context) {
    final statusColor = _isConnected
        ? AppColors.success
        : _isBusy
        ? AppColors.warning
        : AppColors.danger;
    final statusLabel = switch (connectionState) {
      DeviceConnectionState.connecting => context.translate(
        'Connecting…',
        'Menghubungkan…',
      ),
      DeviceConnectionState.connected => context.translate(
        'Connected',
        'Terhubung',
      ),
      DeviceConnectionState.disconnecting => context.translate(
        'Disconnecting…',
        'Memutuskan…',
      ),
      DeviceConnectionState.disconnected => context.translate(
        'Disconnected',
        'Terputus',
      ),
    };
    final detail =
        errorMessage ??
        (_isConnected
            ? deviceId
            : bleStatus == BleStatus.ready
            ? context.translate(
                'Ready to connect to $deviceId',
                'Siap terhubung ke $deviceId',
              )
            : context.translate(
                'Bluetooth is not ready.',
                'Bluetooth belum siap.',
              ));

    return _ConnectionCard(
      tone: statusColor,
      icon: _isConnected
          ? Icons.bluetooth_rounded
          : Icons.bluetooth_disabled_rounded,
      busy: _isBusy,
      title: statusLabel,
      detail: detail,
      actionLabel: _isConnected
          ? context.translate('Disconnect', 'Putuskan')
          : context.translate('Retry', 'Coba lagi'),
      onAction: _isBusy
          ? null
          : _isConnected
          ? onDisconnect
          : onRetry,
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.tone,
    required this.icon,
    required this.title,
    required this.detail,
    required this.actionLabel,
    required this.onAction,
    this.busy = false,
  });

  final Color tone;
  final IconData icon;
  final String title;
  final String detail;
  final String actionLabel;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(tone.withValues(alpha: 0.18), AppColors.surface),
            Color.alphaBlend(tone.withValues(alpha: 0.06), AppColors.surface),
          ],
        ),
        border: Border.all(color: tone.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: tone.withValues(alpha: 0.12), blurRadius: 16),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _WavePainter(tone.withValues(alpha: 0.14)),
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: tone,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: tone.withValues(alpha: 0.6), blurRadius: 6),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 16, 16),
            child: Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      tone.withValues(alpha: 0.35),
                      AppColors.surface,
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(color: tone.withValues(alpha: 0.5)),
                  ),
                  child: busy
                      ? SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: tone,
                          ),
                        )
                      : Icon(icon, color: Colors.white, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: tone,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: onAction,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: tone,
                    backgroundColor: tone.withValues(alpha: 0.1),
                    side: BorderSide(color: tone.withValues(alpha: 0.7)),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: Text(actionLabel),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final start = size.width * 0.42;
    final wave = Path()..moveTo(start, size.height);
    for (var x = start; x <= size.width; x += 2) {
      final progress = (x - start) / (size.width - start);
      final y =
          size.height * 0.78 -
          math.sin(progress * math.pi * 1.6) * size.height * 0.16;
      wave.lineTo(x, y);
    }
    wave
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(
      wave,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) => oldDelegate.color != color;
}

class _DemoControls extends StatelessWidget {
  const _DemoControls({
    required this.faultActive,
    required this.lowBatteryActive,
    required this.onNewSample,
    required this.onToggleFault,
    required this.onToggleLowBattery,
  });

  final bool faultActive;
  final bool lowBatteryActive;
  final VoidCallback onNewSample;
  final VoidCallback onToggleFault;
  final VoidCallback onToggleLowBattery;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _DemoChip(
          icon: Icons.refresh_rounded,
          label: context.translate('New sample', 'Sampel baru'),
          onPressed: onNewSample,
        ),
        _DemoChip(
          icon: faultActive
              ? Icons.check_circle_outline
              : Icons.warning_amber_rounded,
          label: faultActive
              ? context.translate('Clear fault', 'Hapus gangguan')
              : context.translate('Simulate fault', 'Simulasikan gangguan'),
          onPressed: onToggleFault,
        ),
        _DemoChip(
          icon: lowBatteryActive
              ? Icons.battery_std_rounded
              : Icons.battery_alert_rounded,
          label: lowBatteryActive
              ? context.translate('Clear low battery', 'Hapus baterai lemah')
              : context.translate(
                  'Simulate low battery',
                  'Simulasikan baterai lemah',
                ),
          onPressed: onToggleLowBattery,
        ),
      ],
    );
  }
}

class _DemoChip extends StatelessWidget {
  const _DemoChip({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 16, color: AppColors.accent),
      label: Text(label),
      labelStyle: const TextStyle(color: AppColors.text, fontSize: 12),
      backgroundColor: AppColors.surface,
      side: const BorderSide(color: AppColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _MonitoringHeader extends StatelessWidget {
  const _MonitoringHeader({required this.onBack, required this.onSettings});

  final VoidCallback onBack;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _HeaderButton(
          icon: Icons.arrow_back_ios_new_rounded,
          tooltip: context.translate('Back', 'Kembali'),
          iconSize: 18,
          onPressed: onBack,
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                context.translate('Monitoring Device', 'Pemantauan Perangkat'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                context.translate(
                  'Real-time battery monitoring',
                  'Pemantauan baterai real-time',
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        _HeaderButton(
          icon: Icons.settings_outlined,
          tooltip: context.translate('Device settings', 'Pengaturan perangkat'),
          iconSize: 22,
          onPressed: onSettings,
        ),
      ],
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.iconSize,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final double iconSize;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: AppColors.border),
    );
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.surface,
        shape: shape,
        child: InkWell(
          onTap: onPressed,
          customBorder: shape,
          child: SizedBox.square(
            dimension: 44,
            child: Icon(icon, color: AppColors.text, size: iconSize),
          ),
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: AppColors.border),
    );
    return Material(
      color: AppColors.surface,
      shape: shape,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.memory_rounded,
                  color: AppColors.success,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      context.translate(
                        'Battery Management System',
                        'Sistem Manajemen Baterai',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textMuted,
                size: 26,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StateOfChargeCard extends StatelessWidget {
  const _StateOfChargeCard({
    required this.charge,
    required this.hasData,
    required this.isCharging,
    required this.isLow,
    required this.subtitle,
    required this.remainingCapacity,
    required this.status,
    required this.statusColor,
  });

  final double charge;
  final bool hasData;
  final bool isCharging;
  final bool isLow;
  final String subtitle;
  final String remainingCapacity;
  final String status;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    final iconColor = isLow ? AppColors.danger : AppColors.info;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isLow
                      ? Icons.battery_alert_rounded
                      : isCharging
                      ? Icons.battery_charging_full_rounded
                      : Icons.battery_full_rounded,
                  color: iconColor,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.translate('Stage of Charge', 'Tingkat Daya'),
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (isLow)
                const _LowBatteryBadge()
              else if (isCharging)
                const _ChargingBadge(),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 62,
                  child: _SegmentedBattery(
                    charge: hasData ? charge : 0,
                    isCharging: isCharging,
                    isLow: isLow,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Text(
                hasData ? '${(charge * 100).round()}%' : '--%',
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 40,
                  height: 1,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _LabeledValue(
                  label: context.translate(
                    'Remaining Capacity',
                    'Kapasitas Tersisa',
                  ),
                  value: remainingCapacity,
                  valueColor: AppColors.text,
                ),
              ),
              _LabeledValue(
                label: context.translate('Status', 'Status'),
                value: status,
                valueColor: statusColor,
                alignEnd: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LabeledValue extends StatelessWidget {
  const _LabeledValue({
    required this.label,
    required this.value,
    required this.valueColor,
    this.alignEnd = false,
  });

  final String label;
  final String value;
  final Color valueColor;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _SegmentedBattery extends StatelessWidget {
  const _SegmentedBattery({
    required this.charge,
    required this.isCharging,
    required this.isLow,
  });

  static const _segmentCount = 8;
  final double charge;
  final bool isCharging;
  final bool isLow;

  @override
  Widget build(BuildContext context) {
    final chargedSegments = (charge * _segmentCount).ceil();
    final fillColor = isLow
        ? AppColors.danger
        : isCharging
        ? AppColors.info
        : AppColors.success;

    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border, width: 1.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                for (var index = 0; index < _segmentCount; index++) ...[
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: index < chargedSegments
                            ? fillColor
                            : AppColors.surfaceRaised,
                        borderRadius: BorderRadius.circular(5),
                        boxShadow: index < chargedSegments
                            ? [
                                BoxShadow(
                                  color: fillColor.withValues(alpha: 0.35),
                                  blurRadius: 8,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ),
                  if (index < _segmentCount - 1) const SizedBox(width: 4),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 3),
        Container(
          width: 7,
          height: 26,
          decoration: const BoxDecoration(
            color: AppColors.border,
            borderRadius: BorderRadius.horizontal(right: Radius.circular(4)),
          ),
        ),
      ],
    );
  }
}

class _LowBatteryBadge extends StatelessWidget {
  const _LowBatteryBadge();

  @override
  Widget build(BuildContext context) {
    return _StatusBadge(
      label: context.translate('Low', 'Lemah'),
      icon: Icons.error_rounded,
      color: AppColors.danger,
    );
  }
}

class _ChargingBadge extends StatelessWidget {
  const _ChargingBadge();

  @override
  Widget build(BuildContext context) {
    return _StatusBadge(
      label: context.translate('Charging', 'Mengisi daya'),
      icon: Icons.bolt_rounded,
      color: AppColors.info,
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PackCellToggle extends StatelessWidget {
  const _PackCellToggle({required this.showPack, required this.onChanged});

  final bool showPack;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 230,
      height: 46,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ToggleOption(
              label: context.translate('Pack', 'Paket'),
              selected: showPack,
              onTap: () => onChanged(true),
            ),
          ),
          Expanded(
            child: _ToggleOption(
              label: context.translate('Cell', 'Sel'),
              selected: !showPack,
              onTap: () => onChanged(false),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToggleOption extends StatelessWidget {
  const _ToggleOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.45),
                  blurRadius: 14,
                ),
              ]
            : null,
      ),
      child: Material(
        color: selected ? AppColors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : AppColors.textMuted,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CellMonitoringSection extends StatelessWidget {
  const _CellMonitoringSection({required this.cellVoltages});

  final List<int> cellVoltages;

  @override
  Widget build(BuildContext context) {
    final activeCells = <MapEntry<int, int>>[
      for (final entry in cellVoltages.indexed)
        if (entry.$2 > 0) MapEntry(entry.$1, entry.$2),
    ];
    final maximum = activeCells.isEmpty
        ? null
        : activeCells.reduce((a, b) => a.value >= b.value ? a : b);
    final minimum = activeCells.isEmpty
        ? null
        : activeCells.reduce((a, b) => a.value <= b.value ? a : b);
    final difference = maximum == null || minimum == null
        ? null
        : maximum.value - minimum.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CellPanel(
          icon: Icons.bar_chart_rounded,
          title: context.translate('Statistic', 'Statistik'),
          child: Row(
            children: [
              Expanded(
                child: _CellStatisticCard(
                  label: context.translate('VCell Max (V)', 'VCell Maks (V)'),
                  value: maximum == null
                      ? null
                      : _formatCellVoltageVolts(maximum.value),
                  cellIndex: maximum?.key,
                  icon: Icons.bolt_rounded,
                  tone: AppColors.info,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CellStatisticCard(
                  label: context.translate('VCell Min (V)', 'VCell Min (V)'),
                  value: minimum == null
                      ? null
                      : _formatCellVoltageVolts(minimum.value),
                  cellIndex: minimum?.key,
                  icon: Icons.arrow_downward_rounded,
                  tone: AppColors.danger,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CellStatisticCard(
                  label: context.translate(
                    'VCell Diff (V)',
                    'Selisih VCell (V)',
                  ),
                  value: difference == null
                      ? null
                      : _formatCellVoltageVolts(difference),
                  icon: Icons.show_chart_rounded,
                  tone: AppColors.success,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _CellPanel(
          icon: Icons.grid_view_rounded,
          title: context.translate('Cell Voltage (V)', 'Tegangan Sel (V)'),
          trailing: cellVoltages.isEmpty
              ? null
              : context.translate(
                  '${cellVoltages.length} cells',
                  '${cellVoltages.length} sel',
                ),
          child: cellVoltages.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    context.translate(
                      'Waiting for cell voltage data',
                      'Menunggu data tegangan sel',
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                )
              : GridView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: cellVoltages.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: math.min(4, cellVoltages.length),
                    mainAxisExtent: 40,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 9,
                  ),
                  itemBuilder: (context, index) => _CellVoltageTile(
                    index: index,
                    voltage: cellVoltages[index],
                    isMaximum: maximum?.key == index,
                    isMinimum: minimum?.key == index,
                  ),
                ),
        ),
      ],
    );
  }
}

class _CellPanel extends StatelessWidget {
  const _CellPanel({
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final trailing = this.trailing;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.accent, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (trailing != null)
                Text(
                  trailing,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _CellStatisticCard extends StatelessWidget {
  const _CellStatisticCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.tone,
    this.cellIndex,
  });

  final String label;
  final String? value;
  final int? cellIndex;
  final IconData icon;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final cellIndex = this.cellIndex;
    return Container(
      height: 104,
      padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(tone.withValues(alpha: 0.12), AppColors.surface),
            Color.alphaBlend(tone.withValues(alpha: 0.03), AppColors.surface),
          ],
        ),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                  border: Border.all(color: tone.withValues(alpha: 0.4)),
                ),
                child: Icon(icon, color: tone, size: 15),
              ),
            ],
          ),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value ?? '--',
              style: TextStyle(
                color: value == null ? AppColors.textMuted : tone,
                fontSize: 24,
                height: 1,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            cellIndex == null
                ? ''
                : '${context.translate('Cell', 'Sel')} '
                      '${(cellIndex + 1).toString().padLeft(2, '0')}',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _CellVoltageTile extends StatelessWidget {
  const _CellVoltageTile({
    required this.index,
    required this.voltage,
    required this.isMaximum,
    required this.isMinimum,
  });

  static const _neutralBadge = Color(0xFF34445E);

  final int index;
  final int voltage;
  final bool isMaximum;
  final bool isMinimum;

  @override
  Widget build(BuildContext context) {
    final highlight = isMinimum
        ? AppColors.danger
        : isMaximum
        ? AppColors.info
        : null;

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: highlight == null
            ? AppColors.surfaceRaised.withValues(alpha: 0.6)
            : Color.alphaBlend(
                highlight.withValues(alpha: 0.14),
                AppColors.surface,
              ),
        border: Border.all(
          color: highlight?.withValues(alpha: 0.85) ?? AppColors.border,
        ),
        borderRadius: BorderRadius.circular(10),
        boxShadow: highlight == null
            ? null
            : [
                BoxShadow(
                  color: highlight.withValues(alpha: 0.25),
                  blurRadius: 10,
                ),
              ],
      ),
      child: Row(
        children: [
          Container(
            width: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: highlight ?? _neutralBadge,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              (index + 1).toString().padLeft(2, '0'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _formatCellVoltageVolts(voltage),
                maxLines: 1,
                style: TextStyle(
                  color: isMinimum ? AppColors.danger : AppColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatCellVoltageVolts(int millivolts) {
  return (millivolts / 1000).toStringAsFixed(3);
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});

  final List<_MetricData> metrics;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var row = 0; row < 2; row++) ...[
          Row(
            children: [
              Expanded(child: _MetricCard(metric: metrics[row * 2])),
              const SizedBox(width: 12),
              Expanded(child: _MetricCard(metric: metrics[row * 2 + 1])),
            ],
          ),
          if (row == 0) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric});

  final _MetricData metric;

  @override
  Widget build(BuildContext context) {
    final tone = metric.tone;
    final history = metric.history;
    final badge = metric.badge;

    return Container(
      height: 124,
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(tone.withValues(alpha: 0.16), AppColors.surface),
            Color.alphaBlend(tone.withValues(alpha: 0.04), AppColors.surface),
          ],
        ),
        border: Border.all(color: tone.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: history == null
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Color.alphaBlend(
                    tone.withValues(alpha: 0.45),
                    AppColors.surface,
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(color: tone.withValues(alpha: 0.6)),
                ),
                child: Icon(metric.icon, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      metric.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 3),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        metric.value,
                        maxLines: 1,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 21,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (badge != null)
                Container(
                  width: 34,
                  height: 34,
                  margin: const EdgeInsets.only(top: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Color.alphaBlend(
                      tone.withValues(alpha: 0.35),
                      AppColors.surface,
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: tone.withValues(alpha: 0.35),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: Icon(badge, color: Colors.white, size: 20),
                ),
            ],
          ),
          if (history != null) ...[
            const Spacer(),
            SizedBox(
              height: 34,
              width: double.infinity,
              child: CustomPaint(
                painter: _SparklinePainter(values: history, color: tone),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricData {
  const _MetricData({
    required this.label,
    required this.value,
    required this.icon,
    required this.tone,
    this.history,
    this.badge,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color tone;
  final List<double>? history;
  final IconData? badge;
}

class _SparklinePainter extends CustomPainter {
  const _SparklinePainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);
    final range = maximum - minimum < 1e-6 ? 1.0 : maximum - minimum;
    final points = [
      for (var i = 0; i < values.length; i++)
        Offset(
          size.width * i / (values.length - 1),
          size.height * 0.9 -
              (values[i] - minimum) / range * size.height * 0.75,
        ),
    ];

    final line = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final previous = points[i - 1];
      final current = points[i];
      final midX = (previous.dx + current.dx) / 2;
      line.cubicTo(midX, previous.dy, midX, current.dy, current.dx, current.dy);
    }

    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.3), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) {
    return oldDelegate.color != color ||
        !listEquals(oldDelegate.values, values);
  }
}

class _ErrorLogTable extends StatelessWidget {
  const _ErrorLogTable({required this.rows});

  static const _columnWidths = <int, TableColumnWidth>{
    0: FlexColumnWidth(1.55),
    1: FlexColumnWidth(0.64),
    2: FlexColumnWidth(1.35),
  };

  final List<_ErrorLogEntry> rows;

  @override
  Widget build(BuildContext context) {
    final hasErrors = rows.isNotEmpty;
    final summary = !hasErrors
        ? context.translate('No errors detected', 'Tidak ada kesalahan')
        : rows.length == 1
        ? context.translate('1 error', '1 kesalahan')
        : context.translate(
            '${rows.length} errors',
            '${rows.length} kesalahan',
          );
    final summaryColor = hasErrors ? AppColors.danger : AppColors.success;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.description_rounded,
                color: AppColors.accent,
                size: 26,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.translate('Error Logs', 'Log Kesalahan'),
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                summary,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 7),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: summaryColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: summaryColor.withValues(alpha: 0.6),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: AppColors.background.withValues(alpha: 0.45),
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Container(
                  color: AppColors.surfaceRaised,
                  child: Table(
                    columnWidths: _columnWidths,
                    children: [
                      TableRow(
                        children: [
                          _HeaderCell(context.translate('Timestamp', 'Waktu')),
                          _HeaderCell(context.translate('Code', 'Kode')),
                          _HeaderCell(
                            context.translate('Description', 'Deskripsi'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (!hasErrors)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 24,
                    ),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.description_outlined,
                          color: AppColors.textMuted,
                          size: 38,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          context.translate(
                            'No error code',
                            'Tidak ada kode kesalahan',
                          ),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.translate(
                            'All systems are operating normally.',
                            'Semua sistem beroperasi normal.',
                          ),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Table(
                    columnWidths: _columnWidths,
                    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                    border: const TableBorder(
                      horizontalInside: BorderSide(color: AppColors.border),
                    ),
                    children: [
                      for (final row in rows)
                        TableRow(
                          children: [
                            _LogCell(row.timestamp),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.danger.withValues(
                                      alpha: 0.15,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    row.code,
                                    style: const TextStyle(
                                      color: AppColors.danger,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            _LogCell(row.description),
                          ],
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorLogEntry {
  const _ErrorLogEntry({
    required this.timestamp,
    required this.code,
    required this.description,
    this.liveTelemetry = false,
  });

  final String timestamp;
  final String code;
  final String description;
  final bool liveTelemetry;
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: AppColors.text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LogCell extends StatelessWidget {
  const _LogCell(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.text, fontSize: 11),
      ),
    );
  }
}
