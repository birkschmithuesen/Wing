import 'package:flutter_test/flutter_test.dart';
import 'package:wing/core/models/gateway_activity.dart';
import 'package:wing/core/services/chat_runtime.dart';

void main() {
  test('authoritative idle and resume snapshots retire ephemeral progress', () {
    for (final resume in [false, true]) {
      final runtime = ChatRuntime(runtimeId: 'progress');
      runtime.beginTurn(submitting: false);
      runtime.observeTool('tool.start', {
        'tool_id': 'call',
        'name': 'mcp_search',
      });
      runtime.observeTool('tool.progress', {
        'tool_id': 'call',
        'name': 'mcp_search',
        'progress': 1,
      });
      expect(runtime.observation.toolActivities.single.progress, isNotNull);
      if (resume) {
        runtime.installResume({
          'session_id': 'progress',
          'running': false,
          'messages': [],
          'open_requests': [],
        });
      } else {
        runtime.observeExecutionSnapshot({'running': false});
      }
      expect(runtime.observation.toolActivities.single.progress, isNull);
    }
  });
  test('MCP progress is exact, transient and cannot revive or create work', () {
    final runtime = ChatRuntime(runtimeId: 'progress');
    runtime.beginTurn(submitting: false);
    for (final id in ['one', 'two']) {
      runtime.observeTool('tool.start', {'tool_id': id, 'name': 'mcp_search'});
    }
    Map<String, dynamic> progress(String id) => {
      'tool_id': id,
      'name': 'mcp_search',
      'progress': 4.0,
      'total': 10.0,
      'percent': 40,
      'message': 'Indexed four folders',
    };
    runtime.observeTool('tool.progress', progress('missing'));
    expect(runtime.observation.toolActivities, hasLength(2));
    runtime.observeTool('tool.progress', progress('one'));
    expect(
      runtime.observation.toolActivities.first.progress?.label,
      '40% · Indexed four folders',
    );
    expect(runtime.observation.toolActivities.last.progress, isNull);
    runtime.observeTool('tool.complete', {
      'tool_id': 'one',
      'name': 'mcp_search',
    });
    runtime.observeTool('tool.progress', progress('one'));
    expect(runtime.observation.toolActivities.first.progress, isNull);
    expect(runtime.observation.toolActivities.first.isTerminal, isTrue);
    runtime.observeTool('tool.progress', progress('two'), live: false);
    expect(runtime.observation.toolActivities.last.progress, isNull);
    runtime.observeTool('tool.progress', progress('two'));
    runtime.beginRecovery();
    expect(runtime.observation.toolActivities.last.progress, isNull);
    runtime.recovered();
    runtime.observeTool('tool.progress', progress('two'));
    runtime.completeTurn(failed: true, cancelled: false, error: 'Disconnected');
    runtime.observeTool('tool.progress', progress('two'));
    expect(runtime.observation.toolActivities.last.progress, isNull);
  });

  test(
    'MCP progress rejects malformed values without manufacturing a percentage',
    () {
      expect(GatewayToolProgress.parse({'progress': double.nan}), isNull);
      expect(GatewayToolProgress.parse({'progress': -1}), isNull);
      final progress = GatewayToolProgress.parse({
        'progress': 4,
        'total': 0,
        'percent': 101,
        'message': 'Still working',
      })!;
      expect(progress.label, '4 · Still working');
      expect(progress.percent, isNull);
    },
  );
  group('GatewayToolActivity', () {
    test('parses the official tool.start contract', () {
      final activity = GatewayToolActivity.fromGatewayEvent('tool.start', {
        'tool_id': 'tool-1',
        'name': 'search_files',
        'context': 'Wing workspace',
        'args_text': '{"query":"not rendered"}',
      });

      expect(activity, isNotNull);
      expect(activity!.toolId, 'tool-1');
      expect(activity.name, 'search_files');
      expect(activity.displayName, 'Search files');
      expect(activity.phase, GatewayToolActivityPhase.running);
      expect(activity.detail, 'Wing workspace');
    });

    test('parses a successful official tool.complete', () {
      final activity = GatewayToolActivity.fromGatewayEvent('tool.complete', {
        'tool_id': 'tool-1',
        'name': 'search_files',
        'summary': 'Found the official activity contract',
        'duration_s': 0.42,
        'result_text': 'Large result is intentionally not surfaced',
      });

      expect(activity!.phase, GatewayToolActivityPhase.completed);
      expect(activity.detail, 'Found the official activity contract');
      expect(activity.statusLabel, 'Completed in 420 ms');
      expect(activity.result, 'Large result is intentionally not surfaced');
    });

    test('preserves full delivered arguments and result payloads', () {
      final activity = GatewayToolActivity.fromGatewayEvent('tool.complete', {
        'tool_id': 'tool-1',
        'name': 'read_file',
        'args': {'path': '/tmp/file'},
        'result': 'x' * 13000,
      })!;

      expect(activity.arguments, '{"path":"/tmp/file"}');
      expect(activity.result, hasLength(13000));
      expect(activity.result, 'x' * 13000);
    });

    test('preserves a tool error inside the canonical result', () {
      final activity = GatewayToolActivity.fromGatewayEvent('tool.complete', {
        'tool_id': 'tool-2',
        'name': 'terminal',
        'result': {'error': 'Synthetic command failed'},
        'summary': 'Call finished',
      });

      expect(activity!.phase, GatewayToolActivityPhase.completed);
      expect(activity.detail, 'Call finished');
      expect(activity.result, '{"error":"Synthetic command failed"}');
      expect(activity.statusLabel, 'Completed');
    });

    test('preserves boolean error markers inside canonical results', () {
      final activity = GatewayToolActivity.fromGatewayEvent('tool.complete', {
        'tool_id': 'tool-2',
        'name': 'browser',
        'result': {'error': true},
      })!;

      expect(activity.phase, GatewayToolActivityPhase.completed);
      expect(activity.result, '{"error":true}');
    });

    test('merges official completion into the start state', () {
      final start = GatewayToolActivity.fromGatewayEvent('tool.start', {
        'tool_id': 'tool-1',
        'name': 'search_files',
        'context': 'Initial context',
      })!;
      final completion = GatewayToolActivity.fromGatewayEvent('tool.complete', {
        'tool_id': 'tool-1',
        'name': 'search_files',
        'summary': 'Found the result',
      })!;

      final merged = start.merge(completion);
      expect(merged.toolId, 'tool-1');
      expect(merged.phase, GatewayToolActivityPhase.completed);
      expect(merged.detail, 'Found the result');
    });
  });
}
