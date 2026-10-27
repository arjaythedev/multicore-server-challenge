"""Run the unchanged full-seed contract and Go comparison using one clone at a time."""
import json
import os
from pathlib import Path

from support import Server, upstream

work = Path(os.environ['CHALLENGE_WORK'])
submission = Path(__file__).resolve().parents[1]
results = work / 'results/full-seed'
results.mkdir(parents=True, exist_ok=True)
transcripts = {}
summaries = {}
for label, executable in [('zig', submission / 'zig-out/bin/conduit'), ('go', work / 'tools/reference-go')]:
    with Server(results, 'full-seed-test-only', 'full', label, executable, template='conduit_seed') as server:
        run, transcript, _, summary = upstream(server, label, work / 'tools/conformance')
        assert run.returncode == 0 and len(transcript) == 197, run.stdout
        transcripts[label] = transcript
        summaries[label] = summary
        print(label + ': ' + summary, flush=True)
assert transcripts['zig'] == transcripts['go']
(results / 'results.json').write_text(json.dumps({
    'upstream_steps_passed': 197, 'normalized_responses_equal_to_reference': 197,
    'summaries': summaries, 'seed': 'unchanged full seed: 500000 articles',
    'scope': 'native Mac correctness; not Linux runtime or official capacity'}, indent=2) + '\n')
print('PASS: all 197 full-seed normalized responses match the unchanged Go reference', flush=True)
