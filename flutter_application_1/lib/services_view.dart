import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_controller.dart';
import 'theme.dart';
import 'widgets.dart';

/// 已连接设备内的服务 / 特征值浏览区（并入设备页，不再单开一页）。
class ServicesSection extends StatelessWidget {
  const ServicesSection({super.key, required this.ble});

  final BleController ble;

  @override
  Widget build(BuildContext context) {
    final services = ble.services;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '服务与特征值',
            icon: Icons.account_tree_rounded,
            subtitle: '指定 TX / RX 收发通道，开关数据通知',
            trailing: IconButton(
              tooltip: '重新发现服务',
              onPressed: () => ble.discover(),
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _channelSummary(
                  'TX',
                  ble.tx == null ? '未选择' : ble.shortGuid(ble.tx!.characteristicUuid),
                  AppColors.violet,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _channelSummary(
                  'RX',
                  ble.rx == null ? '未选择' : ble.shortGuid(ble.rx!.characteristicUuid),
                  AppColors.sky,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (services.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ),
            )
          else
            for (final service in services) _ServiceCard(ble: ble, service: service),
        ],
      ),
    );
  }

  Widget _channelSummary(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: color,
              letterSpacing: .6,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: AppColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.ble, required this.service});

  final BleController ble;
  final BluetoothService service;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt.withValues(alpha: .4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.stroke.withValues(alpha: .8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          iconColor: AppColors.accent,
          collapsedIconColor: AppColors.textDim,
          leading: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.hub_rounded, size: 15, color: AppColors.accent),
          ),
          title: Text(
            ble.shortGuid(service.uuid),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              color: AppColors.accent,
            ),
          ),
          subtitle: Text(
            '${service.characteristics.length} 个特征值',
            style: const TextStyle(fontSize: 10, color: AppColors.textDim),
          ),
          children: [
            for (final c in service.characteristics) _CharTile(ble: ble, characteristic: c),
          ],
        ),
      ),
    );
  }
}

class _CharTile extends StatelessWidget {
  const _CharTile({required this.ble, required this.characteristic});

  final BleController ble;
  final BluetoothCharacteristic characteristic;

  @override
  Widget build(BuildContext context) {
    final c = characteristic;
    final p = c.properties;
    final isTx = ble.tx?.characteristicUuid.str == c.characteristicUuid.str &&
        ble.tx?.serviceUuid.str == c.serviceUuid.str;
    final isRx = ble.rx?.characteristicUuid.str == c.characteristicUuid.str &&
        ble.rx?.serviceUuid.str == c.serviceUuid.str;
    final notifying = ble.notifyOn(c);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isTx
              ? AppColors.violet.withValues(alpha: .35)
              : isRx
                  ? AppColors.sky.withValues(alpha: .35)
                  : AppColors.stroke.withValues(alpha: .6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  ble.shortGuid(c.characteristicUuid),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (isTx) const MiniTag(label: 'TX', color: AppColors.violet),
              if (isRx) ...[
                if (isTx) const SizedBox(width: 5),
                const MiniTag(label: 'RX', color: AppColors.sky),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              if (p.read) const MiniTag(label: 'READ'),
              if (p.write) const MiniTag(label: 'WRITE'),
              if (p.writeWithoutResponse) const MiniTag(label: 'WRITE NR'),
              if (p.notify) const MiniTag(label: 'NOTIFY', color: AppColors.accent),
              if (p.indicate) const MiniTag(label: 'INDICATE', color: AppColors.warn),
            ],
          ),
          if (p.read || p.write || p.writeWithoutResponse || p.notify || p.indicate) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (p.read)
                  _ActionChip(
                    label: '读取',
                    icon: Icons.download_rounded,
                    color: AppColors.text,
                    onTap: () => ble.read(c),
                  ),
                if (p.write || p.writeWithoutResponse)
                  _ActionChip(
                    label: '设为 TX',
                    icon: Icons.upload_rounded,
                    color: isTx ? AppColors.violet : AppColors.textDim,
                    active: isTx,
                    onTap: () => ble.selectTx(c),
                  ),
                if (p.notify || p.indicate) ...[
                  _ActionChip(
                    label: '设为 RX',
                    icon: Icons.download_for_offline_outlined,
                    color: isRx ? AppColors.sky : AppColors.textDim,
                    active: isRx,
                    onTap: () => ble.selectRx(c),
                  ),
                  _ActionChip(
                    label: notifying ? '关闭通知' : '开启通知',
                    icon: notifying
                        ? Icons.notifications_off_rounded
                        : Icons.notifications_active_rounded,
                    color: notifying ? AppColors.accent : AppColors.textDim,
                    active: notifying,
                    onTap: () => ble.toggleNotify(c),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: active ? color.withValues(alpha: .14) : AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: active ? color.withValues(alpha: .45) : AppColors.stroke,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
