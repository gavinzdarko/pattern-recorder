#!/usr/bin/env python3
"""Offline only; prints aggregate metrics, never event text or app/title values."""
import json
import statistics
import sys
from pathlib import Path

def summary(paths):
    holds, downs, flights = [], [], []
    pressed = {}
    previous = None
    previous_press = None
    count = corrections = repeats = 0
    boundaries = {}
    durations = {}
    known_drops = 0
    first = last = None
    current_session = None
    for p in paths:
        if p.suffix == '.json':
            manifest = json.loads(p.read_text())
            known_drops += manifest.get('droppedKnown', 0)
            for reason, value in manifest.get('durationsSeconds', {}).items():
                durations[reason] = durations.get(reason, 0) + value
            continue
        session = p.name.rsplit('-', 1)[0]
        if session != current_session:
            pressed.clear(); previous = previous_press = None
            current_session = session
        for line in p.read_text().splitlines():
            r = json.loads(line)
            if r.get('schema') != 1:
                raise ValueError('Unsupported schema')
            t = r.get('sourceTimestampNS', r['stamp']['mono'])
            kind = r['kind']
            if kind in ('boundary', 'app-change'):
                pressed.clear(); previous = previous_press = None
                if kind == 'boundary':
                    reason = r.get('reason', 'unknown')
                    boundaries[reason] = boundaries.get(reason, 0) + 1
                continue
            if first is None:
                first = r['stamp']['continuous']
            last = r['stamp']['continuous']
            if kind == 'key-down':
                repeats += bool(r.get('repeated'))
                if r.get('repeated'):
                    continue
                count += 1
                corrections += r.get('reason') == 'correction-key'
                if previous is not None and t >= previous:
                    downs.append((t-previous)/1e6)
                previous = t
                if r.get('keyCode') is not None:
                    current = {'down': t, 'up': None, 'next': None}
                    if previous_press is not None:
                        previous_press['next'] = t
                        if previous_press['up'] is not None:
                            flights.append((t - previous_press['up'])/1e6)
                    pressed[r['keyCode']] = current
                    previous_press = current
            if kind == 'key-up':
                if 'holdNS' in r:
                    holds.append(r['holdNS']/1e6)
                press = pressed.pop(r.get('keyCode'), None)
                if press is not None:
                    press['up'] = t
                    if press['next'] is not None:
                        flights.append((press['next'] - t)/1e6)
    def stats(v):
        return {'n': len(v), 'median_ms': round(statistics.median(v), 3) if v else None}
    active = durations.get('active', 0)
    total = sum(durations.values())
    return {'schema': 1, 'hold': stats(holds), 'down_to_down': stats(downs), 'signed_flight': stats(flights), 'nonrepeat_key_downs': count, 'repeat_events': repeats, 'correction_key_rate': corrections/count if count else None, 'boundary_counts': boundaries, 'durations_seconds': durations, 'supported_active_fraction': active/total if total else None, 'known_dropped_events': known_drops, 'loss_count_is_lower_bound': True, 'note': 'Redacted exports omit physical keys: signed flight unavailable. Correction keys do not equal semantic edits. Duration coverage requires original session manifests.'}

if __name__ == '__main__':
    paths = []
    for arg in sys.argv[1:]:
        p = Path(arg)
        paths.extend(sorted(p.glob('*.json*')) if p.is_dir() else [p])
    if not paths:
        raise SystemExit('Usage: python3 scripts/summary.py <export-directory|JSONL> ...')
    print(json.dumps(summary(paths), indent=2, sort_keys=True))
