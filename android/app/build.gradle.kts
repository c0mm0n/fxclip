plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Releases override this from the tag, the way MARKETING_VERSION is overridden on macOS.
val appVersion = (System.getenv("FXCLIP_VERSION") ?: "0.2.1").removePrefix("v")

android {
    namespace = "io.github.c0mm0n.fxclip"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.c0mm0n.fxclip"
        minSdk = 26
        targetSdk = 35
        versionCode = (System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = appVersion
    }

    buildTypes {
        release {
            // Sideloaded like the Mac DMG: signed with the debug key for now, no store identity.
            // Not debuggable, so Compose runs at full speed; scrolling is visibly smoother.
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    implementation(project(":engine"))
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.9.3")
}
