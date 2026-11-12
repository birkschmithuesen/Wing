"""Host-only attribution of diagnostic RenderObject paint timeline slices."""
from bisect import bisect_right
import re

from trace_render_system import integer, number, query, ui_thread_predicate

_RENDER_NAME = re.compile(r'Render[A-Za-z0-9_]+')
_STATES = ('running', 'runnable', 'blocked', 'sleeping', 'other_state')


def _state_integrals(loaded, trace, pid, start, end, counts):
    rows = query(loaded, trace, f'''SELECT s.utid,s.ts,s.dur,s.state
      FROM thread_state s JOIN thread t USING(utid) JOIN process p USING(upid)
      WHERE p.pid={pid} AND {ui_thread_predicate()}
      AND s.ts<{end} AND (s.dur<0 OR s.ts+s.dur>{start})''')
    threads = {}
    for row in rows:
        utid,ts,dur = (number(row[key]) for key in ('utid','ts','dur'))
        if dur < 0:
            counts['incomplete_thread_state_intervals'] += 1
            continue
        state = row['state']
        category = ('running' if state == 'Running' else 'runnable' if state in ('R','R+')
                    else 'blocked' if state.startswith('D') else 'sleeping' if state == 'S'
                    else 'other_state')
        threads.setdefault(utid, []).append((max(ts,start), min(ts+dur,end), category))
    integrals = {}
    for utid,intervals in threads.items():
        intervals.sort()
        if any(before[1] > after[0] for before,after in zip(intervals, intervals[1:])):
            counts['overlapping_thread_state_threads'] += 1
            continue
        for category in _STATES:
            selected = [(a,b) for a,b,state in intervals if state == category]
            starts,ends,prefix,total = [],[],[],0
            for a,b in selected:
                starts.append(a)
                ends.append(b)
                prefix.append(total)
                total += b-a
            integrals[utid,category] = (starts,ends,prefix)
    return integrals


def _integral_at(integral, point):
    if integral is None:
        return 0
    starts,ends,prefix = integral
    index = bisect_right(starts, point)-1
    return 0 if index < 0 else prefix[index] + min(point,ends[index])-starts[index]


def _union_ns(intervals):
    total = 0
    end = None
    for start, finish in sorted(intervals):
        total += max(0, finish - max(start, end if end is not None else start))
        end = max(finish, end if end is not None else finish)
    return total


def attribute_render_object_paints(loaded, trace, pid, start_ns, end_ns):
    """Analyze a connection from load_trace; bounds use Perfetto trace-clock ns.

    This never captures a device or reads timeline arguments. Incomplete or
    malformed PAINT trees are reported and excluded rather than repaired.
    """
    integer(pid, 1)
    integer(start_ns)
    integer(end_ns, start_ns + 1)
    rows = query(loaded, trace, f'''SELECT s.id,s.parent_id,s.ts,s.dur,s.track_id,tt.utid,s.name
      FROM slice s JOIN thread_track tt ON tt.id=s.track_id
      JOIN thread t USING(utid) JOIN process p USING(upid)
      WHERE p.pid={pid} AND {ui_thread_predicate()}
      AND s.ts<{end_ns} AND (s.dur<0 OR s.ts+s.dur>={start_ns})''')
    slices = {}
    for row in rows:
        item = {key:number(row[key]) for key in ('id','ts','dur','track_id','utid')}
        item['parent_id'] = None if row['parent_id'] == '[NULL]' else number(row['parent_id'])
        item['name'] = row['name']
        slices[item['id']] = item
    paints = {key:item for key,item in slices.items() if item['name'] == 'PAINT'}
    valid_paints = {
        key:item for key,item in paints.items()
        if item['dur'] > 0 and start_ns <= item['ts']
        and item['ts'] + item['dur'] <= end_ns
    }
    members = {key:[paint] for key,paint in valid_paints.items()}
    counts = {'excluded_paints':len(paints)-len(valid_paints),
              'invalid_parent_links':0, 'unattributed_render_slices':0,
              'incomplete_slices':0, 'out_of_parent_slices':0,
              'overlapping_child_sets':0, 'negative_exclusive_slices':0,
              'invalid_paint_trees':0, 'incomplete_thread_state_intervals':0,
              'overlapping_thread_state_threads':0}
    integrals = _state_integrals(loaded, trace, pid, start_ns, end_ns, counts)
    for item in slices.values():
        parent = item['parent_id']
        visited = {item['id']}
        while parent in slices and parent not in paints and parent not in visited:
            visited.add(parent)
            parent = slices[parent]['parent_id']
        if parent in visited:
            counts['invalid_parent_links'] += 1
        if parent in members:
            members[parent].append(item)
        elif _RENDER_NAME.fullmatch(item['name']):
            counts['unattributed_render_slices'] += 1
    windows = []
    for paint_id,items in members.items():
        paint = paints[paint_id]
        by_id = {item['id']:item for item in items}
        children = {key:[] for key in by_id}
        invalid = False
        for item in items:
            if item['dur'] < 0:
                counts['incomplete_slices'] += 1
                invalid = True
            if item['id'] == paint_id:
                continue
            parent = by_id.get(item['parent_id'])
            if (parent is None or item['ts'] < parent['ts']
                    or item['ts'] + item['dur'] > parent['ts'] + parent['dur']
                    or item['track_id'] != parent['track_id']):
                counts['out_of_parent_slices'] += 1
                invalid = True
            if parent is not None:
                children[parent['id']].append(item)
        exclusive = {}
        for item in items:
            direct = sorted(children[item['id']], key=lambda child:child['ts'])
            if any(before['ts'] + before['dur'] > after['ts']
                   for before,after in zip(direct, direct[1:])):
                counts['overlapping_child_sets'] += 1
                invalid = True
            duration = item['dur'] - sum(child['dur'] for child in direct)
            if duration < 0:
                counts['negative_exclusive_slices'] += 1
                invalid = True
            cursor = item['ts']
            gaps = []
            for child in direct:
                if cursor < child['ts']:
                    gaps.append((cursor, child['ts']))
                cursor = child['ts'] + child['dur']
            if cursor < item['ts'] + item['dur']:
                gaps.append((cursor, item['ts'] + item['dur']))
            exclusive[item['id']] = (duration, gaps)
        groups = {}
        if invalid:
            counts['invalid_paint_trees'] += 1
        else:
            for item in items:
                if not _RENDER_NAME.fullmatch(item['name']):
                    continue
                group = groups.setdefault(item['name'], {
                    'name':item['name'], 'count':0, 'max_inclusive_wall_ns':0,
                    'max_exclusive_wall_ns':0, '_inclusive':[], '_exclusive':[],
                    **{'exclusive_'+state+'_ns':0 for state in _STATES},
                    'exclusive_observed_ns':0, 'exclusive_unobserved_ns':0,
                    'exclusive_unobserved_gap_count':0,
                })
                group['count'] += 1
                group['max_inclusive_wall_ns'] = max(group['max_inclusive_wall_ns'], item['dur'])
                duration,gaps = exclusive[item['id']]
                group['max_exclusive_wall_ns'] = max(group['max_exclusive_wall_ns'], duration)
                group['_inclusive'].append((item['ts'], item['ts'] + item['dur']))
                group['_exclusive'].extend(gaps)
                for a,b in gaps:
                    observed = 0
                    for state in _STATES:
                        integral = integrals.get((item['utid'],state))
                        duration = _integral_at(integral,b)-_integral_at(integral,a)
                        group['exclusive_'+state+'_ns'] += duration
                        observed += duration
                    group['exclusive_observed_ns'] += observed
                    group['exclusive_unobserved_ns'] += b-a-observed
                    group['exclusive_unobserved_gap_count'] += observed < b-a
            for group in groups.values():
                group['inclusive_wall_ns'] = _union_ns(group.pop('_inclusive'))
                group['exclusive_wall_ns'] = _union_ns(group.pop('_exclusive'))
        windows.append({'paint_id':paint_id, 'start_trace_ns':paint['ts'],
                        'paint_wall_ns':paint['dur'], 'valid':not invalid,
                        'groups':sorted(groups.values(), key=lambda group:(-group['exclusive_wall_ns'], group['name']))})
    return {'target_pid':pid, 'start_trace_ns':start_ns, 'end_trace_ns':end_ns,
            'counts':counts, 'paints':sorted(windows, key=lambda paint:paint['start_trace_ns']),
            'limits':'Instrumented wall durations include descheduling. Inclusive durations use a union per type and overlap across types; do not add them. Exclusive gaps subtract all direct child slices. Scheduler running time intersects those gaps; runnable, blocked, sleeping and unobserved time are not CPU execution. Unknown coverage is never assumed asleep. Invalid paint trees are excluded; overlapping scheduler intervals leave CPU attribution unobserved. Native samples remain separate evidence.'}
