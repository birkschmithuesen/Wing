"""Synthetic local trace trees; no Flutter, ADB, or private trace data."""
import json
import sqlite3
import unittest

from render_object_attribution import attribute_render_object_paints


class AttributionChecks(unittest.TestCase):
    def setUp(self):
        self.trace = sqlite3.connect(':memory:')
        self.addCleanup(self.trace.close)
        self.trace.executescript('''
          CREATE TABLE process(upid INTEGER,pid INTEGER);
          CREATE TABLE thread(utid INTEGER,upid INTEGER,tid INTEGER,name TEXT);
          CREATE TABLE thread_track(id INTEGER,utid INTEGER);
          CREATE TABLE slice(id INTEGER,parent_id INTEGER,ts INTEGER,dur INTEGER,track_id INTEGER,name TEXT);
          CREATE TABLE thread_state(utid INTEGER,ts INTEGER,dur INTEGER,state TEXT);
          INSERT INTO process VALUES(1,123),(2,456);
          INSERT INTO thread VALUES(1,1,123,'merged-main'),(2,2,456,'foreign.ui');
          INSERT INTO thread_track VALUES(1,1),(2,2);
        ''')

    def add(self, identifier, parent, start, duration, name, track=1):
        self.trace.execute('INSERT INTO slice VALUES(?,?,?,?,?,?)',
                           (identifier,parent,start,duration,track,name))

    def report(self):
        return attribute_render_object_paints(self.trace, 'unused', 123, 100, 1000)

    def states(self, intervals):
        self.trace.executemany('INSERT INTO thread_state VALUES(1,?,?,?)', intervals)

    def test_direct_children_define_exclusive_wall_and_same_type_is_not_double_counted(self):
        self.add(1,None,100,800,'PAINT')
        self.add(2,1,110,700,'RenderFlex')
        self.add(3,2,120,400,'RenderFlex')
        self.add(4,3,130,300,'RenderEditable')
        self.add(5,2,600,100,'private URL and text')
        result = self.report()
        groups = {group['name']:group for group in result['paints'][0]['groups']}
        flex = groups['RenderFlex']
        self.assertEqual(flex['count'], 2)
        self.assertEqual(flex['inclusive_wall_ns'], 700)
        self.assertEqual(flex['exclusive_wall_ns'], 300)
        self.assertEqual(flex['max_inclusive_wall_ns'], 700)
        self.assertEqual(flex['max_exclusive_wall_ns'], 200)
        self.assertEqual(groups['RenderEditable']['exclusive_wall_ns'], 300)
        self.assertNotIn('private', json.dumps(result))

    def test_bad_tree_reports_overlap_and_negative_exclusive_without_attribution(self):
        self.add(1,None,100,800,'PAINT')
        self.add(2,1,110,600,'RenderParagraph')
        self.add(3,2,120,400,'RenderEditable')
        self.add(4,2,300,400,'RenderEditable')
        result = self.report()
        self.assertFalse(result['paints'][0]['valid'])
        self.assertEqual(result['paints'][0]['groups'], [])
        self.assertEqual(result['counts']['overlapping_child_sets'], 1)
        self.assertEqual(result['counts']['negative_exclusive_slices'], 1)

    def test_incomplete_and_out_of_parent_slices_are_reported_not_repaired(self):
        self.add(1,None,100,800,'PAINT')
        self.add(2,1,120,200,'RenderParagraph')
        self.add(3,2,130,-1,'RenderEditable')
        self.add(4,2,300,100,'RenderFlex')
        result = self.report()
        self.assertEqual(result['counts']['incomplete_slices'], 1)
        self.assertEqual(result['counts']['out_of_parent_slices'], 1)
        self.assertFalse(result['paints'][0]['valid'])
        self.assertEqual(result['paints'][0]['groups'], [])

    def test_only_contained_paints_and_target_pid_are_attributed(self):
        self.add(1,None,50,100,'PAINT')
        self.add(2,1,60,20,'RenderParagraph')
        self.add(3,None,900,200,'PAINT')
        self.add(4,3,910,50,'RenderParagraph')
        self.add(5,None,200,100,'PAINT', track=2)
        self.add(6,5,210,50,'RenderEditable', track=2)
        result = self.report()
        self.assertEqual(result['paints'], [])
        self.assertEqual(result['counts']['excluded_paints'], 2)

    def test_nested_paint_members_are_assigned_once(self):
        self.add(1,None,100,800,'PAINT')
        self.add(2,1,110,700,'RenderFlex')
        self.add(3,2,120,300,'PAINT')
        self.add(4,3,130,200,'RenderEditable')
        result = self.report()
        groups = [group for paint in result['paints'] for group in paint['groups']]
        self.assertEqual(sum(group['count'] for group in groups), 2)
        self.assertEqual(next(group for group in groups if group['name']=='RenderFlex')['exclusive_wall_ns'], 400)

    def test_zero_duration_complete_slice_is_counted_without_invented_cost(self):
        self.add(1,None,100,800,'PAINT')
        self.add(2,1,100,0,'RenderParagraph')
        result = self.report()
        self.assertTrue(result['paints'][0]['valid'])
        group = result['paints'][0]['groups'][0]
        self.assertEqual(group['count'], 1)
        self.assertEqual(group['inclusive_wall_ns'], 0)
        self.assertEqual(group['exclusive_wall_ns'], 0)
        self.assertEqual(result['counts']['incomplete_slices'], 0)

    def test_numeric_scope_rejects_injected_or_reversed_bounds(self):
        for arguments in [('123; PRIVATE',100,1000),(123,1000,100),(True,100,1000)]:
            with self.subTest(arguments=arguments), self.assertRaises(ValueError):
                attribute_render_object_paints(self.trace, 'unused', *arguments)

    def test_scheduler_states_intersect_exclusive_gaps_at_exact_boundaries(self):
        self.add(1,None,100,800,'PAINT')
        self.add(2,1,110,700,'RenderFlex')
        self.add(3,2,130,300,'RenderEditable')
        self.states([(100,100,'Running'), (200,300,'R'),
                     (500,200,'D'), (700,200,'S')])
        groups = {group['name']:group for group in self.report()['paints'][0]['groups']}
        flex = groups['RenderFlex']
        self.assertEqual(flex['exclusive_wall_ns'], 400)
        self.assertEqual([flex['exclusive_'+state+'_ns'] for state in
                          ('running','runnable','blocked','sleeping')], [20,70,200,110])
        self.assertEqual(flex['exclusive_unobserved_ns'], 0)
        self.assertEqual(groups['RenderEditable']['exclusive_running_ns'], 70)
        self.assertEqual(groups['RenderEditable']['exclusive_runnable_ns'], 230)

    def test_missing_scheduler_coverage_remains_unobserved_not_sleeping(self):
        self.add(1,None,100,800,'PAINT')
        self.add(2,1,110,400,'RenderParagraph')
        self.states([(100,100,'Running'), (300,100,'S'), (450,-1,'S')])
        result = self.report()
        group = result['paints'][0]['groups'][0]
        self.assertEqual(group['exclusive_observed_ns'], 190)
        self.assertEqual(group['exclusive_unobserved_ns'], 210)
        self.assertEqual(group['exclusive_sleeping_ns'], 100)
        self.assertEqual(group['exclusive_unobserved_gap_count'], 1)
        self.assertEqual(result['counts']['incomplete_thread_state_intervals'], 1)

    def test_nested_same_type_does_not_double_count_scheduler_running_time(self):
        self.add(1,None,100,800,'PAINT')
        self.add(2,1,110,700,'RenderFlex')
        self.add(3,2,120,400,'RenderFlex')
        self.add(4,3,130,300,'RenderEditable')
        self.add(5,2,600,100,'OtherWork')
        self.states([(100,800,'Running')])
        groups = {group['name']:group for group in self.report()['paints'][0]['groups']}
        self.assertEqual(groups['RenderFlex']['exclusive_running_ns'], 300)
        self.assertEqual(groups['RenderEditable']['exclusive_running_ns'], 300)
        self.assertEqual(groups['RenderFlex']['exclusive_unobserved_gap_count'], 0)

    def test_overlapping_scheduler_intervals_invalidate_cpu_not_wall_attribution(self):
        self.add(1,None,100,800,'PAINT')
        self.add(2,1,110,400,'RenderParagraph')
        self.states([(100,300,'Running'), (300,300,'S')])
        result = self.report()
        group = result['paints'][0]['groups'][0]
        self.assertTrue(result['paints'][0]['valid'])
        self.assertEqual(group['exclusive_wall_ns'], 400)
        self.assertEqual(group['exclusive_running_ns'], 0)
        self.assertEqual(group['exclusive_unobserved_ns'], 400)
        self.assertEqual(result['counts']['overlapping_thread_state_threads'], 1)


if __name__ == '__main__':
    unittest.main()
