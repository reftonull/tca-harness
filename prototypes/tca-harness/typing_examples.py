#!/usr/bin/env python3
"""Three live text-input examples: literal Unicode, generated multiline notes, and a targeted edit."""
import copy
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'cli'))
import tca as cli

host = cli.Host(port=8765)
try:
    assert host.dispatch('root/resetButtonTapped')['ok']
    cases = [
        ('unicode',
         'Create a new personal task titled exactly "Book a table for Zoë 🍜". '
         'Set notes to exactly "Friday, 7 pm — ask for a window seat.". Use normal priority and no due date.',
         {'fields': {'title': 'Book a table for Zoë 🍜', 'notes': 'Friday, 7 pm — ask for a window seat.',
                     'priority': 'normal', 'project': 'personal', 'dueDate': ''}}),
        ('generated-notes',
         'Create a new work task titled exactly "Prepare harness demo" with high priority and no due date. '
         'Write an original five-item checklist in its notes, with each numbered item on a separate line: '
         'build the package, exercise nested routes, check Unicode input, test cancellation, and record the simulator. '
         'Make each item a useful concrete instruction; keep the total notes under 800 characters.',
         {'fields': {'title': 'Prepare harness demo', 'priority': 'high', 'project': 'work', 'dueDate': ''},
          'notesMinLength': 150, 'notesContain': ['build', 'Unicode', 'cancel', 'simulator']}),
        ('targeted-edit',
         'Edit the existing task titled "Book a table for Zoë 🍜". Rename it to exactly "Book a table for Zoë & 李 🍜" '
         'and set its priority to high. Replace its notes with exactly the following two lines:\n'
         'Friday, 7 pm — ask for a window seat.\nConfirm by Thursday.\n'
         'Keep its project and due date unchanged. Leave all other tasks unchanged.',
         {'fields': {'title': 'Book a table for Zoë & 李 🍜',
                     'notes': 'Friday, 7 pm — ask for a window seat.\nConfirm by Thursday.',
                     'priority': 'high', 'project': 'personal', 'dueDate': ''}}),
    ]
    for name, goal, expectation in cases:
        before = copy.deepcopy(host.observation['state']['tasks'])
        cli.emit('example', name=name, goal=goal)
        assert cli.run_goal(host, goal, 'jev-1.14.0', None, max_steps=4, step_delay=2,
                            argument_model='claude-haiku-5-5', expectation=expectation), name
        after = host.observation['state']['tasks']
        if name == 'unicode':
            assert len(after) == len(before) + 1
        elif name == 'generated-notes':
            assert len(after) == len(before) + 1
            notes = next(t['notes'] for t in after if t['title'] == 'Prepare harness demo')
            assert len(notes.splitlines()) >= 5
            assert all(t in after for t in before), 'Creation changed another task'
        else:
            original = next(t for t in before if t['title'] == 'Book a table for Zoë 🍜')
            edited = next(t for t in after if t['id'] == original['id'])
            assert edited['project'] == original['project'] and edited['dueDate'] == original['dueDate']
            assert len(after) == len(before)
            assert all(t in after for t in before if t['id'] != original['id']), 'Edit changed another task'
        cli.emit('text_example_verified', name=name, taskCount=len(after))
    cli.emit('all_text_examples_verified', count=3)
finally:
    host.close()
