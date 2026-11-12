#!/usr/bin/env python3
"""Compare controlled ABBA replays only after workload/observer checks pass."""
import argparse
import json
import math
from pathlib import Path

LABELS = ['control-1','fixed-1','fixed-2','control-2']


def metrics(frames, key):
    values = sorted(f[key] for f in frames)
    if not values:
        raise ValueError('No measured frames')
    return {'frames':len(values), 'p95Ms':values[math.ceil(.95*len(values))-1]/1000,
            'p99Ms':values[math.ceil(.99*len(values))-1]/1000, 'maxMs':values[-1]/1000,
            'over8333Us':sum(v>8333 for v in values), 'over16667Us':sum(v>16667 for v in values)}


def compare(root):
    runs = {label:json.loads((root/label/'replay.json').read_text()) for label in LABELS}
    systems = {label:json.loads((root/label/'system-summary.json').read_text()) for label in LABELS}
    issues = []
    for label,r in runs.items():
        if r['label'] != label:
            issues.append(label+': replay label mismatch')
        if not r['comparisonEligible'] or not r['valid'] or not r['expectedDraftVerified']:
            issues.append(label+': workload or timing validation failed')
        if not json.loads((root/label/'vm-profiler-restored.json').read_text())['restored']:
            issues.append(label+': profiler restoration missing')
        if any(x['total'] for x in systems[label]['trace_data_loss']):
            issues.append(label+': trace reports data loss')
        if (systems[label]['start_monotonic_us'] != r['startUs']
                or systems[label]['end_monotonic_us'] != r['endUs']):
            issues.append(label+': system trace bounds do not match replay')
    starts = [runs[label]['startEpochUs'] for label in LABELS]
    if (any(type(start) is not int or start <= 0 for start in starts)
            or any(before >= after for before,after in zip(starts, starts[1:]))):
        issues.append('Replay capture order is not ABBA')
    for key in ['sourceSha256','initialSourceSha256','draftSha256','deltaCount','deltaIntervalUs',
                'keyboardStartPx','keyboardEndPx','displayRefreshHz','nativeDraftStorage',
                'physicalWidthPx','physicalHeightPx','devicePixelRatio','textScaleAt14',
                'dartCpuSampling']:
        if len({r[key] for r in runs.values()}) != 1:
            issues.append('Different '+key+' across runs')
    for key in ['keys','periodUs','inputMode']:
        if len({r['nativeInput'][key] for r in runs.values()}) != 1:
            issues.append('Different native '+key+' across runs')
    if len({s['native_preflight']['supported'] for s in systems.values()}) != 1:
        issues.append('Different native sampling mode across runs')
    rows = {}
    for label,r in runs.items():
        streaming = [f for f in r['frames'] if r['startUs']<=f['startUs']<r['streamEndUs']]
        tail = [f for f in r['frames'] if r['streamEndUs']<=f['startUs']<r['endUs']]
        rows[label] = {'ui':metrics(streaming,'buildUs'), 'raster':metrics(streaming,'rasterUs'),
                       'completionUi':metrics(tail,'buildUs') if tail else None,
                       'maxDeltaLatenessUs':r['maxDeltaLatenessUs'],
                       'nativeMaxCompletionLatenessUs':r['nativeInput']['maxCompletionLatenessUs']}
    return {'eligible':not issues, 'issues':issues, 'runs':rows,
            'limits':'Two replays per arm, ordered ABBA. UI and raster wall times are not actual presentation gaps. Memory preferences exclude native draft-storage cost. Emulator runs validate tools and cannot establish phone performance.'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('root',type=Path)
    a = p.parse_args()
    result = compare(a.root)
    (a.root/'controlled-comparison.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
    return 0 if result['eligible'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
