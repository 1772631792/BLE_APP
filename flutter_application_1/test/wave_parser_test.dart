import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/wave.dart';

void main() {
  test('JustFloat 解析：整帧、跨包、噪声前缀', () {
    final parser = JustFloatParser();
    // CH1 = 1.5, CH2 = -2.25，帧尾 00 00 80 7F
    final frame = [0x00, 0x00, 0xC0, 0x3F, 0x00, 0x00, 0x10, 0xC0, 0x00, 0x00, 0x80, 0x7F];

    parser.feed(frame);
    expect(parser.frames.length, 1);
    expect(parser.frames.first[0], closeTo(1.5, 1e-6));
    expect(parser.frames.first[1], closeTo(-2.25, 1e-6));
    expect(parser.channelCount, 2);

    // 分包：一帧被拆成三段
    parser.feed(frame.sublist(0, 3));
    parser.feed(frame.sublist(3, 7));
    parser.feed(frame.sublist(7));
    expect(parser.frames.length, 2);

    // 带 2 字节乱码前缀时，该帧字节数不再对齐会被丢弃，但会立即重新同步
    parser.feed([0xAA, 0xBB, ...frame]);
    expect(parser.frames.length, 2);
    parser.feed(frame);
    expect(parser.frames.length, 3);
    expect(parser.frames.last.length, 2);

    parser.clear();
    expect(parser.frames.isEmpty, isTrue);
    expect(parser.channelCount, 0);
  });

  test('JustFloat 多通道：一帧 4 个变量一起解析', () {
    final parser = JustFloatParser();
    final data = <int>[];
    for (final value in [1.0, -2.0, 3.5, 0.25]) {
      final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
      data.addAll(bytes.buffer.asUint8List());
    }
    data.addAll(JustFloatParser.terminator);

    parser.feed(data);
    expect(parser.frames.length, 1);
    expect(parser.channelCount, 4);
    expect(parser.frames.single.length, 4);
    expect(parser.frames.single[0], closeTo(1.0, 1e-6));
    expect(parser.frames.single[1], closeTo(-2.0, 1e-6));
    expect(parser.frames.single[2], closeTo(3.5, 1e-6));
    expect(parser.frames.single[3], closeTo(0.25, 1e-6));
  });
}
