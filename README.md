# Saksi

*Saksi* is Indonesian for **witness** — the one who observes what actually happened and
testifies to it. That is the whole idea.

AI-assisted QA and verification for Godot games.

---

**An AI agent cannot verify what it cannot see.**

Ask an AI to fix your game's UI and it will read your code, change it, and tell you it works.
It has no idea whether the button is now off-screen, the text overlaps, or the menu renders
at all. It is guessing — confidently.

This framework gives the agent eyes: it runs your game, captures every screen, records runtime
state, and feeds all of it back so the agent reasons about what actually happened instead of
what the code implies. Then it holds the agent to that evidence — a change is not "done"
until the screenshots say so.

Built for Godot 4.x on Windows.

> Documentation beyond this page is in Indonesian. The code, CLI output, and templates are
> usable without it, but `QUICKSTART.md` and `FRAMEWORK.md` assume you read Indonesian.

---

## The loop

```
write code → run harness → agent sees screenshots + state → agent analyzes → report → act
```

Everything else in this repo exists to make that loop reliable enough to trust.

**Progressive capability** — usable from the first prototype, not just at production:

| Phase | What you get |
|---|---|
| Prototype | Screenshot harness, manifest, runtime observation |
| Developing | Game state telemetry, scenario testing, assertions |
| Production | Automated gameplay testing, visual regression, CI/CD, autonomous QA |

**Feedback-to-code bridge** — maps playtester complaints to the screenshots, UI components,
and source locations they refer to.

---

## Quick start

### 0. Bootstrap (once per machine)

```powershell
& ".\setup.ps1"
```

Detects Godot and ImageMagick, installs the tools to `~/.config/kilo`, and verifies the
result before reporting success. If Godot is missing it says so plainly rather than claiming
you are ready.

Optional — make the framework discoverable from any game project, not just this repo:

```powershell
& ".\setup.ps1" -InstallAgentRules
```

Opt-in, because it writes to `~/.kilocode/rules/` and `~/.claude/CLAUDE.md`. Marker-delimited,
idempotent, and reversible with `-UninstallAgentRules`.

### 1. Integrate a game project

```powershell
& ".\setup.ps1" -InitProject "C:\path\to\game-project"
```

Copies the `.gd` templates, scenario templates, and AI commands into the project, then
registers the autoloads in `project.godot`.

`project.godot` is your file — and the first file Godot reads. If it breaks, the project will
not open at all. So the edit is defensive: it backs up first, previews the change, never
duplicates entries on re-run, and **stops without touching anything** if an autoload name
already belongs to something of yours. Add `-DryRun` to see the plan only.

### 2. Add the screenshot tour

This part is yours to write — only you know which screens matter and how to reach them.

```gdscript
# main.gd
func _ready() -> void:
    # Do NOT call _shot_tour() here. ErrorTracker calls it after hot-reload settles.
    pass

func _shot_tour() -> void:
    _take_shot("01_title")
    await get_tree().create_timer(0.1).timeout
    get_tree().quit()

func _take_shot(name_: String) -> void:
    DirAccess.make_dir_absolute("user://shots")   # required — save_png fails without it
    var img := get_viewport().get_texture().get_image()
    img.save_png("user://shots/%s.png" % name_)
```

The `_ready()` note is not a style preference. Godot 4.7 reloads scripts when a project is
launched from the command line; calling `_shot_tour()` during that window fails in ways that
are hard to diagnose. `ErrorTracker` waits it out and then calls into your main node.

### 3. Run it

```powershell
& "$env:USERPROFILE\.config\kilo\tools\shot-harness.ps1" -ProjectPath "path/to/project"
```

---

## What's in here

### Tools (PowerShell)

| File | Purpose |
|---|---|
| `tools/shot-harness.ps1` | Automated screenshot tour via the `--shot` flag |
| `tools/shot-harness-unity.ps1` | Unity adapter |
| `tools/visual-diff.ps1` | Visual regression comparison between builds |
| `tools/feedback-bridge.ps1` | Map playtester feedback to screenshots + code |
| `tools/autonomous-qa.ps1` | Autonomous QA loop: observe → analyze → report |
| `tools/run-and-analyze.ps1` | Run the game and analyze its output |
| `tools/schema-migration.ps1` | Migrate manifest schema between versions |
| `tools/doctor.ps1` | Health check for the installation |
| `tools/test-pipeline.ps1` | Framework self-test (36 regression tests) |
| `tools/_common.ps1` | Shared: Godot/ImageMagick detection, `user://` mapping |

### Godot templates

| File | Purpose | Autoload? |
|---|---|---|
| `godot-templates/ScenarioRunner.gd` | Automated gameplay testing (18 step types) | **No** |
| `godot-templates/GameStateWriter.gd` | Scene tracking + writes `game_state.json` | Yes |
| `godot-templates/ErrorTracker.gd` | Error tracking + bootstraps `--scenario` | Yes |
| `godot-templates/InputRecorder.gd` | Records input for bug replay | Yes |

> `ScenarioRunner.gd` is deliberately **not** an autoload. `ErrorTracker` loads it on demand
> when it sees the `--scenario` flag.

### Documentation

- `FRAMEWORK.md` — full architecture and internals
- `QUICKSTART.md` — zero to first screenshot
- `GAME_STATE_SPEC.md` — the `game_state.json` contract, minimal to full telemetry
- `AGENTS.md` — global instructions for AI agents working with this framework

### AI commands

Installed to `.kilo/command/` by `-InitProject`:

| Command | Purpose |
|---|---|
| `/shot` | Run the screenshot harness |
| `/scenario` | Run automated scenario testing |
| `/analisis-feedback` | Analyze playtester feedback through the bridge |
| `/analisis-shot` | Analyze screenshots for visual QA |
| `/baseline` | Set the visual regression baseline |
| `/record` | Record a gameplay session for bug replay |

---

## How this is verified

The framework tests itself: `tools/test-pipeline.ps1` runs 36 regression tests covering the
harness, the gate, path resolution, bootstrap, and project integration.

One rule governs every test, and it is the reason to trust the number:

> A test claiming to prove a fix must first be observed **failing** against the unfixed code.
> A rising green count is not evidence — it is the easiest thing in the world to fake.

Beyond the suite, the tools are exercised against four real Godot projects with deliberately
different layouts (`scripts/`, `src/global/`, `source/scripts/`, `source/common/framework/`),
including one that uses a custom `user://` directory and one whose project name differs from
its folder name. Several real bugs were found precisely because those cases differ.

It has also been used in anger. The framework was developed alongside an indie roguelite based
on Indonesian folklore, carrying it from prototype through four rounds of playtesting with
40+ players:

- `--scenario smoke` — 8/8 passing end-to-end
- `feedback-bridge` — validated across three playtest batches (40 profiles)
- Frequency weighting — validated on the fourth batch (10 profiles, per-profile delimiters)
- Visual regression — `intentional_changes` annotation working as designed

---

## Requirements

- Windows, PowerShell 5.1+
- Godot 4.x
- ImageMagick — optional, enables pixel-level visual diff (falls back to hash comparison)
- An AI coding agent — Kilo Code and Claude Code are supported for rule installation

---

## Scope, honestly

- **Godot 4.x is the supported engine.** A Unity adapter exists but is far less exercised.
- **Windows only.** Cross-platform is not implemented.
- **The screenshot tour is yours to write.** No tool can know which screens matter in your
  game or how to navigate to them. Everything mechanical around it is automated; that part
  is not.

---

## License

MIT — see [LICENSE](LICENSE).
