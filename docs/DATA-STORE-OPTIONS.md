# Where the payment data lives: the options

The payment bot needs somewhere to keep two lists: **customers** (name, phone, DStv account,
amount due, profit, due day) and **payments** (who paid which month, when, and how much). This
guide compares the places that data could live, what it is like to update it in each, and what
each costs on a VM that many workflows share.

**Measured:** 2026-10-08. The memory figures for the self-hosted apps come from running them on
the laptop (section 4).

---

## 1. At a glance

| | Google Sheets | n8n Data Tables | Grist | NocoDB | Baserow |
|---|---|---|---|---|---|
| **Runs** | Google's cloud | Inside n8n, already running | New container on the VM | New container on the VM | New container on the VM |
| **Extra memory on the VM** | None | **None** | **~220MB**, 296MB peak (works under a 384MB cap) | **~510MB**, 735MB peak; **crashes under 512MB**, needs a 1GB cap | 2GB minimum per its docs (not measured) |
| **Licence** | Proprietary service | Sustainable Use (same as n8n) | **Apache-2.0** (open source) | Sustainable Use | MIT core (open source) |
| **Setup** | Google Cloud project, service account, JSON key, share the sheet | **None**: created through n8n's API | Add a container, create an API key | Add a container, create an API token | Add a container, create a token |
| **Editing by hand** | Best: the Sheets app on your phone, with formulas | A plain grid in n8n's web page | A real spreadsheet with formulas, in the browser | A spreadsheet-style grid, in the browser | A spreadsheet-style grid, in the browser |
| **Reachable from** | Anywhere | Tailscale | Tailscale | Tailscale | Tailscale |
| **n8n node** | Google Sheets | Data Table | Grist | NocoDB | Baserow |
| **Backed up by** | Google's version history | `automation-backup` (it lives in n8n's database) | Its volume must be added to the backup | Its volume must be added to the backup | Its volume must be added to the backup |

---

## 2. What updating looks like

### The same in every option: WhatsApp

Most updates are one message in your "Message yourself" chat. The bot does the writing, whichever
store sits behind it, and repeats each change back for a `yes` before saving.

| You send | The bot |
|---|---|
| `#paid <name>` | Marks this month paid, logs it, confirms to the customer |
| `#add <name> <phone> <DStv ref> <amount> <profit> <due day>` | Adds a customer |
| `#set <name> amount 175` | Changes one value (a DStv price rise, a new due day) |
| `#remove <name>` | Stops reminders; the payment history stays |
| `#unpaid`, `#due` | Lists who hasn't paid, or who is due soon |

### When you edit by hand

| Option | How |
|---|---|
| **Google Sheets** | Open the Sheets app and type, as you do now. Formulas recalculate. |
| **n8n Data Tables** | Open `http://ai:5678` → **Overview → Data tables → DStv customers**. Click a cell to change it, add or delete rows. No formulas: the bot works out "customer pays" and the totals. |
| **Grist** | Open `http://ai:8484` on the laptop or phone. It looks and behaves like a spreadsheet, formulas included (written in Python). |
| **NocoDB / Baserow** | Open their web page. A grid like Airtable: views, filters, forms. Formulas are more limited than a spreadsheet's. |

Every self-hosted option is reachable only over Tailscale, so the phone needs the Tailscale app
switched on.

### Bulk changes

Any of them can be loaded from an Excel file: through n8n's API for Data Tables, by import in the
apps, or by uploading to Google Drive. A `#export` command can send the current list back to you
as a spreadsheet on WhatsApp.

---

## 3. Choosing

**Suggestion, for this VM:**

- **n8n Data Tables** if the WhatsApp commands will be the main way you update. It costs no memory,
  needs no setup and is covered by the backup that already exists. Its weak spot is hand-editing,
  which is plain.
- **Grist** if you want a real spreadsheet on your phone that is also open source. It costs about
  300MB of the VM's 12GB at peak, and its data folder has to be added to the backup.
- **Google Sheets** if editing on the phone matters most and the data living with Google is fine.
  It costs no memory, but needs the Google Cloud setup.

**NocoDB** and **Baserow** do the same job as Grist for more memory: NocoDB measured at about twice Grist's, and Baserow asks for 2GB.

Switching later is not hard: the bot's workflows read and write through one n8n node, so moving
means swapping that node and copying the data across.

---

## 4. How the memory was measured

Each app ran on the laptop in Docker, idle with no data, after loading its web page three times.
The number is the container's own memory (`anon` in its cgroup's `memory.stat`), not the cgroup's
total, which also counts disk cache. See section 5 of [`SYSTEM-DESIGN.md`](SYSTEM-DESIGN.md).

| App | Version | No cap | Under a cap |
|---|---|---|---|
| NocoDB | `nocodb/nocodb:2026.09.1` | 776MB, 1,000MB peak | **512MB cap: crashed at start** (`JavaScript heap out of memory`). 1GB cap: 513MB, 735MB peak |
| Grist | `gristlabs/grist:1.7` | 235MB, 522MB peak | 384MB cap: 220MB, 296MB peak, no OOM kill |

Node.js apps take more memory when nothing limits them, which is why both use less under a cap.
Real data adds to these figures: measure again on the VM before setting a cap there.

Baserow was not run. Its documentation asks for at least 2GB, because its image bundles its own
PostgreSQL and Redis.
