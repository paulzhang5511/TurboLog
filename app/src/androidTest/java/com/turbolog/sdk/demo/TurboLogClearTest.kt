package com.turbolog.sdk.demo

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.turbolog.sdk.TurboLog
import org.junit.Assert.*
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * TurboLog clearLogs 端到端测试
 */
@RunWith(AndroidJUnit4::class)
class TurboLogClearTest {

    companion object {
        private lateinit var context: android.content.Context

        @BeforeClass
        @JvmStatic
        fun setUpClass() {
            context = InstrumentationRegistry.getInstrumentation().targetContext
            TurboLog.init(context)
        }
    }

    @Test
    fun testClearLogs_returnsCount() {
        // 写入一些日志确保有文件存在
        TurboLog.d("ClearTest", "log entry 1")
        TurboLog.i("ClearTest", "log entry 2")
        TurboLog.flush()

        // 清理日志（不抛异常即通过）
        val count = TurboLog.clearLogs(clearCurrentLog = true)
        assertTrue("clearLogs should return a non-negative count", count >= 0)
    }

    @Test
    fun testClearLogs_keepCurrentLog() {
        TurboLog.d("ClearTest", "keep current test")
        TurboLog.flush()

        val count = TurboLog.clearLogs(clearCurrentLog = false)
        assertTrue("clearLogs with false should return non-negative count", count >= 0)
    }

    @Test
    fun testClearLogs_defaultParameter() {
        // 默认 clearCurrentLog=true
        TurboLog.d("ClearTest", "default param test")
        TurboLog.flush()

        val count = TurboLog.clearLogs()
        assertTrue("clearLogs with default param should return non-negative count", count >= 0)
    }
}