# Development Status

## 2026-08-10

- Progress: Defined separate microphone-input and Agent/TTS-output controls for the Harmony client; implementation is in progress.
- Impact: The microphone button will stop only PCM capture and ASR. The `停止` button remains the explicit Agent/TTS interrupt.
- Blockers: None.
- Next: Implement the state split, build the signed HAP, and verify the two controls on the connected phone.

## 2026-08-10

- Progress: Compared Harmony message bubbles with `web_native`; identified unstable revision keys, a detached ASR preview, missing stream-follow scrolling, nested process UI, and inconsistent metadata/artifact layout.
- Impact: These issues can cause flicker, jumpy scrolling, and make partial speech/reply state look like separate messages.
- Blockers: None.
- Next: Apply the focused bubble fixes, run static verification and a signed build, then check the result on the device when HDC reconnects.

## 2026-08-10

- Progress: Stabilized Harmony message keys, added near-bottom stream following, upgraded ASR partial/final text in one persistent user bubble, separated process activity from the assistant answer, grouped artifacts with the answer, and displayed Provider metadata.
- Impact: Streaming replies no longer intentionally recreate each bubble; users who scroll upward are not pulled back down, while live speech and final submissions retain one message identity.
- Blockers: HDC device visibility is still pending for true-device UI verification.
- Next: Reconnect the phone with developer mode enabled and verify streaming reply rendering, ASR preview/final upgrade, scroll behavior, process collapse, and artifact layout.

## 2026-08-10

- Progress: Fixed the ASR capture-failure path so it leaves `connecting`, closes the incomplete ASR socket, and exposes the recording-route error; moved model/Provider beside the assistant nickname and reordered completed-message metadata to show date/time before durations.
- Impact: The UI no longer reports a permanent ASR connection attempt after microphone capture fails, and message metadata uses less vertical space.
- Blockers: None in build; true-device interaction is reserved for manual user testing.
- Next: Install the new signed HAP and manually verify microphone routing, ASR state transitions, and message metadata ordering.

## 2026-08-10

- Progress: Replaced the plain stable-key `ForEach` message path with `Repeat` plus fresh UI snapshots, and exposed the active AudioCapturer route as phone/headset microphone text on the microphone button.
- Impact: ASR partial/final text, assistant deltas, and process completion repaint without recreating message identity; the active input route is visible in the main control.
- Blockers: None in static verification or signed build.
- Next: Manually verify complete user text, assistant final text, stopped process animation, and the displayed microphone route on the connected phone.

## 2026-08-10

- Progress: Decoupled microphone-route display from the CoreSpeech ready callback and added a five-second system-ASR startup timeout with ordered release-before-remote fallback.
- Impact: The active phone/headset route is visible as soon as capture starts, and local ASR cannot remain indefinitely in `connecting`.
- Blockers: None in static verification or signed build.
- Next: Manually confirm the route label appears and ASR reaches listening locally or after remote fallback.

## 2026-08-10

- Progress: Reopened the CoreSpeech startup issue after true-device testing showed `startRecognition()` can remain pending before the previous timeout is registered; rejected automatic local-to-remote fallback as a backend policy.
- Impact: The next build will keep explicit `harmony_offline` selection, report the exact startup phase, and stop failed microphone input without interrupting Agent/TTS work or connecting remote speech services.
- Blockers: The buffered device log no longer contains the original CoreSpeech failure, so the exact blocked API call requires one instrumented manual retry.
- Next: Add phase callbacks and a full-operation timeout, remove every implicit remote fallback, then build and install for user-operated verification.

## 2026-08-10

- Progress: Removed every automatic local-to-remote speech transition, time-bounded optional headset-routing calls, made in-flight capture startup cancellable, and reset a failed CoreSpeech recognizer before the next manual retry. Added visible startup phases and full-operation timeout protection.
- Impact: Selecting `harmony_offline` now remains local. Normal startup is no longer blocked indefinitely by optional audio-route configuration, and a failed attempt cannot poison the next microphone-open action with a stale recognizer.
- Blockers: None in static verification, ArkTS type checking, signing, assembly, or cover installation; CoreSpeech `onStart` and the actual microphone route still require user-operated true-device confirmation.
- Next: Manually open the installed app and verify local ASR reaches listening and shows the active phone/headset microphone route.

## 2026-08-10

- Progress: True-device testing found three remaining Harmony failures: a connected headset is rejected before its asynchronous input route settles, one CoreSpeech session eventually exceeds its supported audio length (`1002200003`), and a completed/failed Agent turn can leave the process bubble running.
- Impact: Headset microphone input cannot start reliably, long-running microphone input eventually breaks local ASR, and terminal Agent state is not always reflected by the UI.
- Blockers: None for implementation; final route and lifecycle acceptance requires user-operated true-device testing.
- Next: Wait for the selected headset route before accepting capture, rotate CoreSpeech sessions below the platform length limit without stopping PCM capture, and close pending Agent process state on every verified terminal path.

## 2026-08-10

- Progress: Implemented the three true-device stability fixes in the Harmony client. Audio capture now always uses the media-selectable voice-recognition source and waits up to five seconds for the requested headset route; CoreSpeech rotates at an 18-second PCM budget while preserving capture and pre-roll; gateway errors, closes, direct submit failures, and `message.complete` now finalize or diagnose the pending Agent process.
- Impact: A connected headset is no longer rejected by an immediate stale route read, continuous local ASR stays below error `1002200003`, and verified terminal Agent paths cannot leave the process timer running.
- Blockers: Implementation, static verification, ArkTS type checking, signing, assembly, and cover installation all pass. User-operated true-device acceptance remains.
- Next: Test an already-connected headset, leave local ASR enabled beyond 20 seconds, and complete or fail an Agent turn. If a completion is still missing, use the new gateway event/drop logs to identify whether the terminal event was received or rejected.

## 2026-08-10

- Progress: Reopened headset routing and message rendering after true-device regression testing. Explicit `selectMediaInputDevice()` still left the active descriptor on the phone and blocked capture; using `SOURCE_TYPE_VOICE_RECOGNITION` for speaker capture also removed the original communication-mode echo handling; stable-key `Repeat` rendered only the first ASR character on device.
- Impact: Headset capture cannot start, speaker TTS is fed back into ASR, and the user bubble does not display the transcript already present in controller state.
- Blockers: None for implementation; the affected behaviors have working reference paths in the original Harmony client.
- Next: Restore source selection by private output route, use communication capture for speaker/AEC, remove blocking explicit media-input selection, and restore revision-keyed message rendering.

## 2026-08-10

- Progress: Restored the original route-dependent capture behavior and device-reliable message repainting. Speaker output again uses communication capture, private headset output uses recognition capture with wireless recording preference, explicit media-input selection no longer blocks startup, and each message revision receives a new ArkUI `ForEach` key.
- Impact: System speaker echo handling is restored, HarmonyOS owns Bluetooth/SCO input establishment as in the original client, and ASR/assistant streaming text repaints beyond the first character.
- Blockers: Static verification, ArkTS type checking, signed assembly, and cover installation pass. The three reported regressions require user-operated true-device confirmation.
- Next: Verify headset startup, speaker echo rejection, and multi-character user/assistant streaming updates on the installed build.

## 2026-08-10

- Progress: Replaced output-inferred microphone routing with a shared HarmonyOS voice-communication AudioSession. PCM capture and TTS playback now declare communication semantics, no-accessory communication output defaults to the phone speaker, input-device changes update display/diagnostics without rebuilding capture, and short cues opt out of the communication session.
- Impact: On the connected FreeBuds 5, the system changed from `A2DP + phone MIC` to `PHONE_CHAT + BLUETOOTH_SCO` for both priority routes; the active 16 kHz capturer reported device type `7`, and the UI showed `耳机麦克风`. Closing the microphone released the session without recurring A2DP/SCO switches from status cues.
- Blockers: None for the reported headset-microphone failure. No-headset, output-only-headset, and live hot-plug behavior still need broader hardware acceptance.
- Next: Run the remaining route matrix on a phone without accessories, output-only wired headphones, and a live headset disconnect/reconnect.

## 2026-08-10

- Progress: Added the call-style output preference and true-device diagnostics. With no accessory, the communication fallback now defaults to `EARPIECE` and switches to `SPEAKER` from the UI; connected accessories remain system-prioritized. Agent text now reaches CoreSpeech TTS automatically, and the engine reports successful PCM synthesis at 16 kHz.
- Impact: Input/output routing now follows the intended phone-call model, but generated text is not yet audible in the current development build. Device logs show the system TTS internal `VOICE_ASSISTANT` player is denied audio focus while the app owns a `VOICE_COMMUNICATION` AudioSession (`ActivateAudioInterrupt Failed`, error `6800301`). This is a regression from adding communication-session ownership around capture/TTS, not a synthesis or Agent-text failure.
- Blockers: Automatic system TTS playback is blocked until system-owned TTS playback is isolated from the app's communication session. Communication-session recovery after forced system deactivation is implemented but still needs a true-device recovery event for acceptance.
- Next: Make the smallest audio-session ownership correction, then verify audible TTS with the microphone both enabled and disabled, confirm the interrupt error is gone, and complete the remaining no-accessory/headset hot-plug route matrix.

## 2026-08-10

- Progress: Applied the smallest CoreSpeech TTS focus correction: system TTS no longer acquires the app-owned communication session, while microphone-owned communication sessions allow mixing with the system `VOICE_ASSISTANT` player.
- Impact: The existing ASR/call-routing path remains intact, and TTS no longer creates or strengthens the `VOICE_COMMUNICATION` focus conflict that produced `6800301`.
- Blockers: Static verification, ArkTS type checking, and HAP assembly pass. No HDC target is connected, so audible playback and device logs remain unverified.
- Next: Install the new HAP on the phone, test automatic TTS with the microphone both enabled and disabled, and confirm `ActivateAudioInterrupt Failed` / `6800301` no longer appears.

## 2026-08-10

- Progress: Finished the Harmony interaction polish: persisted debug-only voice status, actual three-state output display, compact microphone text, centered message times and left/right bubbles, compact process metadata, stale-session recreation, conversation loading UI, reversed header groups, and concrete Provider labels supplied by the Adapter.
- Impact: Normal chat no longer exposes ASR/TTS diagnostics or duplicate timing metadata; history transitions visibly load; missing automatic sessions recover silently; audio output reflects HarmonyOS routing; configured Provider names such as `open1` can replace the generic `custom` label without changing provider semantics.
- Blockers: None in static checks, ArkTS compilation, signed HAP assembly, install, launch, or no-headset UI verification. Connected-headset route switching still needs user-operated hardware acceptance.
- Next: Connect a headset, confirm the icon changes to headset, switch once to speaker and back, then configure the deployed Adapter's `HERMES_*_PROVIDER_LABEL` values.
