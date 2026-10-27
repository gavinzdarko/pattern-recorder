#!/usr/bin/env python3
import json
import subprocess
r = json.loads(subprocess.check_output(['python3', 'scripts/summary.py', 'fixtures/synthetic.jsonl']))
assert r['hold'] == {'n': 2, 'median_ms': 110.0}, r
assert r['signed_flight'] == {'n': 2, 'median_ms': 90.0}, r
assert r['nonrepeat_key_downs'] == 3 and r['correction_key_rate'] == 1/3, r
assert r['known_dropped_events'] == 0 and r['loss_count_is_lower_bound'] is True
print('SUMMARY TEST PASS: matched overlap flight -50ms and +230ms; median90ms; holds/corrections verified')
