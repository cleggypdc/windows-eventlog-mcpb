# Windows Event Log for Claude Desktop

Ask Claude why your PC is misbehaving. This extension gives Claude Desktop access to your Windows Event Logs so you can diagnose crashes, errors, and warnings in plain English — no log parsing required.

Packaged as an MCPB Desktop Extension with a pure PowerShell MCP server.

## What it does

Once installed, you can ask Claude things like:

- *"Why did my PC restart unexpectedly last night?"*
- *"What errors have occurred since I booted up?"*
- *"Which application is generating the most warnings?"*
- *"What crashed in the last 30 minutes? Check the Application log"*
- *"Get me the full details for event record 12345"*

Claude reads the raw event data and explains what it means, what likely caused it, and what you might do about it.

## How it works

This extension is a pure PowerShell MCP server. It shells out to `Get-WinEvent` and returns JSON to Claude Desktop, which sends it to Anthropic's API for reasoning. The extension itself makes no network calls — but **the event log data you query is sent to Anthropic's servers** as part of your Claude conversation. See [Data privacy](#data-privacy) below.

The PowerShell script is human-readable — every line of it is auditable before you run it.

## Prerequisites

- Windows 10/11 or Windows Server 2016+
- PowerShell 7+ (`pwsh`) — [download here](https://github.com/PowerShell/PowerShell/releases/latest)
- Claude Desktop with MCPB extension support

To check if you have PowerShell 7, open a terminal and run:

```powershell
pwsh --version
```

## Installation

### One-click install (recommended)

1. Download the latest `windows-eventlog-mcp.mcpb` from the [Releases](../../releases) page
2. Open Claude Desktop
3. Go to **Settings → Extensions**
4. Click **Install Extension…** and select the downloaded `.mcpb` file
5. Restart Claude Desktop

### Direct (`claude_desktop_config.json`)

Add to your `mcpServers` configuration:

```json
{
  "mcpServers": {
    "windows-eventlog": {
      "command": "pwsh",
      "args": ["-NoProfile", "-NonInteractive", "-File", "C:\\path\\to\\server\\server.ps1"],
      "env": {
        "EVENTLOG_ALLOWED_LOGS": "System,Application"
      }
    }
  }
}
```

## Configuration

### Allowed logs

By default, the server only permits access to the `System` and `Application` event logs, controlled by the `EVENTLOG_ALLOWED_LOGS` environment variable (comma-separated log names).

To grant access to additional logs, set the variable in your `claude_desktop_config.json`:

```
EVENTLOG_ALLOWED_LOGS=System,Application,Security
```

Common log names:

| Log | Contains | Privacy note |
|-----|----------|--------------|
| System | Hardware, driver, and OS events | Low sensitivity |
| Application | App crashes, errors, warnings | Low sensitivity |
| Security | Logon events, privilege use, audit | Contains usernames, logon times, auth events |
| Microsoft-Windows-PowerShell/Operational | PowerShell command history | Contains command text |
| Microsoft-Windows-Sysmon/Operational | Process, network, file activity | Detailed system telemetry |

> **Security note:** The Security and operational logs can contain personally identifiable information and detailed activity traces. Any log accessible to the server is also accessible to Claude and, by extension, to anything in the conversation context. Only add logs to the allowlist if you understand what they contain and who can see the conversation.

### Limits

The server enforces hard limits to prevent resource exhaustion. These are not configurable — they are safety boundaries.

| Limit | Value | Description |
|-------|-------|-------------|
| Max results per query | 500 | Caps `max_results` parameter |
| Max time window | 1440 min (24h) | Caps `minutes` parameter |
| Max top sources | 100 | Caps `top_n` parameter |
| Source analysis cap | 10,000 events | Max events scanned for `get_top_event_sources` |
| Request line size | 64 KB | Max JSON-RPC message length |

## Tools

Claude will automatically use the appropriate tool based on your question.

### `get_events_since_boot`

Events from the current boot session. Useful for "what went wrong since I turned on my PC?"

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| log_name | string | System | Event log (must be in allowlist) |
| level | integer | — | 1=Critical, 2=Error, 3=Warning, 4=Info, 5=Verbose |
| max_results | integer | 20 | Maximum events to return (capped at 500) |

### `get_recent_events`

Events from the last N minutes. Good for "my app crashed 10 minutes ago, what happened?" For application crashes, use the `Application` log.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| log_name | string | System | Event log (must be in allowlist) |
| minutes | integer | 60 | Look back this many minutes (1–1440) |
| level | integer | — | 1=Critical, 2=Error, 3=Warning, 4=Info, 5=Verbose |
| max_results | integer | 20 | Maximum events to return (capped at 500) |

### `get_top_event_sources`

Most frequent event sources over a time window. Identifies noisy or problematic components.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| log_name | string | System | Event log (must be in allowlist) |
| minutes | integer | 60 | Look back this many minutes (1–1440) |
| top_n | integer | 10 | Number of top sources to return (capped at 100) |

### `get_event_detail`

Full detail for a single event by RecordId. Use after browsing to drill into a specific entry.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| log_name | string | System | Event log (must be in allowlist) |
| record_id | integer | — | Required. The RecordId of the event |

## Examples

### Example 1: Diagnosing errors since boot

**User prompt:** "What errors have occurred since I started my PC today?"

**Expected behaviour:**
- Claude calls `get_events_since_boot` on the System log filtered to level 2 (Error)
- Returns a list of error events with timestamps, source names, and messages
- Claude summarises what each error means in plain English and flags anything worth investigating

---

### Example 2: Investigating a recent crash

**User prompt:** "My application crashed about 20 minutes ago — what happened?"

**Expected behaviour:**
- Claude calls `get_recent_events` on the Application log with `minutes=30` and `level=2`
- Returns error events from that window including the crashing application's name and error message
- Claude identifies the likely cause and suggests next steps, such as reinstalling, updating, or checking for conflicting software

---

### Example 3: Finding noisy or misbehaving components

**User prompt:** "Which part of Windows is generating the most warnings right now?"

**Expected behaviour:**
- Claude calls `get_top_event_sources` on the System log over the last 60 minutes
- Returns a ranked list of event sources by frequency
- Claude explains what each source is, why it might be noisy, and whether any warrant further investigation

## Data privacy

**Event log data is sent to Anthropic.** When you ask Claude a question that triggers a tool call, the returned event log JSON is included in your conversation and sent to Anthropic's API over HTTPS. This is how all MCP tools work — the extension has no control over it.

### What is sent

The server strips most internal fields before returning data. Each event contains:

- **Id, RecordId, TimeCreated** — event identifiers and timestamps
- **ProviderName, LogName** — which service or component generated the event
- **Level, LevelDisplayName** — severity (Critical, Error, Warning, etc.)
- **Message** — free-text error description
- **ProcessId** — the OS process that logged the event
- **Properties** — structured event parameters (values only)

Fields like BookmarkXml, MatchedQueryIds, BinaryLength, and internal .NET object metadata are stripped and never sent.

### What can be sensitive

Even with field stripping, the `Message` and `Properties` fields may contain:

- **File paths** that reveal directory structure, usernames, or project names
- **Hostnames and IP addresses** from network-related events
- **Service account names** and **domain names** from authentication events
- **Installed software names** from application errors
- **Timestamps** that correlate with user activity patterns

If the **Security log** is enabled, the exposure increases significantly to include usernames, logon/logoff times, source IP addresses, authentication types, and privilege escalation events.

### Who should be cautious

- **Corporate/enterprise users** — event logs may contain internal hostnames, domain structures, and service accounts that constitute sensitive infrastructure information. Check with your security team before installing.
- **Regulated environments** (SOC 2, HIPAA, PCI-DSS, GDPR) — sending system telemetry containing potential PII to a third-party API may require a data processing assessment or may be prohibited by policy.
- **Shared machines** — event logs on a shared workstation contain activity from all users. One user's Claude conversation could surface another user's logon events if the Security log is enabled.

### Mitigations in place

- **Log allowlist** — only System and Application are permitted by default. The Security log and operational logs must be explicitly opted into.
- **Field stripping** — internal .NET metadata and binary fields are removed before data reaches Claude.
- **Result caps** — a maximum of 500 events per query and a 24-hour time window limit reduce the volume of data that can be extracted in a single request.
- **Read-only** — the extension cannot write to event logs, modify system state, or make network calls.

### Recommendation

For personal use on your own machine with the default System and Application logs, the risk is low — you are sending error messages and timestamps to Anthropic, similar to what you might paste into any support conversation.

For corporate, shared, or regulated environments, **review the data with your security team first**. Run a test query, inspect the JSON output, and decide whether the content is acceptable to send to a third-party API. The source is in `server/server.ps1` — read it.

## For sysadmins

This extension is intentionally minimal. It reads event logs and returns raw JSON — nothing more. There is no agent behaviour and no write access to your system.

The PowerShell source is in `server/server.ps1`. Read it before recommending it to users. That is the point.

Tested on Windows 10 22H2, Windows 11 23H2, and Windows Server 2022 with PowerShell 7.4.

## Troubleshooting

**Extension doesn't appear in Claude Desktop** — ensure you are running the latest version of Claude Desktop and that the extension shows as enabled in Settings → Extensions.

**PowerShell not found** — ensure `pwsh` (PowerShell 7) is installed and available in your system PATH. The legacy `powershell.exe` (v5) is not supported.

**Security log access denied** — reading the Security event log requires administrator privileges. Run Claude Desktop as Administrator, or stick to `System` and `Application` logs.

**No events returned** — try specifying a different log name. For application crashes use `Application`, for system and hardware issues use `System`.

## Testing

Run the test fixtures against the server directly:

```powershell
Get-Content test-requests.jsonl | pwsh -NoProfile -File server/server.ps1
```

You should see two JSON responses (`initialize` and `tools/list`) and no response for the notification.

## Contributing

Issues and pull requests are welcome. Please read the source before contributing — the goal is to keep the server simple and auditable.

For bug reports or questions, open an issue on [GitHub Issues](https://github.com/cleggypdc/windows-eventlog-mcpb/issues).

## Licence

[GNU General Public License v3.0](LICENSE)

This software is free to use, modify, and distribute under the terms of the GPLv3. Any derivative works must also be distributed under the same licence.
