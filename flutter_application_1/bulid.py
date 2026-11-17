import subprocess
import sys
from pathlib import Path

# 自动获取当前脚本所在目录
PROJECT_DIR = Path(__file__).resolve().parent

def main():
    if not (PROJECT_DIR / "pubspec.yaml").exists():
        print("错误：找不到 pubspec.yaml，不是 Flutter 工程目录")
        sys.exit(1)

    print(f"工程目录：{PROJECT_DIR}")
    print("开始编译 Android APK...\n")

    # 使用本地 PowerShell 执行 Flutter 命令
    command = (
        "D:\\flutter\\bin\\flutter.bat build apk --release"
    )

    result = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-Command", command
        ],
        cwd=str(PROJECT_DIR)
    )

    if result.returncode != 0:
        print("\nAPK 编译失败！")
        sys.exit(result.returncode)

    apk = PROJECT_DIR / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"

    if apk.exists():
        print(f"\n编译成功：{apk}")
        subprocess.run(["explorer.exe", str(apk.parent)])
    else:
        print("\n未找到 APK 文件")


if __name__ == "__main__":
    main()