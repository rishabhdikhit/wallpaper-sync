#!/usr/bin/env python3
"""
Replaces a system-downloaded aerial with the user's video.
The video it receives MUST ALREADY be in HEVC format (.mov with hvc1 tag).
It only does an atomic copy — no re-encoding.

Usage:
    _set_lockscreen_video.py <video.mov>       # install
    _set_lockscreen_video.py --restore         # restore the original aerial
    _set_lockscreen_video.py --status          # show the status
"""
import os, sys, json, shutil, subprocess, datetime, plistlib, time

os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")

LOG_FILE = os.path.expanduser("~/Library/Application Support/WallpaperSync/logs/engine.log")


def _log_to_file(msg):
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(f"[lockscreen] {msg}\n")
    except Exception:
        pass

AERIALS_DIR = os.path.expanduser("~/Library/Application Support/com.apple.wallpaper/aerials/videos")
MANIFEST_DIR = os.path.expanduser("~/Library/Application Support/com.apple.wallpaper/aerials/manifest")
BACKUP_SUFFIX = ".wallpaper-engine-backup"
STATE_FILE = os.path.expanduser("~/Library/Application Support/WallpaperSync/logs/lockscreen_state.json")


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg):
    print(f"·· {msg}")


def find_downloaded_aerials():
    """Looks for downloaded aerials (.mov) in the system directory."""
    if not os.path.isdir(AERIALS_DIR):
        return []
    results = []
    for f in os.listdir(AERIALS_DIR):
        if f.endswith(".mov") and not f.endswith(BACKUP_SUFFIX) and not f.endswith(".tmp"):
            results.append(os.path.join(AERIALS_DIR, f))
    return results


def get_aerial_id_from_path(path):
    return os.path.splitext(os.path.basename(path))[0]


def load_manifest():
    entries_path = os.path.join(MANIFEST_DIR, "entries.json")
    if not os.path.exists(entries_path):
        return {}
    with open(entries_path) as f:
        data = json.load(f)
    return {a["id"]: a for a in data.get("assets", [])}


def atomic_copy(src, dst):
    """Copies the video, forcing a new inode so macOS doesn't use a stale cache."""
    tmp = dst + ".tmp"
    shutil.copy2(src, tmp)
    if os.path.exists(dst):
        os.unlink(dst)
    os.replace(tmp, dst)


def update_cold_boot_poster(video_path):
    """Generates a static image from the video and saves it to the login screen cache.
    Returns True if the poster was regenerated correctly.
    """
    user = os.environ.get("USER")
    if not user:
        info("warning: $USER is not set, skipping poster")
        _log_to_file("poster: $USER missing")
        return False

    res = subprocess.run(["dscl", ".", "-read", f"/Users/{user}", "GeneratedUID"],
                         capture_output=True, text=True)
    if res.returncode != 0:
        info(f"warning: dscl failed ({res.returncode}): {res.stderr.strip()}")
        _log_to_file(f"poster: dscl failed rc={res.returncode} stderr={res.stderr.strip()}")
        return False

    uuid = res.stdout.split()[-1].strip()
    if not uuid:
        info("warning: dscl did not return a UUID")
        _log_to_file("poster: empty UUID")
        return False

    cache_dir = f"/Library/Caches/Desktop Pictures/{uuid}"
    try:
        os.makedirs(cache_dir, exist_ok=True)
    except OSError as e:
        info(f"warning: could not create cache dir: {e}")
        _log_to_file(f"poster: makedirs failed: {e}")
        return False

    lockscreen_png = os.path.join(cache_dir, "lockscreen.png")
    # Keep the .png extension so ffmpeg infers the correct muxer
    tmp_png = os.path.join(cache_dir, "lockscreen.new.png")

    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        info("warning: ffmpeg is not in PATH, skipping poster")
        _log_to_file("poster: ffmpeg not found in PATH")
        return False

    info("generating poster for cold boot…")
    # Write to a .tmp and then rename — atomic, avoids corrupt posters
    res = subprocess.run(
        [ffmpeg, "-y", "-loglevel", "error", "-i", video_path,
         "-vframes", "1", "-update", "1", tmp_png],
        capture_output=True, text=True
    )
    if res.returncode != 0:
        info(f"warning: ffmpeg failed (rc={res.returncode})")
        _log_to_file(f"poster: ffmpeg rc={res.returncode} stderr={res.stderr.strip()}")
        try: os.unlink(tmp_png)
        except OSError: pass
        return False

    try:
        size = os.path.getsize(tmp_png)
    except OSError:
        size = 0
    if size <= 0:
        info("warning: ffmpeg wrote zero bytes")
        _log_to_file("poster: tmp file empty")
        try: os.unlink(tmp_png)
        except OSError: pass
        return False

    try:
        os.replace(tmp_png, lockscreen_png)
    except OSError as e:
        info(f"warning: could not rename the poster: {e}")
        _log_to_file(f"poster: rename failed: {e}")
        try: os.unlink(tmp_png)
        except OSError: pass
        return False

    # Final check: the final file has the expected size and a fresh mtime
    try:
        st = os.stat(lockscreen_png)
        if st.st_size != size or (time.time() - st.st_mtime) > 60:
            info("warning: the final poster was not updated")
            _log_to_file(f"poster: post-check failed size={st.st_size} expected={size} mtime_age={time.time()-st.st_mtime:.0f}s")
            return False
    except OSError as e:
        _log_to_file(f"poster: final stat failed: {e}")
        return False

    info(f"✓ poster regenerated ({size//1024} KB)")
    _log_to_file(f"poster: ok {size} bytes -> {lockscreen_png}")
    return True


def restart_wallpaper_agent():
    """Restarts the macOS processes so they reload the new video."""
    info("reloading system processes…")
    subprocess.run(["killall", "WallpaperAgent", "WallpaperAerialsExtension"],
                   stderr=subprocess.DEVNULL)


INDEX_PLIST = os.path.expanduser("~/Library/Application Support/com.apple.wallpaper/Store/Index.plist")


AERIALS_APPEX = "WallpaperAerialsExtension.appex"


def _choice_module(c):
    """Return the screen-saver module path referenced by a choice, or ''."""
    cfg = c.get('Configuration')
    if isinstance(cfg, (bytes, bytearray)):
        try:
            return plistlib.loads(cfg).get('module', {}).get('relative', '')
        except Exception:
            return ''
    return ''


def configure_idle_plist(aerial_id):
    """Point the lock screen (Idle) at our aerial. Returns True only if the lock
    screen is ACTUALLY an aerial screen saver we can drive — otherwise the video
    would be swapped into a slot nobody is displaying, so we report failure
    instead of pretending it worked."""
    if not os.path.exists(INDEX_PLIST):
        info("Index.plist not found")
        return False

    try:
        with open(INDEX_PLIST, 'rb') as f:
            d = plistlib.load(f)
    except Exception as e:
        info(f"could not read Index.plist: {e}")
        return False

    matched = False
    for section in ['AllSpacesAndDisplays', 'SystemDefault']:
        idle = d.get(section, {}).get('Idle') if isinstance(d.get(section), dict) else None
        if not idle:
            continue
        for c in idle.get('Content', {}).get('Choices', []):
            prov = c.get('Provider', '')
            if 'screen-saver' not in prov and 'sonoma' not in prov:
                continue
            module = _choice_module(c)
            # Only drivable if the lock-screen screen saver IS the aerials
            # module. If it's some other screen saver (e.g. Word of the Day),
            # we can't make the video appear — bail truthfully.
            if AERIALS_APPEX not in module:
                continue
            c['Configuration'] = plistlib.dumps({
                'module': {'relative': module},
                'selectedID': aerial_id,
                'showAsScreenSaver': True,
            })
            matched = True

    if not matched:
        return False

    try:
        with open(INDEX_PLIST, 'wb') as f:
            plistlib.dump(d, f)
        os.utime(INDEX_PLIST, None)
        info(f"configured aerial {aerial_id} on the lock screen")
        return True
    except Exception as e:
        info(f"could not write Index.plist: {e}")
        return False


def save_state(aerial_path, original_backup):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    state = {
        "aerial_path": aerial_path,
        "original_backup": original_backup,
        "timestamp": datetime.datetime.now().isoformat()
    }
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def load_state():
    if not os.path.exists(STATE_FILE):
        return None
    with open(STATE_FILE) as f:
        return json.load(f)


def cmd_install(video_path):
    """Installs an HEVC video as the lock screen wallpaper."""
    if not os.path.exists(video_path):
        die(f"does not exist: {video_path}")

    aerials = find_downloaded_aerials()
    if not aerials:
        die(
            "no downloaded aerials. Open System Settings → Wallpaper,\n"
            "   download one of the animated wallpapers (e.g. 'Tahoe Day'), and try again."
        )

    manifest = load_manifest()

    # Use the first available aerial
    aerial_path = aerials[0]
    aerial_id = get_aerial_id_from_path(aerial_path)
    aerial_name = manifest.get(aerial_id, {}).get("accessibilityLabel", aerial_id)

    info(f"using aerial slot: {aerial_name} ({aerial_id})")

    # Back up the original if it doesn't exist yet
    backup_path = aerial_path + BACKUP_SUFFIX
    if not os.path.exists(backup_path):
        info(f"saving backup of the original → {os.path.basename(backup_path)}")
        shutil.copy2(aerial_path, backup_path)
    else:
        info("original backup already exists")

    # Atomic copy — the video is ALREADY in HEVC, no conversion
    info("copying video to the system slot…")
    atomic_copy(video_path, aerial_path)

    # Ensure macOS Index.plist points to this aerial for the Idle (lock screen).
    # If the lock screen isn't an aerial screen saver, the swap is invisible —
    # say so instead of falsely reporting success.
    configured = configure_idle_plist(aerial_id)
    if not configured:
        save_state(aerial_path, backup_path)  # so the file swap can still be undone
        die(
            "your lock screen isn't set to an aerial, so the video can't appear there.\n"
            "   Fix it once: System Settings → Wallpaper → pick an animated wallpaper\n"
            "   (e.g. 'Sequoia Sunrise') and turn ON \"Show as screen saver\".\n"
            "   Then run Sync to lock screen again."
        )

    poster_ok = update_cold_boot_poster(video_path)
    restart_wallpaper_agent()

    # Persist the state at the end, once we know what happened.
    # If the poster failed, we still save state but log it for diagnostics.
    save_state(aerial_path, backup_path)
    if not poster_ok:
        _log_to_file(f"install: poster regeneration failed for {video_path}")

    info("✓ lock screen updated" + ("" if poster_ok else " (poster with warnings — see engine.log)"))


def cmd_restore():
    state = load_state()
    if not state:
        die("no saved state to restore")

    aerial_path = state["aerial_path"]
    backup_path = state["original_backup"]

    if not os.path.exists(backup_path):
        die(f"backup does not exist: {backup_path}")

    # Sanity: backup is reasonably large and recognizable as a video by ffprobe
    try:
        backup_size = os.path.getsize(backup_path)
    except OSError as e:
        die(f"cannot read the backup: {e}")
    if backup_size < 64 * 1024:
        die(f"backup looks corrupt or truncated ({backup_size} bytes)")

    ffprobe = shutil.which("ffprobe")
    if ffprobe:
        res = subprocess.run(
            [ffprobe, "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=codec_name", "-of", "csv=p=0", backup_path],
            capture_output=True, text=True
        )
        if res.returncode != 0 or not res.stdout.strip():
            die(f"backup does not look like a valid video (ffprobe: {res.stderr.strip() or 'no stream'})")

    # Atomic copy to the slot
    info("restoring original aerial…")
    tmp = aerial_path + ".restore.tmp"
    try:
        shutil.copy2(backup_path, tmp)
        os.replace(tmp, aerial_path)
    except OSError as e:
        try: os.unlink(tmp)
        except OSError: pass
        die(f"could not restore: {e}")

    restart_wallpaper_agent()
    try:
        os.unlink(STATE_FILE)
    except OSError:
        pass
    info("✓ original aerial restored")


def cmd_status():
    state = load_state()
    aerials = find_downloaded_aerials()
    manifest = load_manifest()

    print(f"downloaded aerials: {len(aerials)}")
    for a in aerials:
        aid = get_aerial_id_from_path(a)
        name = manifest.get(aid, {}).get("accessibilityLabel", "unknown")
        size_mb = os.path.getsize(a) / (1024 * 1024)
        has_backup = os.path.exists(a + BACKUP_SUFFIX)
        status = " [REPLACED]" if has_backup else ""
        print(f"  {name} ({aid}) — {size_mb:.0f} MB{status}")

    if state:
        print(f"\nstate: custom video installed ({state['timestamp']})")
    else:
        print(f"\nstate: using the original system aerial")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    arg = sys.argv[1]
    if arg == "--restore":
        cmd_restore()
    elif arg == "--status":
        cmd_status()
    elif arg == "--help" or arg == "-h":
        print(__doc__)
    else:
        cmd_install(arg)


if __name__ == "__main__":
    main()
