#!/usr/bin/env python3
"""Fetch Critical Maps at a pinned revision into .upstream/ and embed the harness in its app entry.

Patches are text replacements on the pinned sources. Each one asserts its anchor exists, so a
changed upstream fails loudly instead of silently running without the harness or the network guard.
"""
import argparse
from pathlib import Path
import shutil
import subprocess

HERE = Path(__file__).resolve().parent
CHECKOUT = HERE / '.upstream'
REPOSITORY = 'https://github.com/criticalmaps/criticalmaps-ios'
REVISION = 'ef2e06dbbddaae49a82bb66999d5983c1053c6e0'


def git(*args, cwd=CHECKOUT, **kwargs):
    return subprocess.run(['git', *args], cwd=cwd, check=True, text=True, **kwargs)


def fetch(source: Path | None):
    if not CHECKOUT.exists():
        CHECKOUT.mkdir(parents=True)
        git('init', '-q')
        git('remote', 'add', 'origin', str(source.resolve()) if source else REPOSITORY)
        git('fetch', '-q', '--depth', '1', 'origin', REVISION)
        git('checkout', '-q', '--detach', REVISION)
    actual = git('rev-parse', 'HEAD', capture_output=True).stdout.strip()
    if actual != REVISION:
        raise SystemExit(f'Unexpected upstream revision {actual}; refusing to patch')


def original(relative: str) -> str:
    """The pinned file's content, so setup is repeatable on an already-patched checkout."""
    return git('show', 'HEAD:' + relative, capture_output=True).stdout


def patch(relative: str, *replacements: tuple[str, str]):
    text = original(relative)
    for old, new in replacements:
        if old not in text:
            raise SystemExit(f'{relative}: anchor not found; upstream changed:\n{old}')
        text = text.replace(old, new, 1)
    (CHECKOUT / relative).write_text(text)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, help='Existing criticalmaps-ios clone containing the pinned revision; read only')
parser.add_argument('--no-project', action='store_true', help='Skip generating the Xcode project (headless only)')
args = parser.parse_args()
fetch(args.source)

# 1. Package manifest: let the headless host build the package for Mac Catalyst. Upstream only lists
#    iOS, so SwiftPM would default Catalyst to 13.0 and reject the iOS 17 APIs the features use.
patch('CriticalMapsKit/Package.swift', (
    '  platforms: [\n    .iOS(.v17)\n  ],',
    '  platforms: [\n    .iOS(.v17),\n    .macCatalyst(.v17)  // tca-harness: headless host\n  ],',
), (
    # Modules CriticalMapsHarness.swift names (models, shared keys, clients) as products.
    '    .singleTargetLibrary("Styleguide")\n  ],',
    '    .singleTargetLibrary("Styleguide"),\n'
    '    // tca-harness: modules the harness descriptors and fakes use\n'
    '    .singleTargetLibrary("FeedbackGeneratorClient"),\n    .singleTargetLibrary("NextRideFeature"),\n'
    '    .singleTargetLibrary("SharedKeys"),\n    .singleTargetLibrary("SharedModels"),\n'
    '    .singleTargetLibrary("UIApplicationClient")\n  ],',
))

# 2. App entry: retain the harness next to the original root store, record the timeline, and apply
#    the harness dependencies (network guard, fixed location, isolated storage) in harness runs only.
patch('iOS/App.swift',
  ('import SwiftUI\n', 'import SwiftUI\nimport TCAHarnessTCA1\n'),
  ('    AppFeature()\n  }\n', '    AppFeature().harnessTimeline()  // inert unless TCA_HARNESS=1\n  }\n'
                            '  @MainActor static let harness = CriticalMapsHarness.attach(to: store)\n'),
  ('      $0.serverConfiguration = configuration\n',
   '      $0.serverConfiguration = configuration\n'
   '      CriticalMapsHarness.prepare(&$0)  // no-op unless TCA_HARNESS=1\n'),
  ('    CriticalMapsShortcuts.updateAppShortcutParameters()\n',
   '    CriticalMapsShortcuts.updateAppShortcutParameters()\n'
   '    do { try Self.harness.startIfEnabled(defaultPort: 8793) } catch { print("Harness startup: \\(error)") }\n'),
)
harness = CHECKOUT / 'iOS/CriticalMapsHarness.swift'  # a link, so edits here reach the app build
harness.unlink(missing_ok=True)
harness.symlink_to(HERE / 'CriticalMapsHarness.swift')

if not args.no_project:
    if not shutil.which('xcodegen'):
        raise SystemExit('Install XcodeGen to generate the app project, or pass --no-project.')
    subprocess.run(['xcodegen', 'generate', '--spec', 'project.yml'], cwd=HERE, check=True)
print('Embedded the harness in Critical Maps at', REVISION[:12], '->', CHECKOUT)
