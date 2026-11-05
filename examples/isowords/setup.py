#!/usr/bin/env python3
"""Embed the local harness in an isolated clone's actual iOS AppDelegate store."""
import argparse
from pathlib import Path
import shutil
import sqlite3
import subprocess
from upstream import prepare

HERE = Path(__file__).resolve().parent
CHECKOUT = HERE / '.upstream'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, help='Optional cached isowords checkout; read only')
parser.add_argument('--words', type=Path, default=Path('/usr/share/dict/words'), help='Word list for the public-bootstrap dictionary')
args = parser.parse_args()
if not shutil.which('xcodegen'):
    raise SystemExit('Install XcodeGen before preparing the example.')
if not args.words.is_file():
    raise SystemExit('Word list unavailable; supply --words /path/to/word-list.txt')
prepare(CHECKOUT, args.source)
# Follow upstream's public bootstrap: system word list plus CUBES and REMOVES.
database = CHECKOUT / 'Sources/DictionarySqliteClient/Dictionaries/Words.en.db'
database.parent.mkdir(parents=True, exist_ok=True)
if not database.exists():
    words = {w.strip().upper() for w in args.words.read_text().splitlines()}
    words |= {'CUBES', 'REMOVES'}
    words = sorted(w for w in words if len(w) >= 3 and w.isascii() and w.isalpha())
    with sqlite3.connect(database) as connection:
        connection.execute('CREATE TABLE words (word varchar(256) NOT NULL UNIQUE)')
        connection.executemany('INSERT INTO words VALUES (?)', ((word,) for word in words))
for library in ['AppAudioLibrary', 'AppClipAudioLibrary']:
    directory = CHECKOUT / 'Sources' / library / 'Resources'
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'HarnessPlaceholder.txt').write_text('Public bootstrap: proprietary audio is unavailable. Harness mode uses no-op audio.\n')
shutil.copyfile(CHECKOUT / 'Sources/ApiClientLive/Secrets.swift.example', CHECKOUT / 'Sources/ApiClientLive/Secrets.swift')
# Upstream's debug in-memory database tries to create a directory for ':memory:'.
# Modern Foundation rejects that URL; keep real SQLite and skip file setup for it.
relative = 'Sources/LocalDatabaseClient/Live.swift'
text = subprocess.check_output(['git', '-C', str(CHECKOUT), 'show', 'HEAD:' + relative], text=True)
text = text.replace("""        try! FileManager.default.createDirectory(
          at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )""", """        if path.isFileURL {
          try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
          )
        }""")
(CHECKOUT / relative).write_text(text)
source = subprocess.check_output(['git', '-C', str(CHECKOUT), 'show', 'HEAD:App/iOS/App.swift'], text=True)
source = source.replace('import SwiftUI\n', 'import SwiftUI\nimport TCAHarnessTCA1\n', 1)
# Record every reduced action for `tca devtools`; inert unless TCA_HARNESS=1.
source = source.replace('    AppReducer().transformDependency(', '    AppReducer().harnessTimeline().transformDependency(', 1)
source = source.replace('final class AppDelegate: NSObject, UIApplicationDelegate {', 'final class AppDelegate: NSObject, UIApplicationDelegate {\n  private lazy var agentHarness = EmbeddedIsowordsHarness.attach(to: store)')
source = source.replace('      $0.serverConfig = .live(apiClient: $0.apiClient, build: $0.build)', '''      $0.serverConfig = .live(apiClient: $0.apiClient, build: $0.build)
      if ProcessInfo.processInfo.environment["TCA_HARNESS"] == "1" {
        configureHarnessDependencies(&$0)
      }''')
source = source.replace('    self.store.send(.appDelegate(.didFinishLaunching))', '''    do { try agentHarness.startIfEnabled(defaultPort: 8767) }
    catch { print("Harness startup: \\(error)") }
    self.store.send(.appDelegate(.didFinishLaunching))''')
(CHECKOUT / 'App/iOS/App.swift').write_text(source)
shutil.copyfile(HERE / 'EmbeddedIsowordsHarness.swift', CHECKOUT / 'App/iOS/EmbeddedIsowordsHarness.swift')
subprocess.run(['xcodegen', 'generate', '--spec', 'project.yml'], cwd=HERE, check=True)
print('Embedded harness in actual upstream AppDelegate store:', CHECKOUT)
