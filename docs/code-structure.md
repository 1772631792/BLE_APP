# 代码结构

本文只讲**代码长什么样**：有哪些文件、谁依赖谁、核心类怎么组织。要改功能请接着看 [dev-guide.md](dev-guide.md)，要对接固件请看 [protocol.md](protocol.md)。

代码全部在 `flutter_application_1/lib/`，共 10 个文件约 6300 行。没有第三方 UI 库、没有状态管理框架、没有代码生成。

---

## 1. 目录树

```text
BLE/                                    仓库根
├── README.md                           项目介绍 + 使用说明（面向使用者）
├── docs/                               文档（本目录）
├── 图标.png / 图标.ico                  图标源文件
└── flutter_application_1/              Flutter 工程
    ├── lib/
    │   ├── main.dart                   394 行  应用外壳
    │   ├── theme.dart                  159 行  配色与 ThemeData
    │   ├── widgets.dart                498 行  通用组件库
    │   ├── ble_controller.dart        1465 行  BLE 业务核心
    │   ├── control_packet.dart          78 行  整包组包（纯函数）
    │   ├── wave.dart                   221 行  JustFloat 解析 + 绘图
    │   ├── services_view.dart          328 行  服务/特征值区块
    │   └── pages/
    │       ├── devices_page.dart       446 行  设备页
    │       ├── data_page.dart          820 行  数据页
    │       └── controls_page.dart     1955 行  控件页
    ├── test/
    │   ├── control_packet_test.dart     41 行
    │   └── wave_parser_test.dart        55 行
    ├── android/                        Android 壳工程
    ├── build.py                        一键打包脚本
    ├── pubspec.yaml                    依赖与版本号
    └── dist/                           打包产物（gitignore）
```

---

## 2. 分层与依赖

三层，依赖严格单向，没有循环：

```text
┌─────────────────────────────────────────────────────┐
│ 表现层  main.dart / pages/* / services_view.dart     │
│        widgets.dart（通用组件） theme.dart（样式）    │
└────────────────────────┬────────────────────────────┘
                         │ 只调用方法、读 getter
┌────────────────────────▼────────────────────────────┐
│ 状态层  BleController（ChangeNotifier）              │
│        扫描 / 连接 / 重连 / 收发 / 控件值 / 设置持久化 │
└──────────┬───────────────────────────┬──────────────┘
           │                           │
┌──────────▼──────────┐    ┌───────────▼─────────────┐
│ 协议层               │    │ 数据解析层               │
│ control_packet.dart  │    │ wave.dart               │
│ 整包模板 → 字节       │    │ JustFloat 字节 → 帧      │
└──────────────────────┘    └─────────────────────────┘
```

具体 import：

| 文件 | 依赖 |
| --- | --- |
| `main.dart` | `ble_controller`、三个 page、`theme`、`widgets`、`flutter_blue_plus` |
| `pages/devices_page.dart` | `ble_controller`、`services_view`、`theme`、`widgets` |
| `pages/data_page.dart` | `ble_controller`、`wave`、`theme`、`widgets` |
| `pages/controls_page.dart` | `ble_controller`、`control_packet`（取占位符列表）、`theme`、`widgets` |
| `ble_controller.dart` | `control_packet`、`wave`、`flutter_blue_plus`、`shared_preferences` |
| `services_view.dart` / `wave.dart` / `widgets.dart` | `theme` |
| `control_packet.dart` | 无（纯 Dart，最好测） |

**约定**：页面里不写 BLE 调用，只调 `BleController` 的方法；`BleController` 里不出现 `BuildContext`；协议解析不碰 UI。

---

## 3. 表现层

### 3.1 `main.dart`

`BleHomePage` 是唯一的 StatefulWidget 外壳：

- 创建并持有**唯一**的 `BleController`，`initState` 里 `init()`，`dispose` 里 `dispose()`；
- `_tab` 控制三页 `IndexedStack`（0 设备 / 1 数据 / 2 控件）；
- 监听 controller：连接成功（`connectedSerial` 变化）且 `autoOpenControls` 为真时跳到 tab 2；
- 顶栏状态横幅按 `LinkPhase` 切换文案，错误用 SnackBar 弹出（`errorSerial` 去重）；
- `_AuroraBackground` 是背景光斑，纯装饰。

### 3.2 三个页面

| 页面 | 主要类 | 结构 |
| --- | --- | --- |
| 设备页 | `DevicesPage` / `_DeviceCard` / `_LastDeviceCard` | 扫描面板（搜索 + 扫描按钮 + 4 个开关）→ 上次设备卡片 → 服务与特征值 → 设备列表 |
| 数据页 | `DataPage` + `DataMode` 枚举 | 顶部终端/波形切换，终端是日志列表 + 发送框，波形是 `CustomPaint` + 图例 + 通道选择面板 |
| 控件页 | `ControlsPage` → `ControlBoard` → 三套布局 | 页内 `_compactLayout`、全屏横屏 `_wideLayout`、全屏竖屏 `_tallLayout` |

`ControlsPage` 的组成：

| 控件 | 实现 |
| --- | --- |
| 摇杆 | `VirtualJoystick`（`Listener` 手势）+ `_JoystickPainter` |
| 按键 | `PadButton`（按下缩放、水波长按连发）+ `_RipplePainter` |
| 搓动 | `_scrubLayer()` 铺满 Stack 底层的 `Listener` + `_ScrubTracePainter` |
| 滑条 | `_sliderCard()`，`Slider` + `SliderTheme` |
| 指令编辑 | `showCommandEditor()` 弹窗 |
| 设置面板 | `ControlSettingsSheet`（指令列表 / 模式 / 模板 / 周期） |

### 3.3 `widgets.dart`

无业务的通用组件，改样式优先动这里，别在页面里重复写：

`Panel`（卡片）、`SectionHeader`、`GlowDot`、`SignalBars`、`GradientButton`、`TogglePill`、`MiniTag`、`StatTile`、`EmptyState`。

### 3.4 `theme.dart`

`AppColors` 常量（背景、面板、描边、强调色、语义色）+ `buildAppTheme()`。深色主题全部从这里取色，页面里不要写死 `Color(...)`。

---

## 4. 状态层：`BleController`

文件里是按这个顺序排的，照着读即可：

1. 枚举与数据类：`LinkPhase`、`LogKind`、`LogEntry`、`BleAppException`、`ControlSendMode`、`ControlCommand`；
2. 字段：扫描结果 / 日志 / 订阅 / 波形解析器 / 指令表 / 控件值 / 链路对象 / 开关与计数；
3. getter；
4. 生命周期；
5. 扫描；
6. 连接与重连；
7. GATT 与收发；
8. 心跳；
9. 持久化；
10. 设置 setter；
11. 控件状态与整包；
12. 辅助函数。

### 4.1 生命周期

| 方法 | 做什么 |
| --- | --- |
| `init()` | **先** `_loadSettings()` 再订阅扫描/连接/适配器流，最后 `_connectLastOnLaunch()` 尝试启动直连 |
| `dispose()` | 取消所有订阅与定时器，断开当前设备 |
| `onResumed()` | 回前台时如果该连没连，补一次重连调度 |

### 4.2 连接状态机

```text
idle ──connect()──> connecting ──成功──> connected
                        │                  │
                        │失败               │链路断开
                        ▼                  ▼
                      idle <──放弃──── reconnecting ──成功──> connected
```

关键方法：

| 方法 | 职责 |
| --- | --- |
| `connect(device)` | 入口：停扫描、切设备、`_watchConnection`、3 次直连、autoConnect 兜底 |
| `_tryConnect()` | 单轮直连（15 s 超时），失败先 disconnect 再重试 |
| `_tryAutoConnect()` | 系统级 autoConnect，等 20 s |
| `_afterConnected()` | 高优先级连接参数、MTU 517、发现服务、恢复通知、开心跳与整包定时器 |
| `_watchConnection()` | 监听 `connectionState`，首次连上时记 `connectedSerial`（UI 靠它跳页） |
| `_onLinkLost()` / `_scheduleReconnect()` | 断线清理 → 1/2/3/5/8/12/18/25 秒退避重连 |
| `disconnect()` / `_teardown()` | 主动断开，清空服务、特征值、订阅、定时器 |

**竞态保护**：`_generation` 自增。所有异步回调回来先比代数，防止「旧连接回调把新连接顶掉」。改这块时务必保留。

### 4.3 启动直连（v3.0.1 新增）

| 方法 | 职责 |
| --- | --- |
| `_connectLastOnLaunch()` | 启动 600 ms 后：蓝牙开着 → 释放残留连接 → 按保存的 MAC 直连 |
| `connectLastDevice()` | 设备页「上次设备」卡片调用，手动直连（会请求开蓝牙） |
| `_releaseStaleConnection(id)` | 从 `FlutterBluePlus.connectedDevices` 里找到同一台设备并断开 |
| `_rememberDevice(device)` | 连接成功时写入 `lastDeviceId` / `lastDeviceName` |
| 扫描兜底 | `startScan()` 里 8 秒定时器：一个设备都没搜到就直连上次设备 |

### 4.4 收发链路

```text
RX：flutter_blue_plus onValueReceived
      → _handleRx(bytes)
          ├─ _wave.feed(bytes)      波形
          └─ _log('RX …')           终端

TX：控件回调 / 发送框
      → send()/sendBytes()
          → _writeBytes()           唯一的真实写入点
              ├─ 检查长度 ≤ max(20, mtu - 3)
              └─ _tx.write()
```

### 4.5 控件值与整包

- `updateControls({joyX, joyY, sliderA, sliderB, touchX, touchY, pressed})`：所有控件的唯一写入口，内部 clamp（摇杆 -1~1、滑条 0~100、搓动 -128~127）；
- `joyXInt/joyYInt/scrubXInt/scrubYInt`：转成 int8 给协议用；
- `_packetIntValues()`：HEX 模板的取值表，`x/y/tx/ty` 做 `+128`；
- `_packetTextValues()`：文本模板的取值表；
- `sendPacketNow()` / `_syncPacketTimer()`：立即发一包 / 按周期发。

### 4.6 持久化

统一 `SharedPreferences`，key 都是 `settings.<name>`：

| key | 内容 |
| --- | --- |
| `settings.commands` | 全部控件指令（JSON） |
| `settings.packetTemplate` / `packetHex` / `packetIntervalMs` / `controlMode` | 整包配置 |
| `settings.autoReconnect` / `keepAlive` / `autoOpenControls` / `hexSend` / `hexReceive` | 开关 |
| `settings.lastDeviceId` / `lastDeviceName` / `autoConnectLast` | 上次设备与启动自动连接 |

- 读：只在 `init()` 的 `_loadSettings()` 里；
- 写：每个 setter 里立刻 `unawaited` 落盘，不阻塞 UI；
- 兼容：`autoOpenControls` 读不到时回退旧 key `autoOpenTerminal`。

---

## 5. 协议层：`control_packet.dart`

78 行纯函数，没有 Flutter 依赖：

| 符号 | 说明 |
| --- | --- |
| `packetTokens` | 支持的占位符白名单，设置面板的快捷插入按钮也用它 |
| `buildHexPacket(template, values)` | HEX 模式：字面量必须是偶数位十六进制，占位符值 `clamp(0,255)` |
| `buildTextPacket(template, values)` | 文本模式：先校验占位符，再 `replaceAll` |
| `PacketBuildException` | 模板错误 |

包长限制不在这里，在 `BleController._writeBytes()`。协议细节见 [protocol.md](protocol.md)。

---

## 6. 数据解析层：`wave.dart`

| 类 | 职责 |
| --- | --- |
| `JustFloatParser` | 累积字节 → 按帧尾 `00 00 80 7F` 切帧 → 4 字节小端 float；窗口 420 帧；通道数按最长帧推断 |
| `WaveChartPainter` | `CustomPainter`：网格、可视窗口、自适应值域、逐通道曲线、零线、上下限标注 |

数据页的图例、通道勾选、缩放平移都在 `data_page.dart` 里，painter 只管画。

---

## 7. 一次完整数据流

**接收一帧波形**：

```text
设备 NOTIFY → controller._handleRx
            → JustFloatParser.feed（可能跨包）
            → DataPage 的 AnimatedBuilder 重建
            → WaveChartPainter.paint
```

**按一下摇杆（整包模式）**：

```text
VirtualJoystick onChanged
  → ControlBoard 调 ble.updateControls(joyX, joyY)
    → 50 ms 定时器触发 sendPacketNow()
      → buildHexPacket(模板, _packetIntValues())
      → _writeBytes() → 特征值 write
```

---

## 8. 测试

| 文件 | 覆盖 |
| --- | --- |
| `test/control_packet_test.dart` | HEX / 文本组包、非法字面量、未知占位符、空包 |
| `test/wave_parser_test.dart` | 整帧、跨包分段、噪声前缀重同步、4 通道、clear |

`BleController` 依赖真机 BLE 与平台通道，目前没有单测；要补只能测设置持久化（`SharedPreferences.setMockInitialValues`）。

---

## 9. 命名与代码约定

- 私有成员一律 `_` 前缀；异步失败用 `_log(..., LogKind.error)` + `_friendly(e)` 转人话，不向 UI 抛原始异常；
- 对外抛错只用 `BleAppException`；
- 定时器、订阅在 `dispose()` / `_teardown()` 里必须成对取消；
- 新增状态要同时考虑：字段 → getter → `_notify()` → 是否持久化；
- 页面只读 getter，不直接访问 controller 的私有状态。
