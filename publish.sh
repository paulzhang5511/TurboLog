#!/bin/bash
set -e

RUST_PROJECT_DIR="./rustlib"
ANDROID_MODULE_JNI_DIR="./sdk/src/main/jniLibs"
AAR_SOURCE="./sdk/build/outputs/aar/sdk-release.aar"
OUTPUT_DIR="./output"
SDK_VERSION="1.0.0"

# ---------- 参数解析 ----------
DO_CLEAN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            echo "TurboLog SDK version: ${SDK_VERSION}"
            exit 0
            ;;
        --clean)
            DO_CLEAN=true
            shift
            ;;
        *)
            echo "❌ 未知参数: $1"
            echo "用法: $0 [--version] [--clean]"
            exit 1
            ;;
    esac
done

# ---------- 先决条件检查 ----------
echo "🔍 正在检查构建环境..."

if ! command -v cargo &>/dev/null; then
    echo "❌ 错误: 未找到 'cargo' 命令，请先安装 Rust 工具链。"
    echo "   安装指引: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    exit 1
fi

if ! cargo ndk --help &>/dev/null; then
    echo "❌ 错误: 未找到 'cargo ndk' 插件，请先安装。"
    echo "   安装命令: cargo install cargo-ndk"
    exit 1
fi

if [[ ! -x "./gradlew" ]]; then
    echo "❌ 错误: 未找到可执行的 './gradlew'，请确认当前目录为 Android 项目根目录。"
    exit 1
fi

echo "✅ 构建环境检查通过。"

# ---------- 清理 ----------
if $DO_CLEAN; then
    echo "🧹 正在清理构建产物..."
    ./gradlew clean
    rm -rf "$ANDROID_MODULE_JNI_DIR"
    echo "✅ 清理完成。"
fi

echo "=========================================================="
echo " 🛠️  TurboLog 全自动流水线编译 (macOS/Linux)..."
echo "=========================================================="

# 1. 使用 cargo ndk 进行多 CPU 架构的自动化交叉构建
echo "[1/4] 正在使用 cargo ndk 交叉编译 arm64-v8a/armeabi-v7a/x86_64 动态库..."
pushd "$RUST_PROJECT_DIR" > /dev/null

cargo ndk --target aarch64-linux-android --platform 29 build --release
cargo ndk --target armv7-linux-androideabi --platform 29 build --release
cargo ndk --target x86_64-linux-android --platform 29 build --release

popd > /dev/null

# 2. 清理历史文件，将编译生成的各个 .so 分发至 AAR 内部对应的 JNI 目录中
echo "[2/4] 正在分发动态库至 Android SDK 组件目录..."

rm -rf "$ANDROID_MODULE_JNI_DIR"
mkdir -p "$ANDROID_MODULE_JNI_DIR/arm64-v8a"
mkdir -p "$ANDROID_MODULE_JNI_DIR/armeabi-v7a"
mkdir -p "$ANDROID_MODULE_JNI_DIR/x86_64"

cp "$RUST_PROJECT_DIR/target/aarch64-linux-android/release/libturbolog_sdk.so" "$ANDROID_MODULE_JNI_DIR/arm64-v8a/"
cp "$RUST_PROJECT_DIR/target/armv7-linux-androideabi/release/libturbolog_sdk.so" "$ANDROID_MODULE_JNI_DIR/armeabi-v7a/"
cp "$RUST_PROJECT_DIR/target/x86_64-linux-android/release/libturbolog_sdk.so" "$ANDROID_MODULE_JNI_DIR/x86_64/"

# 3. 驱动 Gradle 打包自包含的公共 SDK 产物
echo "[3/4] 正在通过 Gradle 构建统一发布构件 turbolog-sdk.aar..."
./gradlew :sdk:assembleRelease

# 4. 本地发布
echo "[4/4] 正在发布到本地输出目录..."

mkdir -p "$OUTPUT_DIR"
OUTPUT_AAR="$OUTPUT_DIR/turbolog-sdk-${SDK_VERSION}.aar"

cp "$AAR_SOURCE" "$OUTPUT_AAR"

AAR_SIZE=$(ls -lh "$OUTPUT_AAR" | awk '{print $5}')

echo "=========================================================="
echo " 🎉 TurboLog 构建完毕！"
echo " 📦 发布文件: ${OUTPUT_AAR}"
echo " 📏 文件大小: ${AAR_SIZE}"
echo " 🏷️  版本号:   ${SDK_VERSION}"
echo "=========================================================="