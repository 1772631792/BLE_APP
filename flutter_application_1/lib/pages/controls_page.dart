import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ble_controller.dart';
import '../control_packet.dart';
import '../theme.dart';
import '../widgets.dart';

/// 控件页：摇杆 / 滑条 / 按键，支持「独立指令」与「整包」两种发送方式。
class ControlsPage extends StatefulWidget {
  const ControlsPage({super.key, required this.ble});

  final BleController ble;

  @override
  State<ControlsPage> createState() => _ControlsPageState();
}

class _ControlsPageState extends State<ControlsPage> {
  Future<void> _openFullscreen() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (routeContext) => Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(14),
              // 全屏页是独立路由，不在主页面 rebuild 范围内，需要自己监听控制器。
              child: AnimatedBuilder(
                animation: widget.ble,
                builder: (boardContext, _) => ControlBoard(
                  ble: widget.ble,
                  fullscreen: true,
                  onExit: () => Navigator.of(routeContext).maybePop(),
                  onOpenSettings: () => showModalBottomSheet<void>(
                    context: routeContext,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => ControlSettingsSheet(ble: widget.ble),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ControlSettingsSheet(ble: widget.ble),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
      child: Column(
        children: [
          Panel(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            radius: 16,
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.violet.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.sports_esports_rounded,
                    size: 18,
                    color: AppColors.violet,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '控件面板',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        !ble.connected
                            ? '连接设备后可发送指令'
                            : ble.tx == null
                                ? '未选择 TX 通道，请在设备页指定'
                                : '长按控件可改指令 · 横屏全屏更顺手',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: AppColors.textDim),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '控件设置',
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_rounded, size: 19),
                ),
                TextButton(
                  onPressed: _openFullscreen,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.fullscreen_rounded, size: 18),
                      SizedBox(width: 3),
                      Text('全屏', style: TextStyle(fontSize: 11.5)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ControlBoard(ble: ble, onOpenSettings: _openSettings),
          ),
        ],
      ),
    );
  }
}

/// 控件面板本体，页面内与全屏共用。
class ControlBoard extends StatefulWidget {
  const ControlBoard({
    super.key,
    required this.ble,
    this.fullscreen = false,
    this.onExit,
    this.onOpenSettings,
  });

  final BleController ble;
  final bool fullscreen;
  final VoidCallback? onExit;
  final VoidCallback? onOpenSettings;

  @override
  State<ControlBoard> createState() => _ControlBoardState();
}

class _ControlBoardState extends State<ControlBoard> {
  static const double _toolbarHeight = 38;

  DateTime _lastJoystick = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSlider = DateTime.fromMillisecondsSinceEpoch(0);

  void _sendCommand(String key, {Map<String, String>? vars}) {
    final ble = widget.ble;
    if (!ble.connected) return;
    final command = ble.command(key);
    if (command.payload.trim().isEmpty) return;

    if (command.hex) {
      _sendHexCommand(command.payload, vars);
      return;
    }
    var payload = command.payload;
    vars?.forEach((name, value) {
      payload = payload.replaceAll('{$name}', value);
    });
    if (payload.trim().isEmpty) return;
    ble.send(payload, hex: false);
  }

  /// HEX 指令：占位符按单字节写入，摇杆 -100~100 映射成 0~200。
  void _sendHexCommand(String template, Map<String, String>? vars) {
    final ble = widget.ble;
    if (!template.contains('{')) {
      ble.send(template, hex: true);
      return;
    }
    final values = <String, int>{};
    vars?.forEach((name, value) {
      final raw = int.tryParse(value) ?? 0;
      values[name] = name == 'x' || name == 'y' ? raw + 100 : raw;
    });
    try {
      ble.sendBytes(buildHexPacket(template, values));
    } on PacketBuildException {
      // 模板不合法时退回原始 HEX 发送，让控制器统一提示错误。
      ble.send(template, hex: true);
    }
  }

  void _onJoystick(double x, double y) {
    final now = DateTime.now();
    if (now.difference(_lastJoystick).inMilliseconds < 60) return;
    _lastJoystick = now;
    widget.ble.updateControls(joyX: x, joyY: y);
    if (widget.ble.controlMode != ControlSendMode.single) return;
    _sendCommand('joystick', vars: {
      'x': '${(x * 100).round()}',
      'y': '${(y * 100).round()}',
    });
  }

  void _onJoystickRelease() {
    widget.ble.updateControls(joyX: 0, joyY: 0);
    if (widget.ble.controlMode == ControlSendMode.single) {
      _sendCommand('stop');
    } else {
      widget.ble.sendPacketNow();
    }
  }

  void _onSlider(String key, double value, {bool force = false}) {
    if (key == 'slider1') {
      widget.ble.updateControls(sliderA: value);
    } else {
      widget.ble.updateControls(sliderB: value);
    }
    final now = DateTime.now();
    if (!force && now.difference(_lastSlider).inMilliseconds < 80) return;
    _lastSlider = now;
    if (widget.ble.controlMode == ControlSendMode.single) {
      _sendCommand(key, vars: {'v': '${value.round()}'});
    } else if (force) {
      widget.ble.sendPacketNow();
    }
  }

  void _onButtonPressed(String key, bool pressed) {
    final next = {...widget.ble.pressedKeys};
    if (pressed) {
      next.add(key);
    } else {
      next.remove(key);
    }
    widget.ble.updateControls(pressed: next);
    if (widget.ble.controlMode == ControlSendMode.single) {
      if (pressed) _sendCommand(key);
    } else {
      widget.ble.sendPacketNow();
    }
  }

  /// 停止：摇杆回中 + 清空按键状态，再发一次。
  void _stopAll() {
    widget.ble.updateControls(joyX: 0, joyY: 0, pressed: {});
    if (widget.ble.controlMode == ControlSendMode.single) {
      _sendCommand('stop');
    } else {
      widget.ble.sendPacketNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
    return Opacity(
      opacity: ble.connected ? 1 : .6,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 宽屏走「手柄布局」：左手摇杆 + 右手弧形技能键，拇指活动半径最短。
          final wide = constraints.maxWidth > constraints.maxHeight * 1.2;
          return wide ? _wideLayout(constraints) : _tallLayout();
        },
      ),
    );
  }

  // ------------------------------------------------------------- 手柄布局

  Widget _wideLayout(BoxConstraints c) {
    final ble = widget.ble;
    final body = math.max(120.0, c.maxHeight - _toolbarHeight - 6);
    // 摇杆 / 按键都按拇指可覆盖的半径定尺寸，不让手指伸到屏幕中间。
    final joy = math.min(c.maxWidth * .28, body * .78).clamp(96.0, 300.0);
    final sliderWidth = math.min(c.maxWidth * .34, 300.0);
    return Column(
      children: [
        SizedBox(height: _toolbarHeight, child: _toolbar()),
        const SizedBox(height: 6),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: joy + 10,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.bottomCenter,
                        child: SizedBox(
                          width: sliderWidth,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _compactSlider('slider1', 'A', ble.sliderA),
                              const SizedBox(height: 4),
                              _compactSlider('slider2', 'B', ble.sliderB),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(width: joy, height: joy, child: _joystick()),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Expanded(child: _arcPadFit()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tallLayout() {
    final ble = widget.ble;
    return Column(
      children: [
        SizedBox(height: _toolbarHeight, child: _toolbar()),
        const SizedBox(height: 10),
        Expanded(
          child: Row(
            children: [
              Expanded(flex: 5, child: _joystick()),
              const SizedBox(width: 12),
              Expanded(flex: 6, child: _arcPadFit()),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _sliderCard('slider1', 'A', ble.sliderA)),
            const SizedBox(width: 10),
            Expanded(child: _sliderCard('slider2', 'B', ble.sliderB)),
          ],
        ),
      ],
    );
  }

  Widget _toolbar() {
    final ble = widget.ble;
    return Row(
      children: [
        if (widget.fullscreen && widget.onExit != null) ...[
          _exitPill(),
          const SizedBox(width: 8),
        ],
        _ModeSwitch(
          mode: ble.controlMode,
          onChanged: ble.setControlMode,
        ),
        if (ble.controlMode == ControlSendMode.packet) ...[
          const SizedBox(width: 6),
          Text(
            '${ble.packetIntervalMs}ms',
            style: const TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: AppColors.textDim,
            ),
          ),
        ],
        const SizedBox(width: 10),
        Expanded(child: _feedback()),
        const SizedBox(width: 6),
        _stopIcon(),
        if (widget.fullscreen && widget.onOpenSettings != null)
          IconButton(
            onPressed: widget.onOpenSettings,
            tooltip: '控件设置',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.tune_rounded, size: 18),
          ),
      ],
    );
  }

  Widget _exitPill() {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: widget.onExit,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt.withValues(alpha: .9),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.stroke),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.close_fullscreen_rounded, size: 13, color: AppColors.text),
            SizedBox(width: 5),
            Text('退出全屏', style: TextStyle(fontSize: 10.5, color: AppColors.text)),
          ],
        ),
      ),
    );
  }

  /// 发送反馈：一眼看出到底发出去了什么。
  Widget _feedback() {
    final ble = widget.ble;
    final last = ble.lastSentPreview;
    final Color color;
    final String text;
    if (!ble.connected) {
      color = AppColors.textDim;
      text = '未连接';
    } else if (ble.tx == null) {
      color = AppColors.warn;
      text = '未选择 TX';
    } else if (last == null) {
      color = AppColors.textDim;
      text = '等待发送';
    } else {
      color = AppColors.accent;
      text = 'TX $last';
    }
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: color.withValues(alpha: .3)),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 9.5,
            fontFamily: 'monospace',
            color: color,
          ),
        ),
      ),
    );
  }

  Widget _stopIcon() {
    final enabled = widget.ble.connected;
    return Tooltip(
      message: '停止',
      child: Material(
        color: AppColors.danger.withValues(alpha: enabled ? .16 : .06),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? _stopAll : null,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(
              Icons.stop_rounded,
              size: 18,
              color: enabled ? AppColors.danger : AppColors.textDim,
            ),
          ),
        ),
      ),
    );
  }

  Widget _joystick() {
    return Stack(
      children: [
        Positioned.fill(
          child: VirtualJoystick(
            onChanged: _onJoystick,
            onRelease: _onJoystickRelease,
          ),
        ),
        // 顶部小标签：不占摇杆拖动区，长按可改指令。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: () =>
                  showCommandEditor(context, widget.ble, 'joystick'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.bg.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.ble.command('joystick').label,
                  style: const TextStyle(fontSize: 9.5, color: AppColors.textDim),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 把按键簇放进可用区域，取正方形边长，右下角对齐（拇指落点）。
  Widget _arcPadFit() {
    return LayoutBuilder(
      builder: (context, inner) {
        final size = math.min(inner.maxWidth, inner.maxHeight);
        if (!size.isFinite || size <= 0) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.bottomRight,
          child: SizedBox(
            width: size,
            height: size,
            child: _arcPad(size),
          ),
        );
      },
    );
  }

  /// 王者式弧形键位：主键落在右下角，其余沿弧线向内上方铺开。
  Widget _arcPad(double size) {
    final children = <Widget>[];
    for (final spec in _padSpecs) {
      final angle = spec.angle * math.pi / 180;
      final cx = .5 + spec.distance * math.cos(angle);
      final cy = .5 + spec.distance * math.sin(angle);
      final diameter = spec.radius * 2 * size;
      children.add(
        Positioned(
          left: (cx - spec.radius) * size,
          top: (cy - spec.radius) * size,
          width: diameter,
          height: diameter,
          child: _padButton(spec),
        ),
      );
    }
    return Stack(children: children);
  }

  Widget _padButton(_PadSpec spec) {
    final command = widget.ble.command(spec.key);
    return PadButton(
      label: command.label,
      icon: spec.icon,
      primary: spec.primary,
      enabled: widget.ble.connected,
      onDown: () => _onButtonPressed(spec.key, true),
      onUp: () => _onButtonPressed(spec.key, false),
      onLongPress: () => showCommandEditor(context, widget.ble, spec.key),
    );
  }

  Widget _sliderCard(String key, String tag, double value) {
    final command = widget.ble.command(key);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: .85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: () => showCommandEditor(context, widget.ble, key),
            child: Row(
              children: [
                MiniTag(label: tag, color: AppColors.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    command.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: AppColors.textDim),
                  ),
                ),
                Text(
                  '${value.round()}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: AppColors.stroke,
              thumbColor: AppColors.accent,
              overlayColor: AppColors.accent.withValues(alpha: .15),
            ),
            child: Slider(
              value: value,
              max: 100,
              onChanged: (v) => _onSlider(key, v),
              // 松手时补发最后一帧，避免节流把终值丢掉。
              onChangeEnd: (v) => _onSlider(key, v, force: true),
            ),
          ),
        ],
      ),
    );
  }

  /// 横屏紧凑滑条：一行搞定，给摇杆和按键让出垂直空间。
  Widget _compactSlider(String key, String tag, double value) {
    return Container(
      height: 42,
      padding: const EdgeInsets.only(left: 8, right: 4),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: .8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => showCommandEditor(context, widget.ble, key),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                tag,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: AppColors.accent,
                ),
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: AppColors.accent,
                inactiveTrackColor: AppColors.stroke,
                thumbColor: AppColors.accent,
                overlayColor: AppColors.accent.withValues(alpha: .16),
              ),
              child: Slider(
                value: value,
                max: 100,
                onChanged: (v) => _onSlider(key, v),
                onChangeEnd: (v) => _onSlider(key, v, force: true),
              ),
            ),
          ),
          SizedBox(
            width: 24,
            child: Text(
              '${value.round()}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 10.5,
                fontFamily: 'monospace',
                color: AppColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 弧形键位参数：角度以 3 点钟方向为 0、顺时针为正；
/// distance 为相对簇边长的极半径，radius 为按键半径占簇边长的比例。
class _PadSpec {
  const _PadSpec(
    this.key,
    this.angle,
    this.distance,
    this.radius, {
    required this.icon,
    this.primary = false,
  });

  final String key;
  final double angle;
  final double distance;
  final double radius;
  final IconData icon;
  final bool primary;
}

/// 参照王者右手技能区：主键压在右下角，其余键沿弧线向左上展开，
/// 每颗键都落在拇指自然扫过的范围内，不用伸到屏幕中央。
const List<_PadSpec> _padSpecs = [
  _PadSpec('k1', 52, .335, .158, icon: Icons.bolt_rounded, primary: true),
  _PadSpec('k2', 100, .360, .118, icon: Icons.campaign_rounded),
  _PadSpec('k3', 145, .370, .115, icon: Icons.lightbulb_rounded),
  _PadSpec('k4', 188, .340, .104, icon: Icons.tune_rounded),
];

/// 圆形技能键：按下缩小 + 发光 + 描边提亮 + 触感，松开带一点回弹。
class PadButton extends StatefulWidget {
  const PadButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onDown,
    required this.onUp,
    required this.onLongPress,
    this.primary = false,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onDown;
  final VoidCallback onUp;
  final VoidCallback onLongPress;
  final bool primary;
  final bool enabled;

  @override
  State<PadButton> createState() => _PadButtonState();
}

class _PadButtonState extends State<PadButton> {
  bool _down = false;
  Timer? _longPressTimer;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _press() {
    if (!widget.enabled) return;
    HapticFeedback.lightImpact();
    setState(() => _down = true);
    widget.onDown();
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      _longPressTimer = null;
      HapticFeedback.mediumImpact();
      // 先松开再进编辑，避免按键状态卡在按下。
      setState(() => _down = false);
      widget.onUp();
      widget.onLongPress();
    });
  }

  void _release() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    if (!_down) return;
    setState(() => _down = false);
    widget.onUp();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _press(),
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final diameter = math.min(constraints.maxWidth, constraints.maxHeight);
          final down = _down;
          final tint = widget.primary ? AppColors.accent : AppColors.sky;
          final iconColor = widget.primary
              ? (down ? Colors.white : AppColors.onAccent)
              : (down ? Colors.white : tint);
          final labelColor = widget.primary
              ? (down ? Colors.white : AppColors.onAccent)
              : (down ? Colors.white : AppColors.text.withValues(alpha: .9));

          return AnimatedScale(
            scale: down ? .9 : 1,
            duration: Duration(milliseconds: down ? 70 : 170),
            curve: down ? Curves.easeOut : Curves.easeOutBack,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: widget.primary
                      ? (down
                          ? [const Color(0xFF9CFFEA), AppColors.accent]
                          : [AppColors.accent, AppColors.accentDeep])
                      : (down
                          ? [tint.withValues(alpha: .45), AppColors.surfaceAlt]
                          : [
                              AppColors.surfaceAlt,
                              AppColors.surface.withValues(alpha: .95),
                            ]),
                ),
                border: Border.all(
                  color: down
                      ? Colors.white.withValues(alpha: widget.primary ? .8 : .45)
                      : (widget.primary ? AppColors.accentDeep : AppColors.stroke),
                  width: down ? 2 : 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: (widget.primary ? AppColors.accent : tint)
                        .withValues(alpha: down ? .55 : .15),
                    blurRadius: down ? 26 : 12,
                    spreadRadius: down ? 3 : 0,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: diameter * .30, color: iconColor),
                    if (diameter >= 56) ...[
                      const SizedBox(height: 2),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: diameter * .14),
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: (diameter * .145).clamp(8.0, 13.0),
                            height: 1.15,
                            fontWeight: FontWeight.w700,
                            color: labelColor,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final ControlSendMode mode;
  final ValueChanged<ControlSendMode> onChanged;

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
          _segment('独立', Icons.bolt_rounded, ControlSendMode.single),
          _segment('整包', Icons.inventory_2_rounded, ControlSendMode.packet),
        ],
      ),
    );
  }

  Widget _segment(String label, IconData icon, ControlSendMode value) {
    final selected = mode == value;
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: .16) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: selected ? AppColors.accent : AppColors.textDim),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
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

/// 控件设置：发送模式、整包模板、逐条指令。
class ControlSettingsSheet extends StatefulWidget {
  const ControlSettingsSheet({super.key, required this.ble});

  final BleController ble;

  @override
  State<ControlSettingsSheet> createState() => _ControlSettingsSheetState();
}

class _ControlSettingsSheetState extends State<ControlSettingsSheet> {
  late final TextEditingController _template =
      TextEditingController(text: widget.ble.packetTemplate);

  static const List<String> _commandKeys = [
    'up',
    'down',
    'left',
    'right',
    'stop',
    'k1',
    'k2',
    'k3',
    'k4',
    'slider1',
    'slider2',
    'joystick',
  ];

  @override
  void dispose() {
    _template.dispose();
    super.dispose();
  }

  void _insertToken(String token) {
    final text = _template.text;
    final selection = _template.selection;
    final insertAt = selection.isValid ? selection.start : text.length;
    final next = '${text.substring(0, insertAt)}{$token}${text.substring(insertAt)}';
    _template.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: insertAt + token.length + 2),
    );
    widget.ble.setPacketTemplate(next);
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 10,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: AppColors.stroke,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              '控件设置',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            const _SheetLabel('发送模式'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _modeCard(
                    selected: ble.controlMode == ControlSendMode.single,
                    title: '独立指令',
                    desc: '每个按键 / 滑条各发一包，适合简单协议',
                    icon: Icons.bolt_rounded,
                    onTap: () {
                      ble.setControlMode(ControlSendMode.single);
                      setState(() {});
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _modeCard(
                    selected: ble.controlMode == ControlSendMode.packet,
                    title: '整包发送',
                    desc: '摇杆 / 滑条 / 按键合成一个固定结构包',
                    icon: Icons.inventory_2_rounded,
                    onTap: () {
                      ble.setControlMode(ControlSendMode.packet);
                      setState(() {});
                    },
                  ),
                ),
              ],
            ),
            if (ble.controlMode == ControlSendMode.packet) ...[
              const SizedBox(height: 16),
              const _SheetLabel('发送周期'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final ms in [20, 50, 100, 200])
                    ChoiceChip(
                      label: Text('$ms ms'),
                      selected: ble.packetIntervalMs == ms,
                      onSelected: (_) {
                        ble.setPacketIntervalMs(ms);
                        setState(() {});
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(child: _SheetLabel('数据包模板')),
                  TogglePill(
                    label: 'HEX',
                    value: ble.packetHex,
                    onChanged: (value) {
                      ble.setPacketHex(value);
                      setState(() {});
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _template,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                decoration: InputDecoration(
                  hintText: ble.packetHex
                      ? '例如 AA 55 {x} {y} {btn} 55 AA'
                      : '例如 X{x} Y{y} B{btn}',
                ),
                onChanged: ble.setPacketTemplate,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final token in packetTokens)
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => setState(() => _insertToken(token)),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.stroke),
                        ),
                        child: Text(
                          '{$token}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                ble.packetHex
                    ? '{x}/{y}：-100~100 映射为 0~200；{s1}/{s2}：0~100；{btn}：按键位图；{k1}~{k4}：0/1'
                    : '{x}/{y}：-100~100；{s1}/{s2}：0~100；{btn}：按键位图；{k1}~{k4}：0/1',
                style: const TextStyle(fontSize: 10.5, height: 1.6, color: AppColors.textDim),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                const _SheetLabel('控件指令'),
                const Spacer(),
                const Text(
                  '长按控件也能直接改',
                  style: TextStyle(fontSize: 10, color: AppColors.textDim),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final key in _commandKeys)
              Builder(
                builder: (context) {
                  final command = ble.command(key);
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      command.label,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      command.payload.isEmpty
                          ? '（空）'
                          : '${command.hex ? 'HEX · ' : ''}${command.payload}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: AppColors.textDim,
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: '编辑',
                      icon: const Icon(Icons.edit_rounded, size: 17),
                      onPressed: () async {
                        await showCommandEditor(context, ble, key);
                        if (mounted) setState(() {});
                      },
                    ),
                  );
                },
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: GradientButton(
                label: '完成',
                icon: Icons.check_rounded,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeCard({
    required bool selected,
    required String title,
    required String desc,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: .12)
              : AppColors.surfaceAlt.withValues(alpha: .6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.accent.withValues(alpha: .5) : AppColors.stroke,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected ? AppColors.accent : AppColors.textDim,
            ),
            const SizedBox(height: 7),
            Text(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: selected ? AppColors.accent : AppColors.text,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              desc,
              style: const TextStyle(fontSize: 10, height: 1.5, color: AppColors.textDim),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetLabel extends StatelessWidget {
  const _SheetLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: AppColors.textDim,
        letterSpacing: .4,
      ),
    );
  }
}

/// 指令编辑弹窗（独立模式发给设备的原始数据）。
Future<void> showCommandEditor(
  BuildContext context,
  BleController ble,
  String key,
) async {
  final command = ble.command(key);
  final labelController = TextEditingController(text: command.label);
  final payloadController = TextEditingController(text: command.payload);
  var hex = command.hex;

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('编辑指令', style: TextStyle(fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: labelController,
                decoration: const InputDecoration(hintText: '按钮名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: payloadController,
                minLines: 1,
                maxLines: 3,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                decoration: InputDecoration(
                  hintText: key == 'joystick'
                      ? '例如 AA 55 {x} {y} 55 AA'
                      : key.startsWith('slider')
                          ? '例如 AA 55 {v} 55 AA'
                          : '例如 AA 01 01',
                ),
              ),
              const SizedBox(height: 4),
              SwitchListTile.adaptive(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('按 HEX 发送', style: TextStyle(fontSize: 12.5)),
                value: hex,
                onChanged: (value) => setDialogState(() => hex = value),
              ),
              Text(
                key == 'joystick'
                    ? '可用变量：{x} {y}（-100 ~ 100，HEX 时自动 +100）'
                    : key.startsWith('slider')
                        ? '可用变量：{v}（0 ~ 100）'
                        : '内容原样发送；HEX 模式支持 AA 55 这种写法',
                style: const TextStyle(fontSize: 10.5, color: AppColors.textDim),
              ),
              if (hex)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '提示：本例中 {x}/{y} 会转成单字节 0~200',
                    style: TextStyle(fontSize: 10.5, color: AppColors.textDim),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );

  if (saved == true) {
    ble.updateCommand(
      key,
      ControlCommand(
        label: labelController.text.trim().isEmpty
            ? command.label
            : labelController.text.trim(),
        payload: payloadController.text.trim(),
        hex: hex,
      ),
    );
  }
  labelController.dispose();
  payloadController.dispose();
}

/// 虚拟摇杆，输出 -1 ~ 1 的归一化坐标（向上为 +Y）。
///
/// 用 Listener 直接读取指针事件：不和其它手势竞争，且只跟随第一根手指，
/// 另一只手按按键时不会打断摇杆。
class VirtualJoystick extends StatefulWidget {
  const VirtualJoystick({
    super.key,
    required this.onChanged,
    required this.onRelease,
  });

  final void Function(double x, double y) onChanged;
  final VoidCallback onRelease;

  @override
  State<VirtualJoystick> createState() => _VirtualJoystickState();
}

class _VirtualJoystickState extends State<VirtualJoystick>
    with SingleTickerProviderStateMixin {
  Offset _value = Offset.zero;
  Offset _from = Offset.zero;
  int? _activePointer;

  /// 松手回中：弹簧式回弹比瞬间归零更像实体摇杆。
  late final AnimationController _spring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 190),
  )..addListener(_onSpring);

  bool get _active => _activePointer != null || _value != Offset.zero;

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _onSpring() {
    final t = Curves.easeOutCubic.transform(_spring.value);
    setState(() => _value = Offset.lerp(_from, Offset.zero, t) ?? Offset.zero);
  }

  void _update(Offset local, double size) {
    final radius = size / 2;
    final center = Offset(radius, radius);
    var delta = local - center;
    final maxRadius = radius * .64;
    if (delta.distance > maxRadius) {
      delta = delta / delta.distance * maxRadius;
    }
    var nx = (delta.dx / maxRadius).clamp(-1.0, 1.0).toDouble();
    var ny = (-delta.dy / maxRadius).clamp(-1.0, 1.0).toDouble();
    // 拇指轻微抖动不产生指令，避免小车原地抽动。
    if (nx.abs() < .06) nx = 0;
    if (ny.abs() < .06) ny = 0;
    _spring.stop();
    setState(() => _value = Offset(nx, ny));
    widget.onChanged(nx, ny);
  }

  void _release() {
    _activePointer = null;
    if (_value == Offset.zero) {
      setState(() {});
      return;
    }
    _from = _value;
    _spring.forward(from: 0);
    widget.onRelease();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                // 只认第一根按在摇杆上的手指，多指时忽略后续指针。
                if (_activePointer != null) return;
                _activePointer = event.pointer;
                HapticFeedback.lightImpact();
                _update(event.localPosition, size);
              },
              onPointerMove: (event) {
                if (event.pointer != _activePointer) return;
                _update(event.localPosition, size);
              },
              onPointerUp: (event) {
                if (event.pointer != _activePointer) return;
                _release();
              },
              onPointerCancel: (event) {
                if (event.pointer != _activePointer) return;
                _release();
              },
              child: CustomPaint(
                painter: _JoystickPainter(value: _value, active: _active),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'X ${(_value.dx * 100).round()}   Y ${(_value.dy * 100).round()}',
                      style: TextStyle(
                        fontSize: 9,
                        fontFamily: 'monospace',
                        color: _active ? AppColors.accent : AppColors.textDim,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _JoystickPainter extends CustomPainter {
  _JoystickPainter({required this.value, required this.active});

  final Offset value;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    final maxRadius = radius * .64;

    // 拖动时外圈亮起，手指压上去就有反馈。
    if (active) {
      canvas.drawCircle(
        center,
        radius - 1,
        Paint()
          ..shader = RadialGradient(
            colors: [
              AppColors.accent.withValues(alpha: .16),
              AppColors.accent.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..shader = RadialGradient(
          colors: [
            AppColors.surfaceAlt,
            AppColors.bgAlt.withValues(alpha: .95),
          ],
          center: const Alignment(-.3, -.4),
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 1.8 : 1.2
        ..color = active ? AppColors.accent.withValues(alpha: .55) : AppColors.stroke,
    );
    canvas.drawCircle(
      center,
      maxRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = AppColors.stroke.withValues(alpha: .7),
    );

    final cross = Paint()
      ..color = AppColors.stroke.withValues(alpha: .5)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      cross,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      cross,
    );

    final knobCenter = center + Offset(value.dx, -value.dy) * maxRadius;
    final knobRadius = radius * .17;
    canvas.drawCircle(
      knobCenter,
      knobRadius + 7,
      Paint()..color = AppColors.accent.withValues(alpha: .14),
    );
    canvas.drawCircle(
      knobCenter,
      knobRadius,
      Paint()
        ..shader = const LinearGradient(
          colors: [AppColors.accent, AppColors.accentDeep],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(Rect.fromCircle(center: knobCenter, radius: knobRadius)),
    );
    canvas.drawCircle(
      knobCenter,
      knobRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: .25),
    );
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.active != active;
}
