# 文档目录

本目录放的是「给人看」的文档。项目总览、使用说明、协议格式这些都在仓库根的 [README.md](../README.md) 里，这里只补充开发与发布相关的内容。

| 文档 | 内容 | 适合谁看 |
| --- | --- | --- |
| [README.md](../README.md) | 项目介绍、界面截图、完整使用说明（设备 / 数据 / 控件三页）、整包与独立指令的解包方法、权限说明 | 使用者、要对接固件的人 |
| [dev-guide.md](dev-guide.md) | 继续开发指南：代码结构、BleController 怎么运转、设置怎么保存、常见改法（加控件 / 改模板 / 加协议）、坑与调试方法 | 接手或二次开发的人 |
| [release-notes/v3.0.1.md](release-notes/v3.0.1.md) | v3.0.1 发布正文：修复重进 App 搜不到设备、启动自动连接上次设备 | 下载 APK 的人 |
| [release-notes/v3.0.0.md](release-notes/v3.0.0.md) | v3.0.0 发布正文（安装方法 + 上手三分钟 + 协议速查） | 下载 APK 的人 |
| [screenshots/](screenshots/) | 界面截图，README 里引用的原图 | 写文档的人 |

## 改文档的约定

- README 是**面向使用者**的，讲「怎么用、发什么数据」，不放内部实现细节。
- `dev-guide.md` 是**面向开发者**的，讲「代码在哪、改哪里、为什么这么写」。
- 每发一个版本，在 `release-notes/` 下新增 `vX.Y.Z.md`，内容直接粘到 GitHub Release 正文里。
- 截图更新后同步替换 `screenshots/` 里的文件，保持文件名不变，README 不用改。
