package com.daffaheroik.installercodex

import android.app.Application


class InstallerCodexApp : Application() {
    override fun onCreate() {
        super.onCreate()
        FirebaseLogReporter.install(this)
        FirebaseLogReporter.log(
            context = this,
            level = "info",
            event = "app_start",
            message = "Installer Codex app started",
        )
    }
}
