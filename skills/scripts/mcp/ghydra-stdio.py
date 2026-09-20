"""Keep GhydraMCP module diagnostics off the MCP stdout transport."""

import argparse
import builtins
from pathlib import Path
import runpy
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bridge', type=Path, required=True)
args = parser.parse_args()
bridge = args.bridge.resolve(strict=True)


def diagnostic_print(*values, **kwargs):
    kwargs.setdefault('file', sys.stderr)
    builtins.print(*values, **kwargs)


sys.argv = [str(bridge)]
runpy.run_path(str(bridge), run_name='__main__', init_globals={'print': diagnostic_print})
