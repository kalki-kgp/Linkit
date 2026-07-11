import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
val linkitVersionCode = providers.environmentVariable("LINKIT_ANDROID_VERSION_CODE")
    .orElse(providers.environmentVariable("LINKIT_VERSION_CODE"))
    .map(String::toInt)
    .getOrElse(1)
val linkitVersionName = providers.environmentVariable("LINKIT_ANDROID_VERSION_NAME")
    .orElse(providers.environmentVariable("LINKIT_VERSION"))
    .getOrElse("0.1.0")
val linkitUpdateManifestUrl = providers.environmentVariable("LINKIT_ANDROID_UPDATE_MANIFEST_URL")
    .getOrElse("https://github.com/kalki-kgp/Linkit/releases/latest/download/linkit-android-update.json")
val escapedLinkitUpdateManifestUrl = linkitUpdateManifestUrl
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")

android {
    namespace = "tech.kalkikgp.linkit"
    compileSdk = 36

    defaultConfig {
        applicationId = "tech.kalkikgp.linkit"
        minSdk = 26
        targetSdk = 36
        versionCode = linkitVersionCode
        versionName = linkitVersionName
        buildConfigField("String", "LINKIT_ANDROID_UPDATE_MANIFEST_URL", "\"$escapedLinkitUpdateManifestUrl\"")
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.viewmodel.ktx)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.okhttp)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.zxing.embedded)

    debugImplementation(libs.androidx.compose.ui.tooling)
    testImplementation(libs.junit)
    testImplementation(libs.json)
}
