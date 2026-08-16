param(
    [switch]$Version,
    [switch]$Clean,
    [string[]]$AbiFilters = @("arm64-v8a")
)

$ErrorActionPreference = "Stop"

$script:SdkVersion = "0.1.0"
$RUST_PROJECT_DIR = ".\rustlib"
$ANDROID_MODULE_JNI_DIR = ".\sdk\src\main\jniLibs"
$AAR_SOURCE = ".\sdk\build\outputs\aar\sdk-release.aar"
$OUTPUT_DIR = ".\output"

# -------------------------------------------
# 显示版本号
# -------------------------------------------
if ($Version) {
    Write-Host "TurboLog publish script version: $script:SdkVersion" -ForegroundColor Cyan
    exit 0
}

# -------------------------------------------
# 先决条件检查
# -------------------------------------------
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TurboLog - 检查构建环境先决条件..." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$hasError = $false

# 检查 cargo
try {
    $cargoExists = Get-Command cargo -ErrorAction Stop
    Write-Host "  [OK] cargo 已就绪: $($cargoExists.Source)" -ForegroundColor Green
} catch {
    Write-Host "  [错误] 未找到 cargo 命令，请安装 Rust 工具链 (https://rustup.rs)" -ForegroundColor Red
    $hasError = $true
}

# 检查 cargo ndk
try {
    cargo ndk --help 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] cargo ndk 已安装" -ForegroundColor Green
    } else {
        throw "cargo ndk not found"
    }
} catch {
    Write-Host "  [错误] 未找到 cargo ndk 插件，请执行: cargo install cargo-ndk" -ForegroundColor Red
    $hasError = $true
}

# 检查 gradlew.bat
if (Test-Path ".\gradlew.bat") {
    Write-Host "  [OK] gradlew.bat 已就绪" -ForegroundColor Green
} else {
    Write-Host "  [错误] 未找到 gradlew.bat，请确认当前目录为 Android 项目根目录" -ForegroundColor Red
    $hasError = $true
}

if ($hasError) {
    Write-Host ""
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "  先决条件检查未通过，请修复上述错误后重试。" -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    exit 1
}

Write-Host ""

# -------------------------------------------
# 清理（如果指定了 -Clean）
# -------------------------------------------
if ($Clean) {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  正在清理之前的构建产物..." -ForegroundColor Yellow

    if (Test-Path $RUST_PROJECT_DIR) {
        Push-Location $RUST_PROJECT_DIR
        cargo clean
        Pop-Location
    }

    if (Test-Path $ANDROID_MODULE_JNI_DIR) {
        Remove-Item -Path $ANDROID_MODULE_JNI_DIR -Recurse -Force
    }

    if (Test-Path $OUTPUT_DIR) {
        Remove-Item -Path $OUTPUT_DIR -Recurse -Force
    }

    Write-Host "  清理完成！" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host ""
}

# -------------------------------------------
# 主构建流程
# -------------------------------------------
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TurboLog 全自动流水线编译 (Windows PowerShell)..." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# ABI -> cargo ndk target 映射
$abiTargetMap = @{
    "arm64-v8a"   = "aarch64-linux-android"
    "armeabi-v7a" = "armv7-linux-androideabi"
    "x86_64"      = "x86_64-linux-android"
    "x86"         = "i686-linux-android"
}

# 解析 ABI 列表
$abiList = ($AbiFilters | Where-Object { $_ }) | Select-Object -Unique
if ($abiList.Count -eq 0) { $abiList = @("arm64-v8a") }

# 校验 ABI 合法性
$unknownAbis = $abiList | Where-Object { -not $abiTargetMap.ContainsKey($_) }
if ($unknownAbis) {
    Write-Host "[错误] 不支持的 ABI: $($unknownAbis -join ', ')。支持的 ABI: $($abiTargetMap.Keys -join ', ')" -ForegroundColor Red
    exit 1
}

# [1/4] cargo ndk 交叉编译
Write-Host "[1/4] 正在使用 cargo ndk 交叉编译 $($abiList -join '/') 动态库..." -ForegroundColor Yellow
Push-Location $RUST_PROJECT_DIR

foreach ($abi in $abiList) {
    $target = $abiTargetMap[$abi]
    cargo ndk --target $target --platform 29 build --release
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[错误] $abi 编译失败" -ForegroundColor Red
        Pop-Location
        exit 1
    }
}

Pop-Location

# [2/4] 分发动态库
Write-Host "[2/4] 正在分发动态库至 Android SDK 组件目录..." -ForegroundColor Yellow

if (Test-Path $ANDROID_MODULE_JNI_DIR) {
    Remove-Item -Path $ANDROID_MODULE_JNI_DIR -Recurse -Force
}

foreach ($abi in $abiList) {
    $target = $abiTargetMap[$abi]
    New-Item -ItemType Directory -Path "$ANDROID_MODULE_JNI_DIR\$abi" -Force | Out-Null
    Copy-Item "$RUST_PROJECT_DIR\target\$target\release\libturbolog_sdk.so" "$ANDROID_MODULE_JNI_DIR\$abi\"
}

# [3/4] Gradle 构建
Write-Host "[3/4] 正在通过 Gradle 构建统一发布构件 turbolog-sdk.aar..." -ForegroundColor Yellow
.\gradlew.bat :sdk:assembleRelease

if ($LASTEXITCODE -ne 0) {
    Write-Host "[错误] Gradle 构建失败" -ForegroundColor Red
    exit 1
}

# [4/4] 本地发布
Write-Host "[4/4] 正在准备本地发布包..." -ForegroundColor Yellow

# 创建输出目录
if (-not (Test-Path $OUTPUT_DIR)) {
    New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null
}

# 拷贝并重命名 AAR
$outputFile = "$OUTPUT_DIR\turbolog-sdk-$script:SdkVersion.aar"
Copy-Item $AAR_SOURCE $outputFile -Force

# 获取文件大小
$fileSize = (Get-Item $outputFile).Length
if ($fileSize -ge 1MB) {
    $fileSizeStr = "{0:N2} MB" -f ($fileSize / 1MB)
} else {
    $fileSizeStr = "{0:N2} KB" -f ($fileSize / 1KB)
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  TurboLog 构建完毕！" -ForegroundColor Green
Write-Host "  版本: $script:SdkVersion" -ForegroundColor Green
Write-Host "  产物: $outputFile" -ForegroundColor Green
Write-Host "  大小: $fileSizeStr" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green