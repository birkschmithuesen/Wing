#!/usr/bin/env python3
"""Check actual fixture create/update schedule DTOs against pinned stock outputs."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ID = 'STOCK_TASK_SCHEDULE_PROJECTION'
ARTIFACT = Path(__file__).resolve().parents[2] / 'contracts/hermes_task_schedule_projection.json'


def load(path=ARTIFACT):
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or type(value.get('schema')) is not int or value['schema'] != 1:
        raise ValueError('Expected schedule artifact schema 1')
    provenance = value.get('source')
    if not isinstance(provenance, dict) or not all(isinstance(provenance.get(field), str) and provenance[field]
            for field in ('repository', 'commit', 'path', 'sha256', 'parser_sha256', 'generation', 'license')):
        raise ValueError('Missing stock source provenance')
    for field, size in [('commit', 40), ('sha256', 64), ('parser_sha256', 64)]:
        text = provenance[field]
        if len(text) != size or any(char not in '0123456789abcdef' for char in text):
            raise ValueError('Invalid source revision/hash')
    if provenance['repository'] != 'https://github.com/NousResearch/hermes-agent' or provenance['path'] != 'cron/jobs.py':
        raise ValueError('Unexpected stock parser provenance')
    cases = value.get('cases')
    if not isinstance(cases, list) or not cases or not isinstance(value.get('clock'), str):
        raise ValueError('Missing golden cases/clock')
    identities = set()
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get('id'), str) or not case['id'] or case['id'] in identities:
            raise ValueError('Invalid/duplicate case identity')
        identities.add(case['id'])
        schedule = case.get('schedule')
        if not isinstance(case.get('input'), str) or not isinstance(schedule, dict):
            raise ValueError('Missing input/schedule')
        kind = schedule.get('kind')
        field = {'once': 'run_at', 'cron': 'expr', 'interval': 'minutes'}.get(kind)
        if field is None or set(schedule) != {'kind', field, 'display'}:
            raise ValueError('Unsupported golden schedule shape')
        if not isinstance(schedule['display'], str) or case.get('schedule_display') != schedule['display']:
            raise ValueError('Missing/mismatched golden schedule display')
        if field == 'minutes':
            if type(schedule[field]) is not int or schedule[field] <= 0:
                raise ValueError('Invalid interval minutes')
        elif not isinstance(schedule[field], str) or not schedule[field]:
            raise ValueError('Invalid schedule value')
    canonical = json.dumps(cases, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
    if value.get('cases_sha256') != hashlib.sha256(canonical).hexdigest():
        raise ValueError('Golden projection checksum mismatch')
    return value


def check(value, artifact=None):
    golden = artifact or load()
    if not isinstance(value, dict) or not isinstance(value.get('observations'), list):
        raise ValueError('Expected actual fixture observations')
    expected = {case['id']: case for case in golden['cases']}
    seen = set()
    findings = []
    for row in value['observations']:
        if not isinstance(row, dict) or row.get('id') not in expected or row.get('operation') not in {'POST', 'PUT'}:
            raise ValueError('Unknown/missing observation identity or operation')
        identity = (row['id'], row['operation'])
        if identity in seen:
            raise ValueError('Duplicate observation')
        seen.add(identity)
        response = row.get('response')
        if not isinstance(response, dict) or not isinstance(response.get('schedule'), dict) or 'schedule_display' not in response:
            raise ValueError('Missing actual schedule response')
        case = expected[row['id']]
        if response['schedule'] != case['schedule'] or response['schedule_display'] != case['schedule_display']:
            findings.append(f'{ID}: {row["id"]}/{row["operation"]}: project the submitted schedule as its stock kind/value/display')
    if seen != {(identity, method) for identity in expected for method in ('POST', 'PUT')}:
        raise ValueError('Missing create/update coverage for golden schedule cases')
    return sorted(findings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--artifact', type=Path, default=ARTIFACT)
    args = parser.parse_args()
    try:
        findings = check(json.loads(args.input.read_text()), load(args.artifact))
        for finding in findings:
            print(finding)
        return int(bool(findings))
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f'{ID}: input error: {error}')
        return 2


if __name__ == '__main__':
    sys.exit(main())
