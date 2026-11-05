#!/usr/bin/env python3
"""Navigate upstream isowords and play a dictionary-valid word through its embedded runtime."""
import importlib.util
from pathlib import Path
import sqlite3
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('cli', HERE.parents[1] / 'cli/tca.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

def find_word(game):
    faces = {f['id']: f for f in game['faces']}
    def path_for(word, path=(), prefix=''):
        candidates = faces if not path else faces[path[-1]]['neighbors']
        for key in candidates:
            if key in path: continue
            next_prefix = prefix + faces[key]['letter'].upper()
            if not word.startswith(next_prefix): continue
            next_path = path + (key,)
            if next_prefix == word: return next_path
            found = path_for(word, next_path, next_prefix)
            if found: return found
    database = sqlite3.connect(HERE / '.upstream/Sources/DictionarySqliteClient/Dictionaries/Words.en.db')
    preferred = ['CUBES', 'WORDS', 'GAME', 'WORD', 'PLAY', 'READ', 'CODE', 'TEST', 'CATS', 'CAT', 'DOG', 'RED', 'SUN', 'SEA', 'SET', 'TEN', 'NET', 'ONE', 'TWO', 'THE', 'AND', 'SEE', 'EAT', 'TEA', 'ATE', 'ARE', 'EAR', 'ART']
    for word in preferred:
        if database.execute('SELECT 1 FROM words WHERE word = ?', (word,)).fetchone():
            path = path_for(word)
            if path: return word, path
    def search(path=(), prefix=''):
        candidates = faces if not path else faces[path[-1]]['neighbors']
        for key in candidates:
            if key in path: continue
            text = prefix + faces[key]['letter'].upper()
            row = database.execute('SELECT word FROM words WHERE word >= ? AND word < ? LIMIT 1', (text, text + 'ZZ')).fetchone()
            if not row: continue
            next_path = path + (key,)
            if len(text) >= 3 and row[0] == text: return text, next_path
            if len(text) < 6:
                result = search(next_path, text)
                if result: return result
    return search()

host = cli.Host(port=8767)
try:
    assert cli.run_goal(host, 'Open Solo game modes', 'jev-1.14.0', 'soloOpen', 5, step_delay=1)
    assert cli.run_goal(host, 'Start an unlimited solo game', 'jev-1.14.0', 'gameReady', 5, step_delay=1)
    game = host.call('observe')['observation']['state']['game']
    word, path = find_word(game)
    cli.emit('word_plan', word=word, faces=path, source='upstream board geometry and public-bootstrap dictionary')
    for face in path:
        for kind, goal in [('select-' + face, f'Select cube face {face} to build the word {word}.'),
                           ('release', f'Release the selected cube face now, preserving the word selection for {word}.')]:
            observation = host.call('observe')['observation']
            if kind == 'release':
                # Ending the gesture is mechanical, not another semantic model choice.
                candidate = next(c for c in observation['candidates'] if '/release@' in c['id'])
                decision = {'choice': candidate['id']}
                cli.emit('gesture_release', **decision)
            else:
                decision = cli.decide(observation, goal, 'jev-1.14.0')
                cli.emit('decision', goal=goal, **decision)
                assert f'/{kind}@' in decision['choice'], decision
            response = host.dispatch(decision['choice'], revision=observation['revision'])
            cli.emit('dispatch', **response)
            assert response['ok'], response
            time.sleep(1)
    assert host.observation['state']['game']['selectedWord'].upper() == word
    assert host.observation['state']['game']['valid'] is True
    assert cli.run_goal(host, f'Submit the selected word {word}', 'jev-1.14.0', 'wordAccepted', 4, step_delay=1)
    game = host.observation['state']['game']
    assert any(w['word'].upper() == word for w in game['playedWords']), game
    assert game['score'] > 0
    cli.emit('gameplay_verified', word=word, score=game['score'], playedWords=game['playedWords'])
finally:
    host.close()
