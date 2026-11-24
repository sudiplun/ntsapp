# Building Note Safe

Note Safe comes with a build script (`./build.sh`) that automates creating release builds for Linux and Android with the necessary Dart defines baked in.

---

## Prerequisites

Before building release binaries, make sure:
1. `flutter` is available in your terminal path.
2. Your `.env` file exists in the root directory and defines `SUPABASE_URL` and `SUPABASE_KEY`.

---

## Using the Build Script

Run `./build.sh` followed by the target you want:

```bash
# Build Linux desktop bundle
./build.sh linux

# Build split Android release APKs
./build.sh android

# Build both Linux and Android
./build.sh all

# Clean build cache and temporary output
./build.sh clean
```

### Build Options

- By default, `./build.sh` produces **release** builds.
- If you need a debug build for troubleshooting, add the `--debug` flag:
  ```bash
  ./build.sh linux --debug
  ```
- If you keep different backend configurations in separate files, specify the environment file via `ENV_FILE`:
  ```bash
  ENV_FILE=.env.staging ./build.sh android
  ```

---

## Build Output & Artifacts

Once the build finishes, the script prints an artifact summary with file paths and sizes:

### Linux
- Location: `build/linux/x64/release/bundle/`
- Contains the executable binary, assets, and shared libraries ready to run.

### Android
- Location: `build/app/outputs/flutter-apk/`
- By default, `./build.sh android` builds split APKs per ABI (`arm64-v8a`, `armeabi-v7a`, `x86_64`) to keep download sizes as small as possible.
