package com.droiddeck.launcher.runtime

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ProotFastPathTest {
    private val root = File("/data/data/com.droiddeck.launcher/files/linuxfs")

    @Test fun guestEnvironmentCarriesTheHostAndroidApi() {
        for (sdk in listOf(33, 35, 36)) {
            assertTrue(ProotFastPath.guestEnv(root, emptyList(), "test", sdk).contains("PROOT_FP_ANDROID_API=$sdk"))
        }
    }

    @Test fun aSessionsUsualBindsGetAKey() {
        val binds = (1..87).map { "/host/$it:/guest/$it" }
        assertNotNull(ProotFastPath.key(root, binds))
    }

    @Test fun moreBindsThanTheLibraryHoldsLeaveItOff() {
        val binds = (1..ProotFastPath.MAX_BINDS + 1).map { "/host/$it:/guest/$it" }
        assertNull(ProotFastPath.key(root, binds))
    }
}
