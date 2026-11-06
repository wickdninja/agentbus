"""What a hook prints. The harness reads this one JSON object from stdout, so the shape is a contract: context only
for the events that take it, a notice in systemMessage, and never a field that blocks or stops the session. Every
test's docstring names the bug it catches."""
import unittest

from load_agentbus import ab

FORBIDDEN = {"decision", "continue", "permissionDecision", "stopReason", "suppressOutput", "reason"}


class Render(unittest.TestCase):
    def test_context_goes_in_additional_context_for_events_that_take_it(self):
        """Bug: context is printed at the top level, and the harness ignores it."""
        for event in ab.HOOK_CONTEXT_EVENTS:
            self.assertEqual(ab.hook_render(event, "ctx", None), {"hookSpecificOutput": {"hookEventName": event, "additionalContext": "ctx"}})

    def test_stop_and_session_end_take_no_context(self):
        """Bug: context printed for Stop makes the harness treat it as a block reason and keep the agent going."""
        for event in ("Stop", "SessionEnd", "Nope"):
            self.assertIsNone(ab.hook_render(event, "ctx", None))
            self.assertEqual(ab.hook_render(event, "ctx", "note"), {"systemMessage": "note"})

    def test_a_notice_is_a_system_message(self):
        """Bug: the person-only notice is put in the agent's context, or dropped."""
        self.assertEqual(ab.hook_render("SessionStart", None, "note"), {"systemMessage": "note"})
        both = ab.hook_render("UserPromptSubmit", "ctx", "note")
        self.assertEqual(set(both), {"hookSpecificOutput", "systemMessage"})

    def test_nothing_to_say_prints_nothing(self):
        """Bug: an empty object is printed on every hook, and a harness that reads it as output shows noise."""
        for context, notice in ((None, None), ("", ""), (None, ""), ("", None)):
            self.assertIsNone(ab.hook_render("SessionStart", context, notice))

    def test_never_a_field_that_blocks_the_session(self):
        """Bug: a render path adds decision, continue or permissionDecision, and a hook that should only advise stops the agent."""
        for event in ("SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "SessionEnd"):
            out = ab.hook_render(event, "c", "n")
            self.assertFalse(FORBIDDEN & set(out), event)
            self.assertFalse(FORBIDDEN & set(out.get("hookSpecificOutput", {})), event)

    def test_the_context_events_are_the_ones_the_contract_names(self):
        """Bug: Stop joins the list, and every end of turn is a block."""
        self.assertEqual(ab.HOOK_CONTEXT_EVENTS, ("SessionStart", "UserPromptSubmit", "PreToolUse"))


if __name__ == "__main__":
    unittest.main()
