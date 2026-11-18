import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'control_packet.dart';
import 'wave.dart';

/// 链路阶段，用于 UI 展示。
enum LinkPhase { idle, connecting, connected, reconnecting }

/// 日志类型，决定终端里的配色。
enum LogKind { info, tx, rx, error, system }

class LogEntry {
  LogEntry(this.message, this.kind) : time = DateTime.now();

  final String message;
  final LogKind kind;
  final DateTime time;

  String get stamp {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(time.hour)}:${p(time.minute)}:${p(time.second)}';
  }
}

class BleAppException implements Exception {
  const BleAppException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 控件发送模式：逐个指令发送，或合成一个固定结构的数据包。
enum ControlSendMode { single, packet }

/// 控件页上某个按键 / 摇杆 / 滑条绑定的指令。
class ControlCommand {
  const ControlCommand({
    required this.label,
    required this.payload,
    this.hex = false,
  });

  final String label;
  final String payload;
  final bool hex;

  ControlCommand copyWith({String? label, String? payload, bool? hex}) =>
      ControlCommand(
        label: label ?? this.label,
        payload: payload ?? this.payload,
        hex: hex ?? this.hex,
      );
}

/// BLE 业务核心：扫描、连接（多重重试）、自动重连、心跳保活、收发数据。
class BleController extends ChangeNotifier {
  BleController();

  static const String unnamedDevice = '未命名设备';
  static const License _license = License.nonprofit;
  static const int _targetMtu = 517;
  static const int _maxLogs = 500;
  static const String _nusService = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

  final Map<String, ScanResult> _results = {};
  final Map<String, DateTime> _lastSeen = {};
  final List<LogEntry> _logs = [];
  final Map<String, StreamSubscription<List<int>>> _notifySubs = {};
  final Set<String> _wantedNotify = {};
  final JustFloatParser _wave = JustFloatParser();
  final Map<String, ControlCommand> _commands = {
    'up': const ControlCommand(label: '前进', payload: 'F'),
    'down': const ControlCommand(label: '后退', payload: 'B'),
    'left': const ControlCommand(label: '左转', payload: 'L'),
    'right': const ControlCommand(label: '右转', payload: 'R'),
    'stop': const ControlCommand(label: '停止', payload: 'S'),
    'k1': const ControlCommand(label: '按键1', payload: '1'),
    'k2': const ControlCommand(label: '按键2', payload: '2'),
    'k3': const ControlCommand(label: '按键3', payload: '3'),
    'k4': const ControlCommand(label: '按键4', payload: '4'),
    'slider1': const ControlCommand(label: '滑条 A', payload: '{v}'),
    'slider2': const ControlCommand(label: '滑条 B', payload: '{v}'),
    'joystick': const ControlCommand(label: '摇杆', payload: '{x},{y}'),
  };

  // 控件整包模式
  ControlSendMode _controlMode = ControlSendMode.single;
  String _packetTemplate = 'AA 55 {x} {y} {s1} {s2} {btn} 55 AA';
  bool _packetHex = true;
  int _packetIntervalMs = 50;
  double _joyX = 0;
  double _joyY = 0;
  double _sliderA = 0;
  double _sliderB = 0;
  Set<String> _pressedKeys = {};
  String? _lastSentPreview;
  String? _lastPacketError;
  Timer? _packetTimer;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _keepAliveTimer;
  Timer? _scanWatchdog;
  Timer? _reconnectTimer;

  BluetoothDevice? _device;
  BluetoothDevice? _desired;
  List<BluetoothService> _services = const [];
  BluetoothCharacteristic? _tx;
  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _keepAliveChar;

  BluetoothAdapterState _adapter = BluetoothAdapterState.unknown;
  LinkPhase _phase = LinkPhase.idle;
  String _deviceLabel = '';
  String? _connectingId;
  String? _lastError;
  String? _lastConnectError;
  String? _lastConnectedId;
  bool _scanning = false;
  bool _autoReconnect = true;
  bool _keepAlive = true;
  bool _hexSend = false;
  bool _hexReceive = false;
  bool _autoOpenTerminal = true;
  bool _reconnecting = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  int _txCount = 0;
  int _rxCount = 0;
  int _generation = 0;
  int _errorSerial = 0;
  int _connectedSerial = 0;

  // ---------------------------------------------------------------- getters

  List<ScanResult> get results => _results.values.toList();
  List<LogEntry> get logs => List.unmodifiable(_logs);
  List<BluetoothService> get services => _services;

  BluetoothDevice? get device => _device;
  BluetoothCharacteristic? get tx => _tx;
  BluetoothCharacteristic? get rx => _rx;
  LinkPhase get phase => _phase;
  BluetoothAdapterState get adapter => _adapter;
  String get deviceLabel => _deviceLabel;
  String? get connectingDeviceId => _connectingId;
  String? get lastError => _lastError;
  int get errorSerial => _errorSerial;
  String? get lastConnectedId => _lastConnectedId;

  List<List<double>> get waveFrames => _wave.frames;
  int get waveChannelCount => _wave.channelCount;
  int get waveFrameCount => _wave.totalFrames;

  ControlCommand command(String key) =>
      _commands[key] ?? ControlCommand(label: key, payload: '');

  ControlSendMode get controlMode => _controlMode;
  String get packetTemplate => _packetTemplate;
  bool get packetHex => _packetHex;
  int get packetIntervalMs => _packetIntervalMs;
  String? get lastSentPreview => _lastSentPreview;
  double get joyX => _joyX;
  double get joyY => _joyY;
  double get sliderA => _sliderA;
  double get sliderB => _sliderB;
  Set<String> get pressedKeys => _pressedKeys;

  bool get scanning => _scanning;
  bool get connected => _phase == LinkPhase.connected;
  bool get autoReconnect => _autoReconnect;
  bool get keepAlive => _keepAlive;
  bool get autoOpenTerminal => _autoOpenTerminal;
  int get connectedSerial => _connectedSerial;
  bool get hexSend => _hexSend;
  bool get hexReceive => _hexReceive;
  bool get notifyActive => _notifySubs.isNotEmpty;
  int get notifyCount => _notifySubs.length;
  int get reconnectAttempt => _reconnectAttempt;
  int get txCount => _txCount;
  int get rxCount => _rxCount;
  int get mtu => _device?.mtuNow ?? 23;

  String get logText => _logs.reversed.map((e) => '[${e.stamp}] ${e.message}').join('\n');

  // ------------------------------------------------------------- lifecycle

  Future<void> init() async {
    _scanSub = FlutterBluePlus.scanResults.listen(
      _onScanResults,
      onError: (Object e) => _log('扫描异常：${_friendly(e)}', LogKind.error),
    );
    _scanningSub = FlutterBluePlus.isScanning.listen((value) {
      _scanning = value;
      if (!value) _scanWatchdog?.cancel();
      _notify();
    });
    _adapterSub = FlutterBluePlus.adapterState.listen(_onAdapterState);
    _adapter = FlutterBluePlus.adapterStateNow;
    _log('BLE Studio 已启动', LogKind.system);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _keepAliveTimer?.cancel();
    _packetTimer?.cancel();
    _scanWatchdog?.cancel();
    _reconnectTimer?.cancel();
    _scanSub?.cancel();
    _scanningSub?.cancel();
    _adapterSub?.cancel();
    _connSub?.cancel();
    for (final sub in _notifySubs.values) {
      sub.cancel();
    }
    _notifySubs.clear();
    if (_device != null) unawaited(_safeDisconnect(_device!));
    super.dispose();
  }

  /// App 回到前台时补一次链路检查。
  void onResumed() {
    if (_desired == null) return;
    if (_device?.isConnected ?? false) return;
    if (_reconnecting || _connectingId != null || _phase == LinkPhase.connecting) return;
    _log('应用回到前台，检查链路', LogKind.info);
    unawaited(_scheduleReconnect());
  }

  // ------------------------------------------------------------ scan logic

  Future<void> scan() async {
    if (_scanning) {
      await stopScan();
    } else {
      await startScan();
    }
  }

  Future<void> startScan({Duration duration = const Duration(seconds: 12)}) async {
    try {
      if (!await FlutterBluePlus.isSupported) {
        throw const BleAppException('此设备不支持 BLE');
      }
      await _ensureAdapterOn();
      _results.clear();
      _lastSeen.clear();
      _notify();
      _log('开始扫描附近设备', LogKind.system);
      await FlutterBluePlus.startScan(
        timeout: duration,
        continuousUpdates: true,
        removeIfGone: const Duration(seconds: 6),
        androidScanMode: AndroidScanMode.lowLatency,
        androidUsesFineLocation: false,
        // 声明了 neverForLocation 的 BLUETOOTH_SCAN 在 Android 12+ 不需要定位；
        // 关掉这个检查避免“必须打开定位服务”才能扫描。
        androidCheckLocationServices: false,
      );
      _scanWatchdog?.cancel();
      _scanWatchdog = Timer(duration + const Duration(seconds: 3), () {
        if (_scanning) unawaited(stopScan());
      });
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {
      // 忽略停止扫描失败。
    }
  }

  void _onScanResults(List<ScanResult> items) {
    final now = DateTime.now();
    for (final item in items) {
      final id = item.device.remoteId.str;
      _results[id] = item;
      _lastSeen[id] = now;
    }
    final stale = _lastSeen.entries
        .where((e) => now.difference(e.value) > const Duration(seconds: 12))
        .map((e) => e.key)
        .toList();
    for (final id in stale) {
      if (_device?.remoteId.str == id) continue;
      _results.remove(id);
      _lastSeen.remove(id);
    }
    _notify();
  }

  // --------------------------------------------------------- connect logic

  Future<void> connect(BluetoothDevice device) async {
    if (_connectingId != null) return;
    _generation++;
    final gen = _generation;
    _desired = device;
    _reconnecting = false;
    _reconnectAttempt = 0;
    _lastConnectError = null;
    _connectingId = device.remoteId.str;
    _deviceLabel = _labelFor(device);
    _phase = LinkPhase.connecting;
    _notify();

    try {
      await stopScan();
      if (_device != null && _device!.remoteId != device.remoteId) {
        await _teardown(clearDesired: false);
      }
      _device = device;
      _watchConnection(device);
      _log('正在连接 $_deviceLabel', LogKind.system);

      var ok = await _tryConnect(device, attempts: 3);
      if (!ok && gen == _generation) {
        _log('常规连接未成功，改用系统级自动连接', LogKind.info);
        ok = await _tryAutoConnect(device);
      }
      if (gen != _generation) return;
      if (!ok) {
        throw BleAppException(_lastConnectError ?? '连接失败，请靠近设备后重试');
      }

      _phase = LinkPhase.connected;
      _reconnectAttempt = 0;
      _notify();
      _log('连接成功', LogKind.system);
      await _afterConnected(device);
    } catch (e) {
      if (gen == _generation) {
        _fail(e);
        await _teardown(clearDesired: true);
      }
    } finally {
      if (_connectingId == device.remoteId.str) {
        _connectingId = null;
        _notify();
      }
    }
  }

  /// 多轮直连，覆盖偶发的 GATT 133 / 超时。
  Future<bool> _tryConnect(BluetoothDevice device, {int attempts = 1}) async {
    for (var i = 1; i <= attempts; i++) {
      if (i > 1) {
        _log('第 $i 次重试连接…', LogKind.info);
        await Future<void>.delayed(Duration(milliseconds: 400 * i));
      }
      try {
        await device.connect(
          license: _license,
          timeout: const Duration(seconds: 15),
          mtu: _targetMtu,
        );
        if (device.isConnected) return true;
      } catch (e) {
        _lastConnectError = _friendly(e);
        if (device.isConnected) return true;
        _log('连接失败：${_friendly(e)}', LogKind.error);
        try {
          await device.disconnect(timeout: 10, androidDelay: 500);
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  /// 兜底：交给系统做后台自动连接（对已配对/可定向的设备成功率更高）。
  Future<bool> _tryAutoConnect(BluetoothDevice device) async {
    try {
      await device.connect(
        license: _license,
        autoConnect: true,
        mtu: null,
        timeout: const Duration(seconds: 8),
      );
    } catch (e) {
      _lastConnectError = _friendly(e);
      _log('系统自动连接请求失败：${_friendly(e)}', LogKind.error);
      return false;
    }
    try {
      await device.connectionState
          .where((s) => s == BluetoothConnectionState.connected)
          .first
          .timeout(const Duration(seconds: 20));
      return device.isConnected;
    } on TimeoutException {
      _log('系统自动连接超时', LogKind.error);
      try {
        await device.disconnect(timeout: 5, androidDelay: 300);
      } catch (_) {}
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _afterConnected(BluetoothDevice device) async {
    try {
      await device.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
      _log('已请求高优先级连接参数', LogKind.info);
    } catch (_) {
      // iOS 或部分平台不支持，忽略。
    }
    try {
      final negotiated = await device.requestMtu(_targetMtu);
      _log('MTU 协商为 $negotiated', LogKind.info);
    } catch (_) {
      // 协商失败时继续使用默认 MTU。
    }
    await discover();
    await _restoreNotify();
    _startKeepAlive();
    _syncPacketTimer();
    _notify();
  }

  Future<void> _safeDisconnect(BluetoothDevice device) async {
    try {
      await device.disconnect();
    } catch (_) {}
  }

  void _watchConnection(BluetoothDevice device) {
    unawaited(_connSub?.cancel());
    _connSub = device.connectionState.listen(
      (state) {
        if (_device?.remoteId != device.remoteId) return;
        if (state == BluetoothConnectionState.connected) {
          final first = _phase != LinkPhase.connected;
          _phase = LinkPhase.connected;
          _reconnectAttempt = 0;
          _startKeepAlive();
          if (first) {
            _lastConnectedId = device.remoteId.str;
            _connectedSerial++;
            if (_connectingId == null) _log('链路已就绪', LogKind.system);
          }
          _notify();
          return;
        }
        if (_phase == LinkPhase.connecting) return;
        _onLinkLost();
      },
      onError: (Object e) => _log('链路异常：${_friendly(e)}', LogKind.error),
    );
  }

  void _onLinkLost() {
    if (_disposed) return;
    _stopKeepAlive();
    _packetTimer?.cancel();
    _packetTimer = null;
    _services = const [];
    _tx = null;
    _rx = null;
    _keepAliveChar = null;
    for (final sub in _notifySubs.values) {
      sub.cancel();
    }
    _notifySubs.clear();
    if (_reconnecting) {
      // 重连尝试过程中的断开事件：保持“重连中”状态，由重连流程继续推进。
      _notify();
      return;
    }
    _phase = LinkPhase.idle;
    _notify();
    if (!_autoReconnect || _desired == null) {
      _log('连接已断开', LogKind.error);
      return;
    }
    _log('连接已断开，准备自动重连', LogKind.error);
    unawaited(_delayedReconnect());
  }

  /// 断连后稍等再重连，避免链路抖动造成连接风暴。
  Future<void> _delayedReconnect() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_disposed || _reconnecting || _phase == LinkPhase.connected) return;
    await _scheduleReconnect();
  }

  Future<void> _scheduleReconnect() async {
    if (_reconnecting) return;
    final device = _desired;
    if (device == null) return;
    final gen = _generation;
    _reconnecting = true;
    _phase = LinkPhase.reconnecting;
    _notify();
    const waits = [1, 2, 3, 5, 8, 12, 18, 25];
    try {
      for (var i = 0; i < waits.length; i++) {
        if (_disposed ||
            gen != _generation ||
            !_autoReconnect ||
            _desired?.remoteId != device.remoteId) {
          return;
        }
        _reconnectAttempt = i + 1;
        _notify();
        if (_device?.isConnected ?? false) {
          _phase = LinkPhase.connected;
          _reconnectAttempt = 0;
          _notify();
          _log('链路已恢复', LogKind.system);
          await _afterConnected(device);
          return;
        }
        _log('自动重连 ${i + 1}/${waits.length}…', LogKind.info);
        try {
          await _ensureAdapterOn();
        } catch (e) {
          _log('蓝牙不可用：${_friendly(e)}', LogKind.error);
        }
        var ok = await _tryConnect(device, attempts: 1);
        // 前两次走快速直连，多次失败后再交给系统级自动连接，避免长时间阻塞。
        if (!ok && i >= 2 && gen == _generation) {
          ok = await _tryAutoConnect(device);
        }
        if (_disposed || gen != _generation) return;
        if (ok) {
          _phase = LinkPhase.connected;
          _reconnectAttempt = 0;
          _notify();
          _log('自动重连成功', LogKind.system);
          await _afterConnected(device);
          return;
        }
        await Future<void>.delayed(Duration(seconds: waits[i]));
      }
      _log('自动重连失败，请手动重新连接', LogKind.error);
      _phase = LinkPhase.idle;
    } finally {
      _reconnecting = false;
      _notify();
    }
  }

  void cancelReconnect() {
    _generation++;
    _phase = LinkPhase.idle;
    _log('已停止自动重连', LogKind.info);
    _notify();
  }

  Future<void> disconnect() async {
    _generation++;
    _log('主动断开连接', LogKind.system);
    await _teardown(clearDesired: true);
  }

  Future<void> _teardown({required bool clearDesired}) async {
    final device = _device;
    _stopKeepAlive();
    _packetTimer?.cancel();
    _packetTimer = null;
    _services = const [];
    _tx = null;
    _rx = null;
    _keepAliveChar = null;
    for (final sub in _notifySubs.values) {
      sub.cancel();
    }
    _notifySubs.clear();
    _connSub?.cancel();
    _connSub = null;
    _device = null;
    _connectingId = null;
    _phase = LinkPhase.idle;
    _reconnectAttempt = 0;
    if (clearDesired) _desired = null;
    _notify();
    if (device != null) await _safeDisconnect(device);
  }

  // ---------------------------------------------------------- gatt & comms

  Future<void> discover() async {
    final device = _device;
    if (device == null || !device.isConnected) return;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final services = await device.discoverServices();
        _services = services;
        _pickChannels(services);
        _notify();
        final chars = services.fold<int>(0, (sum, s) => sum + s.characteristics.length);
        _log('发现 ${services.length} 个服务 / $chars 个特征值', LogKind.system);
        return;
      } catch (e) {
        if (attempt == 2) {
          _fail(e);
          return;
        }
        // 刚连上时偶发 GATT 133，稍等再读一次服务。
        _log('读取服务失败，准备重试…', LogKind.info);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  void _pickChannels(List<BluetoothService> services) {
    final oldTx = _tx?.characteristicUuid.str;
    final oldRx = _rx?.characteristicUuid.str;

    BluetoothCharacteristic? find(String? uuid, bool Function(BluetoothCharacteristic) test) {
      if (uuid == null) return null;
      for (final service in services) {
        for (final c in service.characteristics) {
          if (c.characteristicUuid.str == uuid && test(c)) return c;
        }
      }
      return null;
    }

    bool writable(BluetoothCharacteristic c) =>
        c.properties.write || c.properties.writeWithoutResponse;
    bool notifiable(BluetoothCharacteristic c) =>
        c.properties.notify || c.properties.indicate;

    var tx = find(oldTx, writable);
    var rx = find(oldRx, notifiable);

    // 优先识别 Nordic UART，串口透传设备通常使用这套 UUID。
    for (final service in services) {
      if (service.uuid.str.toLowerCase() != _nusService) continue;
      for (final c in service.characteristics) {
        if (tx == null && writable(c)) tx = c;
        if (rx == null && notifiable(c)) rx = c;
      }
    }
    for (final service in services) {
      for (final c in service.characteristics) {
        if (tx == null && writable(c)) tx = c;
        if (rx == null && notifiable(c)) rx = c;
      }
    }

    BluetoothCharacteristic? keepAliveChar;
    if (tx != null) {
      for (final service in services) {
        if (!service.characteristics.contains(tx)) continue;
        for (final c in service.characteristics) {
          if (c.properties.read) {
            keepAliveChar = c;
            break;
          }
        }
        break;
      }
    }
    if (keepAliveChar == null) {
      for (final service in services) {
        for (final c in service.characteristics) {
          if (c.properties.read) {
            keepAliveChar = c;
            break;
          }
        }
        if (keepAliveChar != null) break;
      }
    }

    _tx = tx;
    _rx = rx;
    _keepAliveChar = keepAliveChar;
  }

  Future<void> read(BluetoothCharacteristic c) async {
    try {
      final bytes = await c.read();
      _handleRx(bytes, prefix: 'READ ${shortGuid(c.characteristicUuid)}');
    } catch (e) {
      _fail(e);
    }
  }

  /// 统一处理收到的数据：计数、喂给波形解析器、写日志。
  void _handleRx(List<int> data, {String prefix = 'RX'}) {
    if (data.isEmpty) return;
    _rxCount += data.length;
    _wave.feed(data);
    _log('$prefix ${data.length}B  ${_decode(data)}', LogKind.rx);
  }

  Future<void> toggleNotify(BluetoothCharacteristic c) async {
    final key = _keyOf(c);
    try {
      if (_notifySubs.containsKey(key)) {
        await c.setNotifyValue(false);
        await _notifySubs.remove(key)?.cancel();
        _wantedNotify.remove(key);
        _log('已关闭通知 ${shortGuid(c.characteristicUuid)}', LogKind.info);
      } else {
        final sub = c.onValueReceived.listen(_handleRx);
        try {
          await c.setNotifyValue(true);
        } catch (_) {
          await sub.cancel();
          rethrow;
        }
        _notifySubs[key] = sub;
        _wantedNotify.add(key);
        _log('已开启通知 ${shortGuid(c.characteristicUuid)}', LogKind.info);
      }
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  void selectTx(BluetoothCharacteristic c) {
    _tx = c;
    _log('TX 通道切换为 ${shortGuid(c.characteristicUuid)}', LogKind.info);
  }

  void selectRx(BluetoothCharacteristic c) {
    _rx = c;
    _log('RX 通道切换为 ${shortGuid(c.characteristicUuid)}', LogKind.info);
  }

  bool notifyOn(BluetoothCharacteristic c) => _notifySubs.containsKey(_keyOf(c));

  Future<void> _restoreNotify() async {
    if (_wantedNotify.isEmpty) return;
    for (final service in _services) {
      for (final c in service.characteristics) {
        final key = _keyOf(c);
        if (!_wantedNotify.contains(key) || _notifySubs.containsKey(key)) continue;
        if (!(c.properties.notify || c.properties.indicate)) continue;
        final sub = c.onValueReceived.listen(_handleRx);
        try {
          await c.setNotifyValue(true);
          _notifySubs[key] = sub;
        } catch (_) {
          await sub.cancel();
          _log('恢复通知失败 ${shortGuid(c.characteristicUuid)}', LogKind.error);
        }
      }
    }
    _notify();
  }

  Future<bool> send(String text, {bool? hex}) async {
    final useHex = hex ?? _hexSend;
    try {
      final bytes = useHex ? parseHex(text) : utf8.encode(text);
      return await _writeBytes(bytes, preview: useHex ? toHex(bytes) : text);
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// 直接发送原始字节（控件整包模式使用）。
  Future<bool> sendBytes(List<int> bytes, {bool silent = false}) {
    return _writeBytes(bytes, preview: toHex(bytes), silent: silent);
  }

  Future<bool> _writeBytes(
    List<int> bytes, {
    required String preview,
    bool silent = false,
  }) async {
    final channel = _tx;
    if (channel == null) {
      _fail(const BleAppException('请先连接设备并选择 TX 特征值'));
      return false;
    }
    if (bytes.isEmpty) {
      _fail(const BleAppException('发送内容为空'));
      return false;
    }
    try {
      final currentMtu = _device?.mtuNow ?? 23;
      final limit = math.max(20, currentMtu - 3);
      if (bytes.length > limit) {
        throw BleAppException(
          '数据 ${bytes.length} 字节，超过单包上限 $limit 字节（当前 MTU $currentMtu）',
        );
      }
      final withoutResponse = !channel.properties.write && channel.properties.writeWithoutResponse;
      await channel.write(bytes, withoutResponse: withoutResponse);
      _txCount += bytes.length;
      _lastSentPreview = preview;
      _log('TX ${bytes.length}B  $preview', LogKind.tx);
      return true;
    } catch (e) {
      if (silent) {
        // 周期组包失败时不要每秒弹提示，只在错误变化时写一条日志。
        final message = '发送失败：${_friendly(e)}';
        if (_lastPacketError != message) {
          _lastPacketError = message;
          _log(message, LogKind.error);
        }
      } else {
        _fail(e);
      }
      return false;
    }
  }

  // ------------------------------------------------------------- keepalive

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    if (!_keepAlive) return;
    _keepAliveTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(_keepAliveTick()),
    );
  }

  void _stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  /// 定期读一次可读特征值，让链路维持活跃，减少系统空闲超时断连。
  Future<void> _keepAliveTick() async {
    if (!_keepAlive || _phase != LinkPhase.connected) return;
    final device = _device;
    final channel = _keepAliveChar;
    if (device == null || !device.isConnected || channel == null) return;
    try {
      await channel.read();
    } catch (_) {
      // 读取失败交给 connectionState 处理，这里不打断用户操作。
    }
  }

  // -------------------------------------------------------------- settings

  void setAutoReconnect(bool value) {
    _autoReconnect = value;
    if (!value) {
      _reconnectTimer?.cancel();
      if (_phase == LinkPhase.reconnecting) {
        _generation++;
        _phase = LinkPhase.idle;
      }
    }
    _log(value ? '已开启自动重连' : '已关闭自动重连', LogKind.info);
    _notify();
  }

  void setKeepAlive(bool value) {
    _keepAlive = value;
    if (value) {
      _startKeepAlive();
    } else {
      _stopKeepAlive();
    }
    _log(value ? '已开启心跳保活（每 12 秒）' : '已关闭心跳保活', LogKind.info);
    _notify();
  }

  void setHexSend(bool value) {
    _hexSend = value;
    _notify();
  }

  void setAutoOpenTerminal(bool value) {
    _autoOpenTerminal = value;
    _log(value ? '连接成功后自动进入数据页' : '连接成功后留在设备页', LogKind.info);
  }

  void setHexReceive(bool value) {
    _hexReceive = value;
    _notify();
  }

  void clearLogs() {
    _logs.clear();
    _notify();
  }

  void clearWave() {
    _wave.clear();
    _notify();
  }

  void updateCommand(String key, ControlCommand command) {
    _commands[key] = command;
    _log('控件指令已更新：${command.label}', LogKind.info);
  }

  // ------------------------------------------------------- 控件发送模式

  void setControlMode(ControlSendMode mode) {
    if (_controlMode == mode) return;
    _controlMode = mode;
    _syncPacketTimer();
    _log(
      mode == ControlSendMode.single ? '控件：独立指令模式' : '控件：整包模式',
      LogKind.info,
    );
  }

  void setPacketTemplate(String template) {
    _packetTemplate = template;
    _lastPacketError = null;
  }

  void setPacketHex(bool value) {
    _packetHex = value;
    _lastPacketError = null;
    _notify();
  }

  void setPacketIntervalMs(int milliseconds) {
    _packetIntervalMs = milliseconds.clamp(20, 1000);
    _syncPacketTimer();
    _notify();
  }

  void updateControls({
    double? joyX,
    double? joyY,
    double? sliderA,
    double? sliderB,
    Set<String>? pressed,
  }) {
    if (joyX != null) _joyX = joyX.clamp(-1.0, 1.0).toDouble();
    if (joyY != null) _joyY = joyY.clamp(-1.0, 1.0).toDouble();
    if (sliderA != null) _sliderA = sliderA.clamp(0.0, 100.0).toDouble();
    if (sliderB != null) _sliderB = sliderB.clamp(0.0, 100.0).toDouble();
    if (pressed != null) _pressedKeys = pressed;
    _notify();
  }

  int get pressedBitmap {
    var bitmap = 0;
    for (var i = 1; i <= 4; i++) {
      if (_pressedKeys.contains('k$i')) bitmap |= 1 << (i - 1);
    }
    return bitmap;
  }

  Map<String, int> _packetIntValues() {
    return {
      'x': ((_joyX * 100).round() + 100).clamp(0, 200),
      'y': ((_joyY * 100).round() + 100).clamp(0, 200),
      's1': _sliderA.round().clamp(0, 100),
      's2': _sliderB.round().clamp(0, 100),
      'btn': pressedBitmap,
      'k1': _pressedKeys.contains('k1') ? 1 : 0,
      'k2': _pressedKeys.contains('k2') ? 1 : 0,
      'k3': _pressedKeys.contains('k3') ? 1 : 0,
      'k4': _pressedKeys.contains('k4') ? 1 : 0,
    };
  }

  Map<String, String> _packetTextValues() {
    final ints = _packetIntValues();
    return {
      'x': '${(_joyX * 100).round()}',
      'y': '${(_joyY * 100).round()}',
      's1': '${ints['s1']}',
      's2': '${ints['s2']}',
      'btn': '${ints['btn']}',
      'k1': '${ints['k1']}',
      'k2': '${ints['k2']}',
      'k3': '${ints['k3']}',
      'k4': '${ints['k4']}',
    };
  }

  /// 立即按模板组包并发送一次（按键变化时调用，保证响应）。
  Future<void> sendPacketNow() async {
    if (!connected || _tx == null) return;
    try {
      if (_packetHex) {
        final bytes = buildHexPacket(_packetTemplate, _packetIntValues());
        await sendBytes(bytes, silent: true);
      } else {
        final text = buildTextPacket(_packetTemplate, _packetTextValues());
        await _writeBytes(utf8.encode(text), preview: text, silent: true);
      }
      _lastPacketError = null;
    } on PacketBuildException catch (e) {
      // 模板写错时不要每秒刷屏，只在错误变化时提示。
      if (_lastPacketError != e.message) {
        _lastPacketError = e.message;
        _log('组包失败：${e.message}', LogKind.error);
      }
    }
  }

  void _syncPacketTimer() {
    _packetTimer?.cancel();
    _packetTimer = null;
    if (_controlMode != ControlSendMode.packet || !connected) return;
    _packetTimer = Timer.periodic(
      Duration(milliseconds: _packetIntervalMs),
      (_) => unawaited(sendPacketNow()),
    );
  }

  // --------------------------------------------------------------- helpers

  void _onAdapterState(BluetoothAdapterState state) {
    final wasOn = _adapter == BluetoothAdapterState.on;
    _adapter = state;
    _notify();
    if (state == BluetoothAdapterState.on) {
      if (!wasOn && _desired != null) {
        // 蓝牙刚打开时协议栈需要短暂初始化，延迟一点再恢复连接。
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(const Duration(milliseconds: 1200), () {
          if (_disposed || _desired == null) return;
          if (_device?.isConnected ?? false) return;
          if (_reconnecting || _phase == LinkPhase.connecting) return;
          _log('蓝牙已开启，尝试恢复连接', LogKind.system);
          unawaited(_scheduleReconnect());
        });
      }
      return;
    }
    if (wasOn) {
      _log('系统蓝牙已关闭', LogKind.error);
      _stopKeepAlive();
      _phase = LinkPhase.idle;
      // 暂停进行中的自动重连，等蓝牙重新打开后再恢复。
      _generation++;
      _notify();
    }
  }

  Future<void> _ensureAdapterOn() async {
    var state = FlutterBluePlus.adapterStateNow;
    _adapter = state;
    if (state == BluetoothAdapterState.on) return;
    if (state == BluetoothAdapterState.unauthorized) {
      throw const BleAppException('蓝牙权限被拒绝，请在系统设置中允许');
    }
    if (state == BluetoothAdapterState.unavailable) {
      throw const BleAppException('当前设备不支持蓝牙');
    }
    _log('正在请求开启蓝牙…', LogKind.system);
    try {
      await FlutterBluePlus.turnOn(timeout: 30);
    } catch (e) {
      throw BleAppException('无法开启蓝牙：${_friendly(e)}');
    }
    await FlutterBluePlus.adapterState
        .where((s) => s == BluetoothAdapterState.on)
        .first
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => FlutterBluePlus.adapterStateNow,
        );
    // 刚打开蓝牙时协议栈还未完全就绪，稍等再扫描。
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  String deviceName(ScanResult result) {
    final advName = result.advertisementData.advName.trim();
    if (advName.isNotEmpty) return advName;
    final platformName = result.device.platformName.trim();
    return platformName.isNotEmpty ? platformName : unnamedDevice;
  }

  String _labelFor(BluetoothDevice device) {
    final name = device.platformName.trim();
    return name.isNotEmpty ? name : device.remoteId.str;
  }

  String _keyOf(BluetoothCharacteristic c) =>
      '${c.serviceUuid.str}/${c.characteristicUuid.str}';

  String shortGuid(Guid guid) {
    final text = guid.str.toUpperCase();
    if (text.endsWith('-0000-1000-8000-00805F9B34FB')) return text.substring(4, 8);
    return text;
  }

  String _decode(List<int> data) =>
      _hexReceive ? toHex(data) : utf8.decode(data, allowMalformed: true);

  static String toHex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  static List<int> parseHex(String text) {
    final normalized = text.replaceAll(RegExp(r'[\s,;:]'), '');
    if (normalized.isEmpty ||
        normalized.length.isOdd ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(normalized)) {
      throw const BleAppException('HEX 格式错误，例如 AA 01 0F');
    }
    return List<int>.generate(
      normalized.length ~/ 2,
      (i) => int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16),
    );
  }

  void _log(String message, LogKind kind) {
    if (_disposed) return;
    _logs.insert(0, LogEntry(message, kind));
    if (_logs.length > _maxLogs) _logs.removeLast();
    _notify();
  }

  void _fail(Object e) {
    _lastError = _friendly(e);
    _errorSerial++;
    if (_disposed) return;
    _logs.insert(0, LogEntry('错误：$_lastError', LogKind.error));
    if (_logs.length > _maxLogs) _logs.removeLast();
    _notify();
  }

  String _friendly(Object e) {
    if (e is BleAppException) return e.message;
    if (e is TimeoutException) return '操作超时，请靠近设备后重试';
    final text = e.toString();
    final lower = text.toLowerCase();
    if (lower.contains('permission') ||
        lower.contains('security') ||
        lower.contains('not authorized')) {
      return '缺少蓝牙权限，请在系统设置中允许蓝牙访问';
    }
    if (text.contains('133')) {
      return '连接失败(133)：设备拒绝或信号太弱，请靠近后重试';
    }
    if (lower.contains('location services') || lower.contains('location service')) {
      return '请打开系统定位服务后再扫描（Android 扫描 BLE 需要）';
    }
    if (lower.contains('bluetooth is off') || lower.contains('adapter is off')) {
      return '蓝牙未开启，请先打开蓝牙';
    }
    if (lower.contains('timeout')) return '操作超时，请靠近设备后重试';
    if (lower.contains('not supported')) return '当前设备不支持该操作';
    if (lower.contains('cancelled') || lower.contains('canceled')) {
      return '连接已取消';
    }
    return text.replaceFirst('Exception: ', '');
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}
