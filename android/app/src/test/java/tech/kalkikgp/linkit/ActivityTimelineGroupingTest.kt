package tech.kalkikgp.linkit

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Calendar

class ActivityTimelineGroupingTest {
    @Test
    fun `splits entries into Today, Yesterday and dated groups in order`() {
        val now = noonOn(year = 2026, month = Calendar.JULY, day = 26)
        val entries = listOf(
            entry("a", now - HOUR),
            entry("b", now - 3 * HOUR),
            entry("c", now - DAY),
            entry("d", now - 5 * DAY)
        )

        val groups = groupByDay(entries, now)

        assertEquals(listOf("Today", "Yesterday"), groups.take(2).map { it.first })
        assertEquals(listOf("a", "b"), groups[0].second.map { it.id })
        assertEquals(listOf("c"), groups[1].second.map { it.id })
        assertEquals(listOf("d"), groups[2].second.map { it.id })
        assertEquals(3, groups.size)
    }

    /**
     * "Yesterday" is a calendar boundary, not a 24-hour window: something sent at 23:00 last
     * night is yesterday even when only a few hours have passed.
     */
    @Test
    fun `day labels follow calendar boundaries rather than elapsed hours`() {
        val now = at(year = 2026, month = Calendar.JULY, day = 26, hour = 1)
        val lateLastNight = at(year = 2026, month = Calendar.JULY, day = 25, hour = 23)

        val groups = groupByDay(listOf(entry("a", lateLastNight)), now)

        assertEquals("Yesterday", groups.single().first)
    }

    @Test
    fun `empty history produces no groups`() {
        assertEquals(emptyList<Pair<String, List<TransferHistoryEntry>>>(), groupByDay(emptyList()))
    }

    private fun entry(id: String, completedAt: Long) = TransferHistoryEntry(
        id = id,
        direction = TransferHistoryEntry.DIRECTION_SENT,
        filename = "$id.txt",
        size = 10,
        peerName = "Mac",
        completedAt = completedAt,
        status = TransferHistoryEntry.STATUS_COMPLETE,
        savedPath = null,
        error = null
    )

    private fun noonOn(year: Int, month: Int, day: Int) = at(year, month, day, hour = 12)

    private fun at(year: Int, month: Int, day: Int, hour: Int): Long {
        val calendar = Calendar.getInstance()
        calendar.set(year, month, day, hour, 0, 0)
        calendar.set(Calendar.MILLISECOND, 0)
        return calendar.timeInMillis
    }

    private companion object {
        const val HOUR = 3_600_000L
        const val DAY = 24 * HOUR
    }
}
