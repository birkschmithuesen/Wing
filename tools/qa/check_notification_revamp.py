#!/usr/bin/env python3
"""Native smoke test for notification_revamp_device.dart, isolated emulator only."""
# Optimization would remove the verdict assertions below.
if not __debug__:
    raise RuntimeError("Native acceptance requires Python assertions; remove -O/PYTHONOPTIMIZE")

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

PACKAGE = 'com.tarkilhk.wing.notificationqa'
LOCAL_PORT = 18766
SERIAL = 'emulator-5556'
_fixture_http = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def adb(*args):
    return subprocess.check_output([str(Path(os.environ['ANDROID_HOME']) / 'platform-tools/adb'),
                                   '-s', SERIAL, *args], text=True, timeout=25)


def state(path='/', data=None):
    request = urllib.request.Request(f'http://127.0.0.1:{LOCAL_PORT}' + path,
        data=None if data is None else json.dumps(data).encode(),
        headers={'Content-Type': 'application/json'})
    return json.load(_fixture_http.open(request, timeout=5))


def until(check, message, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, ValueError):
            pass
        time.sleep(.3)
    raise AssertionError(message)


def nodes():
    captured = adb('shell', 'uiautomator', 'dump', '/sdcard/wing-notification-ui.xml')
    if 'dumped to:' not in captured:
        raise ValueError('Android UI hierarchy is unavailable; discard the previous capture')
    return list(ET.fromstring(adb('shell', 'cat', '/sdcard/wing-notification-ui.xml')).iter('node'))


def notification_card(shown, title, *, headerless_owner=False):
    """Identify one current System UI conversation card, never adjacent text."""
    cards = []
    for node in shown:
        if node.get('resource-id') != 'com.android.systemui:id/expandableNotificationRow':
            continue
        children = list(node.iter('node'))
        labels = [child.get('text') for child in children
                  if child.get('resource-id') == 'android:id/app_name_text']
        owned = labels == ['Wing Dev'] or (not labels and headerless_owner)
        if (owned and any(child.get('resource-id') in {'android:id/title', 'android:id/conversation_text'}
                          and child.get('text') == title for child in children)):
            cards.append(node)
    assert len(cards) <= 1, f'More than one native notification for {title!r}'
    return cards[0] if cards else None



def notification_title_owned(dump, title):
    """Bind a headerless Android conversation card to one active owned slot."""
    active = re.search(r'^  Notification List:\n(.*?)(?=^  \S|\Z)',
                       dump, re.MULTILINE | re.DOTALL)
    if active is None:
        return False
    owners = []
    for block in re.split(r'(?=NotificationRecord\()', active.group(1)):
        if not block.startswith('NotificationRecord('):
            continue
        titles = re.findall(r'android\.conversationTitle=String \((.*?)\)\n', block)
        if title not in titles:
            continue
        owner = re.search(r'\bpkg=(\S+)', block.splitlines()[0])
        owners.append(owner.group(1) if owner else None)
    return owners == [PACKAGE]


def notification_text_matches(card, required=(), forbidden=()):
    # Include accessibility labels: a private preview must not leak there either.
    text = ' '.join(' '.join(node.get(field, '').split())
                    for node in card.iter('node') for field in ('text', 'content-desc'))
    return (all(re.search(r'(?<!\w)' + re.escape(value) + r'(?!\w)', text)
                for value in required)
            and not any(value.casefold() in text.casefold() for value in forbidden))


def tap_notification_node(node):
    bounds = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
    assert len(bounds) == 4 and bounds[2] > bounds[0] and bounds[3] > bounds[1], \
        'Native notification target has no reachable bounds'
    adb('shell', 'input', 'tap', str((bounds[0] + bounds[2]) // 2),
        str((bounds[1] + bounds[3]) // 2))


def shown_notification(title, *, expanded, required=(), forbidden=()):
    """Observe the requested collapsed/expanded card through real Android controls."""
    shade(expand=False)
    def current_card():
        shown = nodes()
        current = notification_card(shown, title)
        if current is not None:
            return current
        # API36 collapses conversation headers without an app-name label.
        # Require a unique active Android slot owned by the QA package before
        # using that presentation; matching text elsewhere is insufficient.
        owned = notification_title_owned(
            adb('shell', 'dumpsys', 'notification', '--noredact'), title)
        return notification_card(shown, title, headerless_owner=owned)

    def located():
        current = current_card()
        return [current] if current is not None else None

    card = until(located, f'Native notification for {title!r} is not visible')[0]

    def expansion_control(current):
        controls = [node for node in current.iter('node')
                    if node.get('resource-id') == 'android:id/expand_button']
        assert len(controls) == 1, 'Notification has no unique expansion control'
        assert controls[0].get('enabled') == 'true', 'Notification expansion is disabled'
        return controls[0]

    expected = 'Collapse' if expanded else 'Expand'
    control = expansion_control(card)
    if control.get('content-desc') != expected:
        assert control.get('content-desc') == ('Expand' if expanded else 'Collapse'), \
            'Notification expansion state is unknown'
        tap_notification_node(control)

    def rendered():
        current = current_card()
        if current is None:
            return None
        if expansion_control(current).get('content-desc') != expected:
            return None
        return [current] if notification_text_matches(current, required, forbidden) else None

    return until(rendered, f'{title!r} did not show the required '
                 f'{"expanded" if expanded else "collapsed"} notification content')[0]


def tap(resource=None, text=None):
    found = next((n for n in nodes() if
        (resource is not None and n.get('resource-id') == resource) or
        (text is not None and text in (n.get('text'), n.get('content-desc')))), None)
    assert found is not None, f'Missing control: {resource or text}'
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', found.get('bounds')))
    adb('shell', 'input', 'tap', str((x1 + x2)//2), str((y1 + y2)//2))


def scroll_through_answer(answer):
    """Scroll a visible answer toward newer messages."""
    until(lambda: any(answer in (node.get('text'), node.get('content-desc'))
                      for node in nodes()), 'The exact answer is not visible')
    width, height = map(int, re.findall(r'(\d+)x(\d+)', adb('shell', 'wm', 'size'))[-1])
    adb('shell', 'input', 'swipe', str(width // 2), str(height * 2 // 3),
        str(width // 2), str(height // 3), '400')


def shade(*, expand=True):
    width, height = map(int, re.findall(r'(\d+)x(\d+)', adb('shell', 'wm', 'size'))[-1])

    launcher = adb('shell', 'cmd', 'package', 'resolve-activity', '--brief',
                   '-a', 'android.intent.action.MAIN',
                   '-c', 'android.intent.category.HOME').strip().splitlines()[-1].split('/')[0]
    if '.' not in launcher:
        raise ValueError('Android did not resolve its home launcher')

    def home_visible():
        adb('shell', 'input', 'keyevent', 'KEYCODE_BACK', 'KEYCODE_BACK', 'KEYCODE_HOME')
        return any(node.get('package') == launcher for node in nodes())

    def opened():
        # A second pull can open Quick Settings. Observe the actual launcher
        # before every attempt; sending Home does not mean System UI settled.
        until(home_visible, 'Notification panel did not close to the launcher', timeout=15)
        adb('shell', 'input', 'swipe', str(width // 2), '1', str(width // 2), str(height * 2 // 3), '400')
        time.sleep(.7)
        shown = nodes()
        return shown if any(n.get('resource-id') == 'android:id/app_name_text' for n in shown) else None

    shown = until(opened, 'Notification shade did not open')
    if not expand:
        return
    button = next((n for n in shown if n.get('resource-id') == 'android:id/expand_button'), None)
    if button is not None and button.get('content-desc') == 'Expand':
        x1, y1, x2, y2 = map(int, re.findall(r'\d+', button.get('bounds')))
        adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
        time.sleep(.5)


def screenshot(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(subprocess.check_output([
        str(Path(os.environ['ANDROID_HOME']) / 'platform-tools/adb'),
        '-s', SERIAL, 'exec-out', 'screencap', '-p']))


def check_untrusted_main_intents():
    before = state()
    notices = json.loads(before['notices'])
    notice = next(value for value in notices.values()
                  if value['inputs'] and value['inputs'][0]['focus']['kind'] == 'approval')
    rendered = json.loads(notice['rendered'])
    # Use the exact live target and revision: rejection must come from the
    # exported entry point's authorization boundary, not a stale chat lookup.
    interaction = json.dumps({
        'payload': rendered['payload'], 'choice': 'once', 'review': False,
        'chat': rendered['chat'], 'revision': rendered['revision'],
        'notification_id': rendered['id'],
    })
    pid = adb('shell', 'pidof', PACKAGE).strip()
    attempts = [
        ('--es', 'wing_notification_interaction', interaction),
        ('--es', 'wing_notification_interaction', '{'),
        ('--es', 'wing_notification_handle', '00000000-0000-0000-0000-000000000000'),
        ('--es', 'wing_notification_handle', interaction),
        ('--ei', 'wing_notification_handle', '7'),
        ('--es', 'wing_conversation_navigation', '00000000-0000-0000-0000-000000000000'),
        ('--es', 'wing_conversation_navigation', interaction),
        ('--ei', 'wing_conversation_navigation', '7'),
    ]
    for kind, extra, value in attempts:
        command = ['am', 'start', '-W', '-n', PACKAGE + '/com.tarkilhk.wing.MainActivity',
                   '-f', '0x30000000', kind, extra, value]
        # adb shell joins arguments before remote shell parsing. Quote the JSON
        # there so Android receives one complete extra with its actual spaces.
        adb('shell', shlex.join(command))
        for _ in range(3):
            time.sleep(.4)
            after = state()
            assert after['decisions'] == before['decisions'], 'Forged main intent submitted a decision'
            assert after['pending'] == before['pending'], 'Forged main intent changed pending approvals'
            assert after['selected_chat'] == before['selected_chat'], 'Forged main intent navigated to a chat'
        assert adb('shell', 'pidof', PACKAGE).strip() == pid, 'Untrusted main intent crashed/restarted Wing'
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    print('PASS: exported MainActivity rejects raw, forged and wrong-type notification inputs without decisions or crashes', flush=True)


def wait_for_reply_notice(answer):
    """Observe the exact reply after the coordinator has rendered and saved it."""
    def published_notice():
        notices = json.loads(state()['notices'] or '{}')
        return next((value for key, value in notices.items()
                     if json.loads(key).get('profile') == 'a'
                     and isinstance(value.get('result'), dict)
                     and value['result'].get('content', {}).get('preview') == answer), None)
    return until(published_notice, 'Exact reply notification was not published')


def check_content_tap_clear():
    """A body tap must clear Android's slot before history/network settlement."""
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    until(lambda: state()['lifecycle'] == 'paused', 'Fixture did not enter the background')
    answer = 'Read this notification while history is held.'
    state('/reply', {'text': answer})
    notice = wait_for_reply_notice(answer)
    notification_id = json.loads(notice['rendered'])['id']
    state('/hold-history', {})
    try:
        shade()
        tap(text=answer)
        until(lambda: state()['history_held'], 'Tap did not start the captured chat history')
        assert state()['read_guards']['selected_is_target'], 'Tap opened a different chat'
        raw = adb('shell', 'dumpsys', 'notification', '--noredact')
        assert not any(f'pkg={PACKAGE} ' in line and f'id={notification_id} ' in line
                       for line in raw.splitlines() if 'NotificationRecord(' in line), \
            'Body tap left its notification in the shade while history was loading'
    finally:
        state('/release-history', {})
    def answer_visible():
        current = state()
        return (current['lifecycle'] == 'resumed' and current['chat_visible']
                and any(answer in (node.get('text'), node.get('content-desc')) for node in nodes()))
    until(answer_visible, 'Tapped chat answer is not visible after history completes')
    print('PASS: body tap opens the captured chat and clears the shade before history completes', flush=True)


def check_group_body_taps(output):
    """Tap what the shade actually displays, without expanding an OS summary."""
    component = PACKAGE + '/com.tarkilhk.wing.MainActivity'
    answer = 'The shared discussion reached its exact destination.'
    for kind, cold in (('answer', False), ('approval', False), ('answer', True)):
        adb('shell', 'am', 'start', '-W', '-n', component)
        state('/list', {})
        adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        until(lambda: state()['lifecycle'] == 'paused', 'Fixture did not pause')
        # Multiple conversations expose Android's automatic summary. Expanding
        # that summary first bypasses the broken default tap target.
        state('/reply', {'text': 'An independent chat also needs attention.'})
        state('/stop', {})
        current = state('/native-group-' + kind, {'long': False})
        notification_id = current['group_notification_id']
        if cold:
            pid = adb('shell', 'pidof', PACKAGE).strip()
            adb('shell', 'run-as', PACKAGE, 'kill', '-9', pid)
            until(lambda: not adb('shell', f'pidof {PACKAGE} || true').strip(),
                  'Fixture did not stop')
        shade(expand=False)
        stage = f'group-{kind}-{"cold" if cold else "warm"}'
        screenshot(output / (stage + '-shade.png'))
        tap(text='Research team' if kind == 'answer' else 'Native group approval')
        until(lambda: any(answer in (node.get('text'), node.get('content-desc'))
                          for node in nodes()),
              f'NATIVE_GROUP_BODY_TAP: {stage} did not open the captured discussion')
        raw = adb('shell', 'dumpsys', 'notification', '--noredact')
        assert not any(f'pkg={PACKAGE} ' in line and f'id={notification_id} ' in line
                       for line in raw.splitlines() if 'NotificationRecord(' in line), \
            f'NATIVE_GROUP_BODY_TAP: {stage} left the tapped notification visible'
        assert not state()['decisions'], 'Group body tap submitted an approval'
        screenshot(output / (stage + '-discussion.png'))
        print(f'PASS: {stage} default-shade tap opens the exact shared discussion and clears its alert', flush=True)


def check_many_conversation_alerts(output):
    state('/list', {})
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    for index in range(8):
        state('/native-group-answer', {'room': f'other-room-{index}', 'title': f'Other group {index}'})
    state('/native-group-answer', {})
    # Let Android's delayed forced-grouping pass run before tapping.
    time.sleep(10)
    raw = adb('shell', 'dumpsys', 'notification', '--noredact')
    records = [line for line in raw.splitlines() if 'NotificationRecord(' in line and f'pkg={PACKAGE} ' in line]
    assert not any('AUTOGROUP_SUMMARY' in line for line in records), \
        'NATIVE_CONVERSATION_GROUPING: Android replaced conversation taps with an automatic summary'
    shade(expand=False)
    screenshot(output / 'many-conversations-shade.png')
    tap(text='Research team')
    until(lambda: any('The shared discussion reached its exact destination.'
                     in (n.get('text'), n.get('content-desc')) for n in nodes()),
          'NATIVE_CONVERSATION_GROUPING: default tap opened the wrong conversation')
    print('PASS: nine conversation alerts retain their own targets after Android grouping settles', flush=True)


def check_cold_chat_body_tap(output):
    state('/list', {})
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    answer = 'This exact individual answer must survive cold startup.'
    state('/reply', {'text': answer})
    wait_for_reply_notice(answer)
    pid = adb('shell', 'pidof', PACKAGE).strip()
    adb('shell', 'run-as', PACKAGE, 'kill', '-9', pid)
    until(lambda: not adb('shell', f'pidof {PACKAGE} || true').strip(),
          'Fixture did not stop for individual cold tap')
    shade(expand=False)
    tap(text=answer)
    until(lambda: state()['selected_profile'] == 'a'
          and any(answer in (n.get('text'), n.get('content-desc')) for n in nodes()),
          'NATIVE_COLD_CHAT_TAP: remembered workspace displaced the captured chat')
    screenshot(output / 'individual-cold-chat.png')
    print('PASS: cold individual tap opens its exact answer above remembered workspace startup', flush=True)


def notification_actions(shown):
    return {node.get('text', '').casefold() for node in shown
            if node.get('resource-id') == 'android:id/action0'}


def assert_group_approval_controls(shown, review):
    visible = notification_actions(shown)
    expected = {'review', 'deny'} if review else {'once', 'deny'}
    assert visible == expected, f'NATIVE_GROUP_APPROVAL_RENDER: expected {expected}, found {visible}'


def check_group_approval_rendering(output):
    """Unsupported hidden buttons must not prevent a group alert being posted."""
    component = PACKAGE + '/com.tarkilhk.wing.MainActivity'
    for review in (False, True):
        try:
            adb('shell', 'am', 'start', '-W', '-n', component)
            try:
                state('/native-group-approval', {'long': review})
            except urllib.error.HTTPError as error:
                raise AssertionError('NATIVE_GROUP_APPROVAL_RENDER: Android rejected the group alert: '
                                     + error.read().decode(errors='replace')) from error
            shade()
            shown = nodes()
            # Android may collapse a new card when another chat already has an
            # alert. Expand this exact group card before asserting its controls.
            cards = [node for node in shown
                     if any(child.get('text') == 'Native group approval' for child in node.iter('node'))
                     and any(child.get('resource-id') == 'android:id/expand_button' for child in node.iter('node'))]
            if cards:
                card = min(cards, key=lambda node: len(list(node.iter('node'))))
                button = next(child for child in card.iter('node')
                              if child.get('resource-id') == 'android:id/expand_button')
                if button.get('content-desc', '').lower().startswith('expand'):
                    x1, y1, x2, y2 = map(int, re.findall(r'\d+', button.get('bounds')))
                    adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
                    time.sleep(.5)
                    shown = nodes()
            output.mkdir(parents=True, exist_ok=True)
            (output / ('group-review-ui.txt' if review else 'group-once-ui.txt')).write_text(
                '\n'.join(ET.tostring(node, encoding='unicode') for node in shown[:1]))
            screenshot(output / ('group-review.png' if review else 'group-once.png'))
            assert_group_approval_controls(shown, review)
        finally:
            # Android may freeze a cached app behind the shade. Wake the QA
            # control server before asking it to clean up its synthetic alert.
            adb('shell', 'am', 'start', '-W', '-n', component)
            state('/cancel-native-group-approval', {})
    print('PASS: group approvals render only Once/Deny or Review/Deny without hidden unsupported actions', flush=True)


def reset_fixture():
    assert SERIAL.startswith('emulator-'), 'Use a disposable emulator, never a phone'
    adb('shell', 'pm', 'clear', PACKAGE)
    adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
    # This journey assumes background monitoring was enabled during onboarding.
    # Provision that prerequisite only for the disposable QA package.
    adb('shell', 'dumpsys', 'deviceidle', 'whitelist', '+' + PACKAGE)
    adb('shell', 'settings', 'put', 'system', 'font_scale', '1.0')
    adb('shell', 'cmd', 'uimode', 'night', 'no')
    adb('shell', 'am', 'start', '-n', PACKAGE + '/com.tarkilhk.wing.MainActivity')
    until(lambda: (current := state())['ready'] and current['lifecycle'] == 'resumed',
          'Fixture did not start in the foreground', timeout=120)

def monitoring_notification_posted():
    # Android can start the foreground service before publishing its deferred
    # notification. Routing requires a real posted slot, not merely a service.
    dump = adb('shell', 'dumpsys', 'notification', '--noredact')
    active = re.search(r'^  Notification List:\n(.*?)(?=^  \S|\Z)',
                       dump, re.MULTILINE | re.DOTALL)
    return active is not None and any(
        re.search(r'\bpkg=' + re.escape(PACKAGE) + r'\s', line)
        and re.search(r'\bid=214601\s+tag=null\b', line)
        and 'Notification(channel=hermes_monitoring ' in line
        for line in active.group(1).splitlines()
        if 'NotificationRecord(' in line)


def wait_for_monitoring_notification():
    until(monitoring_notification_posted,
          'QA monitoring notification was not posted before leaving Wing')


def check_monitoring_taps(output):
    reset_fixture()
    state('/list', {})
    state('/work', {})
    wait_for_monitoring_notification()
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    shade(expand=False)
    tap(text='Watching chats')
    until(lambda: state()['selected_profile'] == 'b'
          and any('b completed' in (n.get('text'), n.get('content-desc')) for n in nodes()),
          'MONITORING_TAP_TARGET: one monitored chat did not open that chat')
    screenshot(output / 'monitoring-single-chat.png')
    print('PASS: monitoring tap opens the exact single profile chat', flush=True)
    state('/list', {})
    state('/work-primary', {})
    wait_for_monitoring_notification()
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    shade(expand=False)
    tap(text='Watching chats')
    until(lambda: any('Recents' in (n.get('text'), n.get('content-desc')) for n in nodes()),
          'MONITORING_TAP_TARGET: multiple monitored chats did not open Recents')
    screenshot(output / 'monitoring-recents.png')
    print('PASS: monitoring tap with two active chats opens Recents', flush=True)
    state('/reply', {'text': 'First monitored task finished.'})
    state('/stop', {})
    state('/monitor-group', {})
    wait_for_monitoring_notification()
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    shade(expand=False)
    tap(text='Watching chats')
    until(lambda: any('The shared discussion reached its exact destination.'
                     in (n.get('text'), n.get('content-desc')) for n in nodes()),
          'MONITORING_TAP_TARGET: one monitored group did not open its discussion')
    screenshot(output / 'monitoring-single-group.png')
    state('/stop-monitor-group', {})
    print('PASS: monitoring taps open the single chat/group or Recents for multiple chats', flush=True)


def wait_for_approval_choices():
    labels = ('Approve once', 'Approve for session', 'Always approve', 'Reject')
    revealed = False

    def visible_choices():
        nonlocal revealed
        shown = nodes()
        if all(any(label in (node.get('text'), node.get('content-desc'))
                       and node.get('enabled') == 'true'
                       for node in shown) for label in labels):
            return True
        # Review opens at the command. At large text its actions can be below
        # the transcript viewport; use the same explicit jump as the reader.
        cue = next((node for node in shown if
                    'Input needed' in (node.get('text'), node.get('content-desc'))
                    and node.get('enabled') == 'true'), None)
        if cue is not None and not revealed:
            tap_notification_node(cue)
            revealed = True
        return False

    until(visible_choices, 'Review did not expose all enabled approval choices')


def run(output, tap_only=False):
    reset_fixture()
    # Keep the production work lease alive while its loopback QA control
    # server is behind the notification shade.
    state('/work', {})
    wait_for_monitoring_notification()
    if tap_only:
        check_content_tap_clear()
        check_group_approval_rendering(output)
        check_group_body_taps(output)
        check_cold_chat_body_tap(output)
        check_many_conversation_alerts(output)
        check_monitoring_taps(output)
        return
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    state('/approval', {})
    state('/approval', {'command': 'npm run release'})
    check_untrusted_main_intents()
    shade()
    screenshot(output / 'light-normal.png')
    tap(text='Once')
    until(lambda: len(state()['decisions']) == 1, 'Once did not submit')
    assert state()['decisions'][0]['params']['prompt_id'] == 'qa-1'
    assert state()['decisions'][0]['params']['execution_generation'] == 0
    assert state()['pending'][0]['request_id'] == 'qa-2'
    print('PASS: Once resolves the exact head and advances FIFO', flush=True)
    state('/fail', {'enabled': True})
    shade()
    tap(text='Once')
    until(lambda: len(state()['decisions']) == 2, 'Failure fixture did not receive attempt')
    assert state()['pending'][0]['request_id'] == 'qa-2'
    shade()
    assert any('not confirmed' in n.get('text', '') for n in nodes())
    screenshot(output / 'unconfirmed.png')
    print('PASS: failed submission retains notification and request', flush=True)
    state('/fail', {'enabled': False})
    tap(text='Review')
    wait_for_approval_choices()
    reviewed = state()
    assert len(reviewed['decisions']) == 2, 'Review submitted a decision'
    assert reviewed['pending'][0]['request_id'] == 'qa-2', 'Review changed the pending owner'
    screenshot(output / 'approval-review-choices.png')
    print('PASS: Review opens the owning request with Session/Always choices without submitting', flush=True)
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    state('/preview', {'enabled': False})
    shade()
    shown = nodes()
    assert 'once' not in notification_actions(shown)
    assert notification_actions(shown) == {'review'}
    screenshot(output / 'private-preview.png')
    print('PASS: hidden previews expose Review only', flush=True)
    state('/preview', {'enabled': True})
    for night in ('no', 'yes'):
        for scale in ('1.0', '2.0'):
            adb('shell', 'settings', 'put', 'system', 'font_scale', scale)
            adb('shell', 'cmd', 'uimode', 'night', night)
            time.sleep(.7)
            shade()
            shown = nodes()
            expected = {'review', 'deny'} if scale == '2.0' else {'once', 'review', 'deny'}
            assert notification_actions(shown) == expected
            controls = [n for n in shown if n.get('resource-id') == 'android:id/action0']
            bounds = [list(map(int, re.findall(r'\d+', n.get('bounds')))) for n in controls]
            assert all(b[3] - b[1] >= 100 for b in bounds), 'Clipped approval target'
            screenshot(output / f"{'dark' if night == 'yes' else 'light'}-{scale}.png")
    print('PASS: platform actions remain readable and reachable in both themes at 100%/200%', flush=True)
    state('/remote', {})
    until(lambda: all(not v['inputs'] for v in json.loads(state()['notices']).values()), 'Watcher did not clear remote decision')
    print('PASS: watcher reconciles a desktop decision without another notification tap', flush=True)
    check_direct_actions(output)
    check_reply_read(output)
    check_content_tap_clear()
    check_group_approval_rendering(output)
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    state('/error', {})
    shade()
    screenshot(output / 'stopped.png')
    state('/stop', {})



def check_reply_read(output):
    # A settled cold action may release its engine; restart this fake app for
    # the unrelated reply/open checks that follow.
    adb('shell', 'am', 'start', '-n', PACKAGE + '/com.tarkilhk.wing.MainActivity')
    until(lambda: state()['ready'], 'Fixture did not restart after the cold action')
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    until(lambda: state()['lifecycle'] == 'paused', 'Reply fixture did not enter the background')
    reads_before = len(state()['read_acks'])
    answer = 'The mobile layout is ready. Read the result before publishing.'
    state('/reply', {'text': answer})
    shade()
    screenshot(output / 'reply.png')
    tap(text=answer)
    until(lambda: state()['chat_visible'] and state()['read_guards']['selected_is_target'],
          'Reply tap did not open its exact owner')
    until(lambda: any(answer in (node.get('text'), node.get('content-desc'))
                      for node in nodes()), 'The exact answer is not visible')
    until(lambda: all(v['result'] is None for k, v in json.loads(state()['notices']).items() if json.loads(k)['profile'] == 'a'), 'Seeing the latest answer did not clear its notification')
    assert state()['read_acks'][reads_before:] == [{'profile': 'a', 'session': 'same'}]
    assert not state()['mark_read_failed']
    print('PASS: seeing the latest answer acknowledges its exact owner and clears the result', flush=True)


def check_direct_actions(output):
    # The layout matrix ends at enlarged text, where Once intentionally requires
    # Review. Direct-action acceptance starts in the short-command configuration.
    adb('shell', 'settings', 'put', 'system', 'font_scale', '1.0')
    adb('shell', 'cmd', 'uimode', 'night', 'no')
    time.sleep(.7)
    state('/fail', {'enabled': False})
    state('/preview', {'enabled': True})
    state('/remote', {})
    until(lambda: all(not v['inputs'] for v in json.loads(state()['notices']).values()), 'Old requests did not clear')
    for choice in ('once', 'deny'):
        before = len(state()['decisions'])
        state('/approval', {'command': 'echo ok'})
        shade()
        tap(text=choice.title())
        until(lambda: len(state()['decisions']) == before + 1, f'{choice} did not submit directly')
        assert state()['decisions'][-1]['params']['choice'] == choice
        assert not any('Review command' in (n.get('text'), n.get('content-desc')) for n in nodes())
    print('PASS: Once and Deny complete without another confirmation', flush=True)
    long_command = 'echo ' + 'long-command-argument-' * 50
    state('/approval', {'command': long_command})
    pending_request = state()['pending'][0]['request_id']
    before = len(state()['decisions'])
    for night in ('no', 'yes'):
        for scale in ('1.0', '2.0'):
            adb('shell', 'settings', 'put', 'system', 'font_scale', scale)
            adb('shell', 'cmd', 'uimode', 'night', night)
            time.sleep(.7)
            shade()
            shown = nodes()
            assert notification_actions(shown) == {'review', 'deny'}
            screenshot(output / f"truncated-{'dark' if night == 'yes' else 'light'}-{scale}.png")
    tap(text='Review')
    wait_for_approval_choices()
    reviewed = state()
    assert len(reviewed['decisions']) == before, 'Review submitted a decision'
    assert reviewed['pending'][0]['request_id'] == pending_request, 'Review changed the pending owner'
    adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    shade()
    tap(text='Deny')
    until(lambda: len(state()['decisions']) == before + 1, 'Truncated command Deny did not submit')
    assert state()['decisions'][-1]['params']['choice'] == 'deny'
    print('PASS: truncated commands expose Review and direct Deny in both themes and text sizes', flush=True)
    adb('shell', 'settings', 'put', 'system', 'font_scale', '1.0')
    adb('shell', 'cmd', 'uimode', 'night', 'no')
    check_cold_action(output)




def saved_notification_decisions():
    # A settled action releases the fake HTTP server with its engine.
    # Read the fake server's acknowledgement persisted before its RPC reply.
    try:
        raw = adb('shell', 'run-as', PACKAGE, 'cat',
                  'shared_prefs/FlutterSharedPreferences.xml')
    except subprocess.CalledProcessError:
        # SharedPreferences atomically replaces this file while persisting.
        # The bounded poll must still observe the exact acknowledgement.
        return []
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        # A successful cat can still race the atomic preferences replacement.
        # Retry the observation; only a complete exact receipt counts as an ACK.
        return []
    value = next(n.text for n in root if n.get('name') == 'flutter.notification_qa_decisions')
    return json.loads(value)


def check_cold_action(output):
    state('/approval', {'command': 'echo ok'})
    before = len(state()['decisions'])
    cold_request = state()['pending'][0]['request_id']
    adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    pid = adb('shell', 'pidof', PACKAGE).strip()
    adb('shell', 'run-as', PACKAGE, 'kill', '-9', pid)
    until(lambda: not adb('shell', f'pidof {PACKAGE} || true').strip(), 'Fixture did not stop')
    shade()
    tap(text='Once')
    def acknowledged():
        decisions = saved_notification_decisions()
        return decisions if len(decisions) == before + 1 else None
    decisions = until(acknowledged, 'Cold Once did not submit')
    assert decisions[-1]['params']['prompt_id'] == cold_request
    assert decisions[-1]['params']['execution_generation'] == 0
    until(lambda: not any(PACKAGE in line for line in adb('shell', 'dumpsys', 'activity', 'activities').splitlines()
                          if 'topResumedActivity=' in line), 'Cold action left Wing in front')
    assert not any('Review command' in (n.get('text'), n.get('content-desc')) for n in nodes())
    screenshot(output / 'cold-return.png')
    print('PASS: cold Once submits the exact request and returns to the previous screen', flush=True)


def check_recents_visibility(output):
    """Exercise real notification PendingIntents with absent and existing app tasks."""
    assert SERIAL.startswith('emulator-'), 'Use a disposable emulator, never a phone'
    assert adb('shell', 'getprop', 'ro.kernel.qemu').strip() == '1', 'Requires an emulator'
    adb('shell', 'am', 'force-stop', PACKAGE)
    adb('shell', 'pm', 'clear', PACKAGE)
    adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS')
    # This journey assumes background monitoring was enabled during onboarding.
    # Provision that prerequisite only for the disposable QA package.
    adb('shell', 'dumpsys', 'deviceidle', 'whitelist', '+' + PACKAGE)
    component = PACKAGE + '/com.tarkilhk.wing.MainActivity'
    adb('shell', 'am', 'start', '-n', component)
    until(lambda: state()['ready'], 'Notification fixture did not start')

    def main_tasks():
        dump = adb('shell', 'dumpsys', 'activity', 'recents')
        tasks = []
        for block in re.split(r'(?=  \* Recent #\d+:)', dump)[1:]:
            activity = re.search(
                r'^    Activities=\[[^\n]*' + re.escape(component) + r' t(\d+)',
                block, re.M,
            )
            if activity:
                intent = re.search(r'^    intent=\{([^\n]*)\}', block, re.M)
                assert intent, 'Missing task base intent'
                flags = re.search(r'\bflg=0x([0-9a-f]+)', intent.group(1))
                tasks.append((activity.group(1), int(flags.group(1), 16) if flags else 0))
        return tasks

    def visible_task(stage):
        tasks = main_tasks()
        assert len(tasks) == 1, f'{stage}: expected one live Wing task, found {len(tasks)}'
        task_id, flags = tasks[0]
        assert not flags & 0x00800000, (
            f'[NATIVE_NOTIFICATION_RECENTS] {stage}: Wing task {task_id} is excluded '
            f'from Android Recents (base intent flags=0x{flags:x})'
        )
        return task_id

    for missing_task in (True, False):
        stage = 'notification without an app task' if missing_task else 'notification with an app task'
        original = None if missing_task else visible_task(stage)
        adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        state('/reply', {'text': 'WING-RECENTS-REGRESSION'})
        if missing_task:
            original_tasks = main_tasks()
            assert len(original_tasks) == 1, 'Expected the original fixture task before removal'
            for task_id, _ in original_tasks:
                # Remove only this disposable fixture's task, as a Recents swipe does.
                adb('shell', 'am', 'stack', 'remove', task_id)
            assert not main_tasks(), 'Original fixture task was not removed'
        card = shown_notification('Website refresh', expanded=True,
                                  required=['WING-RECENTS-REGRESSION'])
        target = next((n for n in card.iter('node')
                       if n.get('text') == 'WING-RECENTS-REGRESSION'), None)
        assert target is not None, 'Missing native fixture reply notification'
        tap_notification_node(target)
        until(lambda: any(component in line for line in
                         adb('shell', 'dumpsys', 'activity', 'activities').splitlines()
                         if 'topResumedActivity=' in line), 'Notification did not open Wing')
        task_id = visible_task(stage)
        if original is not None:
            assert task_id == original, 'Notification replaced the existing app task'
        pid = adb('shell', 'pidof', PACKAGE).strip()
        adb('shell', 'am', 'start', '-W', '-a', 'android.settings.SETTINGS')
        assert visible_task(stage + ' after switching apps') == task_id
        assert adb('shell', 'pidof', PACKAGE).strip() == pid, 'App switch restarted Wing'
        adb('shell', 'input', 'keyevent', 'KEYCODE_APP_SWITCH')
        until(lambda: any(n.get('resource-id', '').endswith('/snapshot')
                          and n.get('content-desc', '').startswith('Wing Dev') for n in nodes()),
              'Wing card is missing from the actual Android Recents UI')
        assert visible_task(stage + ' in Recents') == task_id
        screenshot(output / ('recents-new-task.png' if missing_task else 'recents-existing-task.png'))
        adb('shell', 'am', 'start', '-W', '-n', component,
            '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.LAUNCHER')
        assert visible_task(stage + ' after launcher reentry') == task_id
        until(lambda: state()['ready'], 'Fixture did not resume')
        print(f'PASS: {stage} retains one visible task across app switch and launcher reentry', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', default=SERIAL)
    parser.add_argument('--output', type=Path, default=Path('build/notification-review'))
    parser.add_argument('--recents-only', action='store_true',
                        help='Check real notification task visibility with absent/existing app tasks')
    parser.add_argument('--tap-only', action='store_true',
                        help='Check shade dismissal with held history and native group approval rendering')
    args = parser.parse_args()
    SERIAL = args.serial
    if not SERIAL.startswith('emulator-'):
        parser.error('Use a disposable emulator, never a phone')
    LOCAL_PORT = int(adb('forward', 'tcp:0', 'tcp:18766').strip())
    try:
        if args.recents_only:
            check_recents_visibility(args.output)
        else:
            run(args.output, tap_only=args.tap_only)
            if not args.tap_only:
                check_recents_visibility(args.output)
    finally:
        try:
            adb('shell', 'settings', 'put', 'system', 'font_scale', '1.0')
            adb('shell', 'cmd', 'uimode', 'night', 'no')
        finally:
            adb('forward', '--remove', f'tcp:{LOCAL_PORT}')
