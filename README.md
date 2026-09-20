# headroom

Claude and Codex usage limits in the macOS menu bar.

<img src="docs/menu.png" width="270" alt="The headroom menu">

The menu bar shows one row per provider: how much of the current session
window is used. If any other window (weekly, model-scoped) passes 90%, that
one takes the row instead, since it is the one about to stop you. Rows turn
orange at 75% and red at 90%.

Click for every limit, when each resets, and a pace tick on each bar: the
tick is how far through the window the clock is, so a fill past the tick
means you are burning faster than the window refills.

It is a small native app with no dependencies: one Swift binary, about
400 KB, no Electron, no login flow, no settings.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/dittofleet/headroom/HEAD/install.sh | sh
```

Releases are universal, signed with a Developer ID, and notarized.

This puts `Headroom.app` in `~/Applications` and registers a LaunchAgent so
it starts at login and comes back if it ever crashes. Quitting from the menu
keeps it quit until the next login. To build from a checkout instead, run
`./install.sh` inside it (needs the Xcode command line tools).

`./uninstall.sh` removes all of it.

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
