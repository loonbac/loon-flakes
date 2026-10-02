# LOON: LOON Offers Only Nuanced-gentle

LOON Offers Only Nuanced-gentle — Claude Code visual identity for [pi](https://pi.dev): curated dark ANSI theme, welcome banner, status line, spinner, turn footer, and CC-style tool rendering with dynamic wallpaper accent sync.

## Install

```bash
pi install npm:better-claude-code-ui
```

Try it without installing:

```bash
pi -e npm:better-claude-code-ui
```

### Recommended setting

This extension draws its own welcome banner, so pi's built-in startup header
becomes redundant. Hide it in `~/.pi/agent/settings.json`:

```json
{ "quietStartup": true }
```

The full two-column banner (extensions + skills) appears the first time you
open a given project, matching CC's `showOnboarding` behavior; later starts in
that project use the condensed logo.

## What you get

**Theme**:

- `loon` — single unified ANSI-16 theme synchronized with the active wallpaper accent color

**UI modules**:

- **Welcome banner** — CC's condensed logo on startup, boxed banner for new versions / first run in a project
- **Status line** — model, cwd (with `~` shortening), git branch
- **Spinner** — CC's verb rotation with byline: elapsed time, token count, `esc to interrupt`
- **Turn footer** — per-request cost/duration summary, matching CC v2.1.234 behavior
- **Tool rendering** — CC-style tool rows (no background box), grouped consecutive calls with `⎿` continuation lines, CC-faithful diff rendering with syntax highlighting (shiki)
- **Thinking** — collapsed by default with CC's label treatment; `alt+t` to expand
- **Prompt editor** — CC's `❯` prompt pointer

**Commands**:

- `/cc-tools` — toggle CC-style tool rendering options
- `/cc-spinner` — spinner options

## Requirements

Runs inside pi (`@earendil-works/pi-coding-agent`); pi core packages are peer dependencies provided by the host. Tested against pi 0.84.x.

When a Claude Code theme is active, the extension also watches
`~/.config/mpvpaper/accent.txt`. A valid `#RRGGBB` value updates the CC brand
accent live; missing or incomplete values are ignored until the producer writes
a complete value.

If `gentle-pi` is installed with its quiet tools enabled, this package leaves
the seven built-in tool registrations to `gentle-pi` so both packages can load.
Use `GENTLE_PI_QUIET_TOOLS=0 pi` when the CC tool renderers should take
ownership instead.

## License

MIT
