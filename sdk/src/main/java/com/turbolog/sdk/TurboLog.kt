package com.turbolog.sdk

import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * TurboLog —— 基于 Rust + tracing 生态的高性能 Android 日志 SDK。
 *
 * 使用方式：
 * 1. Application.onCreate() 中调用 TurboLog.init(context)
 * 2. 业务代码中调用 TurboLog.d("tag", "msg") 等日志接口
 * 3. App 压后台前调用 TurboLog.flush() 确保落盘
 * 4. 清理过期日志时调用 TurboLog.clearLogs()
 */
object TurboLog {

    init {
        System.loadLibrary("turbolog_sdk")
    }

    // ==================== Tag 过滤 ====================

    @Volatile
    private var allowedTags: Set<String>? = null

    /**
     * 设置允许输出的 Tag 白名单。
     * @param tags 变参传入；留空或不传表示关闭过滤，恢复输出所有 Tag。
     */
    fun setAllowedTags(vararg tags: String) {
        allowedTags = if (tags.isEmpty()) null else tags.toSet()
    }

    /**
     * 清除 Tag 过滤，恢复输出所有 Tag 的日志。
     */
    fun clearTagFilter() {
        allowedTags = null
    }

    private fun isTagAllowed(tag: String): Boolean {
        val currentAllowed = allowedTags
        return currentAllowed == null || currentAllowed.contains(tag)
    }

    // ==================== 初始化 ====================

    /**
     * 初始化 TurboLog 日志服务。
     * 必须在任何日志调用之前调用，通常在 Application.onCreate() 中执行。
     *
     * @param context Application Context
     */
    fun init(context: Context) {
        val logDir = File(context.cacheDir, "turbolog")
        if (!logDir.exists()) {
            logDir.mkdirs()
        }
        nativeInitLogger(logDir.absolutePath)
    }

    // ==================== 日志输出 API ====================

    fun v(tag: String, msg: String) {
        log(LEVEL_VERBOSE, tag, msg)
    }

    fun d(tag: String, msg: String) {
        log(LEVEL_DEBUG, tag, msg)
    }

    fun i(tag: String, msg: String) {
        log(LEVEL_INFO, tag, msg)
    }

    fun w(tag: String, msg: String) {
        log(LEVEL_WARN, tag, msg)
    }

    /**
     * 输出 Error 级别日志。唯一支持 Throwable 堆栈打印的接口。
     *
     * @param tag 日志标签
     * @param msg 日志消息
     * @param tr 可选的异常对象，传入后自动格式化堆栈文本
     */
    fun e(tag: String, msg: String, tr: Throwable? = null) {
        val finalMsg = if (tr != null) {
            "$msg\n${getStackTraceString(tr)}"
        } else {
            msg
        }
        log(LEVEL_ERROR, tag, finalMsg)
    }

    // ==================== 刷盘与清理 ====================

    /**
     * 手动触发异步刷盘，将缓冲区数据强制写入磁盘。
     * 不阻塞调用线程，典型场景：Activity.onStop()、关键操作完成后。
     */
    fun flush() {
        nativeFlushLogger()
    }

    /**
     * 同步阻塞清理日志文件。
     * 对当前活动文件执行截断（set_len(0)），对历史归档文件执行删除。
     * 调用者需自行决定线程调度（建议在后台线程或协程中调用）。
     *
     * @param clearCurrentLog 是否清空当前正在写入的日志文件内容（默认为 true）
     * @return 被清理/截断的文件数量
     */
    fun clearLogs(clearCurrentLog: Boolean = true): Int {
        return nativeClearLogs(clearCurrentLog)
    }

    // ==================== 内部实现 ====================

    private fun log(level: Int, tag: String, msg: String) {
        if (!isTagAllowed(tag)) return // Tag 过滤在 Kotlin 层，不触发 JNI
        nativeWriteLog(level, tag, msg)
    }

    private fun getStackTraceString(tr: Throwable): String {
        val sw = StringWriter()
        val pw = PrintWriter(sw)
        tr.printStackTrace(pw)
        pw.flush()
        return sw.toString()
    }

    // ==================== JNI Native 声明 ====================

    private const val LEVEL_VERBOSE = 2
    private const val LEVEL_DEBUG = 3
    private const val LEVEL_INFO = 4
    private const val LEVEL_WARN = 5
    private const val LEVEL_ERROR = 6

    private external fun nativeInitLogger(cacheDirPath: String)
    private external fun nativeWriteLog(level: Int, tag: String, msg: String)
    private external fun nativeFlushLogger()
    private external fun nativeClearLogs(clearCurrentLog: Boolean): Int
}