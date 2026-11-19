# 继续开发指南

写给要改这个工程的人：**改哪里、怎么改、哪里容易改坏**。

先读两篇再动手：

- [code-structure.md](code-structure.md) —— 代码长什么样、类和方法都在哪；
- [protocol.md](protocol.md) —— 发出去的字节是什么意思。

一句话原则：**所有状态都在 `BleController`，页面只负责画和调方法；协议与解析是独立纯逻辑模块。**

---

## 1. 常用命令

```bash
cd flutter_application_1
flutter pub get
flutter analyze            # 提交前必须过（当前 0 告警）
flutter test               # 组包 + 波形解析的单测
flutter run                # 真机调试（模拟器没有 BLE）
flutter run --release      # 验证性能
python build.py            # 出 dist/BLEStudio-vX.Y.Z-日期.apk
```

详细环境与打包见 [build.md](build.md)。

---

## 2. 加一个设置项

标准五步，少一步就会出现「重启后丢失」或「界面能改但不生效」：

1. `ble_controller.dart` 加字段（给默认值）；
2. 加 getter；
3. 在 `_loadSettings()` 里读，key 用 `settings.<驼峰名>`；
4. 加 setter：改字段 → `_saveBool/_saveInt/_saveString` → `_notify()` → 可选 `_log`；
5. 在对应页面加控件（设备页用 `TogglePill`，控件页用 `ControlSettingsSheet`）。

> 顺序注意：`init()` 里必须**先** `_loadSettings()` **再**订阅 BLE 流，否则默认值会覆盖存档。

---

## 3. 常见改法（照着抄）

### A. 加一条滑条 C（`s3`）

按依赖顺序改，漏一处就会出现「界面有、发不出」或「发得出、设置里改不了」：

1. `control_packet.dart` 的 `packetTokens` 加 `'s3'`（设置面板的快捷插入按钮用）；
2. `ble_controller.dart` 加字段 `_sliderC` 和 getter；
3. `updateControls()` 加参数并 `clamp(0, 100)`；
4. `_packetIntValues()` 和 `_packetTextValues()` 各加一行 `'s3'`；
5. 默认指令表 `_commands` 加 `'slider3': ControlCommand(label: '滑条 C', payload: '{v}')`；
6. `controls_page.dart` 的 `_compactLayout` 底部 Row 加第三张 `_sliderCard`；
7. `_onSlider` 加分支（现在是 if/else，建议顺手改成按 key 的 map）；
8. `_commandKeys` 加上 `'slider3'`，设置面板才会列出来；
9. 想让它在整包里发出去，模板里加 `{s3}`。

### B. 改整包默认模板

- 默认值在 `ble_controller.dart` 的 `_packetTemplate` 字段；
- **只影响从没保存过的用户**，已落盘的仍读 `settings.packetTemplate`。自己测试时要么清 App 数据，要么在设置面板里重输；
- 同步改示例文案：`control_packet.dart` 的错误提示、`controls_page.dart` 的输入框 hint 和变量说明；
- 包长必须对照 `_writeBytes()` 里的上限 `max(20, mtu - 3)`。

### C. 加一种新协议（比如文本 CSV 以外的格式）

1. 新开一个文件（照 `wave.dart` 的结构：解析器 + `CustomPainter`），不要塞进 `BleController`；
2. `BleController` 加解析器实例，在 `_handleRx()` 里按当前协议分派；
3. `data_page.dart` 加协议选择器，把 `frames / channelCount` 接到新 painter；
4. 解析器写成纯函数并补单测（参考 `wave_parser_test.dart`）。

### D. 改断线重连策略

- 只动 `_scheduleReconnect()` 的退避数组（现在是 1/2/3/5/8/12/18/25 秒）和失败后的处理；
- 不要动 `_watchConnection()` 的订阅时机；
- **保留 `_generation` 校验**：每次连接 / 断开都自增，异步回调回来先比代数，否则会出现「已经断开又被旧回调连上」。

### E. 改启动自动连接

| 想改什么 | 改哪里 |
| --- | --- |
| 启动等待时间 / 是否自动连 | `_connectLastOnLaunch()` |
| 记住哪台设备 | `_rememberDevice()`（连接成功时写入） |
| 手动重连入口 | `connectLastDevice()` + 设备页 `_LastDeviceCard` |
| 释放残留连接 | `_releaseStaleConnection()` |
| 扫描兜底时长 | `startScan()` 里的 8 秒定时器 |

> 这块涉及「设备被旧连接卡住后停止广播」的设备侧问题，改之前先读 [faq.md 第 2 条](faq.md#2-重进-app-搜不到必须给设备断电)。

---

## 4. 容易改坏的地方

| 位置 | 风险 | 约定 |
| --- | --- | --- |
| `_generation` | 去掉就会出现重连竞态 | 所有跨 await 的连接流程都要比代数 |
| `init()` 顺序 | 先订阅后读设置会覆盖存档 | 必须先 `_loadSettings()` |
| `_writeBytes()` | 绕过它直接写特征值会漏掉 MTU 检查 | 所有发送走这一个出口 |
| `dispose()` / `_teardown()` | 漏取消定时器/订阅会泄漏、重复回调 | 成对出现，新增资源两处都加 |
| 模板占位符 | 模板有、取值表没有 → 运行期报「未知占位符」 | `packetTokens`、`_packetIntValues`、`_packetTextValues` 三处同步 |
| `settings.*` key | 改名会丢用户设置 | 改名时保留旧 key 回退读取（参考 `autoOpenControls`） |

---

## 5. 构建排错

| 现象 | 处理 |
| --- | --- |
| `Could not close incremental caches` / `different roots: C:\...\Pub\Cache` | Pub 缓存在 C 盘、工程在 D 盘，`android/gradle.properties` 已写 `kotlin.incremental=false`，别删 |
| Gradle 卡在下载 | `android/gradle.properties` 配 `systemProp.http(s).proxyHost/Port`，然后 `./gradlew --stop` |
| `Unsupported class file major version` | JDK 换成 17 |
| 覆盖安装失败 | `pubspec.yaml` 的 build 号没递增，或签名变了 |

完整清单见 [build.md · 构建排错](build.md#5-构建排错)。

---

## 6. 提交与发版

提交信息用 `type(scope): 说明 (vX.Y.Z)`，例如：

```text
fix(ble): 启动直连上次设备并修复重进搜不到 (v3.0.1)
```

发版四件事：

1. `pubspec.yaml` 的 version 改掉（build 号必须递增）；
2. 更新根 `README.md` 的更新日志；
3. 新增 `docs/release-notes/vX.Y.Z.md`；
4. `python build.py` → 提 tag → GitHub Release 上传 APK。

`dist/` 已 gitignore，APK 不进仓库，只做 Release 附件。命令行发 Release 的网络坑见 [build.md · 用命令行发布](build.md#41-用命令行发布可选)。

---

## 7. 测试

现有覆盖：

| 文件 | 内容 |
| --- | --- |
| `test/control_packet_test.dart` | HEX / 文本组包、非法字面量、未知占位符、空包 |
| `test/wave_parser_test.dart` | 整帧、跨包分段、噪声重同步、4 通道、clear |

想扩测试，按代价从低到高：

1. **组包 / 解析**：纯函数，直接加用例；
2. **设置持久化**：`SharedPreferences.setMockInitialValues({})` 就能测，不需要真蓝牙；
3. **页面 widget 测试**：要给 `BleController` 做假实现，成本最高，优先级最低。

改过组包或解析逻辑，至少跑一遍 `flutter test` 再提交。

---

## 8. 代码约定

- 私有成员 `_` 前缀；异步错误统一 `_log(..., LogKind.error)` + `_friendly(e)`，不给 UI 抛原始异常；
- 对外异常只用 `BleAppException`；
- 页面不直接访问 controller 私有状态，只读 getter；
- 新增状态记得链路：字段 → getter → `_notify()` → 是否需要持久化；
- 颜色只从 `theme.dart` 的 `AppColors` 取，不要在页面写死色值。
