"""Check local SIGINT, EOF and failure handling without touching a real Host."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

LAUNCHERS = Path(__file__).resolve().parent / 'mcp'
FIXTURE = '''
import asyncio
from contextlib import asynccontextmanager
import os
import signal
import sys
from mcp.server.fastmcp import FastMCP

if os.environ['REVERSE_FIXTURE_MODE'] == 'error':
    raise RuntimeError('shutdown-fixture-real-error')

@asynccontextmanager
async def lifespan(app):
    try:
        if os.environ['REVERSE_FIXTURE_MODE'] == 'interrupt':
            # raise_signal affects only this test child, never the user's console.
            asyncio.get_running_loop().call_soon(signal.raise_signal, signal.SIGINT)
        yield {}
    finally:
        print('shutdown-fixture-cleanup-complete', file=sys.stderr)

mcp = FastMCP('shutdown-fixture', lifespan=lifespan)
if __name__ == '__main__':
    mcp.run(transport='stdio')
'''


class ShutdownTests(unittest.TestCase):
    def run_fixture(self, mode, launcher, legacy):
        with tempfile.TemporaryDirectory(prefix='reverse-mcp-shutdown-') as directory:
            fixture = Path(directory) / 'fixture.py'
            fixture.write_text(textwrap.dedent(FIXTURE), encoding='utf-8')
            if launcher is None:
                args = [str(LAUNCHERS / 'legacy-mcp-stdio.py'), '--script', str(fixture)]
            else:
                args = [str(LAUNCHERS / launcher), '--bridge', str(fixture)]
                if legacy:
                    args = [str(LAUNCHERS / 'legacy-mcp-stdio.py'), '--script', args[0], '--', *args[1:]]
            return subprocess.run(
                [sys.executable, *args], input='', capture_output=True, text=True,
                encoding='utf-8', errors='replace', timeout=15,
                env={**os.environ, 'REVERSE_FIXTURE_MODE': mode, 'PYTHONUTF8': '1'},
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0,
            )

    def cases(self):
        return [(None, True), ('ghydra-stdio.py', False), ('x64dbg-stdio.py', False),
                ('ghydra-stdio.py', True), ('x64dbg-stdio.py', True)]

    def test_sigint_unwinds_cleanup_without_traceback(self):
        for launcher, legacy in self.cases():
            with self.subTest(launcher=launcher, legacy=legacy):
                result = self.run_fixture('interrupt', launcher, legacy)
                self.assertIn('shutdown-fixture-cleanup-complete', result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                self.assertNotIn('KeyboardInterrupt', result.stderr)
                self.assertEqual(result.returncode, 130, result.stderr)
                self.assertEqual(result.stdout, '')

    def test_eof_still_exits_successfully(self):
        for launcher, legacy in self.cases():
            with self.subTest(launcher=launcher, legacy=legacy):
                result = self.run_fixture('eof', launcher, legacy)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('shutdown-fixture-cleanup-complete', result.stderr)
                self.assertNotIn('Traceback', result.stderr)

    def test_real_errors_remain_visible(self):
        for launcher, legacy in self.cases():
            with self.subTest(launcher=launcher, legacy=legacy):
                result = self.run_fixture('error', launcher, legacy)
                self.assertEqual(result.returncode, 1)
                self.assertIn('RuntimeError: shutdown-fixture-real-error', result.stderr)
                self.assertIn('Traceback', result.stderr)


if __name__ == '__main__':
    unittest.main()
