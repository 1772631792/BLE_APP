"""一键打包：先把 图标.png 同步成 Android 启动图标，再编译 APK。

用法：
    python build.py
"""

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

# 图标源，按顺序找第一个存在的
ICON_SOURCES = (
    PROJECT_DIR / "图标.png",
    PROJECT_DIR.parent / "图标.png",
    PROJECT_DIR / "assets" / "icon.png",
)

# Android 各密度启动图标的边长（dp）
MIPMAP_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}


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


def find_icon_source() -> Path | None:
    for path in ICON_SOURCES:
        if path.is_file():
            return path
    return None


def sync_icons() -> None:
    """把 图标.png 转成 mipmap 各密度 PNG（Android 不认 .ico）。

    原图卡片外的四角是纯黑背景，从四角泛洪成透明并内缩 2px，
    缩小后才不会出现黑角 / 黑边。
    """
    source = find_icon_source()
    if source is None:
        print("提示：没找到 图标.png，跳过图标更新，沿用现有 res/mipmap 图标\n")
        return

    try:
        from PIL import Image, ImageDraw, ImageFilter
    except ImportError:
        print("提示：没装 Pillow，跳过图标更新（pip install pillow）\n")
        return

    print(f"更新应用图标：{source}")

    base = Image.open(source).convert("RGBA")
    side = min(base.size)
    if base.size != (side, side):
        left = (base.width - side) // 2
        top = (base.height - side) // 2
        base = base.crop((left, top, left + side, top + side))

    icon = base.copy()
    width, height = icon.size
    for corner in ((0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)):
        ImageDraw.floodfill(icon, corner, (0, 0, 0, 0), thresh=60)

    red, green, blue, alpha = icon.split()
    icon = Image.merge("RGBA", (red, green, blue, alpha.filter(ImageFilter.MinFilter(5))))

    res_dir = PROJECT_DIR / "android" / "app" / "src" / "main" / "res"
    for density, px in MIPMAP_SIZES.items():
        target = res_dir / f"mipmap-{density}" / "ic_launcher.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        icon.resize((px, px), Image.LANCZOS).save(target, optimize=True)
        print(f"  mipmap-{density}/ic_launcher.png  {px}x{px}")

    ico = source.with_suffix(".ico")
    icon.save(
        ico,
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print(f"  同时导出 {ico}\n")


def main() -> None:
    if not (PROJECT_DIR / "pubspec.yaml").exists():
        print("错误：找不到 pubspec.yaml，不是 Flutter 工程目录")
        sys.exit(1)

    flutter = FLUTTER if Path(FLUTTER).exists() else "flutter"

    print(f"工程目录：{PROJECT_DIR}")
    print(f"版本号：{read_version()}")

    sync_icons()

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
