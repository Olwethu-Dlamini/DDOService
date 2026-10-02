# Backing up the automation stack

This replaces the backup section of Part 6 in `automation-money-guide-research.html`. The guide's
version compresses everything twice, copies Qdrant's files while Qdrant is writing to them, emails
through a `mail` command that isn't installed, and writes to a `/backups` folder that doesn't
exist.

`backup.sh` makes a backup every night and sends it somewhere off the VM with
[rclone](https://rclone.org), a free, open-source tool that can upload to more than 70 storage
services. Use **Google Drive**, or storage you run yourself: **SFTP** to another machine,
**Nextcloud**, or an S3-compatible server such as **Garage** or **MinIO**.

Run every command below on the VM as root: `ssh oll@ai`, then `su -`.

---

## What gets backed up

| Item | How | Why that way |
|---|---|---|
| Qdrant collections | One snapshot per collection, through Qdrant's snapshot API | Consistent while Qdrant keeps running |
| n8n data volume | `tar` of `/home/node/.n8n`, with n8n stopped for a few seconds | Holds the SQLite database **and the encryption key** for saved credentials |
| n8n workflows and credentials | `n8n export:workflow` and `export:credentials` as JSON | Easy to read, or to import into another n8n |
| Stack config | `docker-compose.yml` and `.env` | `.env` holds the Qdrant API key |

**Not backed up:** Ollama models. `docker exec ollama ollama pull mistral` downloads them again.

Each run is a folder named with the date and time, for example `2026-10-02_0330`. The VM keeps 7
days of them in `/var/backups/automation`, and the remote copy keeps 30 days.

> Backups contain your Qdrant key and n8n's encryption key. Encrypt the remote copy (step 3),
> especially on Google Drive.

---

## 1. Install the tools

```
apt install -y jq unzip
curl -fsSL https://rclone.org/install.sh | bash
wget -qO /usr/local/bin/automation-backup https://raw.githubusercontent.com/Olwethu-Dlamini/DDOService/main/backup/backup.sh
chmod +x /usr/local/bin/automation-backup
```

The install script gets the latest rclone. Debian's own package is older, and Google Drive login
sometimes fails on old versions.

Test a local-only backup before setting up any storage:

```
automation-backup
ls /var/backups/automation/*/
```

You should see `qdrant/`, `n8n-export/`, `n8n_data.tar.gz`, `docker-compose.yml` and `.env`.
`Qdrant: no collections yet` and `n8n: no workflows to export` are normal on a new stack.

---

## 2. Connect your storage

Pick **one** of the options below. Every option starts with `rclone config`, then `n` for a new remote.

### Option A: Google Drive

The VM has no browser, so you finish the Google login on your laptop.

1. On the **laptop**, install rclone: `sudo pacman -S rclone` on Arch.
2. On the **VM**, run `rclone config` and answer:

   | Prompt | Answer |
   |---|---|
   | name | `gdrive` |
   | Storage | `drive` (Google Drive) |
   | client_id / client_secret | leave blank |
   | scope | `drive.file`: rclone can only see files it created itself |
   | service_account_file | leave blank |
   | Edit advanced config? | `n` |
   | Use web browser to automatically authenticate? | **`n`** |

3. rclone prints a command like `rclone authorize "drive" "eyJ..."`. Run that on the **laptop**. A
   browser opens; log in to Google and allow access.
4. The laptop prints a token, a long `{...}` block. Paste it at the VM's `config_token>` prompt.
5. Configure as a Shared Drive? `n`. Then `y` to keep the remote, and `q` to quit.

Check it works: `rclone lsd gdrive:` should list folders without an error.

The free Google account gives you 15GB. The blank client_id uses rclone's shared Google key,
which can get rate-limited. If uploads start failing with `403 rate limit`, make your own key
using [rclone's Google Drive guide](https://rclone.org/drive/#making-your-own-client-id).

### Option B: SFTP to another machine you run (open source, simplest)

Any Linux machine with SSH works, such as `srv1` on your tailnet. On the VM:

```
ssh-keygen -t ed25519 -f /root/.ssh/backup -N ""
ssh-copy-id -i /root/.ssh/backup.pub backupuser@srv1
```

Then in `rclone config`:

| Prompt | Answer |
|---|---|
| name | `offsite` |
| Storage | `sftp` |
| host | `srv1` (its Tailscale name) |
| user | `backupuser` |
| key_file | `/root/.ssh/backup` |
| everything else | defaults |

Check: `rclone lsd offsite:`

### Option C: Nextcloud (open source, self-hosted)

In `rclone config`, choose Storage **`webdav`**:

| Prompt | Answer |
|---|---|
| name | `nextcloud` |
| url | `https://YOUR-NEXTCLOUD/remote.php/dav/files/YOUR-USER/` |
| vendor | `nextcloud` |
| user / pass | your Nextcloud user, plus an **app password** (Nextcloud → Settings → Security) |

### Option D: S3-compatible storage (Garage, MinIO, SeaweedFS)

In `rclone config`, choose Storage **`s3`**, then pick your server as the provider (or `Other`).
Enter the access key, secret key, and the endpoint URL, for example `http://srv1:3900` for Garage.
Create a bucket for the backups first.

---

## 3. Encrypt it (recommended)

An rclone **crypt** remote encrypts file contents and file names before they leave the VM. The
storage provider, Google included, only ever sees scrambled data. Set it up on top of the remote
from step 2:

`rclone config`, then `n`:

| Prompt | Answer |
|---|---|
| name | `backup` |
| Storage | `crypt` |
| remote | your step-2 remote plus a folder, e.g. `gdrive:automation-backups` or `offsite:/home/backupuser/automation` |
| filename_encryption | `standard` |
| directory_name_encryption | `true` |
| password | `g` to generate one, then **save it** |
| password2 (salt) | `g` to generate one, then **save it** |

⚠️ **Save both passwords in a password manager, somewhere other than the VM.** If the VM dies and
you've lost the passwords, the backups can never be decrypted. You can recreate the crypt remote
on any machine from the two passwords.

---

## 4. Point the backup at it

```
cat > /etc/automation-backup.env <<'EOF'
REMOTE=backup:
KEEP_LOCAL_DAYS=7
KEEP_REMOTE_DAYS=30
EOF
chmod 600 /etc/automation-backup.env
```

Use `REMOTE=backup:` if you set up encryption. Otherwise use your step-2 remote plus a folder, for
example `REMOTE=gdrive:automation-backups`.

Run it and check the upload:

```
automation-backup
rclone ls backup:
```

`rclone ls` lists the files with their real names, because rclone decrypts them for you. In the
Google Drive web page, the same files show up with scrambled names.

---

## 5. Schedule it

```
automation-backup --install
```

This sets it to run every night at about 03:30 (with up to 10 minutes of random delay). If the VM
was off at that time, it runs as soon as the VM starts again. To check on it:

```
systemctl list-timers automation-backup.timer     # next run
journalctl -u automation-backup -n 30             # last run's output
```

n8n stops for a few seconds during each run, so a webhook that arrives at 03:30 may fail.

---

## 6. Restore

Copy a backup back to the VM, picking a date from `rclone lsd backup:`:

```
rclone copy backup:2026-10-02_0330 /root/restore
cd /opt/automation
```

**Stack config** (only on a new VM):

```
cp /root/restore/docker-compose.yml /root/restore/.env /opt/automation/
docker compose up -d
```

**n8n** (replaces everything in n8n with the backup):

```
docker compose stop n8n
docker run --rm -v automation_n8n_data:/data -v /root/restore:/in alpine \
  sh -c 'rm -rf /data/* /data/.[!.]* ; tar xzf /in/n8n_data.tar.gz -C /data && chown -R 1000:1000 /data'
docker compose start n8n
```

The `chown` matters: n8n runs as user 1000 and won't start if it can't read its files.

**Qdrant**, one collection at a time:

```
source /opt/automation/.env
curl -X POST "http://localhost:6333/collections/COLLECTION/snapshots/upload?priority=snapshot" \
  -H "api-key: $QDRANT_API_KEY" -F snapshot=@/root/restore/qdrant/COLLECTION.snapshot
```

That creates the collection, or replaces it if it already exists.

**Ollama:** `docker exec ollama ollama pull mistral`

**Test a restore every few months.** A backup you've never restored is a guess.

---

## Second layer: Proxmox VM backups

`backup.sh` saves the data. Proxmox can also save the **whole VM**: Datacenter → Backup → Add,
pick VM 101, a schedule, and a storage target. That brings back the VM exactly as it was,
including Docker and the OS setup. It only protects you if the backup storage is on a different
disk or machine from the VM itself.

---

## Watching resource use

The guide's monitoring command still works. Run it on the VM:

```
watch -n 5 'docker stats --no-stream && echo "---" && free -h'
```

If memory sits near the limit, lower `N8N_MEM` or `OLLAMA_MEM` in `/opt/automation/.env`, then
run `docker compose up -d`.
