# Troubleshooting: "I can't reach `ai`" and "n8n shows failed executions"

What to run when `http://ai:5678` won't open, or the n8n editor shows failed executions, and how
to read what you get back. Written after the incident of 2026-11-09 (section 5), where the
server was fine and the laptop's Wi-Fi had dropped.

---

## 1. Run the check first

From the laptop, in this repo:

```bash
bash stack/ai-check.sh            # failed executions from the last 7 days
bash stack/ai-check.sh --days 30  # look further back
```

It checks four layers from the bottom up and stops at the first one that is down, because
every layer above it would fail for the same reason. A healthy run looks like this:

```
==> 1. This machine: is it online?
  info  connected to: Wired connection 1
  ok    DNS resolves github.com
  ok    HTTPS to github.com answers (200)
  ok    Tailscale netcheck: UDP works, nearest relay Johannesburg
==> 2. Tailnet: does ai answer?
  info  Tailscale lists ai as: online (the coordination server's view, not proof)
  ok    3 of 3 pings answered, via DERP(jnb)
==> 3. n8n: does http://ai:5678 answer?
  ok    /healthz answers 200
==> 4. Executions that failed in the last 7 days
  2026-11-05 11:55  manual    <workflow name>  [<node that failed>]
        <the error n8n recorded>

  1 failed, 1 of them runs started from the editor (tests).
All good: this machine is online, ai answers, n8n is healthy, and no automatic run failed.
```

Exit code 0 means nothing to fix; 1 means a layer is down or an automatic run failed. Layer 4
needs the n8n API key, read from `N8N_API_KEY` or `~/.config/ai-n8n-api-key` (the same place as
the workflows repo's `tools/n8n-sync.py`). The key is never printed. Without it, layers 1 to 3
still run and the script says executions were not checked.

---

## 2. The four layers

| Layer | What the script checks | When it fails, it usually means | Look next |
|---|---|---|---|
| 1. This machine | DNS and HTTPS to github.com; `tailscale netcheck` | The laptop has no internet: Wi-Fi dropped, cable out, router down | `journalctl -u wpa_supplicant -u NetworkManager --since -2h \| grep -iE 'beacon\|lost\|disconnect\|activated'` |
| 2. Tailnet | `tailscale ping ai`, three tries | Listed **offline**: the VM is off or tailscaled stopped on it. Listed **online** but no answer: the path is broken, or the VM is hung | VM 101 in the Proxmox web UI (`pve:8006`): running? console responsive? |
| 3. n8n | `GET /healthz` on port 5678 | **Refused**: the VM is up but n8n's container is stopped or restarting. **Timeout**: n8n is hung or the VM is out of memory | On the VM: `cd /opt/automation && sudo docker compose ps`, `sudo docker logs --tail 50 n8n`, `free -h` |
| 4. Executions | n8n API: runs with status `error` or `crashed` in the last N days | A workflow broke. The `mode` column says whether a person ran it from the editor (`manual`) or a trigger did (`webhook`, `trigger`, ...) | Open the execution in the editor; the script names the node and quotes the error |

---

## 3. Traps

**Tailscale's "online" is not proof.** `tailscale status` shows what the coordination server last
heard from each device. If your own laptop is offline, it keeps showing the last list it got,
so `ai` stays "online" while nothing reaches it. Only an answer counts: `tailscale ping`, or the
`lastRecv` value in tailscaled's log, which is how long ago anything arrived from that device:

```bash
journalctl -u tailscaled --since -2h | grep -E 'timeout opening|lastRecv'
# open-conn-track: timeout opening (TCP ... => 100.x.x.x:5678) to node [...]; online=yes, lastRecv=33m15s
```

`online=yes` with a `lastRecv` that keeps growing means the device is on the list but silent.

**`tailscale ping` exits 1 even when it got answers.** If every reply comes through a Tailscale
relay (DERP), it ends with `direct connection not established` and exit code 1. The answers
still count; the script counts the `pong` lines instead of trusting the exit code. A relayed
path works, it is only slower (tens of milliseconds more).

**Refused and timeout mean different things.** `curl` exit code 7 (connection refused) means
the VM answered and said nothing listens on that port, so the machine is fine and the service
isn't. Exit code 28 (timeout) means nothing answered at all.

**A failed execution in the editor is not an outage.** Runs started with *Test workflow* are
saved as executions too, with mode `manual` (or `retry` when you retry one). When you are
building a workflow, most failures are these. The script counts them as tests and only treats
failures started by a trigger as something to fix.

**An empty execution list does not prove a workflow ran.** Workflows set to not save successful
runs (`saveDataSuccessExecution: none`) leave nothing behind when they work. The script lists
which active workflows do that. To prove one runs, trigger it and watch for its effect (the
Telegram message, the reply).

---

## 4. After the fact: what happened while I wasn't looking?

The laptop keeps the evidence. Use the time window of the failure:

```bash
# Was the laptop itself offline?
journalctl -u tailscaled --since '06:30' --until '08:00' \
  | grep -E 'UDP is blocked|PollNetMap|dns udp query|timeout opening'

# Did the Wi-Fi drop, and when did a network come back?
journalctl -u wpa_supplicant -u NetworkManager --since '06:30' --until '08:00' \
  | grep -iE 'beacon-loss|ssid-not-found|activated'
```

`UDP is blocked`, `PollNetMap ... failed` and DNS timeouts together mean the laptop had no
internet. `CTRL-EVENT-BEACON-LOSS` followed by `ssid-not-found` means the access point itself
disappeared (switched off or rebooted), not that the laptop dropped it.

Whether `ai` restarted can be told from outside: Tailscale gives every device a new *disco key*
when tailscaled starts, and tailscaled's log on the laptop prints it for `ai`
(`node [...] d:<key> now using ...`). The same key before and after the gap means tailscaled on
`ai` did not restart, which makes a reboot unlikely.

---

## 5. Worked example: 2026-11-09

**Symptom.** `http://ai:5678` wouldn't open in the morning, `tailscale status` still showed `ai`
online, and the n8n editor showed failed executions. It looked like the server was down.

**What the logs showed** (times SAST):

| Time | Event |
|---|---|
| 06:58 | The laptop's Wi-Fi access point stopped sending beacons and vanished (`ssid-not-found`). From then on: DNS timeouts, `UDP is blocked`, the Tailscale relay and coordination server unreachable |
| 06:58 to 07:31 | Two attempts to open n8n timed out. tailscaled logged `online=yes, lastRecv=33m15s` for `ai`: listed online, silent for 33 minutes |
| 07:31 | The laptop joined another network; the path to `ai` came back within 30 seconds |
| afterwards | Every check passed. `ai`'s disco key was unchanged, so its tailscaled never restarted |

**The failed executions** were unrelated: all were `manual` runs from the editor while a
workflow was being built (HTTP 422 from the service it called, and one test against an endpoint
that fails on purpose to practise retries). None came from a trigger.

**Cause.** The laptop lost its internet. The server, n8n and the workflows were fine.

**Lesson.** Check your own machine first (layer 1), and don't take Tailscale's "online" as an
answer. `stack/ai-check.sh` came out of this incident.
