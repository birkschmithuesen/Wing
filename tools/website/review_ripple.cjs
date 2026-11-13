// Focused acceptance for reply-arrival media. Uses the existing browser harness.
const { resolve } = require('node:path');
const { readFileSync, mkdirSync } = require('node:fs');
const assert = require('node:assert/strict');
const [modulePath, base, output, config] = process.argv.slice(2);
if (!config) throw new Error('Usage: review_ripple.cjs <playwright-core> <url> <output> <browser-paths.json>');
const playwright = require(resolve(modulePath));
const paths = JSON.parse(readFileSync(config, 'utf8'));
mkdirSync(output, { recursive: true });

(async () => {
  for (const engine of (process.argv[6] || 'chromium,firefox,webkit').split(',')) {
    const browser = await playwright[engine].launch({ headless: true, executablePath: paths[engine] });
    try {
      const page = await browser.newPage({ viewport: { width: 1200, height: 1000 } });
      page.setDefaultTimeout(10000);
      const stillPage = await browser.newPage({ viewport: { width: 1200, height: 1000 }, reducedMotion: 'reduce' });
      await stillPage.goto(new URL('recents.html', base).href);
      const stillFrame = stillPage.locator('[data-ripple-demo] .app-frame');
      await stillFrame.scrollIntoViewIfNeeded();
      await stillFrame.locator('img').evaluate(img => { img.loading = 'eager'; });
      await stillPage.waitForFunction(() => {
        const img = document.querySelector('[data-ripple-demo] img');
        return img.complete && img.naturalWidth > 0;
      });
      await stillFrame.locator('img').evaluate(img => img.decode());
      const still = await stillFrame.screenshot();
      await stillPage.close();
      let request;
      let count = 0;
      const attempts = new Set();
      await page.route('**/recents-arrival-dark.gif?*', route => {
        // Routing disables the HTTP cache. Allow the displayed image to reuse
        // an already released preload; hold each new user attempt only once.
        const url = route.request().url();
        if (attempts.has(url)) return route.continue();
        attempts.add(url);
        count++;
        request = route;
      });
      await page.goto(new URL('recents.html', base).href);
      const demo = page.locator('[data-ripple-demo]');
      const replay = page.locator('[data-ripple-replay]');
      await demo.scrollIntoViewIfNeeded();
      await page.waitForFunction(() => document.querySelector('[data-ripple-demo]').getAttribute('aria-busy') === 'true');
      await page.waitForFunction(() => document.querySelector('[data-ripple-replay] svg').getAnimations().some(a => a.playState === 'running'));
      assert.equal(await replay.isDisabled(), true);
      // Capture actual visible feedback while the media request is held.
      await page.screenshot({ path: `${output}/${engine}-pending.png` });
      assert.ok((await demo.locator('.app-frame').screenshot()).equals(still), 'The still image must remain visible while the animation is loading');
      assert.ok(request);
      await request.continue();
      await page.waitForFunction(() => document.querySelector('[data-ripple-demo] img').currentSrc.includes('.gif?'));
      await page.waitForTimeout(1400);
      await demo.screenshot({ path: `${output}/${engine}-playing.png` });
      await page.waitForFunction(() => document.querySelector('[data-ripple-demo]').getAttribute('aria-busy') === 'false');
      assert.equal(count, 1);
      await page.evaluate(() => scrollTo(0, 0));
      await demo.scrollIntoViewIfNeeded();
      assert.equal(count, 1, 'Scrolling back must not autoplay again');
      await replay.click();
      await page.waitForFunction(() => document.querySelector('[data-ripple-demo]').getAttribute('aria-busy') === 'true');
      while (count < 2) await page.waitForTimeout(20);
      await request.abort();
      await page.locator('.ripple-error').waitFor({ state: 'visible' });
      assert.equal(await replay.getAttribute('aria-label'), 'Retry reply ripple animation');
      await demo.screenshot({ path: `${output}/${engine}-failed.png` });
      await replay.click();
      while (count < 3) await page.waitForTimeout(20);
      await request.continue();
      await page.waitForFunction(() => document.querySelector('[data-ripple-demo] img').currentSrc.includes('.gif?'));
      await page.emulateMedia({ reducedMotion: 'reduce' });
      await replay.waitFor({ state: 'hidden' });
      assert.equal(await demo.getAttribute('aria-busy'), 'false');
      assert.equal(await demo.locator('source').getAttribute('srcset'), null);
      await page.reload();
      await demo.scrollIntoViewIfNeeded();
      assert.equal(count, 3, 'Reduced motion must not request an animation');
      await page.close();

      const plain = await browser.newPage({ javaScriptEnabled: false });
      await plain.goto(new URL('recents.html', base).href);
      await plain.locator('[data-ripple-demo]').scrollIntoViewIfNeeded();
      assert.equal(await plain.locator('[data-ripple-demo] img').evaluate(img => img.complete && img.naturalWidth > 0), true);
      assert.equal(await plain.locator('[data-ripple-replay]').isVisible(), false);
      await plain.close();

      const layout = await browser.newPage({ reducedMotion: 'reduce' });
      for (const name of ['recents', 'bots', 'scheduled-tasks', 'get-started']) {
        for (const width of [320, 390, 768, 1200, 1920]) {
          await layout.setViewportSize({ width, height: 900 });
          await layout.goto(new URL(`${name}.html`, base).href);
          await layout.locator('img').evaluateAll(async images => {
            for (const img of images) img.loading = 'eager';
            await Promise.all(images.map(img => img.decode()));
          });
          assert.equal(await layout.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, `${engine}/${name}/${width}`);
          if (width === 390 || width === 1200) await layout.screenshot({ path: `${output}/${engine}-${name}-${width}.png`, fullPage: true });
          await layout.addStyleTag({ content: 'html { font-size: 200% !important; }' });
          assert.equal(await layout.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true, `${engine}/${name}/${width}/large-text`);
        }
        for (const shot of await layout.locator('[data-screenshot]').all()) {
          await shot.click();
          await layout.locator('.screenshot-viewer[open]').waitFor();
          await layout.keyboard.press('Escape');
          await layout.locator('.screenshot-viewer[open]').waitFor({ state: 'hidden' });
        }
      }
      await layout.close();
      console.log(`${engine}: held load, completion, failure/retry, reduced motion, no JS, layouts and screenshot viewing passed`);
    } finally { await browser.close(); }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
