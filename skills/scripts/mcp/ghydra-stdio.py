"""Launch GhydraMCP with clean stdio and the supported analysis tool."""

import argparse
from pathlib import Path
from bridge_compat import adapt_ghydra, run_bridge

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bridge', type=Path, required=True)
args = parser.parse_args()
run_bridge(args.bridge, adapt_ghydra, redirect_print=True)
