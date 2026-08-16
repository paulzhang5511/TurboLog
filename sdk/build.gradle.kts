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
    ndkVersion = "27.0.12077973"
    defaultConfig {
        minSdk = 29
        ndk {
            abiFilters.addAll(setOf("arm64-v8a", "armeabi-v7a", "x86_64"))
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