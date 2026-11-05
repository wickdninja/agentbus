"""Time phrases. Every test's docstring names the bug it catches."""
import datetime
import os
import time
import unittest

from load_agentbus import ab


def at(hours=0, seconds=0):
    """The stored form (UTC, to the second) of a moment relative to 2026-03-10 12:00:00Z, and the moment itself."""
    t = datetime.datetime(2026, 3, 10, 12, tzinfo=datetime.timezone.utc) + datetime.timedelta(hours=hours, seconds=seconds)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ"), t


NOW = at()[1]


class Ago(unittest.TestCase):
    def test_boundaries(self):
        """Bug: an off-by-one at a unit edge says 60s, 60m or 24h."""
        for seconds, want in ((0, "now"), (4, "now"), (5, "5s"), (59, "59s"), (60, "1m"), (3599, "59m"),
                              (3600, "1h"), (86399, "23h"), (86400, "1d"), (172800, "2d")):
            self.assertEqual(ab.ago(at(seconds=-seconds)[0], NOW), want, seconds)

    def test_a_time_in_the_future_is_now(self):
        """Bug: clock skew between agents prints a negative age."""
        self.assertEqual(ab.ago(at(hours=1)[0], NOW), "now")

    def test_a_value_this_tool_did_not_write(self):
        """Bug: a planted timestamp raises in a listing instead of showing ?."""
        for bad in ("yesterday", "2026-03-10", "2026-03-10T12:00:00+00:00", None, 7):
            self.assertEqual(ab.ago(bad, NOW), "?", bad)
            self.assertEqual(ab.time_left(bad, NOW), "?", bad)


class TimeLeft(unittest.TestCase):
    def test_boundaries(self):
        """Bug: a claim with 90 minutes left shows 90m or 1h 3m."""
        for seconds, want in ((59, "0m"), (60, "1m"), (3599, "59m"), (3600, "1h 00m"), (5400, "1h 30m"), (90000, "25h 00m")):
            self.assertEqual(ab.time_left(at(seconds=seconds)[0], NOW), want, seconds)

    def test_expired_is_zero(self):
        """Bug: an expired claim shows a negative time."""
        self.assertEqual(ab.time_left(at(hours=-1)[0], NOW), "0m")


class HumanSpan(unittest.TestCase):
    def test_largest_units_that_say_it(self):
        """Bug: a claim's length reads 119m, 1h 0m or 1d 0h."""
        for seconds, want in ((45, "45s"), (0, "0s"), (59, "59s"), (60, "1m"), (3599, "59m"), (3600, "1h"), (7140, "1h 59m"),
                              (86399, "23h 59m"), (86400, "1d"), (601200, "6d 23h")):
            self.assertEqual(ab.human_span(seconds), want, seconds)


class HumanTime(unittest.TestCase):
    def setUp(self):
        self.addCleanup(self.zone, os.environ.get("TZ"))

    def zone(self, name):
        if name is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = name
        time.tzset()

    def test_today_and_another_day(self):
        """Bug: a stamp from another day reads as today's, or today's carries a date."""
        self.zone("UTC0")
        self.assertEqual(ab.human_time(at(hours=-2)[0], NOW), "10:00")
        self.assertEqual(ab.human_time(at(hours=-24)[0], NOW), "Mar 9 12:00")

    def test_today_is_the_readers_day_not_utc(self):
        """Bug: `today` is compared in UTC, so a late evening stamp shows a date, or the wrong clock time."""
        self.zone("XXX-9")  # UTC+9: 12:00Z is 21:00, 16:00Z is 01:00 the next day
        self.assertEqual(ab.human_time(at()[0], NOW), "21:00")
        self.assertEqual(ab.human_time(at(hours=4)[0], NOW), "Mar 11 01:00")
        self.assertEqual(ab.human_time(at(hours=4)[0], at(hours=4)[1]), "01:00")

    def test_a_value_this_tool_did_not_write_is_returned_as_it_is(self):
        """Bug: a planted time raises, or is shown as some other time."""
        self.assertEqual(ab.human_time("soon", NOW), "soon")

    def test_until_phrase(self):
        """Bug: the claim confirmation's length and end disagree in format."""
        self.zone("UTC0")
        self.assertEqual(ab.until_phrase(7200, at(hours=2)[0], NOW), "for 2h (until 14:00)")


if __name__ == "__main__":
    unittest.main()
