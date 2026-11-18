# 继续开发指南

写给接手这个工程的人。目标：**半天内能看懂代码、能安全地加一个控件 / 改一版协议、能打出包**。

代码都在 `flutter_application_1/lib/`，一共 8 个文件、不到 6000 行，没有第三方面向 UI 的依赖，也没有状态管理框架。看代码前先记住一句话：

> **所有状态都在一个 `BleController` 里，页面只负责画出来和调它的方法。**

---

## 1. 代码地图

```text
lib/
├── main.dart              396 行  App 外壳：顶栏、3 页 IndexedStack、底部导航、生命周期
├── theme.dart             159 行  配色常量 + ThemeData（深色主题都在这）
├── widgets.dart           498 行  通用组件：卡片、信号条、渐变按钮、开关胶囊……（无业务）
├── ble_controller.dart   1336 行  ★ 核心：扫描/连接/重连/收发/波形缓冲/控件状态/设置持久化
├── control_packet.dart     78 行  ★ 整包模板组包，纯函数，无 Flutter 依赖（好测）
├── wave.dart              221 行  ★ JustFloat 解析器 + 波形 CustomPainter
├── services_view.dart     328 行  服务与特征值列表（挂在设备页下半部分）
└── pages/
    ├── devices_page.dart  352 行  设备页
    ├── data_page.dart     820 行  数据页（终端 / 波形）
    └── controls_page.dart 1955 行 控件页（摇杆 / 滑条 / 搓动 / 按键 / 全屏 / 设置面板）
```

依赖是单向的，没有环：

```text
main.dart ──> pages/* ──> ble_controller.dart ──> control_packet.dart
                    │                └─────────> wave.dart
                    └────> theme.dart / widgets.dart
```

- `main.dart:38` 创建**唯一**一个 `BleController` 实例，`:48` 调 `init()`，`:94` 用 `AnimatedBuilder` 监听整个 App。
- 想加页面：在 `main.dart` 的 IndexedStack 和底部导航各加一项，页面里用 `AnimatedBuilder(animation: ble)` 包一层就能跟着刷新。

---

## 2. `BleController` 怎么运转

一个 1336 行的 `ChangeNotifier`，字段分五组，按下面顺序读就行：

| 分组 | 位置 | 说明 |
| --- | --- | --- |
| 扫描结果 / 日志 | `ble_controller.dart:83-87` | 设备列表、终端日志、订阅列表 |
| 波形 | `:88` | 一个 `JustFloatParser` 实例，收到 RX 就 `feed` |
| 指令表与控件状态 | `:89-125` | 每个控件的默认指令、摇杆 / 滑条 / 搓动 / 按键当前值 |
| 连接链路 | `:127-148` | 设备、服务、TX/RX 特征值、订阅、定时器 |
| 开关与计数 | `:142-162` | 自动重连、心跳、发送模式、周期、MTU、TX/RX 计数 |

### 关键流程

**初始化**：`init()`（`:220`）—— **先** `_loadSettings()` 从本地读设置，**再**订阅 BLE 流。顺序不能反，否则会先用默认值覆盖存档。

**扫描**：`scan()` `:269` → `startScan()` `:277`，结果在 `_onScanResults()` `:314` 里做去重和排序，12 秒看门狗自动停。

**连接 / 重连**（这块最容易改坏，动之前先读一遍）：

```text
connect() :335
  └─ _tryConnect() :386        直连，失败重试 3 次
       └─ 全失败 → _tryAutoConnect() :413   系统级 autoConnect 兜底
            └─ _afterConnected() :443       请求 MTU 517、发现服务、自动挑 TX/RX
                 └─ _watchConnection() :471 监听断开
                      └─ _onLinkLost() :496 → _scheduleReconnect() :531
                            按 1→2→3→5→8→12→18→25 秒递增重连，恢复通知订阅
```

`_generation` 计数器是防竞态的：每次连接 / 断开都自增，异步回调回来时代数不对就直接丢弃。**加异步逻辑时记得也带上它**，否则会出现「已经断开又被旧回调连上」的鬼故事。

**收发**：`send()` `:793` / `sendBytes()` `:805` → `_writeBytes()` `:809`，真正写入只有这一处，MTU 限长也在这（`:824-830`，上限 `max(20, mtu - 3)`，超了抛 `BleAppException` 而不是硬拆包）。收到数据走 `_handleRx()` `:728`：先喂波形解析器，再写终端日志。

**心跳**：`_startKeepAlive()` `:854`，每 12 秒静默读一次可读特征值，让链路别被系统回收。

### 设置持久化

- key 命名统一 `settings.<驼峰字段>`，集中定义在 `ble_controller.dart:884-893`。
- 读：只在 `init()` 里 `_loadSettings()` `:897-942`，指令表走 JSON，周期做 20~1000 ms 的 clamp。
- 写：每个 setter 里**立即**落盘（`:981` 起）。写盘全部 `unawaited`，不阻塞 UI。
- 加新设置的标准动作：加一个 `_kXxx` 常量 → 在 `_loadSettings` 里读 → 在 setter 里 `_saveBool/_saveInt/_saveString` → 在设置面板加控件。

---

## 3. 整包协议：`control_packet.dart`

只有 78 行的纯函数文件，是全工程最值得先读的地方：

- 占位符正则 `\{(\w+)\}`（`:14`），白名单 `packetTokens`（`:18-32`）。
- HEX 入口 `buildHexPacket(template, Map<String,int>)` `:35`：字面量必须是偶数长度合法十六进制（允许空格 / 逗号 / 分号 / 冒号分隔），占位符值 `clamp(0,255)` 压成 1 字节。
- 文本入口 `buildTextPacket(template, Map<String,String>)` `:65`：先全量校验占位符，再 `replaceAll`。
- 未知占位符 / 非法字面量 / 空包都会抛 `PacketBuildException` 或 `ArgumentError`，**包长限制不在这里**。

值的来源在 controller：

- HEX 用 `_packetIntValues()` `ble_controller.dart:1109`（`x/y/tx/ty` 各 +128 编码）；
- 文本用 `_packetTextValues()` `:1130`（带符号十进制）；
- 发送在 `sendPacketNow()` `:1150`，周期发送由 `_syncPacketTimer()` `:1170` 控制。

> **坑**：这两个 map 必须和模板里的占位符一一对应。模板写了 `{s3}` 但 map 里没有，运行期会一直报「未知占位符」，而日志有节流（只在错误变化时记一条），很容易看成「没反应」。

---

## 4. 控件页 UI 结构

`controls_page.dart` 最长，但结构是清楚的：

```text
ControlsPage.build :72
├── 标题卡（设置按钮 :119 / 全屏按钮 :124）
└── ControlBoard :400
    ├── _scrubLayer() :333      铺满整个 Stack 的搓动手势层（在所有控件下面）
    └── 布局三选一
        ├── _compactLayout() :471   页内：左摇杆 + 2×3 按键 + 底部两条滑条
        ├── _wideLayout()    :435   全屏横屏：弧形键位
        └── _tallLayout()    :460   全屏竖屏兜底
```

几个关键点：

- **搓动**：`_scrubLayer` 用 `Listener` 的 `onPointerDown/Move/Up/Cancel`，只认第一根手指（`:341-342`）。位移按 `_scrubTravel = 0.35`（`:175`）归一化到 ±128，状态机 `_beginScrub` `:298` / `_moveScrub` `:309` / `_endScrub` `:320`，轨迹由 `_ScrubTracePainter` `:1908` 画。因为它铺在底层，所以「控件占住的地方搓不了、空白都能搓」是天然成立的，**加控件时不用管搓动的手势冲突**。
- **摇杆**：`_joystick()` `:667` → `VirtualJoystick` `:1645`，只用 `Listener` 不用 `GestureDetector`，避免和搓动层抢手势。
- **滑条**：`_sliderCard()` `:782`，`onChangeEnd` 会强制补发一次终值（`:834`），因为拖动过程中是节流发送的。
- **按键**：`PadButton` `:905`，短按发一次；按住 600 ms 后每 250 ms 补发（`:945-946`）；开关式按键在 `:758` 走 latch 逻辑，不进入连发。
- **指令编辑弹窗**：`showCommandEditor()` `:1526`，三个入口分别是摇杆标签 `:685`、滑条标签 `:795`、全屏搓动读数 `:850`。按键因为长按被连发占用，改指令走设置面板的列表。
- **设置面板**：`ControlSettingsSheet` `:1196`，指令列表 `_commandKeys` `:1209`，模板输入框 `:1344`，占位符快捷插入 `_insertToken` `:1233`。

---

## 5. 波形：`wave.dart`

- `JustFloatParser` `:25`：`feed()` `:42` 累积字节流，按帧尾 `[0x00,0x00,0x80,0x7F]`（`:28`）切帧，再按 4 字节切 float32；跨 BLE 包的一帧会自动拼回来。窗口上限 `maxFrames = 420`（`:29`），满了丢最旧。
- 通道数**不预设**，取历史最大帧长 / 4；但 `waveColors` 只有 8 种颜色，超过 8 通道会循环取色。
- 绘制 `WaveChartPainter` `:99`：可视窗口截取、自适应值域、逐通道 path、零线、上下限标注，`shouldRepaint => true`（数据一到就重画，简单粗暴但够用）。
- 消费方在 `pages/data_page.dart:390` 的 `_wave()`，通道勾选面板 `_showChannelPicker()` `:535`。

> 改解析逻辑后**务必跑** `flutter test test/wave_parser_test.dart`，那里覆盖了跨包、噪声重同步、多通道。

---

## 6. 常见改法（照着抄）

### A. 加一条滑条 C（`s3`）

按依赖顺序改 8 处，漏一处就会出现「界面有、发不出」或「发得出、设置里改不了」：

1. `control_packet.dart:18-32` 的 `packetTokens` 加 `'s3'`（设置面板的快捷插入按钮用）。
2. `ble_controller.dart:115` 附近加字段 `_sliderC`，`:196` 附近加 getter。
3. `ble_controller.dart:1073` 的 `updateControls()` 加参数并 `clamp(0, 100)`。
4. `ble_controller.dart:1115` 的 `_packetIntValues()` 和 `:1135` 的 `_packetTextValues()` 各加一行 `'s3'`。
5. `ble_controller.dart:101` 的默认指令表加 `'slider3': ControlCommand(label: '滑条 C', payload: '{v}')`。
6. `controls_page.dart:485` 的 `_compactLayout` 底部 Row 加第三张 `_sliderCard`；`:282` 的 `_onSlider` 加分支（现在是 if/else，建议顺手改成按 key 的 map）。
7. `controls_page.dart:1209` 的 `_commandKeys` 加上 `'slider3'`。
8. 想要它进整包，还得在模板里加 `{s3}`（见下一条）。

### B. 改默认整包模板

- 默认值在 `ble_controller.dart:109`。**只影响从没保存过的用户**，已落盘的仍读 `settings.packetTemplate`（`:918`），自己测的时候要么清 App 数据，要么在设置面板里重输。
- 同步改示例文案：`control_packet.dart:57`、`controls_page.dart:1350` 的输入框 hint、`:1591` 的变量说明。
- 包长对照 `ble_controller.dart:824-830`：默认 MTU 23 时单包上限只有 20 字节，加字段前先确认目标设备的 MTU；真超了要么精简模板，要么改成分片写入。

### C. 加一种新协议（比如文本 CSV 以外的格式）

1. 解析器新开一个文件（照抄 `wave.dart` 的结构：一个 `feed()` + 一个 Painter），不要塞进 `ble_controller`。
2. 在 `ble_controller.dart:88` 旁边加实例，`_handleRx()` `:728` 里按当前协议分派喂养。
3. 数据页加选择器，把 `channelCount / frames` 接到新 painter 上。

### D. 改断线重连策略

只动 `_scheduleReconnect()` `:531` 的退避数组和 `_generation` 检查，别动 `_watchConnection` 的订阅时机。

---

## 7. 构建与踩坑

```bash
cd flutter_application_1
flutter pub get
flutter analyze
flutter test
python build.py            # 出 dist/BLEStudio-vX.Y.Z-YYYYMMDD.apk
```

冷知识：`build.py` 会先把 `图标.png` 转成五档 mipmap 并透明化四角，没有 Pillow 就跳过，不影响编译。

**这个工程特有的坑**：

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `Could not close incremental caches` / `different roots: C:\Users\...\Pub\Cache\...` | Pub 缓存在 C 盘、工程在 D 盘，Kotlin 增量编译无法跨盘算相对路径 | `android/gradle.properties` 里已写死 `kotlin.incremental=false`，别删 |
| 第一次构建卡在下载 | Gradle / Maven 依赖要走代理 | `android/gradle.properties` 加 `systemProp.http(s).proxyHost/Port`，改完 `./gradlew --stop` |
| `Unsupported class file major version` | JDK 不对 | 用 JDK 17（`android/app/build.gradle.kts` 指定） |
| 装新包覆盖失败 | 换了签名或改了 `applicationId` | 卸载重装；改包名等于新应用 |
| 模拟器扫不到设备 | 模拟器没有 BLE | 必须真机 |

真机调试蓝牙只能真机：`flutter run --release` 验证性能，`flutter run` 看日志。

---

## 8. 提交与发版

1. 改 `pubspec.yaml` 的 `version: x.y.z+build`（build 号必须递增，否则装不上）。
2. 更新 README 的「更新日志」，在 `docs/release-notes/` 加 `vX.Y.Z.md`。
3. `python build.py`，把 `dist/` 里的 APK 传到 GitHub Release。
4. tag 用 `vX.Y.Z`，Release 正文直接粘 `docs/release-notes/vX.Y.Z.md`。

> 目前 Release 用的是 debug 签名，只能自己分发；要上架得先配自己的 keystore，再 `flutter build appbundle`。

---

## 9. 想加测试的话

现在只有两个纯逻辑文件有测试：`test/control_packet_test.dart`、`test/wave_parser_test.dart`。想扩的话按代价从低到高：

1. **组包 / 解析**：最简单，纯函数，直接加用例。
2. **`BleController` 的设置持久化**：`SharedPreferences.setMockInitialValues({})` 就能测，不用真蓝牙。
3. **页面 widget 测试**：要给 `BleController` 做假实现，成本高，优先级最低。

改完组包或解析逻辑，至少跑 `flutter test` 再提交。
