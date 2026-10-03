# Aloud for Mac: the airplane check

A short check to do yourself before and during a flight. It covers what the
automated tests can't: real sound, real headphones, a real lid and a real
battery (mac PRD M4, M17, M19). Use the **Release build, named Aloud**. Aloud
Dev, the Debug build, starts muted outside Xcode, so you would hear nothing.

## Before you board (online)

- [ ] Open Aloud, then **Aloud › Settings… (⌘,) › Voice & speed**.
- [ ] Natural voice card: click **Download**. It is 353 MB, once.
  - On a phone's hotspot or Low Data Mode, Aloud asks first ("Download 353 MB
    on a metered connection?"). Prefer Wi-Fi.
- [ ] Wait until the card reads **"Natural voice installed"** and
      **"353 MB on this Mac · works offline"**.
- [ ] Optional: under the voice list, **Add voices in System Settings…**
      opens Spoken Content, where you can download a better System voice as
      a fallback.
- [ ] Add a PDF you want on the flight: **File › Add from Files… (⌘O)**. It
      is copied into Aloud, so it opens later even if it lives in OneDrive.
- [ ] Charge to at least 80% if you plan to measure the battery (below).

## On the plane (Wi-Fi off)

- [ ] Quit Aloud (⌘Q). Turn Wi-Fi off in Control Center and unplug any
      Ethernet cable, then open Aloud. Nothing in it should complain, spin
      or show an alert.
- [ ] Optional: in Terminal, run `nettop -P -p Aloud`. It should list no
      sockets for Aloud the whole time. Press `q` to quit.
- [ ] Settings › Voice & speed shows "Natural voice installed". If it reads
      "Connect to the internet to download." (Download greyed out) or
      "Download paused · waiting for Wi-Fi or Ethernet", the install didn't
      finish. That is honest, but it means only the System voice for this
      flight.
- [ ] Put on headphones.
- [ ] Open a classic: **File › Add a Classic… (⇧⌘O)**, pick one, listen in
      Michael for about 5 minutes.
- [ ] With Wi-Fi still off, add a PDF saved on this Mac with ⌘O. It should
      open and start reading. Then open the PDF you added before boarding.
      Listen to each for a minute.
- [ ] Open the voice chip and try each of the 9 voices. Each one should
      speak with no network.
- [ ] Unplug wired headphones, or switch Bluetooth ones off, while it
      reads. Expect it to stop, with nothing from the Mac's speakers and
      **"Paused · headphones disconnected"** on the chapter line. One click
      on Play goes on from the same sentence.
      (Taking AirPods out of your ears is an ordinary pause, with no
      message.)
- [ ] Close the lid while it reads, wait a few seconds, then open it. Expect
      **"Paused · your Mac went to sleep"**. Play goes on from the same
      sentence.
- [ ] Quit (⌘Q) while paused, reopen Aloud, and open the Continue card. It
      should come back to the same sentence.
- [ ] You should not see the "Natural voice · 353 MB, once" offer anywhere
      while offline.

## The budgets (M19)

Measure on battery, with a stopwatch or a screen recording.

| Measure | Budget | How |
|---|---|---|
| Launch | ≤ 1.0 s | Quit Aloud, then time from the Dock click to the Library you can click. |
| First audio, warm | ≤ 1.0 s | While Michael reads, pause for a few seconds, then time from Play to the first word. |
| First audio, cold | ≤ 3.5 s | Quit and reopen, press Play at once, and time to the first word. "Preparing voice…" may show after 0.8 s. |
| Battery | ≤ 5% above idle per hour | Note the battery %, then listen in Michael for 60 min with the display off. Do the same for 60 min with Aloud paused. The listening hour may use at most 5 points more. |

Let the display turn off on its own, or lock the screen (⌃⌘Q). Don't close
the lid, because that sleeps the Mac and stops playback.

Record each number, the Mac model and the macOS version in the **Build
Updates doc, "Mac build" tab**. Note any measure over its budget.

## If something fails

Write down what you did, the exact words on screen, and the time, and add
it to the Build Updates doc. Keep Wi-Fi off if you try again: with it on,
the problem may not show.
