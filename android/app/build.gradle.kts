plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "io.github.c0mm0n.fxclip"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.c0mm0n.fxclip"
        minSdk = 26
        targetSdk = 35
        versionCode = providers.gradleProperty("fxclipVersionCode").orElse("2").get().toInt()
        versionName = providers.gradleProperty("fxclipVersion").orElse("0.3.0").get()
        buildConfigField("String", "UPDATE_API", "\"https://api.github.com/repos/c0mm0n/fxclip/releases/latest\"")
    }

    val releaseKeystore = System.getenv("FXCLIP_ANDROID_KEYSTORE")
    if (!releaseKeystore.isNullOrBlank()) {
        signingConfigs.create("release") {
            storeFile = file(releaseKeystore)
            storePassword = System.getenv("FXCLIP_ANDROID_KEYSTORE_PASSWORD")
            keyAlias = "fxclip"
            keyPassword = System.getenv("FXCLIP_ANDROID_KEYSTORE_PASSWORD")
        }
    }

    buildTypes {
        create("updateTest") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".updatetest"
            matchingFallbacks += listOf("debug")
            buildConfigField("String", "UPDATE_API", "\"http://127.0.0.1:48637/latest\"")
        }
        release {
            // Published APKs use the persistent release key; local/PR builds use the debug key.
            // Not debuggable, so Compose runs at full speed; scrolling is visibly smoother.
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName(if (releaseKeystore.isNullOrBlank()) "debug" else "release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    implementation(project(":engine"))
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.13.1")
}
