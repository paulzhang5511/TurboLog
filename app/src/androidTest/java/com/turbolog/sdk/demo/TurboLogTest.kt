package com.turbolog.sdk.demo

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.turbolog.sdk.TurboLog
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

/**
 * TurboLog Android instrumented 功能测试
 *
 * 在真机或模拟器上运行，验证 JNI 桥接、日志写入、flush 等端到端行为。
 */
@RunWith(AndroidJUnit4::class)
class TurboLogTest {

    companion object {
        private lateinit var context: android.content.Context

        @BeforeClass
        @JvmStatic
        fun setUpClass() {
            context = InstrumentationRegistry.getInstrumentation().targetContext
            TurboLog.init(context)
        }
    }

    // ==================== 初始化测试 ====================

    @Test
    fun testInit_success() {
        // 重复初始化不抛异常（幂等性）
        TurboLog.init(context)
    }

    @Test
    fun testRepeatedInit_isIdempotent() {
        TurboLog.init(context)
        TurboLog.init(context)
    }

    // ==================== 日志级别测试 ====================

    @Test
    fun testLogLevels_v() {
        TurboLog.v("TestTag", "verbose message")
    }

    @Test
    fun testLogLevels_d() {
        TurboLog.d("TestTag", "debug message")
    }

    @Test
    fun testLogLevels_i() {
        TurboLog.i("TestTag", "info message")
    }

    @Test
    fun testLogLevels_w() {
        TurboLog.w("TestTag", "warning message")
    }

    @Test
    fun testLogLevels_e() {
        TurboLog.e("TestTag", "error message")
    }

    @Test
    fun testLogLevels_e_withThrowable() {
        TurboLog.e("TestTag", "error with exception", java.lang.RuntimeException("测试异常"))
    }

    // ==================== 刷盘测试 ====================

    @Test
    fun testFlush() {
        TurboLog.d("FlushTest", "before flush")
        TurboLog.flush()
    }

    // ==================== Tag 过滤测试 ====================

    @Test
    fun testTagFilter_blocksUnmatched() {
        // 设置过滤后，不匹配的 Tag 调用不抛异常
        TurboLog.setAllowedTags("Network", "Auth")
        TurboLog.d("Cache", "this should be dropped silently")
        TurboLog.d("Network", "this should pass")
        TurboLog.clearTagFilter()
    }

    @Test
    fun testClearTagFilter_restoresAll() {
        TurboLog.setAllowedTags("A")
        TurboLog.clearTagFilter()
        TurboLog.d("AnyTag", "should pass after clear")
    }

    // ==================== 并发写入测试 ====================

    @Test
    fun testConcurrentWrites() {
        val threadCount = 10
        val logsPerThread = 100
        val latch = CountDownLatch(threadCount)
        val executor = Executors.newFixedThreadPool(threadCount)

        for (t in 0 until threadCount) {
            executor.execute {
                try {
                    for (i in 0 until logsPerThread) {
                        TurboLog.d("ConcurrentTag-$t", "log message $i")
                    }
                } finally {
                    latch.countDown()
                }
            }
        }

        latch.await()
        executor.shutdown()
    }

    // ==================== 边界条件测试 ====================

    @Test
    fun testEmptyTag() {
        TurboLog.d("", "message")
    }

    @Test
    fun testEmptyMessage() {
        TurboLog.d("tag", "")
    }

    @Test
    fun testLongMessage() {
        val longMsg = CharArray(10240) { 'A' }.concatToString()
        TurboLog.d("tag", longMsg)
    }

    @Test
    fun testSpecialCharacters() {
        TurboLog.d("tag", "中文\n\t\r\u0000")
    }
}