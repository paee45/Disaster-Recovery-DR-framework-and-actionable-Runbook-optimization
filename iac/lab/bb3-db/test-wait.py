import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch


SPEC = importlib.util.spec_from_file_location("bb3_wait", Path(__file__).with_name("bb3-wait.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class TerminalOutput(io.StringIO):
    def isatty(self):
        return True


class WaitTests(unittest.TestCase):
    def test_terminal_updates_same_line_and_finishes(self):
        child = Mock()
        child.wait.side_effect = [subprocess.TimeoutExpired("fixture", 1),
                                  subprocess.TimeoutExpired("fixture", 1), 0]
        child.poll.return_value = 0
        output = TerminalOutput()
        with patch.object(MODULE.subprocess, "Popen", return_value=child) as launch:
            result = MODULE.run_wait("Primary creation", ["aws", "--profile", "fixture"], output,
                                     clock=Mock(side_effect=[0, 0, 1, 2, 3]))
        self.assertEqual(result, 0)
        self.assertIn("elapsed 00:00:01", output.getvalue())
        self.assertIn("elapsed 00:00:02", output.getvalue())
        self.assertEqual(output.getvalue().count("\n"), 1)
        self.assertGreaterEqual(output.getvalue().count("\r"), 3)
        self.assertIn("complete", output.getvalue())
        self.assertEqual(launch.call_args.args[0][-3:], ["aws", "--profile", "fixture"])

    def test_redirected_output_does_not_emit_tick_lines(self):
        child = Mock()
        child.wait.side_effect = [subprocess.TimeoutExpired("fixture", 1), 7]
        child.poll.return_value = 7
        output = io.StringIO()
        with patch.object(MODULE.subprocess, "Popen", return_value=child):
            result = MODULE.run_wait("Replica creation", ["fixture"], output,
                                     clock=Mock(side_effect=[0, 0, 2]))
        self.assertEqual(result, 7)
        self.assertEqual(output.getvalue().count("\n"), 2)
        self.assertNotIn("\r", output.getvalue())
        self.assertIn("stopped (exit 7)", output.getvalue())

    def test_interrupt_terminates_owned_wait_process(self):
        child = Mock(pid=12345)
        child.wait.side_effect = [KeyboardInterrupt(), 0]
        child.poll.return_value = None
        output = TerminalOutput()
        with patch.object(MODULE.subprocess, "Popen", return_value=child), \
                patch.object(MODULE.os, "killpg") as terminate:
            result = MODULE.run_wait("Waiting", ["fixture"], output)
        self.assertEqual(result, 130)
        terminate.assert_called_once_with(12345, MODULE.signal.SIGTERM)
        self.assertIn("stopped (exit 130)", output.getvalue())

    def test_elapsed_hours(self):
        self.assertEqual(MODULE.elapsed_text(3661), "01:01:01")

    def test_terminal_lines_fit_narrow_width(self):
        child = Mock()
        child.wait.return_value = 0
        child.poll.return_value = 0
        output = TerminalOutput()
        with patch.object(MODULE.subprocess, "Popen", return_value=child), \
                patch.object(MODULE.shutil, "get_terminal_size", return_value=Mock(columns=40)):
            result = MODULE.run_wait("Waiting for restored primary availability", ["fixture"], output,
                                     clock=lambda: 0)
        self.assertEqual(result, 0)
        for line in output.getvalue().split("\r")[1:]:
            self.assertLessEqual(len(line.rstrip("\n")), 39)
        self.assertIn("00:00:00 | complete", output.getvalue())

    def test_termination_signals_use_interrupt_cleanup(self):
        with patch.object(MODULE.signal, "signal") as register, \
                patch.object(MODULE, "run_wait", return_value=130) as wait:
            self.assertEqual(MODULE.main(["Waiting", "fixture"]), 130)
        wait.assert_called_once_with("Waiting", ["fixture"])
        self.assertEqual([call.args[0] for call in register.call_args_list],
                         [MODULE.signal.SIGTERM, MODULE.signal.SIGHUP])
        for call in register.call_args_list:
            with self.assertRaises(KeyboardInterrupt):
                call.args[1](call.args[0], None)


if __name__ == "__main__":
    unittest.main()