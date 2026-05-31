# AGENTS.md — Setup guide for AI coding agents

**You are an AI coding agent** (Claude Code, Cursor, etc.) and your human has asked you to set
up **Doc Narrator** on their Mac and get it running on their iPhone or iPad. Assume the human
may be non-technical: **do everything you can yourself**, run the commands, and only pause for
the steps explicitly marked **HUMAN STEP** (these require an Apple ID, a tap on the physical
device, etc.). After install, walk them through opening the app and adding their first PDF.

Work top to bottom. Verify each step before moving on. Report progress in plain language.

---

## 0. What this is

Doc Narrator is a SwiftUI iOS/iPadOS app that reads PDFs aloud using an on-device neural voice
(Kokoro). The repository contains the entire app **except** the ~330 MB Kokoro model weights
(`model.onnx`), which exceed GitHub's file-size limit. Your main job is: get the toolchain,
clone the repo, supply that one model file, configure signing, and build to the device.

---

## 1. Prerequisites (check; install what's missing)

- **macOS** with **Xcode** installed (from the Mac App Store). Confirm: `xcodebuild -version`.
- **Xcode Command Line Tools**: `xcode-select -p` — if missing, run `xcode-select --install`.
- **git**: `git --version`.
- A **physical iPhone/iPad** is recommended for the on-device voice. The Simulator can build
  and run the app, but test the Kokoro voice on a real device.
- An **Apple ID** for free code signing — **HUMAN STEP** when you reach signing (§4).

---

## 2. Clone the repository

```bash
git clone https://github.com/Yethii/doc-narrator.git
cd doc-narrator
```

(If the human has SSH set up, `git@github.com:Yethii/doc-narrator.git` works too.)

---

## 3. Add the Kokoro model (the one missing file)

The repo already includes the matching `voices.bin`, `tokens.txt`, and `espeak-ng-data/`. You
must add **only** `model.onnx`, and it must be from the **same Kokoro release** as those files
(English `kokoro-en-v0_19`) or the voice will mismatch. Do **not** overwrite the existing files.

```bash
# Download the sherpa-onnx Kokoro (English v0.19) package.
# Verify this asset exists on the sherpa-onnx releases page; if the filename changed,
# pick the "kokoro-en-v0_19" asset under the k2-fsa/sherpa-onnx releases.
curl -L -o /tmp/kokoro.tar.bz2 \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2"

mkdir -p /tmp/kokoro && tar xjf /tmp/kokoro.tar.bz2 -C /tmp/kokoro

# Copy ONLY model.onnx into the app's kokoro folder.
cp "/tmp/kokoro/kokoro-en-v0_19/model.onnx" "Doc Narrator/kokoro/model.onnx"
```

**Verify** the folder now looks like this (model.onnx ≈ 330 MB):

```bash
ls -lh "Doc Narrator/kokoro/"
#   model.onnx   (~330 MB)  ← you added this
#   voices.bin              ← already present, keep
#   tokens.txt              ← already present, keep
#   espeak-ng-data/         ← already present, keep
```

If `model.onnx` is missing, the app still builds and runs — but the Kokoro engine will report
"model not loaded" and only the system/OpenAI voices will work.

---

## 4. Open in Xcode and configure signing

```bash
open "Doc Narrator.xcodeproj"
```

**HUMAN STEP — code signing** (you can't log into their Apple ID for them):
- In Xcode: select the **Doc Narrator** target → **Signing & Capabilities**.
- Tick **Automatically manage signing**.
- Set **Team** to the human's Apple ID. If none is listed, have them add it via
  **Xcode ▸ Settings ▸ Accounts ▸ +**.
- If signing fails on the bundle id, change **Bundle Identifier** to something unique
  (e.g. `com.<theirname>.docnarrator`).

Guide the human through exactly these clicks; wait until signing shows no errors.

---

## 5. Build and run on the device

- Plug in the iPhone/iPad and unlock it. **HUMAN STEP:** tap **Trust This Computer** on the
  device if prompted.
- Find the device id if you want to build from the CLI:
  ```bash
  xcrun xctrace list devices
  ```
- Build & install (replace `<UDID>` with the device id):
  ```bash
  xcodebuild -project "Doc Narrator.xcodeproj" -scheme "Doc Narrator" \
    -destination "id=<UDID>" -configuration Debug build
  ```
  …or just press **Run (⌘R)** in Xcode with the device selected.
- **HUMAN STEP — first launch:** on the device, the app may not open until the developer is
  trusted: **Settings ▸ General ▸ VPN & Device Management ▸** (developer profile) **▸ Trust**.

If the human's device runs an iOS older than the project's deployment target (currently
**iOS 26.4**), lower **IPHONEOS_DEPLOYMENT_TARGET** in the target's build settings and rebuild.

---

## 6. Hand off: tell the human how to use it

Once it's installed, explain (in plain language):

1. **Add a PDF** — open any PDF in the **Files** app (or Safari/Mail) and use **Share ▸ Doc
   Narrator**, or open it directly. It appears in the library.
2. **Open it** — they'll see the real PDF.
3. **Play** — tap play, or **double-tap any sentence** to start reading from there.
4. **Follow along** — the current sentence is highlighted (orange = loading, yellow =
   speaking); the scrubber jumps anywhere; Control Center / lock screen control playback.
5. **Voices** — the default is the on-device Kokoro voice (no internet, private). They can
   switch to the System voice, or to OpenAI (cloud, optional) by entering their own API key in
   **Settings**.

---

## 7. Things to keep in mind

- **Never commit `model.onnx`** — it's git-ignored on purpose (GitHub's 100 MB limit).
- The on-device voice has a one-time warm-up: the **first sentence after launch** takes a few
  seconds while the model loads; later sentences start quickly.
- **Privacy:** in Kokoro / System mode the app makes **no network calls**. Only the optional
  OpenAI engine sends data (the sentence text) off-device, and only when the human enables it
  with their own key. See `README.md` ▸ Privacy.
