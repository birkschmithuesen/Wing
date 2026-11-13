#!/usr/bin/env python3
"""Prepare offline or capture a bounded QA-only system trace in a future phone window.

Raw scheduler/gfx traces include other processes even though exported analysis is
filtered to the QA PID. Keep raw traces in ignored local build/; do not export or
upload them. No logs, screenshots, input events or message contents are requested.
"""
import argparse
import csv
import io
import json
import re
import sqlite3
import subprocess
import tempfile
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from trace_streaming_cpu import focused, integer, require, rpc
from wing_perf_client import WingPerfClient

ROOT = Path(__file__).resolve().parents[2]
BUILD_ROOT = ROOT / "build"
CONFIG = ROOT / "tools/performance/render_system_trace.pbtxt"
PACKAGE = "com.tarkilhk.wing.perfqa"
REPLAY_EXTENSION = "ext.wingReplay.replay"
NATIVE_LIBRARIES = {
    "libflutter.so", "libapp.so", "libc.so", "libm.so", "libdl.so", "liblog.so",
    "libandroid.so", "libvulkan.so", "libEGL.so", "libGLESv1_CM.so", "libGLESv2.so",
    "libgui.so", "libui.so", "libutils.so", "libcutils.so", "libhwui.so", "libbinder.so",
    "libsync.so", "libnativewindow.so", "libart.so", "vulkan.adreno.so", "libGLESv2_adreno.so",
    "libEGL_adreno.so", "libgsl.so", "libllvm-glnext.so", "libllvm-qcom.so",
    "vulkan.mali.so", "libGLES_mali.so", "libGLESv2_mali.so",
}


def private_output(output):
    output = Path(output).resolve()
    require(output.is_relative_to(BUILD_ROOT.resolve()) and output != BUILD_ROOT.resolve())
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    output.chmod(0o700)
    return output


def prepare_config(output, seconds=30, native_pid=None):
    """Pure host preparation; never calls ADB or the VM service."""
    require(type(seconds) is int and 5 <= seconds <= 60)
    output = private_output(output)
    config = CONFIG.read_text().replace("duration_ms: 30000", f"duration_ms: {seconds * 1000}")
    if native_pid is not None:
        integer(native_pid, 1)
        config += f'''data_sources {{ config {{ name: "linux.perf"
  perf_event_config {{
    ring_buffer_pages: 256
    timebase {{ counter: SW_CPU_CLOCK frequency: 100 timestamp_clock: PERF_CLOCK_MONOTONIC }}
    callstack_sampling {{ scope {{ target_pid: {native_pid} }} }}
  }}
}} }}
'''
    path = output / "system-config.pbtxt"
    path.write_text(config)
    path.chmod(0o600)
    return config


def adb_call(client, *words, input_text=None, check=True, timeout=15):
    """Never expose ADB output, command lines, VM tokens or device identifiers."""
    try:
        result = subprocess.run(client.adb + list(words), input=input_text,
                                text=True, capture_output=True, timeout=timeout)
    except Exception:
        raise RuntimeError("System trace transport unavailable") from None
    if check and result.returncode:
        raise RuntimeError("System trace command rejected")
    return result


def query(processor, trace, sql):
    """Only caller-authored numeric SQL is exported; processor stderr stays private."""
    try:
        if isinstance(processor, sqlite3.Connection):
            cursor = processor.execute(sql)
            return [{column[0]: str(value) if value is not None else "[NULL]"
                     for column,value in zip(cursor.description,row)} for row in cursor.fetchall()]
        result = subprocess.run([str(processor), "query", str(trace), sql],
                                text=True, capture_output=True, timeout=60)
        require(result.returncode == 0)
        return list(csv.DictReader(io.StringIO(result.stdout)))
    except Exception:
        raise RuntimeError("Local trace analysis unavailable") from None


@contextmanager
def load_trace(processor, trace):
    """Two bounded setup parses, then one private indexed SQLite connection for all windows."""
    trace = Path(trace).resolve()
    connection = None
    with tempfile.TemporaryDirectory(dir=trace.parent, prefix=".system-analysis-") as directory:
        database = Path(directory) / "private.sqlite"
        sql = ("SELECT start_ts,end_ts FROM trace_bounds;"
               "SELECT id,utid FROM thread_track;"
               "SELECT ts,dur,upid FROM actual_frame_timeline_slice WHERE upid IS NOT NULL;")
        try:
            result = subprocess.run([str(processor), "query", str(trace), sql],
                                    text=True, capture_output=True, timeout=60)
            require(result.returncode == 0)
            exported = subprocess.run([str(processor), "export", "sqlite", "-o", str(database), str(trace)],
                                      text=True, capture_output=True, timeout=60)
            require(exported.returncode == 0 and database.is_file())
            database.chmod(0o600)
            blocks = re.split(r"\n\s*\n", result.stdout.strip())
            require(len(blocks) == 3)
            connection = sqlite3.connect(database)
            # These Perfetto views are not executable in the exported SQLite database.
            for table,columns,block in zip(("trace_bounds", "thread_track", "actual_frame_timeline_slice"),
                                           (("start_ts","end_ts"),("id","utid"),("ts","dur","upid")),blocks):
                rows = list(csv.DictReader(io.StringIO(block)))
                require(all(tuple(row) == columns for row in rows))
                existing = connection.execute("SELECT type FROM sqlite_master WHERE name=?",(table,)).fetchone()
                if existing:
                    require(existing[0] in ("table","view"))
                    connection.execute(f"DROP {existing[0]} {table}")
                connection.execute(f"CREATE TABLE {table} ({','.join(column+' INTEGER' for column in columns)})")
                connection.executemany(f"INSERT INTO {table} VALUES ({','.join('?' for _ in columns)})",
                                       [tuple(number(row[column]) for column in columns) for row in rows])
            for table,columns in (("thread_state","utid,ts"),
                                  ("thread","utid,upid"),("process","upid,pid"),
                                  ("slice","name,track_id,ts"),("thread_track","id,utid"),
                                  ("stack_profile_callsite","id"),("stack_profile_frame","id"),
                                  ("stack_profile_mapping","id"),("stack_profile_symbol","symbol_set_id")):
                kind = connection.execute("SELECT type FROM sqlite_master WHERE name=?",(table,)).fetchone()
                require(kind is not None)
                indexed = "__intrinsic_"+table if kind[0]=="view" else table
                indexed_columns = columns
                if kind[0]=="view" and table=="thread":
                    indexed_columns = columns.replace("utid","id")
                if kind[0]=="view" and table=="process":
                    indexed_columns = columns.replace("upid","id")
                connection.execute(f"CREATE INDEX wing_{table}_lookup ON {indexed} ({indexed_columns})")
            for table,columns in (("__intrinsic_profiler_sample","ts,task_context_id"),
                                  ("__intrinsic_profiler_task_context","id,utid"),
                                  ("__intrinsic_profiler_execution_context","id"),
                                  ("__intrinsic_cpu","id")):
                connection.execute(f"CREATE INDEX wing_{table}_lookup ON {table} ({columns})")
            connection.commit()
            deadline = time.monotonic()+120
            connection.set_progress_handler(lambda: int(time.monotonic()>deadline),10000)
            yield connection
        except Exception:
            raise RuntimeError("Local trace analysis unavailable") from None
        finally:
            if connection is not None:
                connection.close()


def number(value):
    require(isinstance(value, str) and re.fullmatch(r"-?[0-9]+", value) is not None)
    return int(value)


class Session:
    """Cleanup addresses only this invocation's generated detached-session key."""
    def __init__(self, client, output):
        self.client, self.output = client, output
        self.key = "wing-render-" + uuid.uuid4().hex
        self.remote = "/data/misc/perfetto-traces/" + self.key + ".pftrace"
        self.started = False

    def start(self, config):
        self.started = True  # A failed start can still have created a session.
        adb_call(self.client, "shell", "perfetto", "--txt", "-c", "-", "-o", self.remote,
                 "--detach=" + self.key, input_text=config)

    def finish(self):
        if not self.started:
            return None
        state = adb_call(self.client, "shell", "perfetto", "--is_detached=" + self.key, check=False)
        require(state.returncode in (0, 2))
        if state.returncode == 0:
            adb_call(self.client, "shell", "perfetto", "--attach=" + self.key, "--stop")
        trace = self.output / "system-private.pftrace"
        adb_call(self.client, "pull", self.remote, str(trace), timeout=30)
        require(trace.is_file() and trace.stat().st_size > 0)
        trace.chmod(0o600)
        adb_call(self.client, "shell", "rm", "-f", self.remote)
        self.started = False
        return trace


def perf_samples(processor, trace, pid):
    integer(pid, 1)
    rows = query(processor, trace, f"""SELECT COUNT(*) AS samples,
      COALESCE(SUM(callsite_id IS NOT NULL),0) AS stacks
      FROM perf_sample ps JOIN thread t USING(utid) JOIN process p USING(upid)
      WHERE p.pid={pid}""")
    require(len(rows) == 1)
    return {key: number(rows[0][key]) for key in ("samples", "stacks")}


def native_preflight(client, output, processor, pid):
    """An actual 1s PID-scoped pilot proves samples exist; advertisements do not."""
    session = Session(client, private_output(output / "native-pilot"))
    result = {"requested": True, "supported": False, "samples": 0, "stacks": 0}
    try:
        config = prepare_config(session.output, 5, pid).replace("duration_ms: 5000", "duration_ms: 1000")
        (session.output / "system-config.pbtxt").write_text(config)
        session.start(config)
        time.sleep(1.1)
        trace = session.finish()
        result.update(perf_samples(processor, trace, pid))
        result["supported"] = result["samples"] > 0 and result["stacks"] > 0
    except Exception:
        result["supported"] = False
    finally:
        if session.started:
            try:
                session.finish()
            except Exception:
                result["cleanup_confirmed"] = False
    return result


def available_fence_events(client):
    """Read-only optional kernel capability probe; unavailable events never enter config."""
    try:
        result = adb_call(client, "shell", "cat", "/sys/kernel/tracing/available_events", check=False)
        if result.returncode:
            return []
        available = set(result.stdout.splitlines())
        return ["dma_fence/" + event for event in ("dma_fence_wait_start", "dma_fence_wait_end")
                if "dma_fence:" + event in available]
    except Exception:
        return []


def ui_thread_predicate(alias="t"):
    return f"""({alias}.name GLOB '*.ui' OR EXISTS (
      SELECT 1 FROM slice ui_slice JOIN thread_track ui_track ON ui_track.id=ui_slice.track_id
      WHERE ui_track.utid={alias}.utid AND ui_slice.name='PAINT'))"""


def thread_states_sql(pid, start, end):
    return f"""SELECT t.tid AS tid,
      CASE WHEN {ui_thread_predicate()} THEN 1 WHEN t.name GLOB '*.raster' THEN 2
           WHEN t.name GLOB '*.io' THEN 3 WHEN t.tid=p.pid THEN 4 ELSE 0 END AS role,
      SUM(MIN(s.ts+s.dur,{end})-MAX(s.ts,{start})) AS observed_ns,
      SUM(CASE WHEN s.state='Running' THEN MIN(s.ts+s.dur,{end})-MAX(s.ts,{start}) ELSE 0 END) AS running_ns,
      SUM(CASE WHEN s.state IN ('R','R+') THEN MIN(s.ts+s.dur,{end})-MAX(s.ts,{start}) ELSE 0 END) AS runnable_ns,
      SUM(CASE WHEN s.state GLOB 'D*' THEN MIN(s.ts+s.dur,{end})-MAX(s.ts,{start}) ELSE 0 END) AS blocked_ns,
      SUM(CASE WHEN s.state='S' THEN MIN(s.ts+s.dur,{end})-MAX(s.ts,{start}) ELSE 0 END) AS sleeping_ns
      FROM thread_state s JOIN thread t USING(utid) JOIN process p USING(upid)
      WHERE p.pid={pid} AND s.dur>0 AND s.ts<{end} AND s.ts+s.dur>{start}
      GROUP BY t.utid ORDER BY t.tid"""


def numeric_rows(rows):
    return [{key: number(value) for key, value in row.items()} for row in rows]


def native_window_profile(processor, trace, pid, start_ns, end_ns, *, tid=None, role=None):
    """Static native frames only; leaf/inclusive counts are samples, never CPU time."""
    integer(pid, 1)
    integer(start_ns)
    integer(end_ns, start_ns + 1)
    scope = f"p.pid={pid} AND ps.ts>={start_ns} AND ps.ts<{end_ns}"
    if tid is not None:
        scope += f" AND t.tid={integer(tid, 1)}"
    if role is not None:
        require(role in (1, 2))
        scope += " AND " + ui_thread_predicate() if role == 1 else " AND t.name GLOB '*.raster'"
    counts = query(processor, trace, f"""SELECT COUNT(*) AS samples,
      COALESCE(SUM(ps.callsite_id IS NOT NULL),0) AS stacks FROM perf_sample ps
      JOIN thread t USING(utid) JOIN process p USING(upid) WHERE {scope}""")
    require(len(counts) == 1)
    result = {key: number(counts[0][key]) for key in ("samples", "stacks")}
    result.update(native_symbols_resolved=False, sample_counts_are_cpu_time=False,
                  native_symbols_fully_resolved=False, resolved_frame_count=0,
                  address_frame_count=0, excluded_library_frame_count=0, frames=[])
    if result["stacks"] == 0:
        return result
    rows = query(processor, trace, f"""WITH RECURSIVE roots AS (
        SELECT ps.id AS sample_id,ps.callsite_id FROM perf_sample ps
        JOIN thread t USING(utid) JOIN process p USING(upid)
        WHERE {scope} AND ps.callsite_id IS NOT NULL),
      walk(sample_id,callsite_id,frame_id,parent_id,is_leaf) AS (
        SELECT r.sample_id,c.id,c.frame_id,c.parent_id,1 FROM roots r
        JOIN stack_profile_callsite c ON c.id=r.callsite_id
        UNION ALL SELECT w.sample_id,c.id,c.frame_id,c.parent_id,0
        FROM walk w JOIN stack_profile_callsite c ON c.id=w.parent_id),
      frame_counts AS (
        SELECT frame_id,COUNT(DISTINCT sample_id) AS inclusive_samples,
        COUNT(DISTINCT CASE WHEN is_leaf=1 THEN sample_id END) AS leaf_samples
        FROM walk GROUP BY frame_id)
      SELECT m.name AS library,m.build_id AS build_id,f.rel_pc AS rel_pc,
        m.start_offset AS mapping_start_offset,m.exact_offset AS mapping_exact_offset,
        m.load_bias AS mapping_load_bias,
        COALESCE((SELECT s.name FROM stack_profile_symbol s
                  WHERE s.symbol_set_id=f.symbol_set_id ORDER BY s.inlined,s.id LIMIT 1),f.name,'') AS symbol,
        c.inclusive_samples AS inclusive_samples,c.leaf_samples AS leaf_samples
      FROM frame_counts c JOIN stack_profile_frame f ON f.id=c.frame_id
      JOIN stack_profile_mapping m ON m.id=f.mapping
      ORDER BY c.leaf_samples DESC,c.inclusive_samples DESC LIMIT 500""")
    for row in rows:
        library = row["library"].replace("\\", "/").rsplit("/", 1)[-1]
        mapping_kind = "shared_library"
        if library.endswith(".apk"):
            library, mapping_kind = "app_apk", "app_apk"
        elif library not in NATIVE_LIBRARIES:
            result["excluded_library_frame_count"] += 1
            continue
        build_id = row["build_id"]
        if not re.fullmatch(r"[0-9a-fA-F]{0,128}", build_id):
            build_id = ""
        symbol = row["symbol"]
        # Keep compiled static names, never arbitrary paths/URLs/source strings.
        if (not re.fullmatch(r"[A-Za-z0-9_$<>()\[\]:.,*& ~+\-=!?]{1,512}", symbol)
                or symbol in ("[unknown]", "unknown", "[NULL]")):
            symbol = ""
        frame = {"library": library, "mapping_kind": mapping_kind,
                 "build_id": build_id.lower(), "rel_pc": number(row["rel_pc"]),
                 "mapping_start_offset": number(row["mapping_start_offset"]),
                 "mapping_exact_offset": number(row["mapping_exact_offset"]),
                 "mapping_load_bias": number(row["mapping_load_bias"]),
                 "symbol": symbol, "inclusive_samples": number(row["inclusive_samples"]),
                 "leaf_samples": number(row["leaf_samples"])}
        require(frame["rel_pc"] >= 0 and 0 <= frame["leaf_samples"] <= frame["inclusive_samples"] <= result["samples"])
        result["frames"].append(frame)
    result["native_symbols_resolved"] = any(frame["symbol"] for frame in result["frames"])
    result["resolved_frame_count"] = sum(bool(frame["symbol"]) for frame in result["frames"])
    result["address_frame_count"] = len(result["frames"])
    result["native_symbols_fully_resolved"] = bool(result["frames"]) and all(frame["symbol"] for frame in result["frames"])
    return result


def analyze(processor, trace, pid, start_us, end_us, frames=(), raster_windows=()):
    with load_trace(processor, trace) as loaded:
        return analyze_loaded(loaded, trace, pid, start_us, end_us, frames, raster_windows)


def analyze_loaded(processor, trace, pid, start_us, end_us, frames=(), raster_windows=()):
    """Map VM monotonic bounds and export QA-thread scheduler state, never names/args."""
    integer(pid, 1)
    integer(start_us, 1)
    integer(end_us, start_us + 1)
    clocks = query(processor, trace, """SELECT MIN(ts-clock_value) AS lo,
      MAX(ts-clock_value) AS hi, COUNT(*) AS n FROM clock_snapshot
      WHERE clock_name='MONOTONIC'""")
    require(len(clocks) == 1 and number(clocks[0]["n"]) >= 2)
    low, high = number(clocks[0]["lo"]), number(clocks[0]["hi"])
    require(0 <= high - low <= 100000)  # Reject unsupported/unstable clock mapping.
    offset = (low + high) // 2
    start, end = start_us * 1000 + offset, end_us * 1000 + offset
    bounds = query(processor, trace, "SELECT start_ts AS lo,end_ts AS hi FROM trace_bounds")
    require(len(bounds) == 1 and number(bounds[0]["lo"]) <= start < end <= number(bounds[0]["hi"]))
    threads = numeric_rows(query(processor, trace, thread_states_sql(pid, start, end)))
    require(threads and any(row["running_ns"] > 0 for row in threads))
    frames_out = []
    for frame_start_us, build_us in frames:
        integer(frame_start_us, start_us)
        integer(build_us, 1)
        require(frame_start_us + build_us <= end_us)
        fa, fb = frame_start_us * 1000 + offset, (frame_start_us + build_us) * 1000 + offset
        rows = query(processor, trace, thread_states_sql(pid, fa, fb))
        frames_out.append({"start_monotonic_us": frame_start_us, "build_us": build_us,
                           "threads": numeric_rows(rows),
                           "native_profile": native_window_profile(processor, trace, pid, fa, fb, role=1)})
    raster_out = []
    for raster_start_us, raster_us in raster_windows:
        integer(raster_start_us, start_us)
        integer(raster_us, 1)
        require(raster_start_us+raster_us <= end_us)
        ra, rb = raster_start_us*1000+offset, (raster_start_us+raster_us)*1000+offset
        raster_out.append({"start_monotonic_us": raster_start_us, "raster_us": raster_us,
                           "threads": numeric_rows(query(processor, trace, thread_states_sql(pid, ra, rb))),
                           "native_profile": native_window_profile(processor, trace, pid, ra, rb, role=2)})
    paints = numeric_rows(query(processor, trace, f"""SELECT s.ts AS ts,s.dur AS dur,t.tid AS tid
      FROM slice s JOIN thread_track tt ON tt.id=s.track_id
      JOIN thread t USING(utid) JOIN process p USING(upid)
      WHERE p.pid={pid} AND {ui_thread_predicate()} AND s.name='PAINT'
      AND s.dur>10000000 AND s.ts>={start} AND s.ts+s.dur<={end}
      ORDER BY s.dur DESC LIMIT 20"""))
    paint_windows = []
    for paint in paints:
        rows = numeric_rows(query(processor, trace, thread_states_sql(pid, paint["ts"], paint["ts"]+paint["dur"])))
        paint_windows.append({"start_monotonic_us": (paint["ts"]-offset)//1000,
                              "paint_wall_ns": paint["dur"], "tid": paint["tid"],
                              "threads": rows,
                              "native_profile": native_window_profile(processor, trace, pid,
                                                                       paint["ts"], paint["ts"]+paint["dur"],
                                                                       tid=paint["tid"])})
    paint_count = query(processor, trace, f"""SELECT COUNT(*) AS n FROM slice s
      JOIN thread_track tt ON tt.id=s.track_id JOIN thread t USING(utid)
      JOIN process p USING(upid) WHERE p.pid={pid} AND {ui_thread_predicate()}
      AND s.name='PAINT' AND s.ts>={start} AND s.ts<{end}""")
    require(len(paint_count) == 1)
    frame_timeline = numeric_rows(query(processor, trace, f"""SELECT COUNT(*) AS frames,
      COALESCE(MAX(f.dur),0) AS max_ns FROM actual_frame_timeline_slice f
      JOIN process p USING(upid) WHERE p.pid={pid} AND f.ts>={start} AND f.ts<{end} AND f.dur>0"""))
    losses = numeric_rows(query(processor, trace, """SELECT COUNT(*) AS counters,
      COALESCE(SUM(value),0) AS total FROM stats WHERE severity='data_loss' AND value>0"""))
    return {"target_pid": pid, "start_monotonic_us": start_us, "end_monotonic_us": end_us,
            "clock_offset_ns": offset, "clock_offset_spread_ns": high-low,
            "threads": threads, "frames": frames_out, "raster_windows": raster_out,
            "ui_uses_main_thread": any(row["role"]==1 and row["tid"]==pid for row in threads),
            "paint_slices_present": number(paint_count[0]["n"]) > 0,
            "slow_paint_windows": paint_windows, "app_frame_timeline": frame_timeline,
            "trace_data_loss": losses,
            "native_samples": perf_samples(processor, trace, pid),
            "native_profile": native_window_profile(processor, trace, pid, start, end)}


def capture_system(client, output, seconds, scenario, trace_processor, native_stacks=False):
    """Capture around a caller-owned QA replay; no app launch/input/backend action."""
    output = private_output(output)
    require(type(seconds) is int and 5 <= seconds <= 60)
    focused(client)
    isolate = rpc(client, "getIsolate", isolateId=client.isolate)
    require(REPLAY_EXTENSION in isolate.get("extensionRPCs", []))
    pid_text = adb_call(client, "shell", "pidof", PACKAGE).stdout.strip()
    require(re.fullmatch(r"[1-9][0-9]*", pid_text) is not None)
    pid = int(pid_text)
    native = native_preflight(client, output, trace_processor, pid) if native_stacks else {
        "requested": False, "supported": False}
    config = prepare_config(output, seconds, pid if native.get("supported") else None)
    fence_events = available_fence_events(client)
    if fence_events:
        config = config.replace('  atrace_categories: "gfx"',
                                ''.join(f'  ftrace_events: "{event}"\n' for event in fence_events)
                                + '  atrace_categories: "gfx"')
        (output / "system-config.pbtxt").write_text(config)
    session = Session(client, output)
    trace = None
    try:
        envelope_start = integer(rpc(client, "getVMTimelineMicros")["timestamp"], 1)
        session.start(config)
        clock_start = integer(rpc(client, "getVMTimelineMicros")["timestamp"], 1)
        replay = scenario(client)
        clock_end = integer(rpc(client, "getVMTimelineMicros")["timestamp"], clock_start + 1)
        start, end = integer(replay["startMonotonicUs"], clock_start), integer(replay["endMonotonicUs"], clock_start + 1)
        require(envelope_start <= clock_start <= start < end <= clock_end)
        require(clock_end-clock_start < seconds*1000000)
        focused(client)
        require(adb_call(client, "shell", "pidof", PACKAGE).stdout.strip() == pid_text)
    finally:
        trace = session.finish()
    starts, builds = replay.get("frameBuildStartUs", []), replay.get("buildUs", [])
    require(isinstance(starts, list) and isinstance(builds, list) and len(starts) == len(builds))
    require(all(type(s) is int and type(b) is int and s>0 and b>=0 for s,b in zip(starts,builds)))
    slow_builds = [(s,b) for s,b in zip(starts,builds) if b>10000]
    contained_builds = [(s,b) for s,b in slow_builds if start<=s and s+b<=end]
    selected = sorted(contained_builds, key=lambda window: window[1], reverse=True)[:20]
    raster_starts, rasters = replay.get("frameRasterStartUs", []), replay.get("rasterUs", [])
    require(isinstance(raster_starts, list) and isinstance(rasters, list) and len(raster_starts) == len(rasters))
    require(all(type(s) is int and type(r) is int and s>0 and r>=0 for s,r in zip(raster_starts,rasters)))
    slow_rasters = [(s,r) for s,r in zip(raster_starts,rasters) if r>10000]
    contained_rasters = [(s,r) for s,r in slow_rasters if start<=s and s+r<=end]
    selected_rasters = sorted(contained_rasters, key=lambda window: window[1], reverse=True)[:20]
    report = analyze(trace_processor, trace, pid, start, end, selected, selected_rasters)
    report["native_preflight"] = native
    # Policy 1: longest contained durations first; equal durations retain input order.
    report["slow_window_selection_policy"] = 1
    report["fence_wait_event_count"] = len(fence_events)
    report["build_windows_outside_replay_count"] = len(slow_builds)-len(contained_builds)
    report["raster_windows_outside_replay_count"] = len(slow_rasters)-len(contained_rasters)
    report["build_windows_over_limit_count"] = max(0,len(contained_builds)-20)
    report["raster_windows_over_limit_count"] = max(0,len(contained_rasters)-20)
    report["native_symbols_require_matching_apk_and_flutter_engine"] = True
    report["raw_trace_private_local_only"] = True
    (output / "system-summary.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    prepare = modes.add_parser("prepare", help="Host only; no ADB")
    capture = modes.add_parser("capture", help="Future authorized window; caller must prepare the QA replay first")
    for command in (prepare, capture):
        command.add_argument("--output", type=Path, required=True, help="Ignored local build/ directory")
        command.add_argument("--seconds", type=int, default=30)
    capture.add_argument("--serial", required=True)
    capture.add_argument("--trace-processor", type=Path, required=True)
    capture.add_argument("--native-stacks", action="store_true")
    args = parser.parse_args()
    try:
        if args.mode == "prepare":
            prepare_config(args.output, args.seconds)
        else:
            print("Raw system trace stays in ignored local build/: do not upload or export it.", flush=True)
            with WingPerfClient(args.serial, PACKAGE) as client:
                capture_system(client, args.output, args.seconds,
                               lambda c: rpc(c, REPLAY_EXTENSION, timeout=args.seconds,
                                             isolateId=c.isolate), args.trace_processor, args.native_stacks)
        print(json.dumps({"complete": True}))
        return 0
    except (Exception, KeyboardInterrupt):
        print(json.dumps({"complete": False, "error": "system_trace_unavailable"}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
