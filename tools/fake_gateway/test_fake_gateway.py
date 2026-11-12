#!/usr/bin/env python3
"""Live contract probe for the local Wing fixture."""

from __future__ import annotations

# This executable probe uses assertions as its verdict; optimization must never
# turn a run into an unchecked success.
if not __debug__:
    raise RuntimeError("Run the gateway contract probe without Python optimization")

import argparse
import asyncio
import base64
import json

from aiohttp import ClientSession, WSMsgType

DISCONNECT_CASES = (
    ("before_ack", False, 0),
    ("after_ack_before_first_delta", True, 0),
    ("mid_stream_after_2_deltas", True, 2),
)


async def rpc(ws, request_id: int, method: str, params: dict) -> dict:
    await ws.send_json(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }
    )
    while True:
        message = await ws.receive(timeout=5)
        assert message.type == WSMsgType.TEXT, message
        payload = json.loads(message.data)
        if payload.get("id") == request_id:
            assert "error" not in payload, payload
            return payload["result"]


async def rpc_response(ws, request_id: int, method: str, params: dict) -> dict:
    await ws.send_json(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }
    )
    while True:
        message = await ws.receive(timeout=5)
        assert message.type == WSMsgType.TEXT, message
        payload = json.loads(message.data)
        if payload.get("id") == request_id:
            return payload


async def probe_disconnect_scenario(
    session: ClientSession,
    base_url: str,
    scenario: str,
    expected_ack: bool,
    expected_deltas: int,
    request_id: int,
) -> None:
    async with session.post(
        f"{base_url}/api/auth/ws-ticket",
        headers={"X-Hermes-Session-Token": "fixture-dashboard-token"},
    ) as response:
        assert response.status == 200
        ticket = (await response.json())["ticket"]

    ws_url = (
        base_url.replace("http://", "ws://")
        .replace("https://", "wss://")
        + f"/api/ws?ticket={ticket}"
    )
    session_id = f"fixture-disconnect-{scenario}"
    ack_seen = False
    delta_count = 0
    turn_end_count = 0

    async with session.ws_connect(ws_url) as ws:
        created = await rpc(
            ws,
            request_id,
            "session.create",
            {"session_id": session_id},
        )
        assert created["session_id"] == session_id
        await ws.send_json(
            {
                "jsonrpc": "2.0",
                "id": request_id + 1,
                "method": "prompt.submit",
                "params": {
                    "session_id": session_id,
                    "text": "Synthetic disconnect contract probe.",
                    "fixture_disconnect_scenario": scenario,
                },
            }
        )

        while True:
            message = await ws.receive(timeout=5)
            if message.type == WSMsgType.TEXT:
                payload = json.loads(message.data)
                if payload.get("id") == request_id + 1:
                    assert payload["result"]["status"] == "streaming"
                    ack_seen = True
                    continue
                if payload.get("method") != "event":
                    continue
                event_type = payload["params"]["type"]
                if event_type == "message.delta":
                    delta_count += 1
                if event_type == "turn.end":
                    turn_end_count += 1
                continue
            if message.type in {
                WSMsgType.CLOSE,
                WSMsgType.CLOSING,
                WSMsgType.CLOSED,
            }:
                break
            assert message.type != WSMsgType.ERROR, ws.exception()
            raise AssertionError(f"Unexpected WebSocket message: {message}")

    assert ack_seen is expected_ack
    assert delta_count == expected_deltas
    assert turn_end_count == 0

    async with session.get(
        f"{base_url}/api/sessions/{session_id}/messages",
        headers={"Authorization": "Bearer test-key"},
    ) as response:
        assert response.status == 200
        history = await response.json()
        assert history["data"] == []


async def probe(base_url: str) -> None:
    dashboard_headers = {
        "X-Hermes-Session-Token": "fixture-dashboard-token"
    }
    async with ClientSession() as session:
        async with session.get(f"{base_url}/health") as response:
            health = await response.json()
            assert response.status == 200
            assert "json-rpc-websocket" in health["contracts"]
            assert "fail-closed-disconnect-fixtures" in health["contracts"]

        async with session.post(
            f"{base_url}/test/disconnect-ledger/reset"
        ) as response:
            assert response.status == 200
            reset_ledger = await response.json()
            assert reset_ledger["schema"] == (
                "hermes.fake_gateway.disconnect_ledger.v1"
            )
            assert all(
                record["prompt_submit_count"] == 0
                for record in reset_ledger["scenarios"].values()
            )

        async with session.get(f"{base_url}/") as response:
            homepage = await response.text()
            assert 'window.__HERMES_SESSION_TOKEN__="fixture-dashboard-token";' in homepage

        async with session.get(
            f"{base_url}/api/model/info",
            headers=dashboard_headers,
        ) as response:
            model_info = await response.json()
            assert model_info == {
                "model": "hermes-agent",
                "provider": "fixture",
            }

        async with session.get(
            f"{base_url}/api/model/options",
            headers=dashboard_headers,
        ) as response:
            options = await response.json()
            assert options["providers"][0]["models"][1] == "fixture-model"

        async with session.post(
            f"{base_url}/api/model/set",
            headers=dashboard_headers,
            json={
                "scope": "main",
                "provider": "fixture",
                "model": "fixture-model",
            },
        ) as response:
            profile_default = await response.json()
            assert profile_default["scope"] == "profile"
            assert profile_default["model"] == "fixture-model"

        async with session.get(
            f"{base_url}/api/model/info",
            headers=dashboard_headers,
        ) as response:
            updated_info = await response.json()
            assert updated_info["model"] == "fixture-model"

        async with session.post(
            f"{base_url}/api/model/set",
            headers=dashboard_headers,
            json={
                "scope": "main",
                "provider": "fixture",
                "model": "hermes-agent",
            },
        ) as response:
            reset_default = await response.json()
            assert reset_default["model"] == "hermes-agent"

        async with session.post(
            f"{base_url}/api/auth/ws-ticket",
            headers=dashboard_headers,
        ) as response:
            ticket = (await response.json())["ticket"]

        ws_url = (
            base_url.replace("http://", "ws://")
            .replace("https://", "wss://")
            + f"/api/ws?ticket={ticket}"
        )
        async with session.ws_connect(ws_url, max_msg_size=20 * 1024 * 1024) as ws:
            ready = await ws.receive_json(timeout=5)
            assert ready["params"] == {
                "type": "gateway.ready", "payload": {"skin": {}},
            }
            for index, retired_method in enumerate((
                    "session.open", "turn.reconcile", "turn.interrupt",
                    "attachment.detach@2")):
                rejected = await rpc_response(ws, -10 - index, retired_method, {})
                assert rejected["error"]["code"] == -32601, rejected
            session_id = "fixture-contract-test"
            created = await rpc(
                ws,
                1,
                "session.create",
                {"session_id": session_id},
            )
            assert created["session_id"] == session_id
            for index, retired_field in enumerate(("version", "client_turn_id")):
                rejected = await rpc_response(ws, -20 - index, "prompt.submit", {
                    "session_id": session_id,
                    "text": "Unsupported recovery input must never start a turn.",
                    retired_field: 2,
                })
                assert rejected["error"]["code"] == 4000, rejected
            resumed = await rpc(
                ws,
                101,
                "session.resume",
                {"session_id": session_id},
            )
            assert resumed["session_id"] == session_id
            renamed = await rpc(
                ws,
                102,
                "session.title",
                {"session_id": session_id, "title": "Fixture renamed"},
            )
            assert renamed["title"] == "Fixture renamed"
            branched = await rpc(
                ws,
                103,
                "session.branch",
                {"session_id": session_id, "name": "Fixture branch"},
            )
            assert branched["parent"] == session_id
            assert branched["session_id"].endswith("-branch")

            configured = await rpc(
                ws,
                2,
                "config.set",
                {
                    "session_id": session_id,
                    "key": "model",
                    "value": "fixture-model --provider fixture --session",
                },
            )
            assert configured["scope"] == "session"
            reasoning_configured = await rpc(
                ws,
                104,
                "config.set",
                {
                    "session_id": session_id,
                    "key": "reasoning",
                    "value": "xhigh",
                },
            )
            assert reasoning_configured["value"] == "xhigh"
            reasoning = await rpc(
                ws,
                105,
                "config.get",
                {"session_id": session_id, "key": "reasoning"},
            )
            assert reasoning["value"] == "xhigh"

            fixture_bytes = b"Wing fixture attachment\n"
            attachment = await rpc(
                ws,
                3,
                "file.attach",
                {
                    "session_id": session_id,
                    "name": "contract-probe.txt",
                    "path": "",
                    "source_channel": "hermes_mobile",
                    "source_profile": "pro",
                    "data_url": (
                        "data:text/plain;base64,"
                        + base64.b64encode(fixture_bytes).decode("ascii")
                    ),
                },
            )
            assert attachment["attached"] is True
            assert attachment["ref_text"].startswith("@file:")
            assert attachment["atlas_intake"]["accepted"] is True
            assert attachment["atlas_intake"]["status"] == "accepted"

            await ws.send_json(
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "prompt.submit",
                    "params": {
                        "session_id": session_id,
                        "text": f"Inspect this fixture.\n\n{attachment['ref_text']}",
                    },
                }
            )
            response_seen = False
            delta_text = ""
            turn_end_seen = False
            while not turn_end_seen:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("id") == 4:
                    assert payload["result"]["status"] == "streaming"
                    response_seen = True
                    continue
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                if params["type"] == "message.delta":
                    delta_text += params["payload"]["text"]
                if params["type"] == "turn.end":
                    turn_end_seen = True

            assert response_seen
            assert "file.attach" in delta_text
            assert turn_end_seen

            slow_prompt = await rpc(
                ws,
                5,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "slow stop test",
                },
            )
            assert slow_prompt["status"] == "streaming"
            first_delta = await ws.receive(timeout=5)
            first_delta_payload = json.loads(first_delta.data)
            assert first_delta_payload["params"]["type"] == "message.delta"

            interrupted = await rpc(
                ws,
                6,
                "session.interrupt",
                {"session_id": session_id},
            )
            assert interrupted["status"] == "interrupted"
            assert interrupted["active"] is True

            terminal = await ws.receive(timeout=5)
            terminal_payload = json.loads(terminal.data)
            assert terminal_payload["params"]["type"] == "turn.end"
            assert terminal_payload["params"]["payload"]["status"] == "interrupted"

            approval_prompt = await rpc(
                ws,
                7,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "approval test",
                },
            )
            assert approval_prompt["status"] == "streaming"
            approval_message = await ws.receive(timeout=5)
            approval_payload = json.loads(approval_message.data)
            assert approval_payload["params"]["type"] == "approval.request"
            approval_request = approval_payload["params"]["payload"]
            assert approval_request["command"] == "echo wing-approval"
            assert approval_request["choices"] == [
                "once",
                "session",
                "always",
                "deny",
            ]

            approved = await rpc(
                ws,
                8,
                "approval.respond",
                {
                    "session_id": session_id,
                    "choice": "session",
                },
            )
            assert approved["resolved"] is True

            approval_delta = ""
            approval_turn_end = False
            while not approval_turn_end:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                if params["type"] == "message.delta":
                    approval_delta += params["payload"]["text"]
                if params["type"] == "turn.end":
                    approval_turn_end = True
            assert "resolved with session" in approval_delta

            sudo_prompt = await rpc(
                ws,
                9,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "sudo test",
                },
            )
            assert sudo_prompt["status"] == "streaming"
            sudo_message = await ws.receive(timeout=5)
            sudo_payload = json.loads(sudo_message.data)
            assert sudo_payload["method"] == "sudo"
            sudo_request_id = sudo_payload["id"]
            sudo_result = await rpc(
                ws,
                10,
                "request.answer",
                {
                    "id": sudo_request_id,
                    "result": {"value": "fixture-sudo-password"},
                },
            )
            assert sudo_result["status"] == "ok"

            sudo_delta = ""
            sudo_turn_end = False
            while not sudo_turn_end:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                if params["type"] == "message.delta":
                    sudo_delta += params["payload"]["text"]
                if params["type"] == "turn.end":
                    sudo_turn_end = True
            assert "sudo password was received" in sudo_delta

            secret_prompt = await rpc(
                ws,
                11,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "secret test",
                },
            )
            assert secret_prompt["status"] == "streaming"
            secret_message = await ws.receive(timeout=5)
            secret_payload = json.loads(secret_message.data)
            assert secret_payload["method"] == "secret"
            secret_request = secret_payload["params"]
            assert secret_request["env_var"] == "FIXTURE_API_TOKEN"
            secret_result = await rpc(
                ws,
                12,
                "request.answer",
                {
                    "id": secret_payload["id"],
                    "result": {"value": "fixture-secret-value"},
                },
            )
            assert secret_result["status"] == "ok"

            secret_delta = ""
            secret_turn_end = False
            while not secret_turn_end:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                if params["type"] == "message.delta":
                    secret_delta += params["payload"]["text"]
                if params["type"] == "turn.end":
                    secret_turn_end = True
            assert "secret was received" in secret_delta

            expiring_prompt = await rpc(
                ws,
                13,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "secret expire test",
                },
            )
            assert expiring_prompt["status"] == "streaming"
            expiring_request = await ws.receive(timeout=5)
            expiring_payload = json.loads(expiring_request.data)
            assert expiring_payload["method"] == "secret"
            expiring_request_id = expiring_payload["id"]

            expire_seen = False
            expire_turn_end = False
            while not expire_turn_end:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                if params["type"] == "request.cancel":
                    assert params["payload"]["id"] == expiring_request_id
                    expire_seen = True
                if params["type"] == "turn.end":
                    expire_turn_end = True
            assert expire_seen

            expired_result = await rpc(
                ws,
                14,
                "request.answer",
                {
                    "id": expiring_request_id,
                    "result": {"value": "late-secret-value"},
                },
            )
            assert expired_result["status"] == "expired"

            clarify_prompt = await rpc(
                ws,
                15,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "clarify test",
                },
            )
            assert clarify_prompt["status"] == "streaming"
            clarify_message = await ws.receive(timeout=5)
            clarify_payload = json.loads(clarify_message.data)
            assert clarify_payload["method"] == "clarify"
            clarify_request = clarify_payload["params"]
            assert clarify_request["choices"] == [
                "Compact",
                "Balanced",
                "Detailed",
            ]
            assert isinstance(clarify_payload["id"], str)

            clarified = await rpc(
                ws,
                16,
                "request.answer",
                {
                    "id": clarify_payload["id"],
                    "result": {"answer": "Balanced"},
                },
            )
            assert clarified["status"] == "ok"

            clarify_delta = ""
            clarify_turn_end = False
            while not clarify_turn_end:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                if params["type"] == "message.delta":
                    clarify_delta += params["payload"]["text"]
                if params["type"] == "turn.end":
                    clarify_turn_end = True
            assert "clarification received: Balanced" in clarify_delta

            multi_prompt = await rpc(
                ws,
                17,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "clarify multi test",
                },
            )
            assert multi_prompt["status"] == "streaming"
            multi_message = await ws.receive(timeout=5)
            multi_payload = json.loads(multi_message.data)
            assert multi_payload["method"] == "clarify"
            multi_request = multi_payload["params"]
            assert multi_request["multi_select"] is True

            multi_result = await rpc(
                ws,
                18,
                "request.answer",
                {
                    "id": multi_payload["id"],
                    "result": {"answer": "Compact, Detailed"},
                },
            )
            assert multi_result["status"] == "ok"

            multi_delta = ""
            multi_turn_end = False
            while not multi_turn_end:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                if params["type"] == "message.delta":
                    multi_delta += params["payload"]["text"]
                if params["type"] == "turn.end":
                    multi_turn_end = True
            assert "Compact, Detailed" in multi_delta

            free_text_prompt = await rpc(
                ws,
                19,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "clarify free text test",
                },
            )
            assert free_text_prompt["status"] == "streaming"
            free_text_message = await ws.receive(timeout=5)
            free_text_payload = json.loads(free_text_message.data)
            assert free_text_payload["method"] == "clarify"
            free_text_request = free_text_payload["params"]
            assert "choices" not in free_text_request

            skipped = await rpc(
                ws,
                20,
                "request.answer",
                {
                    "id": free_text_payload["id"],
                    "result": {"answer": ""},
                },
            )
            assert skipped["status"] == "ok"

            skipped_delta = ""
            skipped_turn_end = False
            while not skipped_turn_end:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                if params["type"] == "message.delta":
                    skipped_delta += params["payload"]["text"]
                if params["type"] == "turn.end":
                    skipped_turn_end = True
            assert "clarification was skipped" in skipped_delta

            batch_prompt = await rpc(
                ws,
                121,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "batch clarify test",
                },
            )
            assert batch_prompt["status"] == "streaming"
            batch_message = await ws.receive(timeout=5)
            batch_payload = json.loads(batch_message.data)
            assert batch_payload["method"] == "clarify"
            batch_request = batch_payload["params"]
            assert batch_request["questions"][0]["qid"] == "q1"
            assert batch_request["questions"][1]["qid"] == "q2"
            assert "question" not in batch_request

            rejected_reply = await rpc_response(
                ws, 1219, "clarify.lock",
                {
                    "session_id": batch_request["session_id"],
                    "request_id": batch_payload["id"],
                    "question_id": "q1",
                    "answer": "Balanced",
                },
            )
            assert rejected_reply["error"]["code"] == 4000
            assert "session_id" in rejected_reply["error"]["message"]

            q1_result = await rpc(
                ws,
                122,
                "clarify.lock",
                {
                    "request_id": batch_payload["id"],
                    "question_id": "q1",
                    "answer": "Balanced",
                },
            )
            assert q1_result["status"] == "ok"
            assert q1_result["remaining"] == ["q2"]

            q2_result = await rpc(
                ws,
                123,
                "clarify.lock",
                {
                    "request_id": batch_payload["id"],
                    "question_id": "q2",
                    "answer": "Voice, Notifications",
                },
            )
            assert q2_result["status"] == "ok"
            assert q2_result["remaining"] == []

            batch_delta = ""
            batch_turn_end = False
            while not batch_turn_end:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                if params["type"] == "message.delta":
                    batch_delta += params["payload"]["text"]
                if params["type"] == "turn.end":
                    batch_turn_end = True
            assert "batch clarification received: Balanced" in batch_delta
            assert "Voice, Notifications" in batch_delta

            late_clarify = await rpc(
                ws,
                21,
                "request.answer",
                {
                    "id": "clarify-expired",
                    "result": {"answer": "Late answer"},
                },
            )
            assert late_clarify["status"] == "expired"

            activity_prompt = await rpc(
                ws,
                22,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "activity test",
                },
            )
            assert activity_prompt["status"] == "streaming"
            activity_events: list[dict] = []
            activity_delta = ""
            activity_turn_end = False
            while not activity_turn_end:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                activity_events.append(params)
                if params["type"] == "message.delta":
                    activity_delta += params["payload"]["text"]
                if params["type"] == "turn.end":
                    activity_turn_end = True

            activity_types = [event["type"] for event in activity_events]
            assert activity_types[:5] == [
                "status.update",
                "thinking.delta",
                "tool.start",
                "tool.progress",
                "tool.complete",
            ]
            tool_start = activity_events[2]["payload"]
            tool_progress = activity_events[3]["payload"]
            tool_complete = activity_events[4]["payload"]
            assert tool_start["tool_id"].startswith("tool-")
            assert tool_start["name"] == "search_files"
            assert tool_progress == {
                "name": "search_files",
                "preview": "Scanning gateway event handlers",
            }
            assert tool_complete["tool_id"] == tool_start["tool_id"]
            assert tool_complete["summary"] == (
                "Found the official activity contract"
            )
            assert "tool activity completed" in activity_delta

            reasoning_prompt = await rpc(
                ws,
                23,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "reasoning interim test",
                },
            )
            assert reasoning_prompt["status"] == "streaming"
            reasoning_events: list[dict] = []
            reasoning_turn_end = False
            delayed_types: set[str] = set()
            while not (
                reasoning_turn_end
                and delayed_types
                == {"background.complete", "review.summary"}
            ):
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                params = payload["params"]
                reasoning_events.append(params)
                if params["type"] == "turn.end":
                    reasoning_turn_end = True
                if reasoning_turn_end and params["type"] in {
                    "background.complete",
                    "review.summary",
                }:
                    delayed_types.add(params["type"])

            reasoning_types = [event["type"] for event in reasoning_events]
            assert reasoning_types[:5] == [
                "reasoning.delta",
                "reasoning.available",
                "message.delta",
                "message.interim",
                "message.delta",
            ]
            interim_payload = reasoning_events[3]["payload"]
            assert interim_payload["already_streamed"] is True
            assert interim_payload["text"].startswith("Interim result:")
            assert reasoning_types.index("background.complete") > (
                reasoning_types.index("turn.end")
            )
            assert reasoning_types.index("review.summary") > (
                reasoning_types.index("turn.end")
            )

            notification_prompt = await rpc(
                ws,
                24,
                "prompt.submit",
                {
                    "session_id": session_id,
                    "text": "notification subagent test",
                },
            )
            assert notification_prompt["status"] == "streaming"
            notification_types: list[str] = []
            notification_turn_end = False
            while not notification_turn_end:
                message = await ws.receive(timeout=5)
                assert message.type == WSMsgType.TEXT, message
                payload = json.loads(message.data)
                if payload.get("method") != "event":
                    continue
                event_type = payload["params"]["type"]
                notification_types.append(event_type)
                if event_type == "turn.end":
                    notification_turn_end = True
            assert notification_types[:4] == [
                "notification.show",
                "subagent.start",
                "subagent.complete",
                "notification.clear",
            ]

        for index, (scenario, expected_ack, expected_deltas) in enumerate(
            DISCONNECT_CASES
        ):
            await probe_disconnect_scenario(
                session,
                base_url,
                scenario,
                expected_ack,
                expected_deltas,
                200 + index * 10,
            )

        async with session.get(
            f"{base_url}/test/disconnect-ledger"
        ) as response:
            assert response.status == 200
            ledger = await response.json()

        assert ledger == {
            "schema": "hermes.fake_gateway.disconnect_ledger.v1",
            "scenarios": {
                scenario: {
                    "prompt_submit_count": 1,
                    "disconnect_point": scenario,
                    "ack_seen": expected_ack,
                    "delta_count": expected_deltas,
                    "turn_end_count": 0,
                    "resubmit_count": 0,
                }
                for scenario, expected_ack, expected_deltas in DISCONNECT_CASES
            },
        }
        ledger_json = json.dumps(ledger)
        assert "Synthetic disconnect contract probe" not in ledger_json
        assert "test-key" not in ledger_json

        async with session.post(
            f"{base_url}/test/disconnect-ledger/reset"
        ) as response:
            assert response.status == 200
            cleared_ledger = await response.json()
        assert all(
            record == {
                "prompt_submit_count": 0,
                "disconnect_point": scenario,
                "ack_seen": False,
                "delta_count": 0,
                "turn_end_count": 0,
                "resubmit_count": 0,
            }
            for scenario, record in cleared_ledger["scenarios"].items()
        )


    print(
        json.dumps(
            {
                "status": "ok",
                "contracts": [
                    "dashboard-token",
                    "profile-default-model",
                    "ws-ticket",
                    "session.create",
                    "session.resume",
                    "session.title",
                    "session.branch",
                    "config.set",
                    "config.get",
                    "file.attach",
                    "prompt.submit",
                    "message.delta",
                    "turn.end",
                    "session.interrupt",
                    "approval.request",
                    "approval.respond",
                    "sudo",
                    "secret",
                    "request.cancel",
                    "clarify",
                    "request.answer",
                    "clarify.lock",
                    "status.update",
                    "thinking.delta",
                    "tool.start",
                    "tool.progress",
                    "tool.complete",
                    "reasoning.delta",
                    "reasoning.available",
                    "message.interim",
                    "background.complete",
                    "review.summary",
                    "notification.show",
                    "notification.clear",
                    "subagent.start",
                    "subagent.complete",
                    "disconnect.before_ack",
                    "disconnect.after_ack_before_first_delta",
                    "disconnect.mid_stream_after_2_deltas",
                    "disconnect-ledger-v1",
                ],
            }
        )
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:18642")
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    asyncio.run(probe(arguments.url.rstrip("/")))
