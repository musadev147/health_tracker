import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const HyperHealthApp());
}

class HyperHealthApp extends StatelessWidget {
  const HyperHealthApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hyper Health App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5C6BC0)),
        scaffoldBackgroundColor: const Color(0xFFF5F7FB),
      ),
      home: const HealthDashboardScreen(),
    );
  }
}

class HealthDashboardScreen extends StatefulWidget {
  const HealthDashboardScreen({super.key});

  @override
  State<HealthDashboardScreen> createState() => _HealthDashboardScreenState();
}

class _HealthDashboardScreenState extends State<HealthDashboardScreen> {
  final Health _health = Health();

  int _steps = 0;
  double _heartRate = 0;
  double _sleepHours = 0;

  bool _isFirstLoad = true;
  bool _isHealthLoading = false;
  bool _isFetchingHealth = false;
  String _healthError = '';
  DateTime? _lastHealthRefresh;

  bool _showInstallHealthConnect = false;
  bool _showUpdateHealthConnect = false;
  String _sleepDebug = '';

  Timer? _autoRefreshTimer;
  static const Duration _autoRefreshInterval = Duration(seconds: 10);

  bool _isScanning = false;
  bool _isConnectingDevice = false;
  String _connectingDeviceId = '';
  BluetoothDevice? _connectedDevice;
  String _connectedWatchName = '-';
  String _bluetoothStatus = 'Disconnected';
  List<BluetoothDevice> _discoveredDevices = [];
  bool _showDiscoveredDeviceList = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    await _health.configure();
    await _fetchHealthData(showLoader: true);
    _startAutoRefresh();
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      _fetchHealthData(showLoader: false);
    });
  }

  Future<void> _fetchHealthData({required bool showLoader}) async {
    if (_isFetchingHealth) return;

    _isFetchingHealth = true;
    if (showLoader && mounted) {
      setState(() {
        _isHealthLoading = true;
      });
    }

    try {
      final sdkStatus = await _health.getHealthConnectSdkStatus();
      if (sdkStatus == HealthConnectSdkStatus.sdkUnavailable) {
        if (!mounted) return;
        setState(() {
          _steps = 0;
          _heartRate = 0;
          _sleepHours = 0;
          _healthError = 'Health Connect is not installed. Please install it.';
          _showInstallHealthConnect = true;
          _showUpdateHealthConnect = false;
        });
        return;
      }

      if (sdkStatus == HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired) {
        if (!mounted) return;
        setState(() {
          _steps = 0;
          _heartRate = 0;
          _sleepHours = 0;
          _healthError = 'Health Connect update required. Please update from Play Store.';
          _showInstallHealthConnect = false;
          _showUpdateHealthConnect = true;
        });
        return;
      }

      final runtimePermissionsGranted = await _requestHealthRuntimePermissions();
      if (!runtimePermissionsGranted) {
        if (!mounted) return;
        setState(() {
          _steps = 0;
          _heartRate = 0;
          _sleepHours = 0;
          _healthError = 'Permission denied. Allow Activity Recognition and Body Sensors.';
          _showInstallHealthConnect = false;
          _showUpdateHealthConnect = false;
        });
        return;
      }

      final types = <HealthDataType>[
        HealthDataType.STEPS,
        HealthDataType.HEART_RATE,
        HealthDataType.SLEEP_ASLEEP,
        HealthDataType.SLEEP_LIGHT,
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_SESSION,
        HealthDataType.SLEEP_AWAKE,
        HealthDataType.SLEEP_UNKNOWN,
      ];
      final access = List<HealthDataAccess>.filled(types.length, HealthDataAccess.READ);

      final authorized = await _health.requestAuthorization(types, permissions: access);
      if (!authorized) {
        if (!mounted) return;
        setState(() {
          _steps = 0;
          _heartRate = 0;
          _sleepHours = 0;
          _healthError = 'Health permission denied in Health Connect.';
          _showInstallHealthConnect = false;
          _showUpdateHealthConnect = false;
        });
        return;
      }

      final now = DateTime.now();
      final from = now.subtract(const Duration(hours: 24));
      List<HealthDataPoint> data = await _health.getHealthDataFromTypes(
        startTime: from,
        endTime: now,
        types: types,
      );
      data = _health.removeDuplicates(data);

      int steps = 0;
      double latestHr = 0;
      DateTime latestHrTime = DateTime.fromMillisecondsSinceEpoch(0);
      double sleepHours = 0;

      final midnight = DateTime(now.year, now.month, now.day);
      final dailySteps = await _health.getTotalStepsInInterval(midnight, now);
      if (dailySteps != null) {
        steps = dailySteps;
      }

      final sleepTypes = <HealthDataType>{
        HealthDataType.SLEEP_ASLEEP,
        HealthDataType.SLEEP_LIGHT,
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_SESSION,
      };

      for (final point in data) {
        final numeric = point.value is NumericHealthValue
            ? (point.value as NumericHealthValue).numericValue.toDouble()
            : null;

        if (point.type == HealthDataType.STEPS && dailySteps == null) {
          if (numeric != null) {
            steps += numeric.toInt();
          }
          continue;
        }

        if (point.type == HealthDataType.HEART_RATE) {
          if (numeric != null && point.dateFrom.isAfter(latestHrTime)) {
            latestHrTime = point.dateFrom;
            latestHr = numeric;
          }
          continue;
        }

        if (sleepTypes.contains(point.type)) {
          final duration = point.dateTo.difference(point.dateFrom);
          if (duration.inMinutes > 0) {
            sleepHours += duration.inMinutes / 60.0;
          } else if (numeric != null && numeric > 0) {
            sleepHours += numeric / 60.0;
          }
        }
      }

      _logSleepDataDiagnostics(data);

      if (!mounted) return;
      setState(() {
        _steps = steps;
        _heartRate = latestHr;
        _sleepHours = sleepHours;
        _healthError = '';
        _lastHealthRefresh = DateTime.now();
        _showInstallHealthConnect = false;
        _showUpdateHealthConnect = false;
        _sleepDebug = _buildSleepDebugSummary(data);
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      final message = (e.message ?? '').toLowerCase();
      final details = (e.details ?? '').toString().toLowerCase();
      final launcherError = message.contains('permission launcher not found') ||
          details.contains('permission launcher not found');
      setState(() {
        _steps = 0;
        _heartRate = 0;
        _sleepHours = 0;
        _healthError = launcherError
            ? 'Health Connect permission launcher not found. Set MainActivity to FlutterFragmentActivity, rebuild app, and retry.'
            : 'Unable to read health data right now. Please try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _steps = 0;
        _heartRate = 0;
        _sleepHours = 0;
        _healthError = 'Unable to read health data right now. Please try again.';
      });
    } finally {
      _isFetchingHealth = false;
      if (mounted) {
        setState(() {
          _isHealthLoading = false;
          _isFirstLoad = false;
        });
      }
    }
  }

  Future<bool> _requestHealthRuntimePermissions() async {
    final activity = await Permission.activityRecognition.request();
    final sensors = await Permission.sensors.request();
    return activity.isGranted && sensors.isGranted;
  }

  void _logSleepDataDiagnostics(List<HealthDataPoint> data) {
    final sleepTypes = <HealthDataType>{
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.SLEEP_LIGHT,
      HealthDataType.SLEEP_DEEP,
      HealthDataType.SLEEP_REM,
      HealthDataType.SLEEP_SESSION,
      HealthDataType.SLEEP_AWAKE,
      HealthDataType.SLEEP_UNKNOWN,
    };
    final sleepPoints = data.where((p) => sleepTypes.contains(p.type)).toList();
    debugPrint('Sleep diagnostics: ${sleepPoints.length} points');
    for (final p in sleepPoints) {
      final value = p.value is NumericHealthValue
          ? (p.value as NumericHealthValue).numericValue.toString()
          : p.value.toString();
      debugPrint(
        'Sleep point -> type=${p.type.name}, source=${p.sourceName}, '
        'sourceId=${p.sourceId}, from=${p.dateFrom}, to=${p.dateTo}, value=$value',
      );
    }
  }

  String _buildSleepDebugSummary(List<HealthDataPoint> data) {
    final sleepTypes = <HealthDataType>{
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.SLEEP_LIGHT,
      HealthDataType.SLEEP_DEEP,
      HealthDataType.SLEEP_REM,
      HealthDataType.SLEEP_SESSION,
      HealthDataType.SLEEP_AWAKE,
      HealthDataType.SLEEP_UNKNOWN,
    };
    final counts = <String, int>{};
    for (final p in data) {
      if (!sleepTypes.contains(p.type)) continue;
      final source = p.sourceName.isEmpty ? 'unknown-source' : p.sourceName;
      counts[source] = (counts[source] ?? 0) + 1;
    }
    if (counts.isEmpty) return 'Sleep points: 0';
    return counts.entries.map((e) => '${e.key}: ${e.value}').join(' | ');
  }

  String _deviceLabel(BluetoothDevice device) {
    if (device.platformName.isNotEmpty) return device.platformName;
    if (device.advName.isNotEmpty) return device.advName;
    return device.remoteId.str;
  }

  Future<bool> _requestBluetoothPermissions() async {
    final bluetoothScan = await Permission.bluetoothScan.request();
    final bluetoothConnect = await Permission.bluetoothConnect.request();
    final location = await Permission.locationWhenInUse.request();
    return bluetoothScan.isGranted && bluetoothConnect.isGranted && location.isGranted;
  }

  Future<void> _scanSmartwatches() async {
    if (_isScanning || _isConnectingDevice) return;
    setState(() {
      _isScanning = true;
      _bluetoothStatus = 'Scanning...';
      _discoveredDevices = [];
      _showDiscoveredDeviceList = false;
    });

    try {
      final granted = await _requestBluetoothPermissions();
      if (!granted) {
        if (!mounted) return;
        setState(() {
          _isScanning = false;
          _bluetoothStatus = 'Bluetooth permission denied';
          _showDiscoveredDeviceList = false;
        });
        return;
      }

      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }

      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 400));
      }

      final map = <String, BluetoothDevice>{};
      late final StreamSubscription<List<ScanResult>> sub;
      sub = FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          map[r.device.remoteId.str] = r.device;
        }
      });

      try {
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 10),
          androidUsesFineLocation: true,
          androidCheckLocationServices: false,
        );
        await FlutterBluePlus.isScanning.where((s) => s == false).first;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 800));
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 10),
          androidUsesFineLocation: true,
          androidCheckLocationServices: false,
        );
        await FlutterBluePlus.isScanning.where((s) => s == false).first;
      } finally {
        await sub.cancel();
      }

      final bonded = await FlutterBluePlus.bondedDevices;
      final system = await FlutterBluePlus.systemDevices([Guid('1800')]);
      for (final d in bonded) {
        map[d.remoteId.str] = d;
      }
      for (final d in system) {
        map[d.remoteId.str] = d;
      }
      final list = map.values.toList();

      if (!mounted) return;
      setState(() {
        _discoveredDevices = list;
        _bluetoothStatus = list.isEmpty
            ? 'No devices found. Keep watch in discoverable mode.'
            : 'Found ${list.length} device(s). Select one to connect.';
        _isScanning = false;
        _showDiscoveredDeviceList = _connectedDevice == null && list.isNotEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isScanning = false;
        _bluetoothStatus = 'Scan failed. Please try again.';
        _showDiscoveredDeviceList = false;
      });
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_isConnectingDevice) return;

    final targetId = device.remoteId.str;
    if (_connectedDevice?.remoteId.str == targetId) {
      setState(() {
        _bluetoothStatus = 'Connected to $_connectedWatchName';
      });
      return;
    }

    setState(() {
      _isConnectingDevice = true;
      _connectingDeviceId = targetId;
      _bluetoothStatus = 'Connecting...';
    });

    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }

      final granted = await _requestBluetoothPermissions();
      if (!granted) {
        if (!mounted) return;
        setState(() {
          _isConnectingDevice = false;
          _connectingDeviceId = '';
          _bluetoothStatus = 'Bluetooth permission denied';
        });
        return;
      }

      final previous = _connectedDevice;
      if (previous != null && previous.remoteId.str != targetId) {
        try {
          await previous.disconnect();
        } catch (_) {}
      }

      await device.connect(timeout: const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _connectedDevice = device;
        _connectedWatchName = _deviceLabel(device);
        _isConnectingDevice = false;
        _connectingDeviceId = '';
        _isScanning = false;
        _bluetoothStatus = 'Connected to $_connectedWatchName';
        _discoveredDevices = [];
        _showDiscoveredDeviceList = false;
      });
      await _fetchHealthData(showLoader: false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isConnectingDevice = false;
        _connectingDeviceId = '';
        _bluetoothStatus = 'Connection failed';
        _showDiscoveredDeviceList = _connectedDevice == null && _discoveredDevices.isNotEmpty;
      });
    }
  }

  Future<void> _disconnectSmartwatch() async {
    final device = _connectedDevice;
    if (device == null || _isConnectingDevice) return;

    try {
      await device.disconnect();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _connectedDevice = null;
      _connectedWatchName = '-';
      _bluetoothStatus = 'Disconnected';
      _discoveredDevices = [];
      _showDiscoveredDeviceList = false;
    });
  }

  Future<void> _onPullToRefresh() async {
    await _fetchHealthData(showLoader: false);
  }

  bool get _hasHealthData => _steps > 0 || _heartRate > 0 || _sleepHours > 0;
  bool get _isWatchConnected => _connectedDevice != null;

  String get _lastRefreshLabel {
    final t = _lastHealthRefresh;
    if (t == null) return 'Not synced yet';
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final displaySteps = _isWatchConnected ? _steps : 0;
    final displayHeartRate = _isWatchConnected ? _heartRate : 0.0;
    final displaySleepHours = _isWatchConnected ? _sleepHours : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hyper Health App'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _onPullToRefresh,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_isFirstLoad && _isHealthLoading) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 16),
              ],
              if (_healthError.isNotEmpty) ...[
                _buildErrorCard(_healthError),
                const SizedBox(height: 14),
              ],
              if (_healthError.isEmpty && !_isFirstLoad && !_hasHealthData) ...[
                _buildInfoCard(
                  'Follow this sync flow:\n'
                  'WATCH -> Official App -> Health Connect -> Your App',
                ),
                const SizedBox(height: 14),
              ],
              if (!_isWatchConnected) ...[
                _buildInfoCard('No smartwatch connected. Connect watch first to show health data.'),
                const SizedBox(height: 14),
              ],
              if (_showInstallHealthConnect || _showUpdateHealthConnect) ...[
                FilledButton.tonalIcon(
                  onPressed: () => _health.installHealthConnect(),
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    _showInstallHealthConnect ? 'Install Health Connect' : 'Update Health Connect',
                  ),
                ),
                const SizedBox(height: 14),
              ],
              _buildBluetoothCard(),
              const SizedBox(height: 14),
              _buildMetricCard(
                icon: Icons.directions_walk_rounded,
                iconColor: Colors.blue,
                iconBg: Colors.blue.shade50,
                title: 'Steps',
                value: '$displaySteps',
                unit: 'steps',
              ),
              const SizedBox(height: 12),
              _buildMetricCard(
                icon: Icons.favorite_rounded,
                iconColor: Colors.red,
                iconBg: Colors.red.shade50,
                title: 'Heart',
                value: displayHeartRate.toStringAsFixed(1),
                unit: 'bpm',
              ),
              const SizedBox(height: 12),
              _buildMetricCard(
                icon: Icons.bedtime_rounded,
                iconColor: Colors.deepPurple,
                iconBg: Colors.deepPurple.shade50,
                title: 'Sleep',
                value: displaySleepHours.toStringAsFixed(1),
                unit: 'hrs',
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => _fetchHealthData(showLoader: false),
                icon: const Icon(Icons.refresh_rounded),
                label: Text('Refresh (Last: $_lastRefreshLabel)'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCard(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Text(
        message,
        style: TextStyle(color: Colors.red.shade800),
      ),
    );
  }

  Widget _buildInfoCard(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.shade200),
      ),
      child: Text(
        message,
        style: TextStyle(color: Colors.brown.shade700),
      ),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String unit,
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      value,
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        unit,
                        style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                      ),
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

  Widget _buildBluetoothCard() {
    final connected = _connectedDevice != null;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.bluetooth_connected_rounded, color: Colors.teal),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Smartwatch Connection',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: connected ? Colors.green.shade50 : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _bluetoothStatus,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: connected ? Colors.green.shade700 : Colors.grey.shade700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Connected Watch: $_connectedWatchName',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: (_isScanning || _isConnectingDevice) ? null : _scanSmartwatches,
                  icon: _isScanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bluetooth_searching_rounded),
                  label: const Text('Scan Watches'),
                ),
              ),
              if (connected) ...[
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  onPressed: _isConnectingDevice ? null : _disconnectSmartwatch,
                  icon: const Icon(Icons.link_off_rounded),
                  tooltip: 'Disconnect',
                ),
              ],
            ],
          ),
          if (_showDiscoveredDeviceList &&
              !_isScanning &&
              _connectedDevice == null &&
              _discoveredDevices.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            ..._discoveredDevices.map((device) {
              final id = device.remoteId.str;
              final isConnected = _connectedDevice?.remoteId.str == id;
              final isConnectingThis = _connectingDeviceId == id;

              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  tileColor: Colors.grey.shade100,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  leading: const Icon(Icons.watch_rounded),
                  title: Text(_deviceLabel(device)),
                  subtitle: Text(
                    id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: FilledButton(
                    onPressed: (_isScanning || _isConnectingDevice)
                        ? null
                        : () => _connectToDevice(device),
                    child: isConnectingThis
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(isConnected ? 'Connected' : 'Connect'),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}