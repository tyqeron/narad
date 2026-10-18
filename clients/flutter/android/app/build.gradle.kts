import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Local development can use the debug key. Tag releases supply a stable CI key.
val releaseSigningVariables = listOf("NARAD_ANDROID_KEYSTORE", "NARAD_ANDROID_STORE_PASSWORD",
    "NARAD_ANDROID_KEY_ALIAS", "NARAD_ANDROID_KEY_PASSWORD")
val hasReleaseSigning = releaseSigningVariables.all { !System.getenv(it).isNullOrBlank() }
require(hasReleaseSigning || releaseSigningVariables.all { System.getenv(it).isNullOrBlank() }) {
    "Provide all four NARAD_ANDROID signing environment variables, or none for a local development build"
}

android {
    namespace = "dev.narad.narad_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.narad.narad_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (hasReleaseSigning) {
        signingConfigs.create("release") {
            storeFile = File(System.getenv("NARAD_ANDROID_KEYSTORE"))
            storePassword = System.getenv("NARAD_ANDROID_STORE_PASSWORD")
            keyAlias = System.getenv("NARAD_ANDROID_KEY_ALIAS")
            keyPassword = System.getenv("NARAD_ANDROID_KEY_PASSWORD")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseSigning) "release" else "debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"),"proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// The same Rust backend ships inside every APK; no companion process installation.
val rustAbis = providers.gradleProperty("target-platform").orNull
    ?.split(",")?.map { when(it) {
        "android-arm" -> "armeabi-v7a"
        "android-arm64" -> "arm64-v8a"
        "android-x64" -> "x86_64"
        else -> error("Unsupported Flutter Android target: $it")
    }} ?: listOf("arm64-v8a", "armeabi-v7a", "x86_64")
val buildRustAndroid by tasks.registering(Exec::class) {
    val repoRoot = rootProject.projectDir.resolve("../../..").canonicalFile
    workingDir(repoRoot)
    commandLine("python3", repoRoot.resolve("scripts/build-android-rust.py").absolutePath,
        "--ndk", File(Properties().apply {
            rootProject.file("local.properties").inputStream().use { load(it) }
        }.getProperty("sdk.dir"), "ndk/${android.ndkVersion}").absolutePath,
        "--abis", rustAbis.joinToString(","))
    inputs.files(fileTree(repoRoot.resolve("crates")) { include("**/*.rs", "**/Cargo.toml") })
    inputs.files(repoRoot.resolve("Cargo.lock"), repoRoot.resolve("Cargo.toml"), repoRoot.resolve("rust-toolchain.toml"), repoRoot.resolve("scripts/build-android-rust.py"))
    inputs.property("abis",rustAbis.joinToString(","))
    inputs.property("ndkVersion", android.ndkVersion ?: "")
    outputs.dirs(rustAbis.map { file("build/generated/rustJniLibs/$it") })
}
android.sourceSets.getByName("main").jniLibs.srcDir("build/generated/rustJniLibs")
tasks.named("preBuild").configure { dependsOn(buildRustAndroid) }

dependencies {
    implementation("androidx.documentfile:documentfile:1.0.0")
    testImplementation("junit:junit:4.13.2")
}
