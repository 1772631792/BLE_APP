import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_controller.dart';
import 'pages/controls_page.dart';
import 'pages/data_page.dart';
import 'pages/devices_page.dart';
import 'theme.dart';
import 'widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BleStudioApp());
}

class BleStudioApp extends StatelessWidget {
  const BleStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'BLE Studio',
      theme: buildAppTheme(),
      home: const BleHomePage(),
    );
  }
}

class BleHomePage extends StatefulWidget {
  const BleHomePage({super.key});

  @override
  State<BleHomePage> createState() => _BleHomePageState();
}

class _BleHomePageState extends State<BleHomePage> with WidgetsBindingObserver {
  final BleController _ble = BleController();
  int _tab = 0;
  int _errorSerial = 0;
  int _connectedSerial = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ble.addListener(_onBleEvent);
    _ble.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ble.removeListener(_onBleEvent);
    _ble.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _ble.onResumed();
  }

  void _onBleEvent() {
    // 连接成功后按设置自动进入数据页，少点一次。
    final connected = _ble.connectedSerial;
    if (connected != _connectedSerial) {
      _connectedSerial = connected;
      if (_ble.autoOpenTerminal && mounted && _tab != 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _tab = 1);
        });
      }
    }

    final serial = _ble.errorSerial;
    if (serial == _errorSerial) return;
    _errorSerial = serial;
    final message = _ble.lastError;
    if (message == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ble,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: Stack(
            children: [
              const _AuroraBackground(),
              SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    _header(),
                    Expanded(
                      child: IndexedStack(
                        index: _tab,
                        children: [
                          DevicesPage(ble: _ble),
                          DataPage(ble: _ble),
                          ControlsPage(ble: _ble),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: _navigation(),
        );
      },
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.accent, Color(0xFF3FA9FF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: .32),
                      blurRadius: 18,
                      offset: const Offset(0, 7),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.bluetooth_rounded,
                  color: Color(0xFF04121A),
                  size: 25,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'BLE Studio',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: .2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _ble.connected
                          ? _ble.deviceLabel
                          : '蓝牙调试助手 · 稳定连接优化',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textDim,
                        letterSpacing: .2,
                      ),
                    ),
                  ],
                ),
              ),
              if (_ble.connected)
                IconButton(
                  tooltip: '断开连接',
                  onPressed: () => _ble.disconnect(),
                  icon: const Icon(Icons.link_off_rounded, color: AppColors.danger),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: AppColors.stroke),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GlowDot(
                        color: _ble.adapter == BluetoothAdapterState.on
                            ? AppColors.accent
                            : AppColors.textDim,
                        size: 7,
                        active: _ble.adapter == BluetoothAdapterState.on,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _ble.adapter == BluetoothAdapterState.on ? '蓝牙就绪' : '蓝牙未开启',
                        style: const TextStyle(fontSize: 10.5, color: AppColors.textDim),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _statusBanner(),
        ],
      ),
    );
  }

  Widget _statusBanner() {
    final phase = _ble.phase;
    late final Color tint;
    late final IconData icon;
    late final String title;
    late final String subtitle;
    Widget? trailing;

    if (phase == LinkPhase.connected) {
      tint = AppColors.accent;
      icon = Icons.link_rounded;
      title = '已连接';
      subtitle =
          'MTU ${_ble.mtu} · ${_ble.notifyCount} 路通知 · ${_ble.autoReconnect ? '自动重连开启' : '自动重连关闭'}';
    } else if (phase == LinkPhase.connecting) {
      tint = AppColors.warn;
      icon = Icons.sync_rounded;
      title = '正在连接…';
      subtitle = _ble.deviceLabel;
    } else if (phase == LinkPhase.reconnecting) {
      tint = AppColors.warn;
      icon = Icons.autorenew_rounded;
      title = '连接中断，正在自动重连';
      subtitle = '第 ${_ble.reconnectAttempt} 次尝试';
      trailing = TextButton(
        onPressed: _ble.cancelReconnect,
        style: TextButton.styleFrom(
          foregroundColor: AppColors.warn,
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        child: const Text('停止', style: TextStyle(fontSize: 11.5)),
      );
    } else if (_ble.scanning) {
      tint = AppColors.sky;
      icon = Icons.radar_rounded;
      title = '正在扫描附近设备';
      subtitle = '已发现 ${_ble.results.length} 台 · 保持设备靠近手机';
    } else {
      tint = AppColors.textDim;
      icon = Icons.bluetooth_searching_rounded;
      title = '未连接';
      subtitle = _ble.adapter == BluetoothAdapterState.on
          ? '扫描并连接你的蓝牙设备'
          : '连接时会自动请求开启蓝牙';
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tint.withValues(alpha: .26)),
      ),
      child: Row(
        children: [
          GlowDot(
            color: tint,
            active: phase != LinkPhase.idle || _ble.scanning,
          ),
          const SizedBox(width: 10),
          Icon(icon, size: 16, color: tint.withValues(alpha: .9)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: tint,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: AppColors.textDim),
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _navigation() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.stroke.withValues(alpha: .9))),
      ),
      child: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bluetooth_searching_rounded),
            selectedIcon: Icon(Icons.bluetooth_connected_rounded),
            label: '设备',
          ),
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart_rounded),
            label: '数据',
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_esports_outlined),
            selectedIcon: Icon(Icons.sports_esports_rounded),
            label: '控件',
          ),
        ],
      ),
    );
  }
}

/// 背景渐变光斑，营造轻盈的层次感。
class _AuroraBackground extends StatelessWidget {
  const _AuroraBackground();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF070A10), Color(0xFF0B121C), Color(0xFF070B12)],
          ),
        ),
        child: Stack(
          children: [
            Positioned(top: -140, right: -90, child: _blob(300, AppColors.accent)),
            Positioned(top: 190, left: -140, child: _blob(280, AppColors.sky)),
            Positioned(bottom: -120, right: -80, child: _blob(280, AppColors.violet)),
          ],
        ),
      ),
    );
  }

  Widget _blob(double size, Color color) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color.withValues(alpha: .13), color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}
