import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ble_controller.dart';
import '../theme.dart';
import '../wave.dart';
import '../widgets.dart';

enum DataMode { terminal, wave }

/// 数据页：终端日志 ↔ 浮点波形 双模式。
class DataPage extends StatefulWidget {
  const DataPage({super.key, required this.ble});

  final BleController ble;

  @override
  State<DataPage> createState() => _DataPageState();
}

class _DataPageState extends State<DataPage> {
  final TextEditingController _input = TextEditingController();
  final Set<int> _hidden = {};
  DataMode _mode = DataMode.terminal;
  bool _sending = false;
  bool _paused = false;
  List<List<double>>? _frozen;

  // 波形视图：横向窗口帧数 + 纵向缩放 / 平移（双指缩放、单指拖动）。
  double _viewFrames = 420;
  double _zoomY = 1;
  double _offsetY = 0;
  double _baseViewFrames = 420;
  double _baseZoomY = 1;

  static const double _maxFrames = 420;
  static const double _minFrames = 40;

  bool get _fitted =>
      _viewFrames >= _maxFrames && (_zoomY - 1).abs() < .001 && _offsetY.abs() < .001;

  void _fitView() {
    setState(() {
      _viewFrames = _maxFrames;
      _zoomY = 1;
      _offsetY = 0;
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    await widget.ble.send(_input.text);
    if (mounted) setState(() => _sending = false);
  }

  void _togglePause() {
    setState(() {
      _paused = !_paused;
      _frozen = _paused ? List<List<double>>.from(widget.ble.waveFrames) : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
      child: Column(
        children: [
          _topBar(ble),
          const SizedBox(height: 12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _mode == DataMode.terminal ? _terminal(ble) : _wave(ble),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar(BleController ble) {
    return Panel(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      radius: 16,
      child: Row(
        children: [
          _ModeSwitch(
            mode: _mode,
            onChanged: (mode) => setState(() => _mode = mode),
          ),
          const Spacer(),
          _metric('TX', '${ble.txCount} B', AppColors.violet),
          const SizedBox(width: 10),
          _metric('RX', '${ble.rxCount} B', AppColors.sky),
          const SizedBox(width: 10),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: ble.connected ? AppColors.accent : AppColors.stroke,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 8.5, color: AppColors.textDim, letterSpacing: .6),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- terminal

  Widget _terminal(BleController ble) {
    return Column(
      key: const ValueKey('terminal'),
      children: [
        Expanded(child: _logPanel(ble)),
        const SizedBox(height: 10),
        _composer(ble),
      ],
    );
  }

  Widget _logPanel(BleController ble) {
    final logs = ble.logs;
    final rx = ble.rx;
    final canNotify = rx != null && (rx.properties.notify || rx.properties.indicate);
    final notifying = rx != null && ble.notifyOn(rx);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.bgAlt,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(
              children: [
                if (canNotify)
                  IconButton(
                    tooltip: notifying ? '关闭通知' : '开启通知',
                    onPressed: () => ble.toggleNotify(rx),
                    icon: Icon(
                      notifying
                          ? Icons.notifications_active_rounded
                          : Icons.notifications_off_rounded,
                      size: 18,
                      color: notifying ? AppColors.accent : AppColors.textDim,
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: '复制全部',
                  onPressed: logs.isEmpty
                      ? null
                      : () => Clipboard.setData(ClipboardData(text: ble.logText)),
                  icon: const Icon(Icons.copy_rounded, size: 17),
                ),
                IconButton(
                  tooltip: '清空',
                  onPressed: logs.isEmpty ? null : ble.clearLogs,
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: logs.isEmpty
                ? const Center(
                    child: Text(
                      '暂无数据，收发内容会显示在这里',
                      style: TextStyle(fontSize: 11.5, color: AppColors.textDim),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: logs.length,
                      itemBuilder: (context, index) => _logLine(logs[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _logLine(LogEntry entry) {
    final color = switch (entry.kind) {
      LogKind.tx => AppColors.accent,
      LogKind.rx => AppColors.sky,
      LogKind.error => AppColors.danger,
      LogKind.system => AppColors.text,
      LogKind.info => AppColors.textDim,
    };
    final tag = switch (entry.kind) {
      LogKind.tx => 'TX',
      LogKind.rx => 'RX',
      LogKind.error => 'ERR',
      LogKind.system => 'SYS',
      LogKind.info => 'INF',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 54,
            child: Text(
              entry.stamp,
              style: TextStyle(
                fontSize: 9.5,
                height: 1.6,
                fontFamily: 'monospace',
                color: AppColors.textDim.withValues(alpha: .55),
              ),
            ),
          ),
          SizedBox(
            width: 26,
            child: Text(
              tag,
              style: TextStyle(
                fontSize: 9.5,
                height: 1.6,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                color: color,
              ),
            ),
          ),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                fontFamily: 'monospace',
                color: color.withValues(alpha: .92),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer(BleController ble) {
    final enabled = ble.connected && ble.tx != null;
    return Panel(
      padding: const EdgeInsets.all(10),
      margin: EdgeInsets.zero,
      radius: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: ble.hexSend ? '例如 AA 01 0F' : '输入要发送的内容',
                contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _tinyToggle('HEX', ble.hexSend, ble.setHexSend),
          const SizedBox(width: 8),
          _sendButton(enabled),
        ],
      ),
    );
  }

  Widget _tinyToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 46,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: value ? AppColors.accent.withValues(alpha: .14) : AppColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: value ? AppColors.accent.withValues(alpha: .45) : AppColors.stroke,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: .5,
            color: value ? AppColors.accent : AppColors.textDim,
          ),
        ),
      ),
    );
  }

  Widget _sendButton(bool enabled) {
    return Opacity(
      opacity: enabled || _sending ? 1 : .45,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.accent, AppColors.accentDeep],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withValues(alpha: enabled ? .28 : 0),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: enabled ? _send : null,
            child: SizedBox(
              width: 52,
              height: 48,
              child: _sending
                  ? const Padding(
                      padding: EdgeInsets.all(15),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.onAccent,
                      ),
                    )
                  : const Icon(Icons.send_rounded, color: AppColors.onAccent, size: 20),
            ),
          ),
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- wave

  Widget _wave(BleController ble) {
    final frames = _paused ? (_frozen ?? const <List<double>>[]) : ble.waveFrames;
    final channels = ble.waveChannelCount;
    final visible = <int>{
      for (var i = 0; i < channels; i++)
        if (!_hidden.contains(i)) i,
    };

    return Column(
      key: const ValueKey('wave'),
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.bgAlt,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.stroke),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onScaleStart: (_) {
                      _baseViewFrames = _viewFrames;
                      _baseZoomY = _zoomY;
                    },
                    onScaleUpdate: (details) {
                      setState(() {
                        // 双指：同时缩放时间窗与幅值；单指：只上下平移。
                        if (details.pointerCount >= 2) {
                          final scale = details.scale.clamp(.5, 4.0);
                          _viewFrames = (_baseViewFrames / scale)
                              .clamp(_minFrames, _maxFrames);
                          _zoomY = (_baseZoomY * scale).clamp(.2, 20.0);
                        }
                        _offsetY = (_offsetY + details.focalPointDelta.dy / 240)
                            .clamp(-8.0, 8.0);
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                      child: CustomPaint(
                        painter: WaveChartPainter(
                          frames: frames,
                          channelCount: channels,
                          visible: visible,
                          viewFrames: _viewFrames,
                          zoomY: _zoomY,
                          offsetY: _offsetY,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  top: 6,
                  child: Text(
                    frames.isEmpty
                        ? 'JUSTFLOAT'
                        : '${frames.length} 帧 · $channels CH'
                            '${_fitted ? '' : ' · ${_viewFrames.round()}F ×${_zoomY.toStringAsFixed(1)}'}'
                            '${_paused ? ' · 已暂停' : ''}',
                    style: const TextStyle(
                      fontSize: 9.5,
                      letterSpacing: .8,
                      fontFamily: 'monospace',
                      color: AppColors.textDim,
                    ),
                  ),
                ),
                Positioned(
                  right: 4,
                  top: 0,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '自适应',
                        onPressed: _fitted ? null : _fitView,
                        icon: Icon(
                          Icons.center_focus_strong_rounded,
                          size: 18,
                          color: _fitted
                              ? AppColors.textDim.withValues(alpha: .4)
                              : AppColors.accent,
                        ),
                      ),
                      IconButton(
                        tooltip: '选择通道',
                        onPressed:
                            channels == 0 ? null : () => _showChannelPicker(channels),
                        icon: const Icon(Icons.checklist_rounded, size: 18),
                      ),
                      IconButton(
                        tooltip: _paused ? '继续' : '暂停',
                        onPressed: _togglePause,
                        icon: Icon(
                          _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                          size: 18,
                          color: _paused ? AppColors.warn : AppColors.textDim,
                        ),
                      ),
                      IconButton(
                        tooltip: '清空波形',
                        onPressed: () {
                          setState(() {
                            _paused = false;
                            _frozen = null;
                          });
                          ble.clearWave();
                        },
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
                if (frames.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 26),
                      child: Text(
                        '等待 JustFloat 数据\nVOFA+ 协议：N 个小端 float32 + 00 00 80 7F',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.7,
                          color: AppColors.textDim,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        _legend(frames, channels),
      ],
    );
  }

  /// 通道勾选面板：点右上角「选择通道」或长按图例打开，等价于 VOFA+ 的右键菜单。
  Future<void> _showChannelPicker(int channels) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            void toggle(int index) {
              setState(() {
                if (!_hidden.remove(index)) _hidden.add(index);
              });
              setSheetState(() {});
            }

            final shown = channels - _hidden.length;
            return Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: AppColors.stroke),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '选择通道',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                      const Spacer(),
                      Text(
                        '已选 $shown / $channels',
                        style: const TextStyle(fontSize: 11, color: AppColors.textDim),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '勾选要画的变量；长按下方图例也能打开这里',
                    style: TextStyle(fontSize: 10.5, color: AppColors.textDim),
                  ),
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (var i = 0; i < channels; i++)
                            CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              controlAffinity: ListTileControlAffinity.leading,
                              activeColor: channelColor(i),
                              value: !_hidden.contains(i),
                              onChanged: (_) => toggle(i),
                              title: Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: channelColor(i),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'CH${i + 1}',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      fontFamily: 'monospace',
                                      color: _hidden.contains(i)
                                          ? AppColors.textDim
                                          : AppColors.text,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() => _hidden.clear());
                          setSheetState(() {});
                        },
                        child: const Text('全选'),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _hidden
                              ..clear()
                              ..addAll(List<int>.generate(channels, (i) => i));
                          });
                          setSheetState(() {});
                        },
                        child: const Text('全不选'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _legend(List<List<double>> frames, int channels) {
    if (channels == 0) {
      return Panel(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        radius: 16,
        child: Row(
          children: const [
            Icon(Icons.insights_rounded, size: 15, color: AppColors.textDim),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '收到 JustFloat 帧后会自动生成浮点波形',
                style: TextStyle(fontSize: 11, color: AppColors.textDim),
              ),
            ),
          ],
        ),
      );
    }

    final last = frames.isEmpty ? null : frames.last;
    return GestureDetector(
      // 长按整条图例 = 打开通道勾选面板。
      onLongPress: () => _showChannelPicker(channels),
      child: Panel(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        radius: 16,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < channels; i++)
              _channelChip(
                index: i,
                value: (last != null && i < last.length) ? last[i] : null,
                hidden: _hidden.contains(i),
              ),
          ],
        ),
      ),
    );
  }

  Widget _channelChip({required int index, double? value, required bool hidden}) {
    final color = channelColor(index);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() {
        if (!_hidden.remove(index)) _hidden.add(index);
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: hidden ? AppColors.surfaceAlt : color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: hidden ? AppColors.stroke : color.withValues(alpha: .4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: hidden ? AppColors.textDim : color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'CH${index + 1}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: hidden ? AppColors.textDim : color,
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 6),
              Text(
                value.toStringAsFixed(2),
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: hidden ? AppColors.textDim : AppColors.text,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final DataMode mode;
  final ValueChanged<DataMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment('终端', Icons.terminal_rounded, DataMode.terminal),
          _segment('波形', Icons.show_chart_rounded, DataMode.wave),
        ],
      ),
    );
  }

  Widget _segment(String label, IconData icon, DataMode value) {
    final selected = mode == value;
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: .16) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: selected ? AppColors.accent : AppColors.textDim,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: selected ? AppColors.accent : AppColors.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
