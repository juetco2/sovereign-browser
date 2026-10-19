# STAI Cybershield - run log

A running record of what works and what breaks, so a failure is never a mystery.
Every entry is something we actually saw, not something we assumed.

- **OK** = observed working, with the evidence next to it
- **FAIL** = observed broken, with the cause and the fix that was made
- **OPEN** = known, not yet fixed or not verifiable from here

---

## 1. Where it stands

Verified on 19 Oct 2026, ~12:35 PM, on a Cloud Shell VM in `europe-west4`.

| # | What | Evidence |
|---|------|----------|
| 1 | Locked browser runs in Cloud Shell | `docker ps` -> `cybershield: Up (healthy)`, port `6080->80` |
| 2 | It shows one hub page, no desktop | screenshot `hub-page.png` - kiosk Firefox on the hub, no taskbar, no icons |
| 3 | No taskbar, no desktop icons, no file manager | `supervisorctl status` has no `lxpanel` / `pcmanfm`; 8 of 8 programs `RUNNING` |
| 4 | The parent's website list reaches the machine | `~/cybershield/policy.json` = `{"mode":"allow","sites":["youtube.com","google.com"]}` |
| 5 | That list becomes a real Firefox policy | `policies.json` has those domains in `WebsiteFilter.Exceptions` |
| 6 | The app's own Launch code works, unmodified | ran the exact worker block out of `Start-Remote`: 43 s, returned `CYBERSHIELD_HOST=cs-<session-id>` |
| 7 | Firefox really is Firefox | build log: `RUN /usr/bin/firefox --version` -> `Mozilla Firefox 97.0` |
| 8 | The image builds from scratch | `cybershield-demo:latest`, 2.05 GB |
| 9 | The hub page matches the list, automatically | with `google.com, youtube.com` the page lists exactly those two; with wikipedia/khanacademy it lists those two instead |
| 10 | Reset survives being run repeatedly | two setups back to back -> `Up (healthy)`, all 8 programs `RUNNING` |
| 11 | The app writes a log of everything it does | `cybershield.log` next to the `.exe`, entries below |

Session URL (must be opened while signed in as the Cloud Shell account - it is
account-locked, see OPEN-1):

```
https://6080-cs-<session-id>.<region>.cloudshell.dev/?quality=2&compression=1&scalingMode=scale&clipToWindow=true&dotCursor=true
```

---

## 2. OK - things that work

### OK-1 The whole remote round trip (this was the big one)
`gcloud cloud-shell ssh` from the app now runs a command on the Cloud Shell VM
and gets the output back. See FAIL-1 for what it took.

### OK-2 Chunked upload and byte-exact verification
`setup.sh` is uploaded as four base64 chunks, reassembled with `base64 -d`, then
compared by md5 against the local file:

```
5f30209cced39ab0f4133babbcfcc31f  /home/<cloud-shell-user>/cybershield/setup.sh
10392 bytes
```

Both matched. This is how we know the machine is running *our* script and not a
half-written file.

### OK-3 The healthcheck now passes
`docker ps` reports `Up (healthy)`. Before, it sat at `unhealthy` forever - see FAIL-3.

### OK-4 A screenshot of the real screen
There is no `scrot`, `import`, `xwd` or `convert` in the image, but `ffmpeg` is
there, so the screen can be captured without installing anything:

```
docker exec cybershield ffmpeg -f x11grab -video_size 1280x720 -i :1 -frames:v 1 -y /tmp/shot.png
```

That is how `hub-page.png` was produced. It is the only way to see what the
locked browser is really showing without logging into the noVNC page.

### OK-5 The remote command runs exactly once
Worth checking, because a duplicated remote command would double a policy write:
`rm -f /tmp/c; echo X >> /tmp/c; wc -l < /tmp/c` -> `1`.

---

## 3. FAIL - what went wrong, and the fix

### FAIL-1 Launch hung forever on "Listening on local port [N]."  **(the main bug)**
**Symptom.** Clicking Launch in the app did nothing visible, forever. The last
line on screen was gcloud saying it was listening on a local port.

**Cause.** gcloud does not speak SSH itself on Windows; it drives PuTTY's
`plink.exe` through a local websocket tunnel, and it makes three connection
attempts. Each attempt opens a **new random local port**, so PuTTY - which
caches host keys per `host:port` - sees a brand new server every time and asks
the "Store key in cache? (y/n)" question. That question goes to the console and
is read from stdin. With no console (which is exactly how a captured,
windowless call behaves) it blocks there for good.

**Fix.** Two things:
1. pass `--ssh-flag="-legacy-stdio-prompts"` so that question moves onto the
   normal streams where we can see and answer it;
2. keep writing `y` to the process's stdin **until it exits** - a single `y` is
   swallowed by attempt 1, and attempt 2 then sees EOF and gives up with
   "Connection abandoned."

Attempt 1 always fails anyway (`No supported authentication methods available`),
attempt 2 over the tunnel's port 2222 is the one that succeeds.

Implemented in `cybershield-launcher.ps1` -> `Start-Remote`, which now runs
gcloud through a one-line `.cmd` shim with a redirected stdin/stdout/stderr and
feeds it `y` every 200 ms while reading the output line by line into the tracker.

### FAIL-2 "How do you want to open this file?" when Launching
**Cause.** `Find-Gcloud` returned `gcloud.ps1`. The SDK's `bin` folder ships
`gcloud`, `gcloud.cmd` **and** `gcloud.ps1`, and PowerShell's `Get-Command`
prefers the `.ps1`. Handing a `.ps1` to `Start-Process` goes to the file
association, and this PC has no `.ps1` association registered.

**Fix.** `Find-Gcloud` now prefers `gcloud.cmd` / `gcloud.exe` from PATH, then
from the known install folders, and never returns a `.ps1`.

**Related.** Double-clicking any `.ps1` on this PC shows that same dialog. Use
`Cybershield.exe`, or `Rebuild Cybershield.cmd` / `Launch Cybershield.cmd`.

### FAIL-3 Container reported `unhealthy` forever, so every Launch waited out the whole health timeout
**Cause.** The desktop's taskbar (`lxpanel`) was disabled by pointing its
supervisor command at `/bin/true`. That makes it exit immediately on every
start, so supervisord parked it in a `FATAL` back-off loop. The image's own
healthcheck (`curl --fail http://127.0.0.1:6079/api/health`) runs
`supervisorctl status`, which exits 3 as soon as any program is not `RUNNING`,
so `/api/health` returned 500 and the container could never be healthy.

**Fix.** `lxpanel` and `pcmanfm` are removed from `supervisord.conf` outright
(their `[program:...]` sections and their names in the `[group:x]` list) instead
of being neutered. Nothing to fail means nothing to report as failed - and as a
bonus the session is now browser-only, which is what was actually wanted.

### FAIL-4 Cloud Shell recycled the VM in the middle of the work
**Symptom.** Everything vanished: different hostname, different user, empty
home, no Docker images.

**Cause.** Cloud Shell recycles sessions. The Cloud Shell username changed and
`$HOME` was wiped, taking the uploaded `setup.sh` and the built image with it.

**Fix.** Nothing to fix in code - it is how Cloud Shell behaves. Just re-upload
and re-run `setup.sh` (~6 minutes: mostly the 2 GB base image pull). Worth
remembering for the demo: **if the session looks empty, it was recycled, not
broken.** Also the reason `Launch` falls back to `bash setup.sh` when the
container is missing.

### FAIL-5 The `.exe` could not be rebuilt while the app was open
**Cause.** Windows locks a running executable, so the build's `Remove-Item` failed.

**Fix.** Build to a side file and swap it in after closing the app:

```
build-exe.ps1 -OutFile Cybershield.new.exe
```

then close the app and copy over `Cybershield.exe`.

### FAIL-6 Writing `setup.sh` while running `setup.sh` destroys it
**Cause.** The outer installer writes the inner script to the very path bash is
executing, so the heredoc truncates the file mid-run.

**Fix.** Extract to a different filename (the outer installer is meant to be run
as `install.sh`, and it writes `setup.sh`). Both files exist for that reason.

### FAIL-7 Screenshot came back empty over the wire
**Symptom.** `base64 -w 0 /tmp/shot.png` returned nothing on stdout, twice, even
though the file existed on the machine.

**Workaround used.** Capture and encode in the **same** remote command, separating
the payload with a marker line, and wrap the base64 (not `-w 0`):

```
docker exec cybershield ffmpeg ... -y /tmp/s.png; echo SEPB64; docker exec cybershield base64 /tmp/s.png; echo SEPEND
```

**Still OPEN** as to why a 24 KB single line does not survive `plink`'s stdout
here. The wrapped form is proven, so the helper uses that. **This is the one to
suspect first if a future screenshot/upload looks empty.**

### FAIL-8 `docker restart` left the X display dead  **(FIXED)**
**Symptom.** After the app restarted the container, the X programs came up bad:

```
x:xvfb    FATAL     Exited too quickly
x:wm      FATAL     Exited too quickly
x:x11vnc  STARTING
```

The screen went blank, so the browser had nothing to draw on.

**Cause.** `docker restart` keeps the container's filesystem, so
`/tmp/.X1-lock` and `/tmp/.X11-unix/X1` survive from the previous run. Xvfb then
refuses to start - the log says it plainly:

```
Fatal server error:
(EE) Server is already active for display 1
     If this server is no longer running, remove /tmp/.X1-lock
```

That happened on **every Reset**, because Reset restarts the container.

**Fix.** `/usr/local/bin/xvfb.sh` now removes the stale lock and socket before
exec'ing Xvfb, so a restart is always a clean start. Proven by running the setup
twice back to back: `Up (healthy)` and 8 of 8 programs `RUNNING`.

Also, Launch and Reset now run `setup.sh` (remove + re-create the container)
instead of `docker restart`, which sidesteps stale state in general and
regenerates the policy and hub page on the way through.

### FAIL-9 The transport fix could not be tested from the UI without a click
**Symptom.** No way to prove `Start-Remote` works short of clicking Launch and
watching, which is a bad way to debug a 45-second network operation.

**Fix.** The worker block was pulled out of the file with the PowerShell parser
and run directly, with the app's own command template and a real policy blob:

```powershell
$ast  = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$null)
$hit  = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true) |
        Where-Object { $_.Extent.Text -match 'param\(\s*\$gcloudExe' } | Select-Object -First 1
$body = [scriptblock]::Create($hit.Extent.Text.Trim().Substring(1, $hit.Extent.Text.Trim().Length - 2))
& $body $gcloud $cmd $prog
```

Result: 43 s, `CYBERSHIELD_HOST=cs-<session-id>`. The UI path is proven, not
assumed. Useful trick for the next time something only fails behind a button.

---

## 4. OPEN - known, and not verifiable from here

### OPEN-1 The session page is locked to the Cloud Shell account
`https://6080-<host>/` redirects to a Google sign-in unless you are already
signed in as the Cloud Shell user. So the assistant cannot look at the live
session - only the account owner can, by opening the URL above while signed in.
This is Google's design, not something we can change.

### OPEN-2 The hub page is now generated, not hardcoded  **(FIXED)**
`start.html` used to be a static page with the four demo entries (wikipedia,
khanacademy, youtube, reddit) no matter what the parent chose. It is now written
by `write_policy.py` from the same list that produces `policies.json`, and the
container bind-mounts it, so the page cannot disagree with what is enforced.

Verified: with the list `google.com, youtube.com`, the page served from inside
the container lists exactly those two.

### OPEN-3 `localhost` is exempt in the policy
`http://localhost/*` and `127.0.0.1/*` have to be exceptions so the hub page
itself loads, but that also makes the image's file-browser service
(`fsweb`, port 8080) reachable from inside the locked browser. Tighten to the
exact hub path if this matters.

### OPEN-4 Only the allow list was proven, not the block list
The policy generator writes both, and the block-list branch was reviewed, but
only allow mode has been exercised end to end. Worth one demo run in block mode.

### OPEN-5 Cloud Shell limits (by design, not bugs)
Unavailable to under-18 accounts; 50 h/week quota; 12 h session cap; a session
is discarded after roughly 1 h idle. All acceptable for a demo, none fixable.

---

## 6. The app keeps its own log

Every action is appended to `cybershield.log`, next to the `.exe`:

```
2026-10-19 12:44:29  INFO   app start - 5.1.x on Microsoft Windows NT 10.0...
2026-10-19 12:44:30  INFO   gcloud found - C:\...\bin\gcloud.cmd
2026-10-19 12:44:31  INFO   CYBERSHIELD_AUTHCHECK started - Checking the sign-in
2026-10-19 12:44:32  INFO   Sign-in check OK - you@example.com
2026-10-19 12:45:02  INFO   Launch clicked - mode=allow sites=google.com,youtube.com
2026-10-19 12:45:40  INFO   Launch OK - 2 sites, url https://6080-...
```

Failures are recorded too, with the tail of what Cloud Shell actually replied, so
"it didn't work" becomes a specific line in a file:

```
2026-10-19 12:50:11  ERROR  Launch FAILED - no CYBERSHIELD_HOST in the reply
2026-10-19 12:50:11  ERROR  reply: ... Connection abandoned. / Tunnel stopped.
```

That file is the first thing to read after a failed demo. This document
(`RUN-LOG.md`) is the longer version: the causes, the fixes, and what is still
open.

---

## 7. How to re-check the whole thing in about a minute

From the app: click **Launch session**. It writes the policy, restarts the
container, waits for `healthy`, opens the browser and prints the URL.

From a terminal, if the app is suspect, these three commands tell you almost
everything:

```powershell
docker ps --filter name=cybershield          # up and healthy?
docker exec cybershield supervisorctl status # every program RUNNING?
docker exec cybershield ls -la /etc/firefox/policies/policies.json
```

And to actually see the screen:

```powershell
docker exec cybershield ffmpeg -f x11grab -video_size 1280x720 -i :1 -frames:v 1 -y /tmp/shot.png
```
