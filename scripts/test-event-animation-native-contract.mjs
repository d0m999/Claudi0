// Exercise the native driver's real geometry validator without driving a desktop app.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {test} from 'node:test';

const driver = fs.readFileSync(new URL('./event-animation-native-regression.mjs', import.meta.url), 'utf8');
const view = fs.readFileSync(new URL('../gui/Sources/ClaudioSettingsPresentation/EventAnimationSettingsView.swift', import.meta.url), 'utf8');
// The view and a CUA-only script cannot share a compiled seam. Bind the fixture height
// to the production gallery, then execute the driver's existing assertion function.
const height = Number(view.match(/EventAnimationGallery\([\s\S]*?\.frame\(height: (\d+)\)/)?.[1]);
assert(Number.isFinite(height), 'Production gallery height must be available');
const start = driver.indexOf('function assertMatrix(');
const end = driver.indexOf('async function persistedAnimation()', start);
assert(start >= 0 && end > start, 'Native matrix validator must be available');
const styles = ['original', 'mechanicalDuck', 'pixelGhost', 'bitcoin'];
const validate = vm.runInNewContext(`(${driver.slice(start, end).trim()})`, {
  styles,
  assert: (value, message) => assert.ok(value, message),
});

function readback(index, cardHeight = height) {
  const container = {x: 0, y: 0, width: 800, height: 300};
  return {
    language: index <= 4 ? 'zh-Hans' : 'en',
    windowGeometry: {
      width: index % 2 === 0 ? 960 : 1240,
      height: index % 2 === 0 ? 640 : 820,
      appearance: index % 4 === 3 || index % 4 === 0 ? 'NSAppearanceNameDarkAqua' : 'NSAppearanceNameAqua',
    },
    settingsLayout: {
      sampleColorSpace: 'sRGB',
      frames: {
        'settings.animation.choices': container,
        'settings.content': container,
        'settings.reading.notifications': container,
        ...Object.fromEntries(styles.map((style, i) => [
          `settings.animation.style.${style}`, {x: i * 112, y: 10, width: 100, height: cardHeight},
        ])),
      },
    },
  };
}

test('native matrix accepts the production gallery height across all eight variants', () => {
  for (let index = 1; index <= 8; index++) {
    assert.equal(validate(readback(index), index).cards.length, 4);
  }
});

test('native matrix still rejects the retired height and clipped cards', () => {
  assert.throws(() => validate(readback(1, 153), 1), /invalid geometry/);
  const clipped = readback(1);
  clipped.settingsLayout.frames['settings.animation.style.bitcoin'].x = 790;
  assert.throws(() => validate(clipped, 1), /clipped/);
});
