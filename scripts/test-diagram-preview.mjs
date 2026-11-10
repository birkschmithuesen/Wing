import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { mkdir, readFile } from 'node:fs/promises';
import { extname, join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const assets = join(root, 'android', 'app', 'src', 'main', 'assets', 'diagrams');
const playwrightPath = process.env.PLAYWRIGHT_CORE_PATH
  ?? join(root, 'scripts', 'diagram-preview', 'node_modules', 'playwright-core');
const { chromium } = createRequire(import.meta.url)(playwrightPath);
const chromePath = process.env.CHROME_PATH;
const allowedFiles = new Set(['index.html', 'app.js', 'mermaid.min.js', 'report.html']);
let reportSource = '';
// Exercise the same response policy that Android applies to the local document.
const nativeViewer = await readFile(join(root, 'android/app/src/main/kotlin/com/tarkilhk/wing/MermaidDiagramView.kt'), 'utf8');
const htmlPolicy = nativeViewer.match(/private const val HTML_POLICY = ([\s\S]*?)\n        private val ASSETS/)[1]
  .match(/"[^"]*"/g).map(value => JSON.parse(value)).join('');
const viewerUnavailable = nativeViewer.match(/private fun viewerUnavailableScript\(\): String =\s*([\s\S]*?)\n\n/)[1]
  .match(/"[^"]*"/g).map(value => JSON.parse(value)).join('');

const server = createServer(async (request, response) => {
  const name = new URL(request.url, 'http://localhost').pathname.slice(1) || 'index.html';
  if (!allowedFiles.has(name)) {
    response.writeHead(404).end();
    return;
  }
  if (name === 'report.html') {
    response.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'Content-Security-Policy': htmlPolicy,
    });
    response.end(reportSource);
    return;
  }
  const body = await readFile(join(assets, name));
  const contentType = extname(name) === '.html'
    ? 'text/html; charset=utf-8'
    : 'text/javascript; charset=utf-8';
  response.writeHead(200, { 'Content-Type': contentType, 'Cache-Control': 'no-store' });
  response.end(body);
});

await new Promise((resolveListen, reject) => {
  server.once('error', reject);
  server.listen(0, '127.0.0.1', resolveListen);
});

let browser;
try {
  const port = server.address().port;
  const origin = `http://127.0.0.1:${port}`;
  browser = await chromium.launch({
    executablePath: chromePath,
    headless: true,
    args: ['--disable-gpu', '--disable-background-networking'],
  });
  const page = await browser.newPage({ viewport: { width: 412, height: 915 } });
  const unexpectedRequests = [];
  await page.route('**/*', async (route) => {
    const url = new URL(route.request().url());
    if (url.origin === origin && allowedFiles.has(url.pathname.slice(1))) {
      await route.continue();
    } else {
      unexpectedRequests.push(url.href);
      await route.abort();
    }
  });
  await page.goto(`${origin}/index.html`, { waitUntil: 'load' });
  await page.waitForFunction(() => typeof window.renderDiagram === 'function');

  const cases = [
    ['flowchart LR\nA[Start] --> B[Done]', false],
    ['sequenceDiagram\nAlice->>Bob: Hello\nBob-->>Alice: Hi', true],
    ['pie title Pets\n"Dogs" : 6\n"Cats" : 4', false],
    ['flowchart LR\nA --> B\nclick A href "https://example.com" "External link"', false],
    ['%%{init: {"securityLevel": "loose"}}%%\nflowchart LR\nA-->B', false],
    ['---\nconfig:\n  securityLevel: loose\n---\nflowchart LR\nA-->B', false],
    ['flowchart LR\nSECRET_PARSE_TEXT_7f13 -- broken', false],
    ['flowchart LR\nA["ice point<br/>limit-up below twenty"] --> B["warming<br/>volume up"]', false],
    ['flowchart LR\nA["one&nbsp;two"] --> B["three #nbsp; four"]', true],
  ];
  const results = [];

  for (const [source, dark] of cases) {
    results.push(await page.evaluate(async ({ source, dark }) => {
      const rendered = await window.renderDiagram(source, dark);
      return {
        rendered,
        svg: Boolean(document.querySelector('#diagram > svg')),
        blockedNodes: document.querySelectorAll('#diagram a, #diagram image, #diagram foreignObject').length,
        status: document.querySelector('#status').textContent,
        body: document.body.textContent,
        theme: document.documentElement.dataset.theme,
      };
    }, { source, dark }));

    if (results.length === 1) {
      await mkdir(join(root, 'build'), { recursive: true });
      await page.screenshot({ path: join(root, 'build', 'diagram-preview.png'), fullPage: true });
    }
  }

  for (const [index, result] of results.slice(0, 3).entries()) {
    assert.equal(result.rendered, true, `render case ${index + 1} failed: ${result.status}`);
    assert.equal(result.svg, true, `render case ${index + 1} did not produce an SVG`);
    assert.equal(result.blockedNodes, 0, `render case ${index + 1} retained active or embedded content`);
  }
  assert.match(results[0].body, /Start/);
  assert.match(results[0].body, /Done/);
  assert.equal(results[1].theme, 'dark');
  assert.equal(results[3].rendered, false);
  assert.equal(results[3].body.includes('example.com'), false);
  assert.match(results[4].status, /configuration directives are not allowed/i);
  assert.equal(results[4].body.includes('securityLevel'), false);
  assert.match(results[5].status, /configuration directives are not allowed/i);
  assert.equal(results[5].body.includes('securityLevel'), false);
  assert.match(results[6].status, /could not parse/i);
  assert.equal(results[6].body.includes('SECRET_PARSE_TEXT_7f13'), false);
  for (const [index, result] of results.slice(7).entries()) {
    assert.equal(result.rendered, true, `multiline label ${index} failed: ${result.status}`);
    assert.equal(result.svg, true);
    assert.equal(result.blockedNodes, 0);
  }
  assert.match(results[7].body, /ice point/);
  assert.match(results[8].body, /one/);

  console.log('Rendered flowchart, sequence, and pie cases in headless Chromium.');
  console.log('Rejected links and config overrides, and kept errors free of source text.');

  const svgResults = await page.evaluate(async (origin) => {
    const liveUrls = new Set();
    const create = URL.createObjectURL.bind(URL);
    const revoke = URL.revokeObjectURL.bind(URL);
    URL.createObjectURL = (blob) => {
      const url = create(blob);
      liveUrls.add(url);
      return url;
    };
    URL.revokeObjectURL = (url) => { liveUrls.delete(url); revoke(url); };
    const wrap = (body) => `<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">${body}</svg>`;
    const pixel = () => {
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 32;
      const context = canvas.getContext('2d');
      context.drawImage(document.querySelector('#diagram img'), 0, 0, 32, 32);
      return [...context.getImageData(16, 16, 1, 1).data];
    };
    const script = wrap('<rect id="target" width="32" height="32" fill="green"/><script>document.getElementById("target").setAttribute("fill","red")</script>');
    const scriptRendered = await window.renderSvg(script, true);
    const scriptPixel = pixel();
    const embedded = wrap(`<style>@import url('${origin}/forbidden.css');</style><image href="${origin}/forbidden.png"/><foreignObject width="32" height="32"><div xmlns="http://www.w3.org/1999/xhtml" onload="fetch('${origin}/forbidden-event')"><img src="${origin}/forbidden-inner.png"/></div></foreignObject><a href="${origin}/forbidden-link"><rect width="32" height="32" fill="blue"/></a>`);
    const embeddedRendered = await window.renderSvg(embedded);
    document.querySelector('#diagram img')?.click();
    const inlineNodes = document.querySelectorAll('#diagram svg, #diagram script, #diagram a, #diagram foreignObject').length;
    const malformed = await window.renderSvg('<svg>SECRET_BAD_SVG');
    const malformedStatus = document.querySelector('#status').textContent;
    const oversized = await window.renderSvg('x'.repeat(256 * 1024 + 1));
    const huge = await window.renderSvg('<svg xmlns="http://www.w3.org/2000/svg" width="9000" height="9000"/>');
    const replacement = await Promise.all([
      window.renderSvg(wrap('<rect width="32" height="32" fill="red"/>')),
      window.renderSvg(wrap('<rect width="32" height="32" fill="blue"/>')),
    ]);
    return { scriptRendered, scriptPixel, embeddedRendered, inlineNodes, malformed,
      malformedStatus, oversized, huge, replacement, finalPixel: pixel(), liveUrls: liveUrls.size };
  }, origin);
  assert.equal(svgResults.scriptRendered, true);
  assert.deepEqual(svgResults.scriptPixel, [0, 128, 0, 255], 'SVG scripts must not change image pixels');
  assert.equal(svgResults.embeddedRendered, true);
  assert.equal(svgResults.inlineNodes, 0);
  assert.equal(svgResults.malformed, false);
  assert.equal(svgResults.malformedStatus.includes('SECRET_BAD_SVG'), false);
  assert.equal(svgResults.oversized, false);
  assert.equal(svgResults.huge, false);
  assert.equal(svgResults.replacement[1], true);
  assert.deepEqual(svgResults.finalPixel, [0, 0, 255, 255]);
  assert.equal(svgResults.liveUrls, 0, 'SVG object URLs must be released');
  assert.deepEqual(unexpectedRequests, [], 'Previews attempted an external or unexpected request');
  assert.equal(page.url(), `${origin}/index.html`);
  assert.equal(await page.evaluate(() => window.renderSvg(
    '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="240" viewBox="0 0 600 240">' +
    '<rect x="10" y="50" width="200" height="120" rx="20" fill="#005f49"/>' +
    '<path d="M210 110 H385 M365 90 L385 110 L365 130" stroke="#147c63" stroke-width="8" fill="none"/>' +
    '<rect x="390" y="50" width="200" height="120" rx="20" fill="#005f49"/>' +
    '<g fill="white" font-family="sans-serif" font-size="32" text-anchor="middle"><text x="110" y="120">Draft</text><text x="490" y="120">Result</text></g></svg>',
  )), true);
  await page.screenshot({ path: join(root, 'build', 'svg-preview.png'), fullPage: true });
  console.log('SVG image context blocks script execution and external content; errors, limits and replacement pass.');

  const embeddedDataImage = 'data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20width%3D%22160%22%20height%3D%2260%22%3E%3Crect%20width%3D%22160%22%20height%3D%2260%22%20fill%3D%22%23005f49%22%2F%3E%3Ctext%20x%3D%2280%22%20y%3D%2238%22%20text-anchor%3D%22middle%22%20font-size%3D%2220%22%20fill%3D%22white%22%3EData%20image%3C%2Ftext%3E%3C%2Fsvg%3E';
  const htmlSource = `<!doctype html><html><head>
    <meta http-equiv="Content-Security-Policy" content="default-src * 'unsafe-inline'; img-src * data:">
    <style>body { font: 20px system-ui; padding: 16px; } button { font: inherit; padding: 12px; }</style>
    <script src="${origin}/forbidden-html.js"></script>
    </head><body><h1>Preview check</h1><button id="increment">Increment</button>
    <p>Count: <output id="count">0</output></p>
    <img id="embedded-data-image" src="${embeddedDataImage}" alt="Embedded data image">
    <img src="${origin}/forbidden-html.png">
    <script>
      try { parent.document.body.dataset.escaped = 'yes'; } catch (_) { document.body.dataset.parentAccess = 'blocked'; }
      try { localStorage.setItem('probe', 'yes'); } catch (_) { document.body.dataset.storage = 'blocked'; }
      fetch('${origin}/forbidden-html-fetch').catch(() => {});
      document.getElementById('increment').onclick = () => { document.getElementById('count').textContent++; };
    </script></body></html>`;
  reportSource = htmlSource;
  assert.equal(await page.evaluate(() => window.renderHtml()), true);
  const htmlFrame = page.frameLocator('#diagram iframe');
  await htmlFrame.locator('#increment').click();
  assert.equal(await htmlFrame.locator('#count').textContent(), '1');
  assert.equal(await htmlFrame.locator('body').getAttribute('data-parent-access'), 'blocked');
  assert.equal(await htmlFrame.locator('body').getAttribute('data-storage'), 'blocked');
  assert.equal(await page.locator('#diagram iframe').getAttribute('sandbox'), 'allow-scripts');
  assert.equal(await page.locator('body').getAttribute('data-escaped'), null);
  const embeddedDataImageSize = await htmlFrame.locator('#embedded-data-image').evaluate(async (image) => {
    await image.decode();
    return [image.naturalWidth, image.naturalHeight];
  });
  assert.deepEqual(embeddedDataImageSize, [160, 60]);
  assert.equal(await htmlFrame.locator('html').evaluate(() => document.compatMode), 'CSS1Compat');
  assert.deepEqual(unexpectedRequests, [], 'HTML preview attempted an HTTP asset or fetch request');
  await page.screenshot({ path: join(root, 'build', 'html-preview.png'), fullPage: true });
  for (const mib of [2, 8, 32]) {
    const heading = `Complete ${mib} MiB report`;
    const tail = `<h1 id=large-title>${heading}</h1><button id=large-increment>Increment</button><output id=large-count>0</output><script>document.getElementById('large-increment').onclick=()=>document.getElementById('large-count').textContent++;</script>`;
    const prefix = '<!doctype html><!--';
    reportSource = prefix + 'x'.repeat(mib * 1024 * 1024 - prefix.length - tail.length - 3) + '-->' + tail;
    assert.equal(Buffer.byteLength(reportSource), mib * 1024 * 1024);
    assert.equal(await page.evaluate(() => window.renderHtml()), true);
    const largeFrame = page.frameLocator('#diagram iframe');
    await largeFrame.locator('#large-title').waitFor();
    assert.equal(await largeFrame.locator('#large-title').textContent(), heading);
    await largeFrame.locator('#large-increment').click();
    assert.equal(await largeFrame.locator('#large-count').textContent(), '1');
    assert.equal(await largeFrame.locator('html').evaluate(() => document.compatMode), 'CSS1Compat');
    await page.screenshot({ path: join(root, 'build', `html-large-${mib}mib.png`), fullPage: true });
    console.log(`Rendered and interacted with complete ${mib} MiB HTML document.`);
  }
  reportSource = '<!doctype html><button>Replacement</button>';
  assert.equal(await page.evaluate(() => window.renderHtml()), true);
  await page.frameLocator('#diagram iframe').getByRole('button', { name: 'Replacement' }).waitFor();
  await page.evaluate(() => window.showDiagramError('Closed'));
  assert.equal(await page.locator('#diagram iframe').count(), 0);
  assert.equal(page.url(), `${origin}/index.html`);
  console.log('HTML controls work in an opaque sandbox; parent/storage access and HTTP resources are blocked.');
  assert.equal(await page.evaluate(() => {
    const createElement = document.createElement;
    document.createElement = () => { throw new Error('Could not create iframe'); };
    try {
      return window.renderHtml();
    } finally {
      document.createElement = createElement;
    }
  }), false);
  assert.match(await page.getByRole('alert').textContent(), /HTML file could not be previewed/);

  async function checkStudioError(surface, dark, name, copy) {
    const palette = dark
      ? { canvas: '#101B24', panel: '#192934', text: '#EBF1F2', muted: '#ADBDC4', border: '#344C58', error: '#F87171', 'error-surface': '#352422', accent: '#ABC9FF' }
      : { canvas: '#F7F7F4', panel: '#FFFFFF', text: '#1B2D36', muted: '#586970', border: '#D6E0E1', error: '#B91C1C', 'error-surface': '#FFF1EF', accent: '#285F9B' };
    await surface.evaluate(({ dark, palette }) => window.setStudioTheme(dark, palette), { dark, palette });
    const alert = surface.getByRole('alert');
    assert.match(await alert.textContent(), copy);
    assert.equal(await alert.locator('.status-icon').getAttribute('aria-hidden'), 'true');
    const style = await alert.evaluate(node => ({
      ink: getComputedStyle(node).color,
      fill: getComputedStyle(node).backgroundColor,
      border: getComputedStyle(node, '::before').borderTopColor,
      borderOpacity: getComputedStyle(node, '::before').opacity,
      icon: getComputedStyle(node.querySelector('.status-icon')).color,
      width: document.documentElement.scrollWidth,
    }));
    const rgb = hex => `rgb(${[1, 3, 5].map(offset => parseInt(hex.slice(offset, offset + 2), 16)).join(', ')})`;
    assert.deepEqual(style, {
      ink: rgb(palette.text),
      fill: rgb(palette['error-surface']),
      border: rgb(palette.error),
      borderOpacity: dark ? '0.42' : '0.3',
      icon: rgb(palette.error),
      width: surface.viewportSize().width,
    });
    assert.equal(await surface.locator('html').evaluate(node => getComputedStyle(node).backgroundColor), rgb(palette.canvas));
    await surface.screenshot({ path: join(root, 'build', `studio-diagram-error-${name}.png`), fullPage: true });
  }

  const missingScript = await browser.newPage();
  await missingScript.route('**/app.js', route => route.abort());
  for (const dark of [false, true]) {
    for (const scale of [1, 2]) {
      const viewport = { width: scale === 1 ? 390 : 320, height: 740 };
      const name = `${dark ? 'dark' : 'light'}-${scale}x`;
      for (const surface of [page, missingScript]) {
        await surface.setViewportSize(viewport);
        await surface.goto(`${origin}/index.html`);
        await surface.evaluate(scale => {
          document.documentElement.style.fontSize = `${scale * 100}%`;
        }, scale);
      }
      assert.equal(await page.evaluate(dark => window.renderDiagram('bad Mermaid', dark), dark), false);
      await checkStudioError(page, dark, `mermaid-${name}`, /could not parse/i);
      assert.equal(await page.evaluate(dark => window.renderSvg('<svg>', dark), dark), false);
      await checkStudioError(page, dark, `svg-${name}`, /SVG/i);
      // Android sends source-validation failures via this same shell entry.
      await page.evaluate(() => window.showDiagramError('This HTML file is too large to preview.'));
      await checkStudioError(page, dark, `html-${name}`, /HTML file/i);
      assert.equal(await missingScript.evaluate(() => typeof window.renderDiagram), 'undefined');
      await missingScript.evaluate(viewerUnavailable);
      await checkStudioError(missingScript, dark, `missing-script-${name}`, /viewer could not load/i);
    }
  }
  console.log('Mermaid, SVG, HTML and missing-script errors share Studio ink, icon, tint and border at phone widths in both themes and text sizes.');

} finally {
  await browser?.close();
  await new Promise((resolveClose) => server.close(resolveClose));
}
