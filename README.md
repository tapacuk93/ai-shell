# AI Shell

A macOS menu-bar app with two halves: a field where you type what you want your Mac to do —
*“close all windows but IntelliJ”* — and a **⌘-click** that explains the word under your
pointer in a — including inside TUIs like [Claude Code](https://claude.com/claude-code).

The popup shows one thing: Claude reading that word *in the context currently on your screen*.
Not a dictionary entry that ignores where you are — what the word means, and what it is doing
in this command, on this line, in this error.

```
┌───────────────────────────────────────────┐
│ rsync                  CLAUDE claude-opus │
│                                           │
│ Remote SYNC: here it is copying build     │
│ output to the staging host, sending only  │
│ the parts that changed rather than the    │
│ whole tree. --delete would also remove    │
│ files there that no longer exist locally. │
└───────────────────────────────────────────┘
```

## The field

Click the menu-bar icon and type. A question is answered in place; a command comes back as a
one-line summary plus the script that would carry it out (AppleScript, or zsh when that is the
natural fit), and **↩** again runs it. Nothing runs until you have seen it. Editing the line
throws the plan away.

Claude is told which apps are running and which one was in front, so *“intellij”* resolves to
IntelliJ IDEA and *“close”* means closing windows, not quitting. Windows are closed through
System Events UI scripting, which works on apps with no scripting dictionary.

**Permissions are asked for when they are first needed**, not at launch. Scripts run as child
processes of the app, so macOS shows its *“AI Shell wants to control …”* prompt the first time
a command touches each app. Closing windows needs Accessibility, and the dialog for it comes up
the first time a command fails for want of it. Once a prompt has been answered *no*, only
System Settings can change it, and the error says which pane.

**Every command that runs is saved, script and all**, under *Recent*. Clicking one runs its
saved script again straight away, and typing a line that has run before brings its script back
without asking Claude, so a scriptable action is only ever planned once. *Set shortcut* on a
row records a global key combination (it needs ⌘, ⌃ or ⌥; ⌫ clears it, Esc cancels) that runs
the command from anywhere, popover closed; only a failure opens it. Claude is told its scripts
will be replayed, so it writes them to find windows and processes at run time instead of
naming the ones open when it was asked. Shortcuts go through Carbon's `RegisterEventHotKey`,
which needs no permission. Rows with a shortcut are never pushed out of the 30-item history.

A **Shortcuts** card sits above the field until you close it; the ✦ icon in the field brings it
back. The gear, or a right-click on the menu-bar icon, opens the settings.

Commands use `claude-opus-5-5` at low effort with structured output, and the server-side
refusal fallback.

## The gesture

⌘-click a word. The app reads the word straight out of the terminal's accessibility text
(`AXRangeForPosition` → `AXStringForRange`) rather than selecting it, which matters more than
it sounds:

- **It works inside TUIs.** Programs like Claude Code, vim and htop turn on mouse reporting,
  so the terminal forwards clicks to the program instead of selecting text. Anything based on
  synthesizing a double-click finds nothing there.
- **It disturbs nothing.** Your existing selection is untouched, no clipboard round-trip, and
  the mouse pointer doesn't get hidden.

A synthetic-double-click fallback covers terminals that don't answer those queries.

The same ⌘-click works **inside the popup itself** — click any word in Claude's answer to
look that one up, without going back to the terminal. The panel keeps its
position and the screen context it was opened with.

The panel is **draggable** — pull it by its background or header to move it aside. Dragging
starting on the answer selects text instead, since it stays selectable. The next lookup opens a fresh panel at the pointer.

**⌘+ / ⌘−** resize the popup while it's open, and the size is remembered. Those two keys are
swallowed while the panel is showing, so the terminal doesn't zoom its own font at the same
time; everywhere else they behave normally.

One caveat: Terminal.app opens paths and URLs on ⌘-click, and a global monitor can't suppress
that. ⌘-clicking a path may open it in Finder. Plain words are unaffected.

## What it explains

Claude is given the word, the line it came from, and two and a half thousand characters of
*what is on the terminal screen* around it, and answers in 2–4 sentences. What the word is and
what it is doing here come as one explanation rather than a definition with a “here it is…”
sentence bolted on: the meaning is carried through the command it belongs to, the flag it
modifies, the error it appears in. If the screen shows an interactive **Claude Code** session,
the app detects that and says so, and slash commands, permission modes and status-line
elements are read in that light.

A built-in glossary of ~190 CLI commands, shell builtins and terminal abbreviations (`awk`,
`stdout`, `SIGTERM`, `rc`, `inode`, …) is passed along as a reference gloss when it has an
entry. It is a table lookup, so it grounds the answer without delaying the request.

**Declined requests.** The safety classifiers judge the request as a whole, and a terminal
screen can carry security-shaped text — a pentest tool's output, an exploit in a file being
edited, a log full of auth failures — that the clicked word has nothing to do with. Rather than
give up on the context, a refusal is retried, in two stages.

First the window grows where it stands, doubling each time: 5k, 10k, then 20k characters. A
window that stops mid-exchange is the one most easily mistaken for the text around it, so the
first answer to a decline is *more* context rather than older context.

Then, once it has stopped growing, the window starts walking backwards, each rung twice as far
back as the last: 60k, 120k, then 240k characters. The text either side of the current window
is skipped, since it is usually a continuation of the same work and carries whatever got the
request declined. Whichever window answered is named in the header (`24k chars earlier`), since
an answer read off older scrollback looks identical to one read off the current screen. If
every rung is declined, the offline definition stands in.

How far the ladder actually reaches depends on the terminal: it can only climb through the text
the Accessibility API exposes, and some terminals hand over the visible screen and nothing more.

**When there is no answer to show** — no API key, *Explain with Claude* turned off, or a failed
request — the panel falls back to an offline definition rather than nothing: the glossary, then
`whatis` for anything with a man page, the macOS Dictionary for ordinary English words, `which`,
and shape-based guesses for paths, flags and environment variables. A failed request shows the
reason underneath.

Other words on the clicked line appear as chips at the bottom of the panel — click one to
look it up without touching the terminal again.

## Build and run

```sh
./build.sh
open build/AIShell.app
```

Requires the Xcode Command Line Tools (Swift 5.9+). Output: `build/AIShell.app`,
bundle ID `com.oeaio.aishell`.

## Permissions

Nothing is asked for at launch. ⌘-click lookups need **Accessibility** (System Settings →
Privacy & Security → Accessibility) to observe the click, read the selected text and read the
terminal window's contents: choose **Enable ⌘-click lookups…** in the settings menu, or let a
window-closing command bring the dialog up. The app polls for the grant, so you don't need to
relaunch it. **Automation** prompts come up per app, the first time a command scripts it.

The bundle ID changed from `com.oeaio.termdefine` to `com.oeaio.aishell` with the rename, so
an Accessibility grant for the old app doesn't carry over; a key pasted into the old app is
moved to the new Keychain entry on first read.

The build is ad-hoc signed so the permission grant survives rebuilds.

## API key

The Claude layer looks for `ANTHROPIC_API_KEY` (or `ANTHROPIC_AUTH_TOKEN`) in:

1. the process environment
2. a key you pasted into the app, held in the Keychain
3. `~/.zshrc`, `~/.zshenv`, `~/.zprofile`, `~/.zlogin`, `~/.bash_profile`, `~/.bashrc`,
   `~/.profile` — the last `export ANTHROPIC_API_KEY=…` assignment wins

A GUI app doesn't inherit your shell environment, which is why the rc files are read directly.
Indirect assignments (`ANTHROPIC_API_KEY=$SOMETHING`, `$(op read …)`) are skipped.

If nothing is found on launch, the app offers a dialog to paste a key (once — after that use
**Set API key…** in the menu). A pasted key outranks the shell files, since pasting is a
deliberate act and a forgotten rc export shouldn't shadow it. It goes into the Keychain rather
than a preferences plist, which any process running as you could read. **Remove pasted key**
deletes it; **Reload API key** re-reads all sources after you edit a shell file.

Because the app is ad-hoc signed, its signature changes on every rebuild, so macOS may ask you
to allow Keychain access again after `./build.sh`. Allow it once per build.

Without a key the app still answers, but from the offline chain only — see *What it
explains* above.

Requests go to `POST /v1/messages` with `claude-opus-5`, thinking disabled at `low` effort and
`max_tokens: 600`, which is what keeps a popup answer under a couple of seconds.

## Menu options

| Item | Effect |
|---|---|
| Enabled | Master switch |
| Terminal apps only | Only react in Terminal, iTerm2, Warp, kitty, Alacritty, WezTerm, Ghostty, Hyper, … (on by default, so the gesture is inert in other apps) |
| Use ⌘C when needed | Allows the clipboard fallback when a terminal doesn't expose its selection over the Accessibility API. The previous clipboard contents are restored |
| Explain with Claude | Off falls the panel back to offline definitions only |
| Show input in menu bar | The menu-bar item reads as a field (✦ e.g. close all windows) instead of a bare icon; clicking it opens the popover with the field focused. On by default |

The menu opens from the gear in the popover, or by right-clicking the menu-bar icon.

## Dismissing the panel

Click outside it, or press Esc. It has no timeout, and typing or scrolling in the terminal
leaves it alone — so it can sit there while you keep working.

## Layout

| File | Role |
|---|---|
| `Sources/ClickWatcher.swift` | Global mouse-down monitor; fires on ⌘-click, ignores ⌘-drags |
| `Sources/WordAtPoint.swift` | Reads the word under the pointer from the terminal's accessibility text |
| `Sources/SelectionReader.swift` | Fallback: synthetic double-click, selection via Accessibility or ⌘C with clipboard restore |
| `Sources/TerminalContext.swift` | Captures the visible screen; detects a Claude Code session |
| `Sources/Tokenizer.swift` | Strips prompt decoration and picks the interesting token from a line |
| `Sources/Glossary.swift` | The built-in command/abbreviation table |
| `Sources/Lookup.swift` | The reference gloss, and the offline fallback chain |
| `Sources/ClaudeClient.swift` | Raw-HTTP Messages API client (Swift has no official SDK) |
| `Sources/DefinitionPanel.swift` | The floating non-activating panel, and its ⌘+/⌘− scaling |
| `Sources/ScaleHotkeys.swift` | Event tap that claims ⌘+/⌘− while the panel is open |
| `Sources/ApiKey.swift`, `Keychain.swift` | Key discovery and Keychain storage |
| `Sources/ShellPopover.swift` | The menu-bar popover: the field, the shortcuts card, plan and run |
| `Sources/ShellCommand.swift` | Turns a typed line into an answer or a script, and runs it |
| `Sources/ShellHistory.swift` | Saved commands and their scripts, kept in UserDefaults |
| `Sources/GlobalHotKeys.swift` | Global shortcuts for saved commands, and recording them |
| `Sources/AppDelegate.swift` | Menu bar, permissions, orchestration |

## Troubleshooting

The menu's first line tells you whether the app is listening. If it says *"⌘-click lookups need
Accessibility"* after you granted it, re-add it in System Settings → Privacy & Security →
Accessibility — a stale entry can look enabled while being invalid, so remove it with **−**
and add it again.

For anything else, the app logs which path it took:

```sh
log show --last 5m --predicate 'subsystem == "com.oeaio.aishell"' --style compact
```

Only the word looked up and the code path are recorded — never the terminal contents.

## Licence

MIT. See [LICENSE](LICENSE).
