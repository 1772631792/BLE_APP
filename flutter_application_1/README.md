# BLE Studio · 蓝牙调试助手

一个给 BLE（低功耗蓝牙）设备用的调试 / 遥控 App：扫描连接、GATT 调试、数据收发、VOFA+ JustFloat 波形、摇杆控件。
无广告、无联网权限、Android 12 及以上不需要定位权限。

---

## 1. 功能一览

| 页面 | 能力 |
| --- | --- |
| 设备 | 扫描附近 BLE（12 秒 / 下拉刷新）、名称与 MAC 搜索、信号强度、上次设备置顶重连、连接失败自动重试、断线自动重连、心跳保活；连上后同页展开「服务与特征值」，指定 TX / RX 通道、读特征值、开关通知 |
| 数据 | 顶部切换 **终端 / 波形**：终端显示带 `TX / RX / ERR / SYS` 着色的日志，可复制清空、HEX 收发；波形解析 **VOFA+ JustFloat**，多通道自动缩放、可隐藏通道、暂停与清空 |
| 控件 | 虚拟摇杆 + 两个滑条 + 2×2 按键 + 停止键；支持 **独立指令** 与 **整包** 两种发送模式；可全屏横屏（沉浸式）、逐条自定义指令 |

连接相关默认策略：

- 直连失败自动重试 3 次，仍失败则改用系统级 autoConnect 兜底
- 连上后请求高优先级连接参数 + MTU 517
- 断线后按 1→2→3→5→8→12→18→25 秒逐级自动重连，并恢复之前的通知订阅
- 心跳保活：每 12 秒静默读一次可读特征值，降低空闲断连概率

---

## 2. 环境要求

| 项目 | 版本 / 说明 |
| --- | --- |
| Flutter | 3.47.1（stable），Dart 3.13.1 |
| Android SDK | 需安装 platform-tools、build-tools；compileSdk 跟随 Flutter 配置 |
| JDK | 17（`android/app/build.gradle.kts` 里指定 17） |
| 依赖 | `flutter_blue_plus: 2.3.15` |

首次拉取依赖：

```bash
flutter pub get
```

检查环境是否就绪：

```bash
flutter doctor -v
```

需要看到 Android toolchain 一项为通过（`✓`）。

---

## 3. 打包（生成 APK）

### 方式一：一键脚本（推荐）

工程根目录下的 `build.py` 会自动编译、改好名字并打开产物目录：

```bash
cd flutter_application_1
python build.py
```

脚本行为：

1. 读取 `pubspec.yaml` 的版本号（如 `1.0.0+1` → `1.0.0`）
2. 执行 `flutter build apk --release`
3. 把 `build/app/outputs/flutter-apk/app-release.apk` 复制到 `dist/`
4. 命名为 `{APP_NAME}-v{版本}-{日期}.apk`，例如：

```text
dist/BLEStudio-v1.0.0-20261117.apk
```

5. 打印文件大小与原始产物路径，并打开 `dist` 目录

脚本顶部可改的配置：

| 变量 | 作用 | 默认值 |
| --- | --- | --- |
| `APP_NAME` | 产物文件名前缀 | `BLEStudio` |
| `FLUTTER` | flutter 可执行文件路径 | `D:\flutter\bin\flutter.bat` |
| `DIST_DIR` | 产物输出目录 | `dist` |

> 若 `FLUTTER` 指向的路径不存在，脚本会自动改用 PATH 里的 `flutter`。

### 方式二：手动命令

```bash
# 正式包
flutter build apk --release

# 调试包（可直接 flutter run 安装）
flutter run
```

产物路径：

| 构建类型 | 路径 |
| --- | --- |
| release | `build/app/outputs/flutter-apk/app-release.apk` |
| debug | `build/app/outputs/flutter-apk/app-debug.apk` |

### 安装到手机

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

或直接把 APK 传到手机点击安装（需允许“安装未知来源应用”）。

### 打包常见问题

- **`flutter: command not found`**：把 Flutter 的 `bin` 加入 PATH，或改 `build.py` 里的 `FLUTTER`。
- **Gradle 下载依赖很慢 / 失败**：首次构建需要联网拉 Gradle 与依赖，建议配置国内镜像或代理后重试。
- **`Unsupported class file major version`**：JDK 版本不对，换成 JDK 17。
- **想换应用显示名 / 包名**：改 `android/app/src/main/AndroidManifest.xml` 的 `android:label`，包名改 `android/app/build.gradle.kts` 的 `applicationId`（改包名属于新应用，不能覆盖安装旧版）。
- **正式发布**：目前 release 使用 debug 签名（见 `build.gradle.kts`），上架或分发前需配置自己的 keystore；也可用 `flutter build apk --split-per-abi` 减小体积。

---

## 4. 使用说明

### 设备页

1. 点「扫描」，列表按信号强度排序，上次连过的设备置顶并标记「上次」，按钮直接显示「重连」。
2. 点设备卡片上的「连接」，成功后（默认）自动跳到数据页。
3. 连上后本页出现「服务与特征值」：把可写特征值设为 **TX**，把可通知特征值设为 **RX**，并按需开启通知。
4. 三个开关：自动重连、心跳保活、连上后进数据页。

### 数据页

- **终端**：日志最新在上，行首是时间与方向（`TX` 发送、`RX` 接收、`ERR` 错误、`SYS` 系统），右上角可复制全部 / 清空；底部输入框发送，`HEX` 按钮切换十六进制发送。
- **波形**：设备按 JustFloat 协议发送数据即可自动出图。

#### JustFloat 协议格式

每帧 = N 个 **小端 float32**（N 为通道数），帧尾固定 4 字节：

```text
00 00 80 7F
```

示例：两通道，值为 1.5 与 -2.25：

```text
00 00 C0 3F   00 00 10 C0   00 00 80 7F
└─ 1.5 ─────┘ └─ -2.25 ───┘ └─ 帧尾 ────┘
```

波形窗口保留最近 420 帧，满窗后向左滚动；Y 轴自动缩放，底部图例可点选显示 / 隐藏通道。

### 控件页

- **摇杆**：按下即定位、拖动跟手、松手回中（默认同时发送一次停止指令）。
- **滑条 A / B**：0~100。
- **按键**：2×2，按下与松开都会更新状态。
- **停止**：摇杆回中 + 清空按键 + 立即发一次。
- **全屏**：切横屏 + 沉浸式，退出自动恢复。
- **改指令 / 齿轮设置**：可编辑任意控件的名称、内容、是否按 HEX 发送。

#### 两种发送模式

| 模式 | 说明 |
| --- | --- |
| 独立指令（默认） | 每个按键 / 摇杆 / 滑条各自发一包，内容可逐条自定义 |
| 整包 | 把摇杆、滑条、按键合成一个固定结构的包，按周期持续发送 |

整包模式默认模板：

```text
AA 55 {x} {y} {s1} {s2} {btn} 55 AA
```

占位符含义：

| 占位符 | 含义 | HEX 模式下的取值 |
| --- | --- | --- |
| `{x}` `{y}` | 摇杆 X / Y | -100~100 **加 100 偏移** → 0~200 |
| `{s1}` `{s2}` | 滑条 A / B | 0~100 |
| `{btn}` | 按键位图 | k1~k4 对应 bit0~bit3 |
| `{k1}`~`{k4}` | 单个按键状态 | 0 / 1 |

- 发送周期可选 20 / 50 / 100 / 200 ms
- 模板可切 HEX 或文本（文本模式下数值为十进制字符串）
- 按键按下 / 松开会立即补发一包，不必等周期
- 组包失败不会刷屏，只在错误变化时记录一条日志

---

## 5. 权限说明

| 权限 | 用途 |
| --- | --- |
| `BLUETOOTH_SCAN`（`neverForLocation`） | Android 12+ 扫描，声明不用于定位，因此**不需要定位权限** |
| `BLUETOOTH_CONNECT` | Android 12+ 连接与读写 |
| `BLUETOOTH` / `BLUETOOTH_ADMIN`（≤ Android 11） | 旧系统蓝牙操作 |
| `ACCESS_FINE_LOCATION`（≤ Android 11） | Android 11 及以下系统扫描 BLE 的强制要求 |

其他说明：

- release 包**不含 INTERNET 权限**，没有任何联网 / 广告 / 统计行为
- debug 包带 INTERNET 权限，仅用于 Flutter 热重载调试
- Android 11 及以下除权限外还需**打开系统定位服务**，否则搜不到设备（系统限制）

---

## 6. 目录结构

```text
lib/
├── main.dart              应用外壳：状态横幅、底部导航、生命周期
├── theme.dart             配色与 Material 主题
├── widgets.dart           通用组件（卡片、信号条、渐变按钮、开关胶囊…）
├── ble_controller.dart    扫描 / 连接重试 / 自动重连 / 心跳 / 收发 / 控件状态
├── control_packet.dart    整包模式组包（HEX / 文本模板）
├── wave.dart              JustFloat 解析与波形绘制
├── services_view.dart     服务与特征值区块（并入设备页）
└── pages/
    ├── devices_page.dart  设备页
    ├── data_page.dart     数据页（终端 / 波形）
    └── controls_page.dart 控件页（摇杆 / 滑条 / 按键 / 全屏）
test/
├── wave_parser_test.dart   JustFloat 解析单测
└── control_packet_test.dart 整包组包单测
build.py                   一键打包脚本
```

---

## 7. 开发与校验

```bash
flutter analyze          # 静态检查（当前无告警）
flutter test             # 单元测试
flutter run              # 真机调试
flutter run --release    # 真机跑正式包，验证性能
```

真机蓝牙相关功能（扫描、连接、波形）必须用真机测试，模拟器不支持 BLE。

---

## 8. 已知限制

- 单包发送不做自动分包：数据超过 `MTU - 3` 时会明确报错，避免破坏设备协议
- 不保存历史连接（重启 App 后需重新扫描；上次设备仅在本次运行内置顶）
- 未加前台服务，长时间切后台 / 锁屏可能被系统杀掉导致断连
- 波形仅支持 VOFA+ JustFloat，暂不支持 FireWater（文本）协议
- 整包模式 `{x}/{y}` 使用 +100 偏移的无符号单字节编码，若固件要求有符号原值需自行调整模板或改代码
