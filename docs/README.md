# 文档目录

项目总览和使用说明在仓库根的 [README.md](../README.md)；这里是补充文档，按「结构 → 开发 → 协议 → 构建 → 排障」组织。

---

## 1. 文档目录

| 编号 | 文档 | 内容 | 适合谁 |
| --- | --- | --- | --- |
| — | [README.md](../README.md) | 项目介绍、界面截图、三页完整使用说明、权限说明、更新日志 | 使用者、要对接固件的人 |
| 2 | [code-structure.md](code-structure.md) | **代码结构**：目录树、分层依赖、`BleController` 状态机、页面组成、数据流、测试与命名约定 | 接手 / 二次开发 |
| 3 | [dev-guide.md](dev-guide.md) | **继续开发**：加控件、改整包模板、加协议、改重连策略，以及打包踩坑 | 改功能的人 |
| 4 | [protocol.md](protocol.md) | **协议与固件对接**：整包 11 字节字段表、独立指令、开关式按键、JustFloat、MTU 限制 | 写固件的人 |
| 5 | [build.md](build.md) | **构建与发布**：环境、`build.py`、签名、发版流程、命令行发 Release | 打包 / 发版的人 |
| 6 | [faq.md](faq.md) | **常见问题**：扫不到、连不上、波形不出、控件没反应、权限、安装失败 | 所有人 |
| 7 | [release-notes/](release-notes/) | 各版本 Release 正文 | 看更新内容的人 |
| 8 | [screenshots/](screenshots/) | 界面截图，README 引用的原图 | 写文档的人 |

---

## 2. 代码结构

一句话：**所有状态在一个 `BleController` 里，页面只负责画和调方法；协议与解析是独立纯逻辑模块。**

```text
表现层   main.dart / pages/* / services_view.dart / widgets.dart / theme.dart
   │  只读 getter、只调方法
状态层   ble_controller.dart（ChangeNotifier）
   │
   ├── control_packet.dart   整包模板 → 字节（纯函数，有单测）
   └── wave.dart             JustFloat 字节 → 帧 → 绘制
```

细节（每个文件职责、方法清单、状态机、数据流）见 [code-structure.md](code-structure.md)。

---

## 3. 继续开发

常见改动的落点：

| 想做什么 | 看哪里 |
| --- | --- |
| 加控件 / 加通道 | [dev-guide.md · 常见改法](dev-guide.md#3-常见改法照着抄) |
| 改整包默认模板 | `ble_controller.dart` 的默认模板字段 + [protocol.md](protocol.md) |
| 加一种新协议 | [dev-guide.md · 加一种新协议](dev-guide.md#c-加一种新协议比如文本-csv-以外的格式) |
| 改断线重连策略 | `_scheduleReconnect()`，注意 `_generation` |
| 改启动自动连接 | `_connectLastOnLaunch()` / `connectLastDevice()` |

---

## 4. 协议

固件侧只需要看 [protocol.md](protocol.md)：

- 整包默认 11 字节：`AA 55 {x} {y} {s1} {s2} {tx} {ty} {btn} 55 AA`；
- 独立指令默认值：摇杆 / 滑条 / 搓动 / 按键；
- 开关式按键的翻转语义；
- JustFloat 波形格式；
- MTU 与包长上限。

---

## 5. 构建与发布

见 [build.md](build.md)。最短路径：

```bash
cd flutter_application_1
python build.py          # 产出 dist/BLEStudio-vX.Y.Z-YYYYMMDD.apk
```

发版前记得改 `pubspec.yaml` 的 version（build 号必须递增）、更新 README 更新日志、新增 `release-notes/vX.Y.Z.md`。

---

## 6. 排障

见 [faq.md](faq.md)。最高频的三类：

1. **扫不到设备** → 设备是否在广播 / 是否被旧连接卡住；
2. **连上没数据** → TX / RX 是否选对、通知是否开启；
3. **控件没反应** → 发送模式是否和固件一致、MTU 是否够。

---

## 7. 版本记录

| 版本 | 内容 |
| --- | --- |
| [v3.0.1](release-notes/v3.0.1.md) | 启动自动连接上次设备、修复重进 App 搜不到；连上后改为进控件页 |
| [v3.0.0](release-notes/v3.0.0.md) | 滑条 A/B 回归、搓动独立 `tx`/`ty` 通道、整包 11 字节 |

---

## 8. 截图

`docs/screenshots/` 下三张图，README 直接引用：

| 文件 | 内容 |
| --- | --- |
| `01-controls-page.jpg` | 控件页（页内布局） |
| `02-fullscreen-scrub.jpg` | 全屏手柄布局 + 搓动轨迹 |
| `03-command-editor.jpg` | 指令编辑弹窗 |

---

## 维护约定

- **使用者向**的内容放根 `README.md`：怎么装、怎么连、发什么数据；
- **开发者向**的内容放这里：代码在哪、怎么改、为什么这么写；
- 每个版本在 `release-notes/` 新增 `vX.Y.Z.md`，正文可直接粘到 GitHub Release；
- 截图更新后覆盖同名文件，README 不用改；
- 文档里引用代码位置时写**方法名**，不要写行号（代码一改行号就失效）。
