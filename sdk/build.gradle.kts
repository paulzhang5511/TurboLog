plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.turbolog.sdk"
    compileSdk {
        version = release(36) {
            minorApiLevel = 1
        }
    }
    defaultConfig {
        minSdk = 29
        ndk {
            // 仅保留已编译 .so 的架构。
            // 如需支持 armeabi-v7a/x86_64，先用 publish_rlog.ps1 -AbiFilters 编译对应 .so，
            // 再将架构加入 abiFilters。
            abiFilters.addAll(setOf("arm64-v8a"))
        }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

dependencies {
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.junit)
}