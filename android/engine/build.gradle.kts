plugins {
    id("org.jetbrains.kotlin.jvm")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testImplementation(kotlin("test"))
}

val shared = rootProject.file("../Shared")

// The built-in rules are the shared file itself, never a copy kept in this folder.
tasks.processResources {
    from(shared.resolve("rules.json")) { into("fxclip") }
}

tasks.test {
    useJUnitPlatform()
    systemProperty("fxclip.shared", shared.absolutePath)
    inputs.dir(shared)
}
