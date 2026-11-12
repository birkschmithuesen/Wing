const tabs = [...document.querySelectorAll('[role="tab"]')];
const panels = [...document.querySelectorAll('[role="tabpanel"]')];
const stage = document.querySelector('.work-stage');

function selectTab(tab, pointerInitiated = false) {
  stage.dataset.pointerChange = String(pointerInitiated);
  for (const candidate of tabs) {
    const selected = candidate === tab;
    candidate.setAttribute('aria-selected', String(selected));
    candidate.tabIndex = selected ? 0 : -1;
  }
  for (const panel of panels) {
    panel.hidden = panel.id !== tab.getAttribute('aria-controls');
  }
}

for (const tab of tabs) {
  tab.addEventListener('click', event => selectTab(tab, event.detail > 0));
  tab.addEventListener('keydown', event => {
    let index = tabs.indexOf(tab);
    if (event.key === 'ArrowRight' || event.key === 'ArrowDown') index++;
    else if (event.key === 'ArrowLeft' || event.key === 'ArrowUp') index--;
    else if (event.key === 'Home') index = 0;
    else if (event.key === 'End') index = tabs.length - 1;
    else return;
    event.preventDefault();
    const next = tabs[(index + tabs.length) % tabs.length];
    selectTab(next);
    next.focus();
  });
}

const appearanceButtons = [...document.querySelectorAll('[data-theme]')];
for (const button of appearanceButtons) {
  button.addEventListener('click', () => {
    const theme = button.dataset.theme;
    for (const candidate of appearanceButtons) {
      candidate.setAttribute('aria-pressed', String(candidate === button));
    }
    for (const image of document.querySelectorAll('[data-app-image]')) {
      const path = `assets/screenshots/${image.dataset.appImage}-${theme}.png`;
      image.src = path;
      image.closest('[data-screenshot]').href = path;
    }
  });
}


// One viewer for every screenshot. Native dialog owns focus and background inertness.
let viewer;
let viewerImage;
let viewerScrim;
let activeThumbnail;
let closingViewer = false;
let viewerOperation = 0;
let viewerAnimations = [];
let viewerCloseTimer;
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const imageEase = getComputedStyle(document.documentElement).getPropertyValue('--ease-out').trim();

function createViewer() {
  if (viewer) return;
  viewer = document.createElement('dialog');
  viewer.className = 'screenshot-viewer';
  viewer.setAttribute('aria-label', 'Enlarged Wing screenshot');
  viewer.innerHTML = `<div class="viewer-scrim" aria-hidden="true"></div>
    <button class="viewer-picture" type="button" aria-label="Close enlarged screenshot" title="Close screenshot"><img class="viewer-image" alt=""></button>
    <button class="viewer-close icon-button" type="button" aria-label="Close enlarged screenshot" title="Close screenshot"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18"/></svg></button>`;
  document.body.append(viewer);
  viewerImage = viewer.querySelector('img');
  viewerScrim = viewer.querySelector('.viewer-scrim');
  viewer.addEventListener('click', event => closeScreenshot(event.detail > 0));
  viewer.addEventListener('keydown', event => {
    if (event.key !== 'Tab') return;
    const controls = [...viewer.querySelectorAll('button')];
    const first = controls[0];
    const last = controls.at(-1);
    if ((event.shiftKey && document.activeElement === first) || (!event.shiftKey && document.activeElement === last)) {
      event.preventDefault();
      (event.shiftKey ? last : first).focus({ preventScroll: true });
    }
  });
  viewer.addEventListener('cancel', event => {
    event.preventDefault();
    closeScreenshot(false);
  });
  addEventListener('resize', () => closeScreenshot(false));
}

function thumbnailTransform() {
  const source = activeThumbnail.querySelector('img').getBoundingClientRect();
  const target = viewerImage.getBoundingClientRect();
  const x = source.x + source.width / 2 - target.x - target.width / 2;
  const y = source.y + source.height / 2 - target.y - target.height / 2;
  return `translate(${x}px, ${y}px) scale(${source.width / target.width}, ${source.height / target.height})`;
}

function cancelViewerAnimations() {
  clearTimeout(viewerCloseTimer);
  for (const animation of viewerAnimations) animation.cancel();
  viewerAnimations = [];
}

async function openScreenshot(thumbnail, animate) {
  if (activeThumbnail) return;
  createViewer();
  const operation = ++viewerOperation;
  const image = thumbnail.querySelector('img');
  image.loading = 'eager';
  viewerImage.src = image.currentSrc || image.src;
  viewerImage.alt = image.alt;
  await viewerImage.decode();
  if (operation !== viewerOperation) return;
  viewerImage.width = viewerImage.naturalWidth;
  viewerImage.height = viewerImage.naturalHeight;
  activeThumbnail = thumbnail;
  closingViewer = false;
  viewer.setAttribute('aria-label', image.alt);
  viewer.showModal();
  viewer.querySelector('.viewer-close').focus({ preventScroll: true });
  const start = thumbnailTransform();
  thumbnail.style.visibility = 'hidden';
  if (animate && !reducedMotion.matches) {
    viewerAnimations = [
      viewerImage.animate([{ transform: start }, { transform: 'none' }], { duration: 260, easing: imageEase }),
      viewerScrim.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 220, easing: imageEase }),
    ];
  }
}

function closeScreenshot(animate) {
  if (!activeThumbnail || (closingViewer && animate)) return;
  closingViewer = true;
  const operation = ++viewerOperation;
  const currentTransform = getComputedStyle(viewerImage).transform;
  const currentOpacity = getComputedStyle(viewerScrim).opacity;
  cancelViewerAnimations();
  // Measure the resting image, not its in-flight rectangle.
  const end = thumbnailTransform();
  const finish = () => {
    if (operation !== viewerOperation) return;
    const thumbnail = activeThumbnail;
    viewer.close();
    cancelViewerAnimations();
    thumbnail.style.visibility = '';
    activeThumbnail = null;
    closingViewer = false;
    thumbnail.focus({ preventScroll: true });
  };
  if (!animate || reducedMotion.matches) {
    finish();
    return;
  }
  const duration = 180;
  viewerAnimations = [
    viewerImage.animate([{ transform: currentTransform }, { transform: end }], { duration, easing: imageEase, fill: 'forwards' }),
    viewerScrim.animate([{ opacity: currentOpacity }, { opacity: 0 }], { duration, easing: imageEase, fill: 'forwards' }),
  ];
  // The close action owns its duration; animation promises must not hold it open.
  viewerCloseTimer = setTimeout(finish, duration);
}

document.addEventListener('click', event => {
  const thumbnail = event.target.closest('[data-screenshot]');
  if (!thumbnail || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  event.preventDefault();
  openScreenshot(thumbnail, event.detail > 0);
});

document.addEventListener('keydown', event => {
  const thumbnail = event.target.closest('[data-screenshot]');
  if (!thumbnail || event.key !== 'Enter' || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  event.preventDefault();
  openScreenshot(thumbnail, false);
});

// The picture keeps its still-image link available while the GIF plays once.
for (const demo of document.querySelectorAll('[data-ripple-demo]')) {
  const source = demo.querySelector('[data-ripple-source]');
  const image = demo.querySelector('img');
  const replay = demo.querySelector('[data-ripple-replay]');
  const error = demo.querySelector('.ripple-error');
  let timer;
  let retireLoad = () => {};
  let sequence = 0;
  let played = false;

  function stop(failed = false) {
    clearTimeout(timer);
    retireLoad();
    source.removeAttribute('srcset');
    demo.setAttribute('aria-busy', 'false');
    replay.disabled = false;
    replay.hidden = reducedMotion.matches;
    error.hidden = !failed;
    replay.setAttribute('aria-label', failed ? 'Retry reply ripple animation' : 'Replay reply ripple animation');
    replay.title = replay.getAttribute('aria-label');
  }

  function play() {
    if (reducedMotion.matches || demo.getAttribute('aria-busy') === 'true') return;
    played = true;
    error.hidden = true;
    demo.setAttribute('aria-busy', 'true');
    replay.disabled = true;
    replay.setAttribute('aria-label', 'Playing reply ripple animation');
    replay.title = 'Playing reply ripple animation';
    const url = new URL('assets/screenshots/recents-arrival-dark.gif', document.baseURI);
    url.searchParams.set('play', String(++sequence));
    const preload = new Image();
    const ready = () => { source.srcset = url.href; };
    const loaded = () => {
      if (image.currentSrc !== url.href) return;
      retireLoad();
      clearTimeout(timer);
      timer = setTimeout(() => stop(), 4550);
    };
    const failed = () => stop(true);
    image.addEventListener('load', loaded);
    image.addEventListener('error', failed);
    preload.addEventListener('load', ready);
    preload.addEventListener('error', failed);
    retireLoad = () => {
      image.removeEventListener('load', loaded);
      image.removeEventListener('error', failed);
      preload.removeEventListener('load', ready);
      preload.removeEventListener('error', failed);
      preload.removeAttribute('src');
    };
    timer = setTimeout(() => stop(true), 15000);
    // Keep the still in place until the animation is ready to display.
    preload.src = url.href;
  }

  replay.hidden = reducedMotion.matches;
  replay.addEventListener('click', play);
  const observer = new IntersectionObserver(entries => {
    if (!played && entries.some(entry => entry.isIntersecting) && !reducedMotion.matches) play();
  }, { threshold: .35 });
  observer.observe(demo);
  reducedMotion.addEventListener('change', () => stop());
  document.addEventListener('visibilitychange', () => { if (document.hidden) stop(); });
  addEventListener('pagehide', () => { stop(); observer.disconnect(); });
}
