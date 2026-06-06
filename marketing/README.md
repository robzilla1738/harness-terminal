# Harness marketing video (HyperFrames)

HTML-native MP4 compositions for launch clips, social reels, and feature announcements. Powered by [HyperFrames](https://github.com/heygen-com/hyperframes).

## Prerequisites

- **Node.js 22+**
- **FFmpeg** (`brew install ffmpeg`)
- Optional: run `npx hyperframes doctor` from `marketing/video` to verify the environment

## Project layout

| Path | Purpose |
|------|---------|
| `video/` | HyperFrames composition project (`index.html`, `npm run dev`, `npm run render`) |
| `video/.agents/skills/` | AI skills (installed locally; not committed — see below) |
| `../../design-system.md` | Brand tokens, copy, logos (local; gitignored — run `/design-system` to refresh) |

## One-time setup

```bash
cd marketing/video
npx skills add heygen-com/hyperframes -y   # HyperFrames + GSAP skills for Cursor/Codex/Claude
```

Skills install into `.agents/skills/` and are listed in `skills-lock.json` for reproducibility.

## Workflow

1. **Refresh brand reference** (repo root): `/design-system` or edit `design-system.md`.
2. **Open the composition project** in your agent with cwd `marketing/video` (or the whole repo — agents should read `../../design-system.md` and `harness-brand.css`).
3. **Prompt with `/hyperframes`**, e.g.:

   > Using `/hyperframes`, create a 15-second 1920×1080 intro: black canvas, white type, Harness tagline, subtle GSAP fade-in. Use `harness-brand.css` tokens. No system blue.

4. **Preview** (long-running — keep in background):

   ```bash
   cd marketing/video && npm run dev
   ```

5. **Validate** after every edit:

   ```bash
   cd marketing/video && npm run check
   ```

6. **Render**:

   ```bash
   cd marketing/video && npm run render
   ```

From the repo root you can also use `make video-dev`, `make video-check`, and `make video-render`.

## Brand assets for compositions

Copy into `marketing/video/assets/` as needed:

```bash
cp Apps/Harness/Resources/Assets.xcassets/HarnessLogo.imageset/harness-logo.png \
   marketing/video/assets/harness-logo.png
```

The menu-bar **Harness mark** (two rounded squares) is procedural — recreate in HTML/CSS or export from `MenuBarController.markImage` if you need it in-video.

## Links

- [HyperFrames docs](https://hyperframes.heygen.com/introduction)
- [Prompting guide](https://hyperframes.heygen.com/guides/prompting)
- [Open Design handoff](https://hyperframes.heygen.com/guides/open-design) (optional visual-first draft)
