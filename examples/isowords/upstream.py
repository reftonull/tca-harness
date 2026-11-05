"""Pinned upstream preparation shared by the integration example and historical fixture."""
import json
import os
from pathlib import Path
import shutil
import subprocess

REVISION = 'c727d3a7c49cf0c98f2fa4f24c562f81e30165f7'


def prepare(checkout: Path, source: Path | None = None):
    if not shutil.which('git') or not shutil.which('git-lfs'):
        raise SystemExit('Install git and git-lfs before preparing isowords.')
    checkout = checkout.resolve()
    source = source.resolve() if source else None
    if not checkout.exists():
        env = dict(os.environ, GIT_LFS_SKIP_SMUDGE='1')
        command = ['git', 'clone'] + (['--shared', str(source)] if source else ['https://github.com/pointfreeco/isowords']) + [str(checkout)]
        subprocess.run(command, check=True, env=env)
        subprocess.run(['git', '-C', str(checkout), 'checkout', '--detach', REVISION], check=True, env=env)
    actual = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != REVISION:
        raise SystemExit('Unexpected upstream revision; refusing to patch')
    # Client compatibility edits below leave reducers and views unchanged.
    manifest = subprocess.check_output(['git', '-C', str(checkout), 'show', 'HEAD:Package.swift'], text=True)
    pins = json.loads((Path(__file__).parent / 'client-pins.json').read_text())
    constraints = '\n'.join('  .package(url: '+json.dumps(p['url'])+', exact: '+json.dumps(p['version'])+'),' for p in pins)
    manifest = manifest.replace('// MARK: - client', '// Harness-only client dependency pins.\npackage.dependencies = [\n'+constraints+'\n]\n\n// MARK: - client')
    (checkout / 'Package.swift').write_text(manifest)
    # Current DependencyClient expansion initializes endpoints through setters. Keep
    # all ordinary stored properties before endpoints to satisfy definite initialization.
    game_center = checkout / 'Sources/ComposableGameCenter/Interface.swift'
    original = subprocess.check_output(['git', '-C', str(checkout), 'show', 'HEAD:Sources/ComposableGameCenter/Interface.swift'], text=True)
    ordinary = '  public var turnBasedMatch: TurnBasedMatchClient\n  public var turnBasedMatchmakerViewController: TurnBasedMatchmakerViewControllerClient\n'
    original = original.replace(ordinary, '')
    original = original.replace('  public var reportAchievements:', ordinary + '  public var reportAchievements:', 1)
    game_center.write_text(original)
    for filename, flavor, indent in [('TestKey.swift', 'noop', '    '), ('LiveKey.swift', 'live', '        ')]:
        relative = 'Sources/ComposableGameCenter/' + filename
        text = subprocess.check_output(['git', '-C', str(checkout), 'show', 'HEAD:' + relative], text=True)
        tail = indent + 'turnBasedMatch: .' + flavor + ',\n' + indent + 'turnBasedMatchmakerViewController: .' + flavor
        text = text.replace(',\n' + tail, '', 1)
        text = text.replace(indent + 'reportAchievements:', tail + ',\n' + indent + 'reportAchievements:', 1)
        (checkout / relative).write_text(text)
    fonts = checkout / 'Sources/Styleguide/Fonts'
    fonts.mkdir(parents=True, exist_ok=True)
    (fonts / 'HarnessPlaceholder.txt').write_text('Development resource placeholder. Proprietary fonts are not distributed; use system fallback.\n')
    names = subprocess.check_output(['git', '-C', str(checkout), 'lfs', 'ls-files', '-n'], text=True).splitlines()
    needed = [name for name in names if name.startswith(('Sources/', 'App/iOS/'))]
    if source:
        for name in needed:
            original = source / name
            destination = checkout / name
            if original.exists() and not original.read_bytes().startswith(b'version https://git-lfs.github.com/spec/v1'):
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(original, destination)
    if any((checkout / name).read_bytes().startswith(b'version https://git-lfs.github.com/spec/v1') for name in needed if (checkout / name).exists()):
        subprocess.run(['git', '-C', str(checkout), 'lfs', 'pull', '--include=Sources/**,App/iOS/**'], check=True)
