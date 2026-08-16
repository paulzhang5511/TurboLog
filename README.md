# TurboLog —— 高性能 Android 日志 SDK

> 基于 **Rust + tracing** 生态构建，专为 Android 生产环境设计的日志组件。
> 业务线程写日志异步非阻塞，崩溃时 panic hook 自动刷盘，按天轮转不膨胀。

---

## 为什么需要 TurboLog？

| 场景                   | 系统 Logcat           | TurboLog                  |
| ---------------------- | --------------------- | ------------------------- |
| 进程崩溃后日志是否保留 | ❌ 内存丢失           | ✅ panic hook 强制刷盘    |
| 日志能否持久化到文件   | ❌ 需自行实现         | ✅ 按天自动滚动 .log 文件 |
| 写入对主线程的影响     | 同步写入              | ✅ 异步 RingBuffer，微秒级返回 |
| 日志清理安全性         | ❌ 需自行实现         | ✅ 截断当前文件，删除历史归档 |
| 动态 Tag 过滤          | ❌ 无                 | ✅ Kotlin 层零开销拦截    |

---

## 核心特性

**异步非阻塞**
业务线程调用 `TurboLog.d()` 只是向 `tracing-appender` 的 RingBuffer 投递一条事件，实际的格式化和磁盘写入由独立后台线程完成，不阻塞主线程和 UI。

**崩溃安全**
Rust 端注册 panic hook，发生未捕获崩溃时自动写入 `tracing::error!` 并强制 flush，确保崩溃现场不丢失。

**按天轮转**
使用 `tracing-appender::rolling::daily` 自动按天生成归档文件（如 `turbolog.log.2026-08-13`），单文件不会无限膨胀。

**Tag 过滤前置**
Tag 过滤逻辑在 Kotlin 端 `TurboLog.log()` 中执行，不匹配的 Tag 直接 `return`，完全不触发 JNI 调用，零 FFI 开销。

**安全清理**
`clearLogs()` 对当前活动文件执行截断（`set_len(0)`）而非删除，避免破坏写入句柄导致日志丢失。

---

## 架构概览

```
业务线程 (Kotlin)
    │
    │  TurboLog.d("tag", "msg")          ← Tag 过滤在 Kotlin 层，不匹配直接 return
    │
    ▼
JNI 边界 (Rust / jni 0.22)
    │  解构 JString → Rust String
    │  write_log_event(level, tag, msg)
    ▼
tracing 管道
    │  tracing::info!/debug!/error! 等宏
    ▼
tracing-subscriber (fmt layer)
    │  格式化：时间戳、线程ID、级别、消息
    ▼
tracing-appender (Non-blocking)
    │  RingBuffer 无锁队列 → 后台 Worker 线程
    ▼
磁盘文件
    {cacheDir}/turbolog/
    ├── turbolog.log                      ← 当前活动日志
    ├── turbolog.log.2026-08-10           ← 历史归档
    └── turbolog.log.2026-08-11
```

---

## 快速开始

### 第一步：接入依赖

将 `turbolog-sdk-*.aar` 放入 `app/libs/`，在 `app/build.gradle.kts` 中添加：

```kotlin
dependencies {
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar"))))
}
```

### 第二步：初始化 SDK

在 `Application.onCreate()` 中完成初始化，**必须在任何日志调用之前执行**：

```kotlin
class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        TurboLog.init(this)
    }
}
```

### 第三步：写日志

```kotlin
// 五个级别，用法与 Android Log 完全一致
TurboLog.v("Network", "连接建立: $url")
TurboLog.d("Network", "请求参数: $params")
TurboLog.i("Pay", "支付成功，金额: $amount")
TurboLog.w("Cache", "缓存未命中: $key")
TurboLog.e("Auth", "Token 已过期，请重新登录")

// Error 级别支持 Throwable 堆栈打印
TurboLog.e("Crash", "操作失败", RuntimeException("详细异常"))
```

### 第四步：Tag 过滤

```kotlin
// 只保留关键模块的日志
TurboLog.setAllowedTags("Network", "Pay", "Auth")

// 清除过滤，恢复输出所有 Tag
TurboLog.clearTagFilter()
```

### 第五步：刷盘和清理

```kotlin
// 手动刷盘（不阻塞主线程）
TurboLog.flush()

// 清理日志（同步阻塞，建议在后台线程调用）
val count = TurboLog.clearLogs(clearCurrentLog = true)
```

---

## API 参考

```kotlin
object TurboLog {
    // 初始化
    fun init(context: Context)

    // Tag 过滤
    fun setAllowedTags(vararg tags: String)
    fun clearTagFilter()

    // 日志输出（线程安全）
    fun v(tag: String, msg: String)                        // VERBOSE
    fun d(tag: String, msg: String)                        // DEBUG
    fun i(tag: String, msg: String)                        // INFO
    fun w(tag: String, msg: String)                        // WARN
    fun e(tag: String, msg: String, tr: Throwable? = null) // ERROR

    // 刷盘与清理
    fun flush()                               // 异步刷盘
    fun clearLogs(clearCurrentLog: Boolean = true): Int   // 同步清理，返回处理文件数
}
```

---

## 构建指南

### 环境要求

| 工具 | 版本 |
|------|------|
| Rust | 1.82+（需要 Edition 2024） |
| Android NDK | 27.x |
| cargo-ndk | 最新版 |
| JDK | 17+ |
| AGP | 9.3.0+ |

### 一键构建

```powershell
# Windows
.\publish_rlog.ps1                     # 默认 arm64-v8a
.\publish_rlog.ps1 -AbiFilters arm64-v8a,armeabi-v7a,x86_64

# macOS / Linux
./publish_rlog.sh
```

产物位于 `./output/turbolog-sdk-1.0.0.aar`。

### 手动构建

```bash
# 1. 编译 Rust .so
cd rustlib
cargo ndk --target aarch64-linux-android --platform 29 build --release

# 2. 复制到 jniLibs
cp target/aarch64-linux-android/release/libturbolog_sdk.so \
   ../sdk/src/main/jniLibs/arm64-v8a/

# 3. 打包 AAR
cd ..
./gradlew :sdk:assembleRelease
# 产物: sdk/build/outputs/aar/sdk-release.aar
```

### 运行测试

```bash
# Rust 单元测试（真机/模拟器）
cd rustlib && cargo ndk-test -t arm64-v8a

# Kotlin 单元测试
./gradlew :sdk:testDebugUnitTest

# Android instrumented 测试
./gradlew :app:connectedDebugAndroidTest
```

---

## 技术指标

| 指标 | 值 | 说明 |
|------|------|------|
| 写入方式 | 异步非阻塞 | tracing-appender RingBuffer |
| 轮转策略 | 按天 | tracing-appender::rolling::daily |
| 存储位置 | `{cacheDir}/turbolog/` | 无需存储权限 |
| 崩溃恢复 | panic hook 自动刷盘 | Rust panic hook |
| minSdk | 29（Android 10） | |
| 支持架构 | arm64-v8a（默认） | 可扩展 armeabi-v7a / x86_64 |

---

## 常见问题

**Q：初始化之前调用 `TurboLog.d()` 会怎样？**
A：`TurboLog` 的 `init` 块调用 `System.loadLibrary("turbolog_sdk")`，如果类尚未加载，首次访问 `object` 时会触发初始化。建议在 `Application.onCreate()` 中显式调用 `TurboLog.init(context)`。

**Q：`clearLogs()` 是同步还是异步的？**
A：同步阻塞。直接遍历文件系统执行截断/删除，返回处理的文件数量。建议在后台线程或协程中调用。

**Q：日志文件会加密吗？**
A：当前版本不加密，日志以明文 UTF-8 存储。如有安全需求，可在应用层加密。

**Q：如何自定义日志格式？**
A：日志格式由 `tracing-subscriber` 的 `fmt::layer()` 控制。当前配置含时间戳、线程 ID、target 和消息体。如需自定义，修改 `rustlib/src/lib.rs` 中的 `fmt::layer()` 配置。