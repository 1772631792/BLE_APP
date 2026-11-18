/// 控件「整包」模式的组包工具。
///
/// 模板用 `{占位符}` 表示动态字段，例如：
/// `AA 55 {x} {y} {s1} {s2} {btn} 55 AA`
class PacketBuildException implements Exception {
  const PacketBuildException(this.message);

  final String message;

  @override
  String toString() => message;
}

final RegExp _tokenPattern = RegExp(r'\{(\w+)\}');
final RegExp _hexPattern = RegExp(r'^[0-9a-fA-F]+$');

/// 支持的所有占位符（用于界面提示与校验）。
const List<String> packetTokens = [
  'x',
  'y',
  's1',
  's2',
  'btn',
  'k1',
  'k2',
  'k3',
  'k4',
  'k5',
  'k6',
];

/// 按 HEX 模板组包：字面量按十六进制解析，占位符输出 1 字节（0~255）。
List<int> buildHexPacket(String template, Map<String, int> values) {
  final bytes = <int>[];
  var index = 0;
  for (final match in _tokenPattern.allMatches(template)) {
    _appendHexLiteral(bytes, template.substring(index, match.start));
    final token = match.group(1)!;
    final value = values[token];
    if (value == null) {
      throw PacketBuildException('模板里有未知占位符 {$token}');
    }
    bytes.add(value.clamp(0, 255));
    index = match.end;
  }
  _appendHexLiteral(bytes, template.substring(index));
  if (bytes.isEmpty) throw const PacketBuildException('数据包为空');
  return bytes;
}

void _appendHexLiteral(List<int> out, String literal) {
  final normalized = literal.replaceAll(RegExp(r'[\s,;:]'), '');
  if (normalized.isEmpty) return;
  if (normalized.length.isOdd || !_hexPattern.hasMatch(normalized)) {
    throw const PacketBuildException('HEX 模板格式错误，例如 AA 55 {x} {y} 55 AA');
  }
  for (var i = 0; i < normalized.length; i += 2) {
    out.add(int.parse(normalized.substring(i, i + 2), radix: 16));
  }
}

/// 按文本模板组包：占位符替换为十进制文本。
String buildTextPacket(String template, Map<String, String> values) {
  for (final match in _tokenPattern.allMatches(template)) {
    final token = match.group(1)!;
    if (!values.containsKey(token)) {
      throw PacketBuildException('模板里有未知占位符 {$token}');
    }
  }
  var text = template;
  values.forEach((key, value) {
    text = text.replaceAll('{$key}', value);
  });
  if (text.trim().isEmpty) throw const PacketBuildException('数据包为空');
  return text;
}
