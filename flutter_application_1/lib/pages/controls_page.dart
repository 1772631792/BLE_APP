import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ble_controller.dart';
import '../control_packet.dart';
import '../theme.dart';
import '../widgets.dart';

/// 控件页：摇杆 / 空白处搓动 / 按键，支持「独立指令」与「整包」两种发送方式。
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
                                : '长按按钮可持续触发 · 横屏全屏更顺手',
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

  /// 搓到 ±100 需要的位移占空白区域尺寸的比例。
  static const double _scrubTravel = .35;

  DateTime _lastJoystick = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastScrub = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastScrubX = 1 << 30;
  int _lastScrubY = 1 << 30;

  /// 正在搓的手指、起点与当前位置（只用于画分解轨迹）。
  int? _scrubPointer;
  Offset? _scrubStart;
  Offset? _scrubNow;

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

  /// HEX 指令：占位符按单字节写入，摇杆 -128~127 映射成 0~255。
  void _sendHexCommand(String template, Map<String, String>? vars) {
    final ble = widget.ble;
    if (!template.contains('{')) {
      ble.send(template, hex: true);
      return;
    }
    final values = <String, int>{};
    vars?.forEach((name, value) {
      final raw = int.tryParse(value) ?? 0;
      values[name] =
          name == 'x' || name == 'y' ? (raw + 128).clamp(0, 255) : raw;
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
      'x': '${(x * 127).round()}',
      'y': '${(y * 127).round()}',
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

  /// 空白处搓动：把位移分解成 X / Y 两个轴，没搓时就是 0 / 0。
  void _onScrub(double x, double y, {bool force = false}) {
    final ble = widget.ble;
    // 和摇杆一样铺满 int8：-128（反向到底）~ 127（正向到底）。
    final nx = x.clamp(-128.0, 127.0).toDouble();
    final ny = y.clamp(-128.0, 127.0).toDouble();
    final same = (ble.sliderA - nx).abs() < .01 && (ble.sliderB - ny).abs() < .01;
    if (same && !force) return;
    ble.updateControls(sliderA: nx, sliderB: ny);

    final now = DateTime.now();
    if (!force && now.difference(_lastScrub).inMilliseconds < 50) return;
    _lastScrub = now;
    _flushScrub(nx, ny, force: force);
  }

  void _flushScrub(double x, double y, {bool force = false}) {
    final ble = widget.ble;
    if (ble.controlMode != ControlSendMode.single) {
      ble.sendPacketNow();
      return;
    }
    // 独立模式：只发变化的那一轴，省一半无线写入。
    final rx = x.round();
    final ry = y.round();
    if (force || rx != _lastScrubX) {
      _lastScrubX = rx;
      _sendAxis('slider1', rx);
    }
    if (force || ry != _lastScrubY) {
      _lastScrubY = ry;
      _sendAxis('slider2', ry);
    }
  }

  /// 轴指令：文本模式发带符号值，HEX 模式发 +128 后的单字节。
  void _sendAxis(String key, int value) {
    final shifted = widget.ble.command(key).hex ? value + 128 : value;
    _sendCommand(key, vars: {'v': '$shifted'});
  }

  void _beginScrub(Offset local) {
    HapticFeedback.selectionClick();
    _lastScrubX = 1 << 30;
    _lastScrubY = 1 << 30;
    setState(() {
      _scrubStart = local;
      _scrubNow = local;
    });
    _onScrub(0, 0, force: true);
  }

  void _moveScrub(Offset local, Size size) {
    final start = _scrubStart;
    if (start == null) return;
    setState(() => _scrubNow = local);
    final delta = local - start;
    _onScrub(
      delta.dx / (size.width * _scrubTravel) * 128,
      -delta.dy / (size.height * _scrubTravel) * 128,
    );
  }

  void _endScrub() {
    if (_scrubPointer == null) return;
    _scrubPointer = null;
    _lastScrubX = 1 << 30;
    _lastScrubY = 1 << 30;
    setState(() {
      _scrubStart = null;
      _scrubNow = null;
    });
    _onScrub(0, 0, force: true);
  }

  /// 铺满空白的搓动层：不占布局、不画底，只在按下时显示一条分解轨迹。
  Widget _scrubLayer() {
    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            // 只认第一根手指，另一只手照常按按键。
            if (_scrubPointer != null) return;
            _scrubPointer = event.pointer;
            _beginScrub(event.localPosition);
          },
          onPointerMove: (event) {
            if (event.pointer != _scrubPointer) return;
            _moveScrub(event.localPosition, size);
          },
          onPointerUp: (event) {
            if (event.pointer != _scrubPointer) return;
            _endScrub();
          },
          onPointerCancel: (event) {
            if (event.pointer != _scrubPointer) return;
            _endScrub();
          },
          child: CustomPaint(
            painter: _ScrubTracePainter(start: _scrubStart, now: _scrubNow),
          ),
        );
      },
    );
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

  /// 停止：摇杆回中 + 搓动轴归零 + 清空按键状态，再发一次。
  void _stopAll() {
    _lastScrubX = 1 << 30;
    _lastScrubY = 1 << 30;
    widget.ble.updateControls(
      joyX: 0,
      joyY: 0,
      sliderA: 0,
      sliderB: 0,
      pressed: {},
    );
    if (widget.ble.controlMode == ControlSendMode.single) {
      _sendCommand('stop');
      _sendAxis('slider1', 0);
      _sendAxis('slider2', 0);
    } else {
      widget.ble.sendPacketNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
    return Opacity(
      opacity: ble.connected ? 1 : .82,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 页内空间有限：用紧凑布局把按键做大；全屏才铺开成手柄弧形键位。
          final Widget body;
          if (!widget.fullscreen) {
            body = _compactLayout();
          } else {
            // 宽屏走「手柄布局」：左手摇杆 + 右手弧形技能键，拇指活动半径最短。
            final wide = constraints.maxWidth > constraints.maxHeight * 1.2;
            body = wide ? _wideLayout() : _tallLayout();
          }
          return Column(
            children: [
              SizedBox(height: _toolbarHeight, child: _toolbar()),
              const SizedBox(height: 6),
              Expanded(
                // 控件本身的空白都交给下层搓动层，控件自己在上层照常抢事件。
                child: Stack(
                  fit: StackFit.expand,
                  children: [_scrubLayer(), body],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------- 手柄布局

  Widget _wideLayout() {
    return LayoutBuilder(
      builder: (context, c) {
        final body = math.max(120.0, c.maxHeight);
        // 摇杆 / 按键都按拇指可覆盖的半径定尺寸，不让手指伸到屏幕中间。
        final joy = math.min(c.maxWidth * .26, body * .78).clamp(96.0, 300.0);
        return Row(
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
                        width: 138,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _axisCard('X', widget.ble.sliderA),
                            const SizedBox(height: 4),
                            _axisCard('Y', widget.ble.sliderB),
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
        );
      },
    );
  }

  Widget _tallLayout() {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(flex: 5, child: _joystick()),
              const SizedBox(width: 12),
              Expanded(flex: 6, child: _arcPadFit()),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _axisRow(),
      ],
    );
  }

  /// 页内（非全屏）布局：左摇杆 + 右 2×3 大按键，底部显示 X / Y。
  Widget _compactLayout() {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(flex: 5, child: _joystick()),
              const SizedBox(width: 12),
              Expanded(flex: 6, child: _padGrid()),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _axisRow(),
      ],
    );
  }

  /// 原来两条滑条的位置：只显示搓出来的 X / Y。
  Widget _axisRow({double height = 52}) {
    final ble = widget.ble;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Expanded(child: _axisCard('X', ble.sliderA)),
          const SizedBox(width: 10),
          Expanded(child: _axisCard('Y', ble.sliderB)),
        ],
      ),
    );
  }

  /// 紧凑布局的 2 列 × 3 行按键：按键尽量撑满，整体居中不出空隙。
  Widget _padGrid() {
    return LayoutBuilder(
      builder: (context, c) {
        const gap = 10.0;
        final cell = math.min(
          (c.maxWidth - gap) / 2,
          (c.maxHeight - gap * 2) / 3,
        );
        final size = math.max(cell, 44.0);
        return Center(
          child: SizedBox(
            width: size * 2 + gap,
            height: size * 3 + gap * 2,
            child: Column(
              children: [
                for (var row = 0; row < 3; row++) ...[
                  if (row > 0) const SizedBox(height: gap),
                  Row(
                    children: [
                      for (var col = 0; col < 2; col++) ...[
                        if (col > 0) const SizedBox(width: gap),
                        SizedBox(
                          width: size,
                          height: size,
                          child: _padButton(_padSpecs[row * 2 + col]),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
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

  /// 王者式弧形键位：主键在右下，其余环绕它，再往左是恢复 / 回城。
  Widget _arcPad(double size) {
    final children = <Widget>[];
    for (final spec in _padSpecs) {
      // 小屏下按比例算出来的键太小，给一个最小直径保证好按。
      final diameter = math.max(spec.radius * 2 * size, 44.0);
      children.add(
        Positioned(
          left: spec.cx * size - diameter / 2,
          top: spec.cy * size - diameter / 2,
          width: diameter,
          height: diameter,
          child: _padButton(spec),
        ),
      );
    }
    return Stack(clipBehavior: Clip.none, children: children);
  }

  Widget _padButton(_PadSpec spec) {
    final command = widget.ble.command(spec.key);
    return PadButton(
      label: command.label,
      icon: spec.icon,
      primary: spec.primary,
      enabled: widget.ble.connected,
      latch: command.latch,
      active: widget.ble.pressedKeys.contains(spec.key),
      onDown: () => _onButtonPressed(spec.key, true),
      onUp: () => _onButtonPressed(spec.key, false),
      onRepeat: () => _repeatCommand(spec.key),
      onToggle: (on) => _onLatchToggle(spec.key, on),
    );
  }

  /// 开关式按键：点一次置位并发送，再点一次复位并再发一次。
  void _onLatchToggle(String key, bool on) {
    final ble = widget.ble;
    final next = {...ble.pressedKeys};
    if (on) {
      next.add(key);
    } else {
      next.remove(key);
    }
    ble.updateControls(pressed: next);
    if (ble.controlMode == ControlSendMode.single) {
      _sendCommand(key);
    } else {
      ble.sendPacketNow();
    }
  }

  /// 长按重复：独立模式补发该键指令（按住喇叭一直响）；
  /// 整包模式本来就按周期发，按下位已经置 1，无需额外发送。
  void _repeatCommand(String key) {
    if (widget.ble.controlMode != ControlSendMode.single) return;
    _sendCommand(key);
  }

  /// A / B 原来的位置：只显示当前搓出来的那一轴数值，长按可改指令。
  Widget _axisCard(String axis, double value) {
    final moved = value.abs() >= .5;
    final digits = moved ? '${value > 0 ? '+' : ''}${value.round()}' : '0';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => showCommandEditor(
        context,
        widget.ble,
        axis == 'X' ? 'slider1' : 'slider2',
      ),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surface.withValues(alpha: .85),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: moved ? AppColors.accent.withValues(alpha: .5) : AppColors.stroke,
          ),
        ),
        child: Row(
          children: [
            Text(
              axis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: moved ? AppColors.accent : AppColors.textDim,
              ),
            ),
            const Spacer(),
            Text(
              digits,
              style: TextStyle(
                fontSize: 17,
                height: 1.1,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: moved ? AppColors.accent : AppColors.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 键位参数：cx / cy 是圆心在键簇正方形里的归一化坐标，
/// radius 是按键半径占簇边长的比例。
class _PadSpec {
  const _PadSpec(
    this.key,
    this.cx,
    this.cy,
    this.radius, {
    required this.icon,
    this.primary = false,
  });

  final String key;
  final double cx;
  final double cy;
  final double radius;
  final IconData icon;
  final bool primary;
}

/// 参照王者右手技能区：
/// k1 主键压在右下角，k2~k4 以它为圆心绕成一段圆弧；
/// k5（恢复）、k6（回城）再往左一列，拇指横移就能碰到。
const List<_PadSpec> _padSpecs = [
  _PadSpec('k1', .720, .780, .165, icon: Icons.bolt_rounded, primary: true),
  _PadSpec('k2', .415, .780, .112, icon: Icons.campaign_rounded),
  _PadSpec('k3', .524, .546, .112, icon: Icons.lightbulb_rounded),
  _PadSpec('k4', .773, .480, .112, icon: Icons.tune_rounded),
  _PadSpec('k5', .195, .640, .098, icon: Icons.filter_5_rounded),
  _PadSpec('k6', .195, .855, .098, icon: Icons.filter_6_rounded),
];

/// 圆形技能键：按下缩小 + 发光 + 描边提亮 + 触感，松开带一点回弹；
/// 按住超过 600 ms 进入「持续触发」：每 250 ms 补发一次动作并重放水波。
class PadButton extends StatefulWidget {
  const PadButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onDown,
    required this.onUp,
    this.onRepeat,
    this.onToggle,
    this.latch = false,
    this.active = false,
    this.primary = false,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onDown;
  final VoidCallback onUp;

  /// 长按后的重复触发；为 null 时只保持按下态。
  final VoidCallback? onRepeat;

  /// 开关式按键：点一次切换，回调目标状态。
  final ValueChanged<bool>? onToggle;

  /// 是否开关式（按一次保持点亮）。
  final bool latch;

  /// 开关式的当前状态。
  final bool active;
  final bool primary;
  final bool enabled;

  @override
  State<PadButton> createState() => _PadButtonState();
}

class _PadButtonState extends State<PadButton>
    with SingleTickerProviderStateMixin {
  static const Duration _holdDelay = Duration(milliseconds: 600);
  static const Duration _repeatInterval = Duration(milliseconds: 250);

  bool _down = false;
  bool _holding = false;
  bool _pressedSent = false;
  Timer? _holdTimer;
  Timer? _repeatTimer;

  /// 按下时从中心扩散的水波。
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void dispose() {
    _holdTimer?.cancel();
    _repeatTimer?.cancel();
    _ripple.dispose();
    super.dispose();
  }

  void _press() {
    // 未连接也照样给视觉 / 触感反馈，只是不触发指令（发送层自己也会拦）。
    HapticFeedback.lightImpact();
    _ripple.forward(from: 0);
    if (widget.latch) {
      // 开关式：点一下直接切换，不等松手。
      widget.onToggle?.call(!widget.active);
      return;
    }
    setState(() {
      _down = true;
      _pressedSent = widget.enabled;
    });
    if (!_pressedSent) return;
    widget.onDown();

    _holdTimer?.cancel();
    _holdTimer = Timer(_holdDelay, () {
      if (!mounted) return;
      _holdTimer = null;
      HapticFeedback.mediumImpact();
      setState(() => _holding = true);
      _ripple.forward(from: 0);
      widget.onRepeat?.call();
      _repeatTimer?.cancel();
      _repeatTimer = Timer.periodic(_repeatInterval, (_) {
        if (!mounted) return;
        _ripple.forward(from: 0);
        widget.onRepeat?.call();
      });
    });
  }

  void _release() {
    if (widget.latch) return;
    final wasHolding = _holding;
    final sent = _pressedSent;
    _pressedSent = false;
    _stopHold();
    if (!_down) return;
    setState(() => _down = false);
    if (wasHolding) HapticFeedback.selectionClick();
    if (sent) widget.onUp();
  }

  void _stopHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    if (_holding) setState(() => _holding = false);
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
          // 开关式按键的亮灭看外部状态；普通按键看是否按住。
          final down = widget.latch ? widget.active : _down;
          final holding = widget.latch ? false : _holding;
          final lit = down || holding;
          final tint = widget.primary ? AppColors.accent : AppColors.sky;
          final iconColor = widget.primary
              ? (down ? Colors.white : AppColors.onAccent)
              : (down ? Colors.white : tint);
          final labelColor = widget.primary
              ? (down ? Colors.white : AppColors.onAccent)
              : (down ? Colors.white : AppColors.text.withValues(alpha: .9));

          return AnimatedScale(
            // 开关式锁定后不缩着，只保持高亮。
            scale: widget.latch ? 1 : (down ? .87 : 1),
            duration: Duration(milliseconds: down ? 60 : 180),
            curve: down ? Curves.easeOut : Curves.easeOutBack,
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 130),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: widget.primary
                          ? (down
                              ? [Colors.white, const Color(0xFF6FF0D4)]
                              : [AppColors.accent, AppColors.accentDeep])
                          : (down
                              ? [tint.withValues(alpha: .95), tint.withValues(alpha: .42)]
                              : [
                                  AppColors.surfaceAlt,
                                  AppColors.surface.withValues(alpha: .95),
                                ]),
                    ),
                    border: Border.all(
                      color: lit
                          ? Colors.white.withValues(alpha: widget.primary ? .9 : .8)
                          : (widget.primary ? AppColors.accentDeep : AppColors.stroke),
                      width: lit ? (holding ? 3 : 2.4) : 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (widget.primary ? AppColors.accent : tint)
                            .withValues(alpha: holding ? .78 : (down ? .66 : .18)),
                        blurRadius: holding ? 36 : (down ? 30 : 12),
                        spreadRadius: holding ? 7 : (down ? 4 : 0),
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
                // 按下水波：从中心扩散一圈亮光环，像王者技能键的手感。
                IgnorePointer(
                  child: ClipOval(
                    child: AnimatedBuilder(
                      animation: _ripple,
                      builder: (context, _) {
                        if (!_ripple.isAnimating) {
                          return const SizedBox.shrink();
                        }
                        return CustomPaint(
                          painter: _RipplePainter(progress: _ripple.value),
                        );
                      },
                    ),
                  ),
                ),
              ],
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
    'k5',
    'k6',
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
                    desc: '每个按键 / 搓动轴各发一包，适合简单协议',
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
                    desc: '摇杆 / 搓动位移 / 按键合成一个固定结构包',
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
                    ? '{x}/{y}：int8 -128~127，HEX 里写 +128 后的 0~255；{s1}/{s2}：0~100；{btn}：6 位按键位图（k1 起低位）；{k1}~{k6}：0/1'
                    : '{x}/{y}：-128~127；{s1}/{s2}：0~100；{btn}：6 位按键位图（k1 起低位）；{k1}~{k6}：0/1',
                style: const TextStyle(fontSize: 10.5, height: 1.6, color: AppColors.textDim),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                const _SheetLabel('控件指令'),
                const Spacer(),
                const Text(
                  '摇杆标签、X/Y 读数可长按直接改',
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
                          : '${command.hex ? 'HEX · ' : ''}'
                              '${command.latch ? '开关 · ' : ''}'
                              '${command.payload}',
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
  var latch = command.latch;

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
              if (key.startsWith('k'))
                SwitchListTile.adaptive(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开关式按键', style: TextStyle(fontSize: 12.5)),
                  subtitle: const Text(
                    '按一次保持点亮，再按一次取消',
                    style: TextStyle(fontSize: 10.5, color: AppColors.textDim),
                  ),
                  value: latch,
                  onChanged: (value) => setDialogState(() => latch = value),
                ),
              Text(
                key == 'joystick'
                    ? '可用变量：{x} {y}（-128 ~ 127，HEX 时 +128 转成单字节 0~255）'
                    : key.startsWith('slider')
                        ? '可用变量：{v}（0 ~ 100）'
                        : '内容原样发送；HEX 模式支持 AA 55 这种写法',
                style: const TextStyle(fontSize: 10.5, color: AppColors.textDim),
              ),
              if (hex)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '提示：{x}/{y} 会按 int8 补码写入，占 1 字节',
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
        latch: latch,
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
        // 贴底放，竖屏时摇杆正好在左手拇指落点上。
        return Align(
          alignment: Alignment.bottomCenter,
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
                      'X ${(_value.dx * 127).round()}   Y ${(_value.dy * 127).round()}',
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

/// 按键按下的水波纹：实心亮斑 + 描边光环，向外扩散并淡出。
class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = math.max(size.width, size.height) / 2;
    final t = Curves.easeOutCubic.transform(progress.clamp(0.0, 1.0));
    final radius = maxRadius * (0.15 + 0.9 * t);
    final fade = (1 - t).clamp(0.0, 1.0);

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = Colors.white.withValues(alpha: .42 * fade),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..color = Colors.white.withValues(alpha: .85 * fade),
    );
  }

  @override
  bool shouldRepaint(covariant _RipplePainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// 搓动轨迹：只在按住时出现——起点圆点、到当前位置的连线，
/// 加上水平 / 垂直两条分量线，直观看到位移是怎么分解成 X / Y 的。
class _ScrubTracePainter extends CustomPainter {
  _ScrubTracePainter({this.start, this.now});

  final Offset? start;
  final Offset? now;

  @override
  void paint(Canvas canvas, Size size) {
    final from = start;
    final to = now;
    if (from == null || to == null) return;

    final axis = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = AppColors.accent.withValues(alpha: .35);

    // 位移先拆成两条直角边：横向一段、纵向一段。
    final corner = Offset(to.dx, from.dy);
    canvas.drawLine(from, corner, axis);
    canvas.drawLine(corner, to, axis);

    canvas.drawLine(
      from,
      to,
      Paint()
        ..strokeWidth = 2
        ..color = AppColors.accent.withValues(alpha: .5),
    );
    canvas.drawCircle(
      from,
      9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = AppColors.accent.withValues(alpha: .5),
    );
    canvas.drawCircle(
      to,
      5,
      Paint()..color = AppColors.accent.withValues(alpha: .85),
    );
  }

  @override
  bool shouldRepaint(covariant _ScrubTracePainter oldDelegate) =>
      oldDelegate.start != start || oldDelegate.now != now;
}
