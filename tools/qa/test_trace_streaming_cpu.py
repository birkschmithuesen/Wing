"""Host-only protocol/redaction/failure checks; no ADB or VM is launched."""
import io
import json
import unittest
import urllib.parse
from types import SimpleNamespace
from unittest.mock import Mock, patch

from trace_streaming_cpu import PACKAGE, STREAMS, RpcFailure, capture, rpc, sanitize_cpu, sanitize_timeline


def cpu():
    return {"type": "CpuSamples", "sampleCount": 2, "samplePeriod": 1000, "maxStackDepth": 64,
            "functions": [{"function": {"name": "leaf", "id": "PRIVATE"},
                           "resolvedUrl": "package:wing/leaf.dart", "inclusiveTicks": 1, "exclusiveTicks": 1},
                          {"function": {"name": "parent"}, "resolvedUrl": "file:///PRIVATE",
                           "inclusiveTicks": 2, "exclusiveTicks": 1}],
            "samples": [{"timestamp": 110, "tid": 7, "stack": [0, 1], "userTag": "PRIVATE"},
                        {"timestamp": 190, "tid": 7, "stack": [1], "truncated": True}],
            "functionCode": "PRIVATE", "pid": 123}


def timeline():
    return {"type": "Timeline", "traceEvents": [
        {"name": "thread_name", "ph": "M", "args": {"name": "PRIVATE"}},
        {"name": "WingStreamingReplayStart", "cat": "Dart", "ph": "i", "ts": 101,
         "tid": 7, "pid": 123, "args": {"secret": "PRIVATE"}},
        {"name": "Frame", "cat": "Embedder", "ph": "X", "ts": 150, "dur": 5, "id": "0xab", "args": {"text": "PRIVATE"}},
        {"name": "WingStreamingReplayEnd", "cat": "Dart", "ph": "i", "ts": 201}]}


def replay():
    return {"run": 1, "deltas": 600, "presentations": 60, "draftEdits": 120, "valid": 1,
            "geometryStable": 1, "animationEnabled": 1, "focusHeld": 1,
            "exactFinalContent": 1, "exactFinalDraft": 1, "keyboardStartDp": 250,
            "keyboardEndDp": 250, "frameCount": 20, "startMonotonicUs": 100,
            "endMonotonicUs": 200, "elapsedUs": 100, "private": "PRIVATE",
            "buildUs": [5] * 20, "rasterUs": [2] * 20, "frameBuildStartUs": [150] * 20}


class FakeService:
    def __init__(self, failure=None):
        self.profiler, self.streams, self.calls = "false", ["GC"], []
        self.failure, self.clock = failure, iter([90, 210])
        self.client = SimpleNamespace(isolate="isolates/1", call=Mock(return_value=
                                      "mCurrentFocus=Window{123 " + PACKAGE + "/com.tarkilhk.wing.MainActivity}"))

    def rpc(self, client, method, **params):
        self.calls.append((method, params))
        if self.failure:
            result = self.failure(method, params)
            if result is not None:
                return result
        if method == "getIsolate":
            return {"extensionRPCs": ["ext.wingPerf.replay"]}
        if method == "getFlagList":
            return {"flags": [{"name": "profiler", "valueAsString": self.profiler},
                              {"name": "profile_period", "valueAsString": "1000"}]}
        if method == "getVMTimelineFlags":
            return {"recorderName": "Ring", "availableStreams": STREAMS, "recordedStreams": self.streams[:]}
        if method == "setFlag":
            self.profiler = params["value"]
        elif method == "setVMTimelineFlags":
            self.streams = params["recordedStreams"][1:-1].split(",")
        elif method == "getVMTimelineMicros":
            return {"timestamp": next(self.clock)}
        elif method == "ext.wingPerf.replay":
            return replay()
        elif method == "getCpuSamples":
            return cpu()
        elif method == "getVMTimeline":
            return timeline()
        return {"type": "Success"}

    def capture(self):
        with patch("trace_streaming_cpu.rpc", side_effect=self.rpc):
            return capture(self.client, "plain", "test")


class ProtocolTests(unittest.TestCase):
    def test_rejected_rpc_keeps_only_numeric_code_and_method(self):
        body = {"error": {"code": -32601, "message": "PRIVATE", "data": "PRIVATE"}}
        client = SimpleNamespace(base="http://localhost/PRIVATE/", http=Mock())
        client.http.open.return_value = io.StringIO(json.dumps(body))
        with self.assertRaises(RpcFailure) as failure:
            rpc(client, "getCpuSamples")
        self.assertEqual(failure.exception.code, -32601)
        self.assertEqual(failure.exception.method, "getCpuSamples")
        self.assertNotIn("PRIVATE", str(failure.exception))

    def test_streams_use_vm_enum_list_encoding_and_timeout_is_bounded(self):
        client = SimpleNamespace(base="http://localhost/PRIVATE/", http=Mock())
        client.http.open.return_value = io.StringIO('{"result":{"type":"Success"}}')
        rpc(client, "setVMTimelineFlags", recordedStreams="[Dart,Embedder,GC]")
        url = client.http.open.call_args.args[0]
        encoded = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["recordedStreams"][0]
        self.assertEqual(encoded, "[Dart,Embedder,GC]")
        self.assertEqual(client.http.open.call_args.kwargs["timeout"], 8)

    def test_sentinel_and_non_success_mutation_fail(self):
        for result in ({"type": "Sentinel", "valueAsString": "PRIVATE"}, {"type": "Error"}, {}):
            client = SimpleNamespace(base="http://localhost/", http=Mock())
            client.http.open.return_value = io.StringIO(json.dumps({"result": result}))
            with self.subTest(result=result), self.assertRaises(RpcFailure):
                rpc(client, "setFlag", name="profiler", value="true")

    def test_leaf_indices_preserved_and_private_fields_removed(self):
        clean = sanitize_cpu(cpu(), 100, 200)
        self.assertEqual(clean["samples"][0]["stack"], [0, 1])
        self.assertEqual(clean["functions"][clean["samples"][0]["stack"][0]]["name"], "leaf")
        self.assertNotIn("PRIVATE", json.dumps(clean))
        self.assertNotIn("PRIVATE", json.dumps(sanitize_timeline(timeline(), 90, 210)))
        self.assertEqual(sanitize_timeline(timeline(), 90, 210)["traceEvents"][1]["id"], "0xab")

    def test_static_function_owner_preserved_without_object_ids_or_library_paths(self):
        value = cpu()
        value['functions'][0]['function']['owner'] = {
            'type':'@Class', 'name':'RenderEditable', 'id':'PRIVATE'}
        value['functions'][1]['function']['owner'] = {
            'type':'@Library', 'name':'file:///PRIVATE', 'id':'PRIVATE'}
        clean = sanitize_cpu(value, 100, 200)
        self.assertEqual(clean['functions'][0]['owner'], 'RenderEditable')
        self.assertEqual(clean['functions'][1]['owner'], '')
        self.assertNotIn('PRIVATE', json.dumps(clean))

    def test_native_image_names_keep_only_known_library_and_address(self):
        for path in ['/data/app/PRIVATE/base.apk!/lib/arm64-v8a/libapp.so+0x714a74',
                     '/home/PRIVATE/libapp.so+0x714a74',
                     r'C:\PRIVATE\libapp.so+0x714a74']:
            with self.subTest(path=path):
                value = cpu()
                value['functions'][0]['function'].update(
                    name='[Native] ' + path,
                    owner={'type':'@Class', 'name':'RenderEditable', 'id':'PRIVATE'})
                value['functions'][1]['function']['name'] = '[Native] /home/PRIVATE/unknown.so+0x123'
                clean = sanitize_cpu(value, 100, 200)
                self.assertEqual(clean['functions'][0]['name'], '[Native] libapp.so+0x714a74')
                self.assertEqual(clean['functions'][0]['owner'], 'RenderEditable')
                self.assertEqual(clean['functions'][1]['name'], '')
                self.assertEqual(clean['samples'][0]['stack'], [0, 1])
                self.assertNotIn('PRIVATE', json.dumps(clean))

    def test_dart_division_operator_names_are_preserved(self):
        for name in ['/', '~/','=/', '_Double./', '_IntegerImplementation.~/']:
            with self.subTest(name=name):
                value = cpu()
                value['functions'][0]['function']['name'] = name
                self.assertEqual(sanitize_cpu(value, 100, 200)['functions'][0]['name'], name)

    def test_native_installation_path_is_not_exported_as_a_function_name(self):
        value = cpu()
        value['functions'][0]['function']['name'] = 'native /data/app/PRIVATE/base.apk symbol'
        clean = sanitize_cpu(value, 100, 200)
        self.assertEqual(clean['functions'][0]['name'], '')
        self.assertNotIn('PRIVATE', json.dumps(clean))

    def test_empty_bad_indices_and_outside_samples_rejected(self):
        changes = [lambda v: v.update(sampleCount=0, samples=[]),
                   lambda v: v["samples"][0].update(stack=[2]),
                   lambda v: v["samples"][0].update(stack=[True]),
                   lambda v: v["samples"][0].update(timestamp=99)]
        for change in changes:
            value = cpu()
            change(value)
            with self.subTest(change=change), self.assertRaises(ValueError):
                sanitize_cpu(value, 100, 200)

    def test_partial_empty_stacks_are_retained_as_unattributed(self):
        value = cpu()
        value["samples"][0]["stack"] = []
        clean = sanitize_cpu(value, 100, 200)
        self.assertEqual(clean["sample_count"], 2)
        self.assertEqual(clean["unattributed_sample_count"], 1)
        self.assertEqual(clean["samples"][0]["stack"], [])
        value["samples"][1]["stack"] = []
        with self.assertRaises(ValueError):
            sanitize_cpu(value, 100, 200)

    def test_timeline_requires_both_markers_and_in_bounds_events(self):
        for change in (lambda v: v.update(traceEvents=[]),
                       lambda v: v["traceEvents"].pop(),
                       lambda v: v["traceEvents"].pop(2),
                       lambda v: v["traceEvents"][-1].update(ts=211)):
            value = timeline()
            change(value)
            with self.subTest(change=change), self.assertRaises(ValueError):
                sanitize_timeline(value, 90, 210)

    def test_complete_interval_uses_replay_bounds_and_restores(self):
        service = FakeService()
        report = service.capture()
        self.assertEqual(report["status"], "complete")
        self.assertEqual((service.profiler, service.streams), ("false", ["GC"]))
        cpu_call = next(params for method, params in service.calls if method == "getCpuSamples")
        self.assertEqual((cpu_call["timeOriginMicros"], cpu_call["timeExtentMicros"]), (100, 100))
        timeline_call = next(params for method, params in service.calls if method == "getVMTimeline")
        self.assertEqual((timeline_call["timeOriginMicros"], timeline_call["timeExtentMicros"]), (90, 120))
        self.assertEqual(next(p for m, p in service.calls if m == "ext.wingPerf.replay")["timeout"], 25)
        self.assertNotIn("PRIVATE", json.dumps(report))
        self.assertEqual(service.client.call.call_count, 2)

    def test_rpc_failure_restores_both_settings(self):
        def failure(method, params):
            if method == "getCpuSamples":
                raise RpcFailure(method, -32601)
        service = FakeService(failure)
        report = service.capture()
        self.assertEqual(report["status"], "inconclusive")
        self.assertEqual((service.profiler, service.streams), ("false", ["GC"]))
        self.assertEqual(report["errors"], [{"stage": 4, "type": "RpcFailure", "method": "getCpuSamples", "code": -32601}])

    def test_cleanup_failure_still_attempts_other_restore(self):
        def failure(method, params):
            if method == "setVMTimelineFlags" and params["recordedStreams"][1:-1].split(",") == ["GC"]:
                raise RpcFailure(method, 114)
        service = FakeService(failure)
        report = service.capture()
        self.assertEqual(report["status"], "inconclusive")
        self.assertEqual(service.profiler, "false")
        self.assertTrue(any(error["stage"] == 5 for error in report["errors"]))

    def test_focus_and_invalid_replay_fail_closed(self):
        service = FakeService()
        service.client.call.return_value = "mCurrentFocus=Window{other.package/.MainActivity}"
        self.assertEqual(service.capture()["status"], "inconclusive")
        for key, bad in (("deltas", 601), ("valid", 0), ("frameCount", 0), ("keyboardEndDp", 0)):
            def failure(method, params):
                if method == "ext.wingPerf.replay":
                    value = replay()
                    value[key] = bad
                    return value
            service = FakeService(failure)
            with self.subTest(key=key):
                self.assertEqual(service.capture()["status"], "inconclusive")
                self.assertEqual((service.profiler, service.streams), ("false", ["GC"]))

    def test_frame_clock_and_missing_extension_fail_closed(self):
        for method, replacement in (
                ("getIsolate", {"extensionRPCs": []}),
                ("ext.wingPerf.replay", {**replay(), "startMonotonicUs": 80}),
                ("ext.wingPerf.replay", {**replay(), "buildUs": []}),
                ("ext.wingPerf.replay", {**replay(), "frameBuildStartUs": [201] * 20})):
            service = FakeService(lambda name, params: replacement if name == method else None)
            with self.subTest(method=method, replacement=replacement):
                self.assertEqual(service.capture()["status"], "inconclusive")
                self.assertEqual((service.profiler, service.streams), ("false", ["GC"]))


if __name__ == "__main__":
    unittest.main()
