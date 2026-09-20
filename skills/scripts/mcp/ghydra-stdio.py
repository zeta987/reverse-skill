"""Launch GhydraMCP with clean stdio and the supported analysis tool."""

import argparse
from pathlib import Path
from bridge_compat import adapt_ghydra, run_bridge
from stdio_shutdown import run_cli

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bridge', type=Path, required=True)
    args = parser.parse_args()
    run_bridge(args.bridge, adapt_ghydra, redirect_print=True)


if __name__ == '__main__':
    run_cli(main)
