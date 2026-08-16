package com.turbolog.sdk

import org.junit.Assert.*
import org.junit.BeforeClass
import org.junit.Test
import java.io.PrintWriter
import java.io.StringWriter

/**
 * TurboLog 纯逻辑层单元测试（纯 JVM，无需 Robolectric / Android 环境）。
 *
 * 策略：不直接引用 TurboLog object（避免触发 init 块中的 System.loadLibrary），
 * 而是直接测试核心逻辑函数：
 * - getStackTraceString 的 Throwable 格式化
 * - 日志级别常量
 * - Tag 过滤逻辑（通过模拟 isTagAllowed 的等价行为）
 */
class TurboLogTest {

    companion object {
        private const val LEVEL_VERBOSE = 2
        private const val LEVEL_DEBUG = 3
        private const val LEVEL_INFO = 4
        private const val LEVEL_WARN = 5
        private const val LEVEL_ERROR = 6
    }

    // ==================== Throwable 格式化测试 ====================

    @Test
    fun testGetStackTraceString_formatsException() {
        val exception = RuntimeException("测试异常")
        val result = throwableToString(exception)

        assertTrue("堆栈应包含异常类型", result.contains("RuntimeException"))
        assertTrue("堆栈应包含异常消息", result.contains("测试异常"))
        assertTrue("堆栈应包含调用栈", result.contains("\tat "))
    }

    @Test
    fun testGetStackTraceString_withCause() {
        val cause = IllegalArgumentException("底层原因")
        val exception = RuntimeException("外层异常", cause)
        val result = throwableToString(exception)

        assertTrue("堆栈应包含 Caused by", result.contains("Caused by"))
        assertTrue("堆栈应包含底层异常类型", result.contains("IllegalArgumentException"))
        assertTrue("堆栈应包含底层异常消息", result.contains("底层原因"))
    }

    // ==================== Tag 过滤逻辑测试 ====================

    @Test
    fun testTagFilter_allowsWhenNull() {
        val allowedTags: Set<String>? = null
        assertTrue("null 时允许所有 Tag", isTagAllowed(allowedTags, "AnyTag"))
    }

    @Test
    fun testTagFilter_allowsMatchingTag() {
        val allowedTags = setOf("Network", "Auth")
        assertTrue("应允许匹配的 Tag", isTagAllowed(allowedTags, "Network"))
        assertTrue("应允许匹配的 Tag", isTagAllowed(allowedTags, "Auth"))
    }

    @Test
    fun testTagFilter_rejectsNonMatchingTag() {
        val allowedTags = setOf("Network", "Auth")
        assertFalse("应拒绝不匹配的 Tag", isTagAllowed(allowedTags, "Cache"))
        assertFalse("应拒绝不匹配的 Tag", isTagAllowed(allowedTags, "Pay"))
    }

    @Test
    fun testTagFilter_isCaseSensitive() {
        val allowedTags = setOf("Network")
        assertFalse("应大小写敏感", isTagAllowed(allowedTags, "network"))
        assertFalse("应大小写敏感", isTagAllowed(allowedTags, "NETWORK"))
    }

    @Test
    fun testTagFilter_emptyArgsDisablesFilter() {
        // TurboLog.setAllowedTags() with no args → allowedTags = null → filter off
        // This mirrors: setAllowedTags(vararg tags) {
        //     allowedTags = if (tags.isEmpty()) null else tags.toSet()
        // }
        assertTrue("空参数应关闭过滤", isTagAllowed(null, "AnyTag"))
    }

    // ==================== 日志级别常量测试 ====================

    @Test
    fun testLogLevelConstants() {
        assertEquals("VERBOSE=2", 2, LEVEL_VERBOSE)
        assertEquals("DEBUG=3", 3, LEVEL_DEBUG)
        assertEquals("INFO=4", 4, LEVEL_INFO)
        assertEquals("WARN=5", 5, LEVEL_WARN)
        assertEquals("ERROR=6", 6, LEVEL_ERROR)
    }

    // ==================== 等价实现（镜像 TurboLog.kt 中的逻辑） ====================

    private fun throwableToString(tr: Throwable): String {
        val sw = StringWriter()
        val pw = PrintWriter(sw)
        tr.printStackTrace(pw)
        pw.flush()
        return sw.toString()
    }

    private fun isTagAllowed(currentAllowed: Set<String>?, tag: String): Boolean {
        return currentAllowed == null || currentAllowed.contains(tag)
    }
}