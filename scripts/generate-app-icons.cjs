// Run with Node.js and sharp available on NODE_PATH. No image-generation calls.
// Raster source is the approved Playful portrait; wing.svg owns the small mark.
const sharp = require('sharp');
const fs = require('node:fs/promises');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const assets = path.join(root, 'assets/icon');
const navy = '#0C304A';
const wingFile = path.join(assets, 'wing.svg');

async function write(relative, bytes) {
  const target = path.join(root, relative);
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(target, bytes);
}

async function main() {
  const wing = await fs.readFile(wingFile, 'utf8');
  const wingPath = wing.match(/<path[^>]* d="([^"]+)"/)[1];
  // Android's 108 dp layers expose a central 72 dp viewport. At 76 dp, the
  // master's ~82% portrait occupies ~62 dp, inside the 66 dp safe region.
  // The raster master includes its navy matte; don't add another tile/mask.
  const master = path.join(assets, 'playful-master.png');
  for (const [density, scale] of Object.entries({
    mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4,
  })) {
    const size = 108 * scale;
    const foreground = await sharp(master).resize(76 * scale, 76 * scale).png().toBuffer();
    const layer = await sharp({ create: { width: size, height: size, channels: 4, background: navy } })
      .composite([{ input: foreground, left: 16 * scale, top: 16 * scale }]).png().toBuffer();
    await write(`android/app/src/main/res/drawable-${density}/ic_launcher_foreground.png`, layer);
  }
  // Render the same visible composition for pre-adaptive launchers and stores.
  const portrait = await sharp(master).resize(912, 912).png().toBuffer();
  const layer = await sharp({ create: { width: 1296, height: 1296, channels: 4, background: navy } })
    .composite([{ input: portrait, left: 192, top: 192 }]).png().toBuffer();
  const visible = await sharp(layer).extract({ left: 216, top: 216, width: 864, height: 864 })
    .resize(1024, 1024).removeAlpha().png().toBuffer();
  await write('assets/icon/icon.png', visible);
  await write('fastlane/metadata/android/en-US/images/icon.png', await sharp(visible).resize(512, 512).png().toBuffer());
  for (const [density, pixels] of Object.entries({ mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 })) {
    const mask = Buffer.from(`<svg width="${pixels}" height="${pixels}"><rect width="${pixels}" height="${pixels}" rx="${pixels * .22}" fill="white"/></svg>`);
    await write(`android/app/src/main/res/mipmap-${density}/ic_launcher.png`,
      await sharp(visible).resize(pixels, pixels).composite([{ input: mask, blend: 'dest-in' }]).png().toBuffer());
  }
  const vector = `<?xml version="1.0" encoding="utf-8"?>\n<!-- Generated from assets/icon/wing.svg by scripts/generate-app-icons.cjs. -->\n<vector xmlns:android="http://schemas.android.com/apk/res/android"\n    android:width="24dp" android:height="24dp"\n    android:viewportWidth="24" android:viewportHeight="24">\n    <path android:fillColor="#FFFFFFFF" android:pathData="${wingPath}" />\n</vector>\n`;
  await write('android/app/src/main/res/drawable/ic_stat_wing.xml', vector);
  const themed = `<?xml version="1.0" encoding="utf-8"?>\n<!-- Same wing, positioned inside the adaptive icon safe region. -->\n<vector xmlns:android="http://schemas.android.com/apk/res/android"\n    android:width="108dp" android:height="108dp"\n    android:viewportWidth="108" android:viewportHeight="108">\n    <group android:translateX="21" android:translateY="21" android:scaleX="2.75" android:scaleY="2.75">\n        <path android:fillColor="#FFFFFFFF" android:pathData="${wingPath}" />\n    </group>\n</vector>\n`;
  await write('android/app/src/main/res/drawable/ic_launcher_monochrome.xml', themed);
  // A deterministic proof of the shipped pixels, not an ImageGen mockup.
  const parts = [];
  const label = (text, x, y, fill = '#172B27', size = 18) =>
    `<text x="${x}" y="${y}" fill="${fill}" font-size="${size}" font-family="Arial">${text}</text>`;
  const labels = [label('Playful: production asset proof', 28, 38, '#172B27', 26),
    label('Circle mask', 28, 305), label('Rounded mask', 280, 305),
    label('Legacy 48 px', 534, 305), label('Themed wing', 760, 305),
    label('Status bar at 24 px and 18 px', 28, 350),
    label('Light shade', 28, 500), label('Dark shade', 500, 500)];
  for (const [left, round] of [[28, 110], [280, 48]]) {
    const mask = Buffer.from(`<svg width="220" height="220"><rect width="220" height="220" rx="${round}" fill="white"/></svg>`);
    parts.push({ input: await sharp(visible).resize(220, 220).composite([{ input: mask, blend: 'dest-in' }]).png().toBuffer(), left, top: 56 });
  }
  parts.push({ input: await fs.readFile(path.join(root, 'android/app/src/main/res/mipmap-mdpi/ic_launcher.png')), left: 558, top: 137 });
  const themedWing = await sharp(Buffer.from(wing.replace('#FFFFFF', '#146B53'))).resize(120, 120).png().toBuffer();
  parts.push({ input: await sharp({ create: { width: 196, height: 196, channels: 4, background: '#E3F2EC' } })
    .composite([{ input: themedWing, left: 38, top: 38 }]).png().toBuffer(), left: 756, top: 68 });
  const panel = Buffer.from('<svg width="944" height="180"><rect width="452" height="100" rx="8" fill="white"/><rect x="472" width="472" height="100" rx="8" fill="#182621"/></svg>');
  parts.push({ input: panel, left: 28, top: 370 });
  for (const [left, color] of [[52, '#146B53'], [524, '#FFFFFF']]) {
    for (const [offset, pixels] of [[0, 24], [60, 18]]) {
      parts.push({ input: await sharp(Buffer.from(wing.replace('#FFFFFF', color))).resize(pixels, pixels).png().toBuffer(), left: left + offset, top: 390 });
    }
  }
  parts.push({ input: Buffer.from(`<svg width="1000" height="510">${labels.join('')}</svg>`), left: 0, top: 0 });
  await write('build/design-previews/icon-production-proof.png',
    await sharp({ create: { width: 1000, height: 550, channels: 4, background: '#F4F7F6' } }).composite(parts).png().toBuffer());
  console.log('Generated launcher density assets, store icon, notification vector and themed wing.');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
