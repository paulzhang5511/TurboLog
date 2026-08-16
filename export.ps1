# TurboLog 日志导出脚本 (Windows PowerShell)
# 用法: .\export_rlog.ps1 -Package <包名> [-Action pull|delete|both] [-OutputDir <本地目录>]

param(
    [Parameter(Mandatory=$true)]
    [string]$Package,

    [ValidateSet("pull", "delete", "both")]
    [string]$Action = "both",

    [string]$OutputDir = ".\turbolog_export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

$ErrorActionPreference = "Stop"

# 设备上的日志根目录（对应代码中的 context.cacheDir + "/turbolog"）
$REMOTE_BASE = "/data/data/$Package/cache/turbolog"

# TurboLog 日志目录下的文件命名前缀（与 Rust 侧 LOG_FILE_PREFIX 对齐）
$LOG_FILE_PREFIX = "turbolog.log"
$REMOTE_ZIP = "$REMOTE_BASE/$LOG_FILE_PREFIX"

Write-Host "=== TurboLog Export Tool ===" -ForegroundColor Cyan
Write-Host "Package   : $Package"
Write-Host "Remote    : $REMOTE_BASE"
Write-Host "Log File  : $LOG_FILE_PREFIX"
Write-Host "Action    : $Action"
if ($Action -ne "delete") {
    Write-Host "Output    : $OutputDir"
}
Write-Host ""

# 检查 adb 是否可用
try {
    $null = adb version 2>&1
} catch {
    Write-Error "adb not found. Please add adb to PATH."
    exit 1
}

# 检查设备连接
$devices = adb devices | Select-String -Pattern "^\S+\s+device$"
if (-not $devices) {
    Write-Error "No adb device connected."
    exit 1
}

# 检查远端日志目录是否存在
Write-Host "Checking remote log dir: $REMOTE_BASE ..." -ForegroundColor Yellow
$dirCheck = adb shell "ls '$REMOTE_BASE' 2>/dev/null" 2>&1
if ($dirCheck -match "No such file|cannot access") {
    Write-Warning "Remote log dir not found: $REMOTE_BASE"
    Write-Warning "Please call TurboLog.init(context) in the app first, then re-run this script."
    exit 0
}

# ── PULL ──────────────────────────────────────────────────────────────────────
if ($Action -eq "pull" -or $Action -eq "both") {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    Write-Host "Pulling $REMOTE_BASE ..." -ForegroundColor Green
    # 拉取整个 turbolog 目录（包含当前活动文件和历史归档）
    adb pull $REMOTE_BASE $OutputDir | Out-Null

    $localDir = Join-Path $OutputDir "turbolog"
    if (Test-Path $localDir) {
        $files = Get-ChildItem -Path $localDir -File
        $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
        Write-Host "Pull complete: $localDir ($($files.Count) files, $totalSize bytes)" -ForegroundColor Green
    } else {
        Write-Error "Pull failed: $localDir not found after adb pull."
        exit 1
    }
}

# ── DELETE ────────────────────────────────────────────────────────────────────
if ($Action -eq "delete" -or $Action -eq "both") {
    Write-Host ""
    Write-Host "Deleting remote log dir: $REMOTE_BASE ..." -ForegroundColor Yellow
    # 调用 TurboLog.clearLogs() 的等价 adb 操作：删除历史归档 + 截断当前文件
    # 注意：直接删除目录会破坏 Rust 侧持有的文件句柄，这里仅清理历史归档文件
    adb shell "find '$REMOTE_BASE' -name '$LOG_FILE_PREFIX.*' -delete 2>/dev/null; echo done" | Out-Null
    Write-Host "Delete complete (archived files removed, active file preserved)." -ForegroundColor Green
}
