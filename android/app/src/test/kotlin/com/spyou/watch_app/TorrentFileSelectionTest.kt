package com.spyou.watch_app

import org.junit.Assert.assertEquals
import org.junit.Test

class TorrentFileSelectionTest {
    @Test
    fun requestedVideoIndexWinsOverLargestFile() {
        assertEquals(
            1,
            selectTorrentVideoFileIndex(
                listOf("movie.mkv", "episode-1.mp4"),
                listOf(2_000L, 900L),
                1,
            ),
        )
    }

    @Test
    fun invalidOrNonVideoIndexFallsBackToLargestVideo() {
        val names = listOf("movie.mkv", "poster.jpg", "episode.mp4")
        val sizes = listOf(2_000L, 50L, 900L)

        assertEquals(0, selectTorrentVideoFileIndex(names, sizes, 1))
        assertEquals(0, selectTorrentVideoFileIndex(names, sizes, 9))
    }

    @Test
    fun returnsMinusOneWhenTorrentHasNoVideo() {
        assertEquals(
            -1,
            selectTorrentVideoFileIndex(listOf("poster.jpg"), listOf(50L), 0),
        )
    }
}
