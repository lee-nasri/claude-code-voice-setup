# Make Claude talk — setup guide

**Hand this whole folder to Claude Code and say: "read SETUP.md and set this up for me."**

You are Claude Code, running on the user's Mac. This document is your instruction set.
Everything you need is in `kit/` next to this file. Do not invent your own version of these
scripts — install the ones provided.

When you are done, the user will be able to:

- hold **`option+space`**, speak, and have their words land in the prompt as text
- hear each Claude session say what it finished, out loud, in its own voice
- run several sessions at once and have them **queue** instead of talking over each other

Both models run on the Mac. **No API key, no account, nothing leaves the machine.**

---

## Ground rules for you, the agent

1. **Never report success you have not observed.** The failure mode of this system is *silence*,
   and silence is indistinguishable from working. Every phase below ends with a check that
   fails out loud. Run it. Paste the real output.
2. **Some steps you cannot do.** macOS permission dialogs and an app's own onboarding need a
   human hand. They are listed in [Human-only steps](#human-only-steps). When you reach one,
   stop and ask the user to do it, then verify.
3. **Do not `sudo`.** Nothing here needs root. If something seems to, you have taken a wrong turn.
4. **Phase 1 is standalone.** If the user only wants dictation, stop after Phase 1 — it is useful
   on its own and needs no daemon, no queue, no config.
5. Work in the user's real `$HOME`. Every path below is `$HOME`-relative on purpose; the scripts
   already assume `~/.claude/tts`.

---

## Phase 0 — prerequisites (2 min)

```bash
sw_vers -productVersion                  # macOS
uname -m                                 # arm64 or x86_64 — both fine
which brew || echo "MISSING: homebrew"
/usr/bin/python3 --version               # 3.9+ ships with macOS
df -h "$HOME" | tail -1                  # need ~2 GB free
```

Report anything missing before continuing. If Homebrew is absent, ask the user whether to install
it — do not install it silently.

---

## Phase 1 — the listening half (speech → text)

The tool is **Handy** (`handy.computer`) — free, open source, runs Whisper locally.

### 1.1 Install

```bash
brew install --cask handy
open -a Handy
```

### 1.2 Human-only steps — stop and ask

Tell the user, in these words, that you cannot click these yourself and they must do it now:

1. Complete Handy's onboarding window.
2. Grant **Microphone** permission when macOS asks (or System Settings → Privacy & Security →
   Microphone → enable Handy).
3. Grant **Accessibility** permission (Privacy & Security → Accessibility → enable Handy) — this
   is what lets it paste into other apps.
4. In Handy's settings, **download the `turbo` model** (Whisper `large-v3-turbo`, ~1.6 GB).

Wait for them to confirm. Then verify from disk rather than trusting the confirmation:

```bash
ls -la "$HOME/Library/Application Support/com.pais.handy/models/"
# expect: ggml-large-v3-turbo.bin, ~1.62 GB
```

If that file is absent, the model did not download. Do not proceed.

### 1.3 Set the settings that matter

Config lives at `~/Library/Application Support/com.pais.handy/settings_store.json`.
**Quit Handy before editing it, or it will overwrite your changes on exit.**

The values that matter, and why:

| Key | Set to | Why |
|---|---|---|
| `bindings.transcribe.current_binding` | `option+space` | hold to talk, release to insert |
| `push_to_talk` | `true` | **no always-on microphone** — the objection everyone raises |
| `always_on_microphone` | `false` | same |
| `selected_model` | `turbo` | the local Whisper model |
| `selected_language` | `auto` | leave it on `auto` if the user speaks more than one language. Pinned to `en`, other languages come out as phonetic nonsense |
| `auto_submit` | `false` | the user reads what was heard, *then* presses enter. This is what makes it feel safe |
| `post_process_enabled` | `false` | post-processing sends the transcript to a cloud LLM. Off = nothing leaves the Mac |
| `autostart_enabled` | `true` | otherwise it is not running after a restart and dictation silently does nothing |
| `clipboard_handling` | `dont_modify` | keeps the user's clipboard intact |

Edit with a JSON-aware tool (the keys sit under a top-level `settings` object), then relaunch
Handy and re-read the file to confirm your write survived.

### 1.4 Verify Phase 1 — fail loudly

Ask the user to click into any text field, hold `option+space`, say *"testing one two three"*,
and release.

- Text appears → Phase 1 works.
- Nothing appears → the cause is almost always **Accessibility permission**, not the model.
  Check `~/Library/Logs/handy/` or Handy's own log and report what it says. Do not guess.

**Stop here if the user only wanted dictation.**

---

## Phase 2 — the talking half (text → speech)

Engine: **Kokoro v1.0**, run through `kokoro-onnx`, locally. 54 voices in one file.

Two projects, two licences, and it is worth keeping them straight: the **model weights**
([hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M)) are **Apache-2.0**, while
[thewh1teagle/kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) — the pip package that
loads them — is **MIT**. Both permissive; neither requires anything of the user here.

### 2.1 Layout and virtualenv

```bash
mkdir -p "$HOME/.claude/tts/queue/.claimed" "$HOME/.claude/tts/cache" "$HOME/.claude/tts/skip"
cd "$HOME/.claude/tts"
/usr/bin/python3 -m venv kokoro-venv
./kokoro-venv/bin/pip install --quiet --upgrade pip
./kokoro-venv/bin/pip install --quiet kokoro-onnx sounddevice
./kokoro-venv/bin/python -c "import kokoro_onnx, sounddevice; print('venv ok')"
```

### 2.2 Download the models — and check the bytes

```bash
cd "$HOME/.claude/tts"
BASE=https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0
curl -fL -o kokoro-v1.0.onnx "$BASE/kokoro-v1.0.onnx"
curl -fL -o voices-v1.0.bin  "$BASE/voices-v1.0.bin"
stat -f '%z %N' kokoro-v1.0.onnx voices-v1.0.bin
```

**Expected exactly:**

```
325532387 kokoro-v1.0.onnx
28214398  voices-v1.0.bin
```

A different size means a truncated or redirected download. Delete and retry — do not continue
with a partial model, because it fails at *generation* time, hours later, as silence.

### 2.3 Install the scripts

Copy every file from `kit/` into `~/.claude/tts/` (not the `.template` files — those are handled
in 2.5, and not `voices.conf.example` — that is handled in 2.4):

```bash
cp kit/{speak.sh,watcher.sh,duck.sh,mic_hold.py,kokoro_daemon.py,kokoro_stream.py,tts_text.py,tts_client.py} \
   "$HOME/.claude/tts/"
cp kit/{voice-lookup.sh,thai_engine.py} "$HOME/.claude/tts/"           # voice resolution + the Thai path
cp kit/{ack.sh,regen-ack.sh,ack-phrases.conf} "$HOME/.claude/tts/"     # Phase 4 uses these
chmod +x "$HOME/.claude/tts/"*.sh
touch "$HOME/.claude/tts/ENABLED"          # present = allowed to speak; delete = mute
```

What each one is, so you can debug it later:

| File | Job |
|---|---|
| `speak.sh` | speak one string. Picks the voice from `voices.conf`, caches the wav, talks to the daemon, falls back to macOS `say` if Kokoro is broken |
| `kokoro_daemon.py` | holds the model **warm in memory** on a unix socket, so the first word starts in ~3 s instead of after a fresh load. Writes `daemon.status` as a heartbeat |
| `kokoro_stream.py` | cold fallback path when the daemon is down |
| `watcher.sh` | watches the queue folder, plays messages in arrival order, owns mute / skip / pause / barge-in |
| `mic_hold.py` | barge-in detector: mirrors "microphone in use" into a `HOLD` file |
| `duck.sh` | lowers other audio while speaking, restores it afterwards |
| `tts_text.py` | sentence chunking — small first chunk so sound starts fast, bigger later chunks. Thai has its own splitter, because Thai writes no spaces inside a clause |
| `tts_client.py` | stdlib-only client for the daemon socket |
| `voice-lookup.sh` | one copy of "which voice does this speaker key get", sourced by everything that needs it |
| `thai_engine.py` | loads the Thai model when a `th_*` voice is asked for. **Degrades to "not available" instead of raising**, so a missing Thai bundle can never take the English voice down |
| `ack.sh` | the instant chirp on enter (Phase 4) — plays a pre-rendered clip, never generates |
| `regen-ack.sh` | renders those clips locally, one model load for the whole batch |
| `ack-phrases.conf` | the sentences the chirp says, one per line — edit freely |

### 2.4 Voices

```bash
cp kit/voices.conf.example "$HOME/.claude/tts/voices.conf"
# list every available voice:
"$HOME/.claude/tts/kokoro-venv/bin/python" - <<'PY'
import os
from kokoro_onnx import Kokoro
h = os.path.expanduser("~/.claude/tts")
print(sorted(Kokoro(f"{h}/kokoro-v1.0.onnx", f"{h}/voices-v1.0.bin").get_voices()))
PY
```

Ask the user which voice they want as `default`. The mapping is `name=voice`, where the name is
the suffix of the queue filename, so one voice per session is how they will tell sessions apart
without looking at the screen. Prefix rules (`team*=am_michael`) work too.

### 2.5 First sound — before any launchd job

```bash
"$HOME/.claude/tts/speak.sh" --test
```

The user should hear a spoken line. If they do not, and no error appeared, check in this order:
output device, then `tail -20 ~/.claude/tts/kokoro.err`. Fix it **now** — a launchd job on top of
a broken speaker only hides the error.

### 2.6 Keep it running — launchd

Two jobs: the daemon (model warm) and the watcher (queue). Render the templates in
`kit/*.plist.template`, replacing `__HOME__` with the real home directory and `__USER__` with a
short label of your choice (it only names the job):

```bash
for f in kit/claude-tts-daemon.plist.template kit/claude-tts-watcher.plist.template; do
  out="$HOME/Library/LaunchAgents/$(basename "$f" .template)"
  sed "s|__HOME__|$HOME|g; s|__USER__|$(id -un)|g" "$f" > "$out"
  echo "wrote $out"
done
launchctl load -w "$HOME/Library/LaunchAgents/"*claude-tts-*.plist
```

Note the two deliberate settings inside them: the daemon uses
`KeepAlive = {SuccessfulExit: false}` with `ThrottleInterval: 10` so a crash restarts but a clean
exit does not spin; the watcher uses plain `KeepAlive: true`. Do **not** add
`ProcessType: Background` — background QoS pushes generation onto efficiency cores and the speech
develops mid-sentence gaps.

### 2.7 Verify Phase 2 — fail loudly

```bash
# 1. both jobs registered
launchctl list | grep claude-tts

# 2. daemon alive and heartbeating (phase should be idle/speaking, `at` within ~15s of now)
cat "$HOME/.claude/tts/daemon.status"; date +%s

# 3. watcher alive
kill -0 "$(cat "$HOME/.claude/tts/watcher.pid")" && echo "watcher alive"

# 4. the real test: speak by writing a FILE, which is how sessions will do it
echo "Setup complete. This message arrived through the queue." \
  > "$HOME/.claude/tts/queue/$(date +%s)-work.txt"
```

Step 4 is the only check that proves the whole chain. If nothing is heard, read
[Troubleshooting](#troubleshooting) — start with `daemon.err`'s **modification time**.

### 2.8 Thai voices — optional, skip freely

**Ask the user whether they want this before downloading 340 MB.** English is complete without
it, and everything above already works.

`kokoro-v1.0.onnx` has no Thai voice, and the venv's espeak-ng has no Thai
grapheme-to-phoneme either — so Thai is a **second model**, loaded beside the English one rather
than replacing it. Both emit 24 kHz, so the rest of the system cannot tell them apart.

```bash
cd "$HOME/.claude/tts"
./kokoro-venv/bin/pip install --quiet tltk pythainlp        # Thai word-splitting + G2P

# the model is a git-lfs repo; without lfs the .onnx files arrive as 130-byte pointers
brew install git-lfs && git lfs install
git clone https://huggingface.co/kunato/wayu-kokoro-thai-v1 kokoro-thai
```

**Check the bytes before going further** — the same rule as 2.2, and the failure looks the same
(silence at generation time, hours later):

```bash
cd "$HOME/.claude/tts/kokoro-thai/onnx" && stat -f '%z %N' *.onnx
```

```
33721740  curves_fp32.onnx
213445776 decoder_fp32.onnx
78259639  prosody_fp32.onnx
```

A file of ~130 bytes means `git lfs` was not installed before the clone. Delete `kokoro-thai`,
install it, clone again.

**Then restart the daemon so it loads the new model** and verify:

```bash
launchctl kickstart -k "gui/$UID/com.<you>.claude-tts-daemon"
sleep 20 && grep "thai warm" "$HOME/.claude/tts/daemon.err" | tail -1
```

Expected: `[daemon] thai warm: True`. `False` is followed by the reason on the same line.

Finally, add a Thai voice to `voices.conf` and speak through the queue — the real test, same as
2.7 step 4:

```bash
echo "thai=th_fah" >> "$HOME/.claude/tts/voices.conf"
echo "สวัสดีครับ ระบบเสียงภาษาไทยทำงานแล้ว" \
  > "$HOME/.claude/tts/queue/$(date +%s)-thai.txt"
```

Five voices ship with it: `th_fah` and `th_jane` (female), `th_ton`, `th_krit` and `th_bank`
(male). They are ordinary entries in `voices.conf` — nothing else in the system treats them
specially.

| | |
|---|---|
| Model | [kunato/wayu-kokoro-thai-v1](https://huggingface.co/kunato/wayu-kokoro-thai-v1), Apache-2.0 |
| Disk | ~340 MB (decoder 213 MB, prosody 78 MB, curves 34 MB) |
| Extra RAM when warm | roughly the same again, held resident beside the English model |
| First Thai line after a cold start | ~7 s vs ~4.5 s for English — the G2P tables load too |

🔴 **One thing to know before you write to a Thai voice:** nothing in the code checks that the
*text* is Thai. `kokoro_daemon.py` branches on the voice to pick the **engine**, and the Thai
frontend is bilingual, so English sent to `th_fah` is read aloud in a Thai accent instead of
failing. It sounds wrong and reports nothing. Match the language to the voice at write time.

---

## Phase 3 — make the sessions actually speak

Nothing so far tells Claude to talk. That is one instruction in the user's global memory file,
`~/.claude/CLAUDE.md`. Append this, adjusting the name to whatever they used in `voices.conf`:

```markdown
## Speak every turn

FIRST, at the start of the session, register this session's name so it gets its own voice:

    mkdir -p ~/.claude/team-sessions && echo work > ~/.claude/team-sessions/$PPID

(Use a different name per session — `work`, `side`, `docs` — matching `voices.conf`.
Skip this and every session speaks in the same default voice.)

Then at the end of every turn, queue one spoken message, named after the same session:

    cat > ~/.claude/tts/queue/$(date +%s)-work.txt <<'EOF'
    <the message>
    EOF

Rules:
- ONE file per turn. Write it as the FIRST tool call when the outcome is already known,
  so speech starts while the text answer is still being written.
- Start with who you are ("work here — ") and end with "Over." so silence after it reads
  as finished, not cut off.
- ~180–220 words, about a minute spoken. Carry the ANSWER — what happened, what it means,
  what you need from me — not a reading of the screen.
- Screen keeps the evidence: code, diffs, file lists, tables, exact numbers.
- No markdown, no file paths, no URLs, no commit hashes. Round long numbers for speech.
```

That discipline is not decoration. Without it the voice reads the screen aloud, becomes noise,
and gets muted within a day — which is the actual failure mode of this whole system.

Then verify: start a new session, ask it anything, and confirm a file appears in
`~/.claude/tts/queue/` and is spoken.

---

## Phase 4 — answer the instant they press enter

Without this, every reply begins with 10-20 seconds of silence while the model reads the
conversation and thinks. The voice stack is not the slow part &mdash; measured, it contributes
well under a second. This does not make anything faster. It removes the silence, so the wait
stops reading as "something is broken".

### 4.1 Render the clips (local, ~30 s)

```bash
"$HOME/.claude/tts/regen-ack.sh"
```

It renders every phrase in `ack-phrases.conf` once per voice named in `voices.conf`, naming each
file after a hash of its text, so editing one phrase re-renders only that phrase. Expect a line
per clip and a count at the end.

**Pre-rendered is the whole point.** Generating this speech at keypress time would cost 0.3-3 s
and defeat the feature. If you are tempted to "simplify" it by calling the model directly, don't.

### 4.2 Register the hook

`ack.sh` runs on `UserPromptSubmit`. Add it to `~/.claude/settings.json` (merge into the existing
`hooks` object &mdash; do not overwrite other entries):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "/Users/YOU/.claude/tts/ack.sh" } ] }
    ]
  }
}
```

Use the absolute path with the real home directory; `~` is not expanded here.

🔴 **Hooks are read at session start.** Registering it reaches only sessions started afterwards
&mdash; every window already open is unaffected and will look broken. Say so to the user rather
than debugging a hook that is working perfectly.

### 4.3 Verify

Start a **new** session, type anything, press enter. A short spoken line should land within about
a second, in that session's voice.

Silent? In this order:

```bash
tail -5 "$HOME/.claude/tts/ack.log"     # "no team registered" = voice fell back to default
ls "$HOME/.claude/tts/ack" | head       # clips actually rendered?
```

Then verify **barge-in**, which is the one feature that has never been tested on a machine other
than the author's: while a message is speaking, hold the dictation key. The sentence should stop
at once and the queue should hold. If it does not, check that `mic_hold.py` is running
(`pgrep -f tts/mic_hold.py`) and read `~/.claude/tts/mic_hold.err` &mdash; detecting microphone
use may need a permission we have not hit yet. Report what it says rather than guessing.

`ack.sh` also stays deliberately silent when muted, paused, dictating, or when something else is
already speaking &mdash; and for 8 seconds after the last chirp, so three fast prompts give one
sound. Silence in those cases is correct, not broken.

### 4.4 How it picks the voice

Same team &rarr; voice table as everything else, resolved from `~/.claude/team-sessions/<pid>`,
walking up the process tree to the nearest registered ancestor. If nothing is registered anywhere
it uses the default voice **and writes a line to `ack.log`** saying so &mdash; because falling back
silently is how a session ends up chirping in one voice and reporting in another.

To name a session, write its team into that file at startup:

```bash
mkdir -p ~/.claude/team-sessions && echo work > ~/.claude/team-sessions/$PPID
```

---

## Controls &mdash; without a panel, these are files

There is no UI in this kit. Every control is a file, which makes them scriptable and easy to
bind to a shortcut. Tell the user these exist &mdash; otherwise the first time the voice says
something at a bad moment, they have no way to stop it.

| To do this | Do this | Notes |
|---|---|---|
| Mute everything | `rm ~/.claude/tts/ENABLED` | cuts what is speaking now; queued messages are **destroyed**, not saved for later |
| Unmute | `touch ~/.claude/tts/ENABLED` | |
| Pause / resume | `touch` / `rm ~/.claude/tts/PAUSE` | freezes the queue; the interrupted message replays from its start |
| Skip what is speaking | `touch ~/.claude/tts/skip/ALL` | or `skip/<name>` for one session |
| Mute one session only | add its name on its own line in `~/.claude/tts/muted.conf` | others keep talking |
| Talk over it (barge-in) | just open the mic (`option+space`) | cuts the sentence, other sessions keep their turn |
| Change the speaking rate | one line per voice in `~/.claude/tts/speeds.conf` — `bf_emma=1.25` | `1.0` is normal. Keyed on the VOICE, so one voice never sounds like two different people. Missing file means 1.0 everywhere |
| Change a session's voice | edit `~/.claude/tts/voices.conf` | takes effect on the next message, no restart |
| Turn the chirp off, keep speech | `touch ~/.claude/tts/ACK_OFF` | |
| See what is queued | `ls ~/.claude/tts/queue/` | filenames are `<epoch>-<session>.txt` |

---

## Human-only steps

Collected in one place, because these are the steps that stall an unattended install:

| Step | Where | Why you cannot do it |
|---|---|---|
| Handy onboarding | Handy window | GUI-only |
| Microphone permission | System Settings → Privacy & Security | macOS blocks scripted grants (TCC) |
| Accessibility permission | same | same — and without it dictation silently inserts nothing |
| Download the `turbo` model | Handy settings | in-app download |
| Choosing a voice | ask the user | taste, not configuration |
| Confirming they can hear it | ask the user | you have no ears |

---

## Troubleshooting

**Nothing is spoken, but every status file looks healthy.**
The honest check is not `pgrep` and not `daemon.status` — it is the **modification time of
`daemon.err`** compared with the moment of the last queued message. If the log has not been
touched, the daemon never picked the message up.

```bash
stat -f '%Sm %N' "$HOME/.claude/tts/daemon.err"
tail -5 "$HOME/.claude/tts/routing.log"
```

**It stopped after the laptop was closed and reopened.** Known: the daemon can end up in a state
where every signal still reports healthy while nothing plays. Restart it:

```bash
launchctl kickstart -k "gui/$(id -u)/$(basename "$HOME"/Library/LaunchAgents/*claude-tts-daemon.plist .plist)"
```

Then re-run the Phase 2.7 step-4 file test. Do not declare it fixed without hearing it.

**Queue fills up but nothing plays.** Check the mute file (`ENABLED` must exist), then
`muted.conf` (per-name mute), then `skip/`, then whether a `HOLD` or `PAUSE` file is sitting
there — `HOLD` is written when the microphone is in use, so a stuck detector freezes the queue.
`rm` the stale file.

**Speech has gaps mid-sentence.** Something put the daemon on background QoS. Check the plist has
no `ProcessType` key.

**Dictation inserts nothing.** Accessibility permission, nine times out of ten. Not the model.

**Non-English comes out as gibberish.** `selected_language` is pinned to one language. Set it to
`auto`.

**There is no Thai voice.** Not in `kokoro-v1.0.onnx` — its 54 voices carry English plus 7 other
languages, and none of them is Thai. Thai speech comes from a **second model**, installed in
Phase 2.8. The listening half needs nothing extra.

**Thai comes out as gibberish, or as English read with Thai letters.** The Thai bundle failed to
load and the message fell through to the English voice, which will happily read anything.
Nothing raises — that is deliberate, a broken Thai install must never silence the English voice.
Ask the daemon what happened:

```bash
"$HOME/.claude/tts/kokoro-venv/bin/python" -c "
import sys; sys.path.insert(0, '$HOME/.claude/tts')
import thai_engine
print('on disk:', thai_engine.available())
thai_engine.warm()
print('error  :', thai_engine.load_error() or 'none')"
```

`on disk: False` means the model never downloaded. An error naming `tltk` or `pythainlp` means
the pip step in 2.8 was skipped.

---

## Uninstall

```bash
launchctl unload -w "$HOME/Library/LaunchAgents/"*claude-tts-*.plist
rm -f "$HOME/Library/LaunchAgents/"*claude-tts-*.plist
pkill -f kokoro_daemon.py; pkill -f tts/mic_hold.py; pkill -f tts/watcher.sh
rm -rf "$HOME/.claude/tts"                 # includes the 350 MB speech model, and the Thai one if you added it
brew uninstall --cask handy                # and remove the Speak-every-turn block from ~/.claude/CLAUDE.md
# also delete the ack.sh UserPromptSubmit entry from ~/.claude/settings.json
```

Also remove Handy's models and settings if you want the disk back:
`~/Library/Application Support/com.pais.handy`.

---

## What this costs

| | |
|---|---|
| Disk | ~1.6 GB dictation model + ~350 MB speech model + a venv, plus ~340 MB if Thai is installed |
| Network | one-time downloads only |
| Money | none — both projects are free and open source |
| Data leaving the Mac | **none**, provided `post_process_enabled` stays `false` |
