# Aloud audit report

The full audit run from `docs/MASTER-AUDIT-PROMPT.md`, on branch `claude/full-audit`. It covers the iPhone app, the Mac app and their shared core in `ios/`, the web app (`frontend/`), the browser extension (`extension/`), the local backend (`backend/`) and the tooling (`tools/`, build scripts).

## How it ran

1. **Wave 0, map.** Every source file was assigned to one of 20 review groups.
2. **Waves 1–3, full review.** Read-only hunters reviewed each group, ignoring style. Each reported finding went to a separate verifier, which was told to refute it and to confirm only with a concrete path a real user could hit. Rejected reports aren't listed here.
3. **Wave 4, fixes.** Batches of fixes were made in isolated worktrees. Each fix came with a test written to fail before it.
   - **Web, extension and backend:** the fixers ran their tests before and after the fix.
   - **Swift:** the fixers couldn't run Xcode, so their tests first ran in the full iPhone and Mac suite passes after each merge, and any failure there was repaired before the next step.

   Shared-code fixes cover both apps. Mac-only and iPhone-only fixes, and fixes split between the web app and the extension, got a twin on the other side where one applied, except the wave-4 twins listed under Known follow-ups.
4. **Wave 5, re-review.** A fresh, read-only review of the audit's own diff looked for bugs the fixes introduced, missed twins and unfinished edge cases. Its confirmed findings were fixed the same way.
5. **Loop.** A full review wave ran again over the whole repo, excluding everything already handled. The prompt's stop condition is two consecutive full waves with zero confirmed findings. It was not reached: after four full waves and three re-reviews, the owner chose to stop once the wave-4 fixes were in (see the trend below).

## Trend and why the loop stopped

| Wave | Confirmed | High | Medium | Low |
|---|---|---|---|---|
| Full review 1 | 105 | 13 | 59 | 33 |
| Re-review of the loop-1 fixes | 35 | 1 | 20 | 14 |
| Full review 2 | 68 | 2 | 37 | 29 |
| Re-review of the loop-3 fixes | 26 | 0 | 11 | 15 |
| Full review 3 | 48 | 6 | 26 | 16 |
| Re-review of the loop-4 fixes | 28 | 0 | 21 | 7 |
| Full review 4 | 48 | 3 | 26 | 19 |

No wave found anything critical. The full reviews fell from 105 to 68 to 48, then held at 48. Each re-review of a round's own fixes found 26 to 35 more, which is the cost of changing this much code at once.

At that rate, two consecutive clean full waves would take many more rounds. Each fresh review of a codebase this size still turns up about fifty real, mostly medium or low, issues.

The owner chose to stop after the wave-4 fixes. Those fixes did not get a re-review, which would be the first step of any further round. Merging them took four repairs, all committed with them:
- one Mac line that didn't compile;
- a Mac-only key handler outside the platform layer;
- a card test that still expected the old text limits;
- a selection-key gap.

## Final test results

On the final commit of `claude/full-audit`:

| Suite | Tests | Result |
|---|---|---|
| Mac (AloudMacTests, hosted in Aloud Dev) | 1,819 | pass |
| iPhone (AloudTests, simulator) | 1,916 | pass |
| Web app (`frontend`) | 139 | pass, plus typecheck and build |
| Extension (`extension`) | 84 | pass, plus typecheck and build |
| Backend (`backend`) | 119 | pass |
| Tools (`tools`) | 68 | pass |

The UI test targets were not run in this audit, because they drive the apps on screen.

## Counts

| Wave | Confirmed | Fixed | Deferred | Needs you | Left as designed |
|---|---|---|---|---|---|
| Loop 1: waves 1-3 (full review) | 105 | 96 | 5 | 3 | 1 |
| Loop 2: wave 5 re-review of the loop-1 fixes | 35 | 35 | 0 | 0 | 0 |
| Loop 3: full review wave 2 | 68 | 67 | 1 | 0 | 0 |
| Loop 4: wave 5 re-review of the loop-3 fixes | 26 | 26 | 0 | 0 | 0 |
| Loop 4: full review wave 3 | 48 | 45 | 2 | 1 | 0 |
| Loop 5: wave 5 re-review of the loop-4 fixes | 28 | 28 | 0 | 0 | 0 |
| Loop 5: full review wave 4 | 48 | 48 | 0 | 0 | 0 |
| **Total** | **358** | **345** | **8** | **4** | **1** |

Six findings were reported twice by different reviewers and fixed once: H042 and H055, H043 and H057, I002 and I014, I005 and I010, K005 and K007, and K014 and K021. Both copies of each pair are counted above.

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 25 |
| Medium | 200 |
| Low | 133 |

| Area | Confirmed findings |
|---|---|
| Shared iPhone/Mac core and iPhone app | 181 |
| Mac app | 50 |
| Web app | 45 |
| Browser extension | 39 |
| Backend | 33 |
| Tooling and release | 10 |

## Needs you

These need a decision or an action from the owner. Code can't settle them.

1. **espeak-ng licence (F008, high).** sherpa-onnx statically links espeak-ng (GPL-3.0) into both apps, and both bundles ship its data. Neither bundle carries the GPL text. The only source pointer, on the Licenses page, sends readers to the upstream espeak-ng project rather than the fork sherpa-onnx actually links, and there is no written offer of the source. There are three options:
   - Ship the GPL text with a written source offer for the fork, and accept what GPL-3.0 means for the app.
   - Switch Kokoro's phonemizer to one under a permissive licence.
   - Drop Kokoro from the shipping build.
2. **Licence notices (F051, medium).** The Release binary also statically links:
   - protobuf and re2 (BSD-3)
   - abseil, OpenFst and kaldi (Apache-2.0)
   - flatbuffers (MIT)
   - Eigen (MPL-2.0)

   The BSD, Apache and MIT terms, ONNX Runtime's included, require their notice text to ship with the binary. MPL-2.0 requires saying where Eigen's source is. The Licenses page lists four components by licence name, with no text. Add the full notices, or confirm which libraries the shipping build really links.
3. **iPhone Debug bundle id (F009, high).** The iPhone Debug and Release builds share `com.davidxie.Aloud`, so they share one data container. Running the Aloud scheme's tests on the iPhone you read on installs over that app, and the UI tests' library reset wipes its library. The README's own install route is a Debug build, so this applies today. Give Debug its own id (for example `com.davidxie.Aloud.dev`); this changes signing and provisioning, which is your call. The Mac already separates them.
4. **Bookshelf fetcher (F028, F055, F084, F085, F086, H015, J015, J016).** All eight are in `tools/gutenberg_fetch.py`, which another session has uncommitted edits to. They were deferred rather than risk a conflict:
   - Windows-1252 decoding.
   - Leftover "Project Gutenberg" text inside 30 bookshelf books, which matters for the Gutenberg trademark licence.
   - Worktree paths.
   - Failures not counting toward `--count`.
   - Lock staleness.
   - Duplicate queue entries producing a catalog that the bookshelf sync then refuses.
   - A 200 response that isn't the book stops the fetcher from trying the other mirror patterns.
   - Download failures logged by exception class only, with no HTTP status or reason.
5. **Dev-server advisories (documented, not fixed).**
   - **Web app, vite (rated high overall):** the full `npm audit` reports three advisories against vite 5.4.21:
     - a `server.fs.deny` bypass on Windows (high)
     - path traversal in optimized-deps `.map` handling (moderate)
     - a launch-editor UNC-path issue on Windows (moderate)
   - **Web app, esbuild 0.21.5 (moderate):** any website can send requests to the dev server.
   - **Extension, esbuild 0.24.2 (moderate):** the same advisory (GHSA-67mh-4wv8-2f99). It covers esbuild's serve mode, which `extension/build.mjs` never uses.

   All of them affect only development servers. None reaches the built app or the built extension, and `npm audit --omit=dev` is clean in both. The fix is a major upgrade from Vite 5 to Vite 6.4.3 or later (npm itself suggests Vite 8), plus esbuild past 0.24 in the extension. That needs `npm install` in the main checkout and a check of both builds. Until then, don't run `npm run dev`, or `./run.sh` (which starts it), while browsing untrusted sites.
6. **Release signing team (J030, low).** The Mac target signs ad hoc (`CODE_SIGN_IDENTITY "-"`) for every configuration, and `ios/xcb.sh` adds it to every Mac build, so a Release archive has no Team ID and can't be uploaded or notarized. The iPhone target names no team either, and `xcodegen generate` wipes a team picked in Xcode. Set `DEVELOPMENT_TEAM` (and, for the Mac, an Apple Distribution or Developer ID identity) under the Release configuration in `ios/project.yml`, and keep ad hoc signing for Debug and the hosted tests. Only you have the team ID.
7. **F035 (left as designed).** In very long books, a Mac text-size step lays the text out from the start of the book to the reading place. That full layout is what keeps the place exact, and it only costs noticeable time near the end of very long books.

## Known follow-ups

The wave-4 fixes were not re-reviewed, because the loop stopped there. Their fixers flagged these gaps. Each one is small, and none was verified by a separate reviewer:

- **Web and extension twins of wave-4 fixes:**
  - The web and extension word-weight estimates count only a-z letters (L013).
  - The extension's read-along word test is ASCII-only (L036).
  - The web PDF text path still folds vulgar fractions and superscripts (L031).
  - Both clients' chunkers can cut between the two halves of an emoji or other astral character (L037, client side).
  - The web header pass labels pages from a stitched paragraph's first page (L009).
  - The web two-column split still breaks into bands at any line crossing the gutter (K016).
- **Extension clicks:**
  - The extension bar's position track seeks on any mouse button (the L039 twin).
  - Its click-to-jump still jumps on the first click of a double-click that selects a word. A drag-selection is already ignored (the L033 twin).
- **Extension page events (L047):** the reader's `pagehide` listener still tears down on any event. Page code that dispatches a fake `pagehide` can still stop the reader and lose its place, the scenario L047 closed for clicks, Escape and takeover.
- **Extension modals and storage:**
  - A modal hidden with `aria-hidden` or `inert` still counts as open for the page-Escape check (K009).
  - Content scripts can still write the stored backend URL, which is now limited to loopback addresses (L043). Locking `chrome.storage.local` to trusted contexts first needs the synced prefs' local fallback moved.
- **Suspended hyphens on iPhone and Mac:** at a line break, "first-⏎and second-class" comes out as "first-and second-class" with no space. The backend and web app keep "first- and" (J032, K006).
- **Locked files added before this fix:** books imported from Finder-locked files before L004 still keep their locked copy when deleted. Delete and the orphan sweep should clear the flag before removing files.
- **Unreadable-library wording:** the alerts for an unreadable library ("Update Aloud, then try again") don't yet match the new Library notice (L011).
- **iPhone colophon label:** the iPhone's VoiceOver label still reads the colophon after scrolling back from the end of a finished book. The Mac was fixed in J023.
- **Language detection is per book:** a French quotation inside an English book is still read by the English System voice (L003). This was on purpose, so an English book never changes voice mid-way.
- **Now Playing while buffering:** the lock screen and Now Playing scrubber move on while a sentence buffers, then snap back when its audio starts (L025). That's the cost of showing Pause instead of Play.
- **Backend voices:**
  - Japanese voices are left out of `/voices` through a hard-coded list (`_UNSPEAKABLE_LANGS` in `backend/voices.py`) until the engine gains a Japanese phonemizer such as misaki[ja] or pyopenjtalk (L032). Clients that saved a Japanese voice now get the default voice, and the web voice picker still has Japanese labels.
  - Mandarin still has small espeak gaps.
  - `legacy/build_web_app.sh` does not check that the models exist before packaging.
- **Thermal switch notice:** when the phone heats up and Aloud hands the book to the System voice to cool down, a System-voice failure posts the "natural voice unavailable" notice, although the natural voice keeps reading. The cooling switch also stays marked pending. A fixer flagged this in loop 4; it was not verified.
- **Extension popup wording:** the popup says a rejected backend URL snaps back to the stored one, but it snaps back to the default.

### Worth checking by hand

These depend on real browser, trackpad or VoiceOver behaviour that the automated tests can only model:

- **Extension on strict pages (J039):** reading and pause/resume on a page with a strict security policy, such as a github.com README, at 1x and 2x.
- **Web app Space key (I021):** pressing Space right after clicking a button.
- **Web app media keys (J036, K013):** the hardware play/pause key while a sentence is buffering.
- **Mac Force Click (J022, K025):** a Force Click on a word shows its definition and never starts playback.
- **Mac Contents (I013, L024):** VoiceOver announcements on the keyboard cursor.

## Dependency audits

- **Backend:** `pip-audit --path` over the backend venv's 59 installed distributions reports no known vulnerabilities. `backend/requirements.txt` pins the direct dependencies and applies `backend/constraints.txt` (L042), which pins every installed distribution at its tested version. Neither file has hashes yet. `download_models.py` checks each model file's size and pinned SHA-256 (H063).
- **Web app and extension:** `npm audit --omit=dev` finds 0 vulnerabilities in both. The full `npm audit` finds only the dev-server advisories in Needs you, item 5.
- **Apps:** the only third-party code is sherpa-onnx (with onnxruntime-libs) through Swift Package Manager. `ios/project.yml` asks for `from: 1.13.6`, and the committed `Package.resolved` pins sherpa-onnx 1.13.6 (revision 1cb484af) and onnxruntime-libs 1.27.1. The Kokoro model files are checked against pinned SHA-256 hashes before they load.

## Re-running the checks

From the repository root:

```bash
cd ios && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /opt/homebrew/bin/xcodegen generate
```

```bash
cd ios && ./xcb.sh -project Aloud.xcodeproj -scheme AloudMac test
```

```bash
cd ios && ./xcb.sh -project Aloud.xcodeproj -scheme Aloud CODE_SIGNING_ALLOWED=NO -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:AloudTests test
```

```bash
cd backend && .venv/bin/python -m unittest discover -s tests
```

```bash
python3 -m unittest tools.test_gutenberg_fetch tools.test_catalog_normalize tools.test_build_scripts
```

```bash
cd frontend && npm run typecheck && npm test && npm run build
```

```bash
cd extension && npm run typecheck && npm test && npm run build
```

```bash
cd backend && uvx pip-audit --path .venv/lib/python3.12/site-packages
```

```bash
cd frontend && npm audit --omit=dev && npm audit
```

```bash
cd extension && npm audit --omit=dev && npm audit
```

The Mac tests run inside a separate Debug build, Aloud Dev, so they never touch the installed app's library. None of the tests play audio aloud. The measurement tests that write sample files run only with `TEST_RUNNER_ALOUD_PERF=1`.

## Security findings

Every finding the verifiers classed as security, plus F050 (the request-size bound that F053, F054, G030 and L034 build on), and how each was closed.

#### F050 · Medium · Backend

**POST /synthesize has no limit on text length or body size, so one request can occupy the single synthesis worker for hours and use memory in proportion to the text until the machine runs out.**

- **Where:** `backend/app.py:90` (crash)
- **Scenario:** `text: str` has no max length (app.py:90), and the only check is that the text is not empty (app.py:188). kokoro_onnx `create()` splits the phonemes into any number of 510-phoneme batches and joins all the audio in memory. That is about 6.4 KB of float32 per input character at speed 1.0, twice that at speed 0.5.
- **Root cause:** Nothing on the request path limits size. `SynthesizeRequest.text` and `voice` are plain `str` fields with no `max_length` (backend/app.py:90-91).
- **Fix:** POST /synthesize now rejects text over MAX_TEXT_CHARS=2000 with 413 and a voice id over MAX_VOICE_CHARS=64 with 400. Both answer retryable=false, so the frontend and the extension skip the sentence.
- **Test:** backend/tests/test_app_requests.py InputLimitTests (test_text_over_the_limit_is_413_and_never_queued, test_text_at_the_limit_is_synthesized, test_overlong_voice_is_400_and_never_queued, test_declared_oversized_body_is_413, test_streamed_oversized_body_without_length_is_413, test_small_streamed_body_still_reaches_the_handler)
- **Commit:** `c2ab14a`

#### F053 · Medium · Backend

**The documented launcher binds the unauthenticated TTS server to 0.0.0.0 by default, so every device on the same Wi-Fi can use it, while run.sh and the README say it runs on localhost.**

- **Where:** `backend/run.py:26` (security)
- **Scenario:** README.md:235 tells users to run ./run.sh, and run.sh:29 prints 'Starting TTS backend on http://localhost:8000'. run.sh then runs run.py without ALOUD_HOST, so HOST = '0.0.0.0'. On café or office Wi-Fi, any peer can reach http://<mac-ip>:8000/synthesize with no auth and send the oversized-text request above, which hangs or kills the user's reader.
- **Root cause:** backend/run.py:26 binds to 0.0.0.0 unless ALOUD_HOST is set. run.sh:30 launches run.py without setting ALOUD_HOST, yet run.sh:29 and README.md:235 tell the user the server is on localhost. The 0.0.0.0 default has been there since the first commit (8475d6d), and the docstring at run.py:13-14 even admits the server is on the LAN by default.
- **Fix:** run.py now defaults to HOST=127.0.0.1, and ALOUD_HOST=0.0.0.0 is an explicit opt-in. The docstring now says LAN use also needs ALOUD_ALLOWED_HOSTS because of the F054 host check. run.sh prints the real port.
- **Test:** backend/tests/test_launchers.py RunHostTests.test_default_bind_is_loopback, test_lan_is_an_explicit_opt_in
- **Commit:** `c2ab14a`

#### F054 · Medium · Backend

**CORS allows every origin with every method and header, and the Host header is never checked, so any web page the user visits can drive POST /synthesize on the user's machine.**

- **Where:** `backend/app.py:78` (security)
- **Scenario:** allow_origins=['*'], allow_methods=['*'] and allow_headers=['*'] mean the preflight for a JSON POST from https://any-site.example succeeds. A page can then call fetch('http://localhost:8000/synthesize', {method:'POST', headers:{'Content-Type':'application/json'}, body: hugeText}) and set off the oversized-text CPU and memory exhaustion while the user is only browsing.
- **Root cause:** backend/app.py:78-84 uses CORSMiddleware with allow_origins=["*"], allow_methods=["*"] and allow_headers=["*"]. No TrustedHostMiddleware or Host check exists anywhere in the backend.
- **Fix:** Fixed in backend/app.py. TrustedHostMiddleware refuses any Host other than localhost, 127.0.0.1 or a name listed in ALOUD_ALLOWED_HOSTS, so a DNS-rebinding page is turned away before synthesis. CORS allows only GET and POST with a Content-Type header, from origins matching http://localhost or http://127.0.0.1 on any port, any chrome-extension:// origin (added in ec088af), or ALOUD_CORS_ORIGINS.
- **Test:** backend/tests/test_app_requests.py LocalOnlyTests (test_preflight_from_another_site_is_refused, test_preflight_from_the_dev_server_is_allowed, test_lookalike_origin_is_refused, test_rebound_host_is_refused_before_synthesis, test_loopback_hosts_are_served)
- **Commit:** `c2ab14a`

#### G030 · Low · Backend

**The cross-site fix (F054) relies on FastAPI's strict_content_type default to refuse a JSON body sent with no Content-Type. requirements.txt still allows fastapi>=0.115, and older releases parse such a body as JSON.**

- **Where:** `backend/requirements.txt:4` (security)
- **Scenario:** On a venv with an older FastAPI that requirements.txt still permits, the user visits a hostile page. It runs fetch('http://localhost:8000/synthesize', {method:'POST', mode:'no-cors', body:new Blob([JSON.stringify({text:'x'.repeat(2000)})])}) in a loop.
- **Root cause:** The F054 cross-site fix only holds because FastAPI 0.132.0 and later default strict_content_type to True. backend/requirements.txt:4 still reads fastapi>=0.115, and every release from 0.115.0 to 0.131.0 parses a body with no Content-Type as JSON. I ran the current backend/app.py, with its CORS, TrustedHost and _BodySizeLimit middleware, under FastAPI 0.131.0 and Starlette 0.52.1.
- **Fix:** Took the preferred route: the /synthesize handler now checks Content-Type itself. Anything other than application/json or application/*+json, parameters ignored, gets 415 with retryable false before enqueue.
- **Test:** test_app_requests.ContentTypeTests.test_untyped_body_is_refused_even_when_the_framework_parses_it (mounts the real handler on FastAPI(strict_content_type=False) to reproduce FastAPI < 0.132; before the fix it returned 200 and synthesized), ContentTypeTests.test_untyped_body_never_reaches_the_worker, ContentTypeTests.test_json_with_a_charset_is_served
- **Commit:** `ec088af`

#### H033 · Medium · Extension

**The player bar is built in an open shadow root, and its handlers act on untrusted (script-dispatched) events.**

- **Where:** `extension/src/content/ui.ts:342` (security)
- **Scenario:** A hostile page waits for the Aloud bar to appear. It then adds <option value="xxxx…(65+ chars)"> to the voice select inside the open shadow root, selects it, and dispatches a 'change' event. onVoice calls savePrefs({voiceId}), which syncs to every tab and every signed-in Chrome profile.
- **Root cause:** The core claim holds. A page script can write any voiceId into the extension's synced settings, and that breaks the reader on every site until the user picks a voice again.
- **Fix:** The bar and the toast use attachShadow({mode:'closed'}), and only the private PlayerBar.root keeps a reference. Every bar handler (click, track pointerdown, voice and rate change) ignores events whose isTrusted is false. onVoice saves only a voice from the engine's roster, and prefs sanitize() replaces any voiceId longer than 64 characters (the backend's MAX_VOICE_CHARS) with the default.
- **Test:** extension/tests/content.test.mjs: 'H033: the page can neither reach into the bar nor work it with events it dispatches' and 'H033: a voice id past the backend limit is never kept, so it cannot stop every reader'. Both fail on e4d1e5a and pass now.
- **Commit:** `ed6b07a`

#### H063 · Low · Backend

**Several backend dependencies are open-ended, with no lock file and no hashes: fastapi>=0.115, uvicorn[standard]>=0.30 and pywebview>=5.0, plus every transitive package (starlette, pydantic...**

- **Where:** `backend/requirements.txt:4` (security)
- **Scenario:** With the documented `uv pip install -r requirements.txt` (README:227), a fresh install pulls whatever versions are newest that day, unverified, so a broken or compromised release of any of them is installed and run. A venv built when fastapi 0.115 was current keeps that old FastAPI/Starlette for good, because the floor is already met; app.py:335 has to code around exactly that. download_models.py:46 skips re-downloading any kokoro-v1.0.onnx or voices-v1.0.bin whose size is within 5%, whatever its contents.
- **Root cause:** The facts in the report are correct, but the impact is overstated. This is a hardening gap in the legacy, localhost-only web backend.
- **Fix:** requirements.txt now pins fastapi==0.141.1, uvicorn[standard]==0.52.4 and pywebview==6.2.1, the versions installed in the main backend/.venv (read from its dist-info, since that venv has no pip). There are no hashes, because generating them needs the network. download_models.py now pins each asset's exact size and SHA-256 and checks both before skipping a file and after downloading it.
- **Test:** backend/tests/test_launchers.py ModelDownloadTests: test_backend_requirements_are_pinned, test_right_sized_wrong_file_is_fetched_again, test_matching_file_is_skipped, test_download_that_does_not_match_is_deleted, test_real_assets_pin_a_sha256
- **Commit:** `809fd19`

#### J047 · Low · Extension

**The 'activate' message, meant for the popup only, is accepted from any sender, including content scripts running in web-page renderers, and acts on whatever msg.tabId it names.**

- **Where:** `extension/src/background/index.ts:424` (security)
- **Scenario:** A page where the reader was injected has its renderer compromised. It sends chrome.runtime.sendMessage({kind:'activate', tabId: <another tab>, action:'start'}). dispatch() runs executeScript and sends a command into any other tab where the extension has access (a localhost tab via host_permissions, or a tab with a live activeTab grant).
- **Root cause:** The finding is accurate, but it is defence in depth only. It can be triggered only from a compromised renderer: an attacker needs a Chrome renderer exploit in a tab where the reader was already injected.
- **Fix:** The worker's 'activate' case now accepts only messages from the extension's own popup: no sender.tab, sender.id equal to chrome.runtime.id, and a sender.url (without query or hash) equal to chrome.runtime.getURL('popup.html'). Any other sender gets {ok:false} and nothing is injected or sent.
- **Test:** extension/tests/background.test.mjs: 'J047: only the popup may activate a tab, not a content script in a page'
- **Commit:** `af3c97d`

#### L034 · Medium · Backend

**The F050 bound is incomplete.**

- **Where:** `backend/app.py:350` (security)
- **Scenario:** Measured: 'ﷺ' (U+FDFA) expands under NFKC to 18 characters and phonemizes to 66 phonemes per input character, where normal text gives about 1.7. A request with 2,000 of them is 6 KB and passes the 2,000-character check.
- **Root cause:** I could not refute it. The F050 bound is incomplete. backend/app.py:350 checks len(req.text) (code points) before anything else runs.
- **Fix:** phoneme_batches.MAX_PHONEMES = 6000, with check_length raising TooLongError (a ValueError subclass) after phonemize and before any create(). app.py maps it to 413 with retryable=false. SynthQueue tracks the in-flight job and exposes in_flight_cancelled(). app._synthesize passes it as should_stop to engine.synthesize, which checks it between split_for_model pieces and raises JobCancelledError.
- **Test:** backend/tests/test_phoneme_batches.py: LengthTests, EngineTests.test_text_that_phonemizes_too_long_never_reaches_the_model, test_a_job_told_to_stop_skips_the_rest, test_a_job_never_told_to_stop_runs_in_full; backend/tests/test_app_requests.py: PhonemeBoundTests (413 not retryable; worker passes should_stop); backend/tests/test_synth_queue_cancel.py: test_in_flight_job_is_told_its_client_left, test_a_live_in_flight_job_is_not_cancelled
- **Commit:** `ee8c430`

#### L042 · Low · Backend

**The H063 fix is incomplete.**

- **Where:** `backend/requirements.txt:4` (security)
- **Scenario:** I checked the installed metadata. fastapi 0.141.1 requires 'starlette>=0.46.0' and 'pydantic>=2.9.0'. kokoro-onnx 0.5.0 requires 'onnxruntime>=1.20.1', 'phonemizer-fork>=3.3.2' and 'espeakng-loader>=0.2.4'. uvicorn[standard] adds httptools, uvloop, websockets and others, all unpinned. A fresh `uv pip install -r requirements.txt` resolves the newest Starlette, phonemizer and onnxruntime of the day, not the versions the backend tests ran against (starlette 1.6.0, onnxruntime 1.29.0, phonemizer-fork 3.3.2 in backend/.venv).
- **Root cause:** The H063 fix pinned only the six top-level lines. Its own finding also named every transitive package (starlette, pydantic, onnxruntime, phonemizer-fork…), and those were left floating.
- **Fix:** New backend/constraints.txt holds `uv pip freeze --offline` of the backend venv: all 59 installed distributions, at their tested versions. requirements.txt starts with `-c constraints.txt` and now declares anyio==4.14.2, which app.py imports directly. The pins don't carry hashes yet.
- **Test:** backend/tests/test_launchers.py: ModelDownloadTests.test_requirements_apply_the_constraints, test_every_dependency_is_pinned_to_the_tested_version (walks installed metadata from requirements.txt with markers and extras, and asserts each reachable distribution is pinned at its installed version), test_backend_requirements_are_pinned (now ignores option lines)
- **Commit:** `ee8c430`

#### L043 · Medium · Extension

**sanitize() accepts any http(s) origin as backendUrl, and the service worker POSTs every sentence's text to it (background/index.ts:405).**

- **Where:** `extension/src/shared/prefs.ts:71` (security)
- **Scenario:** The user activates Aloud on a hostile page, and that page's renderer is compromised (the J047 threat model). It runs chrome.storage.sync.set({'aloud.prefs.v1': {...prefs, backendUrl: 'https://collector.example'}}). sanitize keeps the URL because it matches /^https?:\/\//.
- **Root cause:** I confirmed this under the threat model J047 already accepted: a compromised page renderer that is hosting Aloud's content script. An ordinary hostile page cannot trigger it.
- **Fix:** prefs.ts has a new exported onThisComputer(url). It accepts http and https on 127.0.0.1, localhost or [::1] with no username or password, and sanitizeBackend sends anything else back to the default. The worker checks it again before every fetch. The backend serves only 127.0.0.1 and refuses a [::1] Host, so in practice only 127.0.0.1 and localhost reach it.
- **Test:** extension/tests/background.test.mjs: 'L043: a backend URL off this computer is refused, and no request leaves it' and 'L043: every request the worker makes is checked against this computer first'. The I018 row for my-mac.local now expects the default.
- **Commit:** `fb0c3d5`

#### L047 · Low · Extension

**H033 made the bar ignore events dispatched by page scripts, but the reader's document-level handlers still act on them.**

- **Where:** `extension/src/content/index.ts:531` (security)
- **Scenario:** A site that wants to block read-aloud, or ordinary page code, runs document.dispatchEvent(new Event('aloud:takeover')) or window.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'})). The bar disappears and the reading position is lost.
- **Root cause:** The finding is real: page scripts can stop the reader or move it. The security framing is overstated, though.
- **Fix:** The click-to-jump and window Escape handlers return early when !e.isTrusted, and the takeover listener tears down only when !extensionAlive(). Still open: the window 'pagehide' listener (content/index.ts) tears down on any event, so page code that dispatches a fake pagehide still stops the reader (see Known follow-ups).
- **Test:** extension/tests/content.test.mjs 'L047: events a page dispatches neither stop the reader nor move it'. It covers an untrusted takeover, an untrusted Escape and an untrusted click; trusted click and Escape still work.
- **Commit:** `fb0c3d5`

## Not fixed

- **F028** (deferred, medium): When a download is not valid UTF-8, fetch_text falls back to latin-1. tools/gutenberg_fetch.py is being edited in another session.
- **F055** (deferred, medium): strip_boilerplate only removes the START/END header and footer markers. tools/gutenberg_fetch.py is being edited in another session.
- **F084** (deferred, low): The fetcher writes to <its own checkout>/books, but sync_bookshelf.sh always reads the hard-coded main-checkout books/. tools/gutenberg_fetch.py is being edited in another session.
- **F085** (deferred, low): Failed or rejected books don't count toward --count, and no delay follows a failure. tools/gutenberg_fetch.py is being edited in another session.
- **F086** (deferred, low): Lock staleness is judged by the lock file's mtime, which is never refreshed while the run is alive, and release_lock unlinks the lock path unconditionally. tools/gutenberg_fetch.py is being edited in another session.
- **H015** (deferred, medium): run() works out `pending` once and never checks `have` again inside the loop. tools/gutenberg_fetch.py is being edited in another session.
- **J015** (deferred, low): Content is validated in run() only after fetch_text has returned the first URL that answered 200. tools/gutenberg_fetch.py is being edited in another session.
- **J016** (deferred, low): Each failed download attempt is logged by exception class only ('URLError on …', 'HTTPError on …'). tools/gutenberg_fetch.py is being edited in another session.
- **F035** (left as designed, medium): In very long books, every text-size step, every resize end and every Contents dock or undock does synchronous main-thread work that grows with how far into the book the reader is. A full layout is what keeps the reading place exact after a text-size step; the cost only shows in very long books.
- **F008** (needs you, high): espeak-ng (GPL-3.0) is statically linked into the closed-source shipping binary through sherpa-onnx, and both apps bundle its data, but neither bundle carries the GPL text or a correct source offer. Licence decision: espeak-ng is GPL-3.0 and is statically linked through sherpa-onnx.
- **F009** (needs you, high): The iPhone Debug and Release builds share the bundle id com.davidxie.Aloud and therefore one data container. Bundle-id decision: give the iPhone Debug build its own id (for example com.davidxie.Aloud.dev) so UI tests can't wipe the shipping library.
- **F051** (needs you, medium): The acknowledgements list only four components, each with a license name and no license text. Licence texts: add the full notices for protobuf, re2, abseil, OpenFst, kaldi and Eigen to the Licenses page.
- **J030** (needs you, low): The Mac app's Release and Archive builds can only be signed ad hoc, with no team. project.yml sets CODE_SIGN_IDENTITY "-" in the AloudMac target's base settings, so it covers Release... Release signing needs your Apple Developer team: set DEVELOPMENT_TEAM (and a distribution identity) for Release in ios/project.yml so archives can be uploaded; ad hoc signing stays for Debug and tests.

## All confirmed findings

Grouped by wave, then by area, most severe first. Each finding was reported by a read-only hunter and confirmed by a separate verifier that was told to refute it; rejected reports are not listed. Each entry describes the fix as first made. A fix that a later finding refined has that later finding's own entry too (for example F034 and G012, G019 and L047). A sampled check of 36 entries against the final code found four such cases, and those four are corrected below.

### Loop 1: waves 1-3 (full review)

#### Backend

##### F050 · Medium · Backend

**POST /synthesize has no limit on text length or body size, so one request can occupy the single synthesis worker for hours and use memory in proportion to the text until the machine runs out.**

- **Where:** `backend/app.py:90` (crash)
- **Scenario:** `text: str` has no max length (app.py:90), and the only check is that the text is not empty (app.py:188). kokoro_onnx `create()` splits the phonemes into any number of 510-phoneme batches and joins all the audio in memory. That is about 6.4 KB of float32 per input character at speed 1.0, twice that at speed 0.5.
- **Root cause:** Nothing on the request path limits size. `SynthesizeRequest.text` and `voice` are plain `str` fields with no `max_length` (backend/app.py:90-91).
- **Fix:** POST /synthesize now rejects text over MAX_TEXT_CHARS=2000 with 413 and a voice id over MAX_VOICE_CHARS=64 with 400. Both answer retryable=false, so the frontend and the extension skip the sentence.
- **Test:** backend/tests/test_app_requests.py InputLimitTests (test_text_over_the_limit_is_413_and_never_queued, test_text_at_the_limit_is_synthesized, test_overlong_voice_is_400_and_never_queued, test_declared_oversized_body_is_413, test_streamed_oversized_body_without_length_is_413, test_small_streamed_body_still_reaches_the_handler)
- **Commit:** `c2ab14a`

##### F053 · Medium · Backend

**The documented launcher binds the unauthenticated TTS server to 0.0.0.0 by default, so every device on the same Wi-Fi can use it, while run.sh and the README say it runs on localhost.**

- **Where:** `backend/run.py:26` (security)
- **Scenario:** README.md:235 tells users to run ./run.sh, and run.sh:29 prints 'Starting TTS backend on http://localhost:8000'. run.sh then runs run.py without ALOUD_HOST, so HOST = '0.0.0.0'. On café or office Wi-Fi, any peer can reach http://<mac-ip>:8000/synthesize with no auth and send the oversized-text request above, which hangs or kills the user's reader.
- **Root cause:** backend/run.py:26 binds to 0.0.0.0 unless ALOUD_HOST is set. run.sh:30 launches run.py without setting ALOUD_HOST, yet run.sh:29 and README.md:235 tell the user the server is on localhost. The 0.0.0.0 default has been there since the first commit (8475d6d), and the docstring at run.py:13-14 even admits the server is on the LAN by default.
- **Fix:** run.py now defaults to HOST=127.0.0.1, and ALOUD_HOST=0.0.0.0 is an explicit opt-in. The docstring now says LAN use also needs ALOUD_ALLOWED_HOSTS because of the F054 host check. run.sh prints the real port.
- **Test:** backend/tests/test_launchers.py RunHostTests.test_default_bind_is_loopback, test_lan_is_an_explicit_opt_in
- **Commit:** `c2ab14a`

##### F054 · Medium · Backend

**CORS allows every origin with every method and header, and the Host header is never checked, so any web page the user visits can drive POST /synthesize on the user's machine.**

- **Where:** `backend/app.py:78` (security)
- **Scenario:** allow_origins=['*'], allow_methods=['*'] and allow_headers=['*'] mean the preflight for a JSON POST from https://any-site.example succeeds. A page can then call fetch('http://localhost:8000/synthesize', {method:'POST', headers:{'Content-Type':'application/json'}, body: hugeText}) and set off the oversized-text CPU and memory exhaustion while the user is only browsing.
- **Root cause:** backend/app.py:78-84 uses CORSMiddleware with allow_origins=["*"], allow_methods=["*"] and allow_headers=["*"]. No TrustedHostMiddleware or Host check exists anywhere in the backend.
- **Fix:** Fixed in backend/app.py. TrustedHostMiddleware refuses any Host other than localhost, 127.0.0.1 or a name listed in ALOUD_ALLOWED_HOSTS, so a DNS-rebinding page is turned away before synthesis. CORS allows only GET and POST with a Content-Type header, from origins matching http://localhost or http://127.0.0.1 on any port, any chrome-extension:// origin (added in ec088af), or ALOUD_CORS_ORIGINS.
- **Test:** backend/tests/test_app_requests.py LocalOnlyTests (test_preflight_from_another_site_is_refused, test_preflight_from_the_dev_server_is_allowed, test_lookalike_origin_is_refused, test_rebound_host_is_refused_before_synthesis, test_loopback_hosts_are_served)
- **Commit:** `c2ab14a`

##### F056 · Medium · Backend

**Requests that the client has abandoned are never removed from the queue, and 'now' jobs are unbounded and served FIFO, so after a seek or a voice change the sentence the user wants waits behind every stale job.**

- **Where:** `backend/synth_queue.py:176` (broken-feature)
- **Scenario:** submit() appends every 'now' job with no limit (line 176) and then blocks on job.done.wait() (line 179), which has no timeout and no cancel path. The sync handler (app.py:195) cannot notice that the client has disconnected.
- **Root cause:** Nothing on the server ever removes a job the client has given up on, and the web player sends every request as 'now', so the priority lanes are never used. SynthQueue.submit (backend/synth_queue.py:165-179) puts each request on an unbounded FIFO deque and then waits on job.done.wait() with no timeout and no way to cancel. _Job has no cancelled flag, and _next_job (218-227) runs whatever is at the front.
- **Fix:** Changes in backend/synth_queue.py and backend/app.py. - synth_queue.py: SynthQueue gains enqueue(), result() and cancel(). submit() keeps its old blocking behaviour. cancel() takes a waiting job out of its lane, and _Job now compares by identity (eq=False). A new JobCancelledError is raised for a cancelled job. - app.py: /synthesize is now async def.
- **Test:** backend/tests/test_app_requests.py AbandonedRequestTests.test_hung_up_request_is_never_synthesized / test_connected_request_waits_and_gets_audio; backend/tests/test_synth_queue_cancel.py CancelTests
- **Commit:** `c2ab14a`

##### F059 · Medium · Backend

**Text with a run of more than 510 phonemes and no . , ! ? ; is cut off without any error by kokoro_onnx, so most of a 350-character chunk can go unspoken.**

- **Where:** `backend/kokoro_engine.py:133` (broken-feature)
- **Scenario:** kokoro_onnx `_split_phonemes` splits only at [.,!?;]. A longer run becomes a single batch, which `_create_audio` cuts to MAX_PHONEME_LENGTH=510 and only logs a warning.
- **Root cause:** The bug is real but fails differently from the report. I loaded the real model in a silent probe, and the request does not return 200 with clipped audio.
- **Fix:** Added backend/phoneme_batches.py with split_for_model(), which splits any punctuation-free run of 400 or more phonemes at spaces. A single word with no space in it is cut where it stands. kokoro_engine.synthesize now phonemizes the text itself with tokenizer.phonemize(text, lang), then calls create(piece, is_phonemes=True) for each piece and concatenates the audio.
- **Test:** backend/tests/test_phoneme_batches.py SplitTests (4 tests) and EngineTests.test_a_row_of_years_is_spoken_in_full / test_a_normal_sentence_is_one_model_call
- **Commit:** `c2ab14a`

##### F060 · Medium · Backend

**run.py/run.sh never check whether port 8000 is already taken.**

- **Where:** `backend/run.py:34` (bad-ux)
- **Scenario:** Uvicorn binds through asyncio create_server, which sets SO_REUSEADDR on POSIX. I checked with a socket test on this Mac: with 127.0.0.1:P already listening, binding 0.0.0.0:P still succeeds, and a connection to 127.0.0.1:P goes to the 127.0.0.1 listener.
- **Root cause:** backend/run.py:34 calls uvicorn.run("app:app", host="0.0.0.0", port=8000) without checking first whether anything already answers on 127.0.0.1:8000. With reload=False and one worker, uvicorn 0.52.4 (the installed version) binds through loop.create_server(host, port) in uvicorn/server.py:173.
- **Fix:** run.py now runs preflight(port) before uvicorn.run, using native_app.probe_backend and port_in_use (renamed from _port_in_use). If an Aloud backend already answers it exits 0; if another program holds the port it exits 1 with a message.
- **Test:** backend/tests/test_launchers.py RunPreflightTests (test_free_port_goes_ahead, test_running_aloud_backend_is_reused, test_other_program_on_the_port_stops_startup, test_main_does_not_start_uvicorn_when_preflight_says_stop)
- **Commit:** `c2ab14a`

##### F103 · Low · Backend

**choose_port() crashes on a non-numeric ALOUD_PORT, and a bind failure in the uvicorn thread is never noticed: the window waits 30 s and then accepts any /health that says status 'ok', even from a non-Aloud service.**

- **Where:** `backend/native_app.py:119` (polish)
- **Scenario:** find_running_backend catches the ValueError from a bad ALOUD_PORT (lines 108-111), but choose_port then calls int(env_port) unguarded (line 119), which ends in a traceback. When ALOUD_PORT names a port that a non-Aloud service owns, probe_backend correctly returns None, choose_port returns that port anyway, and uvicorn's startup sys.exit inside the daemon thread disappears without a trace. _wait_for_health (line 141) checks only status in ('ok','warming') and not engine=='kokoro', unlike probe_backend at line 89.
- **Root cause:** The mechanics are real, and I reproduced them on copies of the code. But the finding only applies to the retired legacy pywebview launcher (docs/legacy-web-app.md: nothing in ios/ builds from it or calls it).
- **Fix:** In native_app.py, a new env_port() parses ALOUD_PORT in one place. A missing value, a non-number or an out-of-range number falls back with a warning, and find_running_backend, choose_port and run.py all use it, which also fixes the same crash at run.py:27. _wait_for_health now requires a dict payload with engine=='kokoro'.
- **Test:** backend/tests/test_launchers.py NativePortTests.test_invalid_aloud_port_does_not_crash_choose_port, NativeHealthTests (test_foreign_ok_is_not_mistaken_for_aloud, test_non_object_health_is_not_a_crash, test_aloud_health_counts_while_warming, test_dead_server_thread_fails_at_once)
- **Commit:** `c2ab14a`

#### Browser extension

##### F010 · High · Extension

**Plain-text pages can't be read.**

- **Where:** `extension/src/content/extract.ts:62` (broken-feature)
- **Scenario:** findContentRoot finds no p/li/article and returns body. walk(body) reaches the only child, the <pre>, and shouldSkip() returns true because of SKIP_TAGS (line 62). No sentences come back, so start() shows the toast 'No readable text found on this page.' (index.ts:181).
- **Root cause:** Nothing guards this path. findContentRoot only scores article, main, [role=main], p, li, blockquote, h2, h3 and dd. Chrome's text/plain document is just body > pre, so the scores map stays empty and the function returns body (extract.ts:189). walk(body) then reaches the single PRE child and shouldSkip returns true at line 251 (SKIP_TAGS has 'PRE', line 62).
- **Fix:** New plainTextPre() picks the PRE when contentType is text/plain, or when the PRE is the body's only element and holds no code. extractPage reads that PRE in plain mode: blocks split at blank lines (paragraphSpans), and newlines are turned into spaces (same length) before splitWithOffsets, so hard-wrapped lines no longer split into fragments. extractSelection starts inside the PRE when the range is anchored on body. Code PREs inside articles are still skipped.
- **Test:** extension/tests/extract.test.mjs: 'F010: a text/plain page is read, not skipped as a code block', 'F010: select-all on a plain-text page reads the PRE too', plus the guard 'F010: a PRE inside an ordinary article is still skipped as code' and 'paragraphSpans splits on blank lines only'
- **Commit:** `41bfcd2`

##### F011 · High · Extension (twin fixed on the other platform)

**Any audio.play() rejection other than an abort is swallowed, and the status is left at 'playing'.**

- **Where:** `extension/src/content/player.ts:657` (broken-feature)
- **Scenario:** playIndex sets status 'playing', then awaits audio.play(). In the catch, a NotAllowedError (autoplay policy on a page with no user interaction) or a NotSupportedError (a 200 body that is not decodable WAV) skips the early return and goes on to startWordLoop(). ensureAudio (lines 244-254) only listens for 'ended' and 'loadedmetadata'.
- **Root cause:** The finding holds, and the autoplay path is common. In playIndex (extension/src/content/player.ts:655-663), status is set to 'playing' and then audio.play() is awaited.
- **Fix:** playIndex and the resume-in-place path in play() both send non-abort play() rejections to playRefused(). NotAllowedError gives status 'paused' with the message 'Chrome blocked the audio — click play on the Aloud bar to start.' (a later click resumes the same sentence).
- **Test:** extension/tests/player.test.mjs: 'F011: an autoplay refusal pauses and asks for a click…', 'F011: a clip the browser cannot play is skipped…', 'F011: an audio error event skips the loaded sentence exactly once'
- **Commit:** `41bfcd2`, `8b0fd10`

##### F012 · High · Extension

**The default shortcuts collide with system and browser keys.**

- **Where:** `extension/src/manifest.json:41` (bad-ux)
- **Scenario:** Chrome refuses to auto-assign a suggested_key that is already a Chrome accelerator. On Windows/Linux the next-sentence and previous-sentence commands are therefore left unset, while the player bar (ui.ts:325-327) still tells users to press Alt+← and Alt+→.
- **Root cause:** Windows, Linux and ChromeOS: Chrome never assigns the next and previous shortcuts. CommandService::CanAutoAssign ends with `return !IsChromeAccelerator(command.accelerator());`.
- **Fix:** Manifest defaults are now toggle Alt+A, next Alt+Period, prev Alt+Comma. On Mac they are MacCtrl+Shift+A, MacCtrl+Shift+Period and MacCtrl+Shift+Comma.
- **Test:** extension/tests/background.test.mjs: 'F012: default shortcuts clash with neither Chrome nor typing', 'F012: no surface hard-codes a shortcut', 'F012: the bar is told the bindings Chrome really made'
- **Commit:** `41bfcd2`

##### F064 · Medium · Extension

**When the backend is down or still warming up, each sentence is skipped and the index moves forward.**

- **Where:** `extension/src/content/player.ts:697` (broken-feature)
- **Scenario:** While the model loads, the backend answers 503 with Retry-After: 2. api.ts retries 3 times (about 4 s), then throws, and skipSentence(0) calls playIndex(1). That repeats for sentences 1 and 2.
- **Root cause:** The core bug is real. If the backend can't be reached, the extension skips 3 sentences, stops with status 'error' at index 2, and every resume path calls playIndex(2).
- **Fix:** A SynthesisError with status 0 (transport, reloaded, or an unexpected reply) never reached an engine. It now calls halt(i), which stays on that sentence with status 'error' and marks nothing as skipped.
- **Test:** extension/tests/player.test.mjs: 'F064: an unreachable backend stops on the first sentence, and play resumes there', 'F064: a run of failing sentences stops where the run began'
- **Commit:** `41bfcd2`

##### F065 · Medium · Extension

**Race on first activation: the content script registers its onMessage listener only after `await loadPrefs()`.**

- **Where:** `extension/src/content/index.ts:285` (broken-feature)
- **Scenario:** dispatch() (background/index.ts:123-127) calls executeScript and then immediately calls tabs.sendMessage({kind:'command'}). The IIFE bundle returns undefined, so executeScript resolves right after synchronous evaluation. main() is then still waiting on one storage round trip, or two on first use when sync has no prefs and it falls back to local.get, before reaching line 285.
- **Root cause:** I could not refute this. The race is built into the code and nothing guards against it.
- **Fix:** content/index.ts registers chrome.runtime.onMessage synchronously, in listenNow(), before await loadPrefs(). Messages that arrive before main() is ready are queued with return true, so the reply channel stays open, and they are answered once main() hands over its responder.
- **Test:** extension/tests/content.test.mjs: 'F065: a command sent the moment injection returns is answered, not dropped'
- **Commit:** `41bfcd2`

##### F068 · Medium · Extension

**After the extension updates or reloads, a tab that is reading or paused tells the user to start the backend.**

- **Where:** `extension/src/content/api.ts:242` (bad-ux)
- **Scenario:** An invalidated context makes sendMessage fail. attemptSynthesize builds SynthesisError(RELOADED_MESSAGE, {status: 0, retryable: false}). A synchronous 'Extension context invalidated' throw becomes status 0 in synthesize() as well. skipSentence then calls describeFailure (player.ts:907), which maps every status-0 error to 'Speech engine unreachable — is the Aloud backend running?'. getHealth (api.ts:140) also catches the same failure and returns OFFLINE, so the bar shows 'Speech engine offline — start the Aloud backend.' (ui.ts:276).
- **Root cause:** After the extension reloads or updates, the content script left on the page cannot talk to the extension any more, and every way that failure surfaces ends in 'start the backend' copy. The 'refresh this page' message is never shown.
- **Fix:** SynthesisError has a new `reloaded` flag. Both the async path and a synchronous 'Extension context invalidated' throw in synthesize() now produce it, carrying RELOADED_MESSAGE (now exported). describeFailure returns that message. getHealth returns PageHealth, whose state 'reloaded' comes from the new shared ReaderEngineState type. statusLine shows the refresh message ahead of 'offline', and scheduleHealth stops polling once the state is 'reloaded'.
- **Test:** extension/tests/player.test.mjs: 'F068: a reloaded extension says refresh, not "start the backend"', 'F068: getHealth tells a reloaded extension apart from an offline engine', 'F068: the bar puts the refresh message ahead of "offline"'
- **Commit:** `41bfcd2`

##### F069 · Medium · Extension

**Long pages are cut off without warning at 600,000 characters (MAX_TEXT) or 8,000 sentences (MAX_SENTENCES).**

- **Where:** `extension/src/content/extract.ts:114` (broken-feature)
- **Scenario:** walk() stops collecting once state.text.length > MAX_TEXT (line 301), and buildSentences stops at MAX_SENTENCES (lines 337 and 348). Nothing records that the page was truncated.
- **Root cause:** In extract.ts, walk() returns once state.text.length > MAX_TEXT (600,000), and buildSentences stops at MAX_SENTENCES (8,000). The Extraction carries no truncated flag, and nothing downstream checks for one. player.ts:703 and :691 set status 'ended' when index+1 >= total, so the bar shows 'Finished' (ui.ts:283) and the popup shows 'Finished this page.' (popup.ts:136).
- **Fix:** This is the minimal fix, not chunked extraction. Extraction.truncated is set when walk() hits MAX_TEXT with nodes left, or when buildSentences would go past MAX_SENTENCES.
- **Test:** extension/tests/extract.test.mjs: 'F069: a page past the length limit says so instead of "Finished"', 'F069: a page within the limit is not marked truncated'
- **Commit:** `41bfcd2`

##### F070 · Medium · Extension

**'Read selection aloud' ignores info.frameId and info.selectionText.**

- **Where:** `extension/src/background/index.ts:75` (broken-feature)
- **Scenario:** Chrome shows the selection context menu for selections in any frame. onClicked calls dispatch(tab.id, 'start-selection'), and executeScript targets only {tabId}, which is frame 0. The content script then runs extractSelection() on window.getSelection() in the top document.
- **Root cause:** The finding is confirmed. The selection menu item has no documentUrlPatterns or frame restriction, so Chrome shows it for selections in any frame.
- **Fix:** I chose the selectionText fallback over injecting into the frame. When contextMenus.onClicked has frameId != 0, it sends info.selectionText along with the 'start-selection' command (TabRequest.command.text).
- **Test:** extension/tests/background.test.mjs: 'F070: a selection in a subframe is read from the text Chrome reports' (guard: '…in the page itself still reads the live DOM selection'); extension/tests/extract.test.mjs: 'F070: text reported from an unreachable frame is read as plain text'
- **Commit:** `41bfcd2`

##### F071 · Medium · Extension

**Client-side navigation through history.pushState is never detected, because only popstate and hashchange are watched.**

- **Where:** `extension/src/content/index.ts:414` (bad-ux)
- **Scenario:** onNavigate runs only for popstate (back/forward) and hashchange. Clicking a link in an SPA (Medium, Substack, GitHub, dev.to) calls pushState, which fires neither.
- **Root cause:** Nothing anywhere in the extension notices a pushState navigation. The content script runs in Chrome's isolated world (it is injected with chrome.scripting.executeScript and no world option).
- **Fix:** The new content/navigation.ts watchNavigation() covers popstate, hashchange and Navigation API currententrychange (Chrome 102+, the floor is 114). It ignores navigationType 'replace' because sites use replaceState to tidy the URL, but still records the new address. index.ts also tears down, deferred with setTimeout, when extraction.root is no longer connected after a sentence change.
- **Test:** extension/tests/content.test.mjs: 'F071: an app navigating with pushState ends the reading; replaceState does not'
- **Commit:** `41bfcd2`

#### Mac app

##### F005 · High · Mac

**Double- or triple-clicking to select a word or paragraph starts playback from that sentence.**

- **Where:** `ios/AloudMac/Reader/ReaderNSTextView.swift:115` (broken-feature)
- **Scenario:** Clicking selects text in two steps. NSTextView.mouseDown for click 1 tracks until mouse-up and returns, and finishClick sends onClickEnded(point, 1, hasSelection=false).
- **Root cause:** Nothing in the click path waits to see whether a second click is coming. AppKit sends a double-click as two separate mouse-down/mouse-up pairs (clickCount 1, then 2).
- **Fix:** In Coordinator.handleClick, a single click no longer plays at once. It schedules the play as a DispatchWorkItem after clickPlayDelay(), which defaults to NSEvent.doubleClickInterval. clickLanded (the next mouse-down) and tearDown cancel it, and the item checks that builtHash has not changed.
- **Test:** ReaderColumnViewTests.testADoubleOrTripleClickSelectsWithoutPlaying (plus testAClickInASentencePlaysFromIt, now checking that the play is held and the default delay is NSEvent.doubleClickInterval)
- **Commit:** `8740cdc`

##### F027 · Medium · Mac

**The Mac Continue card does not get the keyboard handling that grid cards get.**

- **Where:** `ios/AloudMac/Library/MacLibraryView.swift:176` (bad-ux)
- **Scenario:** MacLibraryCard adds .onKeyPress(.return) and .focusedValue(\.macDeleteBook) (MacLibraryCard.swift:25-41), and its header promises 'Return or Space' opens and Cmd-Delete deletes a focused card. MacContinueHero (MacLibraryView.swift:377-424) wraps the shared ContinueListeningCard, which has neither.
- **Root cause:** On the Mac, every other focusable card or row adds its own Return handler, and only the grid card publishes the Delete Book focused value. MacContinueHero wraps the shared ContinueListeningCard and adds neither.
- **Fix:** MacContinueHero now has .focused($focusedCard, equals: hero.id), .onKeyPress(.return) to open it, .onMoveCommand, and .focusedValue(\.macDeleteBook) to delete its book. moveFocus goes through a new pure MacLibraryView.focusTarget: Up from the grid's first row goes to the hero, Down from the hero goes to the first card. The test covers only that arrow rule.
- **Test:** MacGridMetricsTests.testUpFromTheFirstRowReachesTheContinueCard
- **Commit:** `6e7a36b`

##### F033 · Medium · Mac

**Opening a book never gives the page keyboard focus, so ↓/↑, Page Up/Down, Home/End and ⌘↑/⌘↓ do nothing until the user tabs in or opens and closes Contents.**

- **Where:** `ios/AloudMac/Reader/ReaderColumnView.swift:260` (bad-ux)
- **Scenario:** Coordinator.init sets lastFocusRequest = parent.focusRequest, and MacReaderScreen only bumps pageFocusRequests when Contents goes from shown to hidden (MacReaderScreen.swift:54, :166). Nothing else in AloudMac makes the text view first responder: the only makeFirstResponder calls are focusText and the Contents panel.
- **Root cause:** I couldn't refute it. Nothing gives the reader's NSTextView keyboard focus when a book opens.
- **Fix:** In update(to:), the first successful rebuild (builtHash was empty) now calls focusText(sparingAField: true), one main-queue turn later. That skips the focus when the window's first responder is a field editor, such as ⌘F's Contents search opened while the text loaded. focusText(sparingAField:) defaults to false, so the Contents-closing path is unchanged.
- **Test:** ReaderColumnViewTests.testABookOpeningPutsTheKeyboardOnTheText
- **Commit:** `8740cdc`

##### F034 · Medium · Mac

**A light/dark or Increase Contrast change rebuilds the column and clears the reader's text selection and VoiceOver's placed cursor.**

- **Where:** `ios/AloudMac/Reader/ReaderColumnView.swift:478` (bad-ux)
- **Scenario:** rebuildForAppearanceChange calls rebuild(), which runs textView.setSelectedRange(NSRange(location:0,length:0)) at line 453. That goes through setSelectedRanges, so MacReaderAccessibility.selectionMoved() sets placedCursor = nil. changeTextSize wraps the same rebuild in readerAccessibility.keepingCursor (line 584); the appearance path does not wrap it in anything.
- **Root cause:** rebuildForAppearanceChange (ReaderColumnView.swift:478-487) calls rebuild() without wrapping it in anything. rebuild() calls textView.setSelectedRange(NSRange(location:0,length:0)) at line 453. movingProgrammatically only bumps the programmaticMoves counter, so it does not protect the selection. The call goes through ReaderNSTextView.setSelectedRanges (ReaderNSTextView.swift:367-370), where isPlacingAccessibilityCursor is false, so readerAccessibility.selectionMoved() sets placedCursor = nil.
- **Fix:** First fixed in 8740cdc by wrapping the rebuild in keepingCursor. Since G012 (0131b87), an appearance change doesn't rebuild at all: it redraws the text view with the dynamic ReaderInk.live() colors and re-renders the sentence highlight and word underline. The text storage is never edited, so VoiceOver's placed cursor and the reader's selection are never touched.
- **Test:** MacReaderAccessibilityTests.testAnAppearanceChangeKeepsTheCursorAndTheSelection
- **Commit:** `8740cdc`, `0131b87`

##### F035 · Medium · Mac

**In very long books, every text-size step, every resize end and every Contents dock or undock does synchronous main-thread work that grows with how far into the book the reader is.**

- **Where:** `ios/AloudMac/Reader/ReaderColumnView.swift:657` (bad-ux)
- **Scenario:** changeTextSize (line 584) calls rebuild, which runs ReaderColumnText.makeAttributedString for the whole book plus storage.setAttributedString, and that invalidates all TextKit 2 layout. Then arm(anchor, confirming: true) calls restore, which calls column.ensureLayout(through: anchor.range).
- **Root cause:** Each text-size step goes through update(to:) at line 398, then changeTextSize at 581. That calls rebuild at 437-475, which runs makeAttributedString over the whole book and then storage.setAttributedString, so TextKit 2 throws away all of its layout.
- **Status:** left as designed. A full layout is what keeps the reading place exact after a text-size step; the cost only shows in very long books.

##### F037 · Medium · Mac

**On the Mac, nothing shows while a dropped, picked or opened file is being copied in, and it can't be cancelled.**

- **Where:** `ios/AloudMac/Library/MacAddMenu.swift:130` (bad-ux)
- **Scenario:** admit() runs stage(file) for each file in a loop (lines 133-139) and calls importer.importFiles(at:) only after all of them finish (147). `staging` is a private, unpublished counter, and MacImportOverlay (lines 22/30) only reacts to importer.isImporting.
- **Root cause:** The main claim holds. While a file is being copied in, the Mac shows nothing and offers no way to cancel.
- **Fix:** MacFileIntake publishes copyingName for each file while it is staged and keeps each batch's Task. A new cancel() cancels the batches still copying and calls importer.cancel().
- **Test:** MacImportTests.testCancelWhileAFileCopiesAddsNothing
- **Commit:** `6e7a36b`

##### F038 · Medium · Mac (twin fixed on the other platform)

**FileManager.copyItem copies a symlink itself, not the file it points to (checked with a probe).**

- **Where:** `ios/AloudMac/Library/MacAddMenu.swift:372` (broken-feature)
- **Scenario:** stageCopy copies `readable` into Documents/Inbox/<UUID>/name keeping the link. A relative link such as `book.pdf -> ../Books/real.pdf` no longer resolves from the staging folder, so sourceHash fails with ENOENT and the user sees 'This file couldn't be opened' for a file that opens fine in Preview.
- **Root cause:** The bug is real. Neither step in the Mac drop path follows a symlink.
- **Fix:** stageCopy copies readable.resolvingSymlinksInPath(), so relative and absolute links both stage a regular file, under the dropped name. Twin not in my files: shared DocumentStore.copyFile (ios/Aloud/Library/DocumentStore.swift ~624-629) still calls plain copyItem.
- **Test:** MacImportTests.testASymbolicLinkStagesTheFileItPointsTo
- **Commit:** `6e7a36b`, `d376e46`

##### F043 · Medium · Mac

**onChange(of: listLayout) remaps the keyboard cursor even in results mode.**

- **Where:** `ios/AloudMac/Reader/MacContentsPanel.swift:128` (bad-ux)
- **Scenario:** Docked panel, a book with 2 stops. Search 'said' and arrow down to result #5 (cursor 5).
- **Root cause:** The finding is confirmed. In MacContentsPanel.swift line 128, `.onChange(of: listLayout)` runs no matter which mode the panel is in.
- **Fix:** MacContents.remap now takes `in mode: Mode` and returns the cursor unchanged unless the mode is .chapters. MacContentsPanel's onChange(of: listLayout) passes currentMode.
- **Test:** MacContentsPlacesTests.testAResultsCursorStaysOnItsResultWhenAStopIsRecorded
- **Commit:** `8740cdc`

##### F046 · Medium · Mac

**Commands that need the main window stay enabled after it is closed or minimized, and they quietly change hidden state.**

- **Where:** `ios/AloudMac/Commands/MacCommandActions.swift:130` (broken-feature)
- **Scenario:** Close the main window with ⌘W while a book plays; the app keeps running. Press ⌘O or choose File > Add from Files…. isEnabled returns true for addFromFiles at line 87, and perform sets router.rootPresentation = .filePicker.
- **Root cause:** I could not refute it. When the main window is closed, nothing checks whether that window exists before running the window-only commands, so they stay enabled.
- **Fix:** MacCommandActions gains `var showMainWindow: () -> Void` and `needsMainWindow(_:)` (addFromFiles, addClassic, find, toggleContents, back, and voiceAndSpeed in the reader). perform calls showMainWindow before acting. This needed a change to MacAppDelegate.swift, which I don't own: commandState is now built in a lazy closure that wires showMainWindow, and a new MacAppDelegate.showMainWindow() deminiaturizes the window, brings a visible one to the front, or else reopens it through openMainWindow.
- **Test:** MacCommandActionsTests.testWindowCommandsBringTheWindowBackFirst
- **Commit:** `6e7a36b`

##### F048 · Medium · Mac

**For 10 seconds after any jump, Edit > Undo Jump (⌘Z) sits ahead of the system Undo (also ⌘Z), so ⌘Z in a focused text field undoes the jump instead of the typing.**

- **Where:** `ios/AloudMac/Commands/AloudCommands.swift:46` (bad-ux)
- **Scenario:** In the reader, type a query in Contents' "Search this book" field, press ↓ and Return on a match (or click it). This calls MacContents.jump, and playback.undoableJump is offered for UndoableJump.displaySeconds = 10 s.
- **Root cause:** The finding is confirmed. For 10 s after any jump that offers Undo, the Edit menu holds "Undo Jump" (⌘Z, enabled) ahead of the system "Undo" (also ⌘Z).
- **Fix:** In MacKeyRouter.handle, Cmd-Z with editable text as first responder and firstResponder.undoManager.canUndo calls undo() and swallows the event. With nothing to undo in the field, or outside a field, Cmd-Z passes through as before, so Undo Jump still works there. undoJump is not added to defersToEditableText, so the existing testTextKeysDeferToEditableText is unchanged.
- **Test:** MacKeyRouterTests.testCommandZInAFieldUndoesTheTypingNotTheJump
- **Commit:** `6e7a36b`

##### F049 · Medium · Mac

**On macOS 14, the deployment target, Edit > Find… (⌘F) in Classics is enabled but does nothing, and File > Add a Classic… never focuses the search field.**

- **Where:** `ios/AloudMac/Commands/MacCommandActions.swift:122` (bad-ux)
- **Scenario:** On macOS 14, open Classics and press ⌘F, or press ⌘⇧O from anywhere. isEnabled(.find) is true for .classics (line 83), and perform sets ui.searchFocus = .classics. MacClassicsView then sets isSearchFocused = true.
- **Root cause:** The finding holds on macOS 14, which the app supports (deploymentTarget macOS 14.0 in project.yml; the README says "macOS 14 or later"). In Classics, ⌘F and Add a Classic (⌘⇧O) run their actions, but the toolbar search field never gets keyboard focus, so ⌘F looks like it does nothing.
- **Fix:** New MacToolbarSearch (in MacCommandActions.swift) finds the toolbar's search field: an NSSearchToolbarItem's own field, or an NSSearchField inside an item's view. On macOS 14 (#unavailable(macOS 15)), perform(.find) in Classics and perform(.addClassic) call MacToolbarSearch.focusSoon(), which tries up to 10 times at 50 ms (beginSearchInteraction, else makeFirstResponder) once the pushed Classics toolbar exists.
- **Test:** MacCommandActionsTests.testTheToolbarSearchFieldIsFound
- **Commit:** `6e7a36b`

##### F052 · Medium · Mac

**Re-picking the armed duration in Playback > Sleep Timer does nothing.**

- **Where:** `ios/AloudMac/Commands/AloudCommands.swift:143` (bad-ux)
- **Scenario:** Arm a 30-minute timer, wait until a few minutes are left, then choose Playback > Sleep Timer > 30 minutes again to restart it. The checked Toggle's setter receives false, and the guard `if $0` drops it, so SleepTimer.select is never called and the countdown keeps running down.
- **Root cause:** Clicking a checked SwiftUI Toggle in a menu calls its setter with false. In AloudCommands.swift:141-143 the menu-bar Sleep Timer setter is `set: { if $0 { state.actions.selectSleep(option) } }`, so re-picking the armed duration does nothing and the countdown keeps running.
- **Fix:** The menu-bar Sleep Timer Toggle binding is now AloudCommands.sleepToggle(_:selection:select:), whose setter calls select(option) whatever the new value, as MacSleepMenu's chip does.
- **Test:** MacCommandActionsTests.testPickingTheArmedSleepItemAgainReArmsIt
- **Commit:** `6e7a36b`

##### F088 · Low · Mac

**Several standard selection-extending keys are silently swallowed: ⌘⇧←/⌘⇧→, ⌃⇧←/⌃⇧→, ⇧Page Up/Down, ⌃⇧V, ⌃⇧B/F and ⌃⌥⇧B/F.**

- **Where:** `ios/AloudMac/Reader/ReaderNSTextView.swift:300` (bad-ux)
- **Scenario:** doCommand(by:) passes a selector on only when it is in selectionCommands and drops everything else. This Mac's /System/Library/Frameworks/AppKit.framework/Resources/StandardKeyBinding.dict maps these keys to selectors that are not in the set: @$← and ^$← to moveToLeftEndOfLineAndModifySelection:, @$→ and ^$→ to moveToRightEndOfLineAndModifySelection:, $PageUp to pageUpAndModifySelection:, $PageDown and ^V to pageDownAndModifySelection:, ^B and ^F to moveBackward/ForwardAndModifySelection:, and ~^B and ~^F to moveWordBackward/ForwardAndModifySelection:.
- **Root cause:** The finding holds. In ReaderNSTextView.doCommand(by:) (ios/AloudMac/Reader/ReaderNSTextView.swift:281-296), any selector that onCommand/KeyScroll does not take and that is not Tab, Backtab or Esc is passed on only if it is in `selectionCommands` (lines 300-316).
- **Fix:** Added moveToLeft/RightEndOfLineAndModifySelection:, pageUp/pageDownAndModifySelection:, moveBackward/ForwardAndModifySelection: and moveWordBackward/ForwardAndModifySelection: to ReaderNSTextView.selectionCommands and updated its doc comment. The test starts from a mid-line caret and, for each selector, sends doCommand(by:) and asserts the selection grows.
- **Test:** ReaderColumnViewTests.testTheSelectionKeysExtendTheSelection
- **Commit:** `8740cdc`

##### F094 · Low · Mac

**The Dock menu header shows the loaded book's old title after a rename, because it reads the controller's copy of the document, which a rename never updates.**

- **Where:** `ios/AloudMac/App/MacDockMenu.swift:36` (polish)
- **Scenario:** On the Mac a book is loaded (playing or paused). Rename it from the Library.
- **Root cause:** The Dock menu header is built from `actions.playback.document.title`. A rename changes only the store's record.
- **Fix:** The Dock header uses actions.store.documents.first { $0.id == document.id } ?? document, so a rename shows at once. The rig's makeDock(shelved:) seeds the store index with the rig's book.
- **Test:** MacDockMenuTests.testTheHeaderShowsARenameOfTheLoadedBook
- **Commit:** `6e7a36b`

##### F100 · Low · Mac

**The plain [ and ] keys (Slower and Faster) are matched by charactersIgnoringModifiers with no modifiers held, so they can't be pressed on layouts where brackets need ⌥ (German, French, Spanish...**

- **Where:** `ios/AloudMac/Commands/MacShortcuts.swift:48` (bad-ux)
- **Scenario:** On a German layout, [ is ⌥5. MacShortcutKey(event:) reads charactersIgnoringModifiers = "5", and MacModifiers(event:) holds .option. command(for:) finds nothing, the event reaches MacKeyTail, plainCommand(for:) returns nil, and the key is swallowed silently.
- **Root cause:** The core claim holds. MacShortcutKey(event:) at ios/AloudMac/Commands/MacShortcuts.swift:48 reads charactersIgnoringModifiers, which drops every modifier except Shift.
- **Fix:** MacCommand.command(for: NSEvent) falls back to typedBracketCommand: when only Option and/or Shift are held and event.characters is '[' or ']', it returns .slower or .faster. Command or Control held, or Option producing another character (US Option-]), still gives nil.
- **Test:** MacShortcutsTests.testBracketsTypedWithOptionStillStepTheSpeed
- **Commit:** `6e7a36b`

##### F101 · Low · Mac

**Make Text Bigger is bound only to ⌘+, so the unshifted ⌘= that most Mac apps also accept for bigger or zoom in does nothing, and the router's tail swallows it without a sound.**

- **Where:** `ios/AloudMac/Commands/MacShortcuts.swift:174` (polish)
- **Scenario:** On a US keyboard, press ⌘= in the reader. A scratch NSMenu probe with a "+" ⌘ key equivalent returned false for ⌘= and only matched ⌘⇧=. ⌘= doesn't match .biggerText in MacCommand.command(for:) either, so it ends in MacKeyTail.keyDown and is dropped.
- **Root cause:** Make Text Bigger is bound only to a "+" key equivalent with ⌘ (MacShortcuts.swift:174). AppKit matches that only when the key produces "+", which on a US keyboard means ⌘⇧= or keypad +.
- **Fix:** New MacCommand.alternateShortcut (Cmd-= for biggerText) and alternateCommand(for:). MacKeyRouter.handle runs it through run(_:in:), which still respects modals and sheets, and swallows it.
- **Test:** MacShortcutsTests.testCommandEqualsIsBiggerTextsSecondKey, MacKeyRouterTests.testCommandEqualsMakesTheTextBigger
- **Commit:** `6e7a36b`

#### Shared iPhone/Mac core and iPhone app

##### F000 · High · iPhone

**On iPhone, every .AVAudioEngineConfigurationChange is answered with .ignore.**

- **Where:** `ios/Aloud/Playback/AudioSessionManager.swift:60` (broken-feature)
- **Scenario:** A book is reading through the iPhone speaker. The user starts the car, its Bluetooth (often 44.1 kHz against the speaker's 48 kHz) connects, or they pick an AirPlay or Bluetooth output in Control Center.
- **Root cause:** When the output moves to a newly added device, nothing on the iPhone restarts the engine, so the app goes silent while every surface still shows Playing. 1.
- **Fix:** AudioSessionManager now keeps a weak reference to the engine it is given in bindOutput. For a configuration change it answers .ignore for a 0.5 s settle, so an unplug's routeChange pause (which can arrive in either order) lands first.
- **Test:** UITestFaultsTests.testIPhoneMonitorFollowsASettledConfigurationChange, UITestFaultsTests.testIPhoneMonitorWithNoSettleFollowsAtOnce
- **Commit:** `2c33b1f`

##### F001 · High · iPhone

**On iPhone, an AVAudioEngineConfigurationChange is ignored even though, by the protocol's own contract, the engine has stopped itself.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:2383` (broken-feature)
- **Scenario:** outputConfigurationChanged() asks decisionAfterConfigurationChange(), which always returns .ignore on iPhone (AudioSessionManager.swift:60), and then returns. That ignores the protocol doc at AudioOutputMonitoring.swift:25-26: "the engine has stopped itself because its output device or format changed".
- **Root cause:** I couldn't refute this; the trace holds. On iPhone the controller hears every .AVAudioEngineConfigurationChange for its own engine (PlaybackController.swift:536-540) and asks AudioSessionManager, which always answers .ignore (AudioSessionManager.swift:60), so outputConfigurationChanged() just returns (PlaybackController.swift:2381-2384).
- **Fix:** The controller side of F000. sentenceFinished now drops completions that arrive while audioEngine is not running. An engine that stops itself flushes and fires every completion at once, and without this guard the place would move past clips nobody heard before the settled follow.
- **Test:** PlaybackConfigurationChangeTests.testAnEngineThatStoppedItselfKeepsThePlace (+ F000's tests)
- **Commit:** `2c33b1f`

##### F002 · High · iPhone

**After an interruption, or a headphone unplug that also stopped the engine, Play takes the warm-resume path: it restarts the engine and calls resumeNode() on the old schedule.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:2367` (broken-feature)
- **Scenario:** A book is playing and a phone call (or Siri or an alarm) arrives. The .began handler calls stop(because: .interrupted), which calls pause(rampsOut:false); this pauses the node and keeps hasActiveSchedule. iOS stops the AVAudioEngine for the interruption.
- **Root cause:** I could not refute this. The warm-resume branch in play() (PlaybackController.swift:751-763) has no check for an engine that stopped underneath it.
- **Fix:** Shared fix in play()'s warm-resume branch. If the status is .paused with a schedule and the engine is not running, it calls invalidateSchedule() and falls through to startPlayback(at: currentSentence).
- **Test:** PlaybackConfigurationChangeTests.testPlayAfterTheEngineStoppedUnderAPauseSchedulesAfresh
- **Commit:** `2c33b1f`

##### F003 · High · iPhone + Mac (twin fixed on the other platform)

**Running headers are only stripped when one line repeats on at least half of all pages.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:215` (broken-feature)
- **Scenario:** Import an outline-less trade-book PDF (240 pages, 20 chapters) laid out the usual way: the book title on even pages and the chapter title on odd pages, with no header on chapter-opening pages. The book-title header shows up on about 100 pages and each chapter-title header on about 7.
- **Root cause:** detectRunningHeaders (ios/Aloud/Extraction/PDFTextExtractor.swift:200-217) counts each normalized edge line across all pages and keeps only keys that reach max(2, ceil(pages*0.5)). Nothing splits the count by odd and even pages, and no later step removes headers: ExtractionPipeline.buildContent only normalizes and segments, and the only skip during playback is SentenceSegmenter.isSpoken, which drops bracketed text and nothing else.
- **Fix:** Running headers are now counted separately for odd and even pages. A per-page rule also strips an edge line that is set apart by a paragraph gap, sits at the same y and height, and recurs 3 or more times no more than 4 pages apart, unless that run's lines read as chapter openings (areChapterOpenings, added in 4e634f5 after the loop-2 re-review).
- **Test:** PDFTextExtractorTests.testAlternatingRunningHeadersAreStrippedAndPagesRejoin; PDFChapterTiersTests.testRunningHeadersTakenOffThePageStillFindChapters
- **Commit:** `97896a3`, `8b0fd10`

##### F004 · High · iPhone + Mac

**The headings tier turns every single-sentence 'Chapter N ...' paragraph into its own chapter row.**

- **Where:** `ios/Aloud/Extraction/PDFChapters.swift:348` (broken-feature)
- **Scenario:** Take an outline-less PDF whose right-hand running header reads 'CHAPTER 3 THE RETURN' (or just 'Chapter 3', which normalizes to 'chapter #' and appears on fewer than half the pages, so it is never stripped). Each header is a one-sentence paragraph that matches numberedHeading with no trailing period and no trailing page number, so a candidate is added for every page.
- **Root cause:** HeadingChapters.entries (ios/Aloud/Extraction/PDFChapters.swift:322-392) adds a numbered candidate for every one-sentence paragraph that matches numberedHeading. Only two things are removed afterwards: the contents-list filter (lines 362-367, which drops numbered candidates within 2 sentences of each other) and normalized() (lines 115-144, which merges only entries that start at the same sentence).
- **Fix:** HeadingChapters now parses the chapter number (digits, roman numeral or number word, so CHAPTER THREE and Chapter 3 match) and keeps the first candidate per (Part, number). This runs after the contents-list filter.
- **Test:** PDFChapterTiersTests.testRunningHeadsOfANumberedHeadingCountOnce
- **Commit:** `97896a3`

##### F006 · High · iPhone + Mac

**A far jump while playing never records the place being jumped away from. jump(to:origin:) only sets placeSession.movedAway.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:1244` (broken-feature)
- **Scenario:** Listening in Chapter 20 (sentence ~4000; this session started at the last stop, ~3000). While audio plays, open Contents and tap a search result or an older 'Where you stopped' row in Chapter 2 (~150).
- **Root cause:** I could not find anything that records the sentence being jumped away from. A far jump while playing only sets `placeSession.movedAway = true` (`ios/Aloud/Playback/PlaybackController.swift:1242-1246`).
- **Fix:** The fix is in jump(to:origin:). When a jump would offer Undo and the listener is playing, endPlaceSession() runs before the seek and records a stop at `from`.
- **Test:** PlaceStopRecordingTests.testAFarJumpWhilePlayingReportsThePlaceItLeft, PlaceStopRecordingTests.testUndoWhilePlayingReopensTheSessionAtThePlaceLeft
- **Commit:** `2233311`

##### F007 · High · iPhone

**The iPhone app ships with no CFBundleShortVersionString or CFBundleVersion.**

- **Where:** `ios/project.yml:38` (broken-feature)
- **Scenario:** Build the Aloud scheme in any configuration, then Archive and Validate or upload to App Store Connect. The bundle's Info.plist has no version keys, so validation rejects the build (ITMS-90056/90057: the Info.plist is missing the required CFBundleVersion and CFBundleShortVersionString), and TestFlight is impossible.
- **Root cause:** I found no guard: the iPhone target never sets MARKETING_VERSION or CURRENT_PROJECT_VERSION, either at target level or project level. With GENERATE_INFOPLIST_FILE=YES, Xcode builds both version keys from those two settings and replaces whatever is in INFOPLIST_FILE.
- **Fix:** Added MARKETING_VERSION "1.0" and CURRENT_PROJECT_VERSION "1" to targets.Aloud.settings.base in project.yml, with the same comment the Mac block uses. The spec lint checks that every application target sets both keys in base.
- **Test:** ReleaseProjectLintTests.testEveryAppTargetCarriesItsVersion (new class in ios/AloudTests/MacProjectLintTests.swift, iOS suite); ShippedBundleTests.testTheAppCarriesItsVersionAndBuild (shared, both hosts)
- **Commit:** `11be15b`

##### F008 · High · iPhone + Mac

**espeak-ng (GPL-3.0) is statically linked into the closed-source shipping binary through sherpa-onnx, and both apps bundle its data, but neither bundle carries the GPL text or a correct source offer.**

- **Where:** `ios/project.yml:22` (broken-feature)
- **Scenario:** Distribute the Release build: Mac via build_app.sh today, iPhone via the App Store later. Recipients get GPL-3 object code with no copy of the license (only LICENSE-kokoro.txt, which is Apache text, is in Resources), no Corresponding Source for the fork actually linked, and no source for the combined work.
- **Root cause:** Every factual claim checks out. espeak-ng (GPL-3.0) object code is statically linked into both apps' main binaries, and the apps use it at runtime. Neither bundle contains the GPL text: only Apache text in LICENSE-kokoro.txt, and no COPYING file inside espeak-ng-data.
- **Status:** needs you. Licence decision: espeak-ng is GPL-3.0 and is statically linked through sherpa-onnx.

##### F009 · High · iPhone

**The iPhone Debug and Release builds share the bundle id com.davidxie.Aloud and therefore one data container.**

- **Where:** `ios/project.yml:11` (data-loss)
- **Scenario:** The developer, who also reads with Aloud on their own iPhone, picks that iPhone as the destination in Xcode and runs the Aloud scheme's tests (AloudUITests). The test launch installs over the daily app in the same container and wipes every imported document, all listening progress and the Where-you-stopped history.
- **Root cause:** The bigger hazard is that the README's own way of putting Aloud on an iPhone installs a Debug build. A Debug build contains the -uitest-reset-library hook, and it uses the same bundle id, configuration and data container that the Aloud scheme's Test action installs over.
- **Status:** needs you. Bundle-id decision: give the iPhone Debug build its own id (for example com.davidxie.Aloud.dev) so UI tests can't wipe the shipping library.

##### F013 · Medium · iPhone

**The iPhone never stops its AVAudioEngine after a pause, a stop or the end of a book (idleEngineStopDelay is nil), and AudioSessionManager.deactivate() is never called anywhere.**

- **Where:** `ios/Aloud/Platform/PlatformTuning.swift:28` (bad-ux)
- **Scenario:** A user listens in bed with the phone locked and pauses from the lock screen, or lets the book end or the sleep timer stop it. pause() only pauses the player node (pauseNode). armIdleEngineStop returns at once because the delay is nil (PlaybackController.swift:2271). No code calls audioOutput.deactivate(): the only references are its definitions.
- **Root cause:** On iPhone, nothing stops the AVAudioEngine and nothing deactivates the AVAudioSession once playback stops. This applies to a pause (including from the lock screen), a stop, the end of a book and the sleep timer.
- **Fix:** The iPhone's idleEngineStopDelay is now 60 s. After stopIdleEngine stops a running engine, it calls audioOutput.deactivate() (setActive(false, .notifyOthersOnDeactivation)), except when rendering offline or while resumeAfterInterruption is set.
- **Test:** IdleEngineStopTests.testTheIdleStopLetsTheSessionGoAndPlayClaimsItAgain, testAnInterruptionKeepsTheSessionForItsEnd, testAPauseArmsTheWaitOnEveryPlatform, testTheDelayIsTunedPerPlatform
- **Commit:** `2c33b1f`

##### F014 · Medium · iPhone + Mac

**When a `.now` waiter is cancelled, its job stays in the first-in-first-out now lane with no one waiting for it.**

- **Where:** `ios/Aloud/Playback/SynthesisScheduler.swift:139` (bad-ux)
- **Scenario:** Each seek while playing calls startPlayback, then invalidateSchedule, which cancels the top-up task. The waiter's onCancel runs cancelWaiter and removeWaiter (line 155).
- **Root cause:** The finding holds. When a waiter is cancelled, `cancelWaiter` and `removeWaiter` (SynthesisScheduler.swift:139-159) take the waiter out of its Job but leave the Job in `nowLane`.
- **Fix:** removeWaiter now drops a job once its last waiter leaves. A new Job.isWarmUp flag marks jobs queued by prefetch(), and those are kept.
- **Test:** CatchingUpTests.testASentenceNoOneWaitsForLeavesTheNowLane, CatchingUpTests.testAWarmUpStaysWhenAWaiterGivesUp
- **Commit:** `2233311`

##### F015 · Medium · Mac

**decisionAfterConfigurationChange acts on .follow immediately, while the HAL listener path delays .follow by settleInterval for exactly the AirPods-vanishing case.**

- **Where:** `ios/Aloud/Platform/MacAudioOutputMonitor.swift:73` (bad-ux)
- **Scenario:** A book is reading on AirPods on a Mac. The AirPods leave (case closed, battery dead, or auto-switched to the iPhone).
- **Root cause:** The reported flaw is real in the code, and nothing guards against it. MacAudioOutputMonitor.decisionAfterConfigurationChange (line 73) returns .follow at once.
- **Fix:** A .follow from decisionAfterConfigurationChange onto a device other than the bound one (and not already confirmed by a settle) now answers .ignore and runs the shared settleThenFollow. After the settle, a stop pauses.
- **Test:** MacAudioOutputMonitorTests.testAnEngineChangeWhileAirPodsLeaveNeverFollowsToTheSpeakers, testAnEngineChangeOntoTheListenersSwitchIsFollowedOnceSettled, testAFormatChangeOnTheBoundDeviceIsFollowedAtOnce
- **Commit:** `2c33b1f`

##### F016 · Medium · iPhone + Mac (twin fixed on the other platform)

**Seeking while paused leaves up to 8 stale cue prefetches in the bounded prefetch lane.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:1553` (broken-feature)
- **Scenario:** Each paused seek or skip calls invalidateSchedule and then cuePrefetch() (line 944), which queues 2 prefetch jobs, and nothing ever flushes them. On Play, if the current sentence's clip is already cached, synthesize() returns before admit, so the `.now` preemption that would clear the lane never happens.
- **Root cause:** The mechanism is real. A seek or skip while paused never clears the prefetch lane.
- **Fix:** Scheduler: a .prefetch request someone waits on is now put ahead of warm-ups nobody waits on. When the lane is full it replaces the oldest of those warm-ups. backlogFull is thrown only when all 8 queued jobs have waiters, which the one-at-a-time top-up never reaches.
- **Test:** CatchingUpTests.testAWaitedPrefetchDisplacesStaleWarmUps, CatchingUpTests.testAPausedSeekDropsTheOldCuesWarmUps
- **Commit:** `2233311`, `d376e46`

##### F017 · Medium · iPhone

**AudioSessionManager observes only interruption and route-change notifications, not AVAudioSession.mediaServicesWereResetNotification.**

- **Where:** `ios/Aloud/Playback/AudioSessionManager.swift:15` (broken-feature)
- **Scenario:** The system resets media services: mediaserverd or the Bluetooth audio stack restarts, sometimes during a Bluetooth glitch or an OS update. Apple requires apps to dispose of and recreate their audio objects and reapply the category.
- **Root cause:** The code-level claim holds. Nothing in the repo observes AVAudioSession.mediaServicesWereResetNotification (grep over ios/ finds no matches).
- **Fix:** PlatformAudio.mediaServicesReset (iOS: AVAudioSession.mediaServicesWereResetNotification; Mac: nil) lives in PlatformTuning.swift, which keeps the platform branch out of shared PlaybackController (PlatformBoundaryLint). The controller observes it on lifecycle ?? .default. mediaServicesWereReset() stops with .playbackError, invalidates the schedule, drops the render pump, and rebuilds audioEngine, player and timePitch (now private vars) with graphFormat set to nil. assembleAudioGraph() re-attaches the nodes and moves the configuration-change observer, now a separate engineConfigurationObserver that deinit removes.
- **Test:** PlaybackConfigurationChangeTests.testAMediaServicesResetStopsAndPlaysOnANewEngine (skips on Mac)
- **Commit:** `2c33b1f`

##### F018 · Medium · iPhone

**On iPhone, a download left in the background stops after model.onnx.**

- **Where:** `ios/Aloud/TTS/ModelManager.swift:243` (broken-feature)
- **Scenario:** The user taps Download on home Wi-Fi and locks the phone or switches apps with nothing playing, so Aloud is suspended. nsurlsessiond finishes model.onnx (326 MB), but the app is never resumed to hash it or start voices.bin. The next day the user is offline (plane or subway) and opens Aloud.
- **Root cause:** The mechanism is real. Both background sessions are built with `sessionSendsLaunchEvents = false` (ModelManager.swift:243).
- **Fix:** When a run starts, it now also starts the tasks for every later file that isn't staged yet (queueLaterFiles, queuedTasks). A suspended iPhone's background session therefore fetches voices.bin along with model.onnx.
- **Test:** ModelVerificationTests.testARunQueuesEveryLaterFileNotYetStaged (tests only the pure filesQueuedAhead decision)
- **Commit:** `f003a7c`

##### F019 · Medium · iPhone + Mac

**After a cancel or failure, the verified 326 MB staging/model.onnx stays on disk. cancelDownload (638-646) and fail (780-785) never remove it.**

- **Where:** `ios/Aloud/TTS/ModelManager.swift:585` (broken-feature)
- **Scenario:** The device has 800 MB free, which passes the 707 MB check. model.onnx downloads and verifies into staging, leaving about 474 MB free. The user taps X to cancel, or voices.bin fails with an HF 5xx (shown as .interrupted).
- **Root cause:** The code path is real and I found nothing that guards it. In ios/Aloud/TTS/ModelManager.swift, verifyStagedFile (750-771) leaves a verified model.onnx (325,630,829 bytes) in installDirectory/staging, then starts voices.bin.
- **Fix:** hasRoom(freeBytes:stagedBytes:) now subtracts the bytes of files already staged at their exact size, in both requestDownload and startDownload. startDownload sets isExcludedFromBackup on the install directory when it creates staging. The new stagedBytes accessor feeds a confirmed 'Remove Download' on Settings' card (showsInstalledState) in the failed and not-installed states while staged bytes exist.
- **Test:** ModelDownloadStateTests.testStagedFilesCountTowardTheRoom; ModelVerificationTests.testStagedFilesCountTowardTheRoomAndStayOutOfBackups
- **Commit:** `f003a7c`

##### F020 · Medium · iPhone + Mac

**startTask deletes the resume data before it knows whether the resumed task works (693-697).**

- **Where:** `ios/Aloud/TTS/ModelManager.swift:694` (bad-ux)
- **Scenario:** The user cancels at 80% of model.onnx (cancelKeepingResumeData writes model.onnx.resume), or force-quits mid-download, and comes back the next day. Download resumes from the stored redirect URL, whose signature has expired.
- **Root cause:** I confirmed this and reproduced it. A resumed task asks for the stored post-redirect CDN URL directly; it does not go back through huggingface.co/resolve.
- **Fix:** track() records whether the active task resumed from resume data (activeTaskResumed). In fileFailed, an .interrupted failure from such a task, with no new resume data file left, clears the task and calls startTask on the same file.
- **Test:** ModelDownloadStateTests.testOnlyAResumedTaskThatLeftNothingStartsOver (pure rule)
- **Commit:** `f003a7c`

##### F021 · Medium · iPhone + Mac (twin fixed on the other platform)

**inFlightState returns .downloading whenever the run allows cellular, even when there is no network at all. setInFlight (831-833) only passes allowsWiFiOnlyTransfer, which cannot tell "on cellular" from "offline".**

- **Where:** `ios/Aloud/TTS/ModelManager.swift:226` (bad-ux)
- **Scenario:** On LTE the user confirms "Download 353 MB on cellular?", then enters a tunnel or turns on airplane mode at 37%. The background session quietly waits for connectivity.
- **Root cause:** ModelManager.inFlightState (ios/Aloud/TTS/ModelManager.swift:224-227) returns `allowsCellular || wifiAvailable ? .downloading : .waitingForWiFi`. setInFlight (831-833) passes only `pathSource.allowsWiFiOnlyTransfer`. SystemNetworkPath.allowsWiFiOnlyTransfer (NetworkPathSource.swift:73-76) is false both on a satisfied-but-expensive path (LTE) and on an unsatisfied path (no network), so inFlightState cannot tell the two apart.
- **Fix:** inFlightState takes a new networkAvailable argument, defaulting to true. setInFlight passes networkAvailable(on:), which is allowsWiFiOnlyTransfer || isExpensiveOrConstrained, so NetworkPathSource needed no change. A cellular-allowed run with no network now goes to .waitingForWiFi, and both the card and its announcement use ModelManager.waitingLine: 'Download paused · waiting for a connection' (new NaturalVoiceCopy.waitingForConnection).
- **Test:** ModelDownloadStateTests.testNoNetworkAtAllIsWaitingEvenOnCellular; ModelVerificationTests.testACellularRunWithNoNetworkWaits
- **Commit:** `f003a7c`, `d376e46`

##### F022 · Medium · iPhone + Mac

**A plain-text book that is hard-wrapped and marks paragraphs by indenting, with no blank lines, is imported as one paragraph with no chapters, because paragraphs(in:) only splits on blank lines.**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:71` (broken-feature)
- **Scenario:** isOneParagraphPerLine is designed to return false for indented, hard-wrapped text (the testIndentedWrappedParagraphsAreNotSplitPerLine test asserts this). paragraphs(in:) then splits only at blank lines, so every line in the file goes into a single RawParagraph. 'CHAPTER I' lines are swallowed too. isChapterHeading rejects any paragraph over 600 UTF-8 bytes, so the book gets one page and one paragraph.
- **Root cause:** The bug is real and I could not find a guard against it. If a .txt has no blank lines and is hard-wrapped, isOneParagraphPerLine (TextExtractor.swift:103-122) returns false on purpose, through its `wrapped` test. paragraphs(in:) (lines 55-80) then flushes only on blank lines (lines 70-72), so every line in the file ends up in one RawParagraph.
- **Fix:** New TextExtractor.isIndentedParagraphLayout: blank lines rare, at least 6 lines, between 5% and 50% of lines indented by 2 or more columns. In that layout an indented line starts a paragraph.
- **Test:** ExtractionLineParagraphTests.testIndentedParagraphsWithoutBlankLinesSplitAtIndentsAndHeadings
- **Commit:** `97896a3`

##### F023 · Medium · iPhone

**Once a Wi-Fi-only run is in .waitingForWiFi, nothing offers to continue on cellular. requestDownload returns .started for in-flight states (577-578), so no surface can raise the cellular prompt...**

- **Where:** `ios/Aloud/TTS/ModelManager.swift:577` (bad-ux)
- **Scenario:** A download starts on home Wi-Fi and the user leaves the house. The card reads "Download paused · waiting for Wi-Fi", and the user wants to finish on LTE.
- **Root cause:** Once a Wi-Fi-only run reaches .waitingForWiFi, no surface can raise the cellular prompt, and nothing in ModelManager can move a running download onto the cellular session. allowsCellularThisRun is set in only two places: startDownload (line 623) and reattach (line 863). The only way to download on cellular is to Cancel and then tap Download again, and the screen never suggests it.
- **Fix:** New canContinueOnCellular: true while a Wi-Fi-only run is waiting and the path is expensive or constrained. In that state requestDownload returns .needsCellularConfirmation. startDownload(allowingCellular: true) then calls continueOnCellular(), which cancels the Wi-Fi tasks (keeping resume data), waits for every hand-over with a DispatchGroup, then restarts the run on the cellular session from that resume data.
- **Test:** ModelVerificationTests.testAWaitingWiFiOnlyRunCanContinueOnCellular
- **Commit:** `f003a7c`

##### F024 · Medium · iPhone + Mac

**A scanned PDF is rejected only when it yields no sentences at all.**

- **Where:** `ios/Aloud/Extraction/ExtractionPipeline.swift:103` (bad-ux)
- **Scenario:** Google Books public-domain PDFs are page images with no OCR text, except a first page of usage notice that has real text. PDFTextExtractor gets text only from page 1. buildContent finds a non-empty sentence list, so noReadableText (shown as .pdfNoText) is never thrown.
- **Root cause:** Nothing checks how many pages have text. `ExtractionPipeline.buildContent` throws `noReadableText`, which the user sees as `.pdfNoText` ("This PDF has no readable text."), only when the sentence list is completely empty (`ExtractionPipeline.swift:103`).
- **Fix:** PDFTextExtractor counts pages that yield paragraphs after noise stripping. When there are 5 or more pages and under 10% have text, it throws noReadableText, which shows the existing .pdfNoText copy.
- **Test:** PDFTextExtractorTests.testMostlyScannedPDFThrowsNoReadableText
- **Commit:** `97896a3`

##### F025 · Medium · iPhone + Mac

**Text decoding falls back to Windows-1252 and then Latin-1, and Latin-1 accepts any bytes.**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:1195` (bad-ux)
- **Scenario:** read() tries strict UTF-8 first, then String(contentsOf:usedEncoding:), which needs a byte-order mark or an encoding attribute on the file. Next comes repairingStrayBytes, which only accepts mostly-UTF-8 data, then CP1252, then Latin-1.
- **Root cause:** TextExtractor.read() (ios/Aloud/Extraction/TextExtractor.swift:1186-1198) tries five decoders in order: strict UTF-8, then String(contentsOf:usedEncoding:), then repairingStrayBytes, then .windowsCP1252, then .isoLatin1. Latin-1 maps every byte to a character, so the final `throw ExtractionError.unreadableTextFile` can only happen when the file cannot be read at all.
- **Fix:** TextExtractor.read now reads the data once. It decodes BOM-less UTF-16 (zero bytes on alternating offsets).
- **Test:** ExtractionEncodingTests.testLegacyNonWesternEncodingsAreDecoded; ExtractionEncodingTests.testBinaryUnderATextNameIsRefused
- **Commit:** `97896a3`

##### F026 · Medium · iPhone + Mac (twin fixed on the other platform)

**Opening a book does not cancel a Continue-circle load that is still running for a different book.**

- **Where:** `ios/Aloud/Library/LibraryView.swift:243` (broken-feature)
- **Scenario:** At launch the controller holds no book, so the hero's circle takes the load path (ContinuePlayback.toggle -> start, pendingDocumentID = A, store.liveContent(A)). If the user opens another book C before A's load finishes (grid card via LibraryView.open -> router.open, Mac grid onOpen at MacLibraryView.swift:206, a Classics add, Open-in), ReaderScreen.load (ReaderScreen.swift:275) loads C and autoplays it.
- **Root cause:** The finding is confirmed, but the race window is narrow, so I rated it medium. Nothing in the code calls ContinuePlayback.cancel() when a different book is opened.
- **Fix:** Shared fix for both apps in ContinuePlayback.start. It records which book the controller held at the tap.
- **Test:** ContinuePlaybackTests.testAReaderThatOpenedAnotherBookMeanwhileKeepsIt, testATapOnAnotherBooksCircleStillReplacesTheLoadedBook, testOpeningAnotherBookCancelsTheLoad, testTheShelfStopsTheCirclesLoadWhenItOpensABook
- **Commit:** `bcbf873`, `f8eb49f`

##### F029 · Medium · iPhone + Mac

**Search splits the query on whitespace only, and each token must appear as a literal substring.**

- **Where:** `ios/Aloud/Models/BookshelfCatalog.swift:147` (bad-ux)
- **Scenario:** fold() keeps punctuation, and tokens come from q.split(whereSeparator: \.isWhitespace). A token like "h.g.", "&" or "holmes," must appear verbatim in `title + " " + author`. catalog_normalize.normalize_author (lines 122-126) also rewrites "H.G.
- **Root cause:** BookshelfIndex.search (ios/Aloud/Models/BookshelfCatalog.swift:143-157) folds the query only for case, diacritics, width and curly apostrophes (fold, lines 161-166). It then splits on whitespace (line 147) and requires every token to be a literal substring of `title + " " + author` (line 152).
- **Fix:** New BookshelfIndex.searchWords folds both the books and the query to the same words: "&" becomes "and", apostrophes are dropped, other punctuation splits words, and runs of single-letter initials join ("h.g.", "h. g." and "hg" all become "hg"). If the query ends mid-word, a final single letter stays its own word, so typing "h.g. w" keeps matching.
- **Test:** BookshelfSearchTests: testInitialsMatchHoweverTheyArePunctuated, testInitialsKeepMatchingWhileTyped, testAmpersandIsAnd, testApostrophesAndStrayPunctuationAreOptional, testSingleLetterWordsStillMatch, testPunctuationAloneShowsTheShelves
- **Commit:** `11be15b`

##### F030 · Medium · iPhone (twin fixed on the other platform)

**Every light/dark trait flip rebuilds the whole book's attributed string on the main thread.**

- **Where:** `ios/Aloud/Reader/ReaderTextView.swift:1200` (bad-ux)
- **Scenario:** With Appearance set to System, WindowAppearance leaves the window style unspecified. When the app goes to the background (locking the phone while listening), iOS switches userInterfaceStyle to the other mode and back to snapshot the app.
- **Root cause:** I couldn't refute this. The trigger path is real, and the offset-restore assumption it depends on is wrong under TextKit 2.
- **Fix:** A new TraitLook (style, contrast, Bold Text) is recorded at each rebuild. rebuildForTraitChange now returns early when the look is unchanged or the app is in the background (an injectable isInBackground seam). A Combine didBecomeActive observer calls appBecameActive(), which rebuilds once for a real change made while the app was in the background.
- **Test:** ReaderFollowCoordinatorTests.testTheAppSwitchersSnapshotFlipsRebuildNothing, testALightDarkFlipKeepsThePassageOnScreen
- **Commit:** `bcbf873`, `f8eb49f`

##### F031 · Medium · iPhone (twin fixed on the other platform)

**When a sentence is taller than the follow band, calm follow parks its top on the landing line and never scrolls again until the next sentence.**

- **Where:** `ios/Aloud/Reader/ReaderFollow.swift:31` (bad-ux)
- **Scenario:** FollowBand.contains treats a sentence taller than 52% of the viewport as inside the band once its top reaches the 28% landing line. Scrolling is only triggered by sentence changes (setActiveSentence with scroll: true), content-height changes or viewport changes. setActiveWord (ReaderTextView.swift:418-430) never checks whether the underlined word is still visible.
- **Root cause:** The finding holds. Nothing in the code scrolls the column while a sentence is being spoken.
- **Fix:** Added the pure rules FollowBand.isTall and FollowBand.followed(sentence:word:in:). A tall sentence stays parked on the landing line until the spoken word would fall below the band's bottom; past that, following targets the word's line.
- **Test:** FollowBandTests.testATallSentenceIsFollowedByItsSpokenWordPastTheBand, ReaderFollowCoordinatorTests.testASentenceTallerThanTheBandKeepsItsSpokenWordInTheBand
- **Commit:** `bcbf873`, `f8eb49f`

##### F032 · Medium · iPhone

**A VoiceOver three-finger scroll that scrolls nothing still turns following off.**

- **Where:** `ios/Aloud/Reader/ReaderTextView.swift:1173` (bad-ux)
- **Scenario:** accessibilityScroll calls onAccessibilityScroll, then userTookOverScroll, then follow.takeOver() (isFollowing = false) before super.accessibilityScroll runs. If super returns false (a three-finger swipe down at the top of the text, up at the end, or a left/right swipe on a column that only scrolls vertically), no animated scroll runs. scrollViewDidEndScrollingAnimation and userScrollEnded are never called, so isFollowing never comes back on.
- **Root cause:** I could not refute it. The trace through the code is clear.
- **Fix:** ReaderUITextView.accessibilityScroll now keeps super's result. When super returns false (the scroll moved nothing), it calls a new onAccessibilityScrollIgnored, wired to userScrollEnded(), so following comes back while the voice is in view.
- **Test:** ReaderFollowCoordinatorTests.testAVoiceOverScrollThatMovesNothingKeepsFollowing
- **Commit:** `bcbf873`

##### F036 · Medium · iPhone + Mac (twin fixed on the other platform)

**If an import or delete is interrupted, files are left in the library folder and never cleaned up.**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:78` (bad-ux)
- **Scenario:** importPDF copies the source to libraryDir/<UUID>.pdf (line 78), writes the content cache (94) and only then calls insert()/persistIndex (112). The copy at line 78 also sits outside the do/catch cleanup.
- **Root cause:** I could not refute it. Nothing in the app ever lists or sweeps the library folder or the iPhone's Documents/Inbox. importPDF and importText copy the source to libraryDir/<UUID>.pdf or .txt (DocumentStore.swift:78 and :130), then run a long extraction.
- **Fix:** This fixes the library-folder leak only. New nonisolated static DocumentStore.removeOrphanedFiles(in:keeping:).
- **Test:** LaunchRestoreTests.testTheLaunchSweepRemovesOnlyFilesNoRecordClaims
- **Commit:** `1c16d54`, `d376e46`

##### F039 · Medium · iPhone + Mac

**A remote Play or Play/Pause on a book that has played to its end restarts it from the first sentence.**

- **Where:** `ios/Aloud/NowPlaying/NowPlayingManager.swift:155` (broken-feature)
- **Scenario:** A book plays to its natural end, so the controller stays loaded at .ended and Now Playing still names Aloud. Later the listener connects to the car, and the head unit sends the Play command on connect (the comment at NowPlayingManager.swift:151 says cars do this). perform(.play) sees !isListenerPlaying and calls playback.play().
- **Root cause:** The code path is real, and no guard stops it. While the app process is alive, a book that reaches its natural end stays loaded at .ended with Now Playing still published.
- **Fix:** In the shared NowPlayingManager.perform, remote .play does nothing when playback.isAtEnd. .togglePlayPause at the end does nothing unless a voice sample over the end is playing, in which case it pauses the sample. This covers the iPhone and the Mac (media keys, AirPods, headset).
- **Test:** NowPlayingManagerTests.testRemotePlayAtTheEndNeverRestartsTheBook
- **Commit:** `1c16d54`

##### F040 · Medium · iPhone + Mac (twin fixed on the other platform)

**In a text book without a chapter list, every search result's context line shows the book's first sentence. location(ofSentence:page:) -> qualifiedTitle -> labels.contextTitle returns the single der...**

- **Where:** `ios/Aloud/Models/ReaderNavigation.swift:222` (bad-ux)
- **Scenario:** Import a prose .txt or article with no chapter headings, open Contents (search only) and search 'the'. Every result row (ContentsSheet.swift:481, MacContentsPanel.swift:395) has the same footnote under it, e.g.
- **Root cause:** In a text book with no chapter headings, every search hit gets the same footnote: the book's first sentence, cut to 60 characters. I found no guard against it.
- **Fix:** New ReaderNavigation.searchLocation(ofSentence:page:) -> String?. It returns nil for text without a chapter list; otherwise it is location().
- **Test:** ReaderNavigationTests.testASearchHitInChapterlessTextHasNoLocation
- **Commit:** `1c16d54`, `f8eb49f`

##### F041 · Medium · iPhone + Mac (twin fixed on the other platform)

**VoiceOver gets no feedback when a Contents search lands. scheduleSearch only assigns results/searchedQuery, with no announcement of 'N matches' or 'No matches for …'.**

- **Where:** `ios/Aloud/Reader/ContentsSheet.swift:534` (bad-ux)
- **Scenario:** With VoiceOver on, open Contents and type 'whale'. After the 200 ms debounce and the scan, the results list and the 'N matches' count appear silently below the focused field.
- **Root cause:** When a Contents search finishes, VoiceOver says nothing. scheduleSearch only sets results and searchedQuery. Neither the sheet nor its result views post an announcement, a layout-changed notification or anything like a live region, so focus stays in the text field and the "N matches" count or "No matches for '…'" text appears silently.
- **Fix:** The shared helper is an extension on ContentsSearch at the end of ReaderNavigation.swift, which both targets compile: countLabel, noMatchesLabel, resultsAnnouncement(count:query:previousCount:), and the @MainActor announceResults(count:query:previousCount:muted:), which posts through PlaybackController.postAnnouncement. It speaks only when the count changed; clearing the field resets it.
- **Test:** ContentsResultSnippetTests.testALandedSearchIsAnnouncedOncePerCount, ContentsResultSnippetTests.testTheResultsAnnouncementGoesThroughTheOneAnnouncementPath
- **Commit:** `1c16d54`, `f8eb49f`

##### F042 · Medium · iPhone + Mac

**With no book loaded, a second Play/Pause press or a Pause cannot cancel the Continue load that the first press started, so the book starts speaking after the listener pressed Pause.**

- **Where:** `ios/Aloud/NowPlaying/NowPlayingManager.swift:188` (bad-ux)
- **Scenario:** After a relaunch (no book in the controller), the listener presses the AirPods or lock-screen Play/Pause. handle() sees no book and calls onPlayWithNoBook, which runs ShortcutActions.continueListening. That starts ContinuePlayback.start, a content load (PDF extraction or a cold cache that takes seconds), and playback.document stays nil meanwhile.
- **Root cause:** The code path is real, and a probe built from the copied logic reproduces it. With no book loaded, NowPlayingManager.handle (NowPlayingManager.swift:176-190) sends every .play and .togglePlayPause to onPlayWithNoBook.
- **Fix:** Added `weak var continuePlayback` and `static func stopsLoadWithNoBook` to NowPlayingManager. With no book loaded and a load pending, handle() cancels the load on .pause or .togglePlayPause.
- **Test:** NowPlayingManagerTests.testAPauseOrASecondPressStopsTheContinueLoad, NowPlayingManagerTests.testRemotePlayJoinsTheContinueLoad
- **Commit:** `1c16d54`

##### F044 · Medium · iPhone + Mac

**The launch-restored reader and the no-book Continue path can pick different books.**

- **Where:** `ios/Aloud/App/LaunchRestore.swift:46` (broken-feature)
- **Scenario:** readerToReopen reopens any unfinished book that was last on screen, including one with progressFraction 0. continueListeningCandidate (DocumentStore.swift:426-440) requires progressFraction > 0. Repro: listen to book A.
- **Root cause:** The launch restore and the no-book Continue path pick books by different rules, and nothing reconciles them. The narrow precondition keeps this at medium rather than high: the last reader's book must be at progress exactly 0.
- **Fix:** readerToReopen now reopens the last reader only when DocumentStore.continueListeningCandidate(in:stop:) returns that same book, so the restore and Continue use one rule. Behaviour change: a book that was opened but never started (progress 0) no longer reopens at launch; the Library shows instead.
- **Test:** LaunchRestoreTests.testTheReopenedReaderIsTheBookContinuePlays
- **Commit:** `1c16d54`

##### F045 · Medium · iPhone + Mac (twin fixed on the other platform)

**A book with an unattended stop in its last minute (Finished by the 60 s slack rule) is not reopened at launch and is skipped by Continue listening and no-book remote Play, which start a different book.**

- **Where:** `ios/Aloud/App/LaunchRestore.swift:48` (bad-ux)
- **Scenario:** A 30-minute sleep timer stops a long book with 45 s left. progressFraction is at least 0.99 and the time left is under finishedSlackSeconds (60), so isFinished is true. PlaybackController.reopensAtItsEnd deliberately keeps such a book paused at its saved sentence because the stop line promises a one-tap resume.
- **Root cause:** Three rules decide whether this book is offered again, and they disagree after a relaunch. PlaybackController.reopensAtItsEnd makes an exception for a book that reads Finished but has an unattended stop on record.
- **Fix:** New DocumentStore.isAtItsEnd(_:stop:) applies PlaybackController.reopensAtItsEnd. continueListeningCandidate and ShelfLayout.init take an optional `stop: PlaybackStop? = nil`. readerToReopen gains `stop:`. AppModel.restoreLastReader passes `stop: playback.stopped` (one more line in AppModel).
- **Test:** LaunchRestoreTests.testAStopInTheLastMinuteKeepsItsBookOnOfferAfterARelaunch
- **Commit:** `1c16d54`, `f8eb49f`, `d376e46`

##### F047 · Medium · iPhone + Mac

**Neither app has a privacy manifest (no PrivacyInfo.xcprivacy anywhere in the tree or in the built Mac bundle), yet both call required-reason APIs: UserDefaults...**

- **Where:** `ios/project.yml:14` (broken-feature)
- **Scenario:** Upload either app to App Store Connect. Since May 2024 a missing NSPrivacyAccessedAPITypes declaration for these API categories gets the build rejected (ITMS-91053 Missing API declaration), so neither app can be submitted.
- **Root cause:** This is confirmed for the iPhone app only. The Mac half does not hold, and the proposed fix is incomplete. iPhone: there is no PrivacyInfo.xcprivacy anywhere.
- **Fix:** New ios/Aloud/Resources/PrivacyInfo.xcprivacy: tracking off, no tracking domains, nothing collected. It declares UserDefaults CA92.1, FileTimestamp C617.1 (ModelManager's stat/attributesOfItem on model files in the container, plus the stat/fstat from the statically linked sherpa-onnx and onnxruntime) and DiskSpace E174.1 (the download space gate).
- **Test:** PrivacyManifestLintTests (testTheiPhoneManifestMatchesItsCode, testTheMacManifestMatchesItsCode, testTheScanReadsCodeNotComments; iOS suite); ReleaseProjectLintTests.testEachAppShipsItsOwnPrivacyManifest; ShippedBundleTests.testThePrivacyManifestShips (both hosts)
- **Commit:** `11be15b`

##### F051 · Medium · iPhone + Mac

**The acknowledgements list only four components, each with a license name and no license text.**

- **Where:** `ios/Aloud/Settings/LicensesView.swift:19` (polish)
- **Scenario:** An App Store or Mac user opens Settings > Licenses (or About Aloud > Credits on the Mac, which reuses LicensesView.entries). BSD-3 requires reproducing the copyright notice, the conditions and the disclaimer in materials provided with binary distributions.
- **Root cause:** The Release binaries statically link protobuf and re2 (BSD-3), abseil, OpenFst and kaldi (Apache-2.0), Eigen (MPL-2.0), and flatbuffers and ONNX Runtime itself (MIT). The only license text in either bundle is LICENSE-kokoro.txt, and no code displays it.
- **Status:** needs you. Licence texts: add the full notices for protobuf, re2, abseil, OpenFst, kaldi and Eigen to the Licenses page.

##### F072 · Low · iPhone + Mac

**A sentence made only of Chinese characters or Japanese kanji makes Kokoro throw TtsError.emptyAudio.**

- **Where:** `ios/Aloud/TTS/KokoroSherpaEngine.swift:139` (broken-feature)
- **Scenario:** Open an English book that quotes a Chinese poem or a Japanese epigraph one line per sentence (or import a Chinese or Japanese book), pick any Kokoro voice and press Play. In sherpa's kokoro-multi-lang-lexicon.cc, text in U+4E00-9FFF goes to ConvertChineseToTokenIDs.
- **Root cause:** The finding is confirmed only in a much narrower form, and the failing input it gives does not trigger it. sherpa-onnx changes "。" to "." before tokenizing and sends punctuation to its own token, so "床前明月光。", "疑是地上霜。" and "举头望明月。" each come back as tokens [0,'.',0]. Kokoro voices that as a short non-empty clip, so no emptyAudio is thrown.
- **Fix:** KokoroSherpaEngine.synthesize returns the existing short silence clip when the spoken text has Han ideographs and nothing else except whitespace (frontendCanVoice). This is decided before any model work, so no TtsError.emptyAudio is thrown and PlaybackController needed no edit.
- **Test:** KokoroRuntimeConfigTests.testALineOfOnlyHanCharactersIsASilence; KokoroRuntimeConfigTests.testOnlyAllHanTextIsUnvoiceable
- **Commit:** `f003a7c`

##### F073 · Low · iPhone + Mac (twin fixed on the other platform)

**If the blended voices file (voices-aloud.bin) can't be built, Velvet, Anchor and Ember quietly speak as Michael for the rest of the session.**

- **Where:** `ios/Aloud/TTS/KokoroSherpaEngine.swift:316` (bad-ux)
- **Scenario:** After an app update that adds or edits a blend recipe, the recipe string no longer matches the stored record, so the first warm-up rebuilds the 28 MB derived file. With KokoroVoiceBlends.swift:196, an atomic write needs about 28 MB free; on a nearly full phone the write fails, or the read-back or hash check fails. preparedVoicesFile then removes the derived files and returns nil.
- **Root cause:** The code path is real and nothing guards it. If KokoroVoiceBlends.preparedVoicesFile returns nil, the engine sets blendFailure = sourceStamp (KokoroSherpaEngine.swift:316).
- **Fix:** Added a lock-guarded KokoroSherpaEngine.blendsAvailable. It is nil until a load decides, then reflects whether the derived file loaded, and it keeps its value across release().
- **Test:** KokoroRuntimeConfigTests.testABlendWithoutItsTableIsPacedAsItsFallback (covers the pacing part and blendsAvailable being nil before a load)
- **Commit:** `f003a7c`, `d376e46`

##### F074 · Low · iPhone + Mac

**When building the blends, the code hashes voices.bin and finds it does not match the pinned file, then throws the result away and only writes a log line.**

- **Where:** `ios/Aloud/TTS/KokoroVoiceBlends.swift:191` (bad-ux)
- **Scenario:** warmUpOnQueue only checks file sizes (ModelManager.installedFilesLookIntact). So a voices.bin that is corrupted on disk but keeps its size passes the load-time check. preparedVoicesFile hashes the source at line 191, sees the mismatch, throws CocoaError(.fileReadCorruptFile), logs a domain and code, and returns nil.
- **Root cause:** The mechanism is real, but real users essentially never hit it, and the reported impact is overstated. At KokoroVoiceBlends.swift:189-193, preparedVoicesFile hashes voices.bin and finds it differs from the pin.
- **Fix:** New KokoroVoiceBlends.prepareVoicesFile returns KokoroPreparedVoices: .blended(URL), .original or .sourceDamaged. A source hash mismatch is reported separately; a stamp change during the read is still .original. preparedVoicesFile is kept as a URL? wrapper for existing callers.
- **Test:** KokoroVoiceBlendsTests.testAWrongSourceHashIsReportedAsDamaged; KokoroVoiceBlendsTests.testTheEngineReportsAVoicesFileThatFailsItsPin
- **Commit:** `f003a7c`

##### F075 · Low · iPhone

**A failed audio-session activation is swallowed (try?).**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:2203` (bad-ux)
- **Scenario:** During a cellular or FaceTime call, the user taps Play in Aloud (in-app or from the lock screen). setActive(true) fails with insufficientPriority or cannotInterruptOthers, which is ignored at line 2203. audioEngine.start() then throws, and the catch at PlaybackController.swift:752 or 1634 calls failPlayback(): status .error, record(.playbackError), and the 'Playback failed' message is shown, announced and saved to the stop store. play(userInitiated:true) also cleared resumeAfterInterruption, so nothing resumes when the call ends, and the reader is left showing an error.
- **Root cause:** The code path is real and nothing guards it. Two things are smaller than reported.
- **Fix:** There is a new shared AudioOutputHeldElsewhere error (in OutputRoutePolicy.swift). AudioSessionManager.activate maps insufficientPriority and cannotInterruptOthers to it. startAudioHardware rethrows only that error and swallows the rest as before, so simulator playback is unaffected.
- **Test:** PlaybackConfigurationChangeTests.testPlayWhileACallHoldsTheAudioPausesAsInterrupted, testAResumeRefusedMidCallWaitsForTheCallsEnd (skip when offline/Mac); UITestFaultsTests.testHeldElsewhereErrorsAreTold
- **Commit:** `2c33b1f`

##### F076 · Low · iPhone + Mac

**The word highlight reads the player node's render position (lastRenderTime) with no output-latency compensation, while sentences advance at `.dataPlayedBack`.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:570` (polish)
- **Scenario:** wordTimingTick (PlaybackController+WordTiming.swift:182-184) maps playerMediaSeconds, which is player.lastRenderTime converted through playerTime(forNodeTime:), onto windows laid out in media seconds. The render position is ahead of what is heard by the device's output latency, which is roughly 150-250 ms on AirPods.
- **Root cause:** Apple's own API contract says the two clocks disagree, and nothing in the repo corrects for it. The size of the effect is a little smaller than reported, and it only shows when the user has turned word highlight on, which is off by default. **The two clocks** - The word tint reads `playerMediaSeconds` (PlaybackController.swift:563-571).
- **Fix:** wordTimingTick now subtracts player.outputPresentationLatency × timePitch.rate from the render clock, using the new static PlaybackController.heardMediaSeconds. This needed a small new internal property, `outputLag`, in PlaybackController.swift's word-timing hooks region next to playerMediaSeconds, because player and timePitch are private there.
- **Test:** WordTimingEstimatorTests.testHeardTimeTrailsTheRenderClockByTheOutputLatency
- **Commit:** `2233311`

##### F077 · Low · iPhone + Mac

**Any non-empty PDF Title metadata takes priority over the name of the file the user picked, so junk titles written by authoring tools become the book's name on the shelf.**

- **Where:** `ios/Aloud/Extraction/ExtractionPipeline.swift:24` (bad-ux)
- **Scenario:** PDFTextExtractor (line 70) only trims the Title attribute. The pipeline then uses output.title before fallbackTitle, and DocumentStore saves content.title as the document title.
- **Root cause:** The finding is real. ExtractionPipeline.swift:24 builds the title as `output.title ?? fallbackTitle ?? fileTitle(pdfURL)`, and PDFTextExtractor.swift:70-72 only trims the Title attribute and drops it when empty.
- **Fix:** PDFTextExtractor.isPlaceholderTitle drops these metadata titles: 'Microsoft Word/PowerPoint/Excel - ...', untitled / Untitled-N, DocumentN, PowerPoint Presentation / PresentationN, and anything ending in a document file extension. The fallback (picked file name) is then used. testMetadataTitleWinsOverFallback still holds.
- **Test:** ExtractionPDFTitleTests.testPlaceholderMetadataTitleFallsBackToTheFileName
- **Commit:** `97896a3`

##### F078 · Low · iPhone + Mac

**Two PDF text checks only work for ASCII.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:249` (polish)
- **Scenario:** A French or German PDF whose sentence runs onto a page that starts with a lowercase accented letter gets split into two paragraphs at the break, and the sentence is spoken as two pieces. In a Chinese PDF, appendLine joins '我们今天去' and '公园散步。' as '我们今天去 公园散步。', so a space appears at every visual line wrap in the reader.
- **Root cause:** Both halves of the report hold up. Nothing downstream repairs them.
- **Fix:** The cross-page stitch rule is now ^[\p{Ll}\p{N}]. appendLine joins without a space when both sides are Han, kana or CJK/fullwidth punctuation. Hangul keeps its space, as the verifier advised.
- **Test:** PDFTextExtractorTests.testNonASCIIContinuationsAndCJKWraps
- **Commit:** `97896a3`

##### F079 · Low · iPhone + Mac (twin fixed on the other platform)

**normalize() removes U+200C ZWNJ and U+200D ZWJ everywhere.**

- **Where:** `ios/Aloud/Extraction/TextNormalizer.swift:173` (polish)
- **Scenario:** translate() drops ZWJ and ZWNJ together with ZWSP and BOM. A sentence containing '👩‍💻' is stored and shown as '👩💻' (two emoji).
- **Root cause:** The finding is correct. The behaviour is real and shows up for real users.
- **Fix:** translate() now holds a ZWJ/ZWNJ back until it sees the next scalar (still a single streaming pass). TextNormalizer.keepsJoiner keeps it when a neighbour is an emoji (or FE0F or an emoji modifier) or a non-Latin letter or mark.
- **Test:** TextNormalizerTests.testJoinersKeptInEmojiAndNonLatinText; ContentsSearchFoldingTests.testJoinerNeedles
- **Commit:** `97896a3`, `8b0fd10`

##### F080 · Low · iPhone + Mac

**While the circle is still loading a book, VoiceOver reads the Continue card as 'playing' even though nothing is audible.**

- **Where:** `ios/Aloud/Library/ContinueListeningCard.swift:83` (polish)
- **Scenario:** isSpeaking = playState.glyph == .pause. PlayButtonState gives .buffering the .pause glyph (value 'buffering').
- **Root cause:** The finding holds. The card's `isSpeaking` is just `playState.glyph == .pause`, and `PlayButtonState` gives `.buffering` the same `.pause` glyph as `.playing`.
- **Fix:** Added ContinueListeningCopy.isSpeaking(_ state:). It is true only when the circle's own value is 'playing', so the card and circle always agree.
- **Test:** ContinueCardStateTests.testOnlyAudiblePlaybackCountsAsSpeaking
- **Commit:** `bcbf873`

##### F081 · Low · iPhone

**The hero's subtitle is capped at 3 lines in the non-accessibility layout.**

- **Where:** `ios/Aloud/Library/ContinueListeningCard.swift:219` (polish)
- **Scenario:** At non-AX sizes the text column next to the 64 pt cover and 44 pt circle is about 163 pt wide on a 375 pt phone. 'Natural voice · not enough space · need <size> free' fills 3 lines at xLarge footnote (15 pt), per the comment at lines 216-218.
- **Root cause:** The trigger in the report does not reproduce. A different, real trigger does cut the same line through the same lineLimit(3).
- **Fix:** Removed lineLimit(3) from the hero subtitle in the non-AX layout. fixedSize(vertical) already lets the card grow. This follows the verifier: the real trigger is Display Zoom (a 280pt card), which happens at every text size, so a cap keyed on dynamicTypeSize would not have helped.
- **Test:** ContinueCardStateTests.testTheSpaceLineIsNeverCutOnANarrowCard
- **Commit:** `bcbf873`

##### F082 · Low · Tooling

**If books/ exists but is empty or has no catalog.json, `rsync -a --delete --exclude catalog.json` deletes every bundled book but keeps the old bundled catalog.json, because excluded files are protected from --delete.**

- **Where:** `ios/sync_bookshelf.sh:24` (broken-feature)
- **Scenario:** Line 12 only guards against a missing directory. books/ can exist and be empty: gutenberg_fetch.py run() creates it with BOOKS_DIR.mkdir before any download succeeds, or OneDrive has created the folder but not synced its contents yet. rsync then removes every .txt from ios/Aloud/Resources/Bookshelf and keeps the old catalog.json. catalog_normalize exits 2 because src/catalog.json is missing, and set -e aborts the script. build_app.sh's check at line 84 would still pass, since catalog.json exists. A later plain Xcode build ships this bundle: every Classics row and the empty-library featured card show the bundledBookMissing failure (DocumentStore.swift:219-220).
- **Root cause:** The mechanism is real and I reproduced it end to end, but the conditions that trigger it are rare, the failure is loud, and it is easy to undo. Mechanism: sync_bookshelf.sh:12 only checks that SRC is a directory.
- **Fix:** sync_bookshelf.sh now runs an inline Python guard before rsync --delete. It requires a readable catalog.json, at least one book, the decoded types, unique ids, and every listed file present as a plain name in the source.
- **Test:** tools/test_build_scripts.py SyncBookshelfTests (empty source, missing listed file, bad year, quoted id, duplicate id, file outside folder, missing source, whole source syncs, real books/ passes the guard); BookshelfCatalogTests.testEveryCatalogBookIsBundled
- **Commit:** `11be15b`

##### F083 · Low · iPhone + Mac

**The catalog is decoded all-or-nothing with try?.**

- **Where:** `ios/Aloud/Models/BookshelfCatalog.swift:175` (broken-feature)
- **Scenario:** The queue is edited by hand. The fetcher copies `"year": item.get("year")` verbatim (gutenberg_fetch.py:317), and catalog_normalize passes every field other than title/author through unchanged.
- **Root cause:** The mechanism is real and I reproduced it. BookshelfCatalog.load (BookshelfCatalog.swift:175) decodes the whole Catalog in one `try?
- **Fix:** BookshelfCatalog now decodes catalog.json one entry at a time through a new BookshelfCatalog.books(inCatalog:). A bad entry is skipped and logged with os Logger, category "bookshelf".
- **Test:** BookshelfCatalogDecodingTests (testOneBadEntryDoesNotEmptyTheShelf, testEntriesThatAreNotBooksAreSkipped, testEveryGoodEntryDecodes, testAnUnreadableCatalogIsEmpty, testTheHeaderSpellingsStillDecode)
- **Commit:** `11be15b`

##### F087 · Low · iPhone

**PDF page numerals and the "· · ·" end mark are set in a fixed 12 pt system font.**

- **Where:** `ios/Aloud/Reader/ReaderColumnText.swift:249` (polish)
- **Scenario:** markAttributes uses MarkFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium) and ignores fontSize (only the spacing scales). ReaderTextSize seeds the body size from Dynamic Type and lets low-vision readers go up to 40 pt, but the page numbers drawn between PDF pages stay 12 pt.
- **Root cause:** In ReaderColumnText.markAttributes the font is hardcoded as MarkFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium). Only the paragraph spacing uses fontSize.
- **Fix:** Added ReaderColumnText.markFontSize(fontSize:) = max(12, (fontSize * 0.6).rounded()). markAttributes uses it, digits stay monospaced. The code is shared, so the Mac column (ReaderColumnView makeAttributedString / makeEndMark) gets it too.
- **Test:** ReaderColumnTextTests.testPageNumeralsAndTheEndMarkScaleWithTheText
- **Commit:** `bcbf873`

##### F089 · Low · iPhone + Mac

**If you pick a voice after a playback error, the error line's "Try again" pauses the voice sample instead of retrying.**

- **Where:** `ios/Aloud/Reader/PlayerBarView.swift:50` (bad-ux)
- **Scenario:** A sentence fails, so the status is .error and the stop is .playbackError. The chapter line shows the retry line (ReaderMessageLine.swift:117-134) and Play shows "Try again".
- **Root cause:** The finding holds. I could not find a guard against it.
- **Fix:** PlayerBarView and MacPlayerBar now pass onRetry: retry. The new retry() calls playback.play(), plus TransportHaptics.emit(.play) on the iPhone. play() over a speaking sample goes through continueAuditionAsPlayback and clears the stop.
- **Test:** PlayerBarLintTests.testRetryLineAlwaysPlays
- **Commit:** `2233311`

##### F090 · Low · iPhone + Mac (twin fixed on the other platform)

**At the end of a book the scrub fill stops at the start of the last sentence, not at the end of the track.**

- **Where:** `ios/Aloud/Reader/PlayerBarView.swift:109` (polish)
- **Scenario:** The fill width is scrubFraction(of: playhead, in: span). That function (ReaderNavigation.swift:323-330) returns where a sentence starts, and at .ended the playhead is the last sentence.
- **Root cause:** The mechanism is real and nothing guards it. At the end of a book, the fill is still drawn at the start of the last sentence, not at 1.0.
- **Fix:** I added ReaderNavigation.scrubFill(of:in:isFinished:), which returns 1 for a finished book, to ios/Aloud/Models/ReaderNavigation.swift. That file is not mine; the change is a minimal 4-line addition next to scrubFraction.
- **Test:** ReaderScrubTests.testAFinishedBookFillsTheTrack, PlayerBarLintTests.testAFinishedBookFillsTheScrub
- **Commit:** `2233311`, `f8eb49f`

##### F091 · Low · iPhone + Mac (twin fixed on the other platform)

**The importer decides between PDF and text from the file extension alone, and the text reader falls back to Latin-1, which accepts any bytes (TextExtractor.swift:1195-1196).**

- **Where:** `ios/Aloud/Import/DocumentImporter.swift:161` (bad-ux)
- **Scenario:** isPDF is just `url.pathExtension.lowercased() == "pdf"`. Anything else goes to importText, then TextExtractor.read: UTF-8 fails, CP1252/Latin-1 succeed, and the PDF's internal syntax ('%PDF-1.7 … obj … stream') becomes sentences.
- **Root cause:** The finding holds, and I reproduced it with the real extraction code. Nothing between the picker or drop and the shelf checks the file's content.
- **Fix:** New nonisolated DocumentImporter.isPDF(url): true for a .pdf extension, or for '%PDF-' in the first 1 KB (security-scoped read; an unreadable file goes by its name). start() uses it, except for pasted text. The text reader also refuses PDF signatures and binary data.
- **Test:** DocumentImporterTests.testPDFSignatureRoutesAMisnamedFileToThePDFReader; ExtractionEncodingTests.testBinaryUnderATextNameIsRefused
- **Commit:** `97896a3`, `f8eb49f`

##### F092 · Low · iPhone + Mac

**In a page-range PDF whose runs are grouped (more than 25 runs), search-result locations mix 'Pages 5–8' and 'Page 6'. labels.spanEndByPage is built from the grouped rows...**

- **Where:** `ios/Aloud/Models/ReaderNavigation.swift:298` (polish)
- **Scenario:** Open a 60-page PDF with no chapter map (Contents groups it into 15 rows of 4 pages) and search a common word. The results read 'Pages 1–4', 'Page 2', 'Page 3', 'Pages 5–8', 'Page 6'.
- **Root cause:** The finding holds. For a PDF with no usable chapter map, ReaderNavigation.init (ReaderNavigation.swift:178-181) sets `raw = Self.pageRows(index.chapters)`.
- **Fix:** When the runs are grouped, ReaderNavigation keeps a runLabels PageLabels built from the ungrouped pageRuns. location(ofSentence:page:) then names the hit's own run ('Page 5' or 'Pages 6–7'), never the group's 'Pages 5–8'. The drawer rows still show the grouped ranges.
- **Test:** ReaderNavigationTests.testASearchHitInAGroupedPageRangePDFNamesItsOwnRun
- **Commit:** `1c16d54`

##### F093 · Low · iPhone + Mac

**searchNeedles does not fold the space characters that TextNormalizer.translate turns into plain spaces before storing sentences (U+00A0 NBSP, U+202F, U+2000–U+200A).**

- **Where:** `ios/Aloud/Models/DocContent.swift:306` (polish)
- **Scenario:** Copy 'Mr. Darcy' from a web page (often written Mr.&nbsp;Darcy) or French text with NBSP before ':' or inside guillemets, and paste it into Contents search.
- **Root cause:** Stored sentences always contain plain spaces. ExtractionPipeline.buildContent (ExtractionPipeline.swift:86) and PDFTextExtractor (line 145) run TextNormalizer.normalize before segmenting.
- **Fix:** searchNeedles maps U+0085, U+00A0, U+202F, U+2028/2029 and U+2000-200A to a space, collapses whitespace runs, and drops whitespace before , . ; : ! ? (the normalizer's step 6).
- **Test:** ContentsSearchFoldingTests.testQuerySpacesFoldLikeStoredText
- **Commit:** `97896a3`

##### F095 · Low · iPhone + Mac (twin fixed on the other platform)

**In the Listening view, tapping "System voice" while it is only standing in for the natural voice does nothing.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:1791` (broken-feature)
- **Scenario:** ListeningView.voiceRow (ListeningView.swift:255) calls playback.selectVoice(voice). selectVoice computes `changed = newVoice != voice` (line 1776) and only sends voiceSelections when changed (line 1791), so AppModel never writes PrefKey.voiceID (AppModel.swift:546-548). With nothing changed while playing, selectVoice also never touches `handoff`.
- **Root cause:** The mechanism is real. While the System voice is only standing in, the Listening view marks the System row as selected.
- **Fix:** Partly fixed. In selectVoice, picking the voice that is already speaking while a switch away from it is pending now cancels the switch (cancelVoiceHandoff).
- **Test:** VoiceHandoffTests.testPickingTheSpeakingVoiceDuringHandoffCancelsIt
- **Commit:** `2233311`, `d376e46`

##### F096 · Low · iPhone + Mac

**Remove Download does not cancel a pending switch to the natural voice that the install started, so the removed natural voice can still take over playback and announce itself.**

- **Where:** `ios/Aloud/App/AppModel.swift:313` (bad-ux)
- **Scenario:** When the model install finishes, handleModelInstalled calls playback.switchVoiceAtSentenceBoundary(to: Michael), which sets `handoff` while System keeps reading. If the model is then removed (ModelDownloadView.swift:246, manager.deleteModel()), observeModelState's removal branch reassigns playback.voice only when `playback.voice.engine == .kokoro` (AppModel.swift:313).
- **Root cause:** The bug is real, but the trigger window is narrow and the app recovers on its own within about three sentences. When the install finishes while System is reading, the handoff is set to Michael and primed.
- **Fix:** New PlaybackController.cancelVoiceHandoff() clears handoff before any invalidate, so a primed splice is never committed. If the splice was already fixed and a schedule is active, it then reloads the current sentence in the voice that is speaking, which drops the incoming voice's clips.
- **Test:** VoiceHandoffTests.testCancellingAPrimedHandoffKeepsTheVoiceSpeaking
- **Commit:** `2233311`

##### F097 · Low · iPhone

**The "Aa" sample in the Text & appearance sheet grows with Dynamic Type, but the page it previews does not.**

- **Where:** `ios/Aloud/Reader/AppearanceSheet.swift:89` (bad-ux)
- **Scenario:** Set iPhone Text Size to xxxLarge, then open a book and tap Aa. The readout says "19 pt", but the sample draws at about 26 pt (19 x 23/17), larger than the page behind it.
- **Root cause:** The mechanism is real. Theme.readerSerif (ios/Aloud/Theme/AloudTheme.swift:140) calls Font.custom(serifFamilyName, size:).
- **Fix:** Theme.readerSerif now uses Font.custom(serifFamilyName, fixedSize: size), so the Aa sample matches the fixed-size column. The Mac caller (MacContentsPanel.swift:779) is unchanged, since macOS has no Dynamic Type.
- **Test:** ReaderLintTests.testTheReaderSerifIsAFixedSize
- **Commit:** `bcbf873`

##### F098 · Low · iPhone + Mac

**Increase Contrast changes only textMuted and the alpha of highlightBg. line and lineStrong (lines 53-54), surface2, textFaint (47) and accentStrong (63) have no high-contrast variant.**

- **Where:** `ios/Aloud/Theme/AloudTheme.swift:53` (bad-ux)
- **Scenario:** Turn on Settings > Accessibility > Display > Increase Contrast, in light mode. (1) The A-/A+ stepper card, the Appearance capsule, the player chips and the Mac chips draw surface2 (1.11:1 against surface) with a line border (1.27:1) or lineStrong (1.57:1).
- **Root cause:** Every fact in the report checks out. In ios/Aloud/Theme/AloudTheme.swift, only textMuted (line 44-45, `highContrast: (0x5A4A34, 0xC2B497)`) and highlightBg (line 68-71, `highContrastAlpha: 0.34`) pass a high-contrast argument to `dynamic()` (line 240). line, lineStrong (53-54), surface2 (34), textFaint (47) and accentStrong (63) resolve to the same value whether Increase Contrast is on or off.
- **Fix:** Increase Contrast variants added. line is 0x8E7C5C light / 0x7A6A4E dark: at least 3.18:1 on bg, bgTint, surface and surface2. lineStrong is 0x7D6B4C / 0x8C7B5D and stays the heavier line. textFaint is 0x6A5B45 / 0xA99A7C: at least 5.6:1 and still below textMuted. accentStrong is 0x7A4C17 / 0xEBC690: underline on the fill goes 4.08 to 4.64 in light and 6.00 to 6.22 in dark. All existing AA pairs still pass (checked with a Python WCAG port, same compositing as the tests).
- **Test:** ThemeTokenContrastTests.testIncreaseContrastTakesEdgesToThreeToOne, testIncreaseContrastNeverLowersTheUnderlineOrTheFaintTier
- **Commit:** `bcbf873`

##### F099 · Low · iPhone (twin fixed on the other platform)

**The A- and A+ text-size buttons cap their glyphs at .xxxLarge but do not opt in to the Large Content Viewer.**

- **Where:** `ios/Aloud/Reader/AppearanceSheet.swift:127` (polish)
- **Scenario:** Set Dynamic Type to AX5 and open the Aa sheet. All the text around the buttons is very large, but the A-/A+ glyphs stay at the xxxLarge title3 size (about 25 pt).
- **Root cause:** The finding is accurate. The A- and A+ step buttons in AppearanceView are capped with `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` and have no Large Content Viewer modifier, so at AX1 to AX5 a long-press shows nothing.
- **Fix:** AppearanceView.stepButton now adds .largeContentViewerIfAvailable { Label(label, systemImage: systemImage) } after its xxxLarge cap. The verifier noted the same gap on iPhone in PlayerBarView.swift: skipButton (cap at line 317) and playButton (cap at line 330).
- **Test:** ReaderLintTests.testCappedControlsInTheAppearanceSheetOfferTheLargeContentViewer
- **Commit:** `bcbf873`, `d376e46`

#### Tooling and release

##### F028 · Medium · Tooling

**When a download is not valid UTF-8, fetch_text falls back to latin-1.**

- **Where:** `tools/gutenberg_fetch.py:155` (broken-feature)
- **Scenario:** A legacy {id}.txt file is encoded in Windows-1252, so raw.decode('utf-8') fails (line 153). raw.decode('latin-1') then maps byte 0x97 (em dash) to U+0097, 0x94 (closing quote) to U+0094 and 0x95 (bullet) to U+0095. The body is saved as UTF-8 with those control characters and rsync copies it into the app bundle unchanged.
- **Root cause:** The symptom is real, but the reported cause is mostly wrong. All four shipped books contain C1 control characters (U+0080–U+009F) in exactly the reported counts: 8954 has 756 U+0097, 5000 has 2 U+0095, 8419 has 2 U+0095 and 7184 has 1 U+0094.
- **Status:** deferred. tools/gutenberg_fetch.py is being edited in another session.

##### F055 · Medium · iPhone + Mac

**strip_boilerplate only removes the START/END header and footer markers.**

- **Where:** `tools/gutenberg_fetch.py:191` (bad-ux)
- **Scenario:** A user adds 'Twenty Years After' from Classics and presses play. Before chapter 1 the app reads a Project Gutenberg volume index table ('LINKED INDEX OF PROJECT GUTENBERG VOLUMES', a column header row, eBook numbers).
- **Root cause:** The finding is real, but the example scenario it gives is wrong. tools/gutenberg_fetch.py:191 strip_boilerplate only cuts at the START/END markers (and the older legacy markers), and nothing else filters the books before they ship. 30 of the 442 bundled .txt files still contain "Project Gutenberg".
- **Status:** deferred. tools/gutenberg_fetch.py is being edited in another session.

##### F084 · Low · Tooling

**The fetcher writes to <its own checkout>/books, but sync_bookshelf.sh always reads the hard-coded main-checkout books/.**

- **Where:** `tools/gutenberg_fetch.py:28` (broken-feature)
- **Scenario:** ROOT = Path(__file__).resolve().parent.parent, so BOOKS_DIR, CATALOG_PATH and LOCK_PATH all live under the worktree. books/ is gitignored and absent in worktrees (confirmed: .claude/worktrees/security-review-7b6c58 has no books/). run() therefore loads an empty catalog and fetches the queue from #1 (Gatsby, Pride and Prejudice, ...), all already in the canonical shelf. sync_bookshelf.sh:8 reads /Users/davidxie/.../Aloud/books/, so the 'topped up' books never get bundled. The worktree's own lock also lets this run alongside the scheduled 09:08 run in the main checkout.
- **Root cause:** The mechanism is real, and I reproduced it with the network stubbed out. In tools/gutenberg_fetch.py:28-33, `ROOT = Path(__file__).resolve().parent.parent`, so BOOKS_DIR, CATALOG_PATH and LOCK_PATH all point inside whichever checkout the script runs from.
- **Status:** deferred. tools/gutenberg_fetch.py is being edited in another session.

##### F085 · Low · Tooling

**Failed or rejected books don't count toward --count, and no delay follows a failure.**

- **Where:** `tools/gutenberg_fetch.py:287` (bad-ux)
- **Scenario:** run() only breaks when `fetched >= count`. When fetch_text returns None (line 285) or the text is rejected (line 291), it hits `continue` without sleeping (POLITE_DELAY_S runs only after a success, line 328).
- **Root cause:** The finding is real. In run(), `fetched` only goes up after a successful save, and the loop only stops at `fetched >= count`.
- **Status:** deferred. tools/gutenberg_fetch.py is being edited in another session.

##### F086 · Low · Tooling

**Lock staleness is judged by the lock file's mtime, which is never refreshed while the run is alive, and release_lock unlinks the lock path unconditionally.**

- **Where:** `tools/gutenberg_fetch.py:224` (broken-feature)
- **Scenario:** A long run, e.g. a large --count or the timeout sweep above, passes STALE_LOCK_S (2 h, wall clock, so laptop sleep counts). The scheduled 09:08 run sees age > STALE_LOCK_S, unlinks the live run's lock (line 228) and takes over.
- **Root cause:** The mechanics are as reported, and I reproduced them on a scratch copy. acquire_lock judges staleness only by the lock file's mtime (tools/gutenberg_fetch.py:221-224). Nothing refreshes that mtime and nothing checks the pid. release_lock (238-242) unlinks the lock without checking who owns it. run() loads catalog.json once (270) and rewrites the whole file from memory after each book (324).
- **Status:** deferred. tools/gutenberg_fetch.py is being edited in another session.

##### F102 · Low · Tooling

**The legacy packager runs `uv run --with pillow`, which fetches an unpinned, unhashed Pillow from PyPI at build time and executes it.**

- **Where:** `legacy/build_web_app.sh:165` (polish)
- **Scenario:** Running legacy/build_web_app.sh installs whatever Pillow release is newest on PyPI that day into a throwaway environment and runs it to render the app icon. A compromised or broken release would run with the user's privileges during the build.
- **Root cause:** The finding is accurate, but it has almost no practical impact. legacy/build_web_app.sh:165 runs `uv run --with pillow --python "$VENV_PY" ...` with no version pin, hash or lock file. The venv does not already have Pillow: the main checkout's backend/.venv has no PIL, and backend/requirements.txt does not list it.
- **Fix:** legacy/build_web_app.sh now runs uv with --with 'pillow==12.3.0', the version the verifier resolved, and a comment explains the pin. The test failed before the change and passes after it.
- **Test:** tools/test_build_scripts.py LegacyPackagerTests.test_every_uv_with_is_pinned
- **Commit:** `11be15b`

#### Web app

##### F057 · Medium · Web app

**getDocument is called without cMapUrl/cMapPacked, so CJK PDFs whose CID fonts use predefined Adobe CMaps lose their text and are rejected as 'scanned documents'.**

- **Where:** `frontend/src/lib/pdf.ts:363` (broken-feature)
- **Scenario:** pdf.js has to fetch built-in CMaps (UniJIS-UCS2-H, 90ms-RKSJ-H, UniGB-UCS2-H, and the Adobe-*-UCS2 toUnicode maps) to decode CID fonts that have no embedded ToUnicode. When cMapUrl is not set, BaseCMapReaderFactory.fetch throws 'Ensure that the cMapUrl and cMapPacked API parameters are provided' (pdf.mjs:6044).
- **Root cause:** frontend/src/lib/pdf.ts:363 calls `pdfjs.getDocument({ data })` with no cMapUrl or cMapPacked. Nothing else in the frontend sets them: there is no grep hit for cMap or cmaps in src/ or the vite config. pdfjs-dist 4.10.38 is installed and its cmaps/ folder holds 169 files, including UniJIS-UCS2-H, 90ms-RKSJ-H and Adobe-Japan1-UCS2, but the app never uses them.
- **Fix:** New lib/pdfCMaps.ts adds bundledCMapReaderFactory, which pdf.ts passes to getDocument({ data, CMapReaderFactory }). It is fed by import.meta.glob('/node_modules/pdfjs-dist/cmaps/*.bcmap', { query: '?url', import: 'default', exhaustive: true }); without `exhaustive`, Vite skips node_modules.
- **Test:** frontend/tests/pdfCMaps.test.ts: 'the bundled CMap reader lets pdf.js extract the Japanese text', plus 'without a CMap reader, pdf.js loses the Japanese text' (shows the original failure) and 'pdf.ts hands pdf.js the bundled CMap reader' (checks the wiring)
- **Commit:** `4eb13ec`

##### F058 · Medium · Web app

**Skipped sentences are never shown to the user: pushToast and markSkipped write to the store, but no component renders `toast` or `skippedSentences`, so playback silently jumps over text.**

- **Where:** `frontend/src/lib/player.ts:395` (broken-feature)
- **Scenario:** When a sentence fails synthesis with an HTTP status, playIndex calls store().markSkipped(i) and pushToast('Skipped a sentence that couldn't be read'), then advances. A grep of src/components, App.tsx and hooks finds no reader of `toast` or `skippedSentences`, and no CSS class for a skipped sentence.
- **Root cause:** The web frontend writes to both store fields but nothing ever reads them. The only writers of `toast` and `skippedSentences` are frontend/src/lib/player.ts:394-395, and no component, hook, App.tsx or CSS reads either one.
- **Fix:** New components/Toast.tsx (role=status, aria-live=polite, closes after 4 s) is mounted in App. Reader adds .is-skipped and a title to skipped sentences.
- **Test:** frontend/tests/player.test.ts 'F058: a skipped sentence loses its mark once it is read'; appWiring.test.ts 'F058: the toast host is mounted'; readerNav.test.ts 'F058: the reader marks skipped sentences inline'; globalsCss.test.ts 'F058: skipped sentences and toasts have styles'
- **Commit:** `4eb13ec`

##### F061 · Medium · Web app (twin fixed on the other platform)

**If audio.play() rejects for any reason other than an abort (autoplay block, undecodable clip), the player stays in status 'playing' with no audio.**

- **Where:** `frontend/src/lib/player.ts:429` (broken-feature)
- **Scenario:** playIndex sets status 'playing', awaits audio.play(), and swallows non-abort rejections ('an autoplay block is non-fatal'), then starts the word loop. ensureAudio only listens for 'ended' and 'loadedmetadata' (lines 137-140) and has no 'error' listener. The UI therefore shows Pause with a highlighted first word, while nothing plays and nothing auto-advances.
- **Root cause:** The code defect is real. In frontend/src/lib/player.ts, playIndex sets status 'playing' at line 429.
- **Fix:** When play() is rejected with NotAllowedError, the player sets wantPlaying=false, status 'paused' and shows the toast 'Press play to start audio'; the next press resumes in place. The resume path does the same.
- **Test:** frontend/tests/player.test.ts: 'F061: an autoplay block pauses with a hint instead of sitting on playing', 'F061: a clip play() cannot decode is skipped, not stuck on playing', 'F061: a media error while playing steps to the next sentence', 'F061: a run of unplayable clips stops with an error rather than skipping the book'
- **Commit:** `4eb13ec`, `8b0fd10`

##### F062 · Medium · Web app

**After the backend recovers, the red 'Speech engine offline' error banner never clears on its own.**

- **Where:** `frontend/src/lib/player.ts:413` (bad-ux)
- **Scenario:** handleSynthError sets the error and engineState 'offline'. The success path in playIndex only calls setEngineState('ok') and never setError(null), which contradicts the store contract 'Cleared automatically on the next successful synthesis' (store.ts:121-126).
- **Root cause:** Both halves hold, and nothing in the code prevents either. (1) The playIndex success path (frontend/src/lib/player.ts:412-413) calls only setEngineState('ok') and setStatus('playing').
- **Fix:** The playIndex success path now calls setError(null) next to setEngineState('ok'). The App bootstrap poll is replaced by lib/engineWatch.ts watchEngine: it probes until healthy, then stops, and restarts whenever engineState changes to 'offline' (it subscribes to the zustand store).
- **Test:** frontend/tests/player.test.ts 'F062: a successful synthesis clears the engine-offline banner'; engineWatch.test.ts 'the watch probes again after an outage and clears the badge on recovery' and 'stop() ends probing even while offline'; appWiring.test.ts 'F062: the engine watch replaces the one-shot health poll'
- **Commit:** `4eb13ec`

##### F063 · Medium · Web app

**No window-level dragover/drop guard: dropping a PDF anywhere except the empty-state button makes the browser navigate to the file, which destroys the current reading session.**

- **Where:** `frontend/src/App.tsx:169` (bad-ux)
- **Scenario:** Only Dropzone's button calls preventDefault on drag events, and it is unmounted once a doc is loaded (App.tsx:169-175). There are no window 'dragover'/'drop' listeners anywhere in src/.
- **Root cause:** The finding holds. The only drag and drop handlers in the web frontend are React props on the Dropzone `<button>` (frontend/src/components/Dropzone.tsx:69-72).
- **Fix:** New lib/dropGuard.ts guardFileDrops(window, onFile) calls preventDefault on file dragover and drop events and leaves drops the Dropzone already handled alone. In App, a dropped PDF replaces the open document (handleReset, then handleFile).
- **Test:** frontend/tests/dropGuard.test.ts (6 tests: dragover claimed, drop handed to the app, no double-handling of a Dropzone drop, text drags ignored, removal, isPdf); appWiring.test.ts 'F063: file drops anywhere on the window are guarded'
- **Commit:** `4eb13ec`

##### F066 · Medium · Web app

**Keyboard focus is destroyed whenever a sentence becomes active or inactive, because the active sentence is a different component type under the same key.**

- **Where:** `frontend/src/components/Reader.tsx:121` (bad-ux)
- **Scenario:** ReaderParagraph renders <ActiveSentence key={sid}> for the active sentence and <span key={sid}> for every other one. React remounts on the type change, so the focused DOM node is removed and focus falls to <body>.
- **Root cause:** Both halves of the report hold up. I reproduced them in a real browser running React 18.3.1 (the version this repo installs), using the same component code.
- **Fix:** Active and inactive sentences now render as the same <span> under the same key, and only the children change: <ActiveWords>, the sole subscriber to currentWord, or plain text. The focused node therefore survives activation. onSentenceKeyDown uses sentenceKeyAction, so Space or Enter seeks.
- **Test:** frontend/tests/readerNav.test.ts 'F066: Space and Enter both activate a focused sentence' and 'F066/F067: the reader renders one sentence element type with a roving tabIndex' (a source guard: no <ActiveSentence>, roving tabIndex)
- **Commit:** `4eb13ec`

##### F067 · Medium · Web app

**Every sentence is a tab stop (role=button, tabIndex=0), and PlayerBar comes after <main> in DOM order, so keyboard users must Tab through every sentence of the book to reach Play, voice or speed.**

- **Where:** `frontend/src/components/Reader.tsx:130` (bad-ux)
- **Scenario:** For a 300-page PDF (thousands of sentences), the transport controls in <footer class='player'> (App.tsx:178) come after all the sentence spans in the tab sequence, and there is no skip link or roving tabindex. Screen-reader users also get thousands of 'button' items in the accessibility tree.
- **Root cause:** Every sentence in the web reader is its own tab stop, and the player footer comes after all of them in DOM order. There is no skip link, no roving tabindex, and no shortcut that moves focus to the footer, so a keyboard-only user on a book-length PDF has to press Tab thousands of times to reach Voice, Speed or Options.
- **Fix:** Roving tabindex. Only tabStopSentence(focusedId, currentSentence, count) gets tabIndex=0; every other sentence gets -1.
- **Test:** frontend/tests/readerNav.test.ts 'F067: arrows, Home and End move focus inside the group, clamped' and 'F067: exactly one sentence is a tab stop'
- **Commit:** `4eb13ec`

##### F104 · Low · Web app

**The playback-speed slider has no visible keyboard focus indicator, because `.rate-slider { outline: none }` overrides the global `:focus-visible` outline.**

- **Where:** `frontend/src/styles/globals.css:917` (polish)
- **Scenario:** `:focus-visible` (line 141) and `.rate-slider` (line 910) have equal specificity, and the later rule wins, so the outline is removed. There is no `.rate-slider:focus-visible` replacement style, so keyboard users cannot see when the speed control has focus (WCAG 2.4.7).
- **Root cause:** The finding holds. In frontend/src/styles/globals.css, the global `:focus-visible` rule at line 141 sets the focus outline, and `.rate-slider` at line 910 later sets `outline: none` (line 917).
- **Fix:** Added `.rate-slider:focus-visible { outline: 2px solid var(--accent); outline-offset: 4px; }` after the .rate-slider rule.
- **Test:** frontend/tests/globalsCss.test.ts 'the speed slider shows an outline when focused from the keyboard'
- **Commit:** `4eb13ec`

### Loop 2: wave 5 re-review of the loop-1 fixes

#### Backend

##### G009 · Medium · Backend

**run.py's new port check tells the user to set ALOUD_PORT, but run.sh starts the reader without passing that port on. frontend/.env.development fixes VITE_API_BASE at http://localhost:8000...**

- **Where:** `run.sh:47` (broken-feature)
- **Scenario:** 1. Port 8000 is held by another program, so run.py exits 1 with 'Stop that program, or set ALOUD_PORT to a free port' (backend/run.py:55).
- **Root cause:** The defect is real. run.sh reads ALOUD_PORT into $PORT. The backend inherits ALOUD_PORT, binds that port, and run.sh polls it before printing 'Aloud is ready'.
- **Fix:** run.sh now starts the reader with `export VITE_API_BASE="${VITE_API_BASE:-http://localhost:$PORT}"`, so the port it waits on is also the one the reader calls. Twin: the extension's default backendUrl is still http://localhost:8000 (extension/src/shared/prefs.ts:25).
- **Test:** backend/tests/test_launchers.py RunShTests.test_reader_is_pointed_at_the_backend_port (failed before: npm saw VITE_API_BASE 'unset'); RunShTests.test_reader_keeps_an_api_base_set_by_hand (guard)
- **Commit:** `ec088af`

##### G011 · Medium · Backend

**The tightened CORS now refuses the extension's own origin (chrome-extension://<id>).**

- **Where:** `backend/app.py:180` (broken-feature)
- **Scenario:** On a second computer, the user sets the popup's Backend URL to http://my-mac.local:8000, which prefs.ts accepts as any http(s) URL. On the Mac, the server runs with ALOUD_HOST=0.0.0.0 ALOUD_ALLOWED_HOSTS=localhost,127.0.0.1,my-mac.local as the README says.
- **Root cause:** I could not refute this. The audit replaced allow_origins=['*'] with a regex that matches only http://localhost and http://127.0.0.1, plus an ALOUD_CORS_ORIGINS list that is empty by default.
- **Fix:** _LOCAL_ORIGIN_REGEX now also matches chrome-extension://[a-p]{32}. The extension's ID changes with each unpacked install because the manifest has no "key", so a single ID cannot be pinned.
- **Test:** test_app_requests.LocalOnlyTests.test_extension_origin_is_allowed (failed before), LocalOnlyTests.test_extension_lookalike_origins_are_refused (guard)
- **Commit:** `ec088af`

##### G027 · Low · Backend

**run.sh validates ALOUD_PORT differently from run.py's env_port, and the new readiness loop has no timeout.**

- **Where:** `run.sh:27` (bad-ux)
- **Scenario:** With ALOUD_PORT=80000 (a typo) or ALOUD_PORT=0, run.sh's regex accepts the value and polls 127.0.0.1:80000 or :0. run.py's env_port rejects it, logs 'Ignoring invalid ALOUD_PORT', and serves on 8000. With ALOUD_PORT='8001 ' (trailing space), run.sh falls back to 8000 while run.py strips the space and serves on 8001.
- **Root cause:** The bug is real, but only a malformed environment variable triggers it. run.sh:26-27 picks a port with `[[ "$PORT" =~ ^[0-9]+$ ]] || PORT=8000`. It neither trims the value nor checks the range. backend/native_app.py:102-118 `env_port()` strips the value, requires 0 < port < 65536, and falls back to 8000 with a warning.
- **Fix:** run.py has a new `--print-port` mode: main(argv) prints PORT from env_port() and exits without preflight or uvicorn. run.sh gets PORT from it, so both always use the same port. The wait loop now has a deadline: ALOUD_START_TIMEOUT, default 120 s.
- **Test:** test_launchers.RunShTests.test_waits_on_the_port_run_py_serves (ALOUD_PORT 80000, 0 and '8001 '; each hung for 10 s before the fix), RunShTests.test_gives_up_when_nothing_answers (hung before), RunShTests.test_timeout_names_a_bind_address_that_leaves_out_loopback, RunHostTests.test_print_port_answers_without_serving (TypeError before)
- **Commit:** `ec088af`

##### G029 · Low · Web app

**The new LAN note says the steps make Aloud reachable 'from a phone', but the phone's only client, the web reader, cannot work that way.**

- **Where:** `README.md:241` (bad-ux)
- **Scenario:** The user runs ALOUD_HOST=0.0.0.0 ALOUD_ALLOWED_HOSTS=localhost,127.0.0.1,my-mac.local ./run.sh and adds http://my-mac.local:5173 to ALOUD_CORS_ORIGINS, as the README says. Opening http://my-mac.local:5173 on the phone fails to connect, because Vite was started without --host.
- **Root cause:** The documentation gap is real, but the report overstates it. README.md:241-248 says the steps let a phone reach Aloud.
- **Fix:** Rewrote the README LAN note. Phone users build the reader once with `cd frontend && npm run build` and open http://my-mac.local:8000.
- **Test:** None (README wording only)
- **Commit:** `ec088af`

##### G030 · Low · Backend

**The cross-site fix (F054) relies on FastAPI's strict_content_type default to refuse a JSON body sent with no Content-Type. requirements.txt still allows fastapi>=0.115, and older releases parse such a body as JSON.**

- **Where:** `backend/requirements.txt:4` (security)
- **Scenario:** On a venv with an older FastAPI that requirements.txt still permits, the user visits a hostile page. It runs fetch('http://localhost:8000/synthesize', {method:'POST', mode:'no-cors', body:new Blob([JSON.stringify({text:'x'.repeat(2000)})])}) in a loop.
- **Root cause:** The F054 cross-site fix only holds because FastAPI 0.132.0 and later default strict_content_type to True. backend/requirements.txt:4 still reads fastapi>=0.115, and every release from 0.115.0 to 0.131.0 parses a body with no Content-Type as JSON. I ran the current backend/app.py, with its CORS, TrustedHost and _BodySizeLimit middleware, under FastAPI 0.131.0 and Starlette 0.52.1.
- **Fix:** Took the preferred route: the /synthesize handler now checks Content-Type itself. Anything other than application/json or application/*+json, parameters ignored, gets 415 with retryable false before enqueue.
- **Test:** test_app_requests.ContentTypeTests.test_untyped_body_is_refused_even_when_the_framework_parses_it (mounts the real handler on FastAPI(strict_content_type=False) to reproduce FastAPI < 0.132; before the fix it returned 200 and synthesized), ContentTypeTests.test_untyped_body_never_reaches_the_worker, ContentTypeTests.test_json_with_a_charset_is_served
- **Commit:** `ec088af`

##### G031 · Low · Backend

**The CORS setup does not list Retry-After in expose_headers.**

- **Where:** `backend/app.py:183` (polish)
- **Scenario:** The web player now sends look-ahead requests in the 'prefetch' lane. When the prefetch backlog is full (for example, extension tabs also reading), /synthesize answers 429 with Retry-After: 1. frontend/src/lib/api.ts:189 cannot read the header across origins, so all three attempts finish in about 1 s, each hitting the same 429.
- **Root cause:** The mechanism is real. The CORSMiddleware call at backend/app.py:177-184 has no expose_headers, and Retry-After is not a CORS-safelisted response header.
- **Fix:** Added expose_headers=["Retry-After"] to CORSMiddleware. The extension twin needs nothing: its service worker reads the header under a host permission that bypasses CORS.
- **Test:** test_app_requests.LocalOnlyTests.test_cross_origin_page_can_read_retry_after (failed before: no Access-Control-Expose-Headers)
- **Commit:** `ec088af`

#### Browser extension

##### G017 · Medium · Extension

**Three unreadable sentences in a row now trap the reader.**

- **Where:** `extension/src/content/player.ts:738` (broken-feature)
- **Scenario:** Turn on 'skip bracketed' and read a transcript or article that has three bracketed-only sentences in a row. spokenText() returns '' for each one, and the player still sends it (player.ts:406), so the backend returns 400 'text must be a non-empty string'. The reader stops at the first of the three.
- **Root cause:** The trap is real in the current code, but it was not introduced by the audit. Nothing guards against it. skipSkippable defaults to true (extension/src/shared/prefs.ts:21). extract.ts's isSpeakable() keeps bracket-only sentences such as '(Laughter.)'. spokenText() returns '' for them. ensure() (player.ts:406) still sends that '' to the backend, and backend/app.py:318 answers 400 with retryable=false. skipSentence() counts each 400 toward the streak.
- **Fix:** player.ts: if the spoken text has no letter or digit (HAS_SPEAKABLE, the same regex as the web player), ensure() makes a SILENT entry and never calls the backend, and playIndex steps past it through the new advanceFrom(), which onEnded now shares. A 400 still counts toward the streak (so a backend that refuses everything still stops instead of racing through the page), but each streak entry now records whether it may be rewound to.
- **Test:** extension/tests/player.test.mjs: 'G017: a sentence with nothing left to say plays as silence and is never sent' and 'G017: a run of sentences the engine refuses stops past them, so play carries on' (both fail on 439e25c)
- **Commit:** `8d79a8d`

##### G018 · Medium · Extension

**The failure streak is not cleared when the user seeks or moves to another sentence (seekTo, next, prev, voice change).**

- **Where:** `extension/src/content/player.ts:731` (bad-ux)
- **Scenario:** Sentences 0 and 1 fail (400 or retries used up) and sentence 2 is still buffering. The user clicks sentence 4 or presses Next, and sentence 4 fails once.
- **Root cause:** I could not refute it, and I reproduced it. `streak` is cleared in only four places: a successful `audio.play()` in `playIndex`, the resume-in-place `.then` in `play()`, `halt()` and `reset()`.
- **Fix:** jump() (next and prev), seekTo() (clicks, seek bar) and reloadCurrent() (voice or skip change) now reset the streak. Web twin, not in my files: frontend/src/lib/player.ts consecutiveSkips is also not reset on seek, next or prev.
- **Test:** extension/tests/player.test.mjs: 'G018: failures before a Next do not count toward a stop after it' and 'G018: failures before a seek do not count toward a stop after it' (both fail on 439e25c)
- **Commit:** `8d79a8d`

##### G019 · Medium · Extension

**After the extension updates or reloads, the orphaned reader keeps playing the audio it already buffered (up to about 60 s).**

- **Where:** `extension/src/content/index.ts:38` (bad-ux)
- **Scenario:** Chrome updates Aloud while a tab is reading. The orphan's onEnded keeps playing cached blob URLs.
- **Root cause:** I could not refute it. Nothing in the extension notices that its context is gone, and nothing lets a new instance stop an old one.
- **Fix:** The reader listens for the 'aloud:takeover' event a newly injected reader sends, and calls teardown() only when extensionAlive() is false. That condition was narrowed by L047 in fb0c3d5, because any page script can dispatch the event. A reader orphaned by an extension reload shuts down when the reloaded extension injects a new one, and a live reader ignores the event.
- **Test:** extension/tests/player.test.mjs 'G019: once the extension is reloaded, cached audio does not play on'; extension/tests/content.test.mjs 'G019: a reader injected after a reload stops the orphan left from before it' (both fail on 439e25c)
- **Commit:** `8d79a8d`, `fb0c3d5`

##### G020 · Medium · Extension

**F071 is only partly fixed.**

- **Where:** `extension/src/content/navigation.ts:29` (broken-feature)
- **Scenario:** On a docsify or legacy Angular site, the user reads #/quickstart and clicks to #/configuration. hashchange fires, but path+search are unchanged, so check() returns. The app replaces the innerHTML of .markdown-section/main, but the root found by findContentRoot ('article, main') is still connected, so the deferred check at index.ts:107 passes too.
- **Root cause:** The F071 fix still misses hash-routed single-page apps. watchNavigation compares only pathname+search (navigation.ts:25,29). A hashchange only ever fires when nothing but the fragment changed, so the hashchange listener can never call onLeave.
- **Fix:** navigation.ts: the watched address is now path + query + hashRoute(hash). hashRoute keeps only '#/...' and '#!/...' hashes and drops anything after '?', so docsify's in-page '?id=' anchors and ordinary '#section' anchors don't count as leaving. extract.ts gains spanDetached(slices, start, end). The deferred check in index.ts onSentence now tears down when the current sentence's text nodes are detached, not only when the root is.
- **Test:** extension/tests/content.test.mjs: 'G020: a hash-routed app moving to another article ends the reading' and 'G020: text swapped out inside a container the page keeps is noticed' (both fail on 439e25c)
- **Commit:** `8d79a8d`

##### G034 · Low · Extension

**The F070 subframe-selection fix covers only the context menu.**

- **Where:** `extension/src/content/index.ts:314` (bad-ux)
- **Scenario:** The user selects a paragraph in a PDF tab (or an embedded iframe) and presses the toggle shortcut. The top frame's getSelection() is collapsed, so start('page') runs.
- **Root cause:** I couldn't refute the reported path. It is real, but low severity.
- **Fix:** background/index.ts: for the toggle command, subframeSelection() runs executeScript with allFrames under activeTab. It returns {text, focused: document.hasFocus()} from each frame and passes through the selection from a focused subframe (frameId != 0).
- **Test:** extension/tests/background.test.mjs 'G034: the shortcut reads a selection made in the focused subframe' (fails on 439e25c; two guard tests pass either way); extension/tests/content.test.mjs 'G034: the shortcut reads a selection the worker found in a subframe' and 'G034: the PDF message points to the context menu that can read a selection' (both fail on 439e25c)
- **Commit:** `8d79a8d`

#### Mac app

##### G008 · Medium · Mac

**A single click's play now waits out the double-click interval, and only the next mouse-down on the page cancels it.**

- **Where:** `ios/AloudMac/Reader/ReaderColumnView.swift:1513` (broken-feature)
- **Scenario:** handleClick queues a DispatchWorkItem. cancelClickPlay is called only from clickLanded (the next page mouse-down), from tearDown and from a new handleClick. The work item checks only builtHash.
- **Root cause:** I could not refute this. The audit's F005 fix holds a single click's play in a DispatchWorkItem for NSEvent.doubleClickInterval.
- **Fix:** I added a `transportStamp: (() -> Int)?` input to ReaderColumnView (default nil) and a static `transportStamp(of:)`. The stamp combines userPlayAction, jumpSerial, isListenerPlaying and, while paused, currentSentence.
- **Test:** ios/AloudMacTests/ReaderColumnViewTests.swift testAHeldClickGivesWayToAPauseOrAJump: plays, clicks, then pauses; while paused, clicks, then jumps with .chapter; clicks, then calls otherInputArrived. It asserts that none of these held clicks plays, that the monitor is installed only while a click waits, and that a click with nothing in between still plays.
- **Commit:** `0131b87`

##### G010 · Medium · Mac

**copyingName is a single value that is cleared only when the total `staging` count reaches 0.**

- **Where:** `ios/AloudMac/Library/MacAddMenu.swift:169` (bad-ux)
- **Scenario:** cancel() clears copyingName, but the cancelled Task's detached NSFileCoordinator read keeps running, and that batch's files stay counted in `staging` until the read returns. The next batch sets copyingName to its own file.
- **Root cause:** I could not refute this. `copyingName` (MacAddMenu.swift:83) is one shared value.
- **Fix:** MacFileIntake now keeps `copyingFiles: [(batch, name)]` and publishes the newest live entry. Each batch updates or removes only its own entry, at handover or cancel. copyingBatches stores (task, files). cancel() adds the cancelled batches' file counts to `abandoned`, and the cancelled branch subtracts them again. releaseHoldIfSettled checks `staging - abandoned == 0`.
- **Test:** ios/AloudMacTests/MacImportTests.swift. testACancelledCopyStillReadingNeitherShowsNorHolds: big.txt's stage blocks; Cancel, then add notes.txt. It asserts copyingName is nil and the overlay is not shown once notes.txt is added, and that a later two-file batch's holdsOpens is released while the cancelled read still runs. testOverlappingCopiesNameTheOneStillCopying: after the quick drop is added, copyingName is "big.txt".
- **Commit:** `0131b87`

##### G012 · Medium · Mac

**A light/dark or Increase Contrast change now calls arm(anchor, confirming: true).**

- **Where:** `ios/AloudMac/Reader/ReaderColumnView.swift:513` (bad-ux)
- **Scenario:** Before the audit, rebuildForAppearanceChange rebuilt the storage and then called setOffset(offset), with no layout pass through the book. The F030 Mac twin captures a reading anchor and arms it with confirming: true. restore(_:confirmed:) then calls `column?.ensureLayout(through: anchor.range)` after setAttributedString has thrown away all TextKit 2 layout.
- **Root cause:** I could not refute this. The audit introduced it in commit f8eb49f (the "appearance anchor" twin), and a recolor-specific probe shows the cost.
- **Fix:** I replaced the Mac `ReaderInk(appearance:)` in ReaderNSTextView.swift with `ReaderInk.live()`. Its colors are dynamic NSColors that resolve the Theme color for whatever appearance draws them, and the rule images, which use a drawing handler, fill with them. rebuild and setColophon use `.live()`. rebuildForAppearanceChange no longer rebuilds or arms an anchor.
- **Test:** ios/AloudMacTests/ReaderRelayoutTests.swift testAnAppearanceChangeKeepsTheReadersPlaceWhileNotFollowing now asserts: no didProcessEditing edits, no relayout anchor armed, the storage's text color drawn in the new look equals Theme.text resolved for it (and differs from before), and the reader's line stays. MacReaderAccessibilityTests.testAnAppearanceChangeKeepsTheCursorAndTheSelection now expects no edits.
- **Commit:** `0131b87`

#### Shared iPhone/Mac core and iPhone app

##### G000 · High · iPhone + Mac

**The F004 dedupe keeps only the first heading for each (Part, chapter number).**

- **Where:** `ios/Aloud/Extraction/PDFChapters.swift:375` (broken-feature)
- **Scenario:** An outline-less PDF of Emma, laid out 'VOLUME I / CHAPTER I…XVIII', then 'VOLUME II / CHAPTER I…'. 'VOLUME' never matches partHeading, so every chapter counts as part 0.
- **Root cause:** I could not refute this one. I reproduced it with a probe.
- **Fix:** HeadingChapters now drops a numbered heading only when its number equals the previous kept numbered heading's number (a running head right after its chapter's opening). A restart (18 -> 1) always keeps the chapter, with or without a Part heading. partHeading also accepts VOLUME/Volume and 'Book the First'..'the Tenth', so Emma and A Tale of Two Cities rows carry section labels.
- **Test:** PDFChapterTiersTests.testNumberingThatStartsAgainKeepsEveryChapter (synthetic Emma VOLUME I-III x CHAPTER I-IV with running heads, Tale of Two Cities 'Book the First/Second/Third', omnibus second novel plus mid-page PART, preface chapter walk-through); existing testRunningHeadsOfANumberedHeadingCountOnce still passes
- **Commit:** `4e634f5`

##### G001 · Medium · iPhone + Mac

**The new Increase Contrast values for `Theme.line` have about the same luminance as `Theme.accent`.**

- **Where:** `ios/Aloud/Theme/AloudTheme.swift:57` (bad-ux)
- **Scenario:** Turn on Settings > Accessibility > Display & Text Size > Increase Contrast (on the Mac: Increase contrast) in light mode and open a book that is part-way through. The player-bar scrub shows no visible fill.
- **Root cause:** The F098 fix (audit-wave4.json) gave `Theme.line` Increase Contrast values of 0x8E7C5C (light) and 0x7A6A4E (dark). Under Increase Contrast, light-mode `line` now has the same luminance as `accent` (0xA87434), which has no high-contrast variant.
- **Fix:** Added a new token, Theme.track = dynamic(light: 0xE9E1D0, dark: 0x2B2417), with no Increase Contrast variant. All six progress tracks now draw on it (PlayerBarView, BookCover, ModelDownloadView, DocumentImporter, MacScrub, MacImportOverlay), and so does the disabled offline Download capsule in the shared ModelDownloadView, which only shows on the Mac.
- **Test:** ThemeTokenContrastTests.testProgressFillStaysThreeToOneOnItsTrack, ThemeTokenContrastTests.testTheDisabledDownloadLabelStaysLegibleOnTheTrack
- **Commit:** `9ed0000`

##### G002 · Medium · iPhone + Mac (twin fixed on the other platform)

**Every word tick now calls `followIfNeeded`, for every sentence and not only those taller than the band.**

- **Where:** `ios/Aloud/Reader/ReaderTextView.swift:489` (bad-ux)
- **Scenario:** Word highlight on, a book playing. Drag the text up a little to look at the next paragraph, so the spoken sentence sits near the top edge (above 18%) but stays visible, then lift the finger.
- **Root cause:** I found no guard that stops it, and the audit introduced it. Before the audit (1344665), `setActiveWord` never scrolled.
- **Fix:** Added FollowBand.wordTickFollows to the shared code: a word tick re-checks the band only when FollowBand.followed returns the word, meaning a sentence taller than the band, and only when the word has moved to a new line. In ReaderTextView, setSpokenWord now uses this rule.
- **Test:** ReaderFollowCoordinatorTests.testWordTicksNeverPullBackASentenceThatFitsAfterADrag, ReaderFollowCoordinatorTests.testATallSentenceWaitsForTheNextLineAfterADragAndJudgesTheWord
- **Commit:** `9ed0000`, `dd7f1df`

##### G003 · Medium · iPhone + Mac (twin fixed on the other platform)

**The tall-sentence follow fix (FollowBand.followed) runs only on word ticks.**

- **Where:** `ios/Aloud/Reader/ReaderScreen.swift:62` (broken-feature)
- **Scenario:** Default settings (Word highlight off). Set the Aa stepper to its largest size and play a book with long sentences (Gibbon, Melville).
- **Root cause:** I could not refute it. The tall-sentence fix only works when a spoken word position exists, and with the default Word highlight off there is none.
- **Fix:** ReaderTextView has a new input, followWord, which is never drawn. The coordinator tracks it as spokenWordRange next to the underline's activeWordRange. setActiveWord(_:follows:true) still sets both.
- **Test:** ReaderFollowCoordinatorTests.testATallSentenceFollowsTheSpokenWordWithTheUnderlineOff, ReaderFollowCoordinatorTests.testTheWordTickerRunsForFollowingWithTheHighlightOff
- **Commit:** `9ed0000`, `dd7f1df`

##### G004 · Medium · iPhone

**The new 60 s idle stop on iPhone gives the session back with .notifyOthersOnDeactivation after every pause.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:2465` (bad-ux)
- **Scenario:** 1. Music or Spotify is playing.
- **Root cause:** The path is real and nothing in the code blocks it. Any ordinary pause, including the in-app button, a remote or lock-screen Pause, an AirPods pause and the sleep timer's landing, sets status to .paused.
- **Fix:** AudioOutputMonitoring.deactivate() is now deactivate(notifyingOthers:). In stopIdleEngine, other apps are notified only when status == .idle (book closed) or when status == .ended with requestedOutputVolume >= 1, which is the same 'heard to the end' test R24 uses.
- **Test:** IdleEngineStopTests.testAPauseGivesTheSessionBackWithoutWakingAnotherApp; IdleEngineStopTests.testTheBooksEndLetsAnInterruptedAppResume (two cases: heard to the end, and under a sleep-style fade)
- **Commit:** `6d42f4d`

##### G005 · Medium · iPhone + Mac

**The new per-page running-header rule (F003) strips chapter-opening headings in books with short chapters. normalizeRunning turns 'CHAPTER 12' into 'chapter #'.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:309` (broken-feature)
- **Scenario:** Import a thriller, children's chapter book or devotional ('Day 12') PDF without bookmarks, with 2–4 page chapters, each opening page starting 'CHAPTER n' above a gap. I compiled the real runningHeadersByPage and stripNoise against a synthetic layout of 12 chapters of 3 pages each with the heading at y=500: all 12 headings were stripped.
- **Root cause:** The core claim holds. The audit-added runningHeadersByPage (PDFTextExtractor.swift:286-327) folds digits, so 'CHAPTER 12' becomes 'chapter #'.
- **Fix:** New PDFTextExtractor.areChapterOpenings: a run whose lines start with chapter/day/letter/lesson/week/part/book/volume/section + digits, with a different number at every hit, is a run of openings, not a running header. Applied to the per-page run rule (runningHeadersByPage) and to the document-wide rule (detectRunningHeaders), which also stripped 'Day n' on every page.
- **Test:** PDFTextExtractorTests.testNumberedChapterOpeningsAreNeverRunningHeaders (Line-level: 12x3-page 'CHAPTER n', 30 'Day n' page tops, and a control where 'Chapter n The Return' is still stripped) and testShortChaptersKeepTheirHeadingsAndRows (real FixturePDF through ExtractionPipeline: all 12 'Chapter n.' kept, chapterMap .headings with 12 rows)
- **Commit:** `4e634f5`

##### G006 · Medium · iPhone + Mac (twin fixed on the other platform)

**`resumeFollowing` (Play, the Follow chip, Undo, a jump) and `placeActiveSentence` (a text-size or Bold Text reflow) still aim at the tall sentence's top, not at `followedRect`.**

- **Where:** `ios/Aloud/Reader/ReaderTextView.swift:574` (bad-ux)
- **Scenario:** Word highlight on, large text, paused near the end of a sentence taller than the band, scrolled away. Tap the Follow chip: the column lands on the sentence's first line, and the word you'll resume on is under the player bar.
- **Root cause:** Following uses two different targets for a sentence taller than the band. `followIfNeeded` follows the spoken word (`followedRect`, using `FollowBand.followed`).
- **Fix:** resumeFollowing now checks the band and aims at followedRect(sentence:in:). landingTarget() also aims at the followed rect, and placeActiveSentence, checkPlacement and the jump re-aim all use it, so Play from a pause, the Follow chip, a placement check and a reflow mid tall sentence land the spoken word instead of the sentence top. Both rebuild paths re-apply the spoken word before placing: the fresh column in updateUIView and rebuildForTraitChange.
- **Test:** ReaderFollowCoordinatorTests.testPlayFromAPauseInATallSentenceKeepsTheSpokenWordInTheBand, ReaderFollowCoordinatorTests.testResumingOrPlacingMidTallSentenceLandsTheSpokenWord
- **Commit:** `9ed0000`, `dd7f1df`

##### G007 · Medium · iPhone

**Once the idle stop lets iOS suspend a paused Aloud, the ~800 MB Kokoro engine stays loaded if the pause happened while the app was already in the background. releaseNeuralEngineIfIdle runs only at...**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:2452` (broken-feature)
- **Scenario:** 1. The listener plays a book with the screen locked.
- **Root cause:** Partly confirmed. The first claim holds: Kokoro stays loaded in a suspended app, and the path to it is concrete and common.
- **Fix:** stopIdleEngine now calls releaseNeuralEngineIfIdle() when !isAppActive() and PlatformTuning.releasesNeuralOnBackground. This runs before the engine-running guard, so it also covers an engine that was already stopped.
- **Test:** IdleEngineStopTests.testInTheBackgroundTheIdleStopFreesTheNaturalVoice (foreground keeps Kokoro warm; background frees it on iPhone and keeps it on Mac)
- **Commit:** `6d42f4d`

##### G021 · Low · iPhone + Mac

**The F025 mojibake fix is incomplete.**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:1310` (bad-ux)
- **Scenario:** I compiled the real isMostlyHighBytes and legacyDecoded and ran them on four files: Greek in CP1253, Hebrew in CP1255, Arabic in CP1256 and Thai in CP874. Each was 'mostly high bytes', and NSString's detector picked 'Cyrillic (Windows)' every time.
- **Root cause:** TextExtractor.read() (ios/Aloud/Extraction/TextExtractor.swift:1221-1246) sends any file whose high bytes outnumber its ASCII letters to legacyDecoded (line 1310). legacyDecoded asks NSString.stringEncoding to choose among GB18030, Big5, Shift-JIS, EUC-JP, EUC-KR, CP1251 and KOI8-R, with lossy conversion off. Single-byte Greek, Hebrew, Arabic and Thai text is never valid in the CJK multi-byte encodings, because a lone high byte is followed by a space.
- **Fix:** legacyDecoded keeps a Windows-1251 or KOI8-R reading only if readsAsCyrillic accepts it. The checks are: letters are at least 80% of visible characters, at least half the letters are lowercase, most letters are Cyrillic, vowels make up 35-60% of the Cyrillic letters, and capitals partway through a word are under 2%.
- **Test:** ExtractionEncodingTests.testOtherSingleByteScriptsAreRefusedNotReadAsCyrillic (Greek CP1253 and ISO-8859-7, Hebrew CP1255, Arabic CP1256 and Thai CP874 all throw unreadableTextFile; an all-caps-heading Russian CP1251 text still decodes); existing testLegacyNonWesternEncodingsAreDecoded still passes
- **Commit:** `4e634f5`

##### G022 · Low · iPhone + Mac (twin fixed on the other platform)

**The F078 cross-page stitch now accepts ^[\p{Ll}\p{N}], but Han and kana are \p{Lo}.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:375` (bad-ux)
- **Scenario:** A Chinese PDF whose page 5 ends '我们今天去' and whose page 6 starts '公园散步。'. previous.text isn't finished, but '公' doesn't match ^[\p{Ll}\p{N}], so the text becomes two paragraphs and is spoken as two separate pieces at every page turn. In the opposite case, page 5 ends '…散步。' and page 6 starts '1949年…'. looksFinished('…。') is false and '1' matches \p{N}, so the new paragraph is merged into the previous one.
- **Root cause:** I could not refute either half. The F078 fix (diff 1344665..HEAD, line 375) changed the stitch rule only from ^[a-z0-9] to ^[\p{Ll}\p{N}].
- **Fix:** appendPageParagraphs also stitches when the previous block ends and the new paragraph begins with an unspaced CJK scalar (new continuesUnspacedCJK; appendLine already joins CJK with no space). looksFinished now accepts 。 and the closers 」 』 (NFKC already makes ！？ plain). Both changes ship together, as the verifier required.
- **Test:** PDFTextExtractorTests.testCJKSentencesRejoinAcrossPagesAndFullStopsFinishThem
- **Commit:** `4e634f5`, `ac618b3`, `ac618b3`, `ac618b3`

##### G023 · Low · iPhone

**audioHardwareFailed sets resumeAfterInterruption = true and promises that the end of the interruption will resume playback. iOS delivers interruption-ended only to a session it actually interrupted.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:1837` (bad-ux)
- **Scenario:** 1. The book has been paused for more than 60 s, so the session was released.
- **Root cause:** The code path is real, nothing guards it, and the audit introduced it. The iPhone now stops the engine and deactivates the session 60 s after a pause (idleEngineStopDelay went from nil to 60), and F075 added audioHardwareFailed, which sets resumeAfterInterruption = true.
- **Fix:** New private holdsAudioSession. It is set after a successful audioOutput.activate(), and cleared by the idle stop's deactivate, by interruption .ended (the session comes back inactive) and by mediaServicesWereReset. audioHardwareFailed promises resumeAfterInterruption only while the session is held.
- **Test:** IdleEngineStopTests.testAPlayRefusedAfterTheReleasePromisesNoResume; PlaybackConfigurationChangeTests.testPlayWhileACallHoldsTheAudioPausesAsInterrupted (rewritten to iOS's real behavior: a session Aloud never held gets no interruption end, so the reason is announced at once and Play after the call works)
- **Commit:** `6d42f4d`

##### G024 · Low · iPhone + Mac

**The new binary sniff refuses real text. isBinary rejects a whole file for a single NUL byte. hasPDFSignature matches '%PDF-' anywhere in the first KB...**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:1261` (bad-ux)
- **Scenario:** (1) A UTF-8 .txt book with one stray or trailing NUL. Some exporters and partially synced or preallocated files have one.
- **Root cause:** Both claims hold and both are regressions from the audit. Before 1344665, DocumentImporter routed by extension alone (`isPDF = url.pathExtension.lowercased() == "pdf"`), and TextExtractor.read had no binary check.
- **Fix:** hasPDFSignature now requires '%PDF-' at the start of the first KB, after an optional UTF-8 BOM and whitespace. DocumentImporter.isPDF and MacFileIntake.isPDF use this check too, so they are fixed without any edit to them. isBinary ignores trailing zero padding and counts zero bytes with the other C0 controls under the existing 1% share, so one stray zero no longer refuses a UTF-8 book.
- **Test:** ExtractionEncodingTests.testStrayZerosAndAMentionedSignatureStayText (UTF-8 book with one trailing zero byte, and with 4 KB of zero padding, still reads; a stray mid-file zero is not binary; a notes file that mentions %PDF-1.7 is neither a PDF nor binary; %PDF- at offset 0 or after a BOM and newline is still a PDF); existing testBinaryUnderATextNameIsRefused and the DocumentImporter/MacImport sniff fixtures (all %PDF- at offset 0) are unaffected
- **Commit:** `4e634f5`

##### G025 · Low · iPhone + Mac

**applyTimePitchRate now flips timePitch.bypass from rate's didSet, mid-render.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:99` (polish)
- **Scenario:** While a book plays, the listener drags the speed slider in the Listening view. ListeningView.swift:140 sets playback.rate on every drag tick.
- **Root cause:** I could not refute the mechanism, but the report overstates how big it is. Commit 6e634c0 on the audit branch added `timePitch.bypass = abs(residual - 1) < 0.01` to applyTimePitchRate (PlaybackController.swift:96-100).
- **Fix:** applyTimePitchRate(atBoundary:) always sets timePitch.rate, snapping to 1.0 inside the 1% tolerance. It flips bypass only when atBoundary or !player.isPlaying, and only if the value changes.
- **Test:** NativeSpeedTests.testASliderTickMidSentenceNeverSwitchesTheBypass (a mid-render tick leaves bypass unchanged; dragging back snaps the rate to exactly 1.0; the bypass follows at a boundary); testTheSystemVoiceLeavesTheWholeSpeedToTheUnit now changes speed while paused and expects an immediate switch
- **Commit:** `6d42f4d`

##### G026 · Low · iPhone + Mac (build)

**The new guard checks the source before `rsync --delete`, but catalog_normalize.py still runs only after rsync has replaced the bundle.**

- **Where:** `ios/sync_bookshelf.sh:87` (broken-feature)
- **Scenario:** The developer fixes a title by editing tools/catalog_overrides.json and leaves a JSON syntax error (or a source entry carries "header_title": null). Since the last sync, books/ has also renamed or dropped a book file.
- **Root cause:** The mechanism is real, and I reproduced both triggers. ios/sync_bookshelf.sh:86 runs `rsync --delete --exclude catalog.json` first. Normalize runs after it, at line 87. normalize's main() catches the error (OSError/ValueError/KeyError/TypeError/AttributeError) and returns 2 before write_if_changed runs, so DST/catalog.json stays the previous one while the book files have already been replaced.
- **Fix:** sync_bookshelf.sh now builds the catalog in a mktemp -d staging folder, after the guard and before rsync --delete. If normalize exits above 1 or writes no catalog, the script prints a warning and calls keep_bundle (exit 0, bundle untouched), the same as the guard does.
- **Test:** tools/test_build_scripts.py SyncBookshelfTests: test_a_null_header_title_keeps_the_bundle, test_a_catalog_that_cannot_be_built_keeps_the_bundle, test_overrides_that_are_not_objects_keep_the_bundle. All three failed before the fix (exit 2 after rsync had changed the bundle) and pass after it.
- **Commit:** `1d3d0c3`

#### Web app

##### G013 · Medium · Web app

**Clicking a sentence now leaves keyboard focus on it, because it keeps the same element when it becomes active.**

- **Where:** `frontend/src/components/Reader.tsx:45` (bad-ux)
- **Scenario:** Clicking a span with tabIndex=-1 focuses it in Chrome and Safari. Before the audit, the clicked span was replaced by a different <ActiveSentence> element, so focus fell to <body> and the global useKeyboard shortcuts kept working.
- **Root cause:** I couldn't find anything that stops it. The F066/F067 fix (commit 4d578ef / 4eb13ec) made two changes: the active and inactive sentence are now the same <span> under the same key, and Space now seeks.
- **Fix:** On a focused sentence, Space now calls player.toggle() and Left/Right call player.next()/prev(), with focus following the new current sentence. Enter still plays from the sentence, and Up/Down/Home/End still move focus.
- **Test:** frontend/tests/readerNav.test.ts: 'G013: Space and the side arrows stay transport keys on a focused sentence' and 'G013: the reader sends Space and the side arrows to the player'
- **Commit:** `c21aa63`

##### G014 · Medium · Web app

**The new per-run running-header rule deletes real headings.**

- **Where:** `frontend/src/lib/pdfHeaders.ts:111` (broken-feature)
- **Scenario:** normalizeRunning turns 'Step 1'…'Step 5' into the same key, 'step #'. Each heading is line 0 of its page, in body size, with a blank line after it, so `apart` holds.
- **Root cause:** I tried to refute this and could not. No guard stops it. runningHeadersByPage (frontend/src/lib/pdfHeaders.ts:87-133) builds its key with normalizeRunning, which turns every digit run into '#'.
- **Fix:** The per-run rule now skips a key whose hits begin with different numbers (new headingNumber helper: a label followed by a number). Page labels like 'Page N' and 'p.
- **Test:** frontend/tests/pdfHeaders.test.ts: 'G014: numbered headings that open nearby pages are kept' (plus 'G014: a running head that keeps its leading number but carries a folio still goes')
- **Commit:** `c21aa63`

##### G015 · Medium · Web app

**When a PDF is dropped on an open reader, the window drop guard tears down the open document (player.stop + reset) before the new file is parsed.**

- **Where:** `frontend/src/App.tsx:134` (bad-ux)
- **Scenario:** guardFileDrops' callback calls handleReset() as soon as isPdf(file) passes, which only checks the MIME type or the extension, and then calls handleFile(file). loadPdf rejects encrypted, corrupt and scanned PDFs. handleFile's catch then sets doc null and shows the Dropzone with an error. The previous document and position lived only in memory, so they are gone.
- **Root cause:** I could not refute this, and a probe reproduces it. The window drop callback added for F063 (frontend/src/App.tsx:128-136) only checks two things before tearing the session down: that no load is in progress, and that isPdf(file) passes. isPdf (dropGuard.ts:13-15) looks only at the MIME type or the .pdf extension.
- **Fix:** The intake logic moved into a new file, src/lib/intake.ts, as openPdf(file, {loadPdf, player}). It pauses a playing book, parses the new file, and only then stops the player, resets and loads.
- **Test:** frontend/tests/intake.test.ts (3 tests: an unreadable drop keeps the book, its place and a paused player; a readable drop stops the old book only after parsing; nothing open shows the error) + frontend/tests/appWiring.test.ts 'G015: a dropped PDF is parsed before the open book is closed'
- **Commit:** `c21aa63`

##### G016 · Medium · Web app

**The F062 fix is incomplete.**

- **Where:** `frontend/src/lib/engineWatch.ts:38` (bad-ux)
- **Scenario:** handleSynthError sets error and engineState 'offline' and status 'error'. watchEngine restarts polling on 'offline', and on a healthy probe it calls only setEngineState('ok') and onHealthy (voice loading). Only a later successful synthesis in playIndex clears store.error.
- **Root cause:** The defect is real and I could not refute it. Once the backend is back, nothing clears the engine-offline error until the next successful synthesis.
- **Fix:** Added player.engineRecovered(), which also adds a method to the Player interface. It clears the error only when it is exactly the engine-offline message (now an ENGINE_OFFLINE constant) and moves status 'error' to 'paused'.
- **Test:** frontend/tests/player.test.ts: 'G016: the engine coming back clears the offline banner playback left', 'G016: a healthy probe leaves other errors alone'; frontend/tests/appWiring.test.ts 'G016: a healthy /health answer clears a stale engine-offline banner'
- **Commit:** `c21aa63`

##### G028 · Low · Web app

**The web twin of the ZWJ/ZWNJ fix was missed.**

- **Where:** `frontend/src/lib/pdf.ts:77` (bad-ux)
- **Scenario:** In the web reader, open a PDF that contains '👩‍💻' or the Persian 'می‌خواهم'. The page shows '👩💻' as two emoji and 'میخواهم' as one joined word.
- **Root cause:** frontend/src/lib/pdf.ts:77 still deletes every U+200C and U+200D. Commit 8b0fd10 ported the F079 keep rule to backend/text_normalize.py (_drop_stray_joiners) but never changed pdf.ts.
- **Fix:** New file src/lib/joiners.ts ports backend _keeps_joiner / iOS keepsJoiner using the same ranges. pdf.ts normalizeText step 2 now calls dropStrayJoiners instead of deleting every U+200C/U+200D. As the verifier said, this only helps joiners that pdf.js passes through, such as ligature-mapped ones.
- **Test:** frontend/tests/joiners.test.ts (emoji ZWJ sequences, Persian ZWNJ, Devanagari, Latin debris, and a normalizer wiring check)
- **Commit:** `c21aa63`

##### G032 · Low · Web app (twin fixed on the other platform)

**Look-ahead now goes to the backend's 'prefetch' lane, which answers 429 once 8 requests are waiting.**

- **Where:** `frontend/src/lib/player.ts:405` (broken-feature)
- **Scenario:** ensure() keeps the lane an entry was created with (player.ts:265), so a current sentence created by prefetchAround (player.ts:367) is never upgraded to 'now'. The web player also never aborts look-ahead it no longer needs when the user seeks or presses next, and unlike the extension (MAX_PREFETCH_INFLIGHT = 6) it has no cap on look-ahead in flight.
- **Root cause:** The bug is real but much narrower than reported. Three things hold: the audit moved web look-ahead into the 'prefetch' lane (before it, every request went as 'now', which the backend never refuses); ensure() never moves an in-flight entry up to 'now'; and playIndex sends any status other than null, 429 included, to skip(), with stopAfterSkips leaving the earlier marks behind.
- **Fix:** CacheEntry now records its priority. In playIndex, a prefetch entry that fails with 429/503 is requested again in the 'now' lane: playIndex(i) when playing, or ensure(i) to cue it when paused.
- **Test:** frontend/tests/player.test.ts: 'G032: look-ahead turned away as busy is asked again, not marked unreadable' (fake backend 429s every prefetch; asserts no skip, sentence 1 re-requested as 'now' and playing)
- **Commit:** `c21aa63`, `b2fa042`

##### G033 · Low · Web app

**After three unplayable clips in a row, the error says 'try reloading the page'.**

- **Where:** `frontend/src/lib/player.ts:509` (polish)
- **Scenario:** skipUnplayable → stopAfterSkips('Couldn't play the audio for these sentences — try reloading the page.'). The app does not save the document or position anywhere that survives a reload (the dropGuard header calls the session in-memory only).
- **Root cause:** The audit added this message in commit 4eb13ec. It tells the user to reload the page, and a reload throws away the open document and the reading position.
- **Fix:** The message now reads 'Couldn’t play the audio for these sentences — press Play to try again, or skip ahead.' No twin.
- **Test:** frontend/tests/player.test.ts: 'G033: a run of unplayable clips says to press Play, not to reload the page'
- **Commit:** `c21aa63`

### Loop 3: full review wave 2

#### Backend

##### H026 · Medium · Backend

**The F060 port-in-use check only connects to 127.0.0.1.**

- **Where:** `backend/native_app.py:66` (broken-feature)
- **Scenario:** Another project runs `vite --port 8000`, or a Node server calls listen(8000,'localhost'). Node 17+ binds that to ::1 only.
- **Root cause:** The finding holds, and the F060 fix has a gap. port_in_use() in backend/native_app.py:57-70 is the only busy-port check. It calls socket.create_connection(("127.0.0.1", port)), so a listener bound only to [::1]:8000 refuses the connection and the port counts as free. run.py preflight() and native_app's choose_port() and probe_backend() all use this check. uvicorn then binds 127.0.0.1:8000 without error, because the two sockets are different address families. run.sh's backend_ready also dials 127.0.0.1, so it gets Aloud's own /health and prints "Aloud is ready".
- **Fix:** port_in_use() now checks both 127.0.0.1 and ::1 (LOOPBACK_HOSTS). probe_backend() only counts a backend as Aloud if 127.0.0.1 accepts and every loopback address that accepts answers /health as kokoro. The ::1 probe sends Host localhost:<port>.
- **Test:** backend/tests/test_launchers.py NativeLoopbackTests: test_server_on_ipv6_loopback_alone_counts_as_busy, test_run_py_refuses_a_port_held_on_ipv6_alone, test_native_app_does_not_serve_next_to_it, test_aloud_on_ipv4_with_another_server_on_ipv6_is_not_ours, test_dual_stack_aloud_is_ours_and_asked_as_localhost
- **Commit:** `809fd19`

##### H028 · Medium · Backend

**ALOUD_ALLOWED_HOSTS replaces the default localhost,127.0.0.1 instead of adding to it, and run.py's docstring (lines 21-22) only says to list 'the names other devices will use'.**

- **Where:** `backend/app.py:194` (bad-ux)
- **Scenario:** Following run.py's docstring, the user runs `ALOUD_HOST=0.0.0.0 ALOUD_ALLOWED_HOSTS=my-mac.local ./run.sh`. Every /health from run.sh (Host: 127.0.0.1) gets a 400 'Invalid host header'. run.sh waits the full 120 s, then says 'No Aloud backend answered', and its hint covers only ALOUD_HOST.
- **Root cause:** The mechanism is real. backend/app.py:194 passes _env_list("ALOUD_ALLOWED_HOSTS", ["localhost","127.0.0.1"]) to TrustedHostMiddleware. _env_list (app.py:114-117) returns the env items when any are set, so the defaults are dropped. backend/run.py:19-22 is the docstring the audit fix c2ab14a added for F053/F054. It tells the user to "also list the names other devices will use in ALOUD_ALLOWED_HOSTS" and never says that this replaces localhost and 127.0.0.1.
- **Fix:** In app.py, TrustedHostMiddleware now allows ['localhost','127.0.0.1', *ALOUD_ALLOWED_HOSTS], so the env list adds to the defaults instead of replacing them. Updated the app.py docstring, the run.py docstring and the README LAN example, which is now ALOUD_HOST=0.0.0.0 ALOUD_ALLOWED_HOSTS=my-mac.local.
- **Test:** backend/tests/test_app_requests.py AllowedHostsTests: test_loopback_names_are_kept_alongside_the_lan_name, test_other_names_are_still_refused
- **Commit:** `809fd19`

##### H061 · Low · Backend

**webview.start() is called with pywebview's default private_mode=True.**

- **Where:** `backend/native_app.py:251` (broken-feature)
- **Scenario:** Open the packaged web app (legacy/build_web_app.sh launches native_app.py), pick a different voice, set the rate to 1.5x and switch to the dark theme, then quit. Open it again and all of them are back at af_heart, 1x and the default theme.
- **Root cause:** The packaged legacy app wipes its saved preferences every time it launches. backend/native_app.py:251 calls webview.start() with no arguments. In the pywebview installed in backend/.venv (6.2.1), private_mode defaults to True (webview/__init__.py lines 139 and 173).
- **Fix:** native_app now calls webview.start(private_mode=False). I left storage_path out: the macOS Cocoa backend ignores it and uses WebKit's default store. choose_port() now tries FALLBACK_PORTS 8001-8010 before a random port, so the origin and its localStorage stay the same when 8000 is busy.
- **Test:** backend/tests/test_launchers.py NativeWindowTests.test_window_keeps_its_storage_between_launches, NativePortTests.test_busy_default_port_falls_back_to_a_fixed_one
- **Commit:** `809fd19`

##### H062 · Low · Backend

**run.sh tells the user to open http://localhost:5173 (lines 52 and 83), but frontend/vite.config.ts sets strictPort: false.**

- **Where:** `run.sh:83` (bad-ux)
- **Scenario:** A second worktree or another Vite project is already serving on 5173. Run ./run.sh: Vite starts on 5174, then the script prints 'Aloud is ready.
- **Root cause:** The finding is confirmed. run.sh prints a hardcoded http://localhost:5173 twice: at line 52 when the reader starts, and at line 83 in the final "Aloud is ready" line. frontend/vite.config.ts sets server.port 5173 with strictPort: false, and run.sh starts plain `npm run dev`, which runs `vite` with no --port and no --strictPort. When something already listens on localhost:5173, Vite moves to 5174, but run.sh still tells the user to open 5173, where the other app answers.
- **Fix:** vite.config.ts now has strictPort: true. Changes in run.sh: (1) it reads ALOUD_UI_PORT (default 5173); (2) before starting anything, it curls http://localhost:$UI_PORT/ and exits 1 with a clear message if something already answers there; (3) it runs `npm run dev -- --port $UI_PORT --strictPort` and prints $UI_PORT in both messages; (4) if the reader exits with an error during the wait, before the ready line or after the stay-up loop, it says so and exits 1 instead of claiming ready.
- **Test:** backend/tests/test_launchers.py RunShTests: test_taken_reader_port_stops_before_anything_starts, test_reader_keeps_to_the_port_it_prints, test_default_reader_port_is_strict, test_reader_that_fails_to_start_is_reported, test_vite_config_keeps_to_its_port
- **Commit:** `809fd19`

##### H063 · Low · Backend

**Several backend dependencies are open-ended, with no lock file and no hashes: fastapi>=0.115, uvicorn[standard]>=0.30 and pywebview>=5.0, plus every transitive package (starlette, pydantic...**

- **Where:** `backend/requirements.txt:4` (security)
- **Scenario:** With the documented `uv pip install -r requirements.txt` (README:227), a fresh install pulls whatever versions are newest that day, unverified, so a broken or compromised release of any of them is installed and run. A venv built when fastapi 0.115 was current keeps that old FastAPI/Starlette for good, because the floor is already met; app.py:335 has to code around exactly that. download_models.py:46 skips re-downloading any kokoro-v1.0.onnx or voices-v1.0.bin whose size is within 5%, whatever its contents.
- **Root cause:** The facts in the report are correct, but the impact is overstated. This is a hardening gap in the legacy, localhost-only web backend.
- **Fix:** requirements.txt now pins fastapi==0.141.1, uvicorn[standard]==0.52.4 and pywebview==6.2.1, the versions installed in the main backend/.venv (read from its dist-info, since that venv has no pip). There are no hashes, because generating them needs the network. download_models.py now pins each asset's exact size and SHA-256 and checks both before skipping a file and after downloading it.
- **Test:** backend/tests/test_launchers.py ModelDownloadTests: test_backend_requirements_are_pinned, test_right_sized_wrong_file_is_fetched_again, test_matching_file_is_skipped, test_download_that_does_not_match_is_deleted, test_real_assets_pin_a_sha256
- **Commit:** `809fd19`

##### H064 · Low · Backend

**When the native window attaches to a backend that something else started (for example run.sh), it has no way to recover if that process stops.**

- **Where:** `backend/native_app.py:183` (bad-ux)
- **Scenario:** Run ./run.sh (its backend is on 8000), then open the packaged Aloud app: find_running_backend() attaches and server stays None. Press Ctrl-C in the terminal.
- **Root cause:** The finding is real, but it is slightly overstated and affects very few people. When native_app.main() attaches to a backend that is already running (lines 182-188), it never imports app and never builds a uvicorn.Server, so `server` and `server_thread` stay None.
- **Fix:** I moved server startup into _start_own_server(port). When main() attaches to another backend and is not headless, it starts a daemon thread running _take_over_when_gone.
- **Test:** backend/tests/test_launchers.py AttachWatchTests: test_backend_gone_and_port_free_starts_our_own_there, test_live_backend_or_taken_port_is_left_alone; NativeWindowTests: test_attached_window_watches_its_backend, test_window_on_its_own_server_does_not_watch
- **Commit:** `809fd19`

#### Browser extension

##### H030 · Medium · Extension

**Reading a selection runs it through the same page-junk filters as whole-page extraction (JUNK_RE class names, SKIP_TAGS such as FOOTER/ASIDE/NAV/FORM/PRE, SKIP_ROLES, link density).**

- **Where:** `extension/src/content/extract.ts:318` (broken-feature)
- **Scenario:** On a WordPress blog the user selects one whole comment (author line plus text) and chooses right-click > Read selection aloud, or presses Alt+A. The common ancestor is article.comment-body. walk() never checks the root itself, but it skips both of its children: footer.comment-meta (FOOTER is in SKIP_TAGS) and div.comment-content (JUNK_RE matches 'comment-'). run() then returns null and index.ts shows 'Nothing selected to read.' A selection across two Hacker News or WordPress comments fails the same way, because every li.comment or div.comment child is skipped.
- **Root cause:** I could not refute it. extractSelection (extract.ts:521-538) starts run() at the selection's common ancestor. walk() (extract.ts:358-384) then calls the same shouldSkip() (extract.ts:299-320) on every child that the range intersects. The only selection-specific logic is clipping (appendText, the intersectsNode prune) and the plain-text PRE special case.
- **Fix:** In selection mode (state.restrict set), shouldSkip now drops only SELECTION_SKIP_TAGS (script, style, media, embeds, form controls, BUTTON), hidden elements, data-aloud and uiHost. JUNK_RE, SKIP_ROLES, link density and the NAV/ASIDE/FOOTER/FORM/PRE tag skips apply only to whole-page reading.
- **Test:** extension/tests/extract.test.mjs: 'H030: a selection across two comments reads both, highlighted, not "Nothing selected"' and 'H030: a whole WordPress comment reads its author line and its text'. Both fail on e4d1e5a and pass now.
- **Commit:** `ed6b07a`

##### H032 · Medium · Extension

**Chrome's info.selectionText is only used when the selection is in a subframe (info.frameId != 0).**

- **Where:** `extension/src/background/index.ts:79` (broken-feature)
- **Scenario:** The user writes a GitHub comment or any form textarea, selects a paragraph of it to proofread by ear, and picks right-click > Read selection aloud. frameId is 0, so text is undefined. The content script runs extractSelection(), where getSelection() gives a range outside the control (collapsed, or wrapping the TEXTAREA element, which walk() skips).
- **Root cause:** In the top frame, Chrome reports a selection inside a textarea or input, and a mouse selection inside an open shadow root, as collapsed: isCollapsed is true and getRangeAt(0) is a collapsed range at the host's position in its parent. getSelection().toString() still returns the selected text. There is no guard that catches this.
- **Fix:** The fix is in the content script, not in background/index.ts, which is where the finding points. Chrome reports a selection inside a text field or shadow tree as collapsed, but getSelection().toString() still holds the selected text. extractSelection now falls back to extractText on that string, so the context menu's start('selection') in frame 0 reads it.
- **Test:** extension/tests/extract.test.mjs: 'H032: text selected in a text field is read, though Chrome reports it collapsed' (plus a passing control test, 'an empty selection is still nothing to read'). extension/tests/content.test.mjs: 'H032: the shortcut reads text selected in a text field, not the whole page'. The two H032 tests fail on e4d1e5a and pass now.
- **Commit:** `ed6b07a`

##### H033 · Medium · Extension

**The player bar is built in an open shadow root, and its handlers act on untrusted (script-dispatched) events.**

- **Where:** `extension/src/content/ui.ts:342` (security)
- **Scenario:** A hostile page waits for the Aloud bar to appear. It then adds <option value="xxxx…(65+ chars)"> to the voice select inside the open shadow root, selects it, and dispatches a 'change' event. onVoice calls savePrefs({voiceId}), which syncs to every tab and every signed-in Chrome profile.
- **Root cause:** The core claim holds. A page script can write any voiceId into the extension's synced settings, and that breaks the reader on every site until the user picks a voice again.
- **Fix:** The bar and the toast use attachShadow({mode:'closed'}), and only the private PlayerBar.root keeps a reference. Every bar handler (click, track pointerdown, voice and rate change) ignores events whose isTrusted is false. onVoice saves only a voice from the engine's roster, and prefs sanitize() replaces any voiceId longer than 64 characters (the backend's MAX_VOICE_CHARS) with the default.
- **Test:** extension/tests/content.test.mjs: 'H033: the page can neither reach into the bar nor work it with events it dispatches' and 'H033: a voice id past the backend limit is never kept, so it cannot stop every reader'. Both fail on e4d1e5a and pass now.
- **Commit:** `ed6b07a`

##### H036 · Medium · Extension (twin fixed on the other platform)

**Once a page has finished (status 'ended'), Play, Alt+A and the popup's 'start' all call player.play().**

- **Where:** `extension/src/content/player.ts:882` (bad-ux)
- **Scenario:** The user listens to an article to the end, and the bar says 'Finished'. They press the bar's play button or Alt+A to hear it again: only the last sentence plays, and the bar returns to 'Finished'.
- **Root cause:** When the page ends, advanceFrom (player.ts:844-851) sets the status to 'ended' and leaves index and loadedIndex on the last sentence. Pressing play goes through toggle(), then play().
- **Fix:** When currentStatus is 'ended', AloudPlayer.play() now clears the streak and calls playIndex(0). This covers the bar's Play, Alt+A and the popup/background 'start'.
- **Test:** extension/tests/player.test.mjs: 'H036: Play at "Finished" listens again from the first sentence, not the last one again'. extension/tests/content.test.mjs: 'H036: after "Finished", the shortcut reads text selected further on'. Both fail on e4d1e5a and pass now.
- **Commit:** `ed6b07a`, `77b3b0b`

##### H038 · Medium · Extension

**Seeking never aborts look-ahead requests for the old position. fill() counts every in-flight prefetch entry in the cache against MAX_PREFETCH_INFLIGHT (6), wherever it is in the page...**

- **Where:** `extension/src/content/player.ts:604` (bad-ux)
- **Scenario:** The user starts a long article, which sends about 6 prefetch requests right away to fill the 60 s buffer target. They then click a paragraph near the end (click-to-jump) or drag the progress track. seekTo() calls playIndex(), and fill() at the new index counts the 6 old prefetches (line 586) and hits the break at line 604.
- **Root cause:** seekTo() (player.ts:954) and jump() (927) never abort in-flight look-ahead. playIndex() only bumps playToken and ensures the target at `now`. evict() runs only when the cache bounds are exceeded. fill() (578-616) counts every unresolved PREFETCH entry in the whole cache (586). At the new index it reaches `if (inFlight >= MAX_PREFETCH_INFLIGHT) break` (604) at k=1, so nothing near the target is scheduled, and the 'three sentences ahead' floor is broken.
- **Fix:** seekTo() calls a new dropStaleLookahead(target) before playIndex. It walks the same floor-then-target window as fill() and forget()s every in-flight PREFETCH entry outside [target, window end].
- **Test:** extension/tests/player.test.mjs: 'H038: a far seek aborts the old look-ahead and fetches ahead of the new place'. It fails on e4d1e5a (times out waiting for look-ahead of sentence 31) and passes now.
- **Commit:** `ed6b07a`

#### Mac app

##### H011 · Medium · Mac

**During an import, the Mac Library cards keep keyboard focus and respond to keys under the import overlay.**

- **Where:** `ios/AloudMac/Library/MacLibraryView.swift:216` (bad-ux)
- **Scenario:** Keyboard navigation is on and a Library card has focus. The user adds a large PDF and the 'Adding … %' overlay comes up.
- **Root cause:** Nothing takes the shelf out of keyboard reach while the import overlay is up. MacImportOverlay is a ZStack of a scrim and a card.
- **Fix:** Followed the verifier's better fix: MacRootView now applies .disabled(isImportOverlayShown) next to .accessibilityHidden(isImportOverlayShown). It is keyed on the overlay flag, so it covers the copy phase, Classics and the reader, and it starts at the overlay, not 0.8 s before.
- **Test:** None (no unit seam: SwiftUI key-view focus under a disabled stack is not observable from a unit test, and hosted accessibility/focus trees are not built without an AT client, which a probe confirmed)
- **Commit:** `f0839e6`

##### H013 · Medium · Mac

**When Delete Book… (⌘⌫) or the context-menu Delete removes the focused card, keyboard focus is not passed to another card.**

- **Where:** `ios/AloudMac/Library/MacLibraryView.swift:109` (bad-ux)
- **Scenario:** With keyboard navigation on and a book playing, the user arrows to a grid card, presses ⌘⌫, and confirms Delete. The card is removed and no card has focus.
- **Root cause:** The code confirms the finding. I did not run the app (the rules forbid it), so one link rests on how SwiftUI behaves rather than on a reproduction.
- **Fix:** New MacLibraryView.focusAfterRemoving(_:hero:grid:) picks the next grid card, else the previous one, else the Continue card. From the Continue card it picks the grid's first. perform(.delete) records whether the target had focus (deleteHadFocus).
- **Test:** MacGridMetricsTests.testARemovedCardHandsFocusToANeighbour (written, not run: xcodebuild is off-limits)
- **Commit:** `f0839e6`

##### H020 · Medium · Mac

**Calm follow still moves the page while the mouse button is down for a drag selection. followIfNeeded only checks `isFollowing, !userHoldsScroll`...**

- **Where:** `ios/AloudMac/Reader/ReaderColumnView.swift:1040` (bad-ux)
- **Scenario:** While a book plays and the page follows the voice, the user drags to select a passage to copy. During the drag the voice moves on to a sentence below the band. update(to:) -> setActiveSentence(scroll: true) (line 911) -> followIfNeeded -> startGlide moves the page up by as much as most of a screen.
- **Root cause:** On the Mac, holding the mouse button down on the page does not stop calm follow. followIfNeeded (ReaderColumnView.swift:1039-1040) only checks `isFollowing, !userHoldsScroll`. userHoldsScroll (line 233) is `inLiveScroll && scrollView?.inMomentum != true`, so it is true only during a trackpad or scroller scroll. clickLanded (line 1578) cancels a held click-play, stops a coast, and treats a running glide as a user takeover. It sets no flag that blocks the next follow.
- **Fix:** ReaderNSTextView now has isMouseHeld, set around super.mouseDown, and an onMouseReleased hook. The coordinator's userHoldsScroll now includes isMouseHeld, so followIfNeeded, placeActiveSentence, verifyPlacement, resumeFollowing and the handleLayout jump all hold while the button is down.
- **Test:** ReaderColumnViewTests.testAHeldMouseButtonKeepsThePageUntilItComesUp
- **Commit:** `cfb1531`

##### H022 · Medium · Mac

**Pressing Return on "Show N earlier stops" or "Show fewer" moves the keyboard cursor off the toggle. toggleEarlierPlaces already sets the cursor to the toggle's new index.**

- **Where:** `ios/AloudMac/Reader/MacContentsPanel.swift:553` (broken-feature)
- **Scenario:** Mac, book with chapters and 6 or more stops. Open Contents, press ↓ to enter the list, arrow to "Show 3 earlier stops" and press Return.
- **Root cause:** The bug is real: the cursor is moved twice. `toggleEarlierPlaces` (MacContentsPanel.swift:551-554) flips `showsEarlierPlaces` and, if a cursor exists, moves it to the toggle's index in the new layout.
- **Fix:** toggleEarlierPlaces now puts the cursor on the toggle's index in the layout before the flip (new MacContents.cursorOnToggle), and the onChange(of: listLayout) remap carries it once. The old code computed the index after the flip, so it moved twice.
- **Test:** MacContentsPlacesTests.testTheToggleKeepsTheCursorOnTheToggle
- **Commit:** `cfb1531`

##### H023 · Medium · Mac

**Picking a "Where you stopped" row while audio plays leaves the keyboard ring on a different place. pickPlace sets the cursor to the row's position...**

- **Where:** `ios/AloudMac/Reader/MacContentsPanel.swift:546` (bad-ux)
- **Scenario:** Mac, docked panel (window 780 pt or wider). The book has places A (yesterday), B and C.
- **Root cause:** pickPlace (ios/AloudMac/Reader/MacContentsPanel.swift:543-548) sets `cursor = index`, then calls jump. A place pick is a `.chapter` jump, so PlaybackController.offersUndo is true whenever from != to.
- **Fix:** ListLayout gains placeSentences (default []), and listLayout(...) gains a placeSentences: param. The panel passes its PlaceRow sentences through flatLayout(_ places:). remap now follows a .place cursor by its sentence.
- **Test:** MacContentsPlacesTests.testAPlacesCursorFollowsItsPlaceWhenAStopLandsAboveIt
- **Commit:** `cfb1531`

##### H024 · Medium · Mac

**VoiceOver never hears where the Contents list's keyboard cursor is.**

- **Where:** `ios/AloudMac/Reader/MacContentsPanel.swift:426` (bad-ux)
- **Scenario:** Mac with VoiceOver on. Press ⌘F, type a query, and press ↓ to move into the results, as the panel's keyboard design intends.
- **Root cause:** The code confirms the finding. The panel's ↑/↓/Return path is a private @State cursor that VoiceOver never sees.
- **Fix:** moveCursor (.row), focusList (down-arrow from the field) and focus arriving on the list with no cursor now call announceCursor. It builds the row's label with the new MacContents.cursorLabel: place label, Show N earlier / Show fewer, chapter row label.
- **Test:** MacContentsPanelTests.testTheCursorsRowIsSaidAsItLands
- **Commit:** `cfb1531`

##### H025 · Medium · Mac

**Menu commands still run while a sheet or alert covers the main window.**

- **Where:** `ios/AloudMac/Commands/MacCommandActions.swift:137` (bad-ux)
- **Scenario:** In the Library, right-click a book card and choose Rename. The Rename alert opens with its text field focused.
- **Root cause:** Nothing stops a ⌘ menu command while a SwiftUI alert sheet is attached to the main window. MacKeyRouter returns ⌘O to AppKit because .addFromFiles is not a plain key and does not set defersToEditableText (MacShortcuts.swift:215).
- **Fix:** MacCommandActions.isEnabled returns false while isRootAlertShown (rootPresentation is .rename or .deleteConfirmation) for every needsMainWindow command (.addFromFiles, .addClassic, .find, .toggleContents, .back) and for .deleteBook, since a second ⌘⌫ would also swap Rename out. perform goes through isEnabled, so these are refused too. MacCommandState.observe now watches router.$rootPresentation, so the menu snapshot greys and un-greys.
- **Test:** MacCommandActionsTests.testMainWindowCommandsWaitForARootAlert and testTheMenuSnapshotFollowsARootAlert (written, not run)
- **Commit:** `f0839e6`

##### H045 · Low · Mac (twin fixed on the other platform)

**Opening an unsupported file in Aloud from Finder clears the window (pops the reader and closes Rename/Delete) before the file type is checked.**

- **Where:** `ios/AloudMac/Library/MacRootView.swift:75` (bad-ux)
- **Scenario:** onOpenURL calls router.clearForOpenIn() right away (MacRootView.swift:73-76; MacAppDelegate.open does the same at 136-137). Only then does intake.admitOpened -> admit filter with isAddable (MacAddMenu.swift:129-130).
- **Root cause:** The finding is real. In MacRootView.onOpenURL, router.clearForOpenIn() runs synchronously at lines 73-76.
- **Fix:** New `static func MacRootView.receiveOpened(_:router:intake:) -> ImportFailure?`. It checks MacFileIntake.isAddable before clearForOpenIn.
- **Test:** MacImportTests.testAnUnsupportedFileOpenedKeepsTheWindowAndSaysWhy; the existing Open With helper now goes through MacRootView.receiveOpened and asserts no failure for addable files
- **Commit:** `a803def`, `26071f9`

##### H052 · Low · Mac

**The Mac chapter line ignores a scrub press or drag.**

- **Where:** `ios/AloudMac/Reader/MacPlayerBar.swift:84` (polish)
- **Scenario:** On the Mac, press the scrub and drag toward the chapter's end. The preview capsule above the track shows the target's words and "· 12:40", but the chapter line still reads the playhead's "· 3 of 12 · 18 min left" until release.
- **Root cause:** This is real and has no guard. MacPlayerBar.position (MacPlayerBar.swift:84-89) always builds the chapter line from the playhead, using navigation.positionLine(at: playhead, ..., isFinished: playback.isAtEnd), where playhead = max(playback.currentSentence, 0) (line 205).
- **Fix:** MacScrub publishes press?.target through the new MacScrubPressKey preference, defined in MacPlayerBar.swift. That is one line in MacScrub.swift, which this batch doesn't own.
- **Test:** MacScrubTests.testAPressMovesTheChapterLineToItsTarget and testThePressKeyKeepsThePress (written, not run)
- **Commit:** `f0839e6`

##### H054 · Low · Mac

**⌘C (and the menu's Copy) writes the selection's raw characters as plain text, U+FFFC object-replacement characters included.**

- **Where:** `ios/AloudMac/Reader/ReaderNSTextView.swift:224` (polish)
- **Scenario:** Select from the end of one chapter into the next (or across a PDF page boundary) and copy. Pasting into Notes, Mail, Messages or a plain-text editor shows an empty box or attachment placeholder between the paragraphs, and a PDF page numeral appears too, so the quote is not the clean words that writablePasteboardTypes' comment promises.
- **Root cause:** The Mac page builds its text with the shared ReaderColumnText.makeAttributedString (ReaderColumnView.swift:505, with isChapterBook and the colophon passed in). That builder puts an NSTextAttachment rule paragraph ("\u{FFFC}\n") in three places: after every chapter heading in a chaptered text book (ReaderColumnText.swift:168-173), at every PDF page boundary just before the page numeral (lines 128-135), and at the top of the colophon (line 211).
- **Fix:** ReaderNSTextView overrides writeSelection(to:types:). It calls super, then if the plain string contains U+FFFC it rewrites it with ReaderNSTextView.quotable: removes each U+FFFC plus the newline after it, then any stray U+FFFC.
- **Test:** ReaderColumnViewTests.testACopyAcrossARuleParagraphQuotesOnlyTheWords
- **Commit:** `cfb1531`

#### Shared iPhone/Mac core and iPhone app

##### H000 · High · iPhone + Mac

**A Chinese or Japanese .txt novel in the usual layout (one paragraph per line, indented with U+3000 ideographic spaces, no blank lines) is imported as a single paragraph with no chapters.**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:146` (broken-feature)
- **Scenario:** isOneParagraphPerLine counts a line as ending a sentence only if its last character is one of .!?:"”’. The CJK full stop 。, ！, ？, 」 and 』 are not in that set, so few lines count and the function returns false. isIndentedParagraphLayout (indent(of:) at :99-104) counts only ASCII spaces and tabs, so U+3000 indents count as zero.
- **Root cause:** The finding is not in audit-handled.md. F022 covered hard-wrapped Western text whose paragraphs are marked only by an indent.
- **Fix:** TextExtractor.isOneParagraphPerLine now counts lines ending in 。！？：」』… as finished. It also treats a file where at least 90% of non-blank lines start with U+3000 as one paragraph per line. indent(of:) counts U+3000 as two columns, so hard-wrapped CJK that indents only first lines splits at the indents.
- **Test:** ExtractionLineParagraphTests.testChineseOneParagraphPerLineKeepsParagraphsAndChapters, testJapaneseAndWrappedCJKLayouts
- **Commit:** `502db00`

##### H001 · High · iPhone + Mac

**If library.json exists but can't be read at launch, the store starts with an empty shelf and does not remember the failed read.**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:42` (data-loss)
- **Scenario:** The code expects this state. The comment at 596-598 says loadIndex returns false 'for one that exists but can't be read (a newer schema, a locked device)'.
- **Root cause:** The F036 guard only stops the orphan sweep on the launch where the index can't be read. It does not stop the next index write. loadIndex returns false and leaves `documents` empty.
- **Fix:** DocumentStore now has a stored `private(set) var isIndexReadable`. While it is false, persistIndex throws LibraryIndexError.unreadable and writes nothing.
- **Test:** ProgressIndexTests: testAnUnreadableIndexIsNeverWrittenOver, testADamagedIndexStaysAsItIs, testNoIndexYetIsAnEmptyShelfThatWrites, testAnAddWhileTheIndexIsUnreadableFails (shared, so it runs on both apps)
- **Commit:** `a803def`

##### H002 · Medium · iPhone + Mac

**The heat rule checks only the voice that is playing now, not a natural voice that is still on its way in.**

- **Where:** `ios/Aloud/Playback/ThermalGuard.swift:85` (bad-ux)
- **Scenario:** When the device cools, line 92 calls switchVoiceAtSentenceBoundary(to: Kokoro). With a cold engine, PlaybackController (1946-1959) only sets `handoff` and starts kokoro.warmUp().
- **Root cause:** While the switch back to Kokoro is pending (`voice` is still System, `handoff.voice` is Kokoro), ThermalGuard ignores a new rise to .serious. Line 85 needs `playback.voice.engine == .kokoro`, which is false, and line 89 needs `new < serious`.
- **Fix:** PlaybackController now exposes a read-only `incomingVoice` (handoff?.voice). ThermalGuard has a new dropIncomingNaturalVoice(): when the System voice is reading and a switch back to Kokoro is pending, it runs on the .critical crossing (after the stop, before releaseNeuralEngineIfIdle) and on the .serious crossing.
- **Test:** ThermalGuardTests.testReheatingBeforeTheSwitchBackLandsKeepsTheSystemVoice and testCriticalWhileTheSwitchBackWarmsDropsIt (ios/AloudTests, both apps)
- **Commit:** `6646580`

##### H003 · Medium · iPhone + Mac

**The G025 fix is supposed to flip the time-pitch bypass only at a sentence boundary, but one of those flips is still late. sentenceFinished does the flip from the clip's .dataPlayedBack completion...**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:1735` (bad-ux)
- **Scenario:** Clips are pre-stretched to the listener's speed, so in steady state the residual is 1 and timePitch.bypass is true. When the speed changes mid-sentence, rate.didSet only sets timePitch.rate and leaves bypass on, because player.isPlaying is true (line 106).
- **Root cause:** When the speed changes during playback, the only flip of the time-pitch bypass at the next boundary is the one in sentenceFinished (PlaybackController.swift:1735), and that function runs from the clip's .dataPlayedBack completion (completionCallbackType, line 379). That callback fires only after the audio has come out of the output device.
- **Fix:** scheduleCompressionSwitch is renamed scheduleBoundaryMarker. It now schedules its 1-frame .dataRendered marker ahead of every clip after a schedule's first, not only when the compression changes.
- **Test:** NativeSpeedTests.testTheBypassSwitchesAsTheRenderCrossesABoundary (source lint, runs in the iOS suite and is skipped on the Mac host like the other source lints). The existing G025 test testASliderTickMidSentenceNeverSwitchesTheBypass now only settles through the new marker.
- **Commit:** `6646580`

##### H004 · Medium · iPhone

**A memory warning never frees the natural-voice engine while anything is playing, even when playback is in the System voice and does not use Kokoro.**

- **Where:** `ios/Aloud/Playback/NeuralPrewarm.swift:229` (bad-ux)
- **Scenario:** memoryWarning gates on releasesEngine(under:status:), which returns false for .playing/.buffering (line 214). It then calls releaseNeuralEngineIfIdle, which also refuses when isActive (PlaybackController:2102).
- **Root cause:** The finding holds. Once the System voice is reading while Kokoro is still loaded, nothing frees Kokoro until playback stops.
- **Fix:** NeuralPrewarm.memoryWarning now calls playback.releaseNeuralEngineIfUnused() before the status gate, at any level and any status. That call still refuses when the voice is Kokoro or any handoff is pending, so the existing MacPowerTests rules for a reading engine and a paused engine (all on the Michael voice) are unchanged.
- **Test:** NeuralPrewarmTests.testAMemoryWarningFreesAnEngineTheSystemVoiceLeftLoaded (System voice playing with Kokoro warm, .warning posted, engine freed while playback keeps going)
- **Commit:** `6646580`

##### H005 · Medium · iPhone + Mac

**When a sentence fails to synthesize, it goes into skippedSentences and stays there for the rest of the book session, even after the voice or skip-brackets setting changes.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:1578` (bad-ux)
- **Scenario:** topUpSchedule's failure path inserts the sentence (line 1578) and plays silence. applyVoiceOrSkipChange (line 2014) and commitHandoff purge the clip cache and restart, but never clear skippedSentences. After a voice switch, topUpSchedule (line 1514) still treats the sentence as skipped and schedules a beat of silence with no notice. cuePrefetch (line 2136) also never warms it, and wordTimingRecordScheduled gives it no word windows.
- **Root cause:** skippedSentences is reset in only four places: load() (line 673), unload() (line 743), seek's exact target (line 975), and withdrawFailedRunSkips (line 1599), which removes only the current failure run when a 3-failure stop happens. Changing the voice or the skip-brackets setting never clears it: - The voice didSet and skipBrackets didSet both go to applyVoiceOrSkipChange (lines 2014-2032), which purges the clip cache, cancels pending synthesis and calls reloadCurrent -> startPlayback. startPlayback clears failedRunSkips and consecutiveFailures, but not skippedSentences. - commitHandoff and setVoiceQuietly (lines 1990-2010) don't clear it either.
- **Fix:** A new private forgetSkips() clears skippedSentences and failedRunSkips. It is called at the top of applyVoiceOrSkipChange, which is reached only when the voice or skipBrackets actually changes, and in commitHandoff.
- **Test:** StopReasonTests.testAnotherVoiceReadsASentenceTheFirstSkipped (a voice pick clears the skip, and Bravo reads sentence 3 after a seek to sentence 1) and testASkipGoesWithTheVoiceASwitchReplaces (a handoff commit clears it)
- **Commit:** `6646580`

##### H006 · Medium · iPhone

**The iPhone treats every expensive or constrained path as cellular.**

- **Where:** `ios/Aloud/Platform/DeviceNoun.swift:37` (bad-ux)
- **Scenario:** SystemNetworkPath.isExpensiveOrConstrained (NetworkPathSource.swift:66-69) is true for Wi-Fi with Low Data Mode (isConstrained) and for Wi-Fi to a hotspot (isExpensive). requestDownload (ModelManager.swift:668) then returns .needsCellularConfirmation, and the prompt uses DeviceCopy.meteredPrompt, which on iOS says "on cellular?". meteredDetail is nil on iOS (line 40), so nothing names the real cause. For a run already in flight, inFlightState returns .waitingForWiFi because allowsWiFiOnlyTransfer is false, and the card shows the iOS waitingForNetwork line (line 42).
- **Root cause:** The finding holds. On iOS, the shared network check treats every expensive or constrained path the same way.
- **Fix:** NetworkPathSource now has usesCellular. SystemNetworkPath reads it from NWPath.usesInterfaceType(.cellular).
- **Test:** ModelVerificationTests.testACostlyWiFiIsNamedNeverCalledCellular (shared, runs on both apps); NaturalVoiceCopyTests.testACostlyWiFiIsNeverCalledCellular; a cellular-prompt assertion added to testAWaitingWiFiOnlyRunCanContinueOnCellular; NetworkBoundaryTests.testTheLivePathWatchesNothingUntilStarted now also checks usesCellular
- **Commit:** `ec29c3a`

##### H007 · Medium · iPhone + Mac

**PDF paragraphs are split only on vertical gaps.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:160` (bad-ux)
- **Scenario:** paragraphs(from:) starts a new paragraph only when the gap above a line is more than 1.6 times the page's median gap. Line (:113-117) stores only text, y and height. lines(of:) never records the line's x or width, so an indented first line or a short last line cannot be seen.
- **Root cause:** paragraphs(from:) (PDFTextExtractor.swift:150-173) starts a new paragraph only when the vertical gap is more than 1.6 times the page's median gap. Line (:113-117) keeps only text, y and height, and lines(of:) (:124-140) throws away bounds.minX and maxX.
- **Fix:** Line now carries minX and maxX. These are var properties with default 0, so existing Line(text:y:height:) callers still compile, and lines(of:) fills them from the selection bounds.
- **Test:** PDFTextExtractorTests.testFirstLineIndentsOpenParagraphs (unit test on paragraphs(from:)) and PDFTextExtractorTests.testIndentedTypesetPDFKeepsItsParagraphs (end to end: CoreText typesets a 6x9 page with first-line indents and no paragraph spacing into a temp PDF, then PDFTextExtractor.extract reads it back)
- **Commit:** `34d6319`

##### H008 · Medium · iPhone + Mac

**Searching a Chinese or Japanese book for a phrase that contains fullwidth punctuation never matches.**

- **Where:** `ios/Aloud/Models/DocContent.swift:269` (broken-feature)
- **Scenario:** TextNormalizer.normalize applies NFKC to all text, so the stored sentence has ',' (U+002C) where the source had '，' (U+FF0C). The same happens to ！？：；（）.
- **Root cause:** Every block that builds a DocContent passes through TextNormalizer.normalize (ExtractionPipeline.swift:87). Step 1 of normalize runs NFKC on everything except fractions and superscripts (TextNormalizer.swift:22, 69-85).
- **Fix:** Added .widthInsensitive to DocContent.searchOptions, as the verifier recommended. Fullwidth ，：（）, fullwidth digits and letters, and halfwidth katakana now match the NFKC-folded stored text.
- **Test:** ContentsSearchFoldingTests.testFullwidthQueryMatchesFoldedStoredText
- **Commit:** `34d6319`

##### H009 · Medium · iPhone + Mac

**persistIndex ignores write errors (`try? data.write`).**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:639` (data-loss)
- **Scenario:** The steps run in order: importPDF/importText copyFile (throws on ENOSPC), writeContentCache (throws), writeThumbnail (`try?`), then insert() -> persistIndex (`try?`). If space runs out after the content cache is written, the book is still added in memory.
- **Root cause:** The finding is correct as a mechanism, but it is hard to hit in practice. insert() (DocumentStore.swift:573-577) has no error path. persistIndex() (636-640) runs `try? data.write(to: indexURL, options: .atomic)`, so if writing the library.json temp file fails, the error is dropped. importPDF/importText then return the document, and DocumentImporter announces "Added …" and opens the book. At the next launch, loadIndex reads the old library.json, which is valid, so it returns true, and removeOrphanedFiles (621-634) deletes `<id>.pdf` and `<id>.content.json`.
- **Fix:** persistIndex is now `throws`. insert() rolls back the in-memory append and rethrows, so importPDF/importText fail through their existing cleanup, which removes the copy, the content cache and the thumbnail. ENOSPC maps to .outOfSpace through ImportFailure's existing mapping. delete() removes the book's files only after the index write succeeds; otherwise it restores the shelf.
- **Test:** ProgressIndexTests.testAnAddTheIndexCantRecordFails (index folder chmod 0555 stands in for ENOSPC)
- **Commit:** `a803def`

##### H010 · Medium · iPhone + Mac

**In PDFs, every compound word that wraps at its own hyphen loses the hyphen ("well-⏎known" becomes "wellknown"). appendLine joins the halves before the normalizer's dictionary rule for compounds can see them.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:198` (bad-ux)
- **Scenario:** appendLine removes a line-final hyphen whenever a letter comes before it and the next line starts with a-z, then glues the halves together. TextNormalizer step 4 (TextNormalizer.swift:31-51, hyphenSplit :111-121) exists to keep the hyphen when both halves are words and the joined form is not.
- **Root cause:** In ios/Aloud/Extraction/PDFTextExtractor.swift:196-203, appendLine removes a line-final ASCII '-' whenever `[A-Za-z]-$` matches the buffer and `^[a-z]` matches the next line, then joins the two halves with no gap. It does this before any normalization. paragraphs(from:) at line 165 calls it for every wrapped line, and appendPageParagraphs at line 407 calls it for every page-break join.
- **Fix:** For a normal hyphen, appendLine now returns buffer + "\n" + next. TextNormalizer step 4, which already runs on every folded paragraph and on every stitched block in buildContent, then rejoins syllable splits ("inter-/national" still becomes "international") and keeps compounds (well-known, self-evident, twenty-five, mother-in-law, sitting-room).
- **Test:** PDFTextExtractorTests.testCompoundsWrappedAtTheirHyphenKeepIt (within a page and across a page break; skipped if the system has no English NLEmbedding, like ExtractionHyphenationTests)
- **Commit:** `34d6319`

##### H012 · Medium · iPhone + Mac (twin fixed on the other platform)

**Chapter detection only knows English markers.**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:1060` (bad-ux)
- **Scenario:** headingRegex and headingFirstLineRegex (:1060-1068) accept only CHAPTER/BOOK/PART/ACT/PROLOGUE/EPILOGUE and Roman numerals, and the cheap exit at :1118 requires an initial in "CBPAEIVXL". The PDF headings tier (PDFChapters.swift:454) accepts only CHAPTER/Chapter.
- **Root cause:** In TextExtractor.extract (ios/Aloud/Extraction/TextExtractor.swift:34-38), the only way a plain-text book gets a new page or chapter is isChapterHeading. That function rejects anything that does not start with one of "CBPAEIVXL" (:1118-1120).
- **Fix:** New localizedHeadingRegex, used by isChapterHeading (single-line and multi-line paths) and by isHeadingLine. It accepts 第N章/回/節/节/卷/部/篇/話/话/幕, 제N장/편/부/화, Глава/Часть plus a numeral or a Russian ordinal, Kapitel N and Erstes..Zwölftes/Letztes Kapitel, Chapitre N/premier/dernier, and Capítulo/Capitulo/Capitolo N/primero.
- **Test:** ExtractionChapterHeadingTests.testLocalizedChapterMarkersAreHeadings, testLocalizedMarkerProseIsNotAHeading, testRussianChaptersStartPages
- **Commit:** `502db00`, `58de30e`

##### H014 · Medium · iPhone

**At the accessibility text sizes (AX1–AX5), the grid becomes one column.**

- **Where:** `ios/Aloud/Library/LibraryView.swift:43` (bad-ux)
- **Scenario:** A large-text user (Settings ▸ Accessibility ▸ Larger Text at AX1 or above) with 10 books opens the Library on an iPhone SE (3rd gen). Each card fills nearly the whole visible area (about 603 pt), so finding a book takes about one full-screen scroll per book.
- **Root cause:** The finding holds. At AX1 and above, LibraryView.columns (ios/Aloud/Library/LibraryView.swift:41-44) switches to a single GridItem(.flexible()).
- **Fix:** At accessibility sizes, DocumentCardView frames the cover at CoverGeometry.heroSize (64x96) above the full-width text, matching the Continue card's AX layout. Below AX sizes the 2:3 cover still fills the column.
- **Test:** DocumentCardLayoutTests.testTheCoverKeepsItsFixedSizeAtAccessibilitySizes (iOS only, already excluded from the Mac target)
- **Commit:** `a803def`

##### H016 · Medium · iPhone + Mac (twin fixed on the other platform)

**Classics rows show each book's length at 1× (book.estimatedListeningMinutes) and ignore the app-wide speed.**

- **Where:** `ios/Aloud/Bookshelf/BookshelfView.swift:200` (bad-ux)
- **Scenario:** Set Speed to 2× in Settings. With an empty Library, the featured card shows "Edgar Allan Poe · 7 min" (EmptyLibraryView.swift:35-37 divides by the rate).
- **Root cause:** I found nothing that makes the Classics rows follow the app-wide speed. The rows and their VoiceOver labels use BookshelfBook.estimatedListeningMinutes, which is fixed at 1× (BookshelfCatalog.swift:20-23, ListeningEstimate.minutes at the default 165 wpm).
- **Fix:** BookshelfRow gets the rate. The row text and the VoiceOver label use the new nonisolated BookshelfView.rowSubtitle/rowLabel/rowMinutes at model.globalRate.
- **Test:** CardCopyTests.testClassicsRowsReadTheirLengthAtTheAppWideSpeed (new, iOS-only file: Cask reads 7 min at 2x, matches FeaturedClassic.subtitle at 0.5-3x and the Library card at 2x)
- **Commit:** `98a5570`, `26071f9`

##### H017 · Medium · iPhone

**On iPhone, a light/dark or Increase Contrast change in the foreground still rebuilds the whole book's attributed string. putBack...**

- **Where:** `ios/Aloud/Reader/ReaderTextView.swift:333` (bad-ux)
- **Scenario:** Open a very long classic, such as Pepys, and read 80-90% of the way in. Then pull down Control Center and toggle Dark Mode.
- **Root cause:** On iPhone, any light/dark or Increase Contrast change made while the app is in the foreground still throws away the whole column and lays the book out again from its first character down to the passage on screen, all on the main thread. The F030 guard only skips flips while the app is in .background.
- **Fix:** The iPhone column is now built in ReaderInk.live(traits:), a new iOS extension in ReaderTextView.swift. Text uses dynamic UIColors, and each rule image comes from a UIImageAsset holding light/dark x normal/high-contrast variants, with one asset cached per size and color.
- **Test:** ColophonColumnTests.testALightDarkFlipRecolorsTheColumnInPlace (new: no rebuild, no storage edit, rule shows new-look variant); ReaderFollowCoordinatorTests.testTheAppSwitchersSnapshotFlipsRebuildNothing and testALightDarkFlipKeepsThePassageOnScreen updated to expect a recolor, not a rebuild
- **Commit:** `98a5570`

##### H018 · Medium · iPhone

**On iPhone, a text-size step goes down the fresh-column path, which forces isFollowing = true and places the playhead's sentence on the landing line (lines 83-95).**

- **Where:** `ios/Aloud/Reader/ReaderTextView.swift:88` (bad-ux)
- **Scenario:** Pause playback and scroll back a few pages to re-read a passage. Following is now off and the Follow chip shows.
- **Root cause:** On iPhone, a text-size step goes through the same branch as opening a new book: `builtHash != content.contentHash || builtFontSize != fontSize` in updateUIView. That branch rebuilds, sets `isFollowing = true` with no condition, and queues placeActiveSentence(). placeActiveSentence's only guard is `isFollowing`, which the branch has just set, so it jumps the paused playhead's sentence to the landing line. rebuild() also calls follow.startPlacementCheck(), so verifyPlacement keeps putting the voice back on each layout pass.
- **Fix:** updateUIView now handles a size-only change separately from a new document. It calls Coordinator.reflowKeepingPlace(fontSize:) and then falls through to the normal colophon, follow-request and active-sentence checks. reflowKeepingPlace keeps following as it was.
- **Test:** ReaderFollowCoordinatorTests.testATextSizeStepKeepsTheReadersPassage, testATextSizeStepWhileFollowingStaysOnTheVoice, testABoldTextFlipKeepsTheReadersPassage (new)
- **Commit:** `98a5570`

##### H019 · Medium · iPhone

**Over the colophon, VoiceOver's double-tap is meant to do nothing (empty hint, playFromHere returns false at line 1083).**

- **Where:** `ios/Aloud/Reader/ReaderTextView.swift:270` (broken-feature)
- **Scenario:** With VoiceOver on, finish a book so the colophon shows. readsColophon is true and the column label reads 'The End ...'. Do a three-finger swipe to scroll back a page or two. accessibilitySentence stays nil, so the label still reads the colophon and the hint is still empty.
- **Root cause:** I traced the path end to end and found nothing that blocks it. Over the colophon, playFromHere() returns false (ReaderTextView.swift:1083). onActivate passes that false straight through (line 270), and ReaderUITextView.accessibilityActivate() returns it without calling super (line 1309-1310).
- **Fix:** onActivate now returns true when readsColophon is set, without acting, so VoiceOver no longer falls back to a simulated tap at the column's center. The custom action still goes through playFromHere() and returns false.
- **Test:** ColophonColumnTests.testVoiceOverReadsTheColophonAsOneLabel: now asserts accessibilityActivate() returns true over the colophon with no sentence played, and that the Play from here custom action still returns false
- **Commit:** `98a5570`

##### H021 · Medium · iPhone + Mac

**If the book that loads has the same content hash as the one the timer last saw, End of chapter is never re-armed. documentChanged returns at the hash guard before it reaches the `option == .endOfCh...**

- **Where:** `ios/Aloud/Reader/SleepTimer.swift:268` (broken-feature)
- **Scenario:** 1) Arm End of chapter while listening in the book's first chapter (a chapter that starts at sentence 0, for example a user TXT or PDF whose first chapter begins the text). 2) Delete the book: letGo calls unload, the stop is dropped, and documentChanged returns early because there is no document.
- **Root cause:** The finding is real, but the path is narrow. SleepTimer.documentChanged (ios/Aloud/Reader/SleepTimer.swift:268-274) returns at `navigation?.hash != content.contentHash` before it reaches the `option == .endOfChapter` re-arm.
- **Fix:** SleepTimer.documentChanged now stores the loaded document's id (new private var documentID: UUID?). It re-arms End of chapter when the id or the hash changes, which is the same rule the controller uses for a new load that drops sleepStopAfter.
- **Test:** ios/AloudTests/SleepTimerTests.swift testEndOfChapterReaimsWhenTheSameTextLoadsUnderANewID (shared suite, so it runs on both apps)
- **Commit:** `6c8db0b`

##### H039 · Low · iPhone + Mac

**A year followed by an em or en dash and then a short number is read as a year range.**

- **Where:** `ios/Aloud/TTS/SpokenYears.swift:250` (bad-ux)
- **Scenario:** TextNormalizer.swift:195 turns every em or en dash into a spaced hyphen (" - "). dashThenDigit (SpokenYears.swift:220-227) accepts a spaced dash, so range() takes the number after the dash as the range's end, using case (2, .none) at line 264. The isCount guard at lines 250-253 should leave the group alone because a count noun ("years", "men", "ships") follows it.
- **Root cause:** The bug is real and the reported inputs reproduce it exactly, but the cause is not the one reported, it almost never happens, and the proposed fix would cause a regression. KokoroSherpaEngine.spokenText (KokoroSherpaEngine.swift:202) runs SpokenYears.apply on the output of TextNormalizer.normalize.
- **Fix:** The em/en dash difference was lost at import (TextNormalizer mapped U+2012...U+2015 to ' - '). Now an em dash or horizontal bar that follows a digit (spaces skipped) becomes ' -- ', the ASCII em dash.
- **Test:** TextNormalizerTests.testEmDashAfterANumberBecomesDoubleHyphen, SpokenYearsTests.testEmDashAfterAYearIsNotARange
- **Commit:** `502db00`

##### H040 · Low · iPhone + Mac

**The word highlight drifts on sentences with numbers. estimatedSyllables keeps only the letters a-z, so a digit token weighs 1 syllable, but both voices say several: Kokoro, after SpokenYears...**

- **Where:** `ios/Aloud/Extraction/SentenceSegmenter.swift:423` (polish)
- **Scenario:** WordTimingEstimator.windows splits the clip's known duration across display tokens by tokenWeight, which is max(1, estimatedSyllables) plus a pause for trailing punctuation. Number tokens get about a quarter to a ninth of the time they are spoken for.
- **Root cause:** The bug is real and has a concrete trigger, but it is cosmetic. Word timing is always estimated from the display text, and neither engine reports real word positions.
- **Fix:** New SentenceSegmenter.spokenNumberSyllables(token), added to tokenWeight. A year in 1100...2099 counts 4 syllables.
- **Test:** SentenceSegmenterTests.testNumberTokensWeighTheirSpokenLength
- **Commit:** `502db00`

##### H041 · Low · iPhone + Mac

**Several playback timing estimates use the wrong speed for the rest of the sentence after a speed change. outputLag reports timePitch.rate as the rate at which media is pulled, even while timePitch.bypass is on.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:620` (polish)
- **Scenario:** applyTimePitchRate sets timePitch.rate = residual unconditionally but leaves bypass on while the node plays. For the rest of that sentence the bypassed unit passes media through 1:1.
- **Root cause:** The bug is real, and the app's own G025 test confirms the state it depends on. When the speed changes while audio plays, applyTimePitchRate sets timePitch.rate to the new residual but leaves timePitch.bypass on until the next clip boundary (line 106).
- **Fix:** outputLag now returns `timePitch.bypass ? 1 : rate`, which fixes the word highlight's latency subtraction.
- **Test:** NativeSpeedTests.testABypassedUnitIsReadAtOneToOne (after a speed change mid-render, outputLag.timePitchRate is 1 and secondsUntilEnd covers the clip's remaining media 1:1; paused, it reads the 1.5 share) and testWallTimePassesABypassedStretchOneToOne (pure WordKaraokeState unit test)
- **Commit:** `6646580`

##### H042 · Low · iPhone + Mac

**When installed model files are found damaged, the Settings card has no way to remove the roughly 353 MB they still take.**

- **Where:** `ios/Aloud/TTS/ModelDownloadView.swift:238` (bad-ux)
- **Scenario:** Two paths lead here. detectExisting finds a wrong-size file or a hash mismatch (ModelManager.swift:566, 596), or the engine's load check calls markInstalledFilesDamaged. Both set .failed(.damaged), and the files stay on disk on purpose ("reported, never deleted").
- **Root cause:** The gap is real. In .failed(.damaged), Settings' card shows only the retry line ("Voice files damaged · Download again"). removePartialDownload checks stagedBytes, which counts only the staging directory.
- **Fix:** New ModelManager.removableBytes: the staged bytes, plus the installed size in .failed(.damaged) when the app owns the install directory. ModelDownloadView's Remove now checks removableBytes instead of stagedBytes, so in the damaged state Settings shows the confirmed Remove Download, titled "Remove the damaged voice files?" with "Frees N MB…".
- **Test:** ModelVerificationTests.testDamagedFilesAreRemovableWithoutADownload
- **Commit:** `ec29c3a`

##### H043 · Low · iPhone + Mac

**The not-enough-space line always says "need 707 MB free".**

- **Where:** `ios/Aloud/TTS/NaturalVoiceOffer.swift:284` (polish)
- **Scenario:** hasRoom (ModelManager.swift:162-165) requires requiredFreeBytes - stagedBytes. Once model.onnx (325.6 MB) is staged and kept after a cancel or failure (F019), a retry needs about 381 MB. failure(.notEnoughSpace) still formats ModelManager.requiredFreeBytes, which is 707 MB, both on the card and in the reader's offer line (offerLine).
- **Root cause:** This is an incomplete part of the F019 fix (commit f003a7c), not a re-report. That fix made the check subtract staged bytes: hasRoom at ModelManager.swift:162-165 is called with stagedBytes at lines 655 and 693.
- **Fix:** New ModelManager.freeBytesNeeded(stagedBytes:), shared by hasRoom and the message. fail(.notEnoughSpace) records the check's figure in ModelManager.spaceNeeded. NaturalVoiceCopy.failure, failureLine and offerLine take need: (defaulting to requiredFreeBytes, so existing callers and tests keep 707).
- **Test:** ModelVerificationTests.testTheSpaceLineNamesWhatTheCheckAskedFor (381 MB with model.onnx staged, 707 MB after Remove, spoken line included); ContinueCardStateTests.testAfterASpaceFailureTheOfferReadsTheSpaceLine adds a spaceNeeded case (iOS-only file)
- **Commit:** `ec29c3a`

##### H044 · Low · iPhone + Mac

**The cross-page sentence stitch still only covers cased scripts and Chinese/Japanese.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:403` (bad-ux)
- **Scenario:** appendPageParagraphs joins the next page's first paragraph only if it starts with \p{Ll} or \p{N}, continues unspaced CJK, or follows a hyphen. Hangul syllables (U+AC00–D7A3) and Arabic, Hebrew, Devanagari and Thai letters are \p{Lo}. isUnspacedCJK does not cover Hangul.
- **Root cause:** The finding is accurate, and I reproduced it. appendPageParagraphs (ios/Aloud/Extraction/PDFTextExtractor.swift:396-413) joins the next page's first paragraph only in four cases: it starts with \p{Ll} or \p{N}; continuesUnspacedCJK is true; the previous block ends in an ASCII letter and a hyphen; or it ends in a soft hyphen. isUnspacedCJK (:215) covers Han, kana and CJK/fullwidth punctuation, but not Hangul (U+AC00-D7A3) or the Arabic, Hebrew, Devanagari and Thai letters, which are all \p{Lo}. So a sentence in those scripts that runs over a page break stays two blocks.
- **Fix:** A new continuesCaseless check joins a page's first paragraph when the text on both sides of the break is a \p{Lo} letter outside the Han/kana range, skipping trailing vowel signs and marks scalar by scalar. Swift Regex works on whole grapheme clusters, so a \p{M} regex could not strip them.
- **Test:** PDFTextExtractorTests.testCaselessScriptSentencesRejoinAcrossPages
- **Commit:** `34d6319`

##### H046 · Low · iPhone + Mac

**Over-long Chinese or Japanese sentences are hard-cut at exactly 350 characters, mid-word.**

- **Where:** `ios/Aloud/Extraction/SentenceSegmenter.swift:363` (polish)
- **Scenario:** softSplitLongSentence records a break after , ; : ) — – only if whitespace follows (j > i + 1). After NFKC, '，' becomes ',' with no space after it, and '、' is not in the clause set.
- **Root cause:** I reproduced it, and it is real. Before segmentation, ExtractionPipeline.swift:87 runs TextNormalizer.normalize, which applies NFKC and turns '，' into ',' with nothing after it.
- **Fix:** softSplitLongSentence adds 、 (and fullwidth ，；：) to the clause set. A clause mark with no whitespace after it now counts as a break when the mark or the next character is CJK, using the existing PDFTextExtractor.isUnspacedCJK.
- **Test:** SentenceSegmenterTests.testLongCJKSentenceSplitsAfterClauseMarks
- **Commit:** `502db00`

##### H047 · Low · iPhone + Mac

**Any one-word line made only of the letters i, v, x, l, c, d and m ('I', 'XII', 'Did', 'mild', 'civil', 'vivid') within two lines of a page edge is removed as a page number...**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:252` (polish)
- **Scenario:** isPageNumberLine uses wholeMatch of (?i)[ivxlcdm]{1,7}, which also matches non-numeral words, and stripNoise deletes any such line when index <= 1 or index >= n-2. A classic whose chapters are headed "I", "II" or "XIV" at the top of the opening page loses the heading from the text, so it is neither shown nor spoken.
- **Root cause:** The mechanism is real. PDFTextExtractor.isPageNumberLine (ios/Aloud/Extraction/PDFTextExtractor.swift:249-253) whole-matches `(?i)[ivxlcdm]{1,7}`. stripNoise (lines 371-379) then drops any matching line at index 0-1 or n-2..n-1, with no gap test and no check on neighbouring pages.
- **Fix:** isPageNumberLine now accepts only digits or a well-formed Roman numeral (ChapterText.isRomanNumeral). A new romanFolioLines(_:) runs in extract().
- **Test:** PDFTextExtractorTests.testRomanFoliosGoButRomanHeadingsAndWordsStay
- **Commit:** `34d6319`

##### H048 · Low · iPhone + Mac (twin fixed on the other platform)

**Rename's Save button stays enabled when the field is empty or only spaces.**

- **Where:** `ios/Aloud/Library/LibraryView.swift:116` (polish)
- **Scenario:** The user chooses Rename, clears the title to type a new one, and taps Save by mistake (or types only spaces). The alert closes and the book keeps its old name, with no message.
- **Root cause:** The finding is real. Neither Rename alert disables Save, and DocumentStore.rename drops an empty or all-space title without telling the user.
- **Fix:** New shared `nonisolated static func DocumentStore.renamedTitle(_:) -> String?`, which rename() now uses. LibraryView's Save button has `.disabled(DocumentStore.renamedTitle(renameText) == nil)`.
- **Test:** ProgressIndexTests.testAnEmptyTitleIsNoRename; LibraryLintTests.testRenameSaveIsOffWithoutATitle
- **Commit:** `a803def`, `26071f9`

##### H049 · Low · Mac

**On the Mac, VoiceOver does not say what the error line's button does.**

- **Where:** `ios/Aloud/Reader/ReaderMessageLine.swift:132` (bad-ux)
- **Scenario:** Mac, VoiceOver on. A sentence fails to synthesize, so status becomes .error and the chapter line shows the retry line (arrow + DeviceCopy.playbackFailed, which on the Mac is just "Playback stopped").
- **Root cause:** The finding holds. On the Mac, the error arm of the shared chapter line is a Button that retries (onRetry, which is MacPlayerBar.retry() calling playback.play()).
- **Fix:** The shared retryLine gets .accessibilityHint(ReaderMessageLine.retryHint), "Plays from the sentence that failed". It is a local static next to contentsHint, following that existing pattern, with no platform split.
- **Test:** MacPlatformTests.testTheErrorLineHintSaysItRetries (written, not run; it pins the copy and the reason for it, since a hosted SwiftUI accessibility tree isn't built in unit tests, which a probe confirmed)
- **Commit:** `f0839e6`

##### H050 · Low · iPhone + Mac (twin fixed on the other platform)

**After a playback error, a skip or scrub leaves the error stop on the chapter line ("tap to try again") but turns the Play circle back to "Play, paused".**

- **Where:** `ios/Aloud/Reader/PlayerBarView.swift:329` (bad-ux)
- **Scenario:** A sentence fails, so status is .error, the line reads "Playback stopped · tap to try again" and the circle reads "Try again". The user taps Back 15 or Forward 15, or makes a VoiceOver scrub adjust. skip/jump goes through seek(to:andPlay:false), whose paused branch sets status = .paused (PlaybackController.seek, around line 996).
- **Root cause:** The trace holds on both platforms. After a failure, status is .error and the stop slot holds .playbackError.
- **Fix:** Fixed in PlayerBarView only. New static PlayerBarView.circleStatus(_:stop:) maps idle/paused to .error while stopReason(for:) is .playbackError, so the circle keeps 'Try again' for as long as the line says 'tap to try again'.
- **Test:** PlayerBarLayoutTests.testAPlaybackErrorStopKeepsTheCircleOnTryAgain (new, iOS-only)
- **Commit:** `98a5570`, `26071f9`

##### H051 · Low · iPhone + Mac (twin fixed on the other platform)

**While the sleep timer is armed, VoiceOver hears the raw m:ss countdown ("28:14, sleep timer", or "60:00, sleep timer" for 1 hr).**

- **Where:** `ios/Aloud/Reader/SleepChip.swift:45` (polish)
- **Scenario:** Arm the 30 min sleep timer and move VoiceOver to player.sleep. The label is "\(sleepTimer.chipText), sleep timer", where chipText is ListeningEstimate.countdown, e.g.
- **Root cause:** Both apps build the armed chip's VoiceOver label from the visual countdown, and nothing changes or adds to it. I traced it.
- **Fix:** New shared SleepTimer.chipSpokenLabel in SleepChip.swift, which both apps compile. Minute timers read 'N minutes left, sleep timer', rounded up like the countdown; Chapter end / Book end unchanged; 'Sleep timer' when off.
- **Test:** SleepTimerTests.testChipText... additions: chipSpokenLabel == '1 hour left, sleep timer' (60 min), '29 minutes left, sleep timer' (28:14), 'Book end, sleep timer', 'Sleep timer' when off. Runs on both apps
- **Commit:** `98a5570`, `26071f9`

##### H053 · Low · iPhone

**The reader's 'Aa' toolbar button does not opt in to the Large Content Viewer.**

- **Where:** `ios/Aloud/Reader/ReaderScreen.swift:154` (polish)
- **Scenario:** Set Settings > Accessibility > Display & Text Size > Larger Text to AX3 or larger and open a book. The title shows a large preview when long-pressed.
- **Root cause:** The finding holds as polish, though I couldn't run the app. The 'Aa' ToolbarItem in ReaderScreen.swift (lines 152-165) is a Button with a custom label: Text("Aa"), .font(Theme.font(.headline)), .frame(minWidth: 44, minHeight: 44) and .contentShape.
- **Fix:** Added .accessibilityShowsLargeContentViewer { Text("Aa") } to the Aa button. The lint is a source scan and was not run (no xcodebuild).
- **Test:** ReaderLintTests.testTheReadersBarControlsOfferTheLargeContentViewer (new source lint: every ToolbarItem(placement:) block in ReaderScreen.swift has .accessibilityShowsLargeContentViewer; fails before the fix for the Aa item)
- **Commit:** `98a5570`

##### H055 · Low · iPhone + Mac

**When the installed voice files are damaged, the Settings natural-voice card offers no way to remove them.**

- **Where:** `ios/Aloud/TTS/ModelDownloadView.swift:238` (bad-ux)
- **Scenario:** ModelManager.detectExisting() sees files of the wrong size, or the engine calls markInstalledFilesDamaged(). Either path calls fail(.damaged), which leaves model.onnx and voices.bin in Application Support/KokoroModel ('stay on disk until Download again replaces them', ModelManager.swift:589).
- **Root cause:** The main claim holds. When the installed files are damaged, Settings > Voice & speed shows no Remove Download, so the user can't free the space without tapping 'Download again'.
- **Fix:** Duplicate of H042, fixed once. The secondary claim (the card still says damaged after the prompt is cancelled) was refuted by the verifier, so nothing changed there.
- **Test:** ModelVerificationTests.testDamagedFilesAreRemovableWithoutADownload
- **Commit:** `ec29c3a`

##### H056 · Low · iPhone

**Selected options are shown by an accentSoft fill that barely differs from the unselected ground, and Increase Contrast does not strengthen it. accentSoft has no highContrastAlpha...**

- **Where:** `ios/Aloud/Theme/AloudTheme.swift:80` (bad-ux)
- **Scenario:** Light appearance, Increase Contrast on. Open the reader's Aa sheet (or Settings > Text & appearance) and look at the System / Light / Dark row.
- **Root cause:** The reported numbers are correct and the scenario can happen. Nothing in the code strengthens the selected cue under Increase Contrast.
- **Fix:** New token Theme.selectedEdge (alpha 0 by default, accentStrong's high-contrast values at alpha 1 under Increase Contrast), plus Theme.Stroke.selectedWidth (1.5) and selectedColor. The edge is drawn only on the selected option.
- **Test:** ThemeTokenContrastTests.testIncreaseContrastEdgesTheSelectedOption (new: selectedEdge clear without Increase Contrast; at least 3:1 on bg, bgTint, surface, surface2 and on the accentSoft fill with it). A Python probe gives 5.5:1 to 11.7:1
- **Commit:** `98a5570`

##### H057 · Low · iPhone + Mac

**The 'Not enough space' line always says 'need 707 MB free', but the space check subtracts the bytes already staged by an earlier attempt.**

- **Where:** `ios/Aloud/TTS/NaturalVoiceOffer.swift:284` (polish)
- **Scenario:** Since the F019 fix, ModelManager.hasRoom checks freeBytes >= requiredFreeBytes - stagedBytes (ModelManager.swift:162-165, 655, 693). NaturalVoiceCopy.failure(.notEnoughSpace) still prints the constant ModelManager.requiredFreeBytes (NaturalVoiceOffer.swift:284), and offerLine copies that line onto the shelf offer.
- **Root cause:** The space check and the space message use different numbers. The check subtracts what is already staged: `ModelManager.hasRoom` uses `freeBytes >= requiredFreeBytes - max(0, stagedBytes)` (ModelManager.swift:162-165), and both `requestDownload` (655) and `startDownload` (693) pass `stagedBytes`.
- **Fix:** Duplicate of H043, fixed once.
- **Test:** ModelVerificationTests.testTheSpaceLineNamesWhatTheCheckAskedFor
- **Commit:** `ec29c3a`

##### H058 · Low · iPhone

**VoiceOver reads the Settings 'Voice & speed' row as 'Voice & speed, Michael · 1.25×', middle dot included.**

- **Where:** `ios/Aloud/Settings/SettingsView.swift:82` (polish)
- **Scenario:** listeningRowLabel puts ListeningFormat.chipTitle(...) ('Michael · 1.25×') inside the NavigationLink label and sets no accessibilityLabel. The link's spoken name is therefore the raw visible text.
- **Root cause:** The Settings "Voice & speed" NavigationLink (SettingsView.swift:17-23) has an identifier and input labels, but no accessibilityLabel. Its label view, listeningRowLabel (lines 80-98), is a title Text plus Text(ListeningFormat.chipTitle(voice:rate:)). chipTitle returns "\(shortName) · \(rate)" (ListeningFormat.swift:24-25).
- **Fix:** The Settings NavigationLink gets .accessibilityLabel from a new nonisolated static SettingsView.listeningRowSpokenLabel(voice:rate:). It puts the title first, then shortName and ListeningFormat.rate, matching the player chip. iPhone-only; the Mac has no twin.
- **Test:** ListeningFormatTests.testFractionalRates adds an iOS-only check: SettingsView.listeningRowSpokenLabel gives "Voice & speed, Michael, 1.25×" with no middle dot
- **Commit:** `ec29c3a`

##### H059 · Low · Mac

**On the Mac, Theme.Stroke.hairlineWidth comes from NSScreen.main, which is the screen holding the key window, not the screen the drawing window is on.**

- **Where:** `ios/Aloud/Platform/PlatformColor.swift:73` (polish)
- **Scenario:** MacBook (2x) with an external 1x display. Put the library or reader window on the external display, then press Cmd-, so the Settings window opens and becomes key on the built-in screen.
- **Root cause:** The mechanism is real. On the Mac, Theme.Stroke.hairlineWidth (AloudTheme.swift:186) returns PlatformScreen.hairline, which is 1 / NSScreen.main.backingScaleFactor (PlatformColor.swift:73).
- **Fix:** PlatformColor.swift adds PlatformScreen.hairline(scale:), View.hairlineHeight() (a modifier that reads @Environment(\.displayScale)) and HairlineCapsuleBorder. All six Mac consumers now use them: MacPlayerBar and MacLibraryView (owned), plus single-line swaps in MacClassicsView (the rule that vanished), MacScrub (the capsule stroke), MacReaderScreen and MacSettingsView, none of which this batch owns.
- **Test:** MacThemeTests.testAHairlineFollowsTheScreenItIsDrawnOn (written, not run). It renders a bottom-aligned rule with ImageRenderer at 1x and 2x and checks the last pixel row is the rule and the row above is white.
- **Commit:** `f0839e6`

##### H060 · Low · iPhone + Mac

**Neither app declares ITSAppUsesNonExemptEncryption, so App Store Connect will hold every uploaded build at 'Missing Compliance' until someone answers the export questions by hand.**

- **Where:** `ios/project.yml:50` (polish)
- **Scenario:** Archive the iPhone app or the Mac app and upload the build to App Store Connect. The build shows 'Missing Compliance' and can't be sent to TestFlight testers or submitted until the export-compliance questions are answered in the web UI, and this repeats for every build.
- **Root cause:** The finding holds, and I couldn't find anything that cancels it. Neither app declares ITSAppUsesNonExemptEncryption anywhere: not in the hand-kept Info.plists, not in either target's info.properties in project.yml, and not as an INFOPLIST_KEY_ build setting.
- **Fix:** Added ITSAppUsesNonExemptEncryption: false under info.properties for both the Aloud and AloudMac targets in project.yml. Also added <key>ITSAppUsesNonExemptEncryption</key><false/> to the checked-in ios/Aloud/Info.plist and ios/AloudMac/Info.plist, in sorted position, matching what XcodeGen writes; plutil -lint passes.
- **Test:** ios/AloudTests/ShippedBundleTests.swift testTheAppDeclaresNoNonExemptEncryption (built bundle, both hosts); ios/AloudTests/MacProjectLintTests.swift ReleaseProjectLintTests.testBothAppsDeclareNoNonExemptEncryption (iOS suite lint)
- **Commit:** `6c8db0b`

#### Tooling and release

##### H015 · Medium · Tooling

**run() works out `pending` once and never checks `have` again inside the loop.**

- **Where:** `tools/gutenberg_fetch.py:273` (broken-feature)
- **Scenario:** 1) Someone hand-edits tools/gutenberg_queue.json and lists a book twice, or writes "id": "1342" or "year": "c. 1600".
- **Root cause:** run() in tools/gutenberg_fetch.py (lines 268-335) works out `pending = [q for q in queue if q["id"] not in have]` once. Inside the loop it only calls `have.add()` and never checks `have` again. main() (338-354) checks only that the queue is non-empty.
- **Status:** deferred. tools/gutenberg_fetch.py is being edited in another session.

#### Web app

##### H027 · Medium · Web app

**In Chrome, clicking any button leaves focus on it, and the shortcuts shown in the header then misfire.**

- **Where:** `frontend/src/hooks/useKeyboard.ts:46` (broken-feature)
- **Scenario:** In Chrome, open a PDF and click the Next sentence button with the mouse. Then press Space to pause: Next fires again and skips another sentence.
- **Root cause:** The global handler in frontend/src/hooks/useKeyboard.ts:46 returns early when the event target is inside `button, a, [role="button"], [role="slider"], …`, and line 43 does the same for any INPUT. Nothing in the frontend moves focus away from a player-bar control after a mouse click.
- **Fix:** useKeyboard.ts no longer drops every key on a button, slider or range input. It classifies the target (typing/range/track/button/composite/other) and asks globalShortcut() in the new lib/controlKeys.ts. ←/→ now step sentences when a button has focus.
- **Test:** frontend/tests/controlKeys.test.ts: 'H027: a button the mouse left focused does not keep Space or the arrows', 'H027: Space plays or pauses from the sliders, which keep their arrows', 'H027: fields and lists keep their keys...', 'H027: the global handler asks controlKeys...'
- **Commit:** `b22ef76`

##### H029 · Medium · Web app

**A PDF parse cannot be cancelled.**

- **Where:** `frontend/src/lib/intake.ts:34` (broken-feature)
- **Scenario:** With book X open, drop a large PDF A. While 'Preparing your document' shows, click New (App.tsx:123), which runs player.stop() and reset(), and pick a small PDF B.
- **Root cause:** The G015 fix caused it. Before c21aa63, the drop guard ran handleReset() before parsing, so doc was null while loading.
- **Fix:** intake.ts now gives each openPdf call an AbortController. cancelPdfIntake() is exported, and App.handleReset (New) and every newer openPdf call it. A stale result or failure returns without touching the store: no install, no error banner, no restored status.
- **Test:** frontend/tests/intake.test.ts: 'H029: a parse abandoned with New does not open over the book opened since', 'H029: an abandoned parse that fails raises no error over the next book', 'H029: New during a parse with nothing opened after leaves the empty state'; appWiring.test.ts 'H029: New abandons a PDF that is still parsing'
- **Commit:** `b22ef76`

##### H031 · Medium · Web app (twin fixed on the other platform)

**seekTo, jump and playIndex never abort the synthesis requests for the position being left.**

- **Where:** `frontend/src/lib/player.ts:686` (bad-ux)
- **Scenario:** While playing, tap → eight times quickly. Each jump reuses the prefetch entry for the next sentence and starts a new prefetch for the one after.
- **Root cause:** In frontend/src/lib/player.ts the only place a request is aborted is dropResources (line 353). That runs from just three callers: evict() when the LRU passes MAX_CACHE=30, invalidateStaleParams() on a voice or skip change, and stop(). playIndex (384), jump (662) and seekTo (686) never abort the entries for the position being left, so their fetches stay open.
- **Fix:** New PlayerImpl.dropOutsideWindow(i) aborts and evicts every in-flight cache entry (url === null) whose sentence id is outside [i, i+LOOKAHEAD]. It runs in playIndex, which covers seekTo, jump-while-playing and the busy retry, and in jump's paused cue path.
- **Test:** frontend/tests/player.test.ts: 'H031: a seek drops the requests for the position it leaves' and 'H031: a step while paused drops the requests for the sentence it leaves' (muted rig with a new hangSynth fake backend that records aborts). Both were confirmed to fail with the fix disabled.
- **Commit:** `b22ef76`, `77b3b0b`

##### H034 · Medium · Web app

**While a sentence is buffering, the play button's aria-label and title say 'Play', but toggle() treats 'buffering' as playing and pauses.**

- **Where:** `frontend/src/components/PlayerBar.tsx:118` (bad-ux)
- **Scenario:** With VoiceOver or NVDA, press Play. Status becomes 'buffering', the button shows a spinner but is still announced as 'Play'.
- **Root cause:** The finding is real. In frontend/src/components/PlayerBar.tsx:119-120 the play button's name and tooltip come only from `isPlaying` (`status === 'playing'`).
- **Fix:** PlayerBar now takes the play button's aria-label and title from playButtonLabel(status): 'Pause' for both playing and buffering, as PlayButtonState does on iPhone and Mac. It also sets aria-busy while buffering and adds a visually-hidden polite role=status that says 'Loading audio' during buffering.
- **Test:** frontend/tests/controlKeys.test.ts: 'H034: while buffering the play button is named Pause, since a press pauses' and 'H034: the play button uses that name and announces the wait'
- **Commit:** `b22ef76`

##### H035 · Medium · Web app

**Auto-scroll backs off only after wheel or touchmove events.**

- **Where:** `frontend/src/components/Reader.tsx:224` (bad-ux)
- **Scenario:** During playback, a keyboard user presses End or ↓ several times to pick a later sentence to jump to with Enter. Focus moves and the view scrolls to it.
- **Root cause:** In Reader.tsx, auto-scroll backs off only on 'wheel' and 'touchmove' (lines 224-236). The effect at lines 204-221 runs on every currentSentence change and calls scrollIntoView({block:'center'}) on the active sentence whenever userScrolledAt is more than 1.8 s old.
- **Fix:** Reader has a `browsing` ref, updated by browsingAfter() from readerNav.ts. ↑/↓/Home/End focus moves set it. Enter, ←/→, a click, or focus leaving the reader clear it.
- **Test:** frontend/tests/readerNav.test.ts: 'H035: moving focus with ↑/↓/Home/End starts browsing; Enter and ←/→ end it', 'H035: no auto-scroll while browsing, however long ago the last scroll was', 'H035: Page keys count as the user scrolling', 'H035: the reader tracks browsing and marks scrollbar drags and Page keys'
- **Commit:** `b22ef76`

##### H037 · Medium · Web app

**The position track uses role=slider but handles only ArrowLeft/ArrowRight.**

- **Where:** `frontend/src/components/PlayerBar.tsx:78` (bad-ux)
- **Scenario:** Tab to 'Playback position' in a 5,000-sentence PDF and press End or PageDown: nothing happens, because the global handler also ignores role=slider. Reaching the middle of the book takes about 2,500 presses of →.
- **Root cause:** The finding holds. In frontend/src/components/PlayerBar.tsx:78-86, the onKeyDown handles only ArrowRight (player.next()) and ArrowLeft (player.prev()).
- **Fix:** The track's onKeyDown uses positionKeyTarget(): ←/↓ and →/↑ move one sentence, PageUp/PageDown move 5% of the book (at least 1), Home/End go to either end. It calls a new public player.moveTo(index), which wraps jump(), so playing or paused stays as it was. aria-valuetext is now 'Sentence n of N, page p'. aria-valuenow is clamped to at least 1, so it no longer falls below aria-valuemin.
- **Test:** frontend/tests/controlKeys.test.ts: 'H037: the position slider takes Home, End, the Page keys and all four arrows', 'H037: slider steps are clamped...', 'H037: the slider says which sentence and page, not a bare number'
- **Commit:** `b22ef76`

##### H065 · Low · Web app

**Each getDocument call starts its own pdf.js Web Worker (pdfjs-dist 4.10.38, api: `new PDFWorker` per task). loadPdf destroys it only on the success path at line 353.**

- **Where:** `frontend/src/lib/pdf.ts:265` (bad-ux)
- **Scenario:** Drop a 150 MB password-protected PDF three times. Each attempt rejects with PasswordException at line 269, but the loading task is never destroyed, so three workers each keep a 150 MB copy.
- **Root cause:** The leak is real and I reproduced it. loadPdf (frontend/src/lib/pdf.ts:263-276) runs `await pdfjs.getDocument({ data, CMapReaderFactory }).promise` without keeping the loading task. The only call that frees the worker is `await pdf.destroy()` at line 353, on the success path. pdfjs-dist 4.10.38 sets no GlobalWorkerOptions.workerPort, so getDocument starts a new dedicated Worker for every task (pdf.mjs line 11410: `new PDFWorker(workerParams)`) and transfers `data.buffer` into it (line 11459, the GetDocRequest).
- **Fix:** New lib/pdfTask.ts withPdfDocument(task, openError, parse, signal) keeps the loading task. It destroys the task exactly once in a finally block, and immediately on abort, so the worker goes whether the open fails (PasswordException/InvalidPDFException), the parse fails, the parse is abandoned, or it succeeds. pdf.ts loadPdf now hands pdfjs.getDocument(...) to it.
- **Test:** frontend/tests/pdfTask.test.ts: 'H065: a PDF that fails to open still has its worker torn down', 'a failure while parsing pages still tears the worker down', 'a parsed PDF is torn down once', 'an abandoned parse stops the worker at once and rejects as aborted', 'loadPdf hands its loading task to withPdfDocument'
- **Commit:** `b22ef76`

##### H066 · Low · Web app

**Closing the voice popover (Escape, choosing a voice) or the options popover (Escape) unmounts the focused element without returning focus to the trigger, so focus falls to <body>.**

- **Where:** `frontend/src/components/VoicePicker.tsx:120` (bad-ux)
- **Scenario:** Keyboard user: Tab to the voice chip, press Enter (the search field gets focus), press Escape. Focus is now on body, so the next Tab starts again from the header and runs through New, the reader and the transport controls before reaching the voice chip.
- **Root cause:** The main defect is real, but the impact is smaller than reported. When the voice popover opens, focus moves into its search field (VoicePicker.tsx:124).
- **Fix:** VoicePicker and OptionsMenu now keep a triggerRef. If focus was inside the popover when Escape is pressed, focus goes back to the chip, and choose() focuses the chip after picking a voice.
- **Test:** frontend/tests/controlKeys.test.ts: 'H066: the voice list moves focus with the arrows, Home and End' and 'H066: closing a popover from the keyboard hands focus back to its chip'
- **Commit:** `b22ef76`

##### H067 · Low · Web app

**`.popover__search-input { outline: none }` overrides the global :focus-visible ring, and no :focus-within style exists on .popover__search.**

- **Where:** `frontend/src/styles/globals.css:829` (polish)
- **Scenario:** Open the voice picker with the keyboard. Focus is on the search field, but only a thin caret shows where it is, with no outline or border change.
- **Root cause:** The global `:focus-visible` rule (globals.css:141) and `.popover__search-input` (globals.css:825-831) have the same specificity, (0,1,0). The search-input rule comes later in the file, so its `outline: none` wins.
- **Fix:** globals.css adds `.popover__search:focus-within { box-shadow: inset 0 0 0 2px var(--accent); }` after the .popover__search-input rule, following the precedent of the F104 rate-slider fix. No twin.
- **Test:** frontend/tests/globalsCss.test.ts: 'H067: the voice search row shows focus, since the field drops its outline'
- **Commit:** `b22ef76`

### Loop 4: wave 5 re-review of the loop-3 fixes

#### Backend

##### I016 · Medium · Backend

**The H061 fix, webview.start(private_mode=False), stops pywebview from wiping WebKit's whole data store at launch.**

- **Where:** `backend/native_app.py:335` (bad-ux)
- **Scenario:** Build the legacy web app and use Aloud.app for a few weeks, so the cached index.html is fresh for days. Pull a fix and rebuild with legacy/build_web_app.sh or cd frontend && npm run build.
- **Root cause:** I could not refute it. Before loop 3, pywebview's private mode wiped every kind of WebKit website data at each launch, the HTTP disk cache included.
- **Fix:** The new _spa_shell() helper returns FileResponse(index.html, headers={'Cache-Control': 'no-cache'}). serve_index uses it, and so does spa_fallback, which now also sends a direct /index.html request through the shell. /assets and other dist files are unchanged. The test copies app.py into a temp repo layout with a fake frontend/dist and drives the ASGI app directly, with no sockets.
- **Test:** backend/tests/test_app_requests.py SpaShellCacheTests.test_the_shell_is_checked_before_each_use (fails before the fix), plus test_hashed_bundles_and_other_files_stay_cacheable
- **Commit:** `0a36778`

##### I017 · Low · Backend

**_take_over_when_gone makes only one takeover attempt and returns as soon as _start_own_server hands back a thread.**

- **Where:** `backend/native_app.py:216` (broken-feature)
- **Scenario:** ./run.sh is serving on 8000 and Aloud.app is open and attached. The user edits backend code, presses Ctrl-C and re-runs ./run.sh about a second later.
- **Root cause:** The defect is real and I reproduced it with the real uvicorn bind. `_take_over_when_gone` (backend/native_app.py:200-221) makes one takeover attempt, puts whatever `_start_own_server` returns into `own`, and then returns.
- **Fix:** After _start_own_server, the watcher waits in the new _serving(server, thread, stop) until uvicorn sets server.started, which happens once the port is bound. If the thread ends first (lost the bind race), it is removed from `own` and watching continues.
- **Test:** backend/tests/test_launchers.py AttachWatchTests.test_losing_the_port_to_another_backend_keeps_watching (fails before the fix)
- **Commit:** `0a36778`

##### I018 · Low · Backend

**The H026 twin is only half closed.**

- **Where:** `run.sh:73` (broken-feature)
- **Scenario:** ./run.sh is up, with Aloud on 127.0.0.1:8000. In another project the user starts a Node or Vite server on port 8000, which binds ::1 only and succeeds next to Aloud's IPv4 socket.
- **Root cause:** I could not refute it. The H026 fix only checks the port before startup: run.py preflight() calls probe_backend() and port_in_use() in native_app.py, which now dial both 127.0.0.1 and ::1.
- **Fix:** run.sh now sets VITE_API_BASE to http://127.0.0.1:$PORT and its start message prints 127.0.0.1. The README run line matches.
- **Test:** backend/tests/test_launchers.py RunShTests.test_reader_is_pointed_at_the_backend_port now expects http://127.0.0.1:8001 (fails before); extension/tests/background.test.mjs default-URL test now requires hostname 127.0.0.1, and the new 'I018: the old localhost default ... moves to 127.0.0.1' test (both fail before)
- **Commit:** `0a36778`

##### I019 · Low · Backend

**H061 made the fallback ports fixed (8001-8010) so the window keeps one origin and its saved preferences. find_running_backend still probes only ALOUD_PORT or 8000...**

- **Where:** `backend/native_app.py:162` (bad-ux)
- **Scenario:** Some other program holds 8000. Following the README, the user runs ALOUD_PORT=8001 ./run.sh, then opens Aloud.app. find_running_backend probes 8000 and finds the foreign program, so it does not attach. choose_port skips 8000 and 8001, which is busy because Aloud is on it, and serves on 8002, a second 325 MB load.
- **Root cause:** The defect is real and I reproduced it, but it is narrow and only affects the retired legacy pywebview Aloud.app. What holds: - At backend/native_app.py:162, find_running_backend() checks only `env_port() or DEFAULT_PORT`.
- **Fix:** Without ALOUD_PORT, find_running_backend probes DEFAULT_PORT and then FALLBACK_PORTS (8001-8010) in order and attaches to the first Aloud backend it finds. With ALOUD_PORT set it probes only that port, as before. main() then watches and takes over that same port, so the window keeps one origin.
- **Test:** backend/tests/test_launchers.py NativePortTests.test_aloud_on_a_fallback_port_is_attached_to (fails before the fix)
- **Commit:** `0a36778`

##### I020 · Low · Backend

**The attach watcher sends GET /health to the attached backend every 2 s for as long as the window is open. run.py runs uvicorn at log_level info with access logging on...**

- **Where:** `backend/native_app.py:211` (polish)
- **Scenario:** Run ./run.sh, then open Aloud.app, which attaches. Leave both open while reading.
- **Root cause:** I could not refute it. Loop 3 (e4d1e5a..HEAD) added the attach watcher `_take_over_when_gone` and `ATTACH_WATCH_SECS = 2.0`.
- **Fix:** The watcher's liveness check is now port_in_use(port) alone, a bare TCP connect that uvicorn does not log. The old condition, probe_backend(...) is not None or port_in_use(...), already reduced to port_in_use, because probe_backend can only succeed when 127.0.0.1 accepts.
- **Test:** backend/tests/test_launchers.py AttachWatchTests.test_watching_sends_the_backend_no_requests (fails before the fix: urlopen was called)
- **Commit:** `0a36778`

#### Browser extension

##### I022 · Medium · Extension

**Missed twin of H034.**

- **Where:** `extension/src/content/ui.ts:457` (bad-ux)
- **Scenario:** In the extension, with a screen reader on, press Play on a sentence that is not cached. Status becomes 'buffering' and the spinner shows, but VoiceOver or NVDA reads the button as 'Play'.
- **Root cause:** I could not refute this. The extension bar names its play button from `status === 'playing'` only.
- **Fix:** In ui.ts: added playButtonLabel(status), which gives Pause for playing or buffering and busy while buffering, as frontend controlKeys does. update() now sets aria-label, aria-busy, and a title of withShortcut(label, toggleKey). setShortcuts now remembers the toggle shortcut instead of the fixed 'Play / pause' tooltip. Added a visually hidden <span class="live" role="status" aria-live="polite"> that says 'Loading audio' while buffering.
- **Test:** extension/tests/content.test.mjs 'I022: while buffering the play button is named Pause, is busy, and the wait is announced'. It fails against 77b3b0b.
- **Commit:** `e6b4280`

##### I023 · Low · Chrome extension

**In selection mode the H030 fix turns off JUNK_RE completely, so screen-reader-only text (sr-only, visually-hidden, screen-reader-text, skip-link) is now read aloud even though the user cannot see it.**

- **Where:** `extension/src/content/extract.ts:336` (bad-ux)
- **Scenario:** A Bootstrap or WordPress page, or any page with screen-reader-only labels. The user drags across three paragraphs where the middle one is a 'Read more' link that carries a visually hidden label, then presses Alt+A or uses Read selection aloud.
- **Root cause:** I could not refute it. Both halves are real, the audit introduced them, and a user can hit them with the default controls.
- **Fix:** extract.ts shouldSkip: selection mode now checks a narrow VISUALLY_HIDDEN_RE (skip-link, screen-reader, visually-hidden, sr-only) instead of no class rule. Comment and footer classes still pass, and the H030 tests still pass. role="button" is now skipped in selections, matching BUTTON in SELECTION_SKIP_TAGS.
- **Test:** extension/tests/extract.test.mjs 'I023: a selection leaves out screen-reader-only text...' (covers sr-only, screen-reader-text and visually-hidden) and 'I023: a selection leaves out a role="button" control, as it does a <button>'. Both fail against 77b3b0b.
- **Commit:** `e6b4280`

##### I024 · Low · Chrome extension

**hasSelection() returns true for any non-collapsed selection, even one with no text.**

- **Where:** `extension/src/content/index.ts:297` (bad-ux)
- **Scenario:** After a page finishes, the user double-clicks blank space between paragraphs (Chrome selects the whitespace) or drags across an image, then presses Alt+A to hear the page again. The condition at line 355 sends this to start('selection').
- **Root cause:** I could not refute it. The defect is real and the loop-3 audit introduced it, but it is narrow and easy to recover from, so I rated it low rather than medium. hasSelection() in extension/src/content/index.ts:295-298 returns true for any non-collapsed selection: `return !!sel && (!sel.isCollapsed || sel.toString().trim() !== '')`.
- **Fix:** index.ts hasSelection() now requires sel.toString().trim() !== '' and that the selection is not in our UI (see I025). A non-collapsed selection with no words, at 'ended', now falls through to player.toggle(), which listens again.
- **Test:** extension/tests/content.test.mjs 'I024: at "Finished", a selection of blank space or an image does not stop the shortcut listening again'. It fails against 77b3b0b with the 'Nothing selected to read.' toast.
- **Commit:** `e6b4280`

##### I025 · Low · Chrome extension

**The new sel.toString() fallback does not check where the selection is.**

- **Where:** `extension/src/content/extract.ts:543` (polish)
- **Scenario:** While reading, the user selects the bar's title (the page title) or its status line ('Finished', '12 / 340'), for example to copy it. They then right-click › Read selection aloud, or press Alt+A at 'Finished'. extractSelection finds no range in the page DOM and falls back to sel.toString(), so the reader restarts reading 'Finished' or the title.
- **Root cause:** The path is real, and it is new in the loop-3 diff. The player bar's title and status text can be selected. extractSelection now falls back to sel.toString() without checking where the selection is.
- **Fix:** Added an exported selectionInUi(sel, uiHost) in extract.ts. It is true when the selection is collapsed and anchorNode.childNodes[anchorOffset] is uiHost or a [data-aloud] element, which is how Chrome reports a selection inside a shadow tree. extractSelection returns null for such a selection, and hasSelection ignores it.
- **Test:** extension/tests/extract.test.mjs 'I025: text selected in the player bar or a toast is never read back' (also checks that a text-field selection is still read). extension/tests/content.test.mjs 'I025: at "Finished", text selected in the bar itself is not read in place of the page'. Both fail against 77b3b0b.
- **Commit:** `e6b4280`

#### Mac app

##### I013 · Medium · Mac

**The H023 remap now moves the keyboard cursor without a word.**

- **Where:** `ios/AloudMac/Reader/MacContentsPanel.swift:133` (bad-ux)
- **Scenario:** Docked Contents in a chaptered book with 4 or more places (collapsedCount 3). The book plays long enough for a stop to count.
- **Root cause:** I could not refute it. The cursor moves silently, the trigger is reachable, and it breaks the panel's own rule.
- **Fix:** New MacContents.HeardRow / heardRow / remapIsUnheard compare a row by what it is: a place by its sentence, the toggle by how many stops it holds back (0 = "Show fewer"), a chapter by its index. In onChange(of: listLayout) the panel announces the cursor's row when the remap leaves it on an unheard row and the list has focus.
- **Test:** MacContentsPlacesTests.testARemapOntoARowNotHeardIsSaid covers the rule. ReaderLintTests.testTheMacContentsPanelSaysTheRowARemapLeftUnheard pins the onChange wiring and the focus-return branch; it was added in AloudMacTests and moved into the iOS suite in 8afe220, because Mac-hosted tests can't read the checkout.
- **Commit:** `45b1e17`, `8afe220`

##### I014 · Low · Mac

**toggleStatus now runs the loaded book through MacPlayerBar.circleStatus.**

- **Where:** `ios/AloudMac/Commands/MacCommandActions.swift:245` (polish)
- **Scenario:** In the reader, playback fails (status .error, stop .playbackError). The user presses → (skip), and the status becomes paused while the stop stays.
- **Root cause:** This is real, and the loop-3 diff introduced it on the Mac. Loop 3 sends the loaded book's status through circleStatus in three places: MacPlayerBar, PlayerBarView and MacCommandActions.toggleStatus.
- **Fix:** Fixed by the same change as I002. MacCommandActions.toggleStatus uses PlayButtonState.circleStatus for the loaded book.
- **Test:** Same tests as I002. The existing MacCommandActionsTests.testAPlaybackErrorKeepsTryAgainAfterASkip still covers the menu.
- **Commit:** `45b1e17`

#### Shared iPhone/Mac core and iPhone app

##### I000 · Medium · iPhone + Mac (shared core)

**When library.json can't be fully read, the store now fills the shelf with the records that still decode (PartialIndex).**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:650` (data-loss)
- **Scenario:** PlaceHistoryStore.shelfChanged (PlaceHistoryStore.swift:80-83) sweeps nothing only while the shelf has been empty since launch. Its comment assumes 'a library that failed to load' gives an empty shelf.
- **Root cause:** The defect is real, and the audit introduced it. Before e4d1e5a, loadIndex left `documents` empty when library.json failed to decode.
- **Fix:** The fix is in the shared core, so it covers both apps. AppModel.observePlaceHistory now gets its shelf subscription from a new static, AppModel.observeShelf(of:in:).
- **Test:** ios/AloudTests/PlaceHistoryStoreTests.swift testAPartialShelfSweepsNothing; ios/AloudTests/LaunchRestoreTests.swift testTheSlotWaitsWhileTheLibraryCantBeRead
- **Commit:** `0f1465b`

##### I001 · Medium · iPhone + Mac (shared core)

**Delete now removes a book's files only after the index write succeeds.**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:514` (broken-feature)
- **Scenario:** The device is out of space and the user deletes a large PDF to free some. AppModel.deleteDocument (AppModel.swift:281-286) runs letGo (unload), discardStop and closes the reader route, then calls store.delete.
- **Root cause:** I could not refute it. H009 (a803def) changed persistIndex() to throw. delete() at ios/Aloud/Library/DocumentStore.swift:514-530 now puts the shelf back and returns when that write fails.
- **Fix:** DocumentStore.delete now throws. It writes library.json without the book before it changes `documents`. persistIndex takes an optional shelf and writes through a test seam, writeIndexData.
- **Test:** ios/AloudTests/ProgressIndexTests.swift testADeleteOutOfSpaceFreesTheCachesAndTriesAgain, testADeleteTheIndexStillCantRecordKeepsTheBook, testADeleteWhileTheIndexIsUnreadableFails, testADeleteFailureSaysWhyInFixedCopy (plus updated testAnAddTheIndexCantRecordFails); ios/AloudTests/ContinuePlaybackTests.swift testMarkAsFinishedAndDeleteLetGoOnceTheStoreChanged (source lint, renamed from testMarkAsFinishedAndDeleteLetGoOnceTheStoreChanged); .deleteFailed added to MacCommandActionsTests.testMainWindowCommandsWaitForARootAlert and DocumentImporterTests.testOpenInClosesARootModalBeforeImporting
- **Commit:** `0f1465b`

##### I004 · Medium · iPhone + Mac

**The new heat drop of an incoming natural voice calls cancelVoiceHandoff(), and that restarts the current sentence whenever a splice is primed (PlaybackController.swift:1937)...**

- **Where:** `ios/Aloud/Playback/ThermalGuard.swift:116` (bad-ux)
- **Scenario:** primeHandoff (PlaybackController.swift:2008) fixes the splice at lastScheduled+1. That sentence sits past the top-up horizon until currentSentence advances, so for up to a whole sentence after priming lastScheduled < spliceAt, and only System clips are queued.
- **Root cause:** I could not refute it. The cited path runs as described. dropIncomingNaturalVoice() (ThermalGuard.swift:112-116, new in loop 3) calls cancelVoiceHandoff().
- **Fix:** cancelVoiceHandoff now calls reloadCurrent only when `let splice = pending.spliceAt, hasActiveSchedule, lastScheduled >= splice`, meaning a clip in the incoming voice is really on the node. Otherwise it only clears the handoff, and the top-up reads the splice in the voice already speaking.
- **Test:** ThermalGuardTests.testReheatingBeforeTheSwitchBackLandsKeepsTheSystemVoice (extended: no .stopped, no .buffering); VoiceHandoffTests.testCancellingBeforeTheSpliceIsQueuedNeverRestarts, testCancellingASpliceFixedPastTheEndNeverRestarts, testCancellingAfterTheSpliceIsQueuedRestartsInTheSpeakingVoice (the kept reload), testASwitchDroppedWhileItsClipSynthesizesSkipsNothing
- **Commit:** `0c67833`

##### I007 · Medium · iPhone + Mac (shared ios/Aloud)

**When a localized CJK heading has no title on its line ("第二章", "第3話"), the chapter title swallows the first body paragraph. titleLine() decides what a short title is by counting space-separated words...**

- **Where:** `ios/Aloud/Extraction/PDFChapters.swift:419` (broken-feature)
- **Scenario:** Import a Chinese PDF with no outline where each chapter opens with a bare "第一章" line and then body text on the same page. The headings tier (newly enabled for CJK in 58de30e) appends the whole first paragraph to the chapter title.
- **Root cause:** I reproduced it end to end, starting from a real PDF. HeadingChapters.titleLine (ios/Aloud/Extraction/PDFChapters.swift:413-421) treats the next paragraph on the same page as a bare heading's title when it has 8 or fewer whitespace-separated words and its last character is not one of . ! ?
- **Fix:** HeadingChapters.titleLine: if the next paragraph contains unspaced CJK, it must be 30 characters or fewer and contain none of 。！？!?. A closing 」『… also rejects it.
- **Test:** PDFChapterTiersTests.testLocalizedChapterHeadingsAreFound (new CJK bare-heading assertions: 第一章 followed by a 。 sentence, an unpunctuated 40-character run, and a 「…。」 line; 第一話 followed by 「先生」 and a 。 sentence; 第二章 followed by 镇上 still becomes a title)
- **Commit:** `37d9bc0`

##### I008 · Medium · iPhone + Mac (shared ios/Aloud)

**Localized chapter markers are now headings, but the Contents heading that triggers front-matter stripping is English only.**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:834` (broken-feature)
- **Scenario:** Import a Chinese web-novel TXT that starts "书名 / 目录 / 第一章 山村少年 / 第二章 进城 / 第三章 风波" and then has the chapters. Each TOC line passes isChapterHeading through localizedHeadingRegex, and headsText returns true for any single-line heading, so every TOC line opens a page.
- **Root cause:** I tried to refute this and could not. The defect is real, but medium (bad UX) fits better than "broken feature".
- **Fix:** contentsHeadingRegex now also matches 目录/目錄/目次/목차/차례 (letterspacing such as "目 录" allowed), Содержание/Оглавление, Inhalt/Inhaltsverzeichnis, Table des matières/Sommaire and Índice/Indice, each as a whole line. Adding the words alone was not safe.
- **Test:** ExtractionFrontMatterTests.testLocalizedContentsListIsSkipped, ExtractionFrontMatterTests.testLocalizedContentsHeadings
- **Commit:** `834a060`

##### I011 · Medium · iPhone + Mac (ContentsSheet and MacContentsPanel)

**Twin missed for the em-dash change.**

- **Where:** `ios/Aloud/Models/DocContent.swift:365` (broken-feature)
- **Scenario:** After importing a book containing "1812—1870" or "In 1915—20 years later", search Contents for "1812—1870" exactly as the source reads. The needles are ["1812--1870", "1812 - 1870"], and the stored text is "1812 -- 1870", so there are no results.
- **Root cause:** I could not refute it, and it is a regression from loop 3. Commit 502db00 changed TextNormalizer.translate so that an em dash or horizontal bar (U+2014/U+2015) after a digit is now stored as " -- " (TextNormalizer.swift:199-201).
- **Fix:** searchNeedles adds a third needle with the dash spelled ' -- ', dropped when it duplicates the ASCII needle. The existing exact-needle asserts (["a -- b", "a - b"]) are unchanged.
- **Test:** ContentsSearchFoldingTests.testDashQueryMatchesTheStoredClauseBreakAfterANumber
- **Commit:** `834a060`

##### I012 · Medium · iPhone + Mac (shared ios/Aloud)

**The indent-paragraph fix (H007) is incomplete. indentBreaks takes the left margin to be the most common minX, so on a dialogue-heavy page, where most paragraphs are one indented line...**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:209` (bad-ux)
- **Scenario:** A typeset novel PDF (even leading, first-line indents) has a page of short exchanges: '"Where are you going?"', '"Out."', '"Out where?"', and so on, with a few wrapped narrative paragraphs. The probe gave 1 paragraph for a page of 12, so highlighting, pauses and the reader layout run all the dialogue together.
- **Root cause:** indentBreaks (PDFTextExtractor.swift:203-224) takes `margin = mostCommon(lines.map(\.minX))`. When every paragraph opens with an indent, the indent column holds one line per paragraph (P) and the margin column holds the remaining L - P lines.
- **Fix:** indentBreaks now uses setOutMargin. When a column 0.5 to 4 line heights left of the most common minX has 2 or more lines, mostly continuing an unfinished line, and the common column's lines mostly follow a finished one, the left column becomes the margin.
- **Test:** PDFTextExtractorTests.testDialoguePagesKeepTheirParagraphs (12-line dialogue page with curly quotes gives 10 paragraphs; a hanging-indent bibliography gives no indent breaks)
- **Commit:** `37d9bc0`

##### I002 · Low · iPhone + Mac

**The H050 retry-circle fix (circleStatus) reached only the two reader bars and the Mac's Play/Pause menu title.**

- **Where:** `ios/Aloud/Library/LibraryView.swift:355` (bad-ux)
- **Scenario:** A sentence fails. In the reader, tap Back 15: status becomes .paused, and the bar now shows Try again, which is correct.
- **Root cause:** The defect is real. I couldn't refute it.
- **Fix:** circleStatus now lives only on PlayButtonState; the PlayerBarView and MacPlayerBar copies are removed. ContinuePlayback.effectiveStatus takes a required `stop:` and applies the rule, so the Continue card on both apps shows Try again.
- **Test:** ContinueCardStateTests.testAPlaybackErrorStopKeepsTheCardOnTryAgain (pure); ContinuePlaybackTests.testTheCardKeepsTryAgainAfterASkipPastAPlaybackError (muted rig: error, skip, card == bar == .retry)
- **Commit:** `45b1e17`

##### I003 · Low · iPhone + Mac

**The new chipSpokenLabel uses spokenPhrase, which clamps to at least 1 minute.**

- **Where:** `ios/Aloud/Reader/SleepChip.swift:107` (polish)
- **Scenario:** Arm a 15-minute timer and let it run down. At the deadline the countdown shows 0:00 (ListeningEstimate.countdown returns 0:00 in the landing window), but chipSpokenLabel computes minutes = 0 and spokenPhrase(minutes: 0) returns '1 minute'.
- **Root cause:** The bug is real, but the reported trigger is wrong. Letting the timer run down does not cause it.
- **Fix:** chipSpokenLabel now returns Copy.noTimeLeftSpoken + ", sleep timer" when remaining <= 0, and otherwise rounds up as before. The new copy is SleepTimer.Copy.noTimeLeftSpoken = "No time left".
- **Test:** SleepTimerTests.testChipText: the landing timer (remaining < 0, chipText 0:00) now asserts chipSpokenLabel == "No time left, sleep timer". Before the fix it read "1 minute left, sleep timer".
- **Commit:** `45b1e17`

##### I005 · Low · iPhone + Mac

**The H039 fix turns every em dash or horizontal bar after a digit into ' -- ', so a real year range typeset with an em dash is no longer read as a range: the 'to' is lost.**

- **Where:** `ios/Aloud/Extraction/TextNormalizer.swift:199` (polish)
- **Scenario:** Before the fix, "1914—1918" normalized to "1914 - 1918", and SpokenYears.range read it as "nineteen fourteen to nineteen eighteen". Now it becomes "1914 -- 1918". dashThenDigit (SpokenYears.swift:220) needs a digit right after a single hyphen, and the second '-' fails that check, so each year is read on its own: "nineteen fourteen -- nineteen eighteen".
- **Root cause:** I could not refute it. The H039 change (TextNormalizer.swift:197-199, added in the loop-3 diff) turns U+2014 or U+2015 into " -- " whenever the last non-space character before it is a digit.
- **Fix:** Fixed together with I010; it is the same regression. The new TextNormalizer.isClauseDash looks at what follows the dash.
- **Test:** TextNormalizerTests.testDashAfterANumberIsARangeBeforeARangeEnd, SpokenYearsTests.testEmDashYearRangeIsStillARange
- **Commit:** `834a060`

##### I006 · Low · iPhone + Mac

**H039 is fixed only for em dashes.**

- **Where:** `ios/Aloud/Extraction/TextNormalizer.swift:202` (polish)
- **Scenario:** Case 0x2012, 0x2013 still emits " - ", and the later whitespace collapse turns "1915 – 20" into "1915 - 20". dashThenDigit accepts a spaced hyphen, and isCount's year-cue exemption still lets range() join the year to the count after it. UK-published books use the spaced en dash ' – ' for every parenthetical dash, so the H039 input in British typography still fails.
- **Root cause:** The bug is real and a user can hit it. The H039 fix (e4d1e5a..HEAD) changes only U+2014 and U+2015: after a digit they now become " -- ".
- **Fix:** An en dash after a digit with whitespace on either side now uses the same isClauseDash rule as the em dash. An unspaced en dash is always ' - ' ("In 1914–18 men died" is still a range).
- **Test:** TextNormalizerTests.testDashAfterANumberIsARangeBeforeARangeEnd ("In 1915 – 20 years later" -> " -- ", "(1809 – 1882)" and "1914 – 18" -> " - "), SpokenYearsTests.testEmDashYearRangeIsStillARange
- **Commit:** `834a060`

##### I009 · Low · iPhone + Mac (shared ios/Aloud)

**appendLine now keeps a line-end hyphen and leaves the call to TextNormalizer's compound rule.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:236` (bad-ux)
- **Scenario:** Import a French PDF where a justified line ends "main-" and the next starts "tenant". The reader shows "Il est main-tenant parti." and the voice reads two words.
- **Root cause:** I could not refute it. Loop 3 (fix for the "wellknown" finding, commit d823c3d) changed PDFTextExtractor.appendLine (ios/Aloud/Extraction/PDFTextExtractor.swift:233-237).
- **Fix:** appendLine gets `english: Bool? = nil`. It keeps the hyphen plus line break for TextNormalizer's compound rule only when the text is English; otherwise it rejoins the way it did before loop 3. extract() reads the book's language once, with NLLanguageRecognizer over languageSample (up to 5 mid-page lines from about 20 pages spread across the book), and passes it through paragraphs(from:english:) and appendPageParagraphs(...english:).
- **Test:** PDFTextExtractorTests.testNonEnglishSyllableSplitsRejoin (French main-/tenant, German Not-/fall, Italian tan-/to rejoin within a page; par-/tie rejoins across a page break; english:false hint; languageSample reads French and English correctly)
- **Commit:** `37d9bc0`

##### I010 · Low · iPhone + Mac (shared ios/Aloud)

**An em dash after a digit now always becomes " -- ", including between two full years.**

- **Where:** `ios/Aloud/Extraction/TextNormalizer.swift:199` (bad-ux)
- **Scenario:** A PDF biography has "Charles Dickens (1812—1870)". The text is now stored as "(1812 -- 1870)", and SpokenYears sends Kokoro "(eighteen twelve -- eighteen seventy)", read with a pause.
- **Root cause:** I could not refute it. The loop-3 fix for H039 (commit 926ea58) causes the regression exactly as reported.
- **Fix:** Same fix as I005. The Dickens life dates "(1812—1870)" are read "eighteen twelve to eighteen seventy" again.
- **Test:** TextNormalizerTests.testDashAfterANumberIsARangeBeforeARangeEnd, SpokenYearsTests.testEmDashYearRangeIsStillARange
- **Commit:** `834a060`

##### I015 · Low · Mac

**The per-screen hairline fix (H059) missed a shared view the Mac draws.**

- **Where:** `ios/Aloud/Settings/ListeningView.swift:401` (polish)
- **Scenario:** MacBook (2x) with an external 1x display, reader window on the external display, built-in screen holding the key window. The user opens Voice & Speed… (or Settings ▸ Voice on the external screen).
- **Root cause:** The code gap is real. ListeningView.hairline(inset:) at ios/Aloud/Settings/ListeningView.swift:398-402 still uses .frame(height: Theme.Stroke.hairlineWidth).
- **Fix:** ListeningView.hairline(inset:) now uses .hairlineHeight(), which reads displayScale. The modifier exists on both platforms (PlatformColor.swift) and makes no difference on the iPhone.
- **Test:** SettingsHomeLintTests.testListeningRulesFollowTheScreenTheyAreDrawnOn (source lint: no Theme.Stroke.hairlineWidth, uses .hairlineHeight())
- **Commit:** `45b1e17`

#### Web app

##### I021 · Medium · web (Chrome, Edge, any Chromium browser)

**The H027 fix ('Space on a button the mouse left focused plays or pauses') never takes effect in Chromium.**

- **Where:** `frontend/src/hooks/useKeyboard.ts:36` (broken-feature)
- **Scenario:** I tested this in Chromium with a scratch probe page (a button plus a window keydown listener; real mouse click and key input). Right after the click, `button.matches(':focus-visible')` is false and the button has focus.
- **Root cause:** The Space half of the H027 fix never takes effect in Chromium. useKeyboard.ts:33-40 reads `el.matches(':focus-visible')` inside the window keydown listener. Chromium switches the focused element to focus-visible as part of processing the keydown, before the event is dispatched.
- **Fix:** Added a FocusOrigin class to lib/controlKeys.ts. It records el.matches(':focus-visible') at capture-phase focusin, stored in a WeakMap.
- **Test:** frontend/tests/controlKeys.test.ts: 'I021: a clicked button stays clicked though Chromium marks it focus-visible on keydown', 'I021: a button reached with Tab keeps Space; a later click on it gives Space back', 'I021: focus the tracker never saw counts as keyboard focus...', 'I021: useKeyboard saves focus origin at focusin and pointerdown, not inside keydown'. These fail against 77b3b0b, where FocusOrigin is not exported and the hook calls matches(':focus-visible') inside keydown.
- **Commit:** `e6b4280`

### Loop 4: full review wave 3

#### Backend

##### J032 · Medium · Backend

**The line-wrap hyphen repair also fuses suspended hyphens that the author wrote, mid-line.**

- **Where:** `backend/text_normalize.py:175` (broken-feature)
- **Scenario:** The user reads a news article with the extension, or a document in the web reader, containing 'Both short- and long-term rates rose.' engine.synthesize calls normalize_for_tts (kokoro_engine.py:125). _LINEWRAP_HYPHEN_RE ([A-Za-z])-\s+([a-z]) is applied at line 226 and gives 'Both shortand long-term rates rose.', so Kokoro says 'shortand'. Running it locally confirmed these outputs: 'pre- and post-war' becomes 'preand post-war', 'first- or second-order' becomes 'firstor second-order', and 'the x- and y-axis' becomes 'the xand y-axis'.
- **Root cause:** backend/text_normalize.py:175 defines _LINEWRAP_HYPHEN_RE = ([A-Za-z])-\s+([a-z]), and line 226 replaces every match with r"\1\2". Nothing guards it: there is no follower list, no newline requirement, and no check against a word list.
- **Fix:** _LINEWRAP_HYPHEN_RE now captures the gap and the next word, and a callback (_repair_line_wrap_hyphen) rejoins only when the gap contains a line break (\n \r \v \f) and the next word is not and/or/nor. Those are the same three followers as TextNormalizer.suspendedHyphenFollowers.
- **Test:** backend/tests/test_text_normalize.py HyphenTests. test_suspended_hyphens_mid_line_are_kept and test_suspended_hyphen_wrapped_before_a_follower_is_kept failed before the fix (they got 'preand', 'shortand', 'twoor'). test_line_wrap_hyphen_is_rejoined, test_unicode_line_breaks_count_as_line_breaks and test_compounds_without_a_space_are_untouched guard against regressions. All 90 backend tests pass.
- **Commit:** `ece0702`

##### J033 · Medium · Backend

**The 'build required' placeholder tells the user to build the frontend and then reload, but reloading never shows the reader.**

- **Where:** `backend/app.py:442` (bad-ux)
- **Scenario:** The user starts the backend (run.py, or native_app.py, which opens the window) before frontend/dist exists. The window or the browser shows 'Aloud backend is running ...
- **Root cause:** In backend/app.py, `if os.path.isfile(_INDEX_HTML):` at line 442 runs once, when the module is imported. If frontend/dist/index.html is missing then, only `serve_placeholder` is registered on '/' (lines 489-494). serve_index, spa_fallback and the /assets mount never exist in that process.
- **Fix:** serve_index, spa_fallback and _spa_shell are now registered whether or not the frontend is built. _spa_shell checks os.path.isfile(_INDEX_HTML) on each request and returns the placeholder (now with Cache-Control: no-cache) until the build exists, then the real shell. The catch-all serves /assets/* from a build made after startup.
- **Test:** backend/tests/test_app_requests.py BuildAfterStartTests. It loads a copy of app.py in a temp tree that has no frontend/dist. test_placeholder_is_shown_and_checked_before_each_use and test_a_build_made_after_start_is_served_on_reload failed before the fix: there was no no-cache header, and the placeholder was still served after the build. test_api_routes_still_win_over_the_catch_all checks that /health still works.
- **Commit:** `ece0702`

#### Browser extension

##### J039 · High · Extension

**Audio plays through a page-owned <audio> element with a blob: URL made in the content script (line 455).**

- **Where:** `extension/src/content/player.ts:716` (broken-feature)
- **Scenario:** The user opens a GitHub README (github.com's media-src lists only github.com and asset hosts, not blob:) or another site with a strict CSP and starts reading. Each clip synthesizes fine.
- **Root cause:** I could not reproduce it in a browser because the rules forbid it. The content script runs in the default ISOLATED world: background/index.ts:160 calls executeScript with files ['content.js'] and no world option.
- **Fix:** The <audio> element stays the first choice. If it refuses a clip with anything other than NotAllowedError (a CSP block shows up as NotSupportedError or an 'error' event), the player switches for the rest of the session to WebAudioClip (new content/webaudio.ts) and retries the same sentence there.
- **Test:** extension/tests/player.test.mjs: 'J039: on a page whose CSP refuses blob: media, every sentence plays through Web Audio', 'J039: a clip Web Audio cannot decode either is skipped once, and reading goes on', 'J039: through Web Audio, speed keeps its pitch and pause resumes where it stopped', 'J039: the time stretch keeps the pitch and the loudness' (FakeAudioContext added to tests/harness.mjs)
- **Commit:** `af3c97d`

##### J042 · High · Extension

**isHidden calls checkVisibility with contentVisibilityAuto: true.**

- **Where:** `extension/src/content/extract.ts:323` (broken-feature)
- **Scenario:** An article is split into sections styled content-visibility:auto, and the page is taller than about 1.5 viewports. On Alt+A, walk() visits each section.
- **Root cause:** The finding holds; I found nothing that prevents it. At extension/src/content/extract.ts:323, isHidden calls `checkVisibility({ checkVisibilityCSS: true, contentVisibilityAuto: true })`.
- **Fix:** isHidden now calls checkVisibility({ checkVisibilityCSS: true }), which still treats content-visibility:hidden as hidden. contentVisibilityAuto was dropped. No twin on other platforms.
- **Test:** extension/tests/extract.test.mjs: 'J042: sections that content-visibility:auto skips off screen are still read'
- **Commit:** `af3c97d`

##### J044 · Medium · Extension

**When port 8000 is taken, the Aloud backend moves to 8001–8010 (native_app.py FALLBACK_PORTS).**

- **Where:** `extension/src/background/index.ts:232` (bad-ux)
- **Scenario:** A developer has Django's runserver (default port 8000) or 'python -m http.server' running, then launches Aloud, which binds 8001. The extension's /health goes to the other server, gets a 404 or non-JSON reply, and reports OFFLINE.
- **Root cause:** I couldn't refute it. When something else holds port 8000, backend/native_app.py (the legacy pywebview Aloud.app, or `python native_app.py`) quietly moves to 8001.
- **Fix:** shared/prefs.ts exports BACKEND_FALLBACK_PORTS (8001-8010). In the worker, if backendUrl is still the default and the default /health gives no OK JSON answer, health() probes the fallback ports in parallel.
- **Test:** extension/tests/background.test.mjs: 'J044: the fallback ports the worker looks on are the ones the backend moves to' (pins BACKEND_FALLBACK_PORTS to backend/native_app.py's FALLBACK_PORTS) and 'J044: with the default backend URL, a backend that moved to a fallback port is found and used'
- **Commit:** `af3c97d`

##### J045 · Medium · Extension

**Any Escape keydown that is not typed into a text field calls teardown().**

- **Where:** `extension/src/content/index.ts:485` (bad-ux)
- **Scenario:** The user is listening to sentence 140 of a long article when a newsletter <dialog> or cookie modal opens (focus moves to a button in it), or they zoom an image into a lightbox. They press Esc to close it.
- **Root cause:** The extension's only in-page key handler is a bubble-phase keydown listener on document. It returns early only when the key is not Escape, when no reading is active, or when focus is in an INPUT, TEXTAREA, SELECT or contenteditable element.
- **Fix:** The Escape listener moved from document to window, so a modal's own document listener (often added after ours) has already run. The reader ignores Escape when it was defaultPrevented, or when the target or activeElement is inside dialog[open], [aria-modal=true], [role=dialog|alertdialog|menu|listbox].
- **Test:** extension/tests/content.test.mjs: 'J045: an Escape the page uses to close its dialog or modal leaves the reading alone'
- **Commit:** `af3c97d`

##### J046 · Medium · Extension

**Extension twin of G016.**

- **Where:** `extension/src/content/index.ts:319` (bad-ux)
- **Scenario:** The user presses Alt+A while the backend is down. The reader halts with status 'error'.
- **Root cause:** I confirmed this by tracing the code. After a status-0 halt, the content script's `error` holds the player's message, 'Speech engine unreachable — is the Aloud backend running?'.
- **Fix:** New AloudPlayer.engineRecovered(): when the status is 'error' with exactly the unreachable-engine message, it sets the status to 'paused' and keeps the index. This ports the web reader's G016 fix. pollHealth calls it on every ok report, which also covers the immediate poll that follows an error.
- **Test:** extension/tests/player.test.mjs: 'J046: /health answering again clears an unreachable-engine stop to paused, on the same sentence'; extension/tests/content.test.mjs: 'J046: once /health answers again, the bar stops blaming an unreachable engine'
- **Commit:** `af3c97d`

##### J047 · Low · Extension

**The 'activate' message, meant for the popup only, is accepted from any sender, including content scripts running in web-page renderers, and acts on whatever msg.tabId it names.**

- **Where:** `extension/src/background/index.ts:424` (security)
- **Scenario:** A page where the reader was injected has its renderer compromised. It sends chrome.runtime.sendMessage({kind:'activate', tabId: <another tab>, action:'start'}). dispatch() runs executeScript and sends a command into any other tab where the extension has access (a localhost tab via host_permissions, or a tab with a live activeTab grant).
- **Root cause:** The finding is accurate, but it is defence in depth only. It can be triggered only from a compromised renderer: an attacker needs a Chrome renderer exploit in a tab where the reader was already injected.
- **Fix:** The worker's 'activate' case now accepts only messages from the extension's own popup: no sender.tab, sender.id equal to chrome.runtime.id, and a sender.url (without query or hash) equal to chrome.runtime.getURL('popup.html'). Any other sender gets {ok:false} and nothing is injected or sent.
- **Test:** extension/tests/background.test.mjs: 'J047: only the popup may activate a tab, not a content script in a page'
- **Commit:** `af3c97d`

#### Mac app

##### J022 · Medium · Mac

**A Force Click to look up a word also jumps playback to that sentence.**

- **Where:** `ios/AloudMac/Reader/ReaderColumnView.swift:1622` (bad-ux)
- **Scenario:** 1. Use a Force Touch trackpad with Look up set to 'Force Click with one finger' (the default).
- **Root cause:** I traced a concrete path, and nothing on it cancels the held play. ReaderNSTextView overrides mouseDown.
- **Fix:** ReaderNSTextView now overrides pressureChange(with:) and quickLook(with:). pressureChange reacts only to stage 2 or higher, because every click on a Force Touch trackpad sends stage 1. Both call the new onLookUpGesture callback.
- **Test:** AloudMacTests ReaderColumnViewTests.testAForceClickLooksUpWithoutPlaying; source pin AloudTests ReaderLintTests.testTheMacPageHearsLookUpNeverPressureAlone
- **Commit:** `baa6ed1`

##### J023 · Medium · Mac

**Once a book is finished (colophon shown), label() returns the colophon and playFromHere() returns false (line 269), even when the colophon is off screen.**

- **Where:** `ios/AloudMac/Reader/MacReaderAccessibility.swift:289` (broken-feature)
- **Scenario:** 1. Listen to a book to the end. isAtEnd is true, so MacReaderScreen passes a colophon and shownColophon is set.
- **Root cause:** On the Mac, coordinator.shownColophon is set for as long as playback.isAtEnd is true (MacReaderScreen.colophon(for:...) returns a colophon only on isAtEnd, and isAtEnd is listenerStatus == .ended). Nothing about scrolling clears it, and nothing checks whether the colophon is on screen. label() (MacReaderAccessibility.swift:289) and playFromHere() (lines 269-270) both test shownColophon before restingSentence(), so whenever no cursor is on screen they return the colophon and false, wherever the page is.
- **Fix:** New colophonOnScreen(): the colophon counts only while its cached follow rect (activeSentenceRect, which is the colophon's while it shows) is in the viewport, i.e. FollowBand.direction == nil. label() and playFromHere() use it, so a finished book scrolled back reads and plays the first sentence on screen.
- **Test:** AloudMacTests MacReaderAccessibilityTests.testScrolledBackFromTheColophonThePageIsTheLabelAgain
- **Commit:** `baa6ed1`

##### J025 · Medium · Mac

**Look Up on a long selection lays out the whole selection on the main thread. lookUpRange returns the full selection when the pointer is on it or off the text (offset nil → `?? true`...**

- **Where:** `ios/AloudMac/Reader/ReaderNSTextView.swift:195` (bad-ux)
- **Scenario:** 1. Open a very long book such as Pepys.
- **Root cause:** I could not refute this one. Every step in the path is reachable and has no guard.
- **Fix:** lookUpRange (now internal) takes the selection only up to ReaderNSTextView.lookUpSelectionLimit (256 UTF-16) and only when it has no newline. Otherwise it uses the word under the pointer, so with Cmd-A off the text Look Up is disabled. lookUpFromMenu measures the panel origin from NSRange(location: range.location, length: 1) and refuses an empty range.
- **Test:** AloudMacTests ReaderColumnViewTests.testLookUpTakesAPhraseNeverThePage
- **Commit:** `baa6ed1`

##### J026 · Medium · Mac

**On the Mac, a stop recorded while Aloud is not frontmost waits in pendingStopAnnouncement (PlaybackController.swift:1113 gates on NSApp.isActive).**

- **Where:** `ios/AloudMac/Library/MacRootView.swift:106` (bad-ux)
- **Scenario:** With VoiceOver on, play a book in Aloud and switch to another app. This is the usual Mac setup, and the window stays visible.
- **Root cause:** The Mac decides whether to hold a stop announcement by one signal and releases it by a different one. record() (ios/Aloud/Playback/PlaybackController.swift:1113) holds the announcement whenever isAppActive() is false. On the Mac that is PlatformApp.isActive = NSApp?.isActive (ios/Aloud/Platform/PlatformApp.swift:24-26), which only checks whether Aloud is the frontmost app.
- **Fix:** MacAppDelegate.applicationDidBecomeActive calls the new static announceHeldStop(of: AppModel.shared.playback). That runs playback.sceneDidBecomeActive() on the next main-queue turn, so A11yAnnounce reaches the main window.
- **Test:** AloudMacTests MacPlatformTests.testAStopHeldBehindAnotherAppIsSpokenWhenAloudComesForward (muted rig); source pin AloudTests ReaderLintTests.testTheMacAppSpeaksAHeldStopWhenItComesForward
- **Commit:** `baa6ed1`

##### J018 · Low · Mac

**With VoiceOver on the Mac, the Continue card offers a different list of actions from the grid cards: Open, Rename…, Mark as Finished and Delete…, against the grid's three actions under their iPhone names.**

- **Where:** `ios/AloudMac/Library/MacLibraryView.swift:214` (polish)
- **Scenario:** MacLibraryView.swift:214 passes MacDocumentMenu (Open, the menuTitle items, a Divider) as the hero's actions. ContinueListeningCard.swift:126 uses that same builder for both .accessibilityActions and .contextMenu.
- **Root cause:** I could not find anything that rules it out. On the Mac, the Continue card gets its VoiceOver actions from the same builder as its right-click menu.
- **Fix:** ContinueListeningCard<Actions, MenuItems> now takes separate actions: (VoiceOver) and menu: (context menu) builders. A convenience init where MenuItems == Actions keeps the iPhone call site unchanged.
- **Test:** LibraryLintTests.testTheMacContinueCardOffersTheGridCardsVoiceOverActions
- **Commit:** `fb1101a`

##### J028 · Low · Mac

**On the Mac, the disabled A− or A+ button at the 16 pt and 40 pt limits looks almost the same as the enabled one.**

- **Where:** `ios/AloudMac/Reader/MacTextAppearanceView.swift:83` (bad-ux)
- **Scenario:** stepButton uses MacGlyphButtonStyle, and MacGlyphFace (MacPlayerBar.swift:455-456) colors the glyph textFaint when disabled and textMuted at rest. Those two tokens are near-identical browns: 0x77694E vs 0x6A5B45 in light mode, 1.23:1 apart.
- **Root cause:** The Mac A−/A+ stepper (ios/AloudMac/Reader/MacTextAppearanceView.swift:83-84) uses MacGlyphButtonStyle and `.disabled(target == nil)`. MacGlyphFace (ios/AloudMac/Reader/MacPlayerBar.swift:455-456) draws `!isEnabled ?
- **Fix:** New MacTextStepButtonStyle in MacTextAppearanceView.swift, matching the iPhone stepper: Theme.text when enabled, Theme.textMuted while pressed, Theme.textFaint when disabled. The style draws the stepper's A- and A+ buttons.
- **Test:** AloudMacTests MacThemeTests.testTheTextSizeStepperShowsItsLimit (ImageRenderer, offline, contrast >= 2:1 in light and dark); source pin AloudTests ReaderLintTests.testTheMacTextSizeStepperUsesItsOwnGlyphStyle
- **Commit:** `baa6ed1`

##### J031 · Low · Mac

**File > Close (⌘W) is always enabled (line 98), and it calls NSApp.keyWindow?.performClose(nil) without checking the window.**

- **Where:** `ios/AloudMac/Commands/MacCommandActions.swift:148` (polish)
- **Scenario:** Library > right-click a card > Rename… (the alert sheet becomes the key window) > press ⌘W. You hear the system alert sound, and neither the alert nor the window closes.
- **Root cause:** File > Close is always enabled. MacCommandActions.isEnabled returns true for .closeWindow (line 98), and the root-alert guard does not hold it back because needsMainWindow(.closeWindow) is false.
- **Fix:** perform(.closeWindow) now goes through the static windowToClose(key:modal:). That returns nil, so perform returns false and the key is swallowed silently, when there is a modal window, no key window, a sheet, or a window with a sheet attached.
- **Test:** AloudMacTests MacCommandActionsTests.testCloseWindowClosesOnlyAWindowThatCloses
- **Commit:** `baa6ed1`

##### J034 · Low · Mac

**Whether Previous Chapter can restart the current chapter depends on playback.currentSentenceElapsed (lines 298-300), but MacCommandState.observe()...**

- **Where:** `ios/AloudMac/Commands/MacCommandActions.swift:298` (polish)
- **Scenario:** Open a book or page-listed PDF whose opening sentence is long. Play it from the start, wait more than 3 s while that first sentence is still being read, then press ⌘← or open the Playback menu.
- **Root cause:** The bug is real but small. The menu item and ⌘← both read a cached menu snapshot, and nothing updates that snapshot while a sentence plays.
- **Fix:** New MacCommandActions.secondsUntilChapterRestart: the time until Cmd-Left would restart the current step. It is nil unless playback is playing, the playhead is at a step start in a book with a chapter list, and less than restartThreshold has played.
- **Test:** AloudMacTests MacCommandActionsTests.testPreviousChapterComesOnThreeSecondsIntoTheFirstChapter (muted rig, 6 s clips, waits about 3 s)
- **Commit:** `baa6ed1`

#### Shared iPhone/Mac core and iPhone app

##### J004 · High · iPhone + Mac

**The G005 fix that keeps chapter openings from being stripped as running headers only knows English label words.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:426` (broken-feature)
- **Scenario:** Import a Russian, German, Spanish, French, Italian, Chinese or Korean PDF novel with short chapters (each 1 to 4 pages). Every chapter opens with 'Глава N' (or 'Kapitel N', '第N章', and so on) at the same sunk position, set apart by a gap. runningHeadersByPage collects these hits under the normalized key 'глава #'.
- **Root cause:** areChapterOpenings (ios/Aloud/Extraction/PDFTextExtractor.swift:421) only exempts a repeated edge line when it matches openingLabel at line 426. openingLabel lists English words only (chapter, day, letter, lesson, week, part, book, volume, section). normalizeRunning (line 384) still collapses localized numbered openings to one key: 'Глава 12' and 'ГЛАВА 12' become 'глава #', 'Kapitel 12' becomes 'kapitel #', and the same happens for Capítulo, Chapitre and Capitolo. '제12장' becomes '제#장'.
- **Fix:** areChapterOpenings now gets each number from a new openingNumber: the English openingLabel first, then the new HeadingChapters.localizedNumber, which returns chapterNumber only when the line whole-matches localizedHeading, so Han numerals work through cjkNumber. Both stripping rules (whole-book and per-page run) now exempt localized openings that are numbered afresh.
- **Test:** ios/AloudTests/PDFTextExtractorTests.swift: testLocalizedChapterOpeningsAreNeverRunningHeaders (covers Глава, ГЛАВА, Kapitel, Capítulo, Chapitre, Capitolo, 第n章, 제n장 and 第一章…第十二章, each with 2-page and 3-page chapters; also checks that a chapter's own 'Глава 3 Возвращение' header is still stripped) and testLocalizedShortChaptersKeepTheirHeadingsAndRows (end to end through ExtractionPipeline: all 12 'Глава n' headings are read aloud, chapterMap.source is .headings, 12 entries)
- **Commit:** `62a0e96`

##### J009 · High · iPhone + Mac

**Text books whose chapters are headed by bare arabic numerals ('1', '2', '3' on their own lines) get no chapters.**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:1193` (broken-feature)
- **Scenario:** Import a .txt manuscript exported from Word or Scrivener (a common layout): '1\n\nIt was a cold morning…\n\n…\n\n2\n\nThe train was late…'. For the paragraph '1', isChapterHeading returns false at line 1193 because '1' is not in "CBPAEIVXL", so extract() never increments page.
- **Root cause:** In TextExtractor.extract(), page goes up only when isChapterHeading(paragraph) is true. For "1", the month and EPILOGUE switch is skipped (no letters).
- **Fix:** TextExtractor.extract() has a new fallback that only runs when no marker heading split the book (page == 1). numberedChapterHeadings accepts one-line paragraphs of 1-3 ASCII digits, with an optional period, that rise 1, 2, 3... in a run of at least 3. Each must be followed by text: running text or a short sentence that is not Title Case, within the next 6 paragraphs and before the next numeral, where a title line may come first.
- **Test:** ExtractionChapterHeadingTests.testBareNumeralHeadingsStartChapters (the reported input gives 3 chapters titled Chapter 1/2/3), testBareNumeralChapterTitleLineMayFollowTheNumber, testStrayNumbersStartNoChapter, testNumeralsThatAreNotAChapterRunStartNoChapter (guard)
- **Commit:** `2c48af7`

##### J000 · Medium · iPhone + Mac

**A decade range written in short form ('1920s-30s', '1860s-70s') is passed to Kokoro unchanged, so espeak reads the raw digits.**

- **Where:** `ios/Aloud/TTS/SpokenYears.swift:275` (bad-ux)
- **Scenario:** A history book sentence 'The boom of the 1860s-70s ended.' is read with any natural voice. range() finds the dash and the digit and returns a group. Both suffixes are .s, so (b.length, a.suffix) == (2, .s).
- **Root cause:** In ios/Aloud/TTS/SpokenYears.swift, range() (lines 235-278) catches any year, dash and digit group. A short-form decade range such as "1920s-30s" gets past every guard: both ends have the .s suffix, a is 4 digits and in range, there is no chain, and rightOK passes.
- **Fix:** Added a (2, .s) case to SpokenYears.range(): it needs both ends to be round decades and the end to come later in the same century. '1920s-30s' is said 'nineteen twenties to thirties'.
- **Test:** SpokenYearsTests.testTable (new rows: 'the 1920s-30s', 'The boom of the 1860s-70s ended.', 'the 1920s - 30s', '...and 1950s', 'the 2000s-10s', plus untouched 1920s-20s / 1990s-00s / 1920s-35s) and SpokenYearsTests.testKokoroSpeaksAShortDecadeRange (hyphen and en dash through KokoroSherpaEngine.spokenText)
- **Commit:** `2c48af7`

##### J001 · Medium · iPhone + Mac

**When a later sentence fails to synthesize in the incoming voice of a primed handoff, the handoff is dropped with no check for incoming-voice clips already on the node.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:1578` (bad-ux)
- **Scenario:** Listening in the System voice when a natural voice finishes installing (or the thermal guard switches back to it). switchVoiceAtSentenceBoundary primes the splice at S = lastScheduled + 1. topUpSchedule synthesizes S in Kokoro and queues it. Sentence S+1 then fails all 3 synthesis attempts in Kokoro, for example a sentence the phonemizer can't handle.
- **Root cause:** Once the splice sentence S has been queued in the incoming voice, a failure on any later sentence in that voice runs the catch branch at PlaybackController.swift:1578. That branch sets `handoff = nil` and posts `.fellBackToSystem`, but never checks whether an incoming-voice clip is already on the node.
- **Fix:** In the topUpSchedule catch branch for the incoming voice, the code now posts .fellBackToSystem and then calls cancelVoiceHandoff() in place of `handoff = nil`. When a clip in the incoming voice is already on the node (lastScheduled >= splice), cancelVoiceHandoff() runs reloadCurrent(), and the top-up then returns because playToken changed.
- **Test:** VoiceHandoffTests.testAFailurePastAQueuedSpliceRestartsInTheSpeakingVoice. It uses a Michael engine that reads only the splice and fails every later sentence.
- **Commit:** `79d306c`

##### J002 · Medium · iPhone + Mac

**A speed change only retunes the time-pitch unit.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:73` (bad-ux)
- **Scenario:** Natural voice at 1x. The book sits cued with no schedule on the node: after the iPhone 60 s idle stop (stopIdleEngine calls cuePrefetch at tier x100), after a seek while paused, or after a sleep-timer stop.
- **Root cause:** The finding holds. On both apps, a speed change while the book sits cued with no schedule throws away the cue's warm-up.
- **Fix:** selectRate now re-warms the cue when !isActive and !hasActiveSchedule. It calls cuePrefetch(moved: true), or warms sentences 0-1 with replacingWarmUps when status is .ended, which matches load.
- **Test:** NativeSpeedTests.testASpeedPickWhileCuedWarmsTheCueAtTheNewPace. A Kokoro book is cued at sentence 3 and warmed at pace 1.0.
- **Commit:** `79d306c`

##### J005 · Medium · iPhone + Mac

**The one automatic restart for a resumed task whose Hugging Face link has expired only works inside the process that created the task.**

- **Where:** `ios/Aloud/TTS/ModelManager.swift:1113` (bad-ux)
- **Scenario:** R21 says a resumed file whose link has expired starts once more from scratch. That promise only holds while the process that created the task is still alive.
- **Root cause:** After a relaunch, the one restart that R21 promises (the F020 fix) can no longer happen. Whether a task was built from resume data is recorded only in memory: activeTaskResumed, and the resumed flag stored with each entry in queuedTasks.
- **Fix:** makeTask now records the resumed bit in the task's description ('model.onnx#resumed'). modelFileName strips the mark, so the coordinator callbacks and resume-data writes still see only the two known names. reattachIfNeeded matches tasks through modelFileName. finishReattach adopts the live task with track(task, resumedFromData: taskWasResumed(...)) and keeps the bit on queued tasks too. After a relaunch, a 403 from an expired link now restarts the file once from the pinned URL.
- **Test:** ios/AloudTests/ModelDownloadStateTests.swift: testAResumedTaskStillStartsOverAfterARelaunch (checks the description round trip and that the restart predicate fires on the bit read back) and testTheRelaunchAdoptsTasksWithTheirResumedBit (a source pin on finishReattach and makeTask; it fails on the old source, which has track(task) and (later, false))
- **Commit:** `ddf587a`

##### J006 · Medium · iPhone + Mac

**In a text book, any one-line paragraph that starts with the word Part, Book, Act, Chapter, Prologue or Epilogue is treated as a chapter heading and starts a new chapter.**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:1201` (broken-feature)
- **Scenario:** Import a .txt novel or nonfiction book. It has a short narration paragraph on a line of its own, such as 'Part of me wanted to stay.', 'Act natural, she said.', 'Book lovers never sleep.' or 'Chapter 5 shows how the engine works.' (no opening quote mark, under 80 characters, no newline). isChapterHeading takes the newlines == 0 branch, where headingRegex `^(?:…|Part|…|Act|…)\b` matches (confirmed with a probe). extract() at line 35 then increments page because headsText returns true for a single-line paragraph. derivedChapters / navigationIndex groups sentences by page, so the real chapter is split.
- **Root cause:** In isChapterHeading (TextExtractor.swift:1196-1202), the newlines == 0 branch only requires a line of 80 characters or fewer, no page-number tail, and a match for headingRegex. headingRegex is `^(?:CHAPTER|Chapter|BOOK|Book|PART|Part|ACT|Act|PROLOGUE|Prologue|EPILOGUE|Epilogue)\b|^[IVXLC]+\.?$`, so it matches any one-line paragraph that starts with one of those words as a whole word. Nothing else in that branch rules out prose: the numeral requirement, midSentenceRegex and isRunOnProse are only applied on the multi-line path.
- **Fix:** The one-line path in isChapterHeading now needs headingRegex (it keeps the word boundary after PROLOGUE/EPILOGUE) plus headingFirstLineRegex, no midSentenceRegex match and no isRunOnProse match. These are the rules the multi-line path already uses. runOnRegex now treats 'the' together with the word after it, so 'Chapter the last.' (Tom Jones) is still a heading instead of being dropped as the verifier warned.
- **Test:** ExtractionChapterHeadingTests.testSingleLineProseOpeningWithAMarkerWordIsNotAHeading and testSingleLineProseOpeningWithAMarkerWordStartsNoChapter (the reported CHAPTER I / 'Part of me wanted to stay.' / CHAPTER II input now gives 2 chapters)
- **Commit:** `2c48af7`

##### J008 · Medium · iPhone + Mac

**Extraction fixes never reach books that are already on the shelf, and adding the same file again can't fix them, because the sourceHash dedupe hands back the old broken record.**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:147` (broken-feature)
- **Scenario:** With an earlier build, the user added a GBK-encoded Chinese novel .txt. It was decoded as Latin-1 mojibake (F025/G021).
- **Root cause:** I could not find a guard or another way the scenario is avoided. Nothing in either app ever rebuilds a content cache once it is written, except a PDF's chapter map.
- **Fix:** Content caches now carry an extractor version stamp: DocContent.extractorVersion, set by writeContentCache to currentExtractorVersion = 1. A cache with no stamp counts as older.
- **Test:** SourceHashDedupeTests.testThePlaceIsCarriedAcrossByItsText, testTheSameFileAddedAgainGetsTheNewExtractionAndKeepsItsPlace, testAPlaceThatCantBeCarriedKeepsTheOldContent
- **Commit:** `df02964`

##### J011 · Medium · iPhone + Mac

**While library.json can't be read (isIndexReadable == false), every add fails, and the alert blames the file and tells the user to try again.**

- **Where:** `ios/Aloud/Import/ImportFailure.swift:64` (bad-ux)
- **Scenario:** A newer build (TestFlight) wrote library.json with a record this build can't decode, and the user goes back to the App Store build. The shelf shows the records that still decode.
- **Root cause:** The finding is real. When library.json holds a record this build can't decode, isIndexReadable is false for that launch and every launch after it.
- **Fix:** New ImportFailure.libraryUnreadable row: 'This book couldn't be added.' with Delete's next step, 'Aloud couldn't read your library, so it leaves it as it is. Update Aloud, then try again.' ImportFailure maps LibraryIndexError to it. importPDF and importText refuse with LibraryIndexError.unreadable after the sourceHash dedupe and before the copy or extraction, and addClassic goes through importText.
- **Test:** ImportFailureCopyTests.testAnUnreadableLibraryIsNeverTheFilesFault and the updated row table; ProgressIndexTests.testAnAddWhileTheIndexIsUnreadableFails (now expects .libraryUnreadable and a refusal before extraction)
- **Commit:** `df02964`

##### J012 · Medium · iPhone + Mac

**Rename and Mark as finished can fail without telling the user.**

- **Where:** `ios/Aloud/Library/LibraryView.swift:119` (broken-feature)
- **Scenario:** LibraryView.swift:119 (and MacLibraryView.swift:102) call store.rename, and LibraryView.swift:328 (and MacLibraryView.swift:345) call store.markFinished. Both write with `try? persistIndex()` (DocumentStore.swift:556 and :505), so the error is thrown away. persistIndex throws when the disk is full, and always throws when isIndexReadable is false (DocumentStore.swift:747).
- **Root cause:** DocumentStore.rename (DocumentStore.swift:552-557) and markFinished (:502-506) change `documents` in memory first, then call `try? persistIndex()`. When an unreadable library.json is kept, persistIndex always throws LibraryIndexError.unreadable (:747).
- **Fix:** DocumentStore.rename and markFinished now throw. They roll the record back through changeRecord when persistIndex fails.
- **Test:** ProgressIndexTests.testARenameOrMarkTheIndexCantRecordIsRolledBack, testARenameOrMarkFailureSaysWhyInFixedCopy, updated testAnUnreadableIndexIsNeverWrittenOver; ContinueListeningSelectionTests.testTheAppStampsAPlayAndTheShelfSaysWhyAnEditFailed (source pin for both views)
- **Commit:** `df02964`

##### J014 · Medium · iPhone

**At the accessibility text sizes, most of each Library card's top row does not respond to taps.**

- **Where:** `ios/Aloud/Library/DocumentCardView.swift:42` (bad-ux)
- **Scenario:** LibraryView.swift:244-249 wraps DocumentCardView in Button { open } with .buttonStyle(.plain). A plain button hit-tests only the label's drawn content.
- **Root cause:** The H014 fix (commit a803def) introduced this regression on the iPhone. At AX1-AX5, DocumentCardView.swift:42-44 pins the cover to 64x96.
- **Fix:** DocumentCardView's VStack now has .frame(maxWidth: .infinity, alignment: .leading) and .contentShape(Rectangle()) ahead of the combined element. The blank band beside the 64pt cover now takes taps and long-presses.
- **Test:** DocumentCardLayoutTests.testTheCardFillsItsColumnAtAccessibilitySizes (iOS-only); LibraryLintTests.testTheCardIsTappableAcrossItsCell
- **Commit:** `fb1101a`

##### J017 · Medium · iPhone + Mac

**Voice Control users can't open a book by saying its title.**

- **Where:** `ios/Aloud/Library/LibraryView.swift:251` (bad-ux)
- **Scenario:** Each grid card's only name is DocumentCardView.accessibilityLabel (DocumentCardView.swift:18,25-31): 'Title, Author, 1 hour 12 minutes left'. The Continue card's name is 'Continue listening, Title, Author' (ContinueListeningCard.swift:118).
- **Root cause:** Neither the shelf cards nor the Continue card sets accessibilityInputLabels on iPhone or Mac. Apple's SDK headers say that without input labels, Voice Control falls back to the accessibilityLabel.
- **Fix:** Added DocumentCardView.inputLabels(for:), which returns [title], and ContinueListeningCopy.inputLabels(title:), which returns [title, "Continue listening"]. They are applied to the iPhone grid Button (LibraryView), the Mac grid Button (MacLibraryCard) and the shared Continue card body.
- **Test:** ShelfAccessibilityTests.testVoiceControlAnswersToTheTitle (both apps); LibraryLintTests.testEveryCardAnswersVoiceControlByTitle
- **Commit:** `fb1101a`

##### J019 · Medium · iPhone + Mac

**In a PDF that has more than 25 pages and no outline, the VoiceOver rotor called "Pages" moves by Contents row groups, not by page.**

- **Where:** `ios/Aloud/Reader/ReaderRotor.swift:59` (broken-feature)
- **Scenario:** The rotor steps through `navigation.chapters` (ReaderRotor.swift:58-60, called from ReaderTextView.swift:1170 on iPhone and MacReaderAccessibility.swift:122 on Mac). For a page-range PDF, ReaderNavigation.init (ReaderNavigation.swift:179-189) sets `chapters` to `pageRows(index.chapters)`.
- **Root cause:** The bug is real, but it is less severe than reported. When a PDF has no usable chapter map and more than 25 page runs, `ReaderNavigation.chapters` holds the grouped rows (15 to 25 of them).
- **Fix:** ReaderNavigation.rotorSteps returns pageRuns when Contents groups pages, and chapters otherwise. ReaderRotor.target(.chapters) walks it, so the shared Pages rotor moves one page per flick on both apps.
- **Test:** ReaderRotorTests.testPagesRotorStepsOnePageWhereContentsGroupsPages (both apps)
- **Commit:** `fb1101a`

##### J021 · Medium · iPhone + Mac

**The chapter line's notice tier reads `playback.notice` without checking which book it belongs to.**

- **Where:** `ios/Aloud/Reader/PlayerBarView.swift:84` (bad-ux)
- **Scenario:** Book A has rested long enough for a resume rewind. The user presses Play, and A's line shows "Backed up 3 sentences" (or "Skipped a sentence the voice couldn't read" after a failed sentence).
- **Root cause:** `PlaybackController.load(document:content:)` (PlaybackController.swift:664-735) and `unload()` (749-767) reset the stop, Undo, the skipped sentences and the audition. Neither touches `notice` or `noticeTask`.
- **Fix:** Added a private clearNotice() that cancels noticeTask and sets notice = nil. load() calls it after the same-document early return and before invalidateSchedule, so a splice committed by that flush keeps its app-wide voice notice. unload() calls it as well. PlayerBarView.swift and MacPlayerBar.swift needed no change, because both read the shared controller's notice.
- **Test:** ResumeRewindTests.testABooksNoticeNeverCarriesToAnotherBook: A posts .backedUp(2); re-entering A (same id and hash) keeps it; loading B clears it, and B's autoplay posts nothing. ResumeRewindTests.testUnloadTakesTheNoticeDown checks the unload path.
- **Commit:** `79d306c`

##### J027 · Medium · iPhone

**With the iPhone's Bold Text setting on, the serif type styles stay at their normal weight.**

- **Where:** `ios/Aloud/Theme/AloudTheme.swift:148` (bad-ux)
- **Scenario:** Theme.font builds .display, .title, .headline and .aside from Font.custom(serifFamilyName, size:relativeTo:) (lines 148-150 and 158), and Theme.readerSerif uses Font.custom(_:fixedSize:) (line 166). Nothing in SwiftUI code reads legibilityWeight: the only Bold Text handling is in ReaderColumnText and ReaderTextView.
- **Root cause:** I could not refute it. On iPhone, every serif TypeStyle is built from Font.custom: .display and .title at AloudTheme.swift:148-149, .headline with .weight(.semibold) at :150, and .aside at :158.
- **Fix:** Fixed centrally in Theme.font, which covers all 20 serif call sites. Theme.font(_:boldText:) gives display, title and aside the family's bold face under Bold Text, and headline goes from semibold to bold.
- **Test:** DocumentCardLayoutTests.testTheSerifStylesTakeTheirBoldFaceUnderBoldText (iOS-only); PlatformSeamTests.testBoldTextIsTheSystemSetting; ReaderLintTests.testTheAaSampleFollowsBoldText
- **Commit:** `fb1101a`

##### J003 · Low · iPhone

**With no book open, the voice sample (speakSample) plays while status stays .idle. stop(because:) returns early at `guard isActive` (line 1055), so if AirPods or wired headphones go away mid-sample...**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:2190` (bad-ux)
- **Scenario:** 1) With no book loaded, open Settings > Listening with AirPods (or wired headphones) connected. 2) Tap a voice. selectVoice takes the no-content branch (line 1929), and speakSample schedules the sample line with status left at .idle.
- **Root cause:** I traced the bug and it is real. With no book open, the voice sample plays while status stays .idle.
- **Fix:** stop(because:) now runs `if content == nil { invalidateSchedule(); return }` before the isActive guard. That stops the node and bumps playToken, so a sample still warming or synthesizing never starts.
- **Test:** VoiceAuditionTests.testALostRouteCutsTheSampleWithNoBook: with no book and a 3 s sample heard, onRouteRequiresPause must emit .stopped, leave status .idle, record no stop and make no announcement. Also testALostRouteBeforeTheSampleIsMadeNeverStartsIt: route loss while a held sample is still being made means the sample is never scheduled.
- **Commit:** `79d306c`

##### J007 · Low · iPhone + Mac

**On a cellular or metered path, requestDownload always asks for confirmation, and the prompt always names the full download (DeviceCopy.meteredPrompt uses the static ModelManager.downloadSizeText, "353 MB").**

- **Where:** `ios/Aloud/TTS/ModelManager.swift:698` (bad-ux)
- **Scenario:** After F019, a cancelled or failed attempt keeps its verified staged files. When every file is staged, a Download on cellular installs with no network traffic at all: startTask only re-hashes the staged files and finalizes.
- **Root cause:** The finding holds. The metered prompt's size is a static string, and requestDownload never looks at staged files before it asks.
- **Fix:** Added static bytesLeftToFetch(stagedBytes:) and an instance version: before a run it is total minus staged, during a run it is the run's remaining progress, so the existing F023 and H006 tests are unchanged. requestDownload and answerPendingRequest now ask only when the path is costly and bytes are left to fetch. With every file staged they call startDownload(allowingCellular: false), which only hashes and installs, the same as the offline path.
- **Test:** ios/AloudTests/ModelVerificationTests.swift: testEveryFileStagedInstallsOnACostlyPathUnasked (fails before the fix: the old code returns .needsCellularConfirmation) and testTheMeteredPromptNamesOnlyWhatIsLeft (with model.onnx staged, the prompt says 28 MB, not 353 MB, on both the cellular and the metered wording). ios/AloudTests/NaturalVoiceCopyTests.swift: testTheCellularPromptNamesTheSizeLeft
- **Commit:** `ddf587a`

##### J010 · Low · iPhone + Mac

**A Delete that fails on a full disk throws away the kept book's extracted-content cache.**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:536` (data-loss)
- **Scenario:** The device is nearly full. The user tries to delete book X (added before this release, now half read).
- **Root cause:** The code does what the finding says. The scenario it uses mostly doesn't happen, but a narrower case does.
- **Fix:** delete() still frees the caches for its retry, but holds the content cache bytes in memory and writes them back if the retry also fails. A partial write-back is removed, and the book then re-extracts on open.
- **Test:** ProgressIndexTests.testADeleteTheIndexStillCantRecordKeepsTheBook (cache asserted kept) and testABookOpensWhenItsCacheCantBeWritten
- **Commit:** `df02964`

##### J020 · Low · iPhone

**The Library's 'Aloud' bar title has no Large Content Viewer.**

- **Where:** `ios/Aloud/Library/LibraryView.swift:77` (polish)
- **Scenario:** Settings (SettingsView.swift:59-64), Classics (BookshelfView.swift:68-74) and the other bar titles carry .accessibilityShowsLargeContentViewer(), with a comment that 'The bar caps text scaling; at accessibility sizes a long press shows the title large instead.' The Library's leading title at LibraryView.swift:77-83 has .fixedSize() and the header trait but no Large Content Viewer, while the gear and + beside it do have one (lines 180, 204).
- **Root cause:** I could not refute this. The Library's leading bar title is the only custom navigation-bar title on the iPhone without a Large Content Viewer. ios/Aloud/Library/LibraryView.swift:77-83 builds Text("Aloud") with Theme.font(.title) (Theme.font maps .title to .custom(serif, 22, relativeTo: .title2), so it is meant to scale), then .fixedSize(), .isHeader, magicTap and accessibilityHidden(importer.isImporting).
- **Fix:** Added .accessibilityShowsLargeContentViewer() to the leading 'Aloud' bar title in LibraryView, with the same comment the Settings title has. iPhone only: the Mac has no Large Content Viewer.
- **Test:** LibraryLintTests.testTheLibraryTitleOffersTheLargeContentViewer
- **Commit:** `fb1101a`

##### J024 · Low · iPhone + Mac

**A book counts as started only when progressFraction > 0.**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:458` (broken-feature)
- **Scenario:** Add or open a new book B whose first sentence is long. The opening sentence of A Tale of Two Cities is about 119 words, roughly 43 s at 165 wpm.
- **Root cause:** The mechanism is real. `positionFraction` returns `wordsBefore[0] / total`, which is exactly 0 for sentence 0.
- **Fix:** LibraryDocument gains firstPlayedAt: Date?, decoded with decodeIfPresent and writing no key while nil (outside my files, smallest change). AppModel.notePlayedBooks observes playback.$status == .playing and calls DocumentStore.notePlayed(id:), which stamps once and saves with the next debounced write. continueListeningCandidate counts a book as started when progressFraction > 0, when firstPlayedAt is set, or when stop?.documentID names it; the isAtItsEnd rule is unchanged.
- **Test:** ContinueListeningSelectionTests.testABookHeardInsideItsFirstSentenceIsStarted, testABookTheStopNamesIsStartedAtZero, testTheFirstPlayIsStampedOnce, plus source pin of AppModel.notePlayedBooks
- **Commit:** `df02964`

##### J029 · Low · iPhone

**At the accessibility text sizes, the Aa sheet's pinned 'Text & appearance' title has no side gutter or centered wrapping.**

- **Where:** `ios/Aloud/Reader/AppearanceSheet.swift:237` (polish)
- **Scenario:** The header VStack (lines 235-243) pads only the bottom. The title Text has no .padding(.horizontal) and no .multilineTextAlignment(.center), unlike everything below it, which uses the 24 pt sheetGutter.
- **Root cause:** The title in ios/Aloud/Reader/AppearanceSheet.swift (lines 235-243) has no horizontal padding, no .multilineTextAlignment(.center) and no .fixedSize. It sits in a center-aligned VStack that fills the sheet's full width.
- **Fix:** The pinned 'Text & appearance' title in AppearanceSheet now has .multilineTextAlignment(.center), .fixedSize(horizontal: false, vertical: true) and .padding(.horizontal, Theme.Space.sheetGutter), matching ListeningSheet. The lint pins both sheet titles. iPhone only.
- **Test:** ReaderLintTests.testTheSheetTitlesWrapCenteredInsideTheGutters
- **Commit:** `fb1101a`

##### J030 · Low · Mac

**The Mac app's Release and Archive builds can only be signed ad hoc, with no team. project.yml sets CODE_SIGN_IDENTITY "-" in the AloudMac target's base settings, so it covers Release...**

- **Where:** `ios/project.yml:131` (broken-feature)
- **Scenario:** 1) Archive the Mac app: Product > Archive on the AloudMac scheme, or `ios/xcb.sh -project ios/Aloud.xcodeproj -scheme AloudMac archive -archivePath …`. 2) In Organizer, choose Distribute App > App Store Connect, or Developer ID.
- **Root cause:** The facts hold, but the report overstates the impact. Every Mac Release build and archive is signed ad hoc with no team. ios/project.yml:130-131 sets CODE_SIGN_STYLE Manual and CODE_SIGN_IDENTITY "-" in the AloudMac base settings.
- **Status:** needs you. Release signing needs your Apple Developer team: set DEVELOPMENT_TEAM (and a distribution identity) for Release in ios/project.yml so archives can be uploaded; ad hoc signing stays for Debug and tests.

#### Tooling and release

##### J013 · Low · Tooling

**Override values are never type-checked, and lint() runs outside main()'s error handling (line 262).**

- **Where:** `tools/catalog_normalize.py:140` (broken-feature)
- **Scenario:** 1. A hand edit to tools/catalog_overrides.json sets a title to null or to a number (for example 1984).
- **Root cause:** The mechanics are real and I reproduced every case. I rated it low, not high.
- **Fix:** load_overrides raises ValueError when an override is not an object, or when its title or author is not a non-empty, non-blank string. main then exits 2 and sync_bookshelf.sh keeps the bundle. lint() now reports a non-string title or author, and an empty or whitespace-only title, as lint lines instead of raising a TypeError that the sync read as 'lint only' and shipped. sync_bookshelf.sh needed no change. tools/gutenberg_fetch.py was not touched.
- **Test:** tools/test_catalog_normalize.py: LintTests.test_null_numeric_and_blank_values_are_flagged_not_raised and OverridesTests (3 tests). tools/test_build_scripts.py: SyncBookshelfTests.test_override_values_that_are_not_titles_keep_the_bundle (null, 1984, empty and blank values for title and author). All 17 new failures/errors appear against the old normalizer; with the fix all 50 tests pass (python3 -m unittest tools.test_catalog_normalize tools.test_build_scripts)
- **Commit:** `ddf587a`

##### J015 · Low · Tooling

**Content is validated in run() only after fetch_text has returned the first URL that answered 200.**

- **Where:** `tools/gutenberg_fetch.py:291` (broken-feature)
- **Scenario:** 1. Queue a book whose gutenberg.pglaf.org/{mdir}/{id}-0.txt answers 200 with something that isn't the text.
- **Root cause:** The mechanism is real. fetch_text (tools/gutenberg_fetch.py:138-160) returns the body of the first URL that answers 200, as long as the byte count is complete. Content is only checked afterwards, in run() at lines 291-293, and a failed check runs `continue` to the next queue item.
- **Status:** deferred. tools/gutenberg_fetch.py is being edited in another session.

##### J016 · Low · Tooling

**Each failed download attempt is logged by exception class only ('URLError on …', 'HTTPError on …').**

- **Where:** `tools/gutenberg_fetch.py:160` (polish)
- **Scenario:** Run the scheduled fetch with a Python whose root certificates are not installed (for example a python.org install where 'Install Certificates' was never run), or while DNS is failing. Every pattern raises URLError, and the log shows '(URLError on https://gutenberg.pglaf.org/…)' five times per book, then 'all mirrors failed'.
- **Root cause:** In tools/gutenberg_fetch.py, fetch_text has one catch-all handler, `except (OSError, http.client.HTTPException) as err:`, at lines 156-161. It prints only `f" ({type(err).__name__} on {url})"` (line 160) and then tries the next pattern.
- **Status:** deferred. tools/gutenberg_fetch.py is being edited in another session.

#### Web app

##### J035 · High · Web app

**buildLines groups every text piece on the page by baseline alone, across the full page width.**

- **Where:** `frontend/src/lib/pdf.ts:144` (broken-feature)
- **Scenario:** Open almost any two-column paper or magazine PDF (an arXiv, IEEE or ACM paper, for example). Every page is displayed and read as 'left line 1, right line 1, left line 2, right line 2…', so sentences from the two columns are mixed together.
- **Root cause:** buildLines (frontend/src/lib/pdf.ts:139-170) sorts every piece on the page by y, then x, and clusters only on baseline distance (tol = max(2, 0.5*h)). It never looks at x for anything except the order within a line. pdf.js content-stream order is thrown away by that full-page sort, and loadPdf (pdf.ts:315-334) passes the raw pieces straight in.
- **Fix:** I moved the page geometry (Piece, buildLines, joinPiecesOnLine) out of pdf.ts into a new pdf.js-free module, frontend/src/lib/pdfStitch.ts, so node tests can reach it. readingOrderLines looks for a gutter: a channel at least 0.6em wide in the middle 60% of the text that two in three rows leave empty, with prose on both sides. Prose means each side has at least 3 rows, spans at least a quarter of the text width, has a median line fill of 0.6 or more and a median of 12 or more characters per line.
- **Test:** frontend/tests/pdfStitch.test.ts: 'J035: a two-column page reads the left column, then the right' (aligned and offset baselines), 'J035: a title, a header and a centred folio stay where they are around the columns', 'J035: a caption set across both columns splits the page into bands...', and two regression guards: 'J035/J037: a single-column page is grouped into lines exactly as before' (deepEqual to buildLines plus explicit texts) and 'J035: a contents page ... still reads row by row'
- **Commit:** `132ea20`

##### J037 · High · Web app

**Each text item's position is taken from transform[4]/[5] only.**

- **Where:** `frontend/src/lib/pdf.ts:328` (broken-feature)
- **Scenario:** Open a vertically typeset Japanese PDF (a common layout for novels, and the app ships Japanese voices and the vertical Adobe CMaps). All columns start at the same top y, so they fall into one 'line', which is sorted by x ascending.
- **Root cause:** I confirmed this with the real pdf.js 4.10.38 (frontend/node_modules) on a PDF I built, not only with hand-made inputs. frontend/src/lib/pdf.ts:328-336 copies only transform[4]/[5], item.width and item.height into a Piece. It never reads content.styles[fontName].vertical or transform[0..3], and nothing in frontend/src handles vertical or rotated text.
- **Fix:** pdf.ts now builds each piece with pieceOf(item, content.styles[item.fontName]?.vertical). The angle comes from atan2(b, a), and a vertical font is a further quarter turn clockwise, with pdf.js's width and height swapped so that w is the extent and h is the size. readingOrderLines groups pieces by direction.
- **Test:** frontend/tests/pdfStitch.test.ts: 'J037: vertical Japanese reads column by column from the right' (inputs shaped like pdf.js output: transform [10,0,0,10,x,700], width = size, height = column length; includes a column split into two runs and a level folio after the columns), 'J037: a landscape page reads its sideways lines in order' (transform [0,10,-10,0,x,y], with one indented line), 'J037: a sideways stamp in the margin no longer splices into a body line', 'J037: pieceOf keeps a level run as it was'
- **Commit:** `132ea20`

##### J036 · Medium · Web app

**The player listens only for 'ended', 'loadedmetadata' and 'error' on its Audio element.**

- **Where:** `frontend/src/lib/player.ts:150` (broken-feature)
- **Scenario:** In Chrome on a Mac, play a sentence longer than about 5 s and press the keyboard's ⏯ key (or Pause in Chrome's media hub, or the AirPods button). The audio stops, but the bar still shows Pause and the status stays 'playing'.
- **Root cause:** In frontend/src/lib/player.ts, ensureAudio (lines 141-160) listens only for 'ended', 'loadedmetadata' and 'error'. There is no navigator.mediaSession code anywhere in frontend/src or extension/src. wantPlaying, store status and the rAF word loop change only in the player's own methods: play (626), pause (665), playIndex (403) and onEnded (573).
- **Fix:** In player.ts, ensureAudio now registers navigator.mediaSession handlers for play, pause, nexttrack and previoustrack. They do nothing when no document is open or while status is 'loading', which matches the keyboard.
- **Test:** frontend/tests/player.test.ts: 'J036: the ⏯ key and the browser media controls go through the player', 'J036: a pause from outside the player shows as paused, and one press plays again', 'J036: a resume from outside the player plays on into the next sentence', 'J036: an outside resume while a dropped PDF parses keeps the book held' (all four fail on 8afe220), plus a guard test 'J036: the player's own pauses and a clip running out are not taken for outside ones'
- **Commit:** `167bf6b`

##### J038 · Medium · Web app

**To hold the open book while a dropped PDF parses, openPdf calls player.pause() and then sets status 'loading'. pause() does not invalidate a synthesis that is still pending...**

- **Where:** `frontend/src/lib/intake.ts:46` (bad-ux)
- **Scenario:** Book A is open. Click a sentence that is not cached (status 'buffering'), and within that second drop a large PDF B on the window.
- **Root cause:** Ts and intake.ts. When status is 'buffering', openPdf (intake.ts:45-47) calls player.pause(). pause() (player.ts:665-671) clears wantPlaying, pauses the element and sets 'paused', but it does not bump playToken. openPdf then sets 'loading' (intake.ts:52). playIndex is still waiting on entry.promise (player.ts:426), and its token still matches, so it carries on when the request settles: - The clip arrives: it sets audio.src and loadedIndex, sees !wantPlaying and sets status 'paused' (player.ts:478-480). - The backend answers 400: skip() leads to advanceFrom, which sets 'paused' (player.ts:564-567).
- **Fix:** player.pause() now increments playToken, so the pending playIndex continuation stops. It used to set 'paused' when the clip landed, skip the sentence and set 'paused' on a 400, or set the offline error.
- **Test:** frontend/tests/player.test.ts: 'J038: a sentence still buffering when a PDF is dropped leaves the loading view up', 'J038: an unreadable buffering sentence is not skipped over the loading view', 'J038: the engine going down while a sentence buffers does not replace the loading view' (all three fail on 8afe220; they drive the real player and the real openPdf with held synth answers), plus a guard test 'J038: Play after a pause while buffering plays the clip that landed, without asking again'
- **Commit:** `167bf6b`

##### J040 · Medium · Web app

**stripNoise drops any line among the first two or last two lines of a page that consists only of digits (1-4) or roman-numeral letters, whatever its size or position.**

- **Where:** `frontend/src/lib/pdfHeaders.ts:158` (bad-ux)
- **Scenario:** Open a novel whose chapters open with a bare numeral or roman-numeral heading ('7', 'IV', or a title such as '1984'). On every chapter-opening page the heading is the first text line, so it is removed.
- **Root cause:** The bug is real. In frontend/src/lib/pdfHeaders.ts:158, stripNoise drops any line among a page's first two or last two lines when isPageNumberLine matches it. isPageNumberLine (line 34) accepts 1 to 4 digits or any string of 1 to 7 letters from ivxlcdm.
- **Fix:** New in pdfHeaders.ts: romanValue (well-formed roman numerals only, as in Swift's ChapterText.isRomanNumeral) and folioLines(pageLines), which returns each page's folio line indices. stripNoise now takes those indices as a required third argument: stripNoise(lines, running, folios). pdf.ts passes folioLines(pageLines)[idx], and I updated the existing F003/G014 tests to pass folios. The roman rule is a straight port of H047 romanFolioLines: a roman numeral is a folio only if a page up to two away has a numeral at the same height that counts on by the page distance.
- **Test:** frontend/tests/pdfHeaders.test.ts: 'J040: a bare numeral heading a chapter, set larger than the text, stays' ('IV', '7', '1984', 'II'; folios and running heads still go), 'J040: a roman numeral is a folio only when it counts on with the pages (H047)', 'J040: a word spelled with roman letters is not a numeral' ('Did', 'vivid', 'Mid', 'Civic', 'mild'), 'J040: digit folios still go at the head of one page and the foot of the next, or alone' (regression guard)
- **Commit:** `132ea20`

##### J041 · Medium · Web app

**Screen-reader users get no feedback when they open a PDF.**

- **Where:** `frontend/src/App.tsx:151` (bad-ux)
- **Scenario:** With VoiceOver or NVDA, Tab to 'Drop a PDF here or click to browse', press Enter and choose a file. Nothing is spoken while it parses and nothing when it is ready; focus is on <body>.
- **Root cause:** The web reader never tells a screen-reader user that a PDF is being prepared or that it has opened, and it doesn't move focus anywhere when it is ready. App.tsx:151-157 shows one of three views: the LoadingView while status is 'loading', the Reader once a document is open, and the Dropzone otherwise. openPdf (frontend/src/lib/intake.ts:52) calls setStatus('loading') straight away inside the file input's onChange.
- **Fix:** IntakeDeps gains an optional announce(message). openPdf announces 'Preparing <file>…' when loading starts and 'Opened <title>, N page(s)' once the PDF opens (exported openedMessage). It announces '' on a failed parse, because the ErrorBanner alert already explains it; a stale (abandoned) parse announces nothing.
- **Test:** frontend/tests/intake.test.ts: 'J041: opening a PDF says it is being prepared, then that it opened', 'J041: a PDF that cannot be read clears the announcement; the error banner says why', 'J041: a parse abandoned with New announces nothing more'. frontend/tests/appWiring.test.ts: 'J041: opening a PDF is announced from a live region that stays mounted', 'J041: the reader takes the focus the loading view dropped, on its title'. All five fail on 8afe220.
- **Commit:** `167bf6b`

##### J043 · Low · Web app

**The sentence being read is marked only by data-active and the 'is-active' class.**

- **Where:** `frontend/src/components/Reader.tsx:161` (polish)
- **Scenario:** While audio plays, a screen-reader user Tabs into the reader and presses ↓/↑ to browse. Every sentence is announced the same way ('<text>, button'), so they cannot find the sentence being read without leaving the reader and Tabbing back in.
- **Root cause:** Screen readers get no state for the sentence being read, and I found nothing that makes up for it. In frontend/src/components/Reader.tsx:157-167, each sentence is a `<span role="button">`.
- **Fix:** Added aria-current={active ? 'true' : undefined} next to data-active on the Reader's sentence span.
- **Test:** frontend/tests/appWiring.test.ts: 'J043: the sentence being read is marked current for assistive technology' (source pin; fails on 8afe220)
- **Commit:** `167bf6b`

### Loop 5: wave 5 re-review of the loop-4 fixes

#### Backend

##### K010 · Low · Backend

**The J032 fix now rejoins a hyphenated word only when the gap holds a line break.**

- **Where:** `backend/text_normalize.py:193` (broken-feature)
- **Scenario:** With the extension, read a hard-wrapped plain-text document (Chrome shows it as <pre>, made readable by F010) that has 'inter-' at a line end and 'national' on the next line. The extension sends 'inter- national'.
- **Root cause:** The regression is real, and nothing in the client guards against it. On the extension path, hard-wrapped text loses its newlines before it reaches the backend. extract.ts:447 builds each sentence's `text` as raw.replace(/\s+/g,' ').trim().
- **Fix:** The rejoin is done in the extension, which kept it simple. In buildSentences, plain mode only (text/plain or lone-<pre> pages via extractPage, and extractText for frame selections), rejoinWrapped(raw) runs before whitespace collapses.
- **Test:** extension/tests/extract.test.mjs: 'K010: a word hard-wrapped plain text split at a line end is read whole' (fails on f38beac: 'inter- national', 'mer- chants')
- **Commit:** `1f380bd`

#### Browser extension

##### K001 · Medium · Extension

**The J044 fix only checks the fallback ports when the default port gives no JSON at all.**

- **Where:** `extension/src/background/index.ts:270` (broken-feature)
- **Scenario:** The user runs another FastAPI/uvicorn app on 8000, uvicorn's default port, with a /health route. native_app.py sees 8000 is taken and not ours (its probe needs engine 'kokoro'), so it serves on 8001. The extension still has the default backend URL. locate() gets {status:'ok'} from 8000, so d is not null and the fallback scan never runs.
- **Root cause:** I could not refute it. In locate() (extension/src/background/index.ts:263-279), the fallback scan runs only when `!d`. readHealth() returns null only when the reply is not 2xx, the body is not JSON, or the request fails.
- **Fix:** locate() counts the default port only when /health has engine === 'kokoro' (new isAloud helper, the same rule native_app.py's probe uses). Otherwise it scans the fallback ports.
- **Test:** extension/tests/background.test.mjs: 'K001: another server answering /health on the default port is not taken for the backend' (fails on f38beac: the other server was taken for the backend)
- **Commit:** `1f380bd`

##### K004 · Medium · Extension

**Every health poll sets located = null before it rescans the fallback ports, and Promise.all waits for the slowest of the ten probes (up to the 5 s PROBE_TIMEOUT).**

- **Where:** `extension/src/background/index.ts:267` (broken-feature)
- **Scenario:** Aloud runs on 8001 because 8000 is taken, and one of 8002-8010 is held by a process that answers slowly or not at all (for example a dev server suspended with Ctrl-Z, whose socket still accepts connections). While the user reads, the content script polls /health (every 30 s, or every 4 s while buffering).
- **Root cause:** The race is real, and loop 4 introduced it in the J044 fix (af3c97d). I found nothing that guards against it.
- **Fix:** locate() no longer sets located = null before scanning. It assigns located once, when the scan ends (found?.base ?? null), so synthesis during a rescan still goes to the last port found. findOnFallbackPorts starts all probes together and reads them in port order, so the first kokoro answer settles the scan without waiting for a slower port above it.
- **Test:** extension/tests/background.test.mjs: 'K004: a rescan neither sends synthesis to the default port nor waits on a slow port above the backend' (fails on f38beac: synthesis went to http://127.0.0.1:8000/synthesize)
- **Commit:** `1f380bd`

##### K005 · Medium · Extension

**The J036 twin was missed.**

- **Where:** `extension/src/content/player.ts:295` (bad-ux)
- **Scenario:** While the extension is reading an article, press the keyboard's play/pause key or the pause button in Chrome's global media controls. The element pauses, but the bar still shows 'playing' (Pause button) and the highlight freezes.
- **Root cause:** This is the J036 gap still present in the extension. In extension/src/content/player.ts, ensureAudio (lines 287-303) registers only 'ended', 'error' and 'loadedmetadata' on the clip.
- **Fix:** Ported from the web reader's J036 change. navigator.mediaSession play/pause/nexttrack/previoustrack are routed to play()/pause()/next()/prev() through holdMediaKeys(), which setStatus drives. They are registered only while the status is playing or buffering, and set back to null on any other status: pause, ended, error, and idle on stop()/teardown.
- **Test:** extension/tests/player.test.mjs: 'K005: the media keys go through the reader only while it reads, then back to the page' (fails on f38beac: no play handler)
- **Commit:** `1f380bd`

##### K007 · Medium · Extension

**The J036 twin was named but not done.**

- **Where:** `extension/src/content/player.ts:295` (bad-ux)
- **Scenario:** The user reads a long article with the extension, and the sentences are long enough for Chrome to make the page's media session controllable. They press ⏯ (F8) or Pause in Chrome's toolbar media controls.
- **Root cause:** In extension/src/content/player.ts, ensureAudio (lines 285-305) puts only 'ended', 'error' and 'loadedmetadata' listeners on the clip. Nothing in extension/src uses navigator.mediaSession or listens for 'pause' or 'play'.
- **Fix:** Same root cause as K005. ensureAudio adds 'pause' and 'play' listeners, on the <audio> element only, since WebAudioClip fires neither. onElementPaused calls pause() only when wantPlaying is set, the element is paused and not ended, and loadedIndex === index. onElementPlayed takes over in place: wantPlaying, status playing, startFilling, word loop. If the clip is stale (loadedIndex !== index), it pauses the clip and restarts through play().
- **Test:** extension/tests/player.test.mjs: 'K007: a pause from outside the reader shows as paused, and one press plays again', 'K007: a resume from outside the reader plays on into the next sentence' (both fail on f38beac), plus the guard test 'K007: the reader's own pauses and a clip running out are not taken for outside ones'
- **Commit:** `1f380bd`

##### K009 · Medium · Extension

**The J045 'is a modal still open' check calls checkVisibility() with no options.**

- **Where:** `extension/src/content/index.ts:512` (bad-ux)
- **Scenario:** Many sites keep a cart or menu drawer, or a modal, in the DOM while it is closed, with aria-modal="true". They hide it with visibility:hidden and/or opacity:0 so it can fade.
- **Root cause:** Loop-4 commit af3c97d added a check that treats any [aria-modal="true"] element as an open modal unless checkVisibility() returns false. That call passes no options.
- **Fix:** escapeIsThePages now calls checkVisibility with MODAL_SHOWN = { checkVisibilityCSS, visibilityProperty, checkOpacity, opacityProperty }, covering both option spellings. A closed drawer or modal kept in the DOM with visibility:hidden or opacity:0 no longer counts as open. aria-hidden/inert modals are not handled separately.
- **Test:** extension/tests/content.test.mjs: 'J045/K009: an Escape the page uses...' now has modal stubs that report visible unless asked about visibility or opacity (fails on f38beac: a modal hidden by visibility or opacity kept Escape from stopping the reading)
- **Commit:** `1f380bd`

##### K011 · Low · Extension

**WebAudioClip.currentTime is built from AudioContext.currentTime, which is the render clock and runs ahead of what is heard by outputLatency (plus baseLatency).**

- **Where:** `extension/src/content/webaudio.ts:117` (polish)
- **Scenario:** The user reads on a strict-CSP page such as a github.com README, so the reader has switched to Web Audio, and listens through Bluetooth headphones (AirPods), where Chrome's outputLatency is about 0.1-0.25 s. The highlight lights each word that much before it is spoken, about one word ahead at 1.5x-2x.
- **Root cause:** The defect is real. The getter at extension/src/content/webaudio.ts:117 computes `offset + (ctx.currentTime - startedAt) * rate`.
- **Fix:** Following the verifier's caveat, the latency correction is a separate accessor. WebAudioClip.heardTime subtracts (outputLatency + baseLatency) from the elapsed context time before scaling by rate.
- **Test:** extension/tests/player.test.mjs: 'K011: through Web Audio, the word lit is the one heard, not the one rendered' (fails on f38beac: the highlight ran ahead of the voice). It also pins pause resuming from the render clock.
- **Commit:** `1f380bd`

#### Mac app

##### K025 · Low · Mac

**Any stage-2 pressure event is treated as a Look Up, but Force Click only does Look Up when System Settings > Trackpad > Look up & data detectors is set to 'Force Click with one finger'.**

- **Where:** `ios/AloudMac/Reader/ReaderNSTextView.swift:144` (bad-ux)
- **Scenario:** 1. In System Settings > Trackpad, leave 'Force Click and haptic feedback' on and set Look up to 'Tap with three fingers'.
- **Root cause:** I couldn't refute it. The path in the code is concrete, and loop 4 introduced it in commit baa6ed1 as the J022 fix.
- **Fix:** I removed the pressureChange override from ReaderNSTextView, so a stage-2 pressure event no longer counts as Look Up. Only quickLook(with:) marks the click now.
- **Test:** ReaderLintTests.testTheMacPageHearsLookUpNeverPressureAlone (which replaced the J022 pin that required a pressure override): no pressureChange override and no event.stage check remain, and quickLook(with:) still marks the click.
- **Commit:** `2863684`

##### K027 · Low · Mac

**The J031 fixer named this follow-up and did not do it: File > Close (Cmd-W) stays enabled when Aloud has no key window, for example after the main window is closed or minimized while a book plays.**

- **Where:** `ios/AloudMac/Commands/MacCommandActions.swift:98` (polish)
- **Scenario:** 1. Play a book.
- **Root cause:** File > Close is always enabled, and with no key window choosing it, or pressing Cmd-W, silently does nothing. This is not new.
- **Fix:** MacCommandActions has a new seam: var windows: @MainActor () -> (key, modal), defaulting to NSApp.keyWindow and NSApp.modalWindow. isEnabled(.closeWindow) returns closableWindow != nil, and perform(.closeWindow) uses the same helper. MacCommandState.observe also refreshes on NSWindow.didBecomeKeyNotification and didResignKeyNotification.
- **Test:** ios/AloudMacTests/MacCommandActionsTests.swift testCloseIsOffWithNoWindowToClose. With no key window, Close is disabled, perform returns false and the MacCommandState snapshot is disabled.
- **Commit:** `2863684`

#### Shared iPhone/Mac core and iPhone app

##### K003 · Medium · iPhone + Mac

**The new numbered-chapter fallback (J009) only runs when no marker heading split the book (`page == 1`).**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:41` (broken-feature)
- **Scenario:** The user imports a .txt novel laid out '1', text, '2', text … '5', text, then 'EPILOGUE', text. The EPILOGUE line passes isChapterHeading, so page becomes 2 and the numbered pass is skipped.
- **Root cause:** The defect is real, but it is a gap in the J009 fix, not a regression. TextExtractor.extract() (ios/Aloud/Extraction/TextExtractor.swift:40-48) runs numberedChapterHeadings only when `page == 1`, meaning no marker heading split the book.
- **Fix:** extract() now records every marker heading, including one at index 0, and runs numberedChapterHeadings when at most one of them is not named matter. A new isNamedMatter/namedMatterRegex matches PROLOGUE/Prologue/EPILOGUE/Epilogue, optionally after FIRST/SECOND/THIRD/FOURTH/FINAL/LAST.
- **Test:** ios/AloudTests/ExtractionChapterHeadingTests.swift testBareNumeralChaptersStandBesideNamedMatterAndOneStrayMarker
- **Commit:** `94a4627`

##### K008 · Medium · iPhone + Mac

**A follow-up named in the J037 web fix was not done.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:155` (broken-feature)
- **Scenario:** Ran macOS PDFKit (same as iOS) on the web fixer's probe.pdf. On page 3 (/Rotate 90, text set with Tm 0 1 -1 0), selectionsByLine returns 'It was the brightest…', 'the dullest of eve…', 'small things.', 'It was the season…', 'season of light.'.
- **Root cause:** I could not refute this. `lines(of:)` (ios/Aloud/Extraction/PDFTextExtractor.swift:136-156) still builds each Line from `lineSelection.bounds(for: page)` in unrotated page space and returns `lines.sorted { $0.y > $1.y }` with y = bounds.maxY.
- **Fix:** New readingFrame(_:box:rotation:) used by lines(of:). On a page with /Rotate 90 or 270 whose lines are mostly taller than wide (weighted by text length), each line's bounds are mapped into the displayed frame before y, minX and maxX are taken.
- **Test:** PDFTextExtractorTests.testQuarterTurnedPagesReadTheirLinesInOrder
- **Commit:** `8ff2c86`

##### K012 · Medium · iPhone + Mac

**The new column split always reads the left column first.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:171` (broken-feature)
- **Scenario:** An Arabic two-column journal page with columns at x 72-290 and 310-528. gutter() finds 306.5, and columnRuns emits [across, left, right]. The reader hears column 2, then column 1, on every page.
- **Root cause:** The defect is real, but its impact is narrow. columnRuns (ios/Aloud/Extraction/PDFTextExtractor.swift:165-182) always emits each band as [left, right]: `runs += [left, right]` at line 171 and `runs += [across, left, right]` at line 181. Nothing in the extractor checks text direction.
- **Fix:** New readsRightToLeft(_:) counts letters: Hebrew and Arabic blocks 0590-08FF, FB1D-FDFF, FE70-FEFF and the SMP right-to-left ranges, against all other letters. On a right-to-left page, columnRuns emits each band as [right, left]. gutter()'s isColumn takes the column margin at maxX on such a page, so a flush-right, ragged-left column is still a column.
- **Test:** PDFTextExtractorTests.testRightToLeftColumnsReadRightColumnFirst
- **Commit:** `8ff2c86`

##### K014 · Medium · iPhone + Mac

**The extractorVersion stamp only refreshes a book when the same file comes through importPDF/importText. addClassic returns a Bookshelf classic already linked by gutenbergID before importText runs...**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:245` (bad-ux)
- **Scenario:** A user added 'The Secret of Chimneys' (65238) from the Bookshelf before this build. Its cache is unstamped and holds one page (no chapters).
- **Root cause:** I found no guard and no other way to refresh. Only importPDF (DocumentStore.swift:95) and importText (:157) call refreshingExtraction, the only place a stale cache is re-extracted. content(for:) never re-extracts a cached text book: needsChapterMap applies only to PDFs. addClassic (:244-247) returns the record that document(forGutenbergID:) finds before it reaches importText.
- **Fix:** Same defect as K021. When addClassic finds a record already linked by gutenbergID, it now returns try await refreshingExtraction(of: existing, progress: nil) instead of returning the record.
- **Test:** SourceHashDedupeTests.testAClassicTappedAgainGetsTheNewExtraction
- **Commit:** `cc52ff8`

##### K016 · Medium · iPhone + Mac

**On a real two-column page, one line that crosses the gutter is treated as a full-width line and breaks the page into bands.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:178` (bad-ux)
- **Scenario:** Made a 2-column PDF (Courier 9pt, 10pt gap like LaTeX article) with one left line overfull by 3 characters. In PDFKit it spans x 72-304, and the right column starts at 298. gutter() returns 296.5, and the replica of the real columnRuns gives runs L0-L8, R0-R8, L9, L10-L19, R9-R19.
- **Root cause:** I could not refute this, and real PDFKit output reproduces it. columnRuns (PDFTextExtractor.swift:168-182) treats any line with minX < gutter && maxX > gutter as spanning the page. It then flushes the left and right runs gathered so far and starts a new band.
- **Fix:** New straddlers(_:gutter:) finds a gutter-crossing line that has column lines above and below it on both sides, within 2.5 line heights. lines(of:) re-reads a straddler that PDFKit merged (nothing beside it at its height) as two halves, using page.selection(for:) on rects split at the gutter. It keeps the line whole unless both halves hold text. columnRuns keeps any remaining straddler in its band, on the side lines open from, so it no longer breaks the page into bands.
- **Test:** PDFTextExtractorTests.testALineCrossingTheGutterInsideTheColumnsKeepsThemWhole + testAnAddressRunIntoTheGutterReadsInItsColumn
- **Commit:** `8ff2c86`

##### K018 · Medium · iPhone + Mac

**In the new numbered-chapter fallback, any later run that restarts at 1 discards every chapter already found.**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:1298` (broken-feature)
- **Scenario:** A novel laid out '1', text … '5', text, then 'NOTES' with notes '1' 'See the letter of March…', '2' …, '3' …. The notes' '1' opens text and value == 1 with found.count == 5, so the function returns [].
- **Root cause:** The report is real. In numberedChapterHeadings (ios/Aloud/Extraction/TextExtractor.swift:1294-1302), any numeral 1 that opens text after a run has started returns [] at once (line 1298 `} else if value == 1 {`, line 1299 `return []`).
- **Fix:** numberedChapterHeadings now collects runs: each 1 starts a run, and a number joins the latest run it continues. It keeps the first run (3 or more) when the text from the first restart after that run's last heading to the end is under a quarter of the words the run heads.
- **Test:** ios/AloudTests/ExtractionChapterHeadingTests.swift testBackMatterNumberedFromOneKeepsTheChapters
- **Commit:** `94a4627`

##### K019 · Medium · iPhone + Mac

**Some single-column pages have a two-column block at the foot, such as footnotes set in two columns or a two-column list.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:178` (bad-ux)
- **Scenario:** Ran a replica of the real gutter/columnRuns on 4 body paragraphs (full-width lines, short last lines ending at x 260) over 5 rows of two-column footnotes. gutter is 314.35, and the runs are [B0.0-B0.3], [B0.short], [B1.0-B1.3], [B1.short], …, [B3.short, FL0-FL4], [FR0-FR4]. Each 'B*.short' that starts uppercase becomes a separate block, so the reader shows an extra paragraph and TTS pauses mid-paragraph.
- **Root cause:** I could not refute it. columnRuns (new in loop 4, commit a173792) puts any line with maxX <= gutter into the left run, even when it sits alone between lines that span the gutter. So when a page has a gutter (a two-column block anywhere on it), each spanning paragraph whose short last line ends before the gutter has that last line cut off into its own run. paragraphs(from:) folds that run on its own. appendPageParagraphs then rejoins it only if it starts lowercase or with a digit (or one of the CJK, caseless-script or hyphen cases).
- **Fix:** columnRuns keeps a line in the spanning run when it is on the opening side, stops short of the gutter by more than a line height, sits within two line heights under the last spanning line, and has no line across the gutter beside it. A body paragraph's short last line over two-column notes, or an abstract's last line, therefore stays in its paragraph.
- **Test:** PDFTextExtractorTests.testShortLastLinesOverTwoColumnNotesStayWithTheirParagraphs
- **Commit:** `8ff2c86`

##### K020 · Medium · iPhone+Mac (shared core)

**Re-adding a file now gives the book a new contentHash (refreshingExtraction sets refreshed.contentHash = fresh.contentHash).**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:488` (data-loss)
- **Scenario:** 1) A half-read PDF has several 'Where you stopped' entries, and its content cache was written by a build before the extractor stamp (every existing book). 2) Open the same PDF again from Files, or with ⌘O on the Mac.
- **Root cause:** I could not refute it. Loop 4 (df02964) changed importPDF and importText.
- **Fix:** Added a DocumentStore.didReplaceContent callback (@MainActor async). refreshingExtraction awaits it after a successful commit, before returning, so the reader opens with the places already carried. AppModel.carryPlaces (static, called from observePlaceHistory) wires it to the new PlaceHistoryStore.carry. carry maps each entry off the main actor with the new DocumentStore.carriedSentences, which uses carriedPlace's matching with both texts' letters worked out once and falls back to the entry's stored excerpt.
- **Test:** PlaceHistoryStoreTests.testCarryMovesThePlacesToTheNewExtraction; SourceHashDedupeTests.testTheSameFileAddedAgainKeepsItsPlaceHistory
- **Commit:** `cc52ff8`

##### K021 · Medium · iPhone+Mac (shared core)

**addClassic returns the linked record before it ever reaches importText, so a bundled classic on the shelf is never re-extracted.**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:245` (broken-feature)
- **Scenario:** 1) Add a classic in an earlier build and listen partway. 2) Update Aloud.
- **Root cause:** I could not refute it. DocumentStore.addClassic (ios/Aloud/Library/DocumentStore.swift:244-247) returns the record found by document(forGutenbergID:) without any further work.
- **Fix:** Same fix as K014 (DocumentStore.addClassic sends a linked record through refreshingExtraction).
- **Test:** SourceHashDedupeTests.testAClassicTappedAgainGetsTheNewExtraction
- **Commit:** `cc52ff8`

##### K022 · Medium · iPhone+Mac (shared core)

**backfillChapters writes the old cached text plus a chapter map back to the cache.**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:424` (data-loss)
- **Scenario:** 1) A shelved PDF has an old cache that needs a chapter map. 2) Open the same file again from Files; the refresh extraction runs.
- **Root cause:** The race is real. The overwrite and the progress reset follow from the code as written.
- **Fix:** backfillChapters now encodes off the main actor and writes on it. It writes only if the per-book cacheWrites count is unchanged; the count goes up with each refresh cache write (both the equal-hash path and a commit) and with the decline stamp.
- **Test:** SourceHashDedupeTests.testAChapterBackfillNeverWritesOverANewerCache
- **Commit:** `cc52ff8`

##### K023 · Low · iPhone+Mac (shared core)

**A refresh that is declined still costs a full extraction every time, because nothing records the outcome.**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:474` (bad-ux)
- **Scenario:** 1) A mid-book PDF whose old extraction differs enough that its place's text can't be found (the doc's own example: a decoding fix that changes every letter), or that the new extractor now rejects. 2) Open it from Files: a long 'Adding…' overlay, then the old text.
- **Root cause:** The defect is real, but only a narrow set of books hits it. In refreshingExtraction (DocumentStore.swift:445-500), a cache counts as stale when `(cached.extractorVersion ??
- **Fix:** A refresh declined because the new extraction throws (other than cancellation), or because the first carriedPlace returns nil, now calls keepingOldExtraction. It re-reads the cache so a backfilled chapter map is kept, then stamps the old content with the current extractor version, so later re-adds return immediately.
- **Test:** SourceHashDedupeTests.testARefreshDeclinedForGoodIsNotTriedAgain
- **Commit:** `cc52ff8`

##### K024 · Low · iPhone and Mac (MacLibraryView.swift:355)

**Mark as finished still calls continuePlayback.letGo, which unloads the player, before the now-throwing store.markFinished.**

- **Where:** `ios/Aloud/Library/LibraryView.swift:340` (bad-ux)
- **Scenario:** 1) The disk is full, or library.json was written by a newer Aloud. 2) While the Continue card's book is playing, long-press it (or right-click on the Mac) and choose Mark as finished.
- **Root cause:** The path is real and happens every time in one state. When library.json can't be read (for example, a newer build wrote it), isIndexReadable is false, persistIndex always throws, and the shelf still shows the records that decode, so those books can play.
- **Fix:** In iPhone LibraryView.perform and Mac MacLibraryView.perform, `try store.markFinished` now runs first. On failure it shows EditFailure and returns, leaving playback alone.
- **Test:** ContinuePlaybackTests.testMarkAsFinishedAndDeleteLetGoOnceTheStoreChanged (renamed from testMarkAsFinishedAndDeleteLetGoOnceTheStoreChanged)
- **Commit:** `cc52ff8`

##### K026 · Low · iPhone and Mac (shared ModelManager)

**J007 now starts a Wi-Fi-only run without asking when every file is already staged on a costly path. setInFlight then puts that run in .waitingForWiFi and announces 'Download paused · waiting for Wi...**

- **Where:** `ios/Aloud/TTS/ModelManager.swift:722` (bad-ux)
- **Scenario:** 1) Both model files are staged at their exact pinned size, but the voice is not installed. This happens when the last file finished in the background while Aloud was gone, a cancel or failure came during the final hash, or finalizeInstall failed.
- **Root cause:** The defect is real and was introduced by the J007 fix, but it is narrow and clears itself. With both files staged at their pinned size, a tap on Download over a costly path now skips the prompt (needsMeteredConfirmation is false because bytesLeftToFetch is 0) and calls startDownload(allowingCellular: false).
- **Fix:** setInFlight now turns a computed .waitingForWiFi into .downloading(progress) when stagedBytes >= totalExpectedBytes. The check runs only when the next state would be waiting, so progress callbacks never stat the disk.
- **Test:** ios/AloudTests/ModelVerificationTests.swift testARunThatOnlyHashesNeverWaits. It stages both files and checks four runs: costly cellular, costly Wi-Fi (the Mac's case), offline Wi-Fi-only, and offline with cellular allowed.
- **Commit:** `2863684`

#### Web app

##### K000 · Medium · Web app

**On a two-column page, a running-head or folio row is only kept whole when it crosses the gutter or sits more than 2.5 line-gaps from the body.**

- **Where:** `frontend/src/lib/pdfStitch.ts:173` (broken-feature)
- **Scenario:** Open a two-column journal PDF whose header ('Journal of Things' on the left, folio '17' at the top right) sits 2 line-gaps above the text, which is common. Before loop 4 the header row was line 0 and was stripped.
- **Root cause:** I could not refute it. In columnLines (frontend/src/lib/pdfStitch.ts:156-185), a top or bottom row is kept whole only when it crosses the gutter or when its gap to the body is more than 2.5 times the median row gap (`head`/`foot` via `apart`).
- **Fix:** New pdfStitch.readingOrderPages(pages: Piece[][]) builds each page's y-ordered rows (buildLines order; for mixed directions each group's rows stacked like its lines), runs runningHeadersByPage, folioLines and stripNoise on those rows, then reruns readingOrderLines on the kept rows' pieces. This mirrors PDFTextExtractor.swift, which strips before columnRuns. pdf.ts now collects each page's pieces in pass 1 and calls readingOrderPages; pass 2 only folds paragraphs and stitches.
- **Test:** frontend/tests/pdfStitch.test.ts: 'K000: a running head and folio by a two-column body go before the columns are read' (4 pages, header row 24pt above two columns with head left and folio right; and a folio at the foot under the left column)
- **Commit:** `d88706f`

##### K002 · Medium · Web app

**The J040 size guard compares a digit folio with the median line height of its own page (bodySized = height <= 1.2 x median).**

- **Where:** `frontend/src/lib/pdfHeaders.ts:84` (broken-feature)
- **Scenario:** Open a thesis or report PDF that has a page of 8pt code listing, a footnotesize table, an index or a figure with small captions, with a 10pt folio at the foot like every other page. 10 > 1.2 x 8, so folio '17' is read aloud at the end of that page, and it can be glued onto the last paragraph.
- **Root cause:** The defect is real, and loop 4 introduced it. In frontend/src/lib/pdfHeaders.ts:84, folioLines measures `bodySized` against the median line height of the folio's own page (`line.height <= size * 1.2`).
- **Fix:** folioLines now measures bodySized against the median line height of the whole document, not the folio's own page. The rule is otherwise unchanged (bodySized && (countsOn || lone && outermost)).
- **Test:** frontend/tests/pdfHeaders.test.ts: 'K002: a folio on a page set in small type still goes' (pages 16-18, page 17 in 8pt with a 10pt counting-on folio; also checks that a 24pt chapter '7' on that page stays)
- **Commit:** `d88706f`

##### K006 · Medium · Web app

**This is the named follow-up from the backend fixer, and it is still not done. appendLine removes a line-end hyphen before any lowercase line and never checks for the and/or/nor followers.**

- **Where:** `frontend/src/lib/pdfHeaders.ts:277` (broken-feature)
- **Scenario:** In a PDF whose line ends with 'short-' and whose next line begins 'and long-term effects', the web reader shows and speaks 'shortand long-term effects'. The same happens to 'two-'/'or three-day' ('twoor') and across page breaks through appendPageParagraphs.
- **Root cause:** frontend/src/lib/pdfHeaders.ts:275 appendLine has one test: a letter followed by a hyphen at the end of the buffer, and a lowercase letter at the start of the next line. When both hold it drops the hyphen and fuses the words.
- **Fix:** appendLine skips de-hyphenation when the buffer ends in U+002D and the next line starts with and/or/nor followed by a non-letter. The result keeps the hyphen and the space: 'short- and long-term'.
- **Test:** frontend/tests/pdfStitch.test.ts: 'K006: a hyphen wrapped before and, or, nor is a suspended one and stays' (short-/and, two-/or, pre-/nor, across a page break through appendPageParagraphs; reorder, orange and a soft hyphen still rejoin)
- **Commit:** `d88706f`

##### K013 · Medium · Web app

**The J036 media-session 'play' handler calls play() unconditionally, and navigator.mediaSession.playbackState is never set.**

- **Where:** `frontend/src/lib/player.ts:184` (bad-ux)
- **Scenario:** While reading, press → or click a far sentence. During the 'buffering' wait, press the keyboard play/pause key to pause.
- **Root cause:** Nothing in frontend/src sets navigator.mediaSession.playbackState. The 'play' handler at player.ts:182 is remote(() => this.play()), and its only guards are "no document" and status 'loading'.
- **Fix:** In player.ts, attachMediaSession now sets navigator.mediaSession.playbackState from the store when it attaches, and subscribes to status changes. playing and buffering map to 'playing', idle to 'none', and every other status to 'paused'. The mapping is in an exported mediaPlaybackState().
- **Test:** frontend/tests/player.test.ts 'K013: the media session hears a buffering sentence as playing, so the ⏯ key pauses it'. It uses the muted fake Audio and a held /synthesize.
- **Commit:** `3d37055`

##### K015 · Medium · Web app

**The J037 fix puts a sideways margin stamp as its own paragraph after the page's last line.**

- **Where:** `frontend/src/lib/pdfStitch.ts:77` (bad-ux)
- **Scenario:** Open any arXiv PDF whose page 1 ends mid-sentence. You hear '...the model achieves' / 'arXiv 2101.00001v1 cs CL 1 Jan 2021 state of the art results...'.
- **Root cause:** I reproduced this with the real repo code. The J037 change in readingOrderLines (frontend/src/lib/pdfStitch.ts:70-86) sorts direction groups by amount of text.
- **Fix:** readingOrderLines (and pageRows) now stack direction groups with the main group unshifted and read last. Every other group sits a paragraph gap above it, so its y stays in its own frame and running-head and folio heights stay comparable across pages.
- **Test:** frontend/tests/pdfStitch.test.ts: 'J037/K015: a sideways stamp in the margin reads before the page, as its own paragraph' (stamp first, a paragraph gap above the body, the page's last line is the body tail and the next page stitches onto it). The J037 vertical-Japanese test now expects the level folio before the columns.
- **Commit:** `d88706f`

##### K017 · Medium · Web app

**The J041 follow-up the fixer named is not done.**

- **Where:** `frontend/src/App.tsx:90` (bad-ux)
- **Scenario:** With a book open, a keyboard or VoiceOver user activates 'New'. Focus is lost to the body, nothing is announced, and the user has to hunt for the 'choose a PDF' control.
- **Root cause:** Nothing restores focus or announces anything after the header 'New' button. The J041 fixer said in audit-full3-fixes.json that this path was left out ('Not covered: after the header 'New' button, focus still falls to body when the Dropzone mounts').
- **Fix:** handleReset in App.tsx reads the open doc before reset(), then announces closedMessage(doc) through the existing polite live region. Text: 'Closed <title>'.
- **Test:** Three tests fail on f38beac and pass now: appWiring.test.ts 'K017: New says the book closed and hands its focus to the drop target' and 'K017: the drop target takes focus the reset button dropped, once, as it mounts' (source pins; there is no DOM library to render with), and intake.test.ts 'K017: New says which book it closed, as opening says which one opened' (a runtime test of closedMessage). The J041 pin on handleReset now also accepts the close announcement.
- **Commit:** `3d37055`

### Loop 5: full review wave 4

#### Backend

##### L032 · High · Backend

**Japanese voices are phonemized with espeak-ng 'ja', which has no kanji support.**

- **Where:** `backend/voices.py:31` (broken-feature)
- **Scenario:** In the web reader or the extension, pick a Japanese voice (jf_*/jm_*, listed as 'Japanese' in VoicePicker) and read ordinary Japanese text. Measured with the venv tokenizer: '吾輩は猫である、名前はまだ無い…' (69 characters) phonemizes to 842 phonemes such as '(en)tʃˈaɪniːz(ja)lˈetə (en)tʃˈaɪniːz(ja)lˈetə hˈ …', which is one 'chinese letter' per kanji.
- **Root cause:** The finding is confirmed, and Japanese is in worse shape than reported. All 5 Japanese voices are installed and offered: models/voices-v1.0.bin holds jf_alpha, jf_gongitsune, jf_nezumi, jf_tebukuro and jm_kumo. voices.py maps their 'j' prefix to 'ja', and the VoicePicker and the extension's voices.ts label them 'Japanese'.
- **Fix:** The backend venv has no Japanese G2P (no misaki, pyopenjtalk or fugashi in the freeze). voices.voice_is_speakable now keeps 'ja' voices out of the engine's voice set. They are not in /voices, and a saved jf_* id falls back to the default voice like any unknown id, so espeak 'ja' never runs.
- **Test:** backend/tests/test_phoneme_batches.py: EngineTests.test_japanese_voices_are_not_offered, test_a_japanese_voice_is_never_phonemized_as_japanese, test_mandarin_reaches_the_model_respelled; RespellTests (real espeak cmn output strings captured from the venv tokenizer); backend/tests/test_text_normalize.py: IdeographicPunctuationTests
- **Commit:** `ee8c430`

##### L031 · Medium · Backend

**normalize_for_tts runs plain NFKC on every chunk, which turns vulgar fractions and superscripts into different numbers.**

- **Where:** `backend/text_normalize.py:238` (broken-feature)
- **Scenario:** With the extension, read a recipe or measurement page. The extension sends the text without NFKC, so the backend's NFKC is what changes it.
- **Root cause:** The finding holds. backend/text_normalize.py:238 runs a plain unicodedata.normalize("NFKC", text) on every /synthesize request, with no exception for fractions or superscripts. The only caller is KokoroEngine.synthesize (backend/kokoro_engine.py:125), which every /synthesize request reaches (backend/app.py:318 calls engine.synthesize), and nothing before it guards against this.
- **Fix:** I ported the iOS compatibilityFolded/keepsCompatibilityForm rule to normalize_for_tts. U+00B2, U+00B3, U+00B9, U+00BC-00BE, U+2070-207F, U+2150-215F and U+2189 now skip NFKC.
- **Test:** backend/tests/test_text_normalize.py: CompatibilityFormTests (fractions and superscripts kept; ligatures and fullwidth letters still folded)
- **Commit:** `ee8c430`

##### L034 · Medium · Backend

**The F050 bound is incomplete.**

- **Where:** `backend/app.py:350` (security)
- **Scenario:** Measured: 'ﷺ' (U+FDFA) expands under NFKC to 18 characters and phonemizes to 66 phonemes per input character, where normal text gives about 1.7. A request with 2,000 of them is 6 KB and passes the 2,000-character check.
- **Root cause:** I could not refute it. The F050 bound is incomplete. backend/app.py:350 checks len(req.text) (code points) before anything else runs.
- **Fix:** phoneme_batches.MAX_PHONEMES = 6000, with check_length raising TooLongError (a ValueError subclass) after phonemize and before any create(). app.py maps it to 413 with retryable=false. SynthQueue tracks the in-flight job and exposes in_flight_cancelled(). app._synthesize passes it as should_stop to engine.synthesize, which checks it between split_for_model pieces and raises JobCancelledError.
- **Test:** backend/tests/test_phoneme_batches.py: LengthTests, EngineTests.test_text_that_phonemizes_too_long_never_reaches_the_model, test_a_job_told_to_stop_skips_the_rest, test_a_job_never_told_to_stop_runs_in_full; backend/tests/test_app_requests.py: PhonemeBoundTests (413 not retryable; worker passes should_stop); backend/tests/test_synth_queue_cancel.py: test_in_flight_job_is_told_its_client_left, test_a_live_in_flight_job_is_not_cancelled
- **Commit:** `ee8c430`

##### L037 · Low · Backend

**A chunk that contains a lone UTF-16 surrogate crashes the espeak phonemizer with UnicodeEncodeError.**

- **Where:** `backend/kokoro_engine.py:139` (bad-ux)
- **Scenario:** Both chunkers hard-cut at start+350 UTF-16 units when a stretch has no space or ASCII clause break (frontend/src/lib/chunker.ts:166, extension/src/shared/chunker.ts:159). Chinese text has no spaces, and '，' followed by no space does not match /[,;:)—–]\s+/, so its cuts are almost always hard.
- **Root cause:** I traced the whole chain and reproduced each step. Two parts of the report are wrong or overstated.
- **Fix:** normalize_for_tts removes U+D800-DFFF before NFKC. The safety-net fallback also uses the stripped text.
- **Test:** backend/tests/test_text_normalize.py: SurrogateTests; backend/tests/test_phoneme_batches.py: EngineTests.test_text_left_empty_by_normalization_is_refused
- **Commit:** `ee8c430`

##### L038 · Low · Backend

**Every startup failure of the native window only logs to stderr and returns 1.**

- **Where:** `backend/native_app.py:300` (bad-ux)
- **Scenario:** legacy/build_web_app.sh checks only the venv and native_app.py; it never checks for or downloads backend/models. On a checkout where run.sh has never run, build Aloud.app and double-click it. _start_own_server does 'from app import app', kokoro_engine raises FileNotFoundError('Kokoro model not found'), and that is caught at line 191, logged, and returns None. main() then returns 1 at line 301.
- **Root cause:** The finding is real. Every startup failure in backend/native_app.py is only written to stderr, and stderr is the only place the logging setup writes. main() then returns 1 before `import webview` ever runs, so no window opens.
- **Fix:** native_app._tell_user logs the message. When the app was launched without a terminal (macOS, not headless, stderr not a TTY), it also runs `osascript display alert`, passing the message as an argv item.
- **Test:** backend/tests/test_launchers.py: NativeStartupAlertTests (missing model names download_models.py; other import failure, taken port and health timeout are shown; no alert from a terminal; message passed as an osascript argument, never spliced into the script), NativeLaunchKindTests
- **Commit:** `ee8c430`

##### L042 · Low · Backend

**The H063 fix is incomplete.**

- **Where:** `backend/requirements.txt:4` (security)
- **Scenario:** I checked the installed metadata. fastapi 0.141.1 requires 'starlette>=0.46.0' and 'pydantic>=2.9.0'. kokoro-onnx 0.5.0 requires 'onnxruntime>=1.20.1', 'phonemizer-fork>=3.3.2' and 'espeakng-loader>=0.2.4'. uvicorn[standard] adds httptools, uvloop, websockets and others, all unpinned. A fresh `uv pip install -r requirements.txt` resolves the newest Starlette, phonemizer and onnxruntime of the day, not the versions the backend tests ran against (starlette 1.6.0, onnxruntime 1.29.0, phonemizer-fork 3.3.2 in backend/.venv).
- **Root cause:** The H063 fix pinned only the six top-level lines. Its own finding also named every transitive package (starlette, pydantic, onnxruntime, phonemizer-fork…), and those were left floating.
- **Fix:** New backend/constraints.txt holds `uv pip freeze --offline` of the backend venv: all 59 installed distributions, at their tested versions. requirements.txt starts with `-c constraints.txt` and now declares anyio==4.14.2, which app.py imports directly. The pins don't carry hashes yet.
- **Test:** backend/tests/test_launchers.py: ModelDownloadTests.test_requirements_apply_the_constraints, test_every_dependency_is_pinned_to_the_tested_version (walks installed metadata from requirements.txt with markers and extras, and asserts each reachable distribution is pinned at its installed version), test_backend_requirements_are_pinned (now ignores option lines)
- **Commit:** `ee8c430`

#### Browser extension

##### L040 · Medium · Extension

**The backend URL only makes sense on one computer, but it is saved in chrome.storage.sync along with the other prefs, so it follows the user to every Chrome where they are signed in.**

- **Where:** `extension/src/shared/prefs.ts:98` (broken-feature)
- **Scenario:** On the laptop, port 8000 is taken by a dev server, so the user enters http://127.0.0.1:8123 in the popup's Backend field (popup.ts:215-217 → savePrefs → sync.set). On the desktop (same profile, Sync on), the Aloud backend runs on 8000, or on 8001 after a port clash.
- **Root cause:** The code does what the report says. Nothing guards it, but it only happens in one narrow setup. prefs.ts keeps the whole Prefs object, backendUrl included, under one key (aloud.prefs.v1). savePrefs writes it to chrome.storage.sync (line 98) and loadPrefs reads sync first (line 81).
- **Fix:** backendUrl now lives under its own key, aloud.backendUrl.v1, in chrome.storage.local. The synced aloud.prefs.v1 object no longer carries it.
- **Test:** extension/tests/background.test.mjs 'L040: the backend URL stays on the computer it was set on; the other settings sync'. Two fake computers share one sync store.
- **Commit:** `fb0c3d5`

##### L043 · Medium · Extension

**sanitize() accepts any http(s) origin as backendUrl, and the service worker POSTs every sentence's text to it (background/index.ts:405).**

- **Where:** `extension/src/shared/prefs.ts:71` (security)
- **Scenario:** The user activates Aloud on a hostile page, and that page's renderer is compromised (the J047 threat model). It runs chrome.storage.sync.set({'aloud.prefs.v1': {...prefs, backendUrl: 'https://collector.example'}}). sanitize keeps the URL because it matches /^https?:\/\//.
- **Root cause:** I confirmed this under the threat model J047 already accepted: a compromised page renderer that is hosting Aloud's content script. An ordinary hostile page cannot trigger it.
- **Fix:** prefs.ts has a new exported onThisComputer(url). It accepts http and https on 127.0.0.1, localhost or [::1] with no username or password, and sanitizeBackend sends anything else back to the default. The worker checks it again before every fetch. The backend serves only 127.0.0.1 and refuses a [::1] Host, so in practice only 127.0.0.1 and localhost reach it.
- **Test:** extension/tests/background.test.mjs: 'L043: a backend URL off this computer is refused, and no request leaves it' and 'L043: every request the worker makes is checked against this computer first'. The I018 row for my-mac.local now expects the default.
- **Commit:** `fb0c3d5`

##### L045 · Medium · Extension

**The bar fetches the voice list only inside start(), and only once.**

- **Where:** `extension/src/content/index.ts:273` (bad-ux)
- **Scenario:** The user presses Alt+A before starting the backend, and the bar says 'Speech engine offline'. They start the backend.
- **Root cause:** The content script assigns `voices` in one place only, inside start() (extension/src/content/index.ts:273-278), and only when the list is empty. With the backend down, the background worker's voices() (extension/src/background/index.ts:335-346) returns { voices: [] }, so the list stays [].
- **Fix:** content/index.ts has a new loadVoices(). It skips when voices are already loaded, and a voicesPending flag stops a second request while one is in flight. start() calls it, and so does pollHealth whenever state is ok.
- **Test:** extension/tests/content.test.mjs: 'L045: a bar first painted with no voices still offers the default voice' (PlayerBar on stubDom) and 'L045: voices missed while the engine was down are fetched once it answers' (booted reader; health goes offline then ok; counts voice requests, expects exactly one more). Both fail pre-fix.
- **Commit:** `fb0c3d5`

##### L047 · Low · Extension

**H033 made the bar ignore events dispatched by page scripts, but the reader's document-level handlers still act on them.**

- **Where:** `extension/src/content/index.ts:531` (security)
- **Scenario:** A site that wants to block read-aloud, or ordinary page code, runs document.dispatchEvent(new Event('aloud:takeover')) or window.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'})). The bar disappears and the reading position is lost.
- **Root cause:** The finding is real: page scripts can stop the reader or move it. The security framing is overstated, though.
- **Fix:** The click-to-jump and window Escape handlers return early when !e.isTrusted, and the takeover listener tears down only when !extensionAlive(). Still open: the window 'pagehide' listener (content/index.ts) tears down on any event, so page code that dispatches a fake pagehide still stops the reader (see Known follow-ups).
- **Test:** extension/tests/content.test.mjs 'L047: events a page dispatches neither stop the reader nor move it'. It covers an untrusted takeover, an untrusted Escape and an untrusted click; trusted click and Escape still work.
- **Commit:** `fb0c3d5`

#### Mac app

##### L007 · Medium · Mac

**When several files are added at once, a failure never says which file failed.**

- **Where:** `ios/AloudMac/Library/MacAddMenu.swift:153` (bad-ux)
- **Scenario:** admit() keeps one value: `firstFailure = firstFailure ?? Self.failure(...)` (line 153).
- **Root cause:** The finding is confirmed. Every link in the reported chain is in the code, and no guard breaks it.
- **Fix:** MacFileIntake now queues every copy failure of a batch, plus a later batch's failure that arrives while an alert is up (pendingFailures). dismissFailure shows the next one. Each queued failure keeps its file's name when its batch had more than one file.
- **Test:** MacImportTests.testEveryFailedCopyOfABatchIsShownByName and testTheImportersFailureInABatchNamesItsFile; ImportFailureCopyTests.testABatchFailureNamesItsFile
- **Commit:** `8ee9533`

##### L014 · Medium · Mac

**On the Mac, Rename and Mark as Finished have no menu-bar item or shortcut.**

- **Where:** `ios/AloudMac/Library/MacLibraryCard.swift:40` (bad-ux)
- **Scenario:** A card offers Rename… and Mark as Finished only through .contextMenu (right-click or Control-click) and .accessibilityActions (VoiceOver). focusedValue publishes only \.macDeleteBook (line 40, and the hero at MacLibraryView.swift:241). AloudCommands adds only item(.deleteBook) to the Edit menu (AloudCommands.swift:52).
- **Root cause:** With plain macOS Keyboard navigation and no VoiceOver, a user can Tab to a Library card and open it (Return or Space) or delete it (Edit > Delete Book…, ⌘⌫). Nothing they can press reaches Rename… or Mark as Finished.
- **Fix:** Added MacCommand.renameBook and .markFinished to the one table: Edit menu, no key, copy-table titles 'Rename Book…' and 'Mark as Finished', help names. They are published as new macRenameBook / macMarkFinished focused values by a single macBookCommands(for:perform:) helper that both the grid card and the Continue hero apply.
- **Test:** MacCommandActionsTests.testEditsBookItemsActOnTheFocusedCard (Mac); LibraryLintTests.testTheFocusedMacCardOffersEditsBookItems (source pin, iOS suite)
- **Commit:** `82d6097`

##### L021 · Medium · Mac

**The selection keys (⇧↓, ⇧↑, ⇧Page Down, ⌘⇧→ and the rest of selectionCommands) extend the selection from an insertion point the reader can't see and the keyboard can't move.**

- **Where:** `ios/AloudMac/Reader/ReaderNSTextView.swift:347` (bad-ux)
- **Scenario:** 1. Open a book saved deep in its text.
- **Root cause:** I tried to refute this and could not. The bug is real for the reader's first selection key after a book opens. rebuild() always sets the selection to {0,0} (ios/AloudMac/Reader/ReaderColumnView.swift:527).
- **Fix:** A selection key with the caret off screen first moves the caret to the first word shown, with downstream affinity, so the selection starts in the passage on screen and the page stays. The first word rather than the first character, and downstream, so that Cmd-Shift-Right from a wrapped line's start selects the line (the post-merge repair in f0031a8).
- **Test:** ReaderColumnViewTests.testASelectionKeyStartsFromThePassageOnScreen, testTheCaretGoesToTheFirstWordShown
- **Commit:** `32bc4b0`, `f0031a8`

##### L022 · Medium · Mac

**Click to play waits the full NSEvent.doubleClickInterval before it plays and shows nothing while it waits.**

- **Where:** `ios/AloudMac/Reader/ReaderColumnView.swift:1674` (bad-ux)
- **Scenario:** 1. In System Settings > Accessibility > Pointer Control, move Double-click speed toward Slow.
- **Root cause:** The hold is deliberate and covered by a test, but there is no feedback while it runs, and the user's retry is always treated as a cancel. A click on the Mac reader plays only after NSEvent.doubleClickInterval, and nothing on the page or the bar changes until then.
- **Fix:** Mac only. Only the click-hold code in ReaderColumnView changed.
- **Test:** AloudMacTests ReaderColumnViewTests.testAHeldClickShowsItsSentenceAtOnceAndHoldsTheAudioBriefly (and testAClickInASentencePlaysFromIt updated for the cap)
- **Commit:** `32bc4b0`

##### L024 · Medium · Mac

**When a new search finishes, the panel swaps in the new results but leaves the keyboard cursor where it was.**

- **Where:** `ios/AloudMac/Reader/MacContentsPanel.swift:652` (bad-ux)
- **Scenario:** While the previous query's results are still showing during the 200 ms debounce and the scan, mode is .results (searchedQuery is still the old string), so focusList() (line 493) puts the cursor on old results[0] and announces it. When the new scan lands, lines 651-655 replace results and searchedQuery and announce only the count.
- **Root cause:** The finding holds, and nothing in the code guards against it. While a new query waits out its debounce and scan, MacContents.mode returns .results, because searchedQuery is still the old string and the old results are not empty.
- **Fix:** Mac only. A new pure helper, MacContents.cursorAfterScan(listFocused:found:), decides where the cursor goes.
- **Test:** AloudMacTests MacContentsPanelTests.testALandingScanMovesAListCursorOntoWhatLanded; ReaderLintTests.testTheMacContentsSearchMovesAListCursorOntoWhatLanded (source pin)
- **Commit:** `32bc4b0`

##### L030 · Medium · Mac

**The F048 fix (⌘Z in a text field with typing undoes the typing, not Undo Jump) does nothing on non-Latin keyboard layouts.**

- **Where:** `ios/AloudMac/Commands/MacKeyRouter.swift:92` (bad-ux)
- **Scenario:** With the Russian (or Greek, Hebrew, Ukrainian…) input source active, open a book and type 'whale' in Contents > Search this book. Click a result: that is a jump, and the Undo jump chip and the Edit > Undo Jump (⌘Z) item appear for about 10 s.
- **Root cause:** The finding holds. The F048 guard at MacKeyRouter.swift:92 finds ⌘Z only through MacCommand.command(for:).
- **Fix:** Mac only. The F048 guard in MacKeyRouter.handle now uses Self.isUndoKey(event).
- **Test:** AloudMacTests MacKeyRouterTests.testCommandZOnANonLatinLayoutUndoesTheTypingNotTheJump
- **Commit:** `32bc4b0`, `f0031a8`

##### L008 · Low · Mac

**The Mac accepts a file by its name extension only.**

- **Where:** `ios/AloudMac/Library/MacAddMenu.swift:383` (bad-ux)
- **Scenario:** isAddable requires UTType(filenameExtension:) to conform to .pdf or .plainText (lines 382-384). For a name with no extension there is no such type, so: the drop target refuses the drag; a Finder Copy followed by ⌘V passes it through admit(), which drops it with no message (line 129); and MacRootView.receiveOpened (MacRootView.swift:152) returns .textNoText, which shows 'This file has no readable text.
- **Root cause:** The Mac behaviour is real, but most of it is how the app was designed, and the iPhone comparison is overstated. What holds: MacFileIntake.isAddable (MacAddMenu.swift:380-385) decides by file name alone.
- **Fix:** Added a new ImportFailure.unsupportedType row: the title says Aloud can't add this kind of file, and the next step names PDFs and plain-text files. File outside my list, one word: MacRootView.receiveOpened returns .unsupportedType instead of .textNoText.
- **Test:** MacImportTests.testAnUnsupportedFileOpenedKeepsTheWindowAndSaysWhy (updated to expect .unsupportedType); ImportFailureCopyTests.testEveryRowReadsAsItAlwaysHas row and testAnUnsupportedTypeIsNotCalledUnreadable
- **Commit:** `8ee9533`

##### L015 · Low · Mac

**Return on the focused Continue circle opens the reader instead of pressing the circle, because the hero's .onKeyPress(.return) sits on the whole card, circle included.**

- **Where:** `ios/AloudMac/Library/MacLibraryView.swift:234` (polish)
- **Scenario:** The F027 fix attaches .onKeyPress(.return) { open(hero) } to the MacContinueHero container. The circle is its own focusable Button inside that container.
- **Root cause:** The F027 Return handler sits on the MacContinueHero container (MacLibraryView.swift:233-237). That container is an ancestor of both buttons in the shared ContinueListeningCard: the body Button and the circle Button.
- **Fix:** Return on the focused Continue circle plays or pauses in place instead of bubbling to the card's Return, which opened the reader. A Mac-only returnKeyActsOnMac modifier in the platform seam handles it, and it is a no-op on the iPhone.
- **Test:** LibraryLintTests.testReturnOnTheMacContinueCircleTogglesInPlace
- **Commit:** `82d6097`, `f0031a8`

##### L023 · Low · Mac

**⌘C and the menu's Copy strip only U+FFFC (H054), so the page's own furniture ends up in the quote.**

- **Where:** `ios/AloudMac/Reader/ReaderNSTextView.swift:267` (polish)
- **Scenario:** 1. Open a multi-page PDF.
- **Root cause:** The H054 fix is incomplete. The original H054 report already said a PDF page numeral shows up in the copy, but the fix (cfb1531) only removes U+FFFC and the line break after it.
- **Fix:** Shared ReaderColumnText (furniture attribute only): NSAttributedString.Key.readerFurniture is added to markAttributes (the PDF numeral line and the end mark) and over the whole colophon. On the Mac, ReaderNSTextView.writeSelection builds the quote for a single selection from the storage substring minus the furniture runs (withoutFurniture), then applies the existing quotable().
- **Test:** ReaderColumnTextTests.testPageNumeralsTheEndMarkAndTheColophonAreFurniture; AloudMacTests ReaderColumnViewTests.testACopyLeavesOutPageNumeralsAndTheColophon
- **Commit:** `32bc4b0`

#### Shared iPhone/Mac core and iPhone app

##### L003 · High · iPhone + Mac

**The System voice always reads with an English voice, whatever language the book is in.**

- **Where:** `ios/Aloud/Playback/AVSpeechEngine.swift:65` (bad-ux)
- **Scenario:** On an iPhone set to French or German, which ships with the compact Thomas or Anna voice, import a French or German EPUB/TXT and press Play before downloading the natural voice, or on the System voice. Every sentence is read by the top English voice (Samantha/Ava) with English pronunciation, although a matching voice is installed.
- **Root cause:** The finding holds, and for non-Latin scripts it is worse than reported. The System voice is always resolved by ranks() (AVSpeechEngine.swift:62-72).
- **Fix:** The language is detected once per book. AVSpeechEngine.readingLanguage runs NLLanguageRecognizer over 64 sentences sampled across the book.
- **Test:** VoicePreferenceTests: testAFrenchBookReadsInAnInstalledFrenchVoice, testChineseReadsInItsOwnDialect, testALanguageWithNoVoiceHasNoPick, testOnlyTheSystemVoiceCarriesTheBooksLanguage, testABooksLanguageIsFoundFromItsSentences, testPlaybackHandsTheSystemVoiceTheBooksLanguage (source pin). SystemVoiceCacheTests (in KokoroRuntimeConfigTests.swift): testEachLanguageKeepsItsOwnPick, testALanguageWithNoInstalledVoiceReadsInTheEnglishPick, testAnInstalledLanguageVoiceReadsItsBook
- **Commit:** `c6227ae`

##### L006 · High · iPhone + Mac

**A legacy Central European, Turkish or Baltic text file (Windows-1250, 1254 or 1257, or ISO-8859-2) is decoded as Windows-1252, so the book is stored as gibberish.**

- **Where:** `ios/Aloud/Extraction/TextExtractor.swift:1405` (broken-feature)
- **Scenario:** read() sends only files with more high bytes than ASCII letters to legacyDecoded (line 1398), and that list has no Latin-script code pages. A Polish, Czech, Hungarian or Turkish file is mostly ASCII, so it skips that check and reaches the Windows-1252 decode at line 1405, which accepts almost any bytes.
- **Root cause:** I could not refute it. For a .txt file that is not UTF-8 and has no BOM, the reader works through these steps: - `String(contentsOf:usedEncoding:)` returns nil when the file has no encoding xattr.
- **Fix:** read() no longer goes straight to Windows-1252. The new TextExtractor.latinDecoded decodes the file as 1252, Latin-1, 1250, ISO-8859-2, 1254 and 1257 and scores each reading.
- **Test:** ExtractionEncodingTests.testCentralEuropeanTurkishAndBalticCodePagesAreDecoded, ExtractionEncodingTests.testWesternTextKeepsItsWindows1252Reading
- **Commit:** `d5e5989`

##### L000 · Medium · iPhone + Mac

**Emma, the only British natural voice, is phonemized with American pronunciations.**

- **Where:** `ios/Aloud/TTS/KokoroSherpaEngine.swift:336` (bad-ux)
- **Scenario:** In Listening, pick Emma ('Gentle, mellow', lang en-GB, the voice SpokenYears already gives the British 'two thousand and five'). Play a sentence containing tomato, schedule, dance or water.
- **Root cause:** Emma (kokoro:bf_emma), the only British voice in the curated list, gets American phonemes on every sentence. The report gives two mechanisms, and only its second one actually runs.
- **Fix:** The sentence call now goes through tts.generateWithConfig with SherpaOnnxGenerationConfigSwift(speed:sid:extra: ["lang": phonemeLanguage(for: voice.lang)]). That gives en-gb for en-GB voices (Emma) and en-us for the rest and the blends, which is what sherpa already used by default.
- **Test:** KokoroPhonemeLanguageTests (in KokoroRuntimeConfigTests.swift): testEmmaIsPhonemizedAsBritish, testEveryOtherVoiceIsPhonemizedAsAmerican, testEverySentenceCallNamesTheLanguage (source pin)
- **Commit:** `c6227ae`

##### L004 · Medium · Mac

**Both copy sites use FileManager.copyItem, which keeps the Finder 'Locked' (uchg) flag.**

- **Where:** `ios/Aloud/Library/DocumentStore.swift:1074` (broken-feature)
- **Scenario:** I checked this with a probe: copyItem of a uchg file gives a uchg copy, and removeItem on that copy fails with Cocoa error 513. On the Mac, MacFileIntake.stageCopy (MacAddMenu.swift:447) copies the dropped or picked file into Documents/Inbox/<UUID>/ with the flag set.
- **Root cause:** FileManager.copyItem carries the Finder Locked (uchg) flag over to the copy. After that, every removeItem on the copy, or on the folder holding it, fails with Cocoa error 513.
- **Fix:** Added DocumentStore.unlock(_:), which clears the .immutable and .appendOnly flags. It runs right after copyItem in DocumentStore.copyFile and in MacFileIntake.stageCopy.
- **Test:** SourceHashDedupeTests.testALockedFilesLibraryCopyCanBeRemoved (both apps); MacImportTests.testALockedFileStagesACopyThatCanBeRemoved and testTheLaunchSweepClearsALockedLeftover; DocumentImporterTests.testALockedInboxLeftoverIsSwept (iOS)
- **Commit:** `8ee9533`

##### L005 · Medium · iPhone

**Importing a very large PDF holds the parsed text layout of every page in memory until the import ends.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:54` (crash)
- **Scenario:** On an iPhone, add a dense PDF of 1,000 to 3,000 pages, such as a reference book or a textbook. The loop at lines 54-61 calls page.selection(for:) and selectionsByLine() on each page of one PDFDocument that stays open for the whole extraction.
- **Root cause:** The mechanism is real, but the report overstates how easily it crashes the app. Pass 1 (PDFTextExtractor.swift:54-61) reads every page through one PDFDocument.
- **Fix:** Pass 1 now reopens the PDFDocument every pagesPerOpening pages (default 100; a new stored property, so the memberwise init PDFTextExtractor(pagesPerOpening:) also exists) and reads each page inside an autoreleasepool. The title and outline come from their own short-lived opening, and the old document is released before the next one opens.
- **Test:** PDFTextExtractorTests.testPagesReadThroughSeveralOpeningsMatchOne, PDFTextExtractorTests.testPageReadingHoldsBoundedMemoryAndCancels (source pin)
- **Commit:** `d5e5989`

##### L009 · Medium · iPhone + Mac

**When page after page reads as one paragraph that runs on, the cross-page stitch keeps adding to a single TextBlock.**

- **Where:** `ios/Aloud/Extraction/PDFTextExtractor.swift:767` (bad-ux)
- **Scenario:** Take a PDF where each page reads as one paragraph (no gap or indent break on the page) and the next page opens lowercase or continues the sentence. Examples: text set in blocks without indents, or ragged-right Thai, where looksFinished never matches and continuesCaseless always does. appendPageParagraphs merges each page's paragraph into blocks.last.
- **Root cause:** The mechanism is real. In appendPageParagraphs (PDFTextExtractor.swift:760-780), only the first paragraph of each page can merge onto blocks.last.
- **Fix:** looksFinished, endsInSoftHyphen and the new endsInLetterHyphen now look only at a 16-character tail before any trailing whitespace. continuesUnspacedCJK finds the last non-whitespace character directly. appendLine has an inout version that trims and appends in place; the String-returning version still exists. appendPageParagraphs moves the block out of the array and grows it in place. TextBlock.text became var, and TextBlock gains laterPages ([PageStart(letters:page:)]), a running letters count and pages(of:). buildContent gives each sentence the page it starts on, comparing the share of letters read so far.
- **Test:** PDFTextExtractorTests.testStitchedParagraphKeepsEachSentencesPage, PDFTextExtractorTests.testLongRunOnParagraphStitchesInLinearTime
- **Commit:** `d5e5989`

##### L011 · Medium · iPhone + Mac

**When library.json can't be read, the Library shows the first-run empty screen (or a partial shelf) with no sign that the user's books still exist.**

- **Where:** `ios/Aloud/Library/LibraryView.swift:52` (bad-ux)
- **Scenario:** No view checks store.isIndexReadable. LibraryView (line 52) and MacLibraryView (MacLibraryView.swift:49) branch only on store.documents.isEmpty.
- **Root cause:** Neither Library screen has anything that reads store.isIndexReadable. The only app-code uses are the guards in AppModel (lines 150 and 391, and AppModel+PlaceHistory.swift:48) and the throw paths inside DocumentStore.
- **Fix:** Added a shared UnreadableLibraryNotice view in EmptyLibraryView.swift, which both apps compile. Both LibraryView and MacLibraryView show it through .safeAreaInset(edge: .top) when !store.isIndexReadable, above both the first-run screen and a partial shelf.
- **Test:** LibraryLintTests.testBothLibrariesShowTheUnreadableLibraryNotice (source pin, both views); ImportFailureCopyTests.testTheUnreadableLibraryNoticeSaysTheBooksAreKept (copy, per platform)
- **Commit:** `8ee9533`

##### L017 · Medium · iPhone + Mac

**Classics search only looks at the shortened display author. catalog_normalize.py removes each author's full name and pseudonym from the display name and keeps the original only in headerAuthor...**

- **Where:** `ios/Aloud/Models/BookshelfCatalog.swift:92` (bad-ux)
- **Scenario:** On iPhone or Mac, open Classics and search for the author's best-known name. Book 1597's header author is 'H.
- **Root cause:** I confirmed this, and it is a regression. SearchKey.init (ios/Aloud/Models/BookshelfCatalog.swift:86-94) builds its haystack only from book.title and book.author.
- **Fix:** SearchKey now takes alias words that BookshelfIndex.authorAliases gathers per display author across all of that author's books, as the verifier suggested. These are header-author words missing from the display name, and they count as author words for ranking.
- **Test:** BookshelfSearchTests.testSearchFindsTheNamesTheHeaderSpelledOut, plus shipped-catalog assertions in testShippedCatalog
- **Commit:** `82d6097`

##### L020 · Medium · iPhone

**VoiceOver's label for the column and its double-tap / Play from here use the playhead's sentence (`accessibilitySentence ?? activeSentence`, lines 1135 and 1147) even when that sentence is off screen.**

- **Where:** `ios/Aloud/Reader/ReaderTextView.swift:1147` (bad-ux)
- **Scenario:** 1. Turn VoiceOver on and play a book; the voice is at sentence 500.
- **Root cause:** The finding holds. On iPhone, when no rotor stop is chosen, the column's VoiceOver label and its double-tap / Play from here always use the playhead's sentence (`accessibilitySentence ?? activeSentence`).
- **Fix:** iPhone: rotorAnchor() is renamed restingSentence(). With no rotor stop, spokenSentence (the label) and playFromHere (double-tap and Play from here) now use it, like the rotor's first step.
- **Test:** ReaderFollowCoordinatorTests.testVoiceOverRestsOnThePassageOnScreenWhileTheVoiceIsAway
- **Commit:** `32bc4b0`

##### L025 · Medium · iPhone + Mac

**While a sentence buffers, Now Playing tells the system the book is paused (playbackRate 0...**

- **Where:** `ios/Aloud/NowPlaying/NowPlayingSnapshot.swift:35` (bad-ux)
- **Scenario:** An iPhone listener locks the phone and presses Play on the lock screen with the natural voice still cold, or skips 15 s from the lock screen or AirPods while a book plays. startPlayback sets status = .buffering, and refresh(force: true) right after the skip publishes rate 0. The lock screen shows a Play glyph and the scrubber stops for the whole buffering time, which can be several seconds for a cold Kokoro load.
- **Root cause:** I confirmed this from the code, and the mechanism is certain on the Mac. On iPhone the code path is the same, but whether the lock-screen glyph actually flips is likely rather than certain.
- **Fix:** The snapshot now publishes the rate for both .playing and .buffering. The iPhone lock screen therefore keeps its pause button, and on the Mac state(for:) gives playbackState .playing.
- **Test:** NowPlayingSnapshotTests.testABufferingSentenceReportsThePlayingRateAndReanchorsWhenItStarts; NowPlayingManagerTests.testThePublishedStateFollowsThePublishedRate (row is now (.buffering, .playing)); NowPlayingSnapshotTests.testOnlyPlayingOrBufferingReportsTheRate
- **Commit:** `9c88240`

##### L026 · Medium · iPhone

**On iPhone, 'Where you stopped' rows are identified by their position (PlaceRow.id is index).**

- **Where:** `ios/Aloud/Reader/ContentsSheet.swift:384` (bad-ux)
- **Scenario:** PlaceHistoryRows.swift:19 makes PlaceRow.id the index, and ContentsSheet iterates ForEach(Array(rows.prefix(visible))). When the sleep timer, a call interruption or a headphone unplug ends listening while Contents is open, PlaceHistoryStore.record puts the new stop at index 0 and shifts the rest down.
- **Root cause:** The finding holds. Nothing on the iPhone sheet stops it. iPhone place rows are keyed by their position.
- **Fix:** Both apps. iPhone ContentsSheet: the place ForEach is keyed by id: \.sentence. Mac MacContentsPanel: the place ForEach is keyed by \.sentence, and the row's explicit id is now MacContents.PlaceKey(sentence:) instead of .id(row.index). onChange(of: cursor) maps a place cursor to its PlaceKey for scrollTo.
- **Test:** ReaderLintTests.testPlaceRowsAreKeyedByTheirPlaceOnBothApps (source pin; SwiftUI identity can't be driven from a unit test)
- **Commit:** `32bc4b0`

##### L001 · Low · iPhone + Mac

**Opening a book leaves the previous book's queued cue warm-ups in the synthesis scheduler. load() warms the new cue with cuePrefetch() (or cuePrefetch(from: 0, through: 1...**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:734` (bad-ux)
- **Scenario:** Use a Kokoro voice on iPhone or Mac. Open book A paused. load() queues warm-ups for A[n] and A[n+1], and A[n] starts synthesizing (seconds when the model is cold).
- **Root cause:** The code fact is true, but the reported impact mostly does not happen. load() (PlaybackController.swift:731-735) never passes replacingWarmUps and never calls cancelPending(), and unload() (753-771) does not either. So the outgoing book's queued warm-ups do outlive the switch.
- **Fix:** load() now warms the new cue with replacingWarmUps: cuePrefetch(moved: true), or cuePrefetch(from: 0, through: 1, voice:, replacingWarmUps: true) for a Finished book. unload() drops the closed book's queued warm-ups with scheduler.prefetch([], replacingWarmUps: true). Jobs that something is waiting on are kept.
- **Test:** CatchingUpTests.testOpeningOrClosingABookDropsTheOldBooksWarmUps
- **Commit:** `9c88240`

##### L002 · Low · iPhone

**If a route loss arrives during an interruption, it cancels the promised auto-resume but is never recorded.**

- **Where:** `ios/Aloud/Playback/PlaybackController.swift:1063` (bad-ux)
- **Scenario:** stop(because:) clears resumeAfterInterruption at line 1059, then returns at `guard isActive else { return }` (line 1063) because the earlier `.began` already paused playback. record(.headphonesDisconnected) never runs, so `stopped` and `pendingStopAnnouncement` stay `.interrupted` (record() always defers `.interrupted`, line 1126). When the interruption ends, handleInterruption(.ended) (line 2632) sees resumeAfterInterruption == false and calls sceneDidBecomeActive(), which announces the stale `.interrupted` text.
- **Root cause:** The code path is real, but the harm is smaller than reported. When a route loss arrives while playback is paused by an interruption, stop(because:) clears resumeAfterInterruption (PlaybackController.swift:1059) and then returns at `guard isActive else { return }` (line 1063). record(.headphonesDisconnected) never runs, so `stopped` and `pendingStopAnnouncement` stay `.interrupted`.
- **Fix:** stop(because:) keeps the resumeAfterInterruption value from before it clears it. When playback is already paused, that value was true, and the loaded book's current stop is .interrupted, it calls record(reason).
- **Test:** StopReasonTests.testHeadphonesLostDuringAnInterruptionBecomeTheStop
- **Commit:** `9c88240`

##### L010 · Low · Mac

**Book titles and the 'Adding' overlay use the POSIX file name.**

- **Where:** `ios/Aloud/Import/DocumentImporter.swift:459` (polish)
- **Scenario:** I checked this with a probe. A file Finder shows as 'AC/DC Live.txt' has lastPathComponent 'AC:DC Live.txt', while FileManager.displayName and URLResourceValues.localizedName both return 'AC/DC Live.txt'.
- **Root cause:** The finding holds. On macOS, Finder shows a ':' in a POSIX file name as '/'.
- **Fix:** Added URL.displayName (localizedName, falling back to lastPathComponent) and URL.displayStem in DocumentImporter.swift. displayStem cuts the extension only when the shown name ends with it, so a hidden extension never cuts 'Mr. Smith' to 'Mr' (the probe confirmed localizedName hides it).
- **Test:** MacImportTests.testTitlesTakeTheNameFinderShows and testTheCopyingOverlayShowsTheNameFinderShows; testTheImportersFailureInABatchNamesItsFile covers the named alert
- **Commit:** `8ee9533`

##### L012 · Low · iPhone + Mac

**The PDF import progress gives 90% of the bar to PDFKit's per-page pass, which is the quick part.**

- **Where:** `ios/Aloud/Extraction/ExtractionPipeline.swift:22` (polish)
- **Scenario:** progress?(fraction * 0.9) runs only during pass 1 of PDFTextExtractor.extract. The rest happens with no further progress calls until progress?(1.0): header detection, folding paragraphs, stitching, normalizing, segmenting sentences (buildContent) and detecting chapters.
- **Root cause:** In ios/Aloud/Extraction/ExtractionPipeline.swift:21-23 the only progress before the end is `progress?(fraction * 0.9)`. PDFTextExtractor.extract (PDFTextExtractor.swift:54-62) calls it only in its pass-1 page loop.
- **Fix:** The extractor's progress now covers both passes: PDFKit page reading takes the first half and folding pages into paragraphs the second. The pipeline maps that to 0 to 0.6, then buildContent reports blocks at each whole percent from 0.6 to 0.95, then chapters run and progress reaches 1.0.
- **Test:** PDFTextExtractorTests.testPDFProgressCoversEveryStage
- **Commit:** `d5e5989`

##### L013 · Low · iPhone + Mac

**estimatedSyllables keeps only the ASCII letters a-z.**

- **Where:** `ios/Aloud/Extraction/SentenceSegmenter.swift:431` (polish)
- **Scenario:** tokenWeight gives max(1, estimatedSyllables + digits), and those weights spread a sentence's duration over its words (the mechanism H040 relied on). In a Hindi book read by Kokoro, a five-syllable word and a one-syllable particle get the same share, so the highlight runs ahead on short words and falls behind on long ones.
- **Root cause:** The bug is real, but the report overstates how much it matters. In ios/Aloud/Extraction/SentenceSegmenter.swift:430-437, estimatedSyllables keeps only a-z after lowercasing. tokenWeight (line 490-491) then gives max(1, syllables + numberSyllables) plus pause weight.
- **Fix:** estimatedSyllables changes: - ASCII a-z keeps a fast path. - Latin letters with accents fold to a-z: été 2, café 2, résumé 3. - A diaeresis starts its own syllable: naïve 2, Zoë 2. - The silent-e discount now needs a plain final e that starts its own vowel run, or a -gue/-que ending, so fiancée, degree, continue and goodbye gain their syllable while tongue and vague stay 1. - Greek and Cyrillic count vowel runs, and й stays a consonant. - Han, kana and Hangul count one per character. - Indic letters count unless a virama follows them (संयुक्तराष्ट्र 5, नमस्ते 3). - Other scripts count one per two letters. A probe over Shakespeare's complete works changed 260 distinct words, all of them to...
- **Test:** SentenceSegmenterTests: testAccentedLatinVowelsCount, testOtherScriptsCountTheirSyllables (existing testEstimatedSyllables unchanged and still holds)
- **Commit:** `c6227ae`

##### L016 · Low · iPhone

**At xxLarge/xxxLarge, the largest sizes below the accessibility range, grid cards still cut titles at 2 lines and authors at 1 line, and the hero cuts titles at 2 lines in a column of about 108 pt.**

- **Where:** `ios/Aloud/Library/DocumentCardView.swift:74` (polish)
- **Scenario:** wrapsInFull is true only for isAccessibilitySize. Below AX1 the grid stays at 2 columns: 159 pt each on a 375 pt phone, 132 pt with SE Display Zoom (320 pt).
- **Root cause:** I could not refute it. The code does what the report says, and measuring the real fonts shows text that fits at the default size gets cut at xxLarge and xxxLarge.
- **Fix:** Added DocumentCardView.wrapsInFull(at:), true from .xxLarge, which replaces isAccessibilitySize for the grid card's title and author limits. The hero's non-AX title in ShelfHeroCard (ContinueListeningCard.swift) now follows the same rule, a one-line change outside the owned list.
- **Test:** ShelfAccessibilityTests (rule and pin); DocumentCardLayoutTests.testTheTwoColumnCardKeepsItsLimits (full wrap from xxLarge, two lines and one below)
- **Commit:** `82d6097`, `f0031a8`

##### L018 · Low · iPhone + Mac

**searchWords drops apostrophes but splits at hyphens.**

- **Where:** `ios/Aloud/Models/BookshelfCatalog.swift:183` (bad-ux)
- **Scenario:** Open Classics on iPhone or Mac and type 'casebook'. The bundled title 'The Case-Book of Sherlock Holmes' is indexed as 'the case book of sherlock holmes'.
- **Root cause:** The finding is real. BookshelfIndex.searchWords (ios/Aloud/Models/BookshelfCatalog.swift:183-186) deletes apostrophes but splits at every other non-letter or non-digit character, hyphens included.
- **Fix:** Added BookshelfIndex.hyphenJoinedWords, which adds each hyphenated word, written as one, to the haystack for the title, header title and author. Queries still split at hyphens.
- **Test:** BookshelfSearchTests.testAHyphenatedWordMatchesWrittenAsOne
- **Commit:** `82d6097`

##### L019 · Low · iPhone + Mac

**After the H016 fix, each row shows the book's length at the app-wide speed, but the shelves are still grouped at 1× under time-named headers.**

- **Where:** `ios/Aloud/Bookshelf/BookshelfView.swift:141` (bad-ux)
- **Scenario:** Set the speed to 0.5× (SpeedScale.range starts at 0.5) and open Classics. BookshelfSection.section(forMinutes:) still puts 'The Big Fix' (56 min at 1×) under the 'Under an hour' header, yet its row reads '1 hr 52 min' and VoiceOver says 'about 2 hours'.
- **Root cause:** BookshelfIndex.init (ios/Aloud/Models/BookshelfCatalog.swift:126-127) sorts every book onto a shelf by estimatedListeningMinutes, which is the 1× length (165 wpm). The shelf titles come from BookshelfSection.title (lines 41-46): "Under an hour", "An evening" and "Long reads".
- **Fix:** Chose one measure: the rate-aware time. Added BookshelfBook.listeningMinutes(rate:) and BookshelfIndex.shelves(rate:); at 1× the latter returns the stored shelves, and at other speeds it regroups in one pass.
- **Test:** BookshelfSearchTests.testShelvesFollowTheSpeedTheRowsShow; MacShelfFeedTests.testClassicsShelvesAndRowsAreOneMeasure; CardCopyTests row-minutes check; LibraryLintTests.testTheClassicsScreensShelveAtTheirRowsSpeed (pin)
- **Commit:** `82d6097`

##### L027 · Low · iPhone

**The Settings and Licenses screens have no headings for VoiceOver.**

- **Where:** `ios/Aloud/Settings/LicensesView.swift:92` (polish)
- **Scenario:** With VoiceOver on, open Settings and then Licenses, and set the rotor to Headings. Swiping up or down finds no headings, so a VoiceOver user can't jump to the title or move between the five acknowledgement cards (sherpa-onnx, ONNX Runtime, Kokoro, espeak-ng, Bundled classics).
- **Root cause:** On iPhone, the Settings and Licenses screens have no element with the header trait, so VoiceOver's Headings rotor finds nothing on either one. Neither screen sets .navigationTitle.
- **Fix:** Added .accessibilityAddTraits(.isHeader) to the principal Text("Settings") and Text("Licenses") titles, to each Licenses card's component name, and to the Bundled classics title. iPhone only: the Mac excludes SettingsView and never shows the LicensesView body.
- **Test:** SettingsHomeLintTests.testSettingsAndLicensesOfferHeadings (source pin)
- **Commit:** `82d6097`

##### L028 · Low · iPhone

**With no book loaded, a headset Play/Pause always counts as 'continue the last book', even when the only audio is a no-book voice sample (PlaybackController.speakSample, status stays .idle).**

- **Where:** `ios/Aloud/NowPlaying/NowPlayingManager.swift:205` (bad-ux)
- **Scenario:** With no book open in the Library, the listener opens the listening settings and taps a voice to hear its sample. While the sample speaks they press the AirPods stem, which sends togglePlayPause.
- **Root cause:** The finding is real: I traced every step in the code and none of them guards against it. It is still low severity, because the window is narrow and the result is harmless and easy to undo.
- **Fix:** PlaybackController now has private(set) isSpeakingSample. speakSample sets it. It is cleared when the sample finishes, when it fails or never starts with the same token, and in invalidateSchedule. pause() with no book now cuts a sample that is speaking; before, it did nothing.
- **Test:** VoiceAuditionTests.testARemotePauseDuringTheNoBookSampleCutsItAndContinuesNothing; NowPlayingManagerTests.testOnlyAPauseCutsTheNoBookSample
- **Commit:** `9c88240`

##### L029 · Low · Tooling

**Three iPhone natural-voice UI test paths take their model directory from KokoroPlaybackUITest.modelDirectory.**

- **Where:** `ios/AloudUITests/KokoroPlaybackUITest.swift:20` (broken-feature)
- **Scenario:** 1. Run the iPhone UI tests.
- **Root cause:** The finding holds. KokoroPlaybackUITest.modelDirectory (ios/AloudUITests/KokoroPlaybackUITest.swift:19-20) is still the scratchpad path from an old Claude session, and that path no longer exists.
- **Fix:** KokoroPlaybackUITest.modelDirectory (shared by ListeningUITests and HonestStopsUITest) now names /Users/Shared/AloudKokoroModel, the seed ios/tools/fetch_kokoro_model.sh fills and the Mac UI tests already read, instead of an old session's /private/tmp scratchpad.
- **Test:** AppLintTests.testUITestsReadTheSharedModelSeed
- **Commit:** `afde3a9`

#### Web app

##### L033 · Medium · Web app

**Clicking a sentence to seek also fires when the user is only selecting text.**

- **Where:** `frontend/src/components/Reader.tsx:166` (broken-feature)
- **Scenario:** The sentence handler is `onClick={() => seek(sid)}`, and seek() is just `player.seekTo(sid)`. Nothing checks window.getSelection() or event.detail.
- **Root cause:** I could not refute it. The only click handler on a sentence is `onClick={() => seek(sid)}` at frontend/src/components/Reader.tsx:166. seek() calls player.seekTo straight away (Reader.tsx:44-46). seekTo pauses and then always calls playIndex (frontend/src/lib/player.ts:826-831), and playIndex sets wantPlaying = true (player.ts:511), so reading starts even when the user had paused.
- **Fix:** Added clickSeekGate in readerNav.ts. Reader's sentence onClick now calls clickSeek.click(sid, e.detail) instead of seeking at once.
- **Test:** frontend/tests/readerNav.test.ts: 'L033: a single click plays from its sentence once the double-click time has passed', 'L033: double-clicking a word to select it neither moves the place nor plays', 'L033: a drag that selects a phrase inside one sentence does not seek', 'L033: a click from assistive technology plays at once; a newer click replaces one waiting', 'L033: the reader routes sentence clicks through the gate, with the click count'
- **Commit:** `8d3f88d`

##### L035 · Medium · Web app

**When a PDF dropped onto an open book fails to parse, the book comes back (G015) but the reader view does not. <Reader> is unmounted for the loading view and remounted with scrollTop 0.**

- **Where:** `frontend/src/App.tsx:165` (bad-ux)
- **Scenario:** openPdf sets status 'loading', and App renders `isLoading ? <LoadingView/> : doc ? <Reader/>`, which unmounts the Reader. On failure, intake.ts:111 restores before.status, and the Reader mounts fresh.
- **Root cause:** The G015 fix keeps the book's state (doc, fileName, currentSentence and a paused status) but not its view. openPdf sets status 'loading' synchronously, and App's ternary at App.tsx:165-171 then swaps <Reader> for <LoadingView>. These are different component types in the same slot, so React unmounts the Reader together with its scroll container.
- **Fix:** App now keeps <Reader key={readerKey(doc)} held={isLoading}> mounted whenever a doc is open. The LoadingView sits over it in .app__main-over (absolute, inset 0). .reader.is-held uses visibility:hidden, so the box keeps its layout and its scrollTop.
- **Test:** frontend/tests/appWiring.test.ts 'L035: a PDF parsing over an open book leaves the reader mounted beneath it'; frontend/tests/globalsCss.test.ts 'L035: a reader held under the loading view is hidden but keeps its layout'
- **Commit:** `8d3f88d`

##### L036 · Medium · Web app

**The karaoke word highlight treats a token as a word only when it contains an ASCII letter or digit (`/[A-Za-z0-9]/`).**

- **Where:** `frontend/src/lib/chunker.ts:317` (bad-ux)
- **Scenario:** tokenizeSentence sets isWord from an ASCII-only regex. computeWindows still gives these tokens a time window (weight >= 1), so currentWord points at them. ActiveWords (Reader.tsx:97) only styles a token when tk.isWord, so nothing is lit for that span of audio.
- **Root cause:** The bug is real. The highlight timing gives every non-whitespace token a time slot, but the reader only draws the highlight on tokens whose isWord flag is true.
- **Fix:** tokenizeSentence now sets isWord with /[\p{L}\p{N}]/u (HAS_LETTER_OR_DIGIT), the same pattern player.ts uses for HAS_SPEAKABLE. On the base tokenizer, 'Ele é professor.' lit only Ele and professor., and the Hindi sentence lit nothing.
- **Test:** frontend/tests/readerNav.test.ts 'L036: words with no ASCII letter are words the read-along lights'
- **Commit:** `8d3f88d`

##### L039 · Medium · Web app

**The position track's pointer handlers ignore which button was pressed and handle no pointercancel or lostpointercapture.**

- **Where:** `frontend/src/components/PlayerBar.tsx:51` (bad-ux)
- **Scenario:** onPointerDown calls setPointerCapture and setPreview for any button. onPointerUp then calls player.seekTo(target), which always plays. On macOS the context menu opens on mousedown and takes the mouseup, so no pointerup arrives. preview stays non-null, onPointerMove keeps updating it on hover (it only checks preview !== null), and 'is-scrubbing' stays on until another click lands on the track.
- **Root cause:** I could not refute it, and the code has no guard. In frontend/src/components/PlayerBar.tsx:51-65, onPointerDown only checks `total === 0`.
- **Fix:** Added startsScrub({button, ctrlKey}) in controlKeys.ts: only button 0 without Control scrubs, so a right-click, middle click, two-finger tap or Mac Control-click no longer seeks and plays. The track now also has onPointerCancel and onLostPointerCapture, which call endScrub (setPreview(null), no seek), and onPointerMove ends the scrub when e.buttons === 0, so the stuck is-scrubbing state cannot persist.
- **Test:** frontend/tests/controlKeys.test.ts 'L039: only a primary press scrubs the position slider', 'L039: a scrub cut short stops without seeking, and nothing else starts one'
- **Commit:** `8d3f88d`

##### L041 · Medium · Web app

**When a non-PDF is picked through the drop target's file dialog (or dropped on it), the only feedback is the button's visible text.**

- **Where:** `frontend/src/components/Dropzone.tsx:44` (bad-ux)
- **Scenario:** handleFiles sets rejected=true, which swaps the inner title to 'That file isn't a PDF'. The button's accessible name comes from aria-label='Drop a PDF here or click to browse' (line 87), which overrides its content.
- **Root cause:** In frontend/src/components/Dropzone.tsx, handleFiles (lines 43-46) handles a non-PDF with only `setRejected(true)` and a 2.2 s timer. That changes the visible title and hint (lines 97-104) and adds a CSS class.
- **Fix:** Dropzone now computes title and hint once and renders them in the button as before. It also adds a polite role=status visually-hidden <p> beside the button, mounted empty, which holds the title and hint while rejected.
- **Test:** frontend/tests/appWiring.test.ts 'L041: a file the drop target refuses is said from a live region'
- **Commit:** `8d3f88d`

##### L044 · Medium · Web app

**The J041 focus fix covers only success.**

- **Where:** `frontend/src/lib/intake.ts:115` (bad-ux)
- **Scenario:** openPdf's failure branch with no open book sets doc null and status 'error'. App renders `<Dropzone focusOnMount={focusDropzone}>`, but focusDropzone only becomes true after the header 'New' button (handleReset).
- **Root cause:** The J041 and K017 fixes move focus only when a book opens (the Reader mount effect) or after the header's 'New' button (handleReset sets focusDropzone). The failure path for a first open does neither.
- **Fix:** App passes focusOnMount={focusDropzone || status === 'error'} to the Dropzone. The Dropzone that mounts after a failed first open (no book) takes focus through its existing mount effect.
- **Test:** frontend/tests/appWiring.test.ts 'L044: a first PDF that could not be read hands the focus back to the drop target' (K017 pin updated to accept the new prop expression)
- **Commit:** `8d3f88d`

##### L046 · Low · Web app

**The error banner's Dismiss button removes the banner, and itself, while it has focus, so keyboard focus falls to <body>.**

- **Where:** `frontend/src/components/StatusBadge.tsx:49` (polish)
- **Scenario:** onClick={() => setError(null)} makes ErrorBanner return null. The focused button is removed from the DOM, and nothing moves focus to a nearby control such as the play button or the reader.
- **Root cause:** I confirmed this from the code. Dismiss runs setError(null), so ErrorBanner returns null and React removes the whole div.banner along with the focused button.
- **Fix:** ErrorBanner subscribes to the store, and the listener runs synchronously when error goes from set to null, before React removes the banner. If the banner held document.activeElement, focusAfterBanner focuses the first of .play-btn, .dropzone, .reader__title.
- **Test:** frontend/tests/appWiring.test.ts 'L046: the error banner hands on the focus it held before it goes away'
- **Commit:** `8d3f88d`
