"""Host-only scope, clock, privacy and cleanup checks; no phone or backend calls."""
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import trace_render_system as system


class SystemTraceTests(unittest.TestCase):
    def test_prepare_is_bounded_and_has_no_content_sources(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(system, "BUILD_ROOT", Path(directory)):
            output = Path(directory) / "private"
            with patch.object(system, "adb_call") as adb:
                config = system.prepare_config(output, 30)
                adb.assert_not_called()
            self.assertIn('duration_ms: 30000', config)
            self.assertIn('duration_ms: 30000\nflush_period_ms: 1000\nwrite_into_file: true', config)
            self.assertNotIn('flush_period_ms', config[config.index('ftrace_config {'):])
            self.assertIn('atrace_apps: "com.tarkilhk.wing.perfqa"', config)
            for private in ('android.log', 'atrace_categories: "input"', 'atrace_categories: "wm"', 'linux.perf'):
                self.assertNotIn(private, config)
            self.assertEqual((output / 'system-config.pbtxt').stat().st_mode & 0o777, 0o600)
            for bad in (0, 61, True):
                with self.assertRaises(ValueError):
                    system.prepare_config(output, bad)

    def test_raw_output_cannot_escape_ignored_build_directory(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(system, "BUILD_ROOT", Path(directory) / 'build'):
            with self.assertRaises(ValueError):
                system.private_output(Path(directory) / 'export')

    def test_native_config_is_pid_scoped(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(system, "BUILD_ROOT", Path(directory)):
            config = system.prepare_config(Path(directory) / 'pilot', 5, 123)
            self.assertIn('target_pid: 123', config)
            self.assertIn('frequency: 100', config)
            self.assertIn('ring_buffer_pages: 256', config)
            self.assertIn('counter: SW_CPU_CLOCK', config)
            self.assertIn('timestamp_clock: PERF_CLOCK_MONOTONIC', config)
            with self.assertRaises(ValueError):
                system.prepare_config(Path(directory) / 'pilot', 5, '123;PRIVATE')

    def test_own_session_cleanup_never_uses_global_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            session = system.Session(SimpleNamespace(adb=['adb', '-s', 'PRIVATE']), Path(directory))
            (Path(directory) / 'system-private.pftrace').write_bytes(b'local')
            with patch.object(system, 'adb_call', return_value=SimpleNamespace(returncode=0)) as adb:
                session.start('bounded config')
                session.finish()
            calls = [call.args[1:] for call in adb.call_args_list]
            self.assertIn(('shell', 'perfetto', '--attach=' + session.key, '--stop'), calls)
            self.assertIn(('shell', 'rm', '-f', session.remote), calls)
            self.assertFalse(any('killall' in call or 'pkill' in call for call in calls))

    def test_transport_errors_never_echo_private_output(self):
        with patch.object(system.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout='PRIVATE', stderr='PRIVATE')):
            with self.assertRaises(RuntimeError) as error:
                system.adb_call(SimpleNamespace(adb=['adb', '-s', 'PRIVATE']), 'shell', 'perfetto')
            self.assertNotIn('PRIVATE', str(error.exception))

    def test_native_pilot_failure_is_optional(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(system, 'BUILD_ROOT', Path(directory)):
            with patch.object(system.Session, 'start', side_effect=RuntimeError('PRIVATE')):
                result = system.native_preflight(Mock(), Path(directory)/'capture', Mock(), 123)
            self.assertFalse(result['supported'])
            self.assertNotIn('PRIVATE', json.dumps(result))

    def test_clock_and_process_filters_fail_closed(self):
        with patch.object(system, 'query', return_value=[{'lo': '0', 'hi': '100001', 'n': '2'}]):
            with self.assertRaises(ValueError):
                system.analyze_loaded('processor', 'trace', 123, 10, 20)
        sql = system.thread_states_sql(123, 10000, 20000)
        self.assertIn('p.pid=123', sql)
        self.assertIn("s.state='Running'", sql)
        self.assertNotIn('SELECT t.name', sql)
        with self.assertRaises(ValueError):
            system.numeric_rows([{'secret': 'PRIVATE'}])

    def test_missing_paint_is_reported_without_paint_cost_claim(self):
        def query(_, __, sql):
            if 'clock_snapshot' in sql:
                return [{'lo': '0', 'hi': '10', 'n': '2'}]
            if 'trace_bounds' in sql:
                return [{'lo': '0', 'hi': '1000000'}]
            if 'thread_state s' in sql:
                return [{'tid': '124', 'role': '1', 'observed_ns': '10000', 'running_ns': '5000',
                         'runnable_ns': '1000', 'blocked_ns': '1000', 'sleeping_ns': '3000'}]
            if 'SELECT s.ts AS ts' in sql:
                return []
            if 'SELECT COUNT(*) AS n FROM slice' in sql:
                return [{'n': '0'}]
            if 'actual_frame_timeline_slice' in sql:
                return [{'frames': '1', 'max_ns': '10000'}]
            if 'perf_sample' in sql:
                return [{'samples': '0', 'stacks': '0'}]
            if 'FROM stats' in sql:
                return [{'counters': '0', 'total': '0'}]
            raise AssertionError(sql)
        with patch.object(system, 'query', side_effect=query):
            report = system.analyze_loaded('processor', 'trace', 123, 10, 20)
        self.assertFalse(report['paint_slices_present'])
        self.assertEqual(report['slow_paint_windows'], [])
        self.assertEqual(report['threads'][0]['running_ns'], 5000)

    def test_failed_scenario_finalizes_only_own_session(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(system, 'BUILD_ROOT', Path(directory)):
            clocks = iter([100, 200])
            def rpc(_, method, **params):
                if method == 'getIsolate':
                    return {'extensionRPCs': [system.REPLAY_EXTENSION]}
                return {'timestamp': next(clocks)}
            client = SimpleNamespace(isolate='PRIVATE', adb=['adb', '-s', 'PRIVATE'])
            with patch.object(system, 'focused'), patch.object(system, 'rpc', side_effect=rpc), \
                    patch.object(system, 'adb_call', return_value=SimpleNamespace(stdout='123')), \
                    patch.object(system.Session, 'start') as started, \
                    patch.object(system.Session, 'finish') as finished:
                with self.assertRaises(RuntimeError):
                    system.capture_system(client, Path(directory)/'capture', 30,
                                          Mock(side_effect=RuntimeError('PRIVATE')), 'processor')
            started.assert_called_once()
            finished.assert_called_once()
            self.assertFalse((Path(directory)/'capture/system-summary.json').exists())

    def test_native_leaf_inclusive_counts_scope_symbols_and_addresses(self):
        db = sqlite3.connect(':memory:')
        db.executescript('''
          CREATE TABLE process(upid INTEGER,pid INTEGER);
          CREATE TABLE thread(utid INTEGER,upid INTEGER,tid INTEGER,name TEXT);
          CREATE TABLE perf_sample(id INTEGER,utid INTEGER,ts INTEGER,callsite_id INTEGER);
          CREATE TABLE stack_profile_callsite(id INTEGER,parent_id INTEGER,frame_id INTEGER);
          CREATE TABLE stack_profile_frame(id INTEGER,mapping INTEGER,rel_pc INTEGER,symbol_set_id INTEGER,name TEXT);
          CREATE TABLE stack_profile_mapping(id INTEGER,name TEXT,build_id TEXT,start_offset INTEGER DEFAULT 0,exact_offset INTEGER DEFAULT 0,load_bias INTEGER DEFAULT 0);
          CREATE TABLE stack_profile_symbol(id INTEGER,symbol_set_id INTEGER,name TEXT,inlined INTEGER);
          INSERT INTO process VALUES(1,123),(2,999);
          INSERT INTO thread VALUES(1,1,124,'1.ui'),(2,2,999,'other.ui'),(3,1,125,'1.raster');
          INSERT INTO stack_profile_mapping(id,name,build_id) VALUES(1,'/PRIVATE/libflutter.so','ab12'),(2,'/PRIVATE/libc.so','cd34');
          INSERT INTO stack_profile_frame VALUES(1,1,4096,1,''),(2,2,8192,NULL,''),(3,1,9000,NULL,'/PRIVATE/path');
          INSERT INTO stack_profile_symbol VALUES(1,1,'flutter::Paint',0);
          INSERT INTO stack_profile_callsite VALUES(1,NULL,1),(2,1,2),(3,1,3);
          INSERT INTO perf_sample VALUES(1,1,110,2),(2,1,120,3),(3,2,130,2),(4,1,500,2),(5,3,140,2);
        ''')
        def query(_, __, sql):
            cursor = db.execute(sql)
            names = [column[0] for column in cursor.description]
            return [{name: str(value) if value is not None else '[NULL]' for name,value in zip(names,row)}
                    for row in cursor.fetchall()]
        with patch.object(system, 'query', side_effect=query):
            profile = system.native_window_profile('processor', 'trace', 123, 100, 200, tid=124)
            raster = system.native_window_profile('processor', 'trace', 123, 100, 200, role=2)
        self.assertEqual(profile['samples'], 2)
        self.assertTrue(profile['native_symbols_resolved'])
        parent = next(frame for frame in profile['frames'] if frame['rel_pc']==4096)
        self.assertEqual((parent['leaf_samples'],parent['inclusive_samples']), (0,2))
        self.assertEqual(parent['symbol'], 'flutter::Paint')
        unresolved = next(frame for frame in profile['frames'] if frame['rel_pc']==9000)
        self.assertEqual(unresolved['symbol'], '')
        self.assertEqual(unresolved['build_id'], 'ab12')
        self.assertNotIn('PRIVATE', json.dumps(profile))
        self.assertEqual(raster['samples'], 1)
        self.assertFalse(profile['sample_counts_are_cpu_time'])

    def test_unsymbolized_native_frames_still_retain_relative_addresses(self):
        responses = [[{'samples':'1','stacks':'1'}],
                     [{'library':'/PRIVATE/libapp.so','build_id':'ab12','rel_pc':'4096',
                       'mapping_start_offset':'0','mapping_exact_offset':'0','mapping_load_bias':'0',
                       'symbol':'','inclusive_samples':'1','leaf_samples':'1'}]]
        with patch.object(system, 'query', side_effect=responses):
            profile = system.native_window_profile('processor','trace',123,100,200,role=1)
        self.assertFalse(profile['native_symbols_resolved'])
        self.assertEqual(profile['address_frame_count'], 1)
        self.assertEqual(profile['frames'][0]['rel_pc'], 4096)

    def test_apk_backed_addresses_are_preserved_without_exporting_apk_path(self):
        responses=[[{'samples':'1','stacks':'1'}],
                   [{'library':'/PRIVATE/base.apk','build_id':'ab12','rel_pc':'4096','symbol':'',
                     'mapping_start_offset':'1024','mapping_exact_offset':'2048','mapping_load_bias':'0',
                     'inclusive_samples':'1','leaf_samples':'1'}]]
        with patch.object(system,'query',side_effect=responses):
            profile=system.native_window_profile('processor','trace',123,100,200,role=1)
        self.assertEqual(profile['frames'][0]['library'],'app_apk')
        self.assertEqual(profile['frames'][0]['mapping_kind'],'app_apk')
        self.assertEqual(profile['frames'][0]['mapping_start_offset'],1024)
        self.assertFalse(profile['native_symbols_resolved'])
        self.assertNotIn('PRIVATE',json.dumps(profile))

    def test_fence_probe_does_not_add_unavailable_events(self):
        with patch.object(system, 'adb_call', return_value=SimpleNamespace(returncode=1,stdout='PRIVATE')):
            self.assertEqual(system.available_fence_events(Mock()), [])
        with patch.object(system, 'adb_call', return_value=SimpleNamespace(returncode=0,stdout=
                          'dma_fence:dma_fence_wait_start\ndma_fence:dma_fence_wait_end\nPRIVATE')):
            self.assertEqual(system.available_fence_events(Mock()),
                             ['dma_fence/dma_fence_wait_start','dma_fence/dma_fence_wait_end'])

    def test_partial_tail_frames_are_filtered_without_discarding_replay(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(system, 'BUILD_ROOT', Path(directory)):
            clocks = iter([100,200,100000])
            def rpc(_,method,**params):
                if method=='getIsolate':
                    return {'extensionRPCs':[system.REPLAY_EXTENSION]}
                return {'timestamp':next(clocks)}
            replay = {'startMonotonicUs':300,'endMonotonicUs':50000,
                      'frameBuildStartUs':[1000,48000],'buildUs':[11000,11000],
                      'frameRasterStartUs':[1500,49000],'rasterUs':[11000,11000]}
            with patch.object(system,'focused'), patch.object(system,'rpc',side_effect=rpc), \
                    patch.object(system,'adb_call',return_value=SimpleNamespace(returncode=0,stdout='123')), \
                    patch.object(system.Session,'start'),patch.object(system.Session,'finish'), \
                    patch.object(system,'analyze',return_value={}) as analyze:
                report=system.capture_system(SimpleNamespace(isolate='PRIVATE'),Path(directory)/'capture',
                                             30,lambda _:replay,'processor')
            self.assertEqual(analyze.call_args.args[-2],[(1000,11000)])
            self.assertEqual(analyze.call_args.args[-1],[(1500,11000)])
            self.assertEqual(report['build_windows_outside_replay_count'],1)
            self.assertEqual(report['raster_windows_outside_replay_count'],1)

    def test_longest_late_windows_are_selected_with_stable_ties_and_bounds(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(system, 'BUILD_ROOT', Path(directory)):
            clocks = iter([100,200,2000000])
            def rpc(_,method,**params):
                if method=='getIsolate':
                    return {'extensionRPCs':[system.REPLAY_EXTENSION]}
                return {'timestamp':next(clocks)}
            builds = [(1000+i*30000,11000) for i in range(23)] + [(691000,60000)]
            rasters = [(1500+i*30000,12000) for i in range(23)] + [(691500,70000)]
            replay = {'startMonotonicUs':300,'endMonotonicUs':1000000,
                      'frameBuildStartUs':[s for s,_ in builds]+[100,999000],
                      'buildUs':[d for _,d in builds]+[90000,90000],
                      'frameRasterStartUs':[s for s,_ in rasters]+[100,999000],
                      'rasterUs':[d for _,d in rasters]+[90000,90000]}
            with patch.object(system,'focused'), patch.object(system,'rpc',side_effect=rpc), \
                    patch.object(system,'adb_call',return_value=SimpleNamespace(returncode=0,stdout='123')), \
                    patch.object(system.Session,'start'),patch.object(system.Session,'finish'), \
                    patch.object(system,'analyze',return_value={}) as analyze:
                report=system.capture_system(SimpleNamespace(isolate='PRIVATE'),Path(directory)/'capture',
                                             30,lambda _:replay,'processor')
            self.assertEqual(analyze.call_args.args[-2], [builds[-1]]+builds[:19])
            self.assertEqual(analyze.call_args.args[-1], [rasters[-1]]+rasters[:19])
            self.assertEqual(report['slow_window_selection_policy'],1)
            self.assertEqual(report['build_windows_outside_replay_count'],2)
            self.assertEqual(report['raster_windows_outside_replay_count'],2)
            self.assertEqual(report['build_windows_over_limit_count'],4)
            self.assertEqual(report['raster_windows_over_limit_count'],4)

    def test_main_is_ui_only_with_observed_paint_track(self):
        db=sqlite3.connect(':memory:')
        db.executescript('''CREATE TABLE process(upid,pid);
          CREATE TABLE thread(utid,upid,tid,name);
          CREATE TABLE thread_state(utid,ts,dur,state);
          CREATE TABLE slice(track_id,name);
          CREATE TABLE thread_track(id,utid);
          INSERT INTO process VALUES(1,123);
          INSERT INTO thread VALUES(1,1,123,'main');
          INSERT INTO thread_state VALUES(1,100,100,'Running');
          INSERT INTO thread_track VALUES(10,1);
          INSERT INTO slice VALUES(10,'PAINT');''')
        sql=system.thread_states_sql(123,100,200)
        with_paint=db.execute(sql).fetchone()
        self.assertEqual(with_paint[1],1)
        db.execute('DELETE FROM slice')
        without_paint=db.execute(sql).fetchone()
        self.assertEqual(without_paint[1],4)
        db.close()

    def test_loaded_analysis_reuses_connection_and_removes_private_database(self):
        with tempfile.TemporaryDirectory() as directory:
            trace=Path(directory)/'private.pftrace';trace.write_bytes(b'local')
            database_paths=[]
            def run(command,**params):
                if command[1]=='query':
                    return SimpleNamespace(returncode=0,stdout='"start_ts","end_ts"\n0,1000\n\n"id","utid"\n10,1\n\n"ts","dur","upid"\n100,10,1\n')
                database=Path(command[command.index('-o')+1]);database_paths.append(database)
                db=sqlite3.connect(database)
                for table,columns in [('thread_state','utid,ts'),('thread','utid,upid'),
                                      ('process','upid,pid'),('slice','name,track_id,ts'),
                                      ('stack_profile_callsite','id'),('stack_profile_frame','id'),
                                      ('stack_profile_mapping','id'),('stack_profile_symbol','symbol_set_id'),
                                      ('__intrinsic_profiler_sample','ts,task_context_id'),
                                      ('__intrinsic_profiler_task_context','id,utid'),
                                      ('__intrinsic_profiler_execution_context','id'),('__intrinsic_cpu','id')]:
                    db.execute('CREATE TABLE '+table+' ('+columns+')')
                db.close()
                return SimpleNamespace(returncode=0,stdout='')
            with patch.object(system.subprocess,'run',side_effect=run) as process:
                with system.load_trace('processor',trace) as loaded:
                    for _ in range(5):
                        self.assertEqual(system.query(loaded,trace,'SELECT COUNT(*) AS n FROM thread_track'),[{'n':'1'}])
                    self.assertTrue(database_paths[0].exists())
                self.assertEqual(process.call_count,2)
            self.assertFalse(database_paths[0].exists())
            self.assertFalse(list(Path(directory).glob('.system-analysis-*')))


if __name__ == '__main__':
    unittest.main()
