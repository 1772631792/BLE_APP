import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/control_packet.dart';

void main() {
  test('HEX 模板组包', () {
    final bytes = buildHexPacket(
      'AA 55 {x} {y} {btn} 55 AA',
      {'x': 150, 'y': 50, 'btn': 3},
    );
    expect(bytes, [0xAA, 0x55, 150, 50, 3, 0x55, 0xAA]);

    // 数值超过一字节时截断到 0~255
    expect(buildHexPacket('{x}', {'x': 300}), [255]);

    // 非法字面量与未知占位符都要明确报错
    expect(
      () => buildHexPacket('AA ZZ {x}', {'x': 1}),
      throwsA(isA<PacketBuildException>()),
    );
    expect(
      () => buildHexPacket('AA {bogus}', {'x': 1}),
      throwsA(isA<PacketBuildException>()),
    );
  });

  test('文本模板组包', () {
    expect(
      buildTextPacket('X{x} Y{y} B{btn}', {'x': '-40', 'y': '20', 'btn': '1'}),
      'X-40 Y20 B1',
    );
    expect(
      () => buildTextPacket('X{x} Y{oops}', {'x': '1'}),
      throwsA(isA<PacketBuildException>()),
    );
    expect(
      () => buildTextPacket('   ', {'x': '1'}),
      throwsA(isA<PacketBuildException>()),
    );
  });
}
