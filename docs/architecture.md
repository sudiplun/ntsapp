# Architecture & Security

Note Safe is built with two fundamental principles in mind: **Local-First** and **Zero-Knowledge Privacy**.

---

## 1. Local-First Approach

In Note Safe, your local device is always the primary source of truth:
- **SQLite Database**: All note text, categories, groups, tags, and settings are saved locally first.
- **Offline Reliability**: You can create, edit, search, and delete notes without any network access. Changes are queued locally and automatically synchronized once internet access is restored.
- **Local Media**: Attachments (photos, videos, voice recordings, documents) are stored directly on the local filesystem.

---

## 2. End-to-End Encryption (E2EE)

Your private data should remain private. Note Safe uses modern cryptographic primitives provided by **Libsodium**:

### The Master Key
When you sign up or create an account, Note Safe derives a high-entropy 256-bit **Master Key** on your device:
- Using a password-derived key via **Argon2id** (`crypto_pwhash`).
- Or via a randomly generated cryptographic access key.
- The master key lives only in device secure storage (`flutter_secure_storage`) and is never sent to the server in plaintext.

### Note Data Encryption
Every note, category, and group row is converted into a structured JSON string and encrypted using Libsodium secret-box encryption (XChaCha20-Poly1305) with unique random nonces before it is uploaded to the backend.

### Media & Attachment Encryption
Binary files (images, audio notes, documents, video clips) are encrypted using chunked streaming encryption (`crypto_secretstream`):
1. A random 256-bit per-file symmetric key is generated.
2. The file is encrypted in 4 KB chunks.
3. The per-file key is encrypted with the user's master key.
4. Only the ciphertext and encrypted key metadata reach the storage bucket.
5. Even if someone intercepts or accesses the cloud storage buckets, they only see meaningless encrypted bytes.

---

## 3. Sync Pipeline

Synchronization coordinates state across all your active devices:

```
[Local SQLite] 
      │  (encrypt)
      ▼
[Pushed to Supabase] ──► [Realtime Event] ──► [Other Devices Notified]
                                                     │  (fetch & decrypt)
                                                     ▼
                                              [Local SQLite]
```

- **Pushes**:
  - Metadata changes (`category`, `itemgroup`, `item`) are sent in batched transactions via edge functions.
  - Thumbnails and binary files are uploaded directly to private storage buckets (`thmbs`, `media`) with strict per-user Row Level Security (RLS).
- **Pulls & Realtime**:
  - Devices listen to an internal `sync_events` table using Supabase Realtime.
  - When another device pushes a change, connected devices receive a lightweight ping and pull the new encrypted changes immediately.
  - A 60-second fallback poll ensures changes are not missed even if the realtime connection drops.
- **Conflict Handling**:
  - The sync engine uses server timestamps (`server_at`) and monotonic cursor tracking. Local updates keep accurate track of modification times so legitimate edits are preserved without overwriting newer remote updates.
