#!/usr/bin/env python3
"""Run the recorded complex workflow through Jev, the argument LLM and the live TCA runtime."""
import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('harness_cli', root / 'cli/tca.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

goal = (
    'Use the workflow demo. Create a release plan titled "Harness SDK launch". '
    'Use exactly three tasks: "Package the SDK" assigned to Maya with high priority, '
    '"Write integration guide" assigned to Sam with normal priority, and '
    '"Validate isowords" assigned to Alex with high priority. '
    'Write a useful original implementation note for each task and a concise plan summary. '
    'Complete every task and publish the plan locally.'
)

host = cli.Host(port=8766)
try:
    cli.emit('goal', text=goal)
    succeeded = cli.run_goal(host, goal, 'jev-1.14.0', 'planPublished', max_steps=12,
                             step_delay=1.5, argument_model='claude-haiku-5-5')
    assert succeeded, 'Goal was not verified'
    plan = host.observation['state']['plan']
    assert plan['title'] == 'Harness SDK launch'
    expected = {'Package the SDK': ('Maya', 'high'),
                'Write integration guide': ('Sam', 'normal'),
                'Validate isowords': ('Alex', 'high')}
    assert len(plan['items']) == 3
    for item in plan['items']:
        assert (item['owner'], item['priority']) == expected[item['title']]
        assert item['isComplete'] is True and len(item['notes']) >= 30
    assert plan['phase'] == 'published'
    cli.emit('scenario_verified', checks=['exact title', 'three distinct tasks', 'owners', 'priorities',
                                         'generated notes', 'all children complete', 'async publish finished'])
finally:
    host.close()
