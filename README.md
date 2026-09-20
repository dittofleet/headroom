# headroom

A simple menu bar app for your Claude and Codex usage limits.

<img src="docs/menu.png" width="270" alt="The headroom menu">

The menu bar shows one row per provider: how much of the current session
window is used. If any other window (weekly, model-scoped) passes 90%, that
one takes the row instead, since it is the one about to stop you. Rows turn
orange at 75% and red at 90%.

Click for every limit, when each resets, and a pace tick on each bar: the
tick is how far through the window the clock is, so a fill past the tick
means you are burning faster than the window refills.

It does one thing and is simple about it: no login flow, no settings, no
dependencies. It borrows the sessions Claude Code and Codex already have,
shows you the numbers, and otherwise stays out of the way. Being a single
small native binary is a side effect of that.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/dittofleet/headroom/HEAD/install.sh | sh
```

Releases are universal, signed with a Developer ID, and notarized.

This puts `Headroom.app` in `~/Applications`, starts it, and turns on
**Start at Login**. You can switch that off and on from the menu. While it
is on, launchd also brings the app back if it ever crashes; quitting from
the menu keeps it quit until the next login.

If you download `Headroom.zip` from a release instead, open the app and
tick Start at Login yourself. To build from a checkout, run `./install.sh`
inside it (needs the Xcode command line tools).

`./uninstall.sh` removes all of it.

## Updates

headroom keeps itself current. A few times a day it asks GitHub for the
latest release, and when there is a newer one it downloads and installs it
in the background. It never restarts on its own: a dot appears on the icon
and the menu offers "Restart to Update", and the new version also simply
takes over the next time the app starts. "Check for Updates" in the menu
looks right away.

Because this app reads auth tokens, it will not install just anything the
download URL returns. An update must be signed by the same Developer ID
team as the copy already running, be notarized by Apple, carry headroom's
bundle id, and be exactly the newer version that was asked for, so a
tampered, downgraded, or swapped download is refused and the installed
copy stays as it was.

A copy built from a checkout has no signing team to hold an update to, so
it does not update itself: pull and run `./install.sh` again.

To turn the background checks off (the menu item keeps working):

```sh
defaults write io.github.dittofleet.headroom autoUpdate -bool false
```

## Where the numbers come from

headroom has no login of its own. It borrows the sessions you already have:

- **Claude**: the OAuth token Claude Code keeps in the keychain (or
  `~/.claude/.credentials.json`), against the endpoint behind `/usage`.
- **Codex**: the token the Codex CLI keeps in `~/.codex/auth.json`, against
  the endpoint behind `/status`.

Tokens are only ever read, and only sent to the provider they belong to.
headroom never refreshes them, because rotating a refresh token would log
the real tool out. When a token expires, the menu says so and the numbers
come back the next time you use Claude Code or Codex.

The keychain is read through `/usr/bin/security`, which Claude Code's
keychain item already trusts, so there is no password prompt.

## Staying out of trouble

Both endpoints are unofficial, and the Claude one has a very small request
quota. So headroom:

- refreshes every 5 minutes, plus when you open the menu (at most once per
  30 seconds), after wake, and when a window rolls over;
- obeys `retry-after` exactly, even for manual refreshes;
- keeps showing the last good numbers when a refresh fails, dimmed once they
  are over 20 minutes old, with the reason in the menu;
- knows a window that has passed its reset time is at 0% without asking;
- saves its state, so a restart shows numbers instantly and does not forget
  a cooldown;
- refuses to run twice.

## Diagnostics

```sh
~/Applications/Headroom.app/Contents/MacOS/Headroom --print               # fetch once, print as text
~/Applications/Headroom.app/Contents/MacOS/Headroom --render out.png      # draw the menu from cached state (--dark)
```
