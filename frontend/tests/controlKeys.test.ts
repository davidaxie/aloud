// H027 / H034 / H037 / H066: the transport keys, the play button's name, the
// position slider and the voice list. Pure decisions plus the wiring that uses
// them; no DOM, no audio.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import {
  globalShortcut,
  listKeyTarget,
  playButtonLabel,
  positionKeyTarget,
  positionValueText,
} from '../src/lib/controlKeys.ts'

const source = (path: string) => readFileSync(new URL(`../src/${path}`, import.meta.url), 'utf8')

test('H027: a button the mouse left focused does not keep Space or the arrows', () => {
  // Chrome focuses Next on click; Space must pause, not skip again.
  assert.equal(globalShortcut(' ', 'button', false), 'toggle')
  assert.equal(globalShortcut('Spacebar', 'button', false), 'toggle')
  // Buttons have no arrow behaviour: ←/→ step sentences even with one focused.
  assert.equal(globalShortcut('ArrowRight', 'button', false), 'next')
  assert.equal(globalShortcut('ArrowLeft', 'button', true), 'prev')
  // A button reached with Tab still presses on Space.
  assert.equal(globalShortcut(' ', 'button', true), null)
})

test('H027: Space plays or pauses from the sliders, which keep their arrows', () => {
  assert.equal(globalShortcut(' ', 'track', true), 'toggle')
  assert.equal(globalShortcut(' ', 'range', false), 'toggle')
  assert.equal(globalShortcut('ArrowRight', 'track', true), null)
  assert.equal(globalShortcut('ArrowLeft', 'range', true), null)
})

test('H027: fields and lists keep their keys; elsewhere the transport keys work', () => {
  assert.equal(globalShortcut(' ', 'typing', false), null)
  assert.equal(globalShortcut('ArrowRight', 'typing', false), null)
  assert.equal(globalShortcut('ArrowRight', 'composite', false), null)
  assert.equal(globalShortcut(' ', 'other', false), 'toggle')
  assert.equal(globalShortcut('ArrowLeft', 'other', false), 'prev')
  assert.equal(globalShortcut('Enter', 'other', false), null)
})

test('H027: the global handler asks controlKeys, with the target’s keyboard focus', () => {
  const src = source('hooks/useKeyboard.ts')
  assert.match(src, /globalShortcut\(/)
  assert.match(src, /:focus-visible/)
  assert.doesNotMatch(src, /isSelfHandlingControl/, 'every key on a button was dropped')
})

test('H034: while buffering the play button is named Pause, since a press pauses', () => {
  assert.deepEqual(playButtonLabel('buffering'), {
    label: 'Pause',
    title: 'Pause (Space)',
    busy: true,
  })
  assert.equal(playButtonLabel('playing').label, 'Pause')
  assert.equal(playButtonLabel('playing').busy, false)
  for (const status of ['ready', 'paused', 'ended', 'error'] as const) {
    assert.equal(playButtonLabel(status).label, 'Play')
  }
})

test('H034: the play button uses that name and announces the wait', () => {
  const src = source('components/PlayerBar.tsx')
  assert.match(src, /aria-label=\{playButton\.label\}/)
  assert.match(src, /aria-busy=\{playButton\.busy\}/)
  assert.doesNotMatch(src, /aria-label=\{isPlaying \?/)
  assert.match(src, /aria-live="polite"/)
})

test('H037: the position slider takes Home, End, the Page keys and all four arrows', () => {
  const total = 5000
  assert.equal(positionKeyTarget('Home', 2400, total), 0)
  assert.equal(positionKeyTarget('End', 2400, total), 4999)
  assert.equal(positionKeyTarget('PageDown', 2400, total), 2650)
  assert.equal(positionKeyTarget('PageUp', 2400, total), 2150)
  assert.equal(positionKeyTarget('ArrowRight', 2400, total), 2401)
  assert.equal(positionKeyTarget('ArrowUp', 2400, total), 2401)
  assert.equal(positionKeyTarget('ArrowLeft', 2400, total), 2399)
  assert.equal(positionKeyTarget('ArrowDown', 2400, total), 2399)
  assert.equal(positionKeyTarget('a', 2400, total), null)
})

test('H037: slider steps are clamped, and a short book still moves a sentence a page', () => {
  assert.equal(positionKeyTarget('PageUp', 30, 5000), 0)
  assert.equal(positionKeyTarget('PageDown', 4990, 5000), 4999)
  assert.equal(positionKeyTarget('ArrowLeft', 0, 5000), 0)
  assert.equal(positionKeyTarget('PageDown', 3, 10), 4)
  assert.equal(positionKeyTarget('Home', -1, 10), 0)
  assert.equal(positionKeyTarget('End', 0, 0), null)
})

test('H037: the slider says which sentence and page, not a bare number', () => {
  assert.equal(positionValueText(57, 5000, 3), 'Sentence 57 of 5000, page 3')
  assert.equal(positionValueText(57, 5000), 'Sentence 57 of 5000')
  assert.equal(positionValueText(0, 5000), 'Sentence 1 of 5000')
  const src = source('components/PlayerBar.tsx')
  assert.match(src, /aria-valuetext=\{positionValueText\(/)
  assert.match(src, /positionKeyTarget\(e\.key/)
})

test('H066: the voice list moves focus with the arrows, Home and End', () => {
  assert.equal(listKeyTarget('ArrowDown', -1, 54), 0, '↓ from the search field enters the list')
  assert.equal(listKeyTarget('ArrowDown', 3, 54), 4)
  assert.equal(listKeyTarget('ArrowDown', 53, 54), 53)
  assert.equal(listKeyTarget('ArrowUp', 3, 54), 2)
  assert.equal(listKeyTarget('ArrowUp', 0, 54), 0)
  assert.equal(listKeyTarget('Home', 9, 54), 0)
  assert.equal(listKeyTarget('End', 9, 54), 53)
  assert.equal(listKeyTarget('ArrowUp', -1, 54), null)
  assert.equal(listKeyTarget('ArrowDown', -1, 0), null)
  assert.equal(listKeyTarget('Enter', 3, 54), null)
})

test('H066: closing a popover from the keyboard hands focus back to its chip', () => {
  const voices = source('components/VoicePicker.tsx')
  assert.match(voices, /ref=\{triggerRef\}/)
  assert.match(voices, /if \(hadFocus\) triggerRef\.current\?\.focus\(\)/, 'Escape')
  assert.match(voices, /setQuery\(''\)\s*triggerRef\.current\?\.focus\(\)/, 'choosing a voice')
  assert.match(voices, /onKeyDown=\{onListKey\}/)
  assert.match(voices, /aria-haspopup="dialog"/, 'the popup is a dialog, not a listbox')
  const options = source('components/OptionsMenu.tsx')
  assert.match(options, /ref=\{triggerRef\}/)
  assert.match(options, /if \(hadFocus\) triggerRef\.current\?\.focus\(\)/)
})
