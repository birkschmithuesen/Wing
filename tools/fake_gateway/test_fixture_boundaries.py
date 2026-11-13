"""Self-contained transport checks; every case owns a fresh loopback server.

These establish fixture behavior, not conformance to a deployed Hermes revision.
"""
import asyncio
import unittest

from aiohttp import ClientSession, WSServerHandshakeError
from aiohttp.test_utils import TestServer
from tools.fake_gateway.fake_gateway import GatewayState, create_app
from tools.fake_gateway.test_fake_gateway import probe, probe_disconnect_scenario


class FixtureTransport(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.state = GatewayState('test-key', None)
        self.server = TestServer(create_app(self.state))
        await self.server.start_server()
        self.addAsyncCleanup(self.server.close)
        self.url = str(self.server.make_url('')).rstrip('/')
        self.client = ClientSession()
        self.addAsyncCleanup(self.client.close)

    async def test_password_login_rejects_invalid_credentials(self):
        async with self.client.post(self.url + '/auth/password-login', json={
                'provider': 'basic', 'username': 'fixture', 'password': 'wrong'}) as response:
            self.assertEqual(response.status, 401)
            self.assertNotIn('hermes_session_at', response.cookies)

    async def test_password_login_issues_http_only_session_cookie(self):
        async with self.client.post(self.url + '/auth/password-login', json={
                'provider': 'basic', 'username': 'fixture', 'password': 'fixture'}) as response:
            self.assertEqual(response.status, 200)
            self.assertTrue(response.cookies['hermes_session_at']['httponly'])

    async def test_ticket_request_requires_dashboard_authentication(self):
        async with self.client.post(self.url + '/api/auth/ws-ticket') as response:
            self.assertEqual(response.status, 401)
        self.assertEqual(self.state.ws_tickets, set())

    async def test_websocket_ticket_is_single_use(self):
        async with self.client.post(self.url + '/api/auth/ws-ticket', headers={
                'X-Hermes-Session-Token': 'fixture-dashboard-token'}) as response:
            self.assertEqual(response.status, 200)
            ticket = (await response.json())['ticket']
        url = self.url.replace('http:', 'ws:') + '/api/ws?ticket=' + ticket
        async with self.client.ws_connect(url):
            with self.assertRaises(WSServerHandshakeError) as rejected:
                await self.client.ws_connect(url)
            self.assertEqual(rejected.exception.status, 401)

    async def test_disconnect_before_ack_preserves_uncertain_delivery(self):
        await probe_disconnect_scenario(self.client, self.url, 'before_ack', False, 0, 200)

    async def test_disconnect_after_ack_has_no_fabricated_completion(self):
        await probe_disconnect_scenario(self.client, self.url, 'after_ack_before_first_delta', True, 0, 200)

    async def test_disconnect_midstream_has_no_fabricated_completion(self):
        await probe_disconnect_scenario(self.client, self.url, 'mid_stream_after_2_deltas', True, 2, 200)

    async def test_protocol_session_lifecycle(self):
        # Existing broad transport journey is now discovered and runs against
        # fresh state, rather than requiring an externally prestarted fixture.
        async with asyncio.timeout(90):
            await probe(self.url)


if __name__ == '__main__':
    unittest.main()
