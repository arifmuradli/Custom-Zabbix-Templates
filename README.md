# Zabbix Custom Templates

Custom Zabbix templates I built for real production issues. The official templates either didn't scale or didn't cover what I needed.

| Template | What it monitors | Files |
|---|---|---|
| **Veeam Backup Lite by HTTP** | Veeam B&R jobs, repositories, proxies and tape jobs | [`veeam_lite_template.yaml`](Veeam/veeam_lite_template.yaml), [`veeam_tape.ps1`](Veeam/veeam_tape.ps1) |
| **Veeam License by HTTP** | Veeam B&R license status, expiration and instance usage | [`template_veeam_license_by_http.yaml`](Veeam/template_veeam_license_by_http.yaml) |

Tested on **Zabbix 7.2** and **Veeam Backup & Replication 13**.

---

## Why these exist

### The problem

I monitored Veeam Backup & Replication with the official **"Veeam Backup and Replication by HTTP"** template. On our server, its main item (`Get metrics`) kept failing with timeouts.

The official template makes one large Script item that calls five REST endpoints one after another, and every discovery rule and item depends on it:

```
proxies → managedServers → repositories/states → jobs/states → sessions
```

The Veeam REST log showed what was going on. Every call finished in about 100 ms except **`/api/v1/jobs/states`**, which hung for minutes and then failed:

```
[DBRETRY] [MSSQL] SqlTimeout error has occurred.
Affected stored procedure is [dbo].[Rest.GetJobStatesFiltered]
```

The Veeam configuration database is large (around 38 GB), with years of session history and a big tape catalog. That stored procedure couldn't return in time. And because everything depends on one master item, **one slow endpoint took down all of the monitoring**: jobs, repositories and proxies alike. A longer timeout made things worse, because overlapping polls stacked up more copies of the same slow query on the SQL Server.

Two other gaps came up while I worked on this:

- **Tape jobs aren't in the Veeam REST API at all.** There are no endpoints for tape jobs or tape sessions, so no HTTP template can see a job stuck in *WaitingTape*.
- **License usage isn't covered at all**, and it can't be added to the same template. `/api/v1/license` is available only to the **Veeam Backup Administrator** role. A read-only Backup Viewer account gets `403 Forbidden`, and Veeam has no custom role that grants license read access alone.

### The approach

I built a lite version of the template with the help of **Claude** (Anthropic's AI assistant). We read the REST logs, found the slow query, and redesigned the template around it:

- **Several small master items instead of one large one.** Each has its own interval and does its own token request, query and logout. If one fails, the others keep working.
- **Never call `jobs/states`.** Job status comes from the latest session of each job instead.
- **Tape through the Zabbix agent.** A small PowerShell script runs locally on the Veeam server through a `UserParameter`. There's no scheduled task, and the Zabbix server doesn't run anything remotely.
- **Alerts that don't nag.** Failed or warning jobs alert once, closing a problem manually keeps it closed, and it resolves automatically when the job succeeds again.
- **License monitoring as a separate template.** It needs an administrator account, and I didn't want that high-privilege account used everywhere. So the license template has its own credentials and makes one call per hour, to one endpoint. All other monitoring stays on the read-only Backup Viewer account.

---

## Repository structure

```
.
├── README.md
└── Veeam/
    ├── veeam_lite_template.yaml              # Veeam Backup Lite by HTTP
    ├── veeam_tape.ps1                        # Tape status script (Zabbix agent UserParameter)
    └── template_veeam_license_by_http.yaml   # Veeam License by HTTP
```

---

## Veeam Backup Lite by HTTP

### Requirements

- Zabbix **7.0+** (exported from 7.2)
- Veeam B&R with the REST API enabled (`Veeam Backup Server RESTful API Service`, port **9419**)
- A Veeam account with the **Backup Viewer** role
- For tape monitoring: **Zabbix agent 7.0+** on the Veeam server. That version is needed for the per-item 120s timeout.

### How it works

| Master item | Type | Source | Default interval | Feeds |
|---|---|---|---|---|
| Get sessions | Script | `GET /api/v1/sessions?createdAfterFilter=<now-26h>` | 5m | Failed, warning and long-running jobs |
| Get repositories | Script | `GET /api/v1/backupInfrastructure/repositories/states` | 10m | Repository discovery: capacity, free, used, free %, online |
| Get proxies | Script | `GET .../proxies` + `GET .../managedServers` | 1h | Proxy discovery: max tasks, host name, host type |
| Tape status | Zabbix agent (active) | `veeam_tape.ps1` running locally (Veeam PowerShell) | 20m | Tape jobs that are waiting, failed or ended with a warning |

Everything else is a **dependent item**, so it costs no extra API calls.

**Job status without `jobs/states`:** within the lookback window, the script takes the **latest session of each job**. A job counts as failed or warning only if that latest session finished with that result. A job that failed and then succeeded on retry doesn't alert.

### Triggers

| Trigger | Severity | Behavior |
|---|---|---|
| Veeam: Job(s) failed | Average | Fires once per new failure. The problem name shows the job name and Veeam's error message. Resolves on its own when no job is failed |
| Veeam: Job(s) ended with warning | Warning | Same as above |
| Veeam: N session(s) running longer than 12h | Warning | |
| Veeam: Repository [name] free space below 15% | Warning | Per repository |
| Veeam: Repository [name] is offline | Average | Per repository |
| Veeam: Tape job(s) waiting for tape | **High** | Job in `WaitingTape` for 20 min or more. This usually means no free media in the pool, or the library or drive is offline |
| Veeam: Tape job(s) failed | Average | Enabled tape jobs only |
| Veeam: Tape job(s) ended with warning | Warning | Enabled tape jobs only |
| Veeam: Tape status script error | Warning | E.g. a permissions problem |

All triggers allow manual close. For the "fire once" triggers, a closed problem stays closed until the set of failing jobs changes.

### Installation

**1. Import the template**

Data collection → Templates → Import → `Veeam/veeam_lite_template.yaml`.

**2. Link it to the Veeam host and set the macros**

| Macro | Example |
|---|---|
| `{$VEEAM.API.URL}` | `https://veeam-server:9419` |
| `{$VEEAM.USER}` | `DOMAIN\zabbix.veeam` |
| `{$VEEAM.PASSWORD}` | secret |

**3. (Optional) Tape monitoring: set up the agent on the Veeam server**

Copy `Veeam/veeam_tape.ps1` to the agent's scripts folder, for example:

```
C:\Program Files\Zabbix Agent 2\scripts\veeam_tape.ps1
```

Add this line to `zabbix_agent2.conf` (or `zabbix_agentd.conf`):

```
UserParameter=veeam.tape.status[*],powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Program Files\Zabbix Agent 2\scripts\veeam_tape.ps1" -WaitMinutes $1
```

Restart the agent and test it:

```powershell
Restart-Service "Zabbix Agent 2"
& "C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe" -c "C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf" -t "veeam.tape.status[20]"
```

You should get one line of JSON. The number is the wait threshold in minutes. In Zabbix it comes from `{$VEEAM.TAPE.WAIT.MIN}`.

> The agent runs as LocalSystem. If the output contains `"error":"...not authorized..."`, add `NT AUTHORITY\SYSTEM` as **Backup Viewer** in Veeam → Users and Roles.

If you don't use tape, disable the `Veeam: Tape status (agent)` item.

**4. Check it**

Open **Veeam: Get sessions** and click **Test**. Then look at the **Session states** and **Session types** items to see the values your Veeam server returns.

### Macros

| Macro | Default | Description |
|---|---|---|
| `{$VEEAM.API.URL}` | `https://localhost:9419` | REST API base URL |
| `{$VEEAM.API.VERSION}` | `1.3-rev1` | `x-api-version` header (VBR 13) |
| `{$VEEAM.USER}` / `{$VEEAM.PASSWORD}` | | Backup Viewer account |
| `{$VEEAM.HTTP.PROXY}` | | Optional HTTP proxy |
| `{$VEEAM.DATA.TIMEOUT}` | `60s` | Script timeout. Keep it below the intervals |
| `{$VEEAM.SESSIONS.INTERVAL}` | `5m` | Sessions poll interval |
| `{$VEEAM.REPOS.INTERVAL}` | `10m` | Repositories poll interval |
| `{$VEEAM.PROXIES.INTERVAL}` | `1h` | Proxies poll interval |
| `{$VEEAM.TAPE.INTERVAL}` | `20m` | Tape script interval |
| `{$VEEAM.SESSIONS.HOURS}` | `26` | Session lookback window, in hours |
| `{$VEEAM.RUNNING.MAX.HOURS}` | `12` | Long-running threshold |
| `{$VEEAM.REPO.FREE.MIN.PCT}` | `15` | Repository free space threshold, in % |
| `{$VEEAM.TAPE.WAIT.MIN}` | `20` | Minutes in `WaitingTape` before alerting |
| `{$VEEAM.SESSION.NAME.NOT_MATCHES}` | `^(Security & Compliance Analyzer\|Malware Detection\|Configuration Database Resynchronize.*)$` | Session names ignored completely, e.g. Veeam's own background tasks |
| `{$VEEAM.SESSION.TYPE.NOT_MATCHES}` | `CHANGE_IF_NEEDED` | Session types ignored completely |
| `{$VEEAM.RUNNING.NAME.NOT_MATCHES}` | `CHANGE_IF_NEEDED` | Excluded only from the long-running check |

### Compared with the official template

| | Official | Lite |
|---|---|---|
| Master items | 1 (5 endpoints in sequence) | 3 Script items + 1 agent item, independent |
| Calls `jobs/states` | Yes | **No** |
| Per-session items via LLD | Yes, every session over 7 days | No. Counts and names only |
| Job failed alert | Per job | One problem listing the failed jobs and error messages |
| Job warning alert | No | Yes |
| Repository free %, offline alerts | No | Yes |
| Long-running sessions | No | Yes |
| Tape jobs | No (REST has no tape endpoints) | Yes, through the agent |
| Job enabled/disabled status | Yes (from `jobs/states`) | No |

### Known limitations

- **A job that didn't run at all** (disabled, or missed its schedule) produces no session, so it isn't detected.
- **Weekly or monthly jobs:** sessions are only checked within `{$VEEAM.SESSIONS.HOURS}`. Raise it (e.g. to `170` for weekly jobs) if you need to.
- The tape check depends on the Veeam PowerShell module. Loading it takes 10–20 seconds, which is why the agent item has a 120s timeout.

---

## Veeam License by HTTP

### The problem

Neither the official template nor the Lite one monitors licensing. Veeam's REST API does have the data, at `GET /api/v1/license`: status, expiration date, and licensed versus used instances. But that endpoint is available only to the **Veeam Backup Administrator** role:

| Account | `/api/v1/license` |
|---|---|
| Backup Viewer (read-only) | `403 Forbidden` |
| Backup Administrator | `200 OK` |

There's no custom role that grants license read access alone, so an administrator account is the only option.

### The approach

I didn't want that high-privilege account used by every item. So license monitoring is a **separate template** with its own credentials:

- `{$VEEAM.LICENSE.USER}` and `{$VEEAM.LICENSE.PASSWORD}` are used **only** by this template. The Backup Lite template stays on the read-only Viewer account.
- It makes **one call per hour, to one endpoint**: token → `/api/v1/license` → logout.
- The password is stored as a **Secret text** macro on the host.

I also tried a self-refreshing refresh token, to avoid storing a password. I rejected it: a refresh token issued to an admin is just as powerful as the password, and rotating it means writing back to Zabbix through the API, which is a second credential to protect and another way for things to break.

### Items

| Item | Key | Source |
|---|---|---|
| Get license data (master, Script, 1h) | `veeam.license.get` | `GET /api/v1/license` |
| License status | `veeam.license.status` | `$.status` |
| License licensed to | `veeam.license.licensed_to` | `$.licensedTo` |
| License days until expiration | `veeam.license.days_left` | `$.expirationDate` → days |
| Instances licensed | `veeam.license.instances.licensed` | `$.instanceLicenseSummary.licensedInstancesNumber` |
| Instances used | `veeam.license.instances.used` | `$.instanceLicenseSummary.usedInstancesNumber` |
| Instances usage, % (calculated) | `veeam.license.instances.pct` | used / licensed × 100 |

Instance values are stored as floats, because some workloads consume fractional instances.

The master item doesn't store history (`0`), so it has no Latest data, but its dependent items do. Set history to `1d` temporarily if you want to see the raw JSON.

### Triggers

| Trigger | Severity |
|---|---|
| Veeam: License status is not Valid | High |
| Veeam: License expires in less than 7 days | High |
| Veeam: License expires in less than 30 days | Warning (depends on the 7-day trigger) |
| Veeam: License instance usage >= 100% | High |
| Veeam: License instance usage >= 90% | Warning (depends on the 100% trigger) |
| Veeam: No license data for 3h (check credentials / API) | Warning |

The dependencies prevent duplicate alerts. When the High trigger fires, the Warning one is suppressed.

### Installation

1. Create a dedicated Veeam account with the **Veeam Backup Administrator** role, used only for this. Lock it down: deny interactive logon and limit where it can sign in from.
2. Import `Veeam/template_veeam_license_by_http.yaml` and link it to the Veeam host.
3. Set these macros on the **host**:

   | Macro | Value |
   |---|---|
   | `{$VEEAM.LICENSE.USER}` | `DOMAIN\veeam.license` |
   | `{$VEEAM.LICENSE.PASSWORD}` | password, as **Secret text** |
   | `{$VEEAM.API.URL}` | `https://veeam-server:9419` (shared with the Lite template) |

4. Run **Execute now** on `Veeam: Get license data`, then check the dependent items in Latest data.

### Macros

| Macro | Default | Description |
|---|---|---|
| `{$VEEAM.LICENSE.USER}` | | Backup Administrator account, used only for this template |
| `{$VEEAM.LICENSE.PASSWORD}` | | Secret text |
| `{$VEEAM.LICENSE.API.VERSION}` | `1.2-rev0` | `x-api-version` header |
| `{$VEEAM.LICENSE.EXPIRE.WARN}` | `30` | Days before expiration, Warning |
| `{$VEEAM.LICENSE.EXPIRE.CRIT}` | `7` | Days before expiration, High |
| `{$VEEAM.LICENSE.USAGE.WARN}` | `90` | Instance usage %, Warning |
| `{$VEEAM.LICENSE.USAGE.CRIT}` | `100` | Instance usage %, High |

### Notes

- Built for **instance-based** licensing (VUL). On a socket license, `instanceLicenseSummary` is empty, so you'd change the JSONPaths to `$.socketLicenseSummary.licensedSocketsNumber` / `usedSocketsNumber`.
- The license response doesn't include `supportExpirationDate`, so there's no support-expiration item.
- `Cannot evaluate function: not enough data` on the usage % item right after import is normal. It goes away once the master item has run, or after you click **Execute now** on it.

---

## Troubleshooting

**Item times out.** Watch the REST log on the Veeam server while you test:

```powershell
Get-Content 'C:\ProgramData\Veeam\Backup\Svc.VeeamRestAPI.log' -Tail 50 -Wait
```

- Nothing appears in the log → the problem is on the network or firewall side.
- `SqlTimeout ... Rest.GetJobStatesFiltered` → the slow configuration DB query this template was built to avoid.

**Test the API by hand** (Bruno, Postman or curl):

```
POST {{baseUrl}}/api/oauth2/token
  x-api-version: 1.3-rev1
  Content-Type: application/x-www-form-urlencoded
  grant_type=password&username=...&password=...

GET {{baseUrl}}/api/v1/sessions?createdAfterFilter=2026-01-01T00:00:00Z&limit=50
  x-api-version: 1.3-rev1
  Authorization: Bearer {{token}}
```

---

## Credits

Built and tested in production, with help from [Claude](https://claude.ai) by Anthropic for log analysis, API troubleshooting, template design and the scripts.

## License

<!-- TODO: choose a license (e.g. MIT) and add a LICENSE file -->
