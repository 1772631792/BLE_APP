import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../ble_controller.dart';
import '../services_view.dart';
import '../theme.dart';
import '../widgets.dart';

/// 设备扫描页。
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.ble});

  final BleController ble;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final TextEditingController _search = TextEditingController();
  bool _showUnnamed = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ScanResult> _filtered() {
    final ble = widget.ble;
    final query = _search.text.trim().toLowerCase();
    final items = ble.results.where((r) {
      final name = ble.deviceName(r);
      if (!_showUnnamed && name == BleController.unnamedDevice) return false;
      if (query.isEmpty) return true;
      return name.toLowerCase().contains(query) ||
          r.device.remoteId.str.toLowerCase().contains(query);
    }).toList();
    items.sort((a, b) {
      // 上次连接的设备置顶，方便一键重连。
      final aLast = a.device.remoteId.str == ble.lastConnectedId;
      final bLast = b.device.remoteId.str == ble.lastConnectedId;
      if (aLast != bLast) return aLast ? -1 : 1;
      return b.rssi.compareTo(a.rssi);
    });
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
    final items = _filtered();

    return RefreshIndicator(
      onRefresh: () => ble.startScan(),
      color: AppColors.accent,
      backgroundColor: AppColors.surfaceAlt,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(
                  title: '附近设备',
                  icon: Icons.radar_rounded,
                  subtitle: '下拉可刷新 · 低延迟扫描',
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${items.length} 台',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search_rounded, size: 20),
                          hintText: '搜索名称或 MAC 地址',
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close_rounded, size: 18),
                                  onPressed: () {
                                    _search.clear();
                                    setState(() {});
                                  },
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    GradientButton(
                      label: ble.scanning ? '停止' : '扫描',
                      icon: ble.scanning
                          ? Icons.stop_rounded
                          : Icons.bluetooth_searching_rounded,
                      height: 48,
                      onPressed: () => ble.scan(),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TogglePill(
                      label: '未命名设备',
                      icon: Icons.visibility_outlined,
                      value: _showUnnamed,
                      onChanged: (v) => setState(() => _showUnnamed = v),
                    ),
                    TogglePill(
                      label: '自动重连',
                      icon: Icons.autorenew_rounded,
                      value: ble.autoReconnect,
                      onChanged: ble.setAutoReconnect,
                    ),
                    TogglePill(
                      label: '心跳保活',
                      icon: Icons.favorite_rounded,
                      value: ble.keepAlive,
                      onChanged: ble.setKeepAlive,
                    ),
                    TogglePill(
                      label: '连上后进数据页',
                      icon: Icons.show_chart_rounded,
                      value: ble.autoOpenTerminal,
                      onChanged: ble.setAutoOpenTerminal,
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (ble.connected) ServicesSection(ble: ble),
          if (items.isEmpty)
            Panel(
              child: EmptyState(
                icon: ble.scanning ? Icons.wifi_tethering_rounded : Icons.bluetooth_disabled_rounded,
                title: ble.scanning ? '正在搜索附近设备…' : '暂未发现设备',
                description: ble.scanning
                    ? '保持手机靠近目标设备，列表会自动刷新'
                    : '点击“扫描”开始搜索，或检查设备是否已上电并处于广播状态\nAndroid 12+ 无需定位权限；安卓 11 及以下请打开定位服务',
                action: ble.scanning
                    ? null
                    : TextButton.icon(
                        onPressed: () => ble.startScan(),
                        icon: const Icon(Icons.bluetooth_searching_rounded, size: 18),
                        label: const Text('开始扫描'),
                      ),
              ),
            )
          else
            ...items.map((result) => _DeviceCard(
                  ble: ble,
                  result: result,
                  name: ble.deviceName(result),
                  isLast: result.device.remoteId.str == ble.lastConnectedId,
                )),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.ble,
    required this.result,
    required this.name,
    required this.isLast,
  });

  final BleController ble;
  final ScanResult result;
  final String name;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final id = result.device.remoteId.str;
    final isActive = ble.device?.remoteId.str == id;
    final isConnected = isActive && ble.connected;
    final isConnecting = ble.connectingDeviceId == id;
    final rssi = result.rssi;

    return Panel(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      radius: 18,
      borderColor: isConnected
          ? AppColors.accent.withValues(alpha: .45)
          : AppColors.stroke.withValues(alpha: .8),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isConnected
                    ? [AppColors.accent, AppColors.accentDeep]
                    : [AppColors.surfaceAlt, AppColors.surface],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(
                color: isConnected
                    ? Colors.transparent
                    : AppColors.stroke.withValues(alpha: .9),
              ),
            ),
            child: Icon(
              isConnected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_rounded,
              color: isConnected ? AppColors.onAccent : AppColors.accent,
              size: 23,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (isConnected) ...[
                      const SizedBox(width: 6),
                      const MiniTag(label: '已连接', color: AppColors.accent),
                    ] else if (isActive) ...[
                      const SizedBox(width: 6),
                      const MiniTag(label: '待重连', color: AppColors.warn),
                    ] else if (isLast) ...[
                      const SizedBox(width: 6),
                      const MiniTag(label: '上次'),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppColors.textDim,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    SignalBars(
                      rssi: rssi,
                      color: isConnected ? AppColors.accent : AppColors.sky,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$rssi dBm',
                      style: const TextStyle(fontSize: 11, color: AppColors.textDim),
                    ),
                    if (result.advertisementData.connectable) ...[
                      const SizedBox(width: 8),
                      const MiniTag(label: '可连接', color: AppColors.textDim),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _action(isActive: isActive, isConnected: isConnected, isConnecting: isConnecting),
        ],
      ),
    );
  }

  Widget _action({
    required bool isActive,
    required bool isConnected,
    required bool isConnecting,
  }) {
    if (isConnecting) {
      return const SizedBox(
        width: 38,
        height: 38,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (isConnected) {
      return TextButton(
        onPressed: () => ble.disconnect(),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.danger,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 36),
        ),
        child: const Text('断开', style: TextStyle(fontSize: 12.5, color: AppColors.danger)),
      );
    }
    final busy = ble.connectingDeviceId != null;
    return FilledButton(
      onPressed: busy ? null : () => ble.connect(result.device),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent.withValues(alpha: .15),
        foregroundColor: AppColors.accent,
        disabledBackgroundColor: AppColors.surfaceAlt,
        disabledForegroundColor: AppColors.textDim,
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(isActive || isLast ? '重连' : '连接'),
    );
  }
}
