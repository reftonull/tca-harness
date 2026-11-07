#!/usr/bin/env python3
"""Play a long unlimited isowords game through the embedded harness, one real TCA action at a time.

Each turn reads the live board from the app's published state, searches it for the highest-scoring
word in the app's own dictionary, then selects each cube face, releases the gesture and submits,
using only operations the harness offers. Score and played words are read back from app state.

Usage: python3 examples/isowords/play_long.py [--port 8767] [--words 60] [--pace 0.35] > run.jsonl

The `finished` event reports the actions dispatched during play (setup navigation excluded),
actions per second, and median / p95 milliseconds per action (one observe plus one dispatch).
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sqlite3
import statistics
import sys
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('cli', HERE.parents[1] / 'cli/tca.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

# Upstream Sources/SharedModels/Scoring.swift.
LETTERS = dict(A=1, B=4, C=4, D=3, E=1, F=5, G=3, H=5, I=1, J=9, K=6, L=2, M=4, N=2, O=1, P=4, Q=12,
               R=2, S=1, T=2, U=1, V=5, W=5, X=9, Y=5, Z=11)


def score(word):
    return sum(LETTERS.get(c, 0) for c in word) * len(word) * max(1, len(word) - 3)


def load_dictionary():
    database = HERE / '.upstream/Sources/DictionarySqliteClient/Dictionaries/Words.en.db'
    words, prefixes = set(), set()
    for (word,) in sqlite3.connect(database).execute('SELECT word FROM words WHERE length(word) BETWEEN 3 AND 14'):
        words.add(word)
        prefixes.update(word[:i] for i in range(1, len(word)))
    return words, prefixes


def best_words(faces, words, prefixes, played, limit=5):
    """Every dictionary word traceable through adjacent faces, best score first. Each face once per word."""
    found = {}

    def walk(path, text):
        if len(text) >= 3 and text in words and text not in played:
            if text not in found or len(path) < len(found[text]):
                found[text] = path
        if text in prefixes:
            for key in faces[path[-1]]['neighbors']:
                if key in faces and key not in path:
                    walk(path + [key], text + faces[key]['letter'].upper())

    for key, face in faces.items():
        walk([key], face['letter'].upper())
    return sorted(found.items(), key=lambda item: (-score(item[0]), item[0]))[:limit]


def emit(event, **data):
    print(json.dumps(dict(event=event, t=round(time.time(), 3), **data)), flush=True)


class Player:
    def __init__(self, port, pace):
        self.host = cli.Host(port=port)
        self.pace = pace
        self.latencies = []  # seconds per dispatched action: observe + dispatch round trips

    def game(self):
        return self.host.call('observe')['observation']['state']['game']

    def act(self, name, attempts=3):
        """Dispatch the offered operation with this route name at the current revision."""
        for _ in range(attempts):
            began = time.perf_counter()
            observation = self.host.call('observe')['observation']
            candidate = next((c for c in observation['candidates'] if cli.route(c['id']).rsplit('/', 1)[-1] == name), None)
            if candidate is None:
                raise RuntimeError(f'{name} is not offered; offered: ' + ', '.join(cli.route(c['id']) for c in observation['candidates'])[:400])
            response = self.host.dispatch(candidate['id'], revision=observation['revision'])
            if response.get('error') == 'stale_revision':
                time.sleep(0.05)
                continue
            if not response.get('ok'):
                raise RuntimeError(f"{name}: {response.get('error')} {response.get('detail') or ''}")
            self.latencies.append(time.perf_counter() - began)
            time.sleep(self.pace)
            return response
        raise RuntimeError(f'{name}: state kept changing')

    def ensure_game(self):
        observation = self.host.call('observe')['observation']
        names = {cli.route(c['id']).rsplit('/', 1)[-1] for c in observation['candidates']}
        if 'openSolo' in names:
            self.act('openSolo')
            time.sleep(1)
            observation = self.host.call('observe')['observation']
            names = {cli.route(c['id']).rsplit('/', 1)[-1] for c in observation['candidates']}
        if 'startUnlimited' in names:
            self.act('startUnlimited')
            time.sleep(2)
        game = self.game()
        if not (game and game.get('ready')):
            raise RuntimeError('No ready game after navigation')
        return game

    def play_word(self, word, path):
        game = self.game()
        if game['selectedWord']:
            self.act('clear')
        for face in path:
            self.act('select-' + face)
            self.act('release')
        game = self.game()
        if game['selectedWord'].upper() != word or not game['valid']:
            self.act('clear')
            return False
        self.act('submit')
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--port', type=int, default=8767)
    parser.add_argument('--words', type=int, default=60, help='Stop after this many accepted words')
    parser.add_argument('--pace', type=float, default=0.35, help='Seconds between actions, so the UI animates')
    args = parser.parse_args()

    words, prefixes = load_dictionary()
    player = Player(args.port, args.pace)
    game = player.ensure_game()
    emit('game_ready', score=game['score'])
    started = time.time()
    setup_actions = len(player.latencies)
    rejected = set()
    while True:
        game = player.game()
        played = {w['word'].upper() for w in game['playedWords']}
        if len(played) >= args.words:
            break
        faces = {f['id']: f for f in game['faces']}
        options = best_words(faces, words, prefixes, played | rejected)
        if not options:
            emit('no_words_left', faces=len(faces))
            break
        word, path = options[0]
        emit('plan', word=word, value=score(word), faces=path, alternatives=[w for w, _ in options[1:]])
        before = game['score']
        if not player.play_word(word, path):
            rejected.add(word)
            emit('word_rejected_by_app', word=word)
            continue
        game = player.game()
        emit('word_played', word=word, gained=game['score'] - before, score=game['score'],
             words=len(game['playedWords']), facesLeft=len(game['faces']))
    game = player.game()
    seconds = time.time() - started
    latencies = player.latencies[setup_actions:]
    emit('finished', score=game['score'], words=[w['word'] for w in game['playedWords']],
         seconds=round(seconds, 1), actions=len(latencies),
         actionsPerSecond=round(len(latencies) / seconds, 1) if seconds else None,
         medianActionMs=round(statistics.median(latencies) * 1000, 2) if latencies else None,
         p95ActionMs=round(statistics.quantiles(latencies, n=20)[-1] * 1000, 2) if len(latencies) > 1 else None)
    player.host.close()


if __name__ == '__main__':
    sys.exit(main())
