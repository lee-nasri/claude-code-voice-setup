# Make Claude talk

Talk to Claude Code, and hear it answer — with both models running on your own Mac.
No API key, no account, nothing leaves the machine.

You get:

- **hold `option+space`, speak, release** — your words land in the prompt as text
- **each session says what it finished, out loud, in its own voice**
- **several sessions at once take turns** instead of talking over each other
- **a sound the instant you press enter**, so the 10–20 s the model spends thinking
  stops reading as "something is broken"

## Install

```bash
git clone git@github.com:lee-nasri/claude-code-voice-setup.git
cd claude-code-voice-setup
claude
```

Then tell it:

> read SETUP.md and set this up for me

`SETUP.md` is written as an instruction set for Claude Code, not for you. It installs the
scripts in `kit/` rather than inventing its own, verifies each phase with a check that
fails out loud, and stops to ask you when it hits something only a human can click —
microphone and accessibility permissions, mostly.

**Phase 1 is standalone.** If all you want is dictation, stop after it. It's useful on its
own and needs no background jobs at all.

## What it installs

| Half | Tool | What it is |
|---|---|---|
| you → Claude | [Handy](https://handy.computer) | push-to-talk dictation, Whisper `large-v3-turbo` running locally |
| Claude → you | [Kokoro](https://github.com/hexgrad/kokoro) | 54 voices in one 326 MB file, Apache-2.0, running locally |

Plus the small system around them, which is the part that took the time:

- a **queue folder** — any session speaks by writing a file; one watcher plays them in
  arrival order and claims each file by *moving* it, so nothing is ever spoken twice
- **chunked speech** — a deliberately tiny first chunk, so the first word starts in about a
  second instead of after the whole paragraph is generated
- **a warm model** — held in memory by a background process, because loading it per message
  costs seconds every message
- **barge-in** — open the mic and the sentence stops mid-word, while every other session
  keeps its turn
- **one voice per session** — the voice is an address; you know who is talking without looking

## Cost

| | |
|---|---|
| Disk | ~1.6 GB dictation model + ~350 MB speech model + a virtualenv |
| Network | one-time downloads |
| Money | none |
| Data leaving your Mac | none, as long as post-processing stays off |

## Credits

- [Handy](https://handy.computer) — the dictation app
- [Kokoro](https://github.com/hexgrad/kokoro) (Apache-2.0) and
  [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) — the voices
- [live-dj](https://github.com/cuppibla/live-dj) — barge-in came from here

Everything else in `kit/` is mine, MIT licensed. It is a working setup lifted off one Mac
rather than a polished product: it assumes macOS, `~/.claude/`, and Claude Code.
