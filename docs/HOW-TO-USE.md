# How to use IINA RAW

IINA RAW plays Nikon raw clips (`.R3D` and `.NEV`) in real time. It is IINA 1.5.1 with our
own decoder inside (`tico_raw`). The app is installed at `/Applications/IINA RAW.app`.

IINA RAW is an unofficial fork of IINA. It is not affiliated with the IINA project. The IINA
code is under the GPL-3.0 licence. See the [README](../README.md) for the licences of all parts.
To build and install the app, follow [`build/README.md`](../build/README.md).

## 1. Open a clip

Use one of these ways:

1. Double-click the clip. IINA RAW is the default app for `.R3D` and `.NEV` files.
2. Right-click the clip. Choose **Open With**, then **IINA RAW**.
3. Drag the clip onto the IINA RAW icon (in the Dock, or in the Applications folder).
4. Open IINA RAW first. Then choose **File > Open…** and pick the clip.

If a double-click opens another app, use way 2 once. Or run `tools/install_iina_raw.sh`
again (see section 5). It sets IINA RAW as the default app again.

IINA remembers where you stopped. The next time you open the same clip, it can start at
that point. To turn this off, open the settings (section 3), go to the **General** page,
and clear **Resume last playback position**.

## 2. What the picture is

- Size: half size, 3030 × 1705 pixels for the ZR test clip. Each pixel comes from one
  group of four sensor sites (2 × 2).
- Colour: Rec.709, full range. The white balance is the one the camera stored with the clip
  (as shot).
- Highlights: bright values roll off softly. They do not clip hard.
- The view is a quick look, not a grade. For the final colour, compare it with a render from
  your grading tool.

Speed on the test Mac (Apple Silicon, M-series): the half view plays at the full 25 fps with
no dropped frame. The app uses several CPU cores while it plays. It holds about 0.6 to 1 GB
of memory.

## 3. Change the view size or the exposure

IINA RAW sets its decoder options before it starts mpv. The built-in value is:

```
view=rec709,view_size=half,thread_type=slice
```

To use another value:

1. Press **Command-comma**. Or open the **IINA RAW** menu (next to the Apple menu) and
   choose **Preferences…**. The settings window opens.
2. Click **Advanced** in the list of pages.
3. Turn on **Enable advanced settings**.
4. In the list **Additional mpv options**, click the **+** button. A new row appears.
5. In the first column (the name), type `vd-lavc-o`.
6. In the second column (the value), type the complete string (see below).
7. Quit IINA RAW (Command-Q) and open it again. mpv reads the option only when it starts.

Your `vd-lavc-o` replaces the whole built-in value. So always write all three parts:
`view=rec709`, `view_size=...` and `thread_type=slice`.

| What you want | Value |
| --- | --- |
| Default (half size) | `view=rec709,view_size=half,thread_type=slice` |
| Full size (6060 × 3410) | `view=rec709,view_size=full,thread_type=slice` |
| Half size, one stop brighter | `view=rec709,view_size=half,thread_type=slice,exposure=1` |
| Half size, one stop darker | `view=rec709,view_size=half,thread_type=slice,exposure=-1` |

- `exposure` is an offset in stops (EV). The range is -8 to 8. The default is 0.
- The full view is slower. On the test Mac it decodes about 16 fps, so it does not play in
  real time (frames drop). Use it to look at one frame, not to watch a clip.
- To go back to the default, select the `vd-lavc-o` row and click the **-** button. Then
  quit IINA RAW and open it again. Or turn off **Enable advanced settings**.
- The same settings window has **Open Log Directory** and **Show Log Viewer** on the
  **Advanced** page. Use the log if a clip does not play.

## 4. Stock IINA stays the same

IINA RAW is a separate app. Its name, its bundle id (`com.alperkaganavci.iina-raw`) and its
settings are its own. The stock `/Applications/IINA.app` and its settings
(`com.colliderli.iina`) are not changed. Keep using stock IINA for normal videos.

IINA RAW never checks for updates and never installs updates. It registers only the
`.R3D` and `.NEV` file types.

You can still open a normal video in IINA RAW (**File > Open…**). But the app applies the
decoder options above to every video. The `view` options mean nothing to other decoders, and
`thread_type=slice` limits their threading. Use stock IINA for normal videos.

## 5. Update or rebuild IINA RAW

Four repositories make the app:

| Repo | Branch | What it holds |
| --- | --- | --- |
| [`alperkaganavci/FFmpeg`](https://github.com/alperkaganavci/FFmpeg) | `tico-raw-9.0` | FFmpeg 9.0.2 with the `tico_raw` decoder |
| [`iina/deps-buildscripts`](https://github.com/iina/deps-buildscripts) | `ee35579d` | build scripts for FFmpeg, mpv and the other libraries (47 dylibs) |
| [`alperkaganavci/iina`](https://github.com/alperkaganavci/iina) | `iina-raw` | the IINA 1.5.1 app code, renamed to IINA RAW |
| `alperkaganavci/nikon-raw-playback` (this repo) | `main` | build script, install script, tests, docs |

The script `build/build-iina-raw.sh` does the whole build in one run. See
[`build/README.md`](../build/README.md). After a decoder change, make a new patch from the
decoder commits (`git diff n9.0.2 tico-raw-9.0`), put it in `build/patches/`, and run the
script again. A full build takes tens of minutes. Run one heavy job at a time.

To install the new app:

1. Quit IINA RAW if it runs.
2. Run:
   ```
   tools/install_iina_raw.sh
   ```
   The script replaces `/Applications/IINA RAW.app` (only an app with the IINA RAW bundle
   id), registers it, enables the Quick Look extensions, and sets IINA RAW as the default app
   for `.R3D` and `.NEV`.
3. Check the result (the test clip is a Nikon ZR `.R3D` clip):
   ```
   CLIP=/path/to/clip.R3D tests/test_playback.sh
   ```
   It plays the test clip with the app's own libmpv and checks the numbers (about 4 minutes).

## 6. Remove IINA RAW

1. Quit IINA RAW.
2. Move `/Applications/IINA RAW.app` to the Bin.
3. Optional: remove the files of IINA RAW. Move these to the Bin:
   - `~/Library/Application Support/com.alperkaganavci.iina-raw`
   - `~/Library/Caches/com.alperkaganavci.iina-raw`
   - `~/Library/Logs/com.alperkaganavci.iina-raw`
   - `~/Library/Preferences/com.alperkaganavci.iina-raw.plist`

Stock IINA is not touched by any of these steps. If a clip then opens with another app, use
**Open With** on the clip and pick the app you want.

## 7. Finder thumbnails and the space-bar preview

Two Quick Look extensions are inside the app (`IINA RAW.app/Contents/PlugIns/`):

- `RawThumbnail.appex` gives Finder a thumbnail of each `.R3D` and `.NEV` clip: a frame from
  10 % into the clip. It takes about 0.3 s per clip.
- `RawPreview.appex` makes the space bar play the clip in the Quick Look preview, at about
  22 to 24 fps and with about 270 MB of memory. The preview pauses when its window is covered
  and stops when it closes.

`tools/install_iina_raw.sh` registers and enables both. If Finder still shows an icon,
enable "IINA RAW Thumbnails" and "IINA RAW Preview" in System Settings, Login Items and
Extensions, Quick Look. Quit and reopen Finder after that.

## 8. Known limits

- Only one ZR test clip (`A015_C004_0706JH.R3D`, R3D NE) was tested as a real clip. Other
  camera modes were not tested.
- The `.NEV` path was tested only with a lossless rewrapped copy of that R3D NE clip (a 10 s
  playback run: 25 fps, no dropped frame). Real N-RAW clips from a camera were not tested.
- The colour is a quick look. Check it against your grading tool before you rely on it.
- The full view (`view_size=full`) does not play in real time (about 16 fps).
- Real-time playback reads about 194 MB/s from the disk (7.75 MB per frame at 25 fps).
  A clip on a slow USB hard disk can stutter, even when the decoder keeps up. Copy the clip
  to the internal SSD.
- IINA RAW ignores `.RMD` sidecar files (exposure, ISO, white balance and tint that you set
  after shooting). A clip with a sidecar can look different in other software.
- The seek-bar thumbnails use the same half-size Rec.709 view as playback. IINA RAW makes
  them in about 5 s per clip. Thumbnails from an earlier build stay in
  `~/Library/Caches/com.alperkaganavci.iina-raw/thumb_cache` and look wrong. Delete that
  folder once to get new ones.
- The clip types are declared as `public.data` and `public.content`, not as `public.movie`.
  macOS sends all `public.movie` types to its own thumbnail extension and would ignore ours.
  So Spotlight searches with "Kind: Movie" do not match these clips.
- The Quick Look extensions need the `disable-library-validation` entitlement, because the
  builds are ad-hoc signed (see [`build/README.md`](../build/README.md)).
- The decoder options apply to every file opened in IINA RAW (see section 4).
- The libraries contain the path of the folder in which they were built. This matters only if
  you share a built app.
