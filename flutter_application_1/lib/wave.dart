import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'theme.dart';

/// 波形通道配色。
const List<Color> waveColors = [
  Color(0xFF63E6C9),
  Color(0xFF7FC4FF),
  Color(0xFFA78BFA),
  Color(0xFFFFC46B),
  Color(0xFFFF7F92),
  Color(0xFF9BE15D),
  Color(0xFF5EEAD4),
  Color(0xFFF472B6),
];

Color channelColor(int index) => waveColors[index % waveColors.length];

/// VOFA+ JustFloat 协议解析。
///
/// 一帧 = N 个小端 float32（N = 通道数），帧尾固定为 00 00 80 7F。
class JustFloatParser {
  JustFloatParser();

  static const List<int> terminator = [0x00, 0x00, 0x80, 0x7F];
  static const int maxFrames = 420;

  final List<int> _buffer = [];
  final List<List<double>> _frames = [];
  final ByteData _scratch = ByteData(4);

  int _channelCount = 0;
  int _totalFrames = 0;

  List<List<double>> get frames => _frames;
  int get channelCount => _channelCount;
  int get totalFrames => _totalFrames;

  void feed(List<int> data) {
    if (data.isEmpty) return;
    _buffer.addAll(data);
    // 防止一直收不到帧尾导致内存膨胀。
    if (_buffer.length > 32768) {
      _buffer.removeRange(0, _buffer.length - 16384);
    }
    while (true) {
      final end = _findTerminator();
      if (end < 0) break;
      if (end > 0 && end % 4 == 0) {
        final floats = <double>[];
        for (var i = 0; i < end; i += 4) {
          _scratch.setUint8(0, _buffer[i]);
          _scratch.setUint8(1, _buffer[i + 1]);
          _scratch.setUint8(2, _buffer[i + 2]);
          _scratch.setUint8(3, _buffer[i + 3]);
          final value = _scratch.getFloat32(0, Endian.little);
          if (value.isFinite) floats.add(value);
        }
        if (floats.isNotEmpty) {
          _channelCount = math.max(_channelCount, floats.length);
          _frames.add(floats);
          _totalFrames++;
          if (_frames.length > maxFrames) {
            _frames.removeRange(0, _frames.length - maxFrames);
          }
        }
      }
      _buffer.removeRange(0, end + terminator.length);
    }
  }

  int _findTerminator() {
    for (var i = 0; i + 3 < _buffer.length; i++) {
      if (_buffer[i] == 0x00 &&
          _buffer[i + 1] == 0x00 &&
          _buffer[i + 2] == 0x80 &&
          _buffer[i + 3] == 0x7F) {
        return i;
      }
    }
    return -1;
  }

  void clear() {
    _buffer.clear();
    _frames.clear();
    _channelCount = 0;
    _totalFrames = 0;
  }
}

/// 滚动示波器曲线。
class WaveChartPainter extends CustomPainter {
  WaveChartPainter({
    required this.frames,
    required this.channelCount,
    required this.visible,
  });

  final List<List<double>> frames;
  final int channelCount;
  final Set<int> visible;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = AppColors.stroke.withValues(alpha: .38)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var i = 1; i < 6; i++) {
      final x = size.width * i / 6;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    if (frames.isEmpty || channelCount == 0) return;

    var minV = double.infinity;
    var maxV = -double.infinity;
    for (final frame in frames) {
      for (var ch = 0; ch < channelCount; ch++) {
        if (!visible.contains(ch) || ch >= frame.length) continue;
        final v = frame[ch];
        if (v < minV) minV = v;
        if (v > maxV) maxV = v;
      }
    }
    if (!minV.isFinite || !maxV.isFinite) return;
    if ((maxV - minV).abs() < 1e-9) {
      minV -= 1;
      maxV += 1;
    }
    final pad = (maxV - minV) * .1;
    minV -= pad;
    maxV += pad;
    final span = maxV - minV;

    // 数据从右侧进入，满窗后向左滚动。
    final step = size.width / (JustFloatParser.maxFrames - 1);
    for (var ch = 0; ch < channelCount; ch++) {
      if (!visible.contains(ch)) continue;
      final paint = Paint()
        ..color = channelColor(ch)
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      final path = Path();
      var started = false;
      for (var i = 0; i < frames.length; i++) {
        final frame = frames[i];
        if (ch >= frame.length) continue;
        final x = size.width - (frames.length - 1 - i) * step;
        final y = size.height - ((frame[ch] - minV) / span) * size.height;
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }
      if (started) canvas.drawPath(path, paint);
    }

    if (minV < 0 && maxV > 0) {
      final zeroY = size.height - ((0 - minV) / span) * size.height;
      canvas.drawLine(
        Offset(0, zeroY),
        Offset(size.width, zeroY),
        Paint()..color = AppColors.textDim.withValues(alpha: .35),
      );
    }

    _label(canvas, maxV.toStringAsFixed(2), const Offset(6, 4));
    _label(canvas, minV.toStringAsFixed(2), Offset(6, size.height - 15));
  }

  void _label(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 9,
          color: AppColors.textDim.withValues(alpha: .75),
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant WaveChartPainter oldDelegate) => true;
}
