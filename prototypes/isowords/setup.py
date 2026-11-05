#!/usr/bin/env python3
"""Prepare the historical Home/Settings feature host; see examples/isowords for the actual app."""
import argparse
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / 'examples/isowords'))
from upstream import prepare

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--checkout', type=Path)
parser.add_argument('--skip-project', action='store_true')
parser.add_argument('--source', type=Path, help='Optional existing checkout, read only')
args = parser.parse_args()
prepare(args.checkout or HERE / '.upstream', args.source)
if not args.skip_project:
    subprocess.run(['xcodegen', 'generate', '--spec', 'project.yml'], cwd=HERE, check=True)
print('Prepared historical feature host at', args.checkout or HERE / '.upstream')
