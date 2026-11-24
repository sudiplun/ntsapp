<div align="center">
  <img src="assets/logo.png" alt="Note Safe Logo" width="160">
  <h1>Note Safe</h1>
  <p><strong>Make Note to Self</strong> — A private, local-first note-taking app with a chat-like interface and end-to-end encrypted cloud sync.</p>
</div>

---

## What is Note Safe?

Note Safe is a note-taking application designed to feel like texting yourself. It combines the speed and simplicity of a messaging app with strict privacy, offline reliability, and seamless multi-device sync.

Most note apps force a compromise: either your thoughts sit unencrypted on somebody else's servers, or privacy-focused tools feel clunky and slow. Note Safe takes a **local-first** approach — your data lives directly on your device in SQLite, works completely offline, and synchronizes across your devices using zero-knowledge end-to-end encryption.

---

## Highlights

- 💬 **Chat-Like Interface**: Capture ideas, thoughts, and reminders in a natural conversational flow. Organize by categories, groups, and date sections.
- 📱 **Local-First & Fully Offline**: Your device is the primary source of truth. The app functions without an internet connection, queuing changes locally until you're back online.
- 🔐 **End-to-End Encrypted**: Built on **Libsodium**. Your master key is derived locally and never sent to any server. Every note, category, group, thumbnail, and media attachment is encrypted before sync.
- 📎 **Rich Media Notes**: Attach images, video clips, voice memos, files, locations, tasks, and contacts (up to 50 MB per file).
- ⚡ **Instant Realtime Sync**: Powered by Supabase Realtime. Edits and new notes appear on your other signed-in devices almost instantly.
- 🖥️ **Cross-Platform**: A single Flutter codebase running on mobile and desktop platforms.

<br/>

<div align="center">
  <img src="graphic/mobile_desktop.png" alt="Note Safe Mobile and Desktop Preview" width="85%">
</div>

<br/>

---

## 📖 Documentation

Everything you need to set up, build, understand, and self-host Note Safe is available in the [`docs/`](docs/) directory:

- [**Getting Started**](docs/getting-started.md) — Prerequisites, environment configuration, and running locally.
- [**Building Note Safe**](docs/building.md) — Using `./build.sh` for Linux desktop and Android release APKs.
- [**Architecture & Security**](docs/architecture.md) — Deep dive into local SQLite storage, Libsodium cryptographic design, and sync mechanics.
- [**Self-Hosting Guide**](docs/self-hosting.md) — Setting up your own backend using Supabase Database, Storage, and Realtime.
- [**Testing**](docs/testing.md) — Running unit and integration test suites.

---

## License

This project is open-source software licensed under the [MIT License](LICENSE).
