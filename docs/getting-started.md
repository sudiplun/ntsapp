# Getting Started

Welcome to Note Safe! This guide walks you through getting the app running locally on your machine.

---

## What You'll Need

- **Flutter SDK** (version 3.5 or newer) installed and added to your `PATH`.
  - Check with `flutter --version` and `flutter doctor`.
- **Target Platform Setup**:
  - For **Linux Desktop**: standard C++ compiler, CMake, and GTK development libraries (`libgtk-3-dev`, `pkg-config`, etc.).
  - For **Android**: Android Studio with Android SDK and command-line tools.
- A **Supabase** backend (either hosted on [supabase.com](https://supabase.com) or local/self-hosted). See [Self-Hosting Guide](self-hosting.md) if you want to set up your own.

---

## 1. Configure Environment

Note Safe reads its backend configuration at compile-time using Flutter's `--dart-define-from-file`.

Create a file named `.env` in the project root:

```bash
SUPABASE_URL=https://<your-project-id>.supabase.co
SUPABASE_KEY=<your-publishable-or-anon-key>
```

> **Note**: The `.env` file is in `.gitignore` so your keys won't accidentally be committed.

---

## 2. Install Dependencies

Fetch all Flutter packages:

```bash
flutter pub get
```

---

## 3. Run the App

The repository includes a handy helper script:

```bash
./run.sh
```

It gives you a quick menu to choose whether you want to run on a connected mobile/web device or your Linux desktop.

Alternatively, you can run directly with Flutter commands:

### Linux Desktop
```bash
flutter run --dart-define-from-file=.env -d linux
```

### Android / Connected Mobile Device
```bash
flutter run --dart-define-from-file=.env
```

---

## Next Steps

- Want to create standalone release packages? Check out [Building Note Safe](building.md).
- Interested in how encryption and sync work under the hood? Read [Architecture & Security](architecture.md).
- Running your own backend? Follow the [Self-Hosting Guide](self-hosting.md).
