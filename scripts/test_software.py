"""Offline test entrypoint: fail closed on serial, camera, or external HTTP access."""
from contextlib import ExitStack
import os
import faulthandler
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def forbidden(*args, **kwargs):
    raise AssertionError("Hardware/network access is forbidden in software verification")


if __name__ == '__main__':
    faulthandler.dump_traceback_later(300, repeat=True)
    with ExitStack() as stack:
        stack.enter_context(patch.dict(os.environ, {
            'VISION_ENABLED': 'false', 'VISION_REQUIRED': 'false',
            'CAMERA_PREVIEW_MODE': 'off', 'PRESENTATION_MODE': 'false',
        }))
        for target in ('serial.Serial', 'cv2.VideoCapture',
                       'httpx.HTTPTransport.handle_request', 'httpx.AsyncHTTPTransport.handle_async_request'):
            stack.enter_context(patch(target, side_effect=forbidden))
        # Load AI tests only after server tests to preserve the server's no-ML-import assertion.
        groups = [sys.argv[1:]] if sys.argv[1:] else [
            ['.'.join(path.with_suffix('').parts) for path in sorted(Path(folder).glob('test_*.py'))]
            for folder in ('server/tests', 'ai/tests')]
        results = []
        for names in groups:
            suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromName(name) for name in names)
            results.append(unittest.TextTestRunner(verbosity=2).run(suite))
        print(f"Total: {sum(result.testsRun for result in results)} tests")
        sys.exit(not all(result.wasSuccessful() for result in results))
