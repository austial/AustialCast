package app.austial.cast.tv

import kotlin.test.Test
import kotlin.test.assertEquals

class AspectSurfaceViewTest {
    @Test
    fun fitLetterboxesWideVideoOnTallerBox() {
        // 16:9 video in a 1920x1200 box: width-limited -> 1920x1080.
        assertEquals(1920 to 1080, AspectSurfaceView.fitSize(1920, 1080, 1920, 1200, fill = false))
    }

    @Test
    fun fitPillarboxesNarrowVideo() {
        // 4:3 video on a 16:9 screen: height-limited -> 1440x1080.
        assertEquals(1440 to 1080, AspectSurfaceView.fitSize(1024, 768, 1920, 1080, fill = false))
    }

    @Test
    fun fillCropsToCoverTheBox() {
        // 4:3 video must be at least as wide as the screen -> 1920x1440 (top/bottom cropped).
        assertEquals(1920 to 1440, AspectSurfaceView.fitSize(1024, 768, 1920, 1080, fill = true))
        // Ultra-wide video must be at least as tall as the screen -> 2560x1080 (sides cropped).
        assertEquals(2560 to 1080, AspectSurfaceView.fitSize(2560, 1080, 1920, 1080, fill = true))
    }

    @Test
    fun sameAspectFillsExactly() {
        assertEquals(1920 to 1080, AspectSurfaceView.fitSize(1280, 720, 1920, 1080, fill = false))
        assertEquals(1920 to 1080, AspectSurfaceView.fitSize(1280, 720, 1920, 1080, fill = true))
    }

    @Test
    fun unknownVideoSizeUsesFullBox() {
        assertEquals(1920 to 1080, AspectSurfaceView.fitSize(0, 0, 1920, 1080, fill = false))
    }
}
