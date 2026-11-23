# MySteno

**Fast, accurate, private dictation for your Mac.** Press a shortcut, speak, press it again, and your words appear wherever you're typing. Everything runs on your Mac. No account, no subscription, no internet needed after setup, and nothing you say ever leaves your computer.

## Why MySteno

- **It's fast.** Your text appears in a fraction of a second. 25 seconds of speech is transcribed in under 0.2 seconds.
- **It's accurate.** MySteno uses the best on-device speech models available, so you spend less time fixing mistakes, even when you talk quickly.
- **It's private.** Your voice is processed in memory on your Mac. No recordings are saved, nothing is uploaded, and there is no analytics or telemetry.
- **It works everywhere.** Dictate into any app: email, documents, chat, code editors, the browser.
- **It stays out of the way.** MySteno lives in the menu bar, uses no CPU while idle, and needs just 100–175 MB of memory.
- **It transcribes files too.** Choose a WAV, M4A, MP3, AIFF, or CAF recording and get a text file back.

## Two modes

| Mode | Model | Best for | Speed on an M5 Pro |
| --- | --- | --- | --- |
| **Speed** (default) | NVIDIA Parakeet Unified EN 0.6B | Everyday dictation | ~145× real time |
| **Accuracy** | Cohere Transcribe 03-2026 | Noisy audio, difficult recordings | ~6× real time (about 1.5 s per dictation) |

Speed is the right choice for almost everyone. Accuracy runs Cohere Transcribe, which led Hugging Face's Open ASR Leaderboard across diverse speech benchmarks, giving it an edge on heavy accents, background noise, and challenging real-world recordings where clean studio benchmarks don't tell the full story.

## Benchmarks

Measured on an Apple M5 Pro (macOS 27) with [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.4 on LibriSpeech.

| Engine | Test set | Word error rate | Throughput |
| --- | --- | ---: | ---: |
| Speed - Parakeet Unified (int8, batch) | test-clean, all 2,620 files | **1.71%** | 147× |
| Speed - Parakeet Unified (int8, batch) | test-other (noisy), all 2,939 files | **3.18%** | 140× |
| Accuracy - Cohere Transcribe (q8) | test-clean, 300 files | **2.18%** mean per file | 6.1× |

On clean audio (`test-clean`), both models perform nearly identically per file (2.20% vs. 2.18% mean per-file WER), while Cohere's larger encoder-decoder architecture provides stronger resilience on noisy or heavily accented speech. In FluidAudio's own same-harness comparison, Parakeet Unified also makes about **17% fewer errors** than Parakeet TDT v3, FluidAudio's default Parakeet model (2.16% vs. 2.6% mean per-file WER on `test-clean`), and writes punctuation and capitalization natively without a separate clean-up pass.

## Requirements

- Apple silicon Mac running macOS 26.0 or later
- 16 GB of memory or more recommended for Accuracy mode
- About 600 MB of disk for Speed, plus about 2.2 GB for Accuracy

## Install

Download the latest build from [Releases](../../releases) (available soon), or [build from source](#build-from-source).

1. Unzip `MySteno.zip` and move `MySteno.app` to `/Applications`.
2. Open it. A welcome window walks you through setup while the Speed model downloads: allow the microphone, then turn on MySteno under **Accessibility** so the shortcut works in every app and MySteno can paste for you. Each step ticks off by itself, and you can try a dictation right there.
3. MySteno then lives in the menu bar, not the Dock. To see the welcome window again, choose **Setup Guide…** from the MySteno menu.

If macOS says the app can't be opened because the developer can't be verified, open **System Settings → Privacy & Security** and click **Open Anyway**.

## Use

**Dictate**

1. Click into any text field.
2. Press `⌃⌥T` (Control-Option-T) and speak.
3. Press `⌃⌥T` again. Your text is pasted where you were typing.

The menu bar icon turns into a timer while you record. Your last 10 dictations are under **Transcript History** in the menu; click one to copy it. If your Mac goes to sleep while you're recording, MySteno still transcribes what you said and adds it to Transcript History.

**Choose a microphone**

Pick one under **Microphone** in the MySteno menu. **System Default** follows the input selected in System Settings.

**Transcribe a file**

Choose **Choose Audio File…** from the menu. The first time, pick a folder for transcripts (for example `~/Documents/MySteno Output`). Each file becomes a UTF-8 text file with the same name, and existing files are never overwritten (`interview.txt`, `interview-2.txt`, …).

**Preferences**

- **General:** launch at login, transcript output folder
- **Transcription:** default mode, maximum recording length (30 minutes by default), install or remove models
- **Shortcut:** change or reset the global shortcut

## Privacy

- Audio is captured and processed in memory. Dictation never writes audio to disk.
- The network is used only to download model files from Hugging Face.
- Transcripts go only to the app you're typing in or the folder you choose. Pasting briefly uses the clipboard, then puts back what you had copied.
- Transcript History stays in memory and is cleared when MySteno quits. Notifications never contain transcript text.

## Troubleshooting

- **The shortcut does nothing or nothing is pasted.** Choose **Setup Guide…** from the MySteno menu and check that Accessibility is ticked. If MySteno is turned on in System Settings but still doesn't work (this can happen after replacing the app), run `tccutil reset Accessibility dev.guptadhruv.mysteno`, reopen MySteno, and allow it again.
- **Nothing is transcribed, or the wrong microphone is used.** Check **System Settings → Privacy & Security → Microphone**, and the **Microphone** choice in the MySteno menu.
- **Reporting a bug.** Include the logs from right after the problem:

  ```sh
  /usr/bin/log show --last 15m --info --style compact --predicate 'subsystem == "dev.guptadhruv.mysteno"'
  ```

## Uninstall

1. Turn off **Launch MySteno at login** in Preferences, then quit MySteno.
2. Delete `MySteno.app`.
3. Delete `~/Library/Containers/dev.guptadhruv.mysteno` (in Finder, **Go → Go to Folder…**). This removes the downloaded models (about 600 MB for Speed, plus about 2.2 GB for Accuracy) and MySteno's settings.
4. Optionally, remove MySteno from **Microphone** and **Accessibility** in **System Settings → Privacy & Security**.

## Build from source

Requires Xcode 27 or later on an Apple silicon Mac.

1. Clone this repository and open `MySteno.xcodeproj`.
2. Under **Signing & Capabilities**, choose your own team. If Xcode says the bundle identifier isn't available, change it to one of your own, such as `com.yourname.mysteno`.
3. Choose **Product → Run**.

Swift Package Manager fetches the one dependency, [FluidAudio](https://github.com/FluidInference/FluidAudio), automatically.

## License

MySteno's code is released under the [MIT License](LICENSE). The speech models are not part of this repository and keep their own licenses: NVIDIA Parakeet Unified EN 0.6B is under the [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/), and Cohere Transcribe 03-2026 is under Apache 2.0. MySteno downloads Core ML conversions of both published by FluidInference on Hugging Face.