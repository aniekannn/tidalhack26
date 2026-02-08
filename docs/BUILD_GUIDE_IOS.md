# HorizonX — Building & Running on a Physical iPhone

## Prerequisites

- **Mac** with Xcode 16+ installed (you have Xcode 26 beta — that works)
- **iPhone** running iOS 17+ (ideally iPhone 14 or later for best ML performance)
- **Apple ID** signed into Xcode (you already have team ID `L2FCZC3SCM`)
- **USB-C or Lightning cable** to connect iPhone to Mac

---

## Step-by-Step: Build & Run

### 1. Open the Xcode Project

```
Open this file in Xcode:
ios/HorizonX/tidalhack26/tidalhack26.xcodeproj
```

You can double-click it in Finder or run:
```bash
open ios/HorizonX/tidalhack26/tidalhack26.xcodeproj
```

### 2. Connect Your iPhone

1. Plug your iPhone into your Mac via USB cable
2. **Unlock your iPhone** (Face ID / passcode)
3. If prompted "Trust This Computer?" on your phone → tap **Trust**
4. In Xcode's toolbar at the top, click the device dropdown (it might say "Any iOS Device")
5. Select **your iPhone** from the list

> If your iPhone doesn't appear, go to **Window → Devices and Simulators** and check it's connected.

### 3. Check Signing (Already Configured)

Your project already has:
- **Team**: `L2FCZC3SCM` (your Apple Developer account)
- **Signing**: Automatic
- **Bundle ID**: `aniekane.tidalhack26`

If you see a signing error:
1. Go to the **tidalhack26** target → **Signing & Capabilities** tab
2. Make sure "Automatically manage signing" is checked
3. Select your team from the dropdown

### 4. Build & Run

1. Press **Cmd + R** (or click the ▶ Play button in Xcode's toolbar)
2. Xcode will compile and install the app on your iPhone
3. **First time only**: Your iPhone will show "Untrusted Developer" alert

### 5. Trust the Developer Profile (First Time Only)

If you see "Untrusted Developer" on your iPhone:

1. On your iPhone: **Settings → General → VPN & Device Management**
2. Under "Developer App", tap your Apple ID / developer certificate
3. Tap **Trust "[Your Name]"**
4. Tap **Trust** again to confirm
5. Go back to the home screen and tap the app icon to launch

### 6. Grant Permissions

When the app launches, it will ask for permissions. **Tap "Allow" for all of these**:

| Permission | Why It's Needed | What Happens If Denied |
|------------|----------------|----------------------|
| **Camera** | Scene narration, obstacle detection | App can't see surroundings |
| **Microphone** | Voice commands | Must use tap gestures instead |
| **Speech Recognition** | Understanding voice commands | Must use tap gestures instead |
| **Location** | Hazard reporting with position | Reports won't have location |

The app speaks "HorizonX ready" once permissions are granted and models are loaded.

---

## What You'll See on Screen

```
┌─────────────────────────────────┐
│  🟢 HorizonX Active            │
│                                 │
│                                 │
│     "Clear path ahead.          │
│      Indoor corridor."          │
│                                 │
│  ⚠️ Recommended action here    │
│                                 │
│     📝 Detected text here       │
│                                 │
│                                 │
│         🎤  (big mic button)    │
│         Tap to speak            │
└─────────────────────────────────┘
```

The screen shows visual feedback for **demo/presentation purposes**, but all information is also spoken aloud. The app is fully usable with eyes closed.

---

## Where Are the Permission Descriptions?

The permission descriptions live in your Xcode project's **build settings**, not in a separate Info.plist file. Your project uses `GENERATE_INFOPLIST_FILE = YES`, which means Xcode auto-generates the Info.plist at build time from build settings.

You can see and edit them in Xcode:

1. Click the **tidalhack26** project in the left sidebar
2. Select the **tidalhack26** target
3. Go to the **Build Settings** tab
4. Search for `privacy` or `INFOPLIST_KEY_NS`
5. You'll see all five permission descriptions:

| Build Setting Key | Value |
|-------------------|-------|
| `INFOPLIST_KEY_NSCameraUsageDescription` | "HorizonX needs camera access to describe your surroundings..." |
| `INFOPLIST_KEY_NSMicrophoneUsageDescription` | "HorizonX needs microphone access for voice commands..." |
| `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` | "HorizonX uses speech recognition to understand..." |
| `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` | "HorizonX uses your approximate location..." |
| `INFOPLIST_KEY_UIBackgroundModes` | `audio location` |

These are already configured in the `project.pbxproj` file — you don't need to add them manually.

### Alternative: If you want a standalone Info.plist

The file `ios/HorizonX/App/Info.plist` has all permissions as a reference. If you ever need a standalone plist:
1. In Xcode, go to target → Build Settings
2. Set `GENERATE_INFOPLIST_FILE` to `NO`
3. Set `INFOPLIST_FILE` to the path of your Info.plist

---

## Troubleshooting

### "iPhone is not available"
- Make sure your iPhone is **unlocked** and the screen is on
- Unplug and replug the USB cable
- In Xcode: **Window → Devices and Simulators** → check iPhone status

### "Untrusted Developer"
- Settings → General → VPN & Device Management → Trust your certificate
- See Step 5 above

### "Could not launch — device locked"
- Unlock your iPhone before pressing Run

### Build errors about concurrency
- The code is written for Swift 6 strict concurrency mode (your project's default)
- All `nonisolated` and `@Sendable` annotations are already in place

### Camera shows black screen
- **You must run on a physical device** — the iOS Simulator has no real camera
- Make sure you tapped "Allow" on the camera permission dialog
- If you accidentally denied: Settings → tidalhack26 → Camera → toggle ON

### No sound / speech
- Check iPhone is not on **Silent Mode** (flip the physical switch on the side)
- Check volume is turned up
- Check: Settings → tidalhack26 → Microphone → ON

### "Vision model failed to load"
- This is expected for the prototype — the VLM mock returns placeholder text
- Camera, TTS, OCR, voice commands, and hazard reporting all still work
- To add a real Core ML model: drop a `.mlmodelc` file into the Xcode project

---

## Demo Tips for Hackathon

1. **Pre-launch the app** before your presentation starts (skip the loading wait)
2. **Turn up iPhone volume** to max so judges can hear the TTS
3. **Point the camera** at different things to trigger scene changes
4. **Say "Read that sign"** while pointing at text to demo OCR
5. **Say "Report a hazard"** to show the civic reporting flow
6. **Switch to the dashboard** (open `dashboard/index.html` on a laptop) to show the full loop
7. **Have a backup**: if live demo fails, describe the architecture with the slides

---

## File Structure in Xcode Project

When you open the project, you'll see this in the Xcode navigator:

```
tidalhack26/
├── tidalhack26App.swift      ← App entry point + AppCoordinator
├── ContentView.swift         ← HorizonXView (main UI)
├── AI/
│   └── VisionPipeline.swift  ← Core ML inference + Vision OCR
├── Camera/
│   └── CameraManager.swift   ← AVFoundation frame capture
├── Speech/
│   └── SpeechEngine.swift    ← AVSpeechSynthesizer TTS
├── Hazard/
│   └── HazardReporter.swift  ← Offline-first hazard queue
└── Assets.xcassets/          ← App icon & colors
```

All files are auto-synced with the filesystem — any new `.swift` file you add to the `tidalhack26/tidalhack26/` folder will automatically appear in Xcode.
