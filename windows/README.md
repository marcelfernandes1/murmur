# Murmur for Windows

Native Windows tray dictation. Hold **Right Ctrl**, talk, then release to insert
your words into the focused app. Speech recognition and optional smart cleanup
run on your PC. No account, API key, transcription server, or audio upload.

## Install

Use `Murmur-Windows-0.1.1-x64-Setup.exe`, then open Murmur from Start.
The installer includes .NET and installs Microsoft's Visual C++ runtime if needed
(Windows may ask for administrator approval for that prerequisite).

For the portable version, extract the **entire** ZIP into a writable folder and
run `Murmur.exe`. If the native speech runtime cannot load, install Microsoft's
[Visual C++ x64 Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe).
Keep the `Cleanup` subfolder and all bundled DLLs beside the application.

Select **Download & prepare** once (default speech model: 148 MB). Model downloads
need internet; dictation works offline after setup. Models have pinned SHA-256
checksums and are fully verified before loading. A canceled or failed download
can be retried and never becomes an active model.

Target: Windows 11, Intel or AMD x64 CPU, microphone, and 8 GB RAM recommended
for larger models and cleanup. The installer also accepts Windows 10 2004 or newer,
but Windows 10 compatibility has not been validated on hardware.
This is an unsigned preview build. Code signing and hands-on hardware acceptance
are required before treating it as a public production release. ARM64-native
packages are not provided; emulation is unverified.

## Use

- Hold Right Ctrl in your destination app, speak, release. Choose Right Shift,
  F8, or F9 in Settings if preferred; that key is reserved while Murmur runs.
- Press Space while holding your shortcut to lock hands-free recording. Release
  the key, keep talking, then press it again or click Done. Esc cancels recording
  or transcription. Recordings finish automatically at ten minutes.
- If you change windows or focused controls before transcription finishes, Murmur
  copies the words instead of bringing an old app forward. The text remains on
  the clipboard after any paste attempt. Apps running as administrator may require
  manual Ctrl+V. Murmur never runs as administrator itself.
- Same-window caret movement is not tracked. Keep the destination selected until
  transcription finishes; automatic paste uses that control's current caret.
- History includes final and original words, search, copy, and clear. Turn history
  off to stop saving future dictations. Existing history remains until cleared.
- Vocabulary accepts up to 100 names/phrases. Very short or quiet recordings avoid
  vocabulary hints to reduce invented prompt words.
- Optional smart cleanup downloads a separate 986 MB model. It runs locally in
  an isolated helper, retains original text on failure or timeout, and rejects
  invented/reordered words or numbers. It deliberately does not convert spoken
  number words to digits. Long takes over 6,000 characters bypass cleanup.
- Failed transcription audio can be retried from the window while Murmur remains
  open. Cancel, starting another take, or quitting discards it. Audio stays in RAM;
  it is never stored as a recording file.
- Closing the window leaves the tray app running. Right-click its tray icon to
  quit. Locking Windows or suspending the PC cancels a recording.

If recording is unavailable, open **Microphone privacy**, enable microphone access
and “Let desktop apps access your microphone,” then select an available input.

Data is local under `%LOCALAPPDATA%\Murmur`: models, `settings.json`, and
`history.json`. History is ordinary local JSON, not encrypted. Uninstalling the
app preserves this folder. Delete it separately to remove saved history/models.

## Build and verify

Install the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).

```powershell
dotnet test windows/Murmur.Tests/Murmur.Tests.csproj -c Release --filter 'Category!=Integration'
dotnet build windows/Murmur.Windows/Murmur.Windows.csproj -c Release
./windows/scripts/publish.ps1
# With Inno Setup 6 installed:
./windows/scripts/publish.ps1 -Installer
```

Builds include .NET, so users do not need the SDK/runtime. The GitHub Actions
workflow builds on Windows, runs behavior/recovery tests plus real whisper.cpp
recognition of the upstream JFK sample. It also installs a signed VB-CABLE driver
on the disposable runner, records prerecorded speech through the real WASAPI
capture service, resamples and transcribes it, and verifies Unicode/text delivery
in Notepad and Chrome. The virtual audio driver is test infrastructure only; it
is never included in Murmur. The workflow opens the packaged WPF app, checks its
accessible setup UI and single-instance activation, and uploads the ZIP, installer,
checksums, test results, and a setup screenshot. Downloads are build artifacts;
the workflow does not publish releases or change the Mac/iOS apps.

To run recognition integration tests, set `MURMUR_TEST_MODELS` to a directory
containing the pinned `ggml-tiny.bin`, and `MURMUR_TEST_WAV` to whisper.cpp's
16 kHz mono PCM `samples/jfk.wav`, then use `--filter 'Category=Integration'`.

Cross-compiling the Windows app from macOS is supported with
`dotnet publish ... -r win-x64 --self-contained true`. WPF and Win32 behavior must
be tested on Windows. The cleanup helper is published separately to `Cleanup/`
so its llama.cpp native dependencies cannot conflict with whisper.cpp's DLLs.

## Scope and hardware acceptance

This first Windows version implements local Whisper, hold-to-talk, hands-free,
microphone selection, a nonactivating waveform, conservative local cleanup,
vocabulary, searchable history, retry, and optional launch at sign-in.
Mac-only engines (Core ML/Parakeet), live partial transcription, automatic learning
from edits, cloud engine options, and Sparkle updates are not ported. Default CPU
recognition favors broad PC compatibility; GPU acceleration is not configured.

Before public release, test real microphone capture (built-in, USB, Bluetooth,
unplug/reconnect), very short holds, hands-free, Esc, Windows lock/sleep, repeated
dictations, language changes, offline startup, and a canceled model download.
Check paste in Notepad, browsers, Office, Electron apps, and an elevated editor;
check switching apps and focused controls during recognition. Verify multi-monitor
placement at mixed DPI, keyboard/screen-reader navigation, history recovery,
installer/uninstaller, and launch at sign-in on clean Windows 10/11 systems.

## Code signing and public release

Trusted signing is not configured yet. The website describes Windows but withholds
the installer link until signing is ready. Do not call these CI builds signed.
The application, cleanup helper, Murmur-owned DLLs, installer, and uninstaller must
be signed using the approved provider; third-party components retain their own
signatures and license notices. Do not sign upstream binaries as Murmur.

After signing, validate the app directory and installer on Windows:

```powershell
./windows/scripts/verify-signatures.ps1 -AppDirectory <signed-app-folder> -InstallerPath <signed-setup.exe> -ExpectedSignerThumbprint <approved-certificate-thumbprint>
```

The check rejects unsigned files, invalid chains, a different publisher, or missing
timestamps. Also install the signed package into a clean temporary directory and
verify the installed binaries and uninstaller. Regenerate the portable ZIP and
SHA-256 checksums from the final signed files. Re-run setup and paste acceptance
on the exact signed package before publishing.

Use a separate Windows tag such as `windows-v0.1.1`, marked **prerelease** and
**not latest**, so `releases/latest/download/Murmur.dmg` and Mac updates still resolve
to the Mac release. Only then replace the website's Windows signing-pending text
with the verified installer URL. See [code signing policy and privacy](../site/windows-signing.html).
