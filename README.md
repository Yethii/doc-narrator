# Doc Narrator

Doc Narrator reads your PDFs aloud on iPhone and iPad. It is built around two ideas: a
narrator that sounds like a person rather than a robot, and a default that keeps your
documents on your device.

You open a PDF, see it in its original layout, and the app reads it to you — highlighting
the current sentence, following along with Control Center and lock-screen controls, and
letting you double-tap any sentence to start from there. With the on-device voice, none of
this requires a network connection or an account.

---

## Why it exists

Most "read aloud" tools either sound mechanical, or send your documents to a server to get a
better voice. Doc Narrator's primary mode does neither: it runs a neural text-to-speech model
(Kokoro) entirely on your device, so the audio is natural **and** the document never leaves
your phone.

A cloud option (OpenAI) is available if you want it, but it is strictly opt-in and clearly
scoped — see [Privacy](#privacy).

---

## Features

- **Natural on-device narration.** The default Kokoro voice is a neural model that runs
  locally — closer to a human reader than the classic system speech synthesizer.
- **Reads the real PDF.** You see the original formatted document (columns, figures, math),
  not a stripped-out text dump. The sentence being read is highlighted in place.
- **Tap to start anywhere.** Double-tap a sentence to begin reading from it. A highlight
  shows what's being read; an orange tint means the next sentence is still being synthesized,
  turning yellow once audio begins.
- **Scrub through the document.** A progress bar lets you jump to any point and start reading
  from there, with a live sentence counter.
- **Background playback & system controls.** Audio continues when the app is backgrounded or
  the screen is locked, with play/pause/skip from Control Center and the lock screen.
- **Resumes where you left off.** Each document remembers its last read position.
- **Three voice engines** (see below), switchable per session.

---

## Voice engines

| Engine | Runs | Network | Account | Notes |
|---|---|---|---|---|
| **Kokoro (local)** | On device | None | None | Default. Natural neural voice, fully offline. |
| **System voice** | On device | None | None | Apple's built-in voices. Quality depends on which voice you've installed in iOS. |
| **OpenAI (cloud)** | OpenAI servers | Required | Your API key | Opt-in. Highest-quality voices; sends sentence text to OpenAI. |

You can switch engines from the player. The on-device options never make a network request.

---

## Privacy

Doc Narrator is local-first. Here is exactly what happens to your data:

- **Your documents stay on your device.** PDFs are never uploaded by the app. Reading,
  rendering, text extraction, and (with Kokoro or the system voice) speech synthesis all
  happen locally.
- **No analytics, no tracking, no accounts.** The app collects nothing and phones home to
  no one.
- **The only network traffic the app makes** is to OpenAI's API (`api.openai.com`), and
  **only if** you select the OpenAI engine and provide a key. In that mode, the **text of each
  sentence being read** is sent to OpenAI to generate audio, governed by OpenAI's own data
  policies. Nothing is sent in Kokoro or system-voice mode.
- **Your OpenAI API key is stored in the iOS Keychain**, not in plain preferences. It is
  marked *accessible-when-unlocked, this-device-only*, which means it is readable only while
  the device is unlocked and is excluded from iCloud Keychain sync and from device backups —
  it cannot be restored onto another device. The key is sent only to OpenAI, over HTTPS, as
  the request's authorization header. It is never logged or transmitted anywhere else. You can
  clear it any time by emptying the API Key field in Settings.

If you never touch the OpenAI engine, Doc Narrator makes no network connections at all.

---

## How documents are added (and when a copy is made)

You can add a PDF by opening it from the Files app, or by sending it to Doc Narrator from
another app's share sheet (Safari, Mail, etc.). The app handles these two cases differently,
by design:

- **Opened in place** (e.g. from the Files app or iCloud Drive): Doc Narrator stores a
  *security-scoped bookmark* and reads the file where it already lives. **No copy is made.**
  Removing it from your library does not delete the original.
- **Received via the share sheet / a temporary location** (where the original can't be
  referenced persistently): Doc Narrator **copies** the PDF into its own storage so it remains
  available later. Removing it from your library deletes that copy.

**Deduplication.** The app avoids obvious duplicates:
- In-place files are matched by resolved file path — opening the same file again reuses the
  existing entry.
- Copied files are matched by filename + file size — sharing the same PDF twice won't create a
  second copy.

**When you might still see two entries of the "same" document:** if you both *open it in place*
(from Files) **and** *share it in* (via the share sheet), those arrive through different paths
and are tracked separately, so both can appear. This is intentional — they point at different
underlying files (the original vs. the in-app copy).

---

## Using it

1. **Add a document** — open a PDF from Files, or share one into Doc Narrator from any app.
2. **Open it** — the PDF appears in its original layout.
3. **Play** — tap play, or **double-tap any sentence** to start from there.
4. **Follow along** — the current sentence is highlighted; the view auto-scrolls. Use the
   locate button to jump back to the current sentence.
5. **Navigate** — drag the scrubber to skip anywhere; use Control Center / lock screen for
   background control.
6. **Choose a voice** — switch engines in the player; configure the system voice or OpenAI key
   in Settings.

---

## System requirements

- **iOS / iPadOS 26.4 or later** (current project deployment target; can be lowered if you
  rebuild for older OS versions).
- **On-device Kokoro voice:** the neural model is **~330 MB** and is loaded into memory at
  runtime, plus its phoneme data. A reasonably recent device with sufficient free RAM is
  recommended; the first sentence after launch takes longer while the model warms up. The
  system voice has no such overhead.
- **OpenAI engine (optional):** a network connection and your own OpenAI API key.

---

## Building from source

This repository contains the full app **except the 330 MB Kokoro model weights**, which exceed
GitHub's file-size limit and are not redistributed here.

1. **Clone** and open `Doc Narrator.xcodeproj` in Xcode.
2. **Add the Kokoro model.** Download the sherpa-onnx Kokoro package and place the model file
   so that the bundle's `kokoro/` folder contains:
   ```
   kokoro/
     model.onnx        ← ~330 MB, NOT in this repo — add it
     voices.bin        ← included
     tokens.txt        ← included
     espeak-ng-data/   ← included
   ```
   The other three are already present; you only need to supply `model.onnx`.
   - Upstream model: Kokoro-82M — https://huggingface.co/hexgrad/Kokoro-82M
   - sherpa-onnx ONNX export (the `model.onnx` / `voices.bin` / `tokens.txt` / `espeak-ng-data`
     layout this app expects) is published with the sherpa-onnx project:
     https://github.com/k2-fsa/sherpa-onnx (see its released Kokoro TTS models).
3. **Build & run** on a device. The on-device engine requires the `kokoro/` assets to be in the
   app bundle; without `model.onnx`, the Kokoro engine reports that the model isn't loaded
   (the system and OpenAI engines still work).

> A fresh clone will not run the Kokoro voice until you add `model.onnx`. It is intentionally
> git-ignored so the repository stays a reasonable size.

---

## Tech notes

- SwiftUI app; PDF rendering via PDFKit (`PDFView`), highlight via `PDFAnnotation`.
- On-device TTS via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Kokoro model), with
  synthesis serialized through a Swift actor and the next sentence prefetched during playback
  to minimize gaps.
- System voice via `AVSpeechSynthesizer`; cloud voice via OpenAI's `/v1/audio/speech`.
- Background audio and Control Center / lock-screen integration via `AVAudioSession`
  (`.playback`) and `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter`.

---

## License

The bundled Kokoro assets are distributed under the Apache License 2.0 (see
`Doc Narrator/kokoro/LICENSE`). Add a license for the application code as appropriate before
public distribution.
