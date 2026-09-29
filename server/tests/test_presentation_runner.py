from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from scripts import presentation_runner as runner


class LauncherTest(unittest.TestCase):
    def test_missing_model_fails_without_starting_or_downloading_anything(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "RUNTIME", Path(temporary)), patch.object(
            runner, "require_free_ports"
        ), patch.object(runner.shutil, "which", return_value="installed"), patch.object(
            runner, "get_json", return_value={"models": []}
        ), patch.object(runner.subprocess, "Popen") as spawn:
            with self.assertRaisesRegex(RuntimeError, "No model was downloaded"):
                runner.run()
            spawn.assert_not_called()

    def test_second_launcher_refuses_without_spawning_processes(self):
        import fcntl
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "RUNTIME", Path(temporary)):
            with (Path(temporary) / "launcher.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch.object(runner.subprocess, "Popen") as spawn:
                    with self.assertRaisesRegex(RuntimeError, "already running"):
                        runner.run()
                    spawn.assert_not_called()

    def test_occupied_port_refuses_without_replacing_existing_server(self):
        with patch.object(runner.socket, "socket") as socket:
            socket.return_value.__enter__.return_value.bind.side_effect = OSError("in use")
            with self.assertRaisesRegex(RuntimeError, "No process was replaced"):
                runner.require_free_ports()

    def test_readiness_detects_child_failure_and_cleanup_targets_owned_children(self):
        child = Mock(pid=12345)
        child.poll.return_value = 1
        with self.assertRaisesRegex(RuntimeError, "exited before readiness"):
            runner.Supervisor.wait_ready(child, "http://unused")
        supervisor = runner.Supervisor()
        child.poll.return_value = None
        supervisor.children = [("owned", child)]
        with patch.object(runner.os, "killpg") as kill:
            supervisor.close()
        kill.assert_called_once_with(12345, runner.signal.SIGTERM)
        child.wait.assert_called_once_with(timeout=8)
