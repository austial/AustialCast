plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.austial.cast.tv"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.austial.cast.tv"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    lint {
        // The app is TV-only; touchscreen / portrait warnings are intentional.
        disable += setOf("MissingTranslation", "ExtraTranslation")
        abortOnError = true
        warningsAsErrors = false
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":core"))
    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
}
