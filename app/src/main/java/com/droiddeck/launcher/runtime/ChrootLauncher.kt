package com.droiddeck.launcher.runtime

import android.content.Context
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

object ChrootLauncher {
    private const val ASSET = "chroot/launch.sh"
    private const val SHELL = "/system/bin/sh"

    @Volatile private var installed: File? = null
    @Volatile private var controlDir: File? = null
    @Volatile private var rootChecked: Boolean? = null

    @JvmStatic
    @Synchronized
    fun script(context: Context): File {
        installed?.takeIf { it.isFile }?.let { return it }
        val dir = File(LinuxRuntime.liveDir(context), "chroot").apply { mkdirs() }
        val file = File(dir, "launch.sh")
        val bytes = context.assets.open(ASSET).use { it.readBytes() }
        if (!file.isFile || !file.readBytes().contentEquals(bytes)) {
            val staged = File(dir, "launch.sh.staged")
            staged.writeBytes(bytes)
            if (!staged.renameTo(file)) throw IOException("Cannot stage $file")
        }
        installed = file
        controlDir = dir
        return file
    }

    @JvmStatic
    fun relay(pid: Int, signal: Int) {
        val pipe = File(controlDir ?: return, "ctl.$pid")
        if (!pipe.exists()) return
        val command = when (signal) {
            android.system.OsConstants.SIGSTOP -> "stop"
            android.system.OsConstants.SIGCONT -> "cont"
            else -> signal.toString()
        }
        try {
            val fd = android.system.Os.open(pipe.path,
                android.system.OsConstants.O_WRONLY or android.system.OsConstants.O_NONBLOCK or android.system.OsConstants.O_CLOEXEC, 0)
            try {
                android.system.Os.write(fd, "$command\n".toByteArray(), 0, command.length + 1)
            } finally {
                android.system.Os.close(fd)
            }
        } catch (e: Exception) {
            android.util.Log.w("ChrootLauncher", "could not pass $command to launcher $pid: $e")
        }
    }

    @JvmStatic
    fun prefix(context: Context): MutableList<String> = mutableListOf(SHELL, script(context).path)

    private val SU = listOf("su", "/system/bin/su", "/system/xbin/su", "/debug_ramdisk/su", "/sbin/su", "/su/bin/su")

    @JvmStatic
    fun rootAvailable(): Boolean {
        rootChecked?.let { if (it) return true }
        val ok = SU.any { su ->
            try {
                val process = ProcessBuilder(su, "-c", "id -u").redirectErrorStream(true).start()
                val out = process.inputStream.bufferedReader().readText().trim()
                process.waitFor(30, TimeUnit.SECONDS) && process.exitValue() == 0 && out.lines().lastOrNull() == "0"
            } catch (e: Exception) {
                false
            }
        }
        rootChecked = ok
        return ok
    }
}
