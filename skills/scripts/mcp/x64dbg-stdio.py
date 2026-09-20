"""Launch the installed x64dbg bridge in stdio server mode."""
import argparse
from pathlib import Path
from bridge_compat import adapt_x64dbg, run_bridge

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bridge', type=Path, required=True)
args = parser.parse_args()
run_bridge(args.bridge, adapt_x64dbg, arguments=('serve',))
