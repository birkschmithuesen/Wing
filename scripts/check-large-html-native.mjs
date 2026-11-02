// Node 22: connect only to the explicitly forwarded Android WebView page.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';

const pageUrl = 'https://wing-diagrams.invalid/index.html';
const reportUrl = 'https://wing-diagrams.invalid/report.html';
const requestTimeout = 10000;
const serial = process.env.WING_ADB_SERIAL;
assert.match(serial ?? '', /^emulator-\d+$/,
  'Set WING_ADB_SERIAL to the disposable emulator, never a physical device');
const run = promisify(execFile);
async function adb(...args) {
  const { stdout } = await run('adb', ['-s', serial, ...args], {
    encoding: 'utf8', timeout: requestTimeout, killSignal: 'SIGKILL', maxBuffer: 65536,
  });
  return stdout.trim();
}
async function emulatorHttpControl(port, path) {
  const pending = run('adb', ['-s', serial, 'shell', '-T', 'toybox', 'nc',
    '-W', '5', '-w', '5', '127.0.0.1', String(port)], {
    encoding: 'utf8', timeout: requestTimeout, killSignal: 'SIGKILL', maxBuffer: 65536,
  });
  let inputError;
  pending.child.stdin.on('error', error => { inputError = error; });
  try {
    // Keep stdin open: Android toybox nc can exit before sending buffered data
    // when a finite printf pipe closes. The server closes its complete response;
    // nc's idle/connect limits and the ADB process timeout bound failures.
    pending.child.stdin.write(
      `GET ${path} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: close\r\n\r\n`);
    const { stdout } = await pending;
    if (inputError) throw inputError;
    return stdout.trim();
  } finally {
    pending.child.stdin.destroy();
  }
}
const endpoint = process.env.WING_CDP_ENDPOINT;
assert.ok(endpoint, 'Set WING_CDP_ENDPOINT to the forwarded WebView HTTP endpoint');
const endpointUrl = new URL(endpoint);
assert.equal(endpointUrl.protocol, 'http:', 'Use the local ADB HTTP forward');
assert.ok(['127.0.0.1', 'localhost', '[::1]'].includes(endpointUrl.hostname),
  'The WebView endpoint must be a local ADB forward');
assert.equal(await adb('shell', 'getprop', 'ro.kernel.qemu'), '1',
  'The selected device must be an emulator');
const forward = `tcp:${endpointUrl.port || '80'}`;
assert.ok((await adb('forward', '--list')).split('\n').some(line => {
  const [device, local, remote] = line.trim().split(/\s+/);
  return device === serial && local === forward &&
    remote?.startsWith('localabstract:webview_devtools_remote_');
}), 'The WebView forward must belong to the same selected emulator');

async function selectPage() {
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    const response = await fetch(new URL('/json/list', endpointUrl), {
      signal: AbortSignal.timeout(requestTimeout),
    });
    assert.ok(response.ok, `WebView target discovery returned HTTP ${response.status}`);
    const pages = (await response.json()).filter(target =>
      target.type === 'page' && target.url === pageUrl);
    assert.ok(pages.length <= 1, 'The native fixture must have exactly one matching page');
    if (pages.length === 1) return pages[0];
    await delay(200);
  }
  throw new Error('Native Wing viewer did not open within 60 seconds');
}

// Page-level CDP avoids browser-context commands unsupported by Android WebView.
class PageConnection {
  #socket;
  #nextId = 1;
  #pending = new Map();
  contexts = new Map();

  constructor(socket) {
    this.#socket = socket;
    socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.method === 'Runtime.executionContextCreated') {
        const context = message.params.context;
        this.contexts.set(context.id, context);
      } else if (message.method === 'Runtime.executionContextDestroyed') {
        this.contexts.delete(message.params.executionContextId);
      } else if (message.method === 'Runtime.executionContextsCleared') {
        this.contexts.clear();
      }
      const pending = this.#pending.get(message.id);
      if (!pending) return;
      this.#pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(new Error(`${pending.method}: ${message.error.message}`));
      } else {
        pending.resolve(message.result);
      }
    });
    socket.addEventListener('close', () => this.#rejectPending('WebView connection closed'));
    socket.addEventListener('error', () => this.#rejectPending('WebView connection failed'));
  }

  #rejectPending(reason) {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error(reason));
    }
    this.#pending.clear();
  }

  static async connect(url) {
    const socket = new WebSocket(url);
    const connection = new PageConnection(socket);
    await new Promise((resolveOpen, rejectOpen) => {
      const timer = setTimeout(() => {
        socket.close();
        rejectOpen(new Error('WebView WebSocket connection timed out'));
      }, requestTimeout);
      socket.addEventListener('open', () => {
        clearTimeout(timer);
        resolveOpen();
      }, { once: true });
      socket.addEventListener('error', () => {
        clearTimeout(timer);
        rejectOpen(new Error('Cannot connect to the forwarded WebView page'));
      }, { once: true });
    });
    return connection;
  }

  request(method, params = {}) {
    const id = this.#nextId++;
    return new Promise((resolveRequest, rejectRequest) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        rejectRequest(new Error(`${method} timed out after ${requestTimeout} ms`));
      }, requestTimeout);
      this.#pending.set(id, {
        method, timer, resolve: resolveRequest, reject: rejectRequest,
      });
      try {
        this.#socket.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        clearTimeout(timer);
        this.#pending.delete(id);
        rejectRequest(error);
      }
    });
  }

  async evaluate(contextId, expression) {
    const result = await this.request('Runtime.evaluate', {
      contextId, expression, awaitPromise: true, returnByValue: true, timeout: requestTimeout,
    });
    assert.equal(result.exceptionDetails, undefined,
      `WebView evaluation failed: ${JSON.stringify(result.exceptionDetails)}`);
    return result.result.value;
  }

  close() {
    this.#rejectPending('Native acceptance finished');
    this.#socket.close();
  }
}

async function checkExternalHttpIsolation(connection, reportContext) {
  const token = randomUUID();
  const controlPath = `/${token}/control`;
  const fetchPath = `/${token}/fetch`;
  const imagePath = `/${token}/image`;
  const paths = new Set([controlPath, fetchPath, imagePath]);
  const hits = [];
  const controlBody = `wing-emulator-http-control-${token}`;
  const server = createServer((request, response) => {
    if (!paths.has(request.url)) {
      response.writeHead(404, { Connection: 'close' }).end();
      return;
    }
    hits.push({ method: request.method, path: request.url });
    response.setHeader('Connection', 'close');
    response.setHeader('Access-Control-Allow-Origin', '*');
    if (request.url === imagePath) {
      response.setHeader('Content-Type', 'image/png');
      response.end(Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aT1sAAAAASUVORK5CYII=',
        'base64'));
    } else {
      response.setHeader('Content-Type', 'text/plain');
      response.setHeader('Content-Length', Buffer.byteLength(controlBody));
      response.end(controlBody);
    }
  });
  server.headersTimeout = requestTimeout;
  server.requestTimeout = requestTimeout;
  server.keepAliveTimeout = 1000;
  // Close even incomplete clients without retaining sockets after a failed probe.
  server.on('connection', socket => socket.setTimeout(requestTimeout, () => socket.destroy()));
  let reverse;
  let ownsReverse = false;
  try {
    await new Promise((resolveListen, rejectListen) => {
      server.once('error', rejectListen);
      server.listen(0, '127.0.0.1', resolveListen);
    });
    const port = server.address().port;
    reverse = `tcp:${port}`;
    assert.ok(!(await adb('reverse', '--list')).split('\n').some(line =>
      line.trim().split(/\s+/).includes(reverse)),
    'The temporary emulator HTTP probe port must be unused');
    await adb('reverse', '--no-rebind', reverse, reverse);
    ownsReverse = true;
    const control = await emulatorHttpControl(port, controlPath);
    assert.ok(control.startsWith('HTTP/1.1 200 '),
      'The same emulator must receive the local HTTP positive control');
    assert.ok(control.endsWith(controlBody), 'The emulator must receive the complete control body');
    assert.deepEqual(hits, [{ method: 'GET', path: controlPath }],
      'The local probe must record exactly one emulator control request');

    const fetchUrl = `http://127.0.0.1:${port}${fetchPath}`;
    const imageUrl = `http://127.0.0.1:${port}${imagePath}`;
    const probeOrigin = new URL(fetchUrl).origin;
    // Use the report's existing default execution context: no isolated world,
    // granted origin access, CSP bypass, or parent-page network permissions.
    const outcomes = await connection.evaluate(reportContext, `(async () => {
      const fetchUrl = ${JSON.stringify(fetchUrl)};
      const imageUrl = ${JSON.stringify(imageUrl)};
      const probeOrigin = ${JSON.stringify(probeOrigin)};
      const violations = [];
      const recordViolation = event => {
        // CSP may redact a cross-origin blocked URI to its origin.
        if ([fetchUrl, imageUrl, probeOrigin].includes(event.blockedURI)) {
          violations.push({ directive: event.effectiveDirective,
            blockedURI: event.blockedURI, disposition: event.disposition });
        }
      };
      document.addEventListener('securitypolicyviolation', recordViolation);
      const controller = new AbortController();
      const image = new Image();
      let fetchTimer;
      let imageTimer;
      try {
        const fetchOutcome = new Promise(resolveOutcome => {
          fetchTimer = setTimeout(() => {
            resolveOutcome('timeout');
            controller.abort();
          }, 5000);
          fetch(fetchUrl, { mode: 'no-cors', signal: controller.signal }).then(
            () => resolveOutcome('resolved'), () => resolveOutcome('rejected'));
        });
        const imageOutcome = new Promise(resolveOutcome => {
          imageTimer = setTimeout(() => resolveOutcome('timeout'), 5000);
          image.onload = () => resolveOutcome('loaded');
          image.onerror = () => resolveOutcome('error');
          image.src = imageUrl;
        });
        const [fetchResult, imageResult] = await Promise.all([fetchOutcome, imageOutcome]);
        await new Promise(resolveOutcome => setTimeout(resolveOutcome, 100));
        return { fetch: fetchResult, image: imageResult, violations };
      } finally {
        clearTimeout(fetchTimer);
        clearTimeout(imageTimer);
        controller.abort();
        image.onload = null;
        image.onerror = null;
        image.removeAttribute('src');
        document.removeEventListener('securitypolicyviolation', recordViolation);
      }
    })()`);
    assert.equal(outcomes.fetch, 'rejected', 'External HTTP fetch must fail without timing out');
    assert.equal(outcomes.image, 'error', 'External HTTP image must fail without timing out');
    for (const [directive, blockedURI] of [['connect-src', fetchUrl], ['img-src', imageUrl]]) {
      assert.ok(outcomes.violations.some(violation => violation.directive === directive &&
        [blockedURI, probeOrigin].includes(violation.blockedURI) &&
        violation.disposition === 'enforce'),
      `The report CSP must enforce ${directive} for the external HTTP probe`);
    }
    await delay(250);
    assert.deepEqual(hits, [{ method: 'GET', path: controlPath }],
      'Neither sandbox HTTP fetch nor image may reach the reachable probe server');
    return { serial, positiveControl: 'GET received with complete HTTP 200 body',
      probeUrls: { fetch: fetchUrl, image: imageUrl }, sandboxProbeHits: 0, ...outcomes };
  } finally {
    try {
      if (ownsReverse) await adb('reverse', '--remove', reverse);
    } finally {
      await new Promise(resolveClose => {
        server.close(resolveClose);
        server.closeAllConnections();
      });
    }
  }
}

const page = await selectPage();
assert.ok(page.webSocketDebuggerUrl, 'The native page must expose its debug socket');
const socketUrl = new URL(page.webSocketDebuggerUrl);
assert.equal(socketUrl.protocol, 'ws:');
assert.equal(socketUrl.host, endpointUrl.host,
  'Connect only to the page on the explicitly forwarded endpoint');
const connection = await PageConnection.connect(socketUrl.href);
try {
  await connection.request('Page.enable');
  await connection.request('Runtime.enable');
  const deadline = Date.now() + 60000;
  let parentContext;
  let reportContext;
  let ready = false;
  while (Date.now() < deadline) {
    const { frameTree } = await connection.request('Page.getFrameTree');
    assert.equal(frameTree.frame.url, pageUrl, 'The viewer must remain on its owned page');
    const report = frameTree.childFrames?.find(child => child.frame.url === reportUrl);
    const defaultContext = frameId => [...connection.contexts.values()].find(context =>
      context.auxData?.isDefault === true && context.auxData.frameId === frameId)?.id;
    parentContext = defaultContext(frameTree.frame.id);
    reportContext = report && defaultContext(report.frame.id);
    if (parentContext !== undefined && reportContext !== undefined) {
      ready = await connection.evaluate(reportContext,
        `document.getElementById('large-title')?.textContent === 'Complete 32 MiB report'`);
      if (ready) break;
    }
    await delay(200);
  }
  assert.ok(ready, 'The tail of the complete 32 MiB report must render within 60 seconds');

  const reportState = await connection.evaluate(reportContext, `({
    parentAccess: document.body.dataset.parentAccess,
    storage: document.body.dataset.storage,
    mode: document.compatMode,
    count: document.getElementById('count').textContent,
  })`);
  assert.equal(reportState.parentAccess, 'blocked');
  assert.equal(reportState.storage, 'blocked');
  assert.equal(reportState.mode, 'CSS1Compat');
  assert.equal(reportState.count, '0');
  const parentState = await connection.evaluate(parentContext, `(() => {
    const frame = document.querySelector('#diagram iframe');
    return {
      escaped: document.body.getAttribute('data-escaped'),
      src: frame?.getAttribute('src'),
      sandbox: frame?.getAttribute('sandbox'),
    };
  })()`);
  assert.equal(parentState.escaped, null);
  assert.equal(parentState.src, 'report.html');
  assert.equal(parentState.sandbox, 'allow-scripts');

  await connection.evaluate(reportContext,
    `document.getElementById('increment').scrollIntoView({block: 'center'})`);
  await connection.evaluate(parentContext,
    `document.querySelector('#diagram iframe').scrollIntoView({block: 'center'})`);
  const framePosition = await connection.evaluate(parentContext, `(() => {
    const rect = document.querySelector('#diagram iframe').getBoundingClientRect();
    return {x: rect.x, y: rect.y};
  })()`);
  const buttonPosition = await connection.evaluate(reportContext, `(() => {
    const rect = document.getElementById('increment').getBoundingClientRect();
    return {x: rect.x + rect.width / 2, y: rect.y + rect.height / 2};
  })()`);
  const click = {
    x: framePosition.x + buttonPosition.x,
    y: framePosition.y + buttonPosition.y,
    button: 'left', clickCount: 1,
  };
  await connection.request('Input.dispatchMouseEvent', {type: 'mousePressed', ...click});
  await connection.request('Input.dispatchMouseEvent', {type: 'mouseReleased', ...click});
  assert.equal(await connection.evaluate(reportContext,
    `document.getElementById('count').textContent`), '1');
  assert.equal(await connection.evaluate(parentContext,
    `document.body.getAttribute('data-escaped')`), null);
  assert.equal(await connection.evaluate(parentContext, 'location.href'), pageUrl);

  const httpIsolation = await checkExternalHttpIsolation(connection, reportContext);
  // Android owns the composed display; capture the selected emulator's pixels.
  const { stdout: screenshot } = await run('adb', ['-s', serial, 'exec-out', 'screencap', '-p'], {
    encoding: null, timeout: requestTimeout, killSignal: 'SIGKILL', maxBuffer: 16 * 1024 * 1024,
  });
  await mkdir(resolve('build/large-html-review'), { recursive: true });
  await writeFile(resolve('build/large-html-review/native-32mib.png'), screenshot);
  await writeFile(resolve('build/large-html-review/native-http-isolation.json'),
    `${JSON.stringify(httpIsolation, null, 2)}\n`);
  console.log('PASS: native Android WebView rendered the complete 32 MiB report; controls work; parent/storage and external HTTP fetch/image remain blocked; the same emulator reached the HTTP control.');
} finally {
  connection.close();
}
