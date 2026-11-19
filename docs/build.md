# 构建、打包与发布

## 1. 环境要求

| 项 | 版本 |
| --- | --- |
| Flutter | 3.47.1（stable）/ Dart 3.13.1 |
| JDK | 17（`android/app/build.gradle.kts` 里锁定） |
| Android SDK | platform-tools + build-tools，compileSdk 跟随 Flutter |
| Python | 3.x（仅 `build.py` 需要，装 Pillow 可顺带生成图标） |

检查环境：

```bash
flutter doctor -v
```

Android toolchain 一项必须是 `✓`。

首次拉依赖：

```bash
cd flutter_application_1
flutter pub get
```

---

## 2. 打包

### 2.1 一键脚本（推荐）

```bash
cd flutter_application_1
python build.py
```

脚本做四件事：

1. 把 `图标.png` 转成 5 档 `res/mipmap-*/ic_launcher.png`，并导出 `图标.ico`（没装 Pillow 或没图时跳过）；
2. 从 `pubspec.yaml` 读版本号（`3.0.1+10` → `3.0.1`）；
3. 执行 `flutter build apk --release`；
4. 复制成 `dist/BLEStudio-v{版本}-{日期}.apk` 并打开目录。

可改的配置在脚本顶部：

| 变量 | 作用 | 默认 |
| --- | --- | --- |
| `APP_NAME` | 产物文件名前缀 | `BLEStudio` |
| `FLUTTER` | flutter 可执行文件 | `D:\flutter\bin\flutter.bat`（不存在则用 PATH） |
| `DIST_DIR` | 产物目录 | `dist` |

### 2.2 手动命令

```bash
flutter build apk --release     # 正式包
flutter build apk --split-per-abi   # 按 ABI 拆分，体积更小
flutter run --release           # 真机跑正式包
```

| 类型 | 路径 |
| --- | --- |
| release | `build/app/outputs/flutter-apk/app-release.apk` |
| debug | `build/app/outputs/flutter-apk/app-debug.apk` |

### 2.3 安装

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

或把 APK 传到手机点击安装（需允许「安装未知来源应用」）。

---

## 3. 版本号与签名

- 版本号只在 `pubspec.yaml`：`version: 3.0.1+10`，`3.0.1` 是 versionName，`10` 是 versionCode；
- **versionCode 必须递增**，否则覆盖安装会被系统拒绝；
- 目前 release 用 debug 签名（`build.gradle.kts` 里 `signingConfig = signingConfigs.getByName("debug")`），只能自己分发；
- 上架应用商店要自己生成 keystore，配置 `signingConfigs`，再 `flutter build appbundle`。

---

## 4. 发版流程

1. 改 `pubspec.yaml` 版本号（name 和 build 号都动）；
2. 更新 `README.md` 的「更新日志」；
3. 新增 `docs/release-notes/vX.Y.Z.md`（Release 正文直接用它）；
4. `python build.py`，确认 `dist/` 里产物；
5. 提交并推送：
   ```bash
   git add -A
   git commit -m "feat(...): ... (vX.Y.Z)"
   git push origin main
   git tag -a vX.Y.Z -m "BLE Studio vX.Y.Z"
   git push origin vX.Y.Z
   ```
6. GitHub → Releases → Draft a new release → 选 tag → 标题 `BLE Studio vX.Y.Z` → 正文粘贴 release notes → 拖入 APK → 发布。

> 仓库的 `.gitignore` 已排除 `dist/`，APK 不会进 Git，只作为 Release 附件。

### 4.1 用命令行发布（可选）

有 GitHub CLI 时：

```bash
gh release create v3.0.1 dist/BLEStudio-v3.0.1-20261118.apk \
  --title "BLE Studio v3.0.1" \
  --notes-file docs/release-notes/v3.0.1.md
```

没有 `gh` 时也可以走 REST API。**注意 `uploads.github.com` 的网络问题**：

- 走 HTTP 代理（如 `127.0.0.1:7897`）时，`CONNECT` 能建立但 TLS 握手会超时；
- 同一端口换成 SOCKS5 正常：

```bash
curl --http1.1 -x socks5h://127.0.0.1:7897 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/vnd.android.package-archive" \
  -H "Expect:" \
  --data-binary @dist/BLEStudio-v3.0.1-20261118.apk \
  "https://uploads.github.com/repos/<owner>/<repo>/releases/<id>/assets?name=BLEStudio-v3.0.1.apk"
```

---

## 5. 构建排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `Could not close incremental caches` / `different roots: C:\Users\...\Pub\Cache` | Pub 缓存在 C 盘、工程在 D 盘，Kotlin 增量编译无法跨盘算相对路径 | `android/gradle.properties` 里已写 `kotlin.incremental=false`，别删 |
| 首次构建卡在下载依赖 | Gradle / Maven 需要代理 | `android/gradle.properties` 加 `systemProp.http(s).proxyHost/Port`，然后 `./gradlew --stop` |
| `Unsupported class file major version` | JDK 版本不对 | 换 JDK 17 |
| `Flutter not found` | PATH 里没有 flutter | 加 PATH 或改 `build.py` 的 `FLUTTER` |
| 覆盖安装失败 | versionCode 没加，或签名变了 | 递增 build 号；改了签名先卸载 |
| 图标没变 | 没跑 `build.py`，或缺 Pillow | `pip install pillow` 后重跑 |
| 改了包名后装不上 | `applicationId` 变了等于新应用 | 属于正常现象，不能覆盖旧版 |

真机蓝牙相关功能（扫描、连接、波形）必须真机测试，模拟器没有 BLE。
