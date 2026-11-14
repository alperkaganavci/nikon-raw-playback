# Build and install IINA RAW

This folder builds IINA RAW, the IINA-based player for Nikon raw clips, from public sources.
The build runs on an Apple Silicon Mac (arm64). It does not need anything that is not in a
public repository.

Only want to use the app? Get the installer from the
[latest release](https://github.com/alperkaganavci/nikon-raw-playback/releases/latest) instead.

| I want to... | Go to |
| --- | --- |
| Build and install the app | [Build and install in one step](#build-and-install-in-one-step) |
| Make an installer DMG from a built app | [Make an installer DMG](#make-an-installer-dmg) |
| Build only the decoder, for the checks | [Only the decoder](#only-the-decoder-an-ffmpeg-build-for-the-checks) |
| Fix a problem | [Problems](#problems) |

## What you need

- A Mac with Apple Silicon and a current macOS.
- Xcode, with the command line tools (`xcode-select --install`). Open Xcode once so that it
  accepts its licence.
- [Homebrew](https://brew.sh) and these packages:

  ```
  brew install meson ninja pkg-config automake nasm libtool cmake
  ```
- `git`, `perl` and `python3` (they come with the macOS command line tools).
- Network access. The build downloads library sources and Swift packages.
- Free disk space for the sources and the build (several GB) and time: the first run takes
  tens of minutes.

## Build and install in one step

From the root of this repository:

```
build/build-iina-raw.sh
```

The script asks for nothing. It does these steps:

1. Checks the tools (`git meson ninja pkg-config aclocal glibtoolize nasm cmake perl python3
   xcodebuild xcrun`) and stops with a list of what is missing.
2. Clones [`iina/deps-buildscripts`](https://github.com/iina/deps-buildscripts) at commit
   `ee35579d` into `build/work/deps-buildscripts`. It applies
   `build/patches/deps-buildscripts.patch` (one line: `JOBS` can come from the environment) and
   copies `build/patches/ffmpeg-9.0.2-tico_raw.patch` into `patches/ffmpeg/`. The deps build
   applies that patch to the FFmpeg 9.0.2 source. The patch is the `tico_raw` decoder, the
   same as `git diff n9.0.2 tico-raw-9.0` in the
   [FFmpeg fork](https://github.com/alperkaganavci/FFmpeg).
3. Builds the libraries: `./build.sh arm64`, then `./fix-install-names.sh arm64`, then
   `./copy-headers.sh`. The result is in `build/work/deps-buildscripts/output/`.
4. Clones the [IINA fork](https://github.com/alperkaganavci/iina) (branch `iina-raw`) into
   `build/work/iina`. It copies the libraries to `deps/lib` and the headers to `deps/include`.
5. Builds the app with `xcodebuild` (Release, arm64, ad-hoc signed). The log is
   `build/work/xcodebuild.log`.
6. Runs `tools/install_iina_raw.sh`. It copies the app to `/Applications/IINA RAW.app`,
   registers it, enables the Quick Look extensions and sets IINA RAW as the default app for
   `.R3D` and `.NEV` clips.

These environment variables change the script. All are optional.

| Variable | Default | Meaning |
| --- | --- | --- |
| `WORK` | `build/work` | Folder for the clones and the build output |
| `JOBS` | `4` | Parallel jobs of the library build. More jobs need more memory. Run no other heavy job at the same time. |
| `REBUILD_DEPS` | `0` | `1` builds the libraries again, even when a finished build exists. Use it after you change a patch. |
| `NO_INSTALL` | `0` | `1` builds the app and stops. It does not touch `/Applications`. |
| `CLIP` | not set | Path of a Nikon ZR `.R3D` clip. When set, the script checks after the library build that FFmpeg opens the clip with the `tico_raw` decoder. |

Example: build with 6 jobs and do not install:

```
JOBS=6 NO_INSTALL=1 build/build-iina-raw.sh
```

Install later with:

```
tools/install_iina_raw.sh "build/work/iina-derived/Build/Products/Release/IINA RAW.app"
```

## The same steps by hand

Use these commands if you want to run the steps one by one. They do the same as the script.

```
mkdir -p build/work && cd build/work

# libraries
git clone https://github.com/iina/deps-buildscripts
cd deps-buildscripts
git checkout --detach ee35579ded3ea95d839d85c2686d96dc505ee344
git apply ../../patches/deps-buildscripts.patch
mkdir -p patches/ffmpeg
cp ../../patches/ffmpeg-9.0.2-tico_raw.patch patches/ffmpeg/0001-ticoraw.patch
JOBS=4 ./build.sh arm64
./fix-install-names.sh arm64
./copy-headers.sh
cd ..

# app
git clone --branch iina-raw --single-branch https://github.com/alperkaganavci/iina
mkdir -p iina/deps/lib iina/deps/include
cp deps-buildscripts/output/arm64/*.dylib iina/deps/lib/
cp -R deps-buildscripts/output/include/. iina/deps/include/
cd iina
xcodebuild -project iina.xcodeproj -scheme iina -configuration Release -arch arm64 \
  -derivedDataPath ../iina-derived CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
cd ../../..

# install
tools/install_iina_raw.sh "build/work/iina-derived/Build/Products/Release/IINA RAW.app"
```

## Make an installer DMG

`build/make-dmg.sh` turns a built `IINA RAW.app` into a DMG that you can share. Run it after
the build (use `NO_INSTALL=1` if you only want the DMG):

```
build/make-dmg.sh --app "build/work/iina-derived/Build/Products/Release/IINA RAW.app" \
  --version 1.5.1-raw.1 --out build/dist
```

| Option | Meaning |
| --- | --- |
| `--app <path>` | The built `IINA RAW.app`. The script copies it and does not change the original. |
| `--version <ver>` | The version for the DMG name, for example `1.5.1-raw.1`. |
| `--out <dir>` | The folder for the finished DMG. |
| `--scrub-prefix <path>` | A local build folder to remove from the binaries. You can give this option more than once. |

The script does these steps:

1. Copies the app.
2. Replaces each `--scrub-prefix` path in the binaries with a neutral path of the same length.
   The libraries keep the path of the folder in which they were built, and this step removes
   it from a shared app.
3. Signs the app again, ad hoc.
4. Checks the result.
5. Builds the DMG with a link to **Applications**.

The DMG is ad-hoc signed and not notarized. A user who installs it must allow the first
launch (**System Settings → Privacy & Security → Open Anyway**, or
`xattr -dr com.apple.quarantine "/Applications/IINA RAW.app"`). See the main
[README](../README.md), section "Install".

## Signing and the Quick Look extensions

The build is ad-hoc signed (`CODE_SIGN_IDENTITY=-`), so it needs no Apple developer account.
The app and its Quick Look extensions (`RawThumbnail.appex`, `RawPreview.appex`) load the
libraries that sit inside the app. These libraries are ad-hoc signed too, and macOS library
validation allows only libraries with the same team id or from Apple. So the two extensions
carry the `com.apple.security.cs.disable-library-validation` entitlement. The entitlement
files are in the IINA fork (`RawThumbnail/RawThumbnail.entitlements` and
`RawPreview/RawPreview.entitlements`). The extensions run in the app sandbox.

If Finder shows no thumbnail after the install, enable "IINA RAW Thumbnails" and
"IINA RAW Preview" in System Settings, Login Items and Extensions, Quick Look. Quit and reopen
Finder.

## Only the decoder: an FFmpeg build for the checks

The decoder checks (`tests/decoder_checks.sh`) need a small out-of-tree FFmpeg build with the
`tico_raw` decoder and its test program:

```
git clone --branch tico-raw-9.0 --single-branch https://github.com/alperkaganavci/FFmpeg
mkdir ffmpeg-build && cd ffmpeg-build
../FFmpeg/configure --disable-doc --disable-everything \
  --enable-decoder='tico_raw,pcm_f32le,rawvideo' --enable-demuxer=mov \
  --enable-muxer='rawvideo,framemd5,null' --enable-encoder='rawvideo,wrapped_avframe' \
  --enable-protocol='file,pipe' \
  --enable-filter='null,anull,format,aformat,scale,select,trim,atrim' \
  --enable-ffmpeg --enable-ffprobe
make -j4
make libavcodec/tests/ticoraw
```

Then run the checks with a Nikon ZR clip and the reference files (see the main
[README](../README.md), section "Run the tests"):

```
FFMPEG_BUILD=$PWD CLIP=/path/to/clip.R3D ../nikon-raw-playback/tests/decoder_checks.sh all
```

The `master` based branch is `tico-raw`. It builds the same way.

## Problems

| Symptom | Fix |
| --- | --- |
| `missing tools: ... glibtoolize` | `brew install libtool`. The `zimg` package needs it. |
| The library build stops at a package | Read the last lines of its output, fix the cause and run the script again. |
| `xcodebuild failed` | Read `build/work/xcodebuild.log`. Check that Xcode is selected: `xcode-select -p`. |
| The app opens clips with another app | Run `tools/install_iina_raw.sh` again, or use **Open With** once. |
| A clip does not play | Open the log in IINA RAW: **Settings > Advanced > Show Log Viewer**. |

## Status of this build

The full build script has **not yet been run end to end on a clean machine**. Its parts were
checked one by one (syntax, patches, the tool list), and the same steps were run by hand
during development. If a step fails for you, please open an issue and include the last lines
of the output and of `build/work/xcodebuild.log`.

## Notes

- `build/patches/deps-buildscripts.patch` has only our own change (one line). The
  `iina/deps-buildscripts` repository has no licence file, so this repository holds no copy
  of its files.
- IINA RAW is built from IINA 1.5.1 (GPL-3.0). The libraries are built from the sources that
  the deps build downloads. Their licences apply to them.
