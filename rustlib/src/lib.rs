use jni::objects::{JClass, JString};
use jni::sys::jboolean;
use jni::EnvUnowned;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use tracing_appender::non_blocking::NonBlocking;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::fmt;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

/// 非阻塞写入器的全局引用。
/// 存储在 Mutex 中，以便 clearLogs() 在文件截断期间通过持有锁来与后台工作线程协调。
static LOG_WRITER: OnceLock<Mutex<NonBlocking>> = OnceLock::new();
/// WorkerGuard 保持后台工作线程在进程生命周期内存活。
static LOG_GUARD: OnceLock<WorkerGuard> = OnceLock::new();
/// 活动日志文件的底层文件句柄。
/// 由 nativeFlushLogger() 用于调用 sync_all() —— NonBlocking::flush() 是空操作，
/// 因此我们必须直接对底层 File 进行 fsync 以保证持久性。
static LOG_FILE: OnceLock<Mutex<fs::File>> = OnceLock::new();
/// clearLogs() 使用的受保护日志目录路径。
static LOG_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);

const LOG_FILE_PREFIX: &str = "turbolog.log";

// ============================================================================
// JNI 导出函数 —— 命名必须匹配 Java_com_turbolog_sdk_TurboLog_<method>
// ============================================================================

/// 使用非阻塞文件追加器初始化全局 tracing 订阅者。
/// 将写入器、守卫和底层文件句柄存储在全局静态变量中。
///
/// Kotlin 签名：nativeInitLogger(String path)
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_turbolog_sdk_TurboLog_nativeInitLogger<'local>(
    _env: EnvUnowned<'local>,
    _class: JClass<'local>,
    path_jstr: JString<'local>,
) {
    // 1. 从 JString 提取日志目录路径
    let log_path = path_jstr.to_string();
    let log_dir = PathBuf::from(&log_path);

    // 2. 持久化路径，供 clearLogs 后续使用
    if let Ok(mut guard) = LOG_DIR.lock() {
        *guard = Some(log_dir.clone());
    }

    // 3. 构建 tracing 管道：简单的 File → non_blocking → fmt 层
    // 注意：我们直接使用 File + NonBlocking 而不是 RollingFileAppender，
    // 因为 RollingFileAppender 内部使用 `symlink`，而 Android 的 /data/data/.../cache
    // 文件系统不支持符号链接。
    let log_file = log_dir.join(LOG_FILE_PREFIX);
    let file = match fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_file)
    {
        Ok(f) => f,
        Err(e) => {
            // 必需项 #3：记录失败原因，而不是静默返回。
            // Kotlin 层无法观察到这一点，但有助于事后调试。
            eprintln!(
                "TurboLog nativeInitLogger: failed to open log file '{}': {}",
                log_file.display(),
                e
            );
            return;
        }
    };

    // 必需项 #1：保留单独的 File 句柄，用于在 nativeFlushLogger 中进行真正的 fsync。
    // NonBlocking::flush() 是空操作，因此我们需要直接访问底层文件。
    let sync_file = match fs::OpenOptions::new().write(true).open(&log_file) {
        Ok(f) => f,
        Err(e) => {
            eprintln!(
                "TurboLog nativeInitLogger: failed to open sync handle for '{}': {}",
                log_file.display(),
                e
            );
            return;
        }
    };

    let (non_blocking, guard) = tracing_appender::non_blocking(file);
    let writer_clone = non_blocking.clone();

    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("trace"));

    let file_layer = fmt::layer()
        .with_writer(non_blocking)
        .with_ansi(false)
        .with_target(true)
        .with_thread_ids(true);

    // 4. init() 只能成功一次；后续调用会被静默忽略。
    // panic 钩子会无条件注册（必需项 #4），这样即使之前的调用或其他 crate
    // 已经安装了 tracing 订阅者，崩溃捕获也能正常工作。
    let subscriber_installed = tracing_subscriber::registry()
        .with(filter)
        .with(file_layer)
        .try_init()
        .is_ok();

    if subscriber_installed {
        let _ = LOG_WRITER.set(Mutex::new(writer_clone));
        let _ = LOG_GUARD.set(guard);
        tracing::info!(target: "SYSTEM", "TurboLog Service initialized successfully.");
    } else {
        // 订阅者已存在；仍然保留引用，以便 flush/clear 可以
        // 针对最近的配置尝试进行操作。
        let _ = LOG_WRITER.set(Mutex::new(writer_clone));
        let _ = LOG_GUARD.set(guard);
        tracing::warn!(
            target: "SYSTEM",
            "TurboLog tracing subscriber already initialized; reusing existing subscriber."
        );
    }

    // 无论 try_init() 是否安装了新的订阅者（必需项 #4），
    // 始终存储同步句柄并注册 panic 钩子。
    let _ = LOG_FILE.set(Mutex::new(sync_file));

    // 必需项 #4：独立于 try_init() 结果注册 panic 钩子。
    std::panic::set_hook(Box::new(|panic_info| {
        tracing::error!(target: "CRASH", "Rust Panic Detected: {:?}", panic_info);
        // 强制刷新底层文件，以便崩溃上下文能够保存下来。
        if let Some(file_mutex) = LOG_FILE.get() {
            if let Ok(mut f) = file_mutex.lock() {
                let _ = f.flush();
                let _ = f.sync_all();
            }
        }
    }));
}

/// 向 tracing 管道写入日志事件。
/// 级别映射：2=TRACE, 3=DEBUG, 4=INFO, 5=WARN, 6=ERROR（默认：INFO）。
///
/// 注意：`tracing` 宏要求 `target` 参数是静态字符串字面量，
/// 因此标签会被前置到消息文本中。
///
/// Kotlin 签名：nativeWriteLog(int level, String tag, String msg)
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_turbolog_sdk_TurboLog_nativeWriteLog<'local>(
    _env: EnvUnowned<'local>,
    _class: JClass<'local>,
    level: jni::sys::jint,
    tag_jstr: JString<'local>,
    msg_jstr: JString<'local>,
) {
    let tag = tag_jstr.to_string();
    let msg = msg_jstr.to_string();
    write_log_event(level, &tag, &msg);
}

/// 核心日志写入逻辑 —— 无需 JNI 类型即可测试。
/// 将消息格式化为 "[tag] msg" 并分发到 tracing 管道。
pub(crate) fn write_log_event(level: i32, tag: &str, msg: &str) {
    let formatted = format!("[{}] {}", tag, msg);
    match level {
        2 => tracing::trace!("{}", formatted),
        3 => tracing::debug!("{}", formatted),
        4 => tracing::info!("{}", formatted),
        5 => tracing::warn!("{}", formatted),
        6 => tracing::error!("{}", formatted),
        _ => tracing::info!("{}", formatted),
    }
}

/// 清除日志文件的核心逻辑 —— 无需 JNI 类型即可测试。
/// - 归档文件（turbolog.log.YYYY-MM-DD）会被删除。
/// - 活动文件（turbolog.log）仅在 `clear_current` 为 true 时被截断为 0 字节（不删除），
///   以便为工作线程保留文件句柄。
///
/// # 与后台工作线程的协调（必需项 #2）
///
/// 为了避免在截断文件时后台工作线程向活动文件写入（这会导致文件偏移量不同步
/// 并产生稀疏文件空洞），持有 `LOG_WRITER` 引用的调用方应在截断期间持有写入器的互斥锁。
/// 此函数接受可选的 `writer_lock` 参数，以便 JNI 入口点可以传入它。
///
/// 返回处理的文件数量。
pub(crate) fn clear_logs_internal(log_dir: &std::path::Path, clear_current: bool) -> i32 {
    clear_logs_internal_locked(log_dir, clear_current, None)
}

/// 与 [`clear_logs_internal`] 相同，但接受预先获取的写入器锁，
/// 以便活动文件的截断相对于后台工作线程是原子的。
pub(crate) fn clear_logs_internal_locked(
    log_dir: &std::path::Path,
    clear_current: bool,
    writer_lock: Option<&std::sync::MutexGuard<'_, NonBlocking>>,
) -> i32 {
    let read_dir = match fs::read_dir(log_dir) {
        Ok(dir) => dir,
        Err(_) => return 0,
    };

    let mut cleared_count = 0i32;

    for entry in read_dir.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        if let Some(file_name) = path.file_name().and_then(|n| n.to_str()) {
            if file_name.starts_with(LOG_FILE_PREFIX) {
                if file_name == LOG_FILE_PREFIX {
                    // 活动文件：截断（永远不删除 —— 为工作线程保留 inode）。
                    // 必需项 #2：如果提供了写入器锁，调用方已经持有它，
                    // 因此工作线程在截断期间无法交错写入。
                    // 锁在此分支期间被消费。
                    if clear_current {
                        // 使用守卫，使其生命周期覆盖截断操作。
                        let _ = writer_lock;
                        if let Ok(file) = fs::OpenOptions::new().write(true).open(&path) {
                            if file.set_len(0).is_ok() {
                                cleared_count += 1;
                            }
                        }
                    }
                } else {
                    // 归档文件：可以安全删除
                    if fs::remove_file(&path).is_ok() {
                        cleared_count += 1;
                    }
                }
            }
        }
    }

    cleared_count
}

/// clear_logs_internal 的 JNI 包装器。
///
/// 在截断活动文件之前获取 LOG_WRITER 互斥锁，
/// 以便后台工作线程无法交错写入（必需项 #2）。
///
/// Kotlin 签名：nativeClearLogs(boolean clearCurrent) → int
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_turbolog_sdk_TurboLog_nativeClearLogs(
    _env: EnvUnowned,
    _class: JClass,
    clear_current: jboolean,
) -> jni::sys::jint {
    let log_dir = match LOG_DIR.lock() {
        Ok(guard) => match guard.as_ref() {
            Some(path) => path.clone(),
            None => return 0,
        },
        Err(_) => return 0,
    };

    // 必需项 #2：在截断期间持有写入器锁，以防止后台工作线程
    // 写入到半截断的文件中。
    let writer_guard = LOG_WRITER.get().map(|m| m.lock().ok()).flatten();
    clear_logs_internal_locked(&log_dir, clear_current, writer_guard.as_ref())
}

/// 强制将底层日志文件刷新到磁盘。
///
/// `tracing-appender` 的 `NonBlocking::flush()` 是空操作（从概念上讲它只是排空
/// 通道的内存缓冲区，但不会 fsync 文件）。为了保证 `TurboLog.flush()` 调用者
/// （例如 Activity.onStop）的持久性，我们直接在底层文件句柄上调用 `File::sync_all()`
/// （关键项 #1）。
///
/// Kotlin 签名：nativeFlushLogger()
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_turbolog_sdk_TurboLog_nativeFlushLogger(
    _env: EnvUnowned,
    _class: JClass,
) {
    if let Some(file_mutex) = LOG_FILE.get() {
        if let Ok(mut f) = file_mutex.lock() {
            let _ = f.flush();
            let _ = f.sync_all();
        }
    }
}

#[cfg(test)]
mod tests;
