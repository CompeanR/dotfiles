# Mac mini remote availability (Tailscale + Xcode)

Researched 2026-08-13 from Apple/Tailscale docs and a live read of `javiers-mac-mini`. Goal: keep the mini reachable from `dev-vps` so `xcodebuild archive` can sign VerseGuard without sitting at the desk.

## What is already true

Live `pmset -g` on the mini (re-checked 2026-08-13 after setting Lock Screen display-off to Never):

- `sleep 0` — system idle sleep is already off
- `ttyskeepawake 1` — an active SSH TTY already blocks idle sleep ([`pmset(1)`](https://ss64.com/osx/pmset.html) / local `man pmset`)
- `womp 1` — Wake for network access is on
- `displaysleep 0` — display does not sleep (the setting that was missing)
- FileVault is **On**
- GUI user `compean` stays logged in on console and unlocked
- Tailscale + Remote Login work
- `codesign` from SSH succeeded with `Apple Distribution: Javier Compean Rios (3Z3L39546V)`

Screen Sharing is now the unlock hatch: TCP 5900 is listening, `screensharingd` is running, and a Tailscale VNC probe got `RFB 003.889`. File Sharing and Remote Login are not that hatch.

## Three different “available”

| Layer | Needed for | Current |
| --- | --- | --- |
| Overlay network | ping / SSH / Tailscale | Works |
| Remote shell | `git pull`, `npm ci`, prebuild | Works (Remote Login) |
| Code signing | `xcodebuild archive` | Works while GUI stays unlocked (`displaysleep 0`) |

A fourth layer exists after **reboot or power loss**: FileVault pre-boot unlock. SSH does not come back until someone unlocks at the console ([Apple: How FileVault works](https://support.apple.com/guide/mac-help/how-does-filevault-work-on-a-mac-flvlt001/mac)).

## Workaround A — keep the session from locking (best fit here)

FileVault forces a password after sleep or screen saver:

> when you turn on FileVault, you need to enter a password to log in when your Mac wakes from sleep, or after leaving the screen saver.
>
> — [Apple Mac Help: How does FileVault work](https://support.apple.com/guide/mac-help/how-does-filevault-work-on-a-mac-flvlt001/mac)

“Require password: Never” is therefore the wrong lever on this machine. Stop the display/screensaver from starting instead.

On the mini (GUI, while unlocked):

1. **System Settings → Lock Screen → Turn display off on power adapter when inactive → Never**<br>
   ([Apple: Change Lock Screen settings](https://support.apple.com/guide/mac-help/change-lock-screen-settings-on-mac-mh11784/mac))
2. Confirm **Energy → Prevent automatic sleeping when the display is off** stays on<br>
   ([Apple: Change Energy settings](https://support.apple.com/guide/mac-help/change-energy-settings-mchlp1168/mac))
3. Leave the `compean` GUI session logged in. Do not log out.

CLI equivalent (needs admin, run locally on the Mac):

```bash
sudo pmset -a sleep 0 displaysleep 0
```

`sleep` is already 0. `displaysleep 0` is the missing piece.

Optional belt: a LaunchAgent running `caffeinate -dims` so display, idle, disk, and AC-sleep assertions stay taken ([local `man caffeinate`](https://ss64.com/osx/caffeinate.html)). Not required if `displaysleep` is Never.

Cost: both monitors stay powered. Lower brightness if that bothers you. Do not turn FileVault off.

## Workaround B — unlock the keychain from the archive script

Apple’s `security` tool can unlock a keychain over SSH:

```text
security unlock-keychain [-p password] [keychain]
Use of the -p option is insecure
```

(`security unlock-keychain -h` on the mini, 2026-08-13)

CI setups that SSH into a Mac and then `xcodebuild` report that this is what makes `codesign` succeed when a GUI Terminal on the same Mac already works ([Apple Developer Forums: codesign fails from SSH, succeeds in Terminal](https://developer.apple.com/forums/thread/690923); [archive fails with errSecInternalComponent until unlock-keychain](https://developer.apple.com/forums/thread/718411)). Quinn’s parent write-up is [Resolving errSecInternalComponent errors during code signing](https://developer.apple.com/forums/thread/712005).

Also set partition ACLs so `codesign` does not need a GUI “Allow”:

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" \
  ~/Library/Keychains/login.keychain-db
```

(`security set-key-partition-list -h`; discussed in [Apple Developer Forums: why set-key-partition-list](https://developer.apple.com/forums/thread/666107))

Do **not** put the login password in chat or in a world-readable script. Prefer a dedicated signing keychain with its own password file mode `600`, not the login keychain.

This path can sign **while the screen stays locked**. It does not help FileVault-at-boot.

## Workaround C — Screen Sharing as an unlock hatch

Chosen 2026-08-13. Enabled and verified the same day: TCP 5900 accepts Tailscale connections and speaks RFB. Remote Login ≠ Screen Sharing.

Enable it once while the Mac is unlocked ([Apple: Turn Mac screen sharing on or off](https://support.apple.com/guide/mac-help/turn-screen-sharing-on-or-off-mh11848/mac)):

1. Unlock the mini at the keyboard if the lock screen is up.
2. **System Settings → General → Sharing**.
3. If **Remote Management** is on, turn it off (cannot run with Screen Sharing).
4. Click the info button next to **Screen Sharing**, turn **Screen Sharing** on.
5. **Allow access for: Only these users** → `compean`.
6. Leave “VNC viewers may control screen with password” **off**. Built-in Screen Sharing already authenticates as the macOS user; a separate VNC password is weaker.

Do not port-forward 5900 off the tailnet. Connect only via Tailscale.

From another Mac on the tailnet:

```bash
open "vnc://javiers-mac-mini"
# or
open "vnc://100.83.34.54"
```

From iPhone: any VNC client to `javiers-mac-mini` / `100.83.34.54` (TCP 5900). Type the lock-screen password. After unlock, SSH `codesign` should work again.

This is recovery, not unattended availability. If display-sleep is left at 10 minutes, FileVault will lock again. With `displaysleep 0`, this hatch is only needed after a lock, logout, or reboot.

## After a reboot (FileVault)

Planned restart only: `sudo fdesetup authrestart` skips the FileVault unlock **once**. Apple’s man page warns that FileVault protections are reduced for that restart (`fdesetup` `authrestart` on the mini).

Unexpected power loss: someone must unlock at the mini. Then Tailscale + SSH return. Optional: **Energy → Start up after a power failure** (`pmset autorestart`; currently `0` on this mini) so it comes back to the FileVault screen by itself.

Keep Tailscale set to start at login after that GUI login ([Tailscale macOS install / system extension](https://tailscale.com/docs/install/mac), [macos-sysext](https://tailscale.com/docs/concepts/macos-sysext)).

## Recommendation for this mini

Use **A** as the always-on build Mac: never sleep the display, stay logged in, FileVault stays on.

Add **C** so a lock from the iPhone can be cleared over Tailscale.

Use **B** only if you want archives while the screen is locked and are willing to store a keychain password on the Mac.

Do not disable FileVault to make signing easier.
