// Browser acceptance for the static website. Reuses the repo's Playwright Core.
const { resolve } = require('node:path');
const { mkdirSync, writeFileSync, readFileSync } = require('node:fs');
const assert = require('node:assert/strict');

const [modulePath, baseUrl, outputPath] = process.argv.slice(2);
if (!modulePath || !baseUrl || !outputPath) {
  throw new Error('Usage: node tools/website/review.cjs <playwright-core-path> <preview-url> <output-directory>');
}
const playwright = require(resolve(modulePath));
const executableConfig = process.argv[5] ? JSON.parse(readFileSync(process.argv[5], 'utf8')) : {};
const launchOptions = name => ({ headless: true, ...(executableConfig[name] ? { executablePath: executableConfig[name] } : {}) });
const output = resolve(outputPath);
mkdirSync(output, { recursive: true });

async function loadedImages(page) {
  await page.evaluate(() => document.fonts.ready);
  await page.locator('img').evaluateAll(async images => {
    for (const image of images) image.loading = 'eager';
    await Promise.all(images.map(image => image.decode()));
  });
}

async function checkLayout(page, label) {
  const result = await page.evaluate(() => {
    const overflow = document.documentElement.scrollWidth > innerWidth + 1;
    const brokenImages = [...document.images].filter(image => !image.complete || !image.naturalWidth).map(image => image.src);
    const brokenAnchors = [...document.querySelectorAll('a[href^="#"]')].filter(link => link.hash && !document.getElementById(link.hash.slice(1))).map(link => link.hash);
    return { overflow, brokenImages, brokenAnchors };
  });
  assert.equal(result.overflow, false, `${label}: horizontal overflow`);
  assert.deepEqual(result.brokenImages, [], `${label}: broken images`);
  assert.deepEqual(result.brokenAnchors, [], `${label}: broken anchors`);
}

async function checkContrast(page) {
  const failures = await page.evaluate(() => {
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = 1;
    const context = canvas.getContext('2d', { willReadFrequently: true });
    function rgba(color) {
      context.clearRect(0, 0, 1, 1);
      context.fillStyle = color;
      context.fillRect(0, 0, 1, 1);
      return [...context.getImageData(0, 0, 1, 1).data];
    }
    function luminance(color) {
      const linear = color.slice(0, 3).map(v => {
        const channel = v / 255;
        return channel <= .04045 ? channel / 12.92 : ((channel + .055) / 1.055) ** 2.4;
      });
      return .2126 * linear[0] + .7152 * linear[1] + .0722 * linear[2];
    }
    const results = [];
    const selectors = 'p,dt,dd,h1,h2,h3,.button,.nav-link,.work-tab>span,.text-link,summary,.footer-top nav>a';
    for (const element of document.querySelectorAll(selectors)) {
      if (!element.getClientRects().length || element.closest('[hidden]')) continue;
      const style = getComputedStyle(element);
      let ancestor = element;
      let background;
      while (ancestor && !background) {
        const color = rgba(getComputedStyle(ancestor).backgroundColor);
        if (color[3] === 255) background = color;
        ancestor = ancestor.parentElement;
      }
      if (!background) continue;
      const a = luminance(rgba(style.color));
      const b = luminance(background);
      const ratio = (Math.max(a, b) + .05) / (Math.min(a, b) + .05);
      const large = parseFloat(style.fontSize) >= 24 || (parseFloat(style.fontSize) >= 18.66 && parseInt(style.fontWeight) >= 700);
      if (ratio < (large ? 3 : 4.5)) results.push({ text: element.textContent.trim().slice(0, 70), ratio });
    }
    return results;
  });
  assert.deepEqual(failures, [], 'Text contrast failures');
}

async function checkLocalLinks(page) {
  const origin = new URL(baseUrl).origin;
  const links = await page.locator('a[href]').evaluateAll(elements => [...new Set(elements.map(link => link.href))]);
  const documents = new Map();
  for (const href of links) {
    const target = new URL(href);
    if (target.origin !== origin) continue;
    const fragment = target.hash.slice(1);
    target.hash = '';
    if (!documents.has(target.href)) {
      const response = await page.request.get(target.href);
      assert.equal(response.status(), 200, `Local link ${target.href}`);
      documents.set(target.href, (response.headers()['content-type'] || '').includes('text/html') ? await response.text() : null);
    }
    if (fragment) {
      const html = documents.get(target.href);
      assert.ok(html, `Fragment target is HTML: ${href}`);
      assert.equal(await page.evaluate(({ html, fragment }) => !!new DOMParser().parseFromString(html, 'text/html').getElementById(decodeURIComponent(fragment)), { html, fragment }), true, `Local fragment ${href}`);
    }
  }
}

async function checkScreenshotViewer(page, label, all = false) {
  // The hero receipt overlaps the lower corner of the conversation screenshot.
  // Click the exposed upper area, as a visitor would.
  const clickThumbnail = async thumbnail => {
    await thumbnail.scrollIntoViewIfNeeded();
    const box = await thumbnail.boundingBox();
    await thumbnail.click({ position: { x: box.width / 2, y: Math.min(40, box.height / 4) } });
  };
  assert.equal(await page.locator('.expand-image').count(), 0, `${label}: no separate enlargement buttons`);
  const links = page.locator('main [data-screenshot]');
  const screenshotCount = await page.locator('main img[src^="assets/screenshots/"]').count();
  assert.equal(await links.count(), screenshotCount, `${label}: every screenshot is a link`);
  const candidates = all ? await links.all() : [links.first()];
  for (const thumbnail of candidates) {
    if (!await thumbnail.isVisible()) continue;
    const source = await thumbnail.locator('img').getAttribute('src');
    assert.equal(await thumbnail.getAttribute('href'), source, `${label}: thumbnail opens its current appearance`);
    await thumbnail.scrollIntoViewIfNeeded();
    const original = await thumbnail.boundingBox();
    const scroll = await page.evaluate(() => scrollY);
    await clickThumbnail(thumbnail);
    const dialog = page.locator('.screenshot-viewer[open]');
    await dialog.waitFor({ state: 'visible' });
    await page.waitForFunction(() => !document.querySelector('.viewer-image').getAnimations().some(animation => animation.playState === 'running'));
    assert.equal(await dialog.locator('img').getAttribute('src').then(src => new URL(src).pathname.endsWith(source)), true, `${label}: displayed screenshot`);
    const large = await dialog.locator('img').boundingBox();
    assert.ok(large.width > original.width, `${label}: screenshot enlarges`);
    const viewport = page.viewportSize();
    assert.ok(large.x >= 0 && large.y >= 0 && large.x + large.width <= viewport.width + 1 && large.y + large.height <= viewport.height + 1, `${label}: entire screenshot fits`);
    assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY), 'hidden', `${label}: page scroll locked`);
    await page.keyboard.press('Tab');
    assert.equal(await page.evaluate(() => !!document.activeElement.closest('dialog')), true, `${label}: focus remains in viewer`);
    await dialog.locator('.viewer-picture').click();
    await dialog.waitFor({ state: 'hidden', timeout: 1500 });
    assert.ok(Math.abs(await page.evaluate(() => scrollY) - scroll) < 1, `${label}: returns to the same page position`);
    assert.equal(await thumbnail.evaluate(el => el === document.activeElement && getComputedStyle(el).visibility === 'visible'), true, `${label}: focus and thumbnail restored`);
  }
  if (!await links.count()) return;
  const thumbnail = links.first();
  await clickThumbnail(thumbnail);
  await page.locator('.screenshot-viewer[open]').waitFor({ state: 'visible' });
  // An outside click during entry must interrupt smoothly and complete the return.
  await page.mouse.click(4, 4);
  await page.locator('.screenshot-viewer[open]').waitFor({ state: 'hidden', timeout: 1500 });
  await thumbnail.focus();
  await page.keyboard.press('Enter');
  await page.locator('.screenshot-viewer[open]').waitFor({ state: 'visible' });
  assert.equal(await page.locator('.viewer-image').evaluate(el => el.getAnimations().length), 0, `${label}: keyboard opens without movement`);
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('.screenshot-viewer[open]').count(), 0, `${label}: Escape closes immediately`);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await clickThumbnail(thumbnail);
  await page.locator('.screenshot-viewer[open]').waitFor({ state: 'visible' });
  assert.equal(await page.locator('.viewer-image').evaluate(el => el.getAnimations().length), 0, `${label}: reduced motion opens without movement`);
  await page.locator('.viewer-close').click();
  assert.equal(await page.locator('.screenshot-viewer[open]').count(), 0, `${label}: close control works`);
  await page.emulateMedia({ reducedMotion: 'no-preference' });
}

async function checkReadingOrder(page, label) {
  const failures = await page.evaluate(() => {
    const results = [];
    for (const group of document.querySelectorAll('.feature-story, .work-panel, .guide-copy section')) {
      if (!group.getBoundingClientRect().height) continue;
      const images = [...group.querySelectorAll('figure')];
      const links = [...group.querySelectorAll(':scope > .text-link')];
      for (const link of links) {
        if (images.some(image => image.getBoundingClientRect().bottom > link.getBoundingClientRect().top + 1)) results.push(link.textContent.trim());
      }
    }
    return results;
  });
  assert.deepEqual(failures, [], `${label}: further reading follows screenshots`);
}

async function review(engineName) {
  const browser = await playwright[engineName].launch(launchOptions(engineName));
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('response', response => { if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`); });
  const response = await page.goto(baseUrl);
  assert.equal(response.status(), 200);
  // Keyboard navigation can reach an offscreen image before lazy loading starts.
  const coldScreenshot = page.locator('#panel-follow [data-screenshot]');
  await coldScreenshot.focus();
  await page.keyboard.press('Enter');
  await page.locator('.screenshot-viewer[open]').waitFor({ state: 'visible' });
  assert.equal(await page.locator('.viewer-image').evaluate(el => el.getAnimations().length), 0, `${engineName}: keyboard opens a lazy screenshot without movement`);
  await page.keyboard.press('Escape');
  assert.equal(await coldScreenshot.evaluate(el => el === document.activeElement), true, `${engineName}: lazy screenshot focus restored`);
  await page.addStyleTag({ content: 'html { scroll-behavior: auto !important; }' });
  await loadedImages(page);
  assert.equal(await page.locator('main').count(), 1, 'One main landmark');
  assert.equal(await page.evaluate(() => document.fonts.check('650 32px Manrope') && document.fonts.check('400 18px "Source Sans 3"')), true, 'Self-hosted fonts loaded');

  for (const width of [320, 390, 768, 1024, 1440]) {
    await page.setViewportSize({ width, height: width < 600 ? 844 : 1000 });
    for (const theme of ['dark', 'light']) {
      await page.locator(`[data-theme="${theme}"]`).click();
      await loadedImages(page);
      for (const name of ['follow', 'steer']) {
        await page.locator(`#tab-${name}`).click();
        assert.equal(await page.locator('[role="tabpanel"]:visible').count(), 1);
        assert.equal(await page.locator(`#tab-${name}`).getAttribute('aria-selected'), 'true');
        assert.equal(await page.locator(`#panel-${name} img`).getAttribute('src').then(src => src.endsWith(`-${theme}.png`)), true);
        const image = await page.locator(`#panel-${name} img`).getAttribute('src');
        assert.equal(await page.locator(`#panel-${name} [data-screenshot]`).getAttribute('href'), image);
        await checkLayout(page, `${engineName} ${width} ${theme} ${name}`);
        await checkReadingOrder(page, `${engineName} ${width} ${name}`);
      }
    }
    await page.locator('#tab-follow').click();
    await page.locator('[data-theme="dark"]').click();
    await loadedImages(page);
    await page.evaluate(() => scrollTo(0, 0));
    if (width === 1440 || width === 390) {
      await page.screenshot({ path: resolve(output, `${engineName}-${width}-full.png`), fullPage: true });
      await page.screenshot({ path: resolve(output, `${engineName}-${width}-hero.png`) });
    }
  }

  assert.equal(await page.locator('#analytics img[src*="analytics"]').count(), 1, 'Analytics has its own illustrated homepage section');
  assert.equal(await page.locator('#panel-follow img').getAttribute('data-app-image'), 'activity', 'Activity is the first workflow example');
  await checkScreenshotViewer(page, `${engineName} homepage`, true);
  await page.setViewportSize({ width: 390, height: 844 });
  await checkScreenshotViewer(page, `${engineName} phone homepage`);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.locator('#tab-follow').focus();
  await page.keyboard.press('ArrowRight');
  assert.equal(await page.locator('#tab-steer').getAttribute('aria-selected'), 'true');
  assert.equal(await page.evaluate(() => document.activeElement.id), 'tab-steer');
  assert.equal(await page.locator('.work-stage').getAttribute('data-pointer-change'), 'false', 'Keyboard changes do not animate');
  await page.keyboard.press('End');
  assert.equal(await page.locator('#tab-steer').getAttribute('aria-selected'), 'true');
  await page.keyboard.press('Home');
  assert.equal(await page.locator('#tab-follow').getAttribute('aria-selected'), 'true');
  for (const question of await page.locator('details').all()) {
    await question.locator('summary').click();
    assert.equal(await question.getAttribute('open'), '');
    await question.locator('summary').click();
    assert.equal(await question.getAttribute('open'), null);
  }
  await checkContrast(page);
  await checkLocalLinks(page);
  for (const width of [390, 1024]) {
    await page.setViewportSize({ width, height: 1000 });
    await page.evaluate(() => document.documentElement.style.fontSize = '200%');
    await checkLayout(page, `${engineName} ${width} 200% text`);
    await page.evaluate(() => document.documentElement.style.fontSize = '');
  }
  await page.emulateMedia({ reducedMotion: 'reduce' });
  const motion = await page.locator('.hero-phone').evaluate(el => getComputedStyle(el).animationName);
  assert.equal(motion, 'none');
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.locator('#tab-steer').click();
  await page.screenshot({ path: resolve(output, `${engineName}-steer.png`), fullPage: true });
  await page.locator('#workspaces').screenshot({ path: resolve(output, `${engineName}-workspaces-section.png`) });
  for (const name of ['workspaces', 'bots', 'recents', 'live-work', 'results', 'health', 'administration', 'scheduled-tasks', 'usage', 'get-started']) {
    const result = await page.goto(new URL(`${name}.html`, baseUrl).href);
    assert.equal(result.status(), 200, `${name}: loads`);
    await page.addStyleTag({ content: 'html { scroll-behavior: auto !important; }' });
    await loadedImages(page);
    assert.equal(await page.locator('h1').count(), 1, `${name}: one main title`);
    assert.equal(await page.locator('.topic-nav [aria-current="page"]').count(), 1, `${name}: current feature guide`);
    await checkLocalLinks(page);
    await checkContrast(page);
    for (const width of [320, 390, 768, 1024, 1440]) {
      await page.setViewportSize({ width, height: width < 600 ? 844 : 1000 });
      await checkLayout(page, `${engineName} ${name} ${width}`);
      await checkReadingOrder(page, `${engineName} ${name} ${width}`);
      if (width === 390 || width === 1440) {
        await page.evaluate(() => scrollTo(0, 0));
        await page.screenshot({ path: resolve(output, `${engineName}-${name}-${width}.png`), fullPage: true });
      }
    }
    if (await page.locator('[data-screenshot]').count()) await checkScreenshotViewer(page, `${engineName} ${name}`, true);
    for (const width of [390, 1024]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.evaluate(() => document.documentElement.style.fontSize = '200%');
      await checkLayout(page, `${engineName} ${name} ${width} 200% text`);
      await page.evaluate(() => document.documentElement.style.fontSize = '');
    }
  }
  assert.deepEqual(errors, [], `${engineName}: browser errors`);
  await browser.close();

  const staticBrowser = await playwright[engineName].launch(launchOptions(engineName));
  const staticPage = await staticBrowser.newPage({ javaScriptEnabled: false, viewport: { width: 390, height: 844 } });
  await staticPage.goto(baseUrl);
  assert.equal(await staticPage.locator('[role="tabpanel"]:visible').count(), 2, 'All workflows remain readable without JavaScript');
  await checkLayout(staticPage, `${engineName} JavaScript disabled`);
  await staticBrowser.close();
  return `${engineName}: 20 homepage viewport/theme/workflow combinations; ten guides at five widths; local links and cross-page anchors; keyboard tabs; disclosures; text contrast; 200% text on every page; reduced motion; screenshot enlargement, return, outside click, Escape, keyboard focus and interruption; section reading order; no-JavaScript reading.`;
}

(async () => {
  const reports = [];
  const engines = process.argv[6]?.split(',') || ['chromium', 'firefox', 'webkit'];
  for (const engine of engines) {
    assert.ok(['chromium', 'firefox', 'webkit'].includes(engine), `Unknown browser engine: ${engine}`);
    reports.push(await review(engine));
    console.log(reports.at(-1));
  }
  writeFileSync(resolve(output, 'verification.txt'), reports.join('\n') + '\n');
})().catch(error => { console.error(error); process.exit(1); });
