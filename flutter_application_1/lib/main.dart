import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BleStudioApp());
}

class BleStudioApp extends StatelessWidget {
  const BleStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF69D7C4);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BLE Studio',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0D1119),
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
          surface: const Color(0xFF171E29),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF171E29),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF202A37),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        ),
      ),
      home: const BleHomePage(),
    );
  }
}

class BleHomePage extends StatefulWidget {
  const BleHomePage({super.key});

  @override
  State<BleHomePage> createState() => _BleHomePageState();
}

class _BleHomePageState extends State<BleHomePage> {
  final _search = TextEditingController();
  final _input = TextEditingController();
  final Map<String, ScanResult> _results = {};
  final List<String> _logs = [];
  final Map<String, StreamSubscription<List<int>>> _notifications = {};
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _scanningSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;

  BluetoothDevice? _device;
  List<BluetoothService> _services = [];
  BluetoothCharacteristic? _tx;
  BluetoothCharacteristic? _rx;
  BluetoothAdapterState _adapter = BluetoothAdapterState.unknown;
  bool _scanning = false;
  bool _connecting = false;
  bool _connected = false;
  bool _showUnnamed = false;
  bool _hexSend = false;
  bool _hexReceive = false;
  bool _notifyOn = false;
  int _tab = 0;
  int _rxCount = 0;
  int _txCount = 0;

  @override
  void initState() {
    super.initState();
    _scanSubscription = FlutterBluePlus.scanResults.listen((items) {
      if (!mounted) return;
      setState(() {
        for (final item in items) {
          _results[item.device.remoteId.str] = item;
        }
      });
    }, onError: (Object e) => _log('扫描异常: $e'));
    _scanningSubscription = FlutterBluePlus.isScanning.listen((v) {
      if (mounted) setState(() => _scanning = v);
    });
    _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (mounted) setState(() => _adapter = state);
    });
    _log('BLE Studio 已启动');
  }

  @override
  void dispose() {
    _search.dispose();
    _input.dispose();
    _scanSubscription?.cancel();
    _scanningSubscription?.cancel();
    _adapterSubscription?.cancel();
    _connectionSubscription?.cancel();
    for (final subscription in _notifications.values) {
      subscription.cancel();
    }
    // 页面退出时不等待系统异步操作。
    super.dispose();
  }

  String _deviceName(ScanResult r) {
    final adv = r.advertisementData.advName.trim();
    if (adv.isNotEmpty) return adv;
    final platform = r.device.platformName.trim();
    return platform.isNotEmpty ? platform : '未命名设备';
  }

  void _log(String message) {
    final t = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    final stamp = '${pad(t.hour)}:${pad(t.minute)}:${pad(t.second)}';
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[$stamp] $message');
      if (_logs.length > 400) _logs.removeLast();
    });
  }

  void _error(Object e) {
    _log('错误: $e');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _scan() async {
    if (_scanning) {
      await FlutterBluePlus.stopScan();
      return;
    }
    try {
      if (!await FlutterBluePlus.isSupported) {
        throw Exception('此设备不支持 BLE');
      }
      if (_adapter != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
        await FlutterBluePlus.adapterState
            .where((s) => s == BluetoothAdapterState.on)
            .first
            .timeout(const Duration(seconds: 12));
      }
      setState(() => _results.clear());
      _log('扫描开始（8 秒）');
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      await FlutterBluePlus.stopScan();
      if (_device != null && _device!.remoteId != device.remoteId) {
        await _disconnect();
      }
      await _connectionSubscription?.cancel();
      _connectionSubscription = device.connectionState.listen((state) {
        if (!mounted || _device?.remoteId != device.remoteId) return;
        final isConnected = state == BluetoothConnectionState.connected;
        if (!isConnected && _connected) {
          _log('设备已断开');
          _clearGatt();
        }
        setState(() => _connected = isConnected);
      });
      setState(() => _device = device);
      _log('正在连接 ${device.remoteId.str}');
      await device.connect(
  license: License.nonprofit,
  timeout: const Duration(seconds: 15),
);
      if (!mounted) return;
      setState(() => _connected = true);
      _log('连接成功，读取 GATT 服务');
      await _discover();
      if (mounted) setState(() => _tab = 1);
    } catch (e) {
      _error(e);
      try { await device.disconnect(); } catch (_) {}
      if (mounted) setState(() { _connected = false; _device = null; });
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _clearGatt() {
    for (final sub in _notifications.values) {
      sub.cancel();
    }
    _notifications.clear();
    _services = [];
    _tx = null;
    _rx = null;
    _notifyOn = false;
  }

  Future<void> _disconnect() async {
    final device = _device;
    if (device == null) return;
    try {
      await device.disconnect();
      _log('主动断开连接');
    } catch (e) {
      _error(e);
    }
    if (!mounted) return;
    setState(() {
      _clearGatt();
      _device = null;
      _connected = false;
      _tab = 0;
    });
  }

  Future<void> _discover() async {
    final device = _device;
    if (device == null || !_connected) return;
    try {
      final services = await device.discoverServices();
      if (!mounted) return;
      setState(() {
        _clearGatt();
        _services = services;
        // 默认选第一个可写/可通知特征值，之后可手动切换。
        for (final service in services) {
          for (final c in service.characteristics) {
            if (_tx == null && (c.properties.write || c.properties.writeWithoutResponse)) {
              _tx = c;
            }
            if (_rx == null && (c.properties.notify || c.properties.indicate)) {
              _rx = c;
            }
          }
        }
      });
      _log('发现 ${services.length} 个服务');
    } catch (e) {
      _error(e);
    }
  }

  String _short(Guid guid) {
    final s = guid.str.toUpperCase();
    if (s.endsWith('-0000-1000-8000-00805F9B34FB')) return s.substring(4, 8);
    return s;
  }

  String _characterKey(BluetoothCharacteristic c) =>
      '${c.serviceUuid.str}/${c.characteristicUuid.str}';

  Future<void> _read(BluetoothCharacteristic c) async {
    try {
      final bytes = await c.read();
      _received(bytes, prefix: 'READ ${_short(c.characteristicUuid)}');
    } catch (e) { _error(e); }
  }

  void _received(List<int> data, {String prefix = 'RX'}) {
    final value = _hexReceive ? _asHex(data) : utf8.decode(data, allowMalformed: true);
    _log('$prefix (${data.length}B): $value');
    if (mounted) setState(() => _rxCount += data.length);
  }

  Future<void> _toggleNotify(BluetoothCharacteristic c) async {
    final key = _characterKey(c);
    try {
      if (_notifications.containsKey(key)) {
        await c.setNotifyValue(false);
        await _notifications.remove(key)?.cancel();
        _log('Notify 关闭 ${_short(c.characteristicUuid)}');
      } else {
        final subscription = c.onValueReceived.listen((data) {
          if (mounted) _received(data);
        });
        try {
          await c.setNotifyValue(true);
        } catch (_) {
          await subscription.cancel();
          rethrow;
        }
        _notifications[key] = subscription;
        _log('Notify 开启 ${_short(c.characteristicUuid)}');
      }
      if (mounted) setState(() => _notifyOn = _notifications.containsKey(key));
    } catch (e) { _error(e); }
  }

  static String _asHex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  List<int> _parseHex(String text) {
    final normalized = text.replaceAll(RegExp(r'[\s,;:]'), '');
    if (normalized.isEmpty || normalized.length.isOdd ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(normalized)) {
      throw const FormatException('HEX 格式错误，例如 AA 01 0F');
    }
    return List.generate(normalized.length ~/ 2,
        (i) => int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16));
  }

  Future<void> _send() async {
    if (!_connected || _tx == null) {
      _error('请先连接设备并选择 TX 特征值');
      return;
    }
    try {
      final bytes = _hexSend ? _parseHex(_input.text) : utf8.encode(_input.text);
      if (bytes.isEmpty) return;
      final c = _tx!;
      // 不自动分包：超过 ATT 单次写入上限时明确报错，防止破坏设备协议。
      final limit = _device!.mtuNow - 3;
      if (bytes.length > limit) {
        throw FormatException('数据 ${bytes.length} 字节，超过当前单包上限 $limit 字节');
      }
      await c.write(bytes, withoutResponse: !c.properties.write && c.properties.writeWithoutResponse);
      _log('TX (${bytes.length}B): ${_hexSend ? _asHex(bytes) : _input.text}');
      if (mounted) setState(() => _txCount += bytes.length);
    } catch (e) { _error(e); }
  }

  Widget _panel({required Widget child}) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      );

  Widget _sectionTitle(String title, IconData icon, [Widget? trailing]) => Row(
        children: [Icon(icon, size: 19, color: const Color(0xFF69D7C4)),
          const SizedBox(width: 9),
          Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
          ?trailing],
      );

  Widget _devicesTab() {
    final q = _search.text.toLowerCase();
    final items = _results.values.where((r) {
      final name = _deviceName(r);
      if (!_showUnnamed && name == '未命名设备') return false;
      return name.toLowerCase().contains(q) || r.device.remoteId.str.toLowerCase().contains(q);
    }).toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    return ListView(padding: const EdgeInsets.all(14), children: [
      _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sectionTitle('附近 BLE 设备', Icons.radar,
          Text('${items.length} 台', style: const TextStyle(color: Colors.white54))),
        const SizedBox(height: 13),
        TextField(controller: _search, onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: '搜索设备名称 / 地址')),
        SwitchListTile.adaptive(dense: true, contentPadding: EdgeInsets.zero,
          title: const Text('显示未命名设备', style: TextStyle(fontSize: 13)),
          value: _showUnnamed, onChanged: (v) => setState(() => _showUnnamed = v)),
        FilledButton.icon(onPressed: _scan,
          icon: Icon(_scanning ? Icons.stop : Icons.bluetooth_searching),
          label: Text(_scanning ? '停止扫描' : '扫描 8 秒')),
      ])),
      if (items.isEmpty) _panel(child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('暂无设备，点击扫描开始搜索', style: TextStyle(color: Colors.white60))),
      )),
      ...items.map((r) => _panel(child: Row(children: [
        Container(width: 42, height: 42,
          decoration: BoxDecoration(color: const Color(0xFF263D48), borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.bluetooth, color: Color(0xFF69D7C4))),
        const SizedBox(width: 11),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_deviceName(r), style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(r.device.remoteId.str, style: const TextStyle(color: Colors.white54, fontSize: 11)),
          Text('${r.rssi} dBm', style: const TextStyle(color: Color(0xFF69D7C4), fontSize: 12)),
        ])),
        FilledButton.tonal(onPressed: _connecting ? null : () => _connect(r.device),
          child: const Text('连接')),
      ]))),
    ]);
  }

  Widget _gattTab() {
    if (!_connected) return const Center(child: Text('请先在设备页连接 BLE 设备'));
    return ListView(padding: const EdgeInsets.all(14), children: [
      _panel(child: Column(children: [
        _sectionTitle('GATT 服务', Icons.account_tree_outlined,
          IconButton(tooltip: '重新发现服务', onPressed: _discover, icon: const Icon(Icons.refresh))),
        const SizedBox(height: 8),
        Text('点击特征值的 TX / RX 来指定收发通道',
          style: TextStyle(color: Colors.white.withValues(alpha: .65), fontSize: 12)),
      ])),
      for (final service in _services) _panel(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('SERVICE  ${_short(service.uuid)}',
            style: const TextStyle(color: Color(0xFF69D7C4), fontWeight: FontWeight.bold)),
          const Divider(height: 22),
          for (final c in service.characteristics) ...[
            Text(_short(c.characteristicUuid), style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 5, children: [
              if (c.properties.read) OutlinedButton(onPressed: () => _read(c), child: const Text('读取')),
              if (c.properties.write || c.properties.writeWithoutResponse)
                FilterChip(label: const Text('TX'), selected: _tx == c,
                  onSelected: (_) { setState(() => _tx = c); _log('TX 选择 ${_short(c.characteristicUuid)}'); }),
              if (c.properties.notify || c.properties.indicate) ...[
                FilterChip(label: const Text('RX'), selected: _rx == c,
                  onSelected: (_) { setState(() => _rx = c); _log('RX 选择 ${_short(c.characteristicUuid)}'); }),
                OutlinedButton(onPressed: () => _toggleNotify(c),
                  child: Text(_notifications.containsKey(_characterKey(c)) ? '关闭通知' : '开启通知')),
              ],
            ]),
            const SizedBox(height: 13),
          ],
        ],
      )),
    ]);
  }

  Widget _terminalTab() => ListView(padding: const EdgeInsets.all(14), children: [
    _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle('收发通道', Icons.tune),
      const SizedBox(height: 10),
      Text('TX: ${_tx == null ? '未选择' : _short(_tx!.characteristicUuid)}'),
      Text('RX: ${_rx == null ? '未选择' : _short(_rx!.characteristicUuid)}'),
      Text('发送 $_txCount B   /   接收 $_rxCount B',
        style: const TextStyle(color: Color(0xFF69D7C4))),
      const SizedBox(height: 8),
      if (_rx != null && (_rx!.properties.notify || _rx!.properties.indicate))
        FilledButton.tonalIcon(
          onPressed: () => _toggleNotify(_rx!),
          icon: Icon(_notifications.containsKey(_characterKey(_rx!)) ? Icons.notifications_off : Icons.notifications_active),
          label: Text(_notifications.containsKey(_characterKey(_rx!)) ? '关闭 RX 通知' : '开启 RX 通知'),
        ),
    ])),
    _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle('发送数据', Icons.send_outlined),
      const SizedBox(height: 10),
      TextField(controller: _input, minLines: 2, maxLines: 5,
        decoration: InputDecoration(hintText: _hexSend ? '例如 AA 01 0F' : '输入要发送的文字')),
      SwitchListTile.adaptive(dense: true, contentPadding: EdgeInsets.zero,
        title: const Text('HEX 发送'), value: _hexSend,
        onChanged: (v) => setState(() => _hexSend = v)),
      SwitchListTile.adaptive(dense: true, contentPadding: EdgeInsets.zero,
        title: const Text('HEX 接收显示'), value: _hexReceive,
        onChanged: (v) => setState(() => _hexReceive = v)),
      FilledButton.icon(onPressed: _connected ? _send : null,
        icon: const Icon(Icons.send), label: const Text('发送')),
    ])),
    _panel(child: Column(children: [
      _sectionTitle('通信日志', Icons.terminal,
        Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: '复制日志', onPressed: () => Clipboard.setData(ClipboardData(text: _logs.reversed.join('\n'))), icon: const Icon(Icons.copy, size: 19)),
          IconButton(tooltip: '清空日志', onPressed: () => setState(_logs.clear), icon: const Icon(Icons.delete_outline, size: 19)),
        ])),
      const SizedBox(height: 10),
      Container(
        constraints: const BoxConstraints(minHeight: 160, maxHeight: 360),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFF0C131C), borderRadius: BorderRadius.circular(12)),
        child: SingleChildScrollView(child: SelectableText(
          _logs.isEmpty ? '暂无日志' : _logs.join('\n'),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.7, color: Color(0xFFB7E0D8)),
        )),
      ),
    ])),
  ]);

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[_devicesTab(), _gattTab(), _terminalTab()];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF111823),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('BLE Studio', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
          Text(_connected ? '已连接 · ${_device!.platformName.isEmpty ? _device!.remoteId.str : _device!.platformName}' :
            '蓝牙 ${_adapter == BluetoothAdapterState.on ? '已开启' : '未就绪'}',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.white60)),
        ]),
        actions: [if (_connected) IconButton(tooltip: '断开连接',
          onPressed: _disconnect, icon: const Icon(Icons.link_off, color: Color(0xFFFF9D9D)))],
      ),
      body: SafeArea(child: tabs[_tab]),
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF111823),
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bluetooth_searching), label: '设备'),
          NavigationDestination(icon: Icon(Icons.account_tree_outlined), label: 'GATT'),
          NavigationDestination(icon: Icon(Icons.terminal), label: '终端'),
        ],
      ),
    );
  }
}
