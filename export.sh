#!/usr/bin/env bash
# TurboLog 日志导出脚本 (macOS / Linux)
# 用法: ./export_rlog.sh -p <包名> [-a pull|delete|both] [-o <本地目录>]

set -euo pipefail

# ── 默认参数 ──────────────────────────────────────────────────────────────────
PACKAGE=""
ACTION="both"
OUTPUT_DIR=""

usage() {
    echo "Usage: $0 -p <package_name> [-a pull|delete|both] [-o <output_dir>]"
    echo "  -p  Android 应用包名（必填），如 com.example.app"
    echo "  -a  操作类型：pull / delete / both（默认 both）"
    echo "  -o  本地输出目录（默认 ./turbolog_export_<timestamp>）"
    exit 1
}

while getopts "p:a:o:h" opt; do
    case $opt in
        p) PACKAGE="$OPTARG" ;;
        a) ACTION="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$PACKAGE" ]]; then
    echo "Error: -p <package_name> is required."
    usage
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="./turbolog_export_$(date +%Y%m%d_%H%M%S)"
fi

# 设备上的日志根目录（对应代码中的 context.cacheDir + "/turbolog"）
REMOTE_BASE="/data/data/${PACKAGE}/cache/turbolog"

# TurboLog 日志目录下的文件命名前缀（与 Rust 侧 LOG_FILE_PREFIX 对齐）
LOG_FILE_PREFIX="turbolog.log"

echo "=== TurboLog Export Tool ==="
echo "Package   : $PACKAGE"
echo "Remote    : $REMOTE_BASE"
echo "Log File  : $LOG_FILE_PREFIX"
echo "Action    : $ACTION"
[[ "$ACTION" != "delete" ]] && echo "Output    : $OUTPUT_DIR"
echo ""

# ── 前置检查 ──────────────────────────────────────────────────────────────────
if ! command -v adb &>/dev/null; then
    echo "Error: adb not found. Please add adb to PATH." >&2
    exit 1
fi

if ! adb devices | grep -qE "^\S+\s+device$"; then
    echo "Error: No adb device connected." >&2
    exit 1
fi

# 检查远端日志目录是否存在
echo "Checking remote log dir: $REMOTE_BASE ..."
if ! adb shell "ls '$REMOTE_BASE'" &>/dev/null; then
    echo "Warning: Remote log dir not found: $REMOTE_BASE"
    echo "Please call TurboLog.init(context) in the app first, then re-run this script."
    exit 0
fi

# ── PULL ──────────────────────────────────────────────────────────────────────
do_pull() {
    mkdir -p "$OUTPUT_DIR"

    echo "Pulling $REMOTE_BASE ..."
    # 拉取整个 turbolog 目录（包含当前活动文件和历史归档）
    adb pull "$REMOTE_BASE" "$OUTPUT_DIR/" >/dev/null

    LOCAL_DIR="$OUTPUT_DIR/turbolog"
    if [[ -d "$LOCAL_DIR" ]]; then
        FILE_COUNT=$(find "$LOCAL_DIR" -type f | wc -l)
        TOTAL_SIZE=$(du -sb "$LOCAL_DIR" | awk '{print $1}')
        echo "Pull complete: $LOCAL_DIR ($FILE_COUNT files, $TOTAL_SIZE bytes)"
    else
        echo "Error: Pull failed, $LOCAL_DIR not found." >&2
        exit 1
    fi
}

# ── DELETE ────────────────────────────────────────────────────────────────────
do_delete() {
    echo ""
    echo "Deleting remote log dir: $REMOTE_BASE ..."
    # 调用 TurboLog.clearLogs() 的等价 adb 操作：删除历史归档 + 截断当前文件
    # 注意：直接删除目录会破坏 Rust 侧持有的文件句柄，这里仅清理历史归档文件
    adb shell "find '$REMOTE_BASE' -name '$LOG_FILE_PREFIX.*' -delete 2>/dev/null || true"
    echo "Delete complete (archived files removed, active file preserved)."
}

# ── 执行 ──────────────────────────────────────────────────────────────────────
case "$ACTION" in
    pull)   do_pull ;;
    delete) do_delete ;;
    both)   do_pull; do_delete ;;
    *)
        echo "Error: Invalid action '$ACTION'. Use pull / delete / both." >&2
        exit 1
        ;;
esac
