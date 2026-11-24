# Testing Note Safe

Note Safe includes automated test suites covering synchronization logic, media queues, conflict resolution, and database constraints.

---

## Running the Tests

To run the entire test suite:

```bash
flutter test
```

To run a specific test file:

```bash
flutter test test/sync_media_test.dart
```

---

## Test Suites Overview

### `test/sync_media_test.dart`
Tests the media upload and change queue lifecycle:
- Verifies that tasks progress cleanly: `pushMap` → `pushThumbnail` → `pushFile` → completed.
- Ensures editing note text does not accidentally cancel a queued media file upload.
- Checks that internal sync updates (e.g. marking a file downloaded) do not advance the note's `updated_at` timestamp, preventing false clock-drift conflicts.

### `test/sync_pipeline_test.dart`
Tests synchronization ordering and networking resilience:
- Verifies pull cursor semantics (rows pushed concurrently while a pull is running are captured in subsequent cycles).
- Ensures pulls execute before heavy file uploads so incoming notes appear immediately.
- Confirms network availability detection operates cleanly without arbitrary socket probes.

### `test/sync_repro_test.dart`
Tests database consistency under real-world sync scenarios:
- Verifies foreign-key integrity when notes arrive before their parent group is created locally (ensuring placeholder groups prevent sync aborts).
- Checks category and group upsert idempotency.
