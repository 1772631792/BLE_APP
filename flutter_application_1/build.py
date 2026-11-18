import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# 自动获取当前脚本所在目录
PROJECT_DIR = Path(__file__).resolve().parent

# 打包产物用的名字（可随意改）
APP_NAME = "BLEStudio"

# Flutter 可执行文件，留空则用 PATH 里的 flutter
FLUTTER = r"D:\flutter\bin\flutter.bat"

# 产物输出目录（相对工程根目录）
DIST_DIR = "dist"


def read_version() -> str:
    """从 pubspec.yaml 读取版本号，例如 1.0.0+1 -> 1.0.0"""
    try:
        text = (PROJECT_DIR / "pubspec.yaml").read_text(encoding="utf-8")
    except OSError:
        return "0.0.0"
    match = re.search(r"^version:\s*([^\s#]+)", text, re.MULTILINE)
    if not match:
        return "0.0.0"
    return match.group(1).split("+")[0]


def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}GB"


def main() -> None:
    if not (PROJECT_DIR / "pubspec.yaml").exists():
        print("错误：找不到 pubspec.yaml，不是 Flutter 工程目录")
        sys.exit(1)

    flutter = FLUTTER if Path(FLUTTER).exists() else "flutter"

    print(f"工程目录：{PROJECT_DIR}")
    print(f"版本号：{read_version()}")
    print("开始编译 Android APK...\n")

    result = subprocess.run(
        [flutter, "build", "apk", "--release"],
        cwd=str(PROJECT_DIR),
    )
    if result.returncode != 0:
        print("\nAPK 编译失败！")
        sys.exit(result.returncode)

    apk = PROJECT_DIR / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
    if not apk.exists():
        print("\n未找到 APK 文件")
        sys.exit(1)

    # 复制成带版本和日期的名字，方便区分和发给别人
    version = read_version()
    stamp = datetime.now().strftime("%Y%m%d")
    dist_dir = PROJECT_DIR / DIST_DIR
    dist_dir.mkdir(parents=True, exist_ok=True)
    target = dist_dir / f"{APP_NAME}-v{version}-{stamp}.apk"
    shutil.copy2(apk, target)

    print(f"\n编译成功：{target}")
    print(f"文件大小：{human_size(target.stat().st_size)}")
    print(f"原始产物：{apk}")
    subprocess.run(["explorer.exe", str(dist_dir)])


if __name__ == "__main__":
    main()
