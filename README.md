# Windows Event Log MCP Server

Windows Event Log access for Claude Desktop. Ask plain-English questions about system errors, crashes, and warnings — no log parsing required.

Packaged as an [MCPB Desktop Extension](https://github.com/modelcontextprotocol/mcpb) with a pure PowerShell MCP server.

## Prerequisites

- **Windows 10/11 or Windows Server 2016+**
- **PowerShell 7+** (`pwsh`) — [Install PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows)
- **Claude Desktop** with MCPB extension support

## Installation

### From MCPB CLI

```
mcpb install windows-eventlog-mcp
```

### Manual

1. Copy this repository into your Claude Desktop extensions directory
2. Restart Claude Desktop — the extension will appear automatically

### Direct (claude_desktop_config.json)

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

### Allowed Logs

By default, the server only permits access to the **System** and **Application** event logs. This is controlled by the `EVENTLOG_ALLOWED_LOGS` environment variable (comma-separated log names).

To grant access to additional logs, set the variable before launching or in your `claude_desktop_config.json`:

```
EVENTLOG_ALLOWED_LOGS=System,Application,Security
```

Common log names:

| Log | Contains | Privacy note |
|-----|----------|--------------|
| System | Hardware, driver, and OS events | Low sensitivity |
| Application | App crashes, errors, warnings | Low sensitivity |
| Security | Logon events, privilege use, audit | **Contains usernames, logon times, auth events** |
| Microsoft-Windows-PowerShell/Operational | PowerShell command history | **Contains command text** |
| Microsoft-Windows-Sysmon/Operational | Process, network, file activity | **Detailed system telemetry** |

> **Security note:** The Security and operational logs can contain personally identifiable information and detailed activity traces. Only add them to the allowlist if you understand the implications. Any log accessible to the server is also accessible to Claude and, by extension, to anything in the conversation context.

### Limits

The server enforces hard limits to prevent resource exhaustion:

| Limit | Value | Description |
|-------|-------|-------------|
| Max results per query | 500 | Caps `max_results` parameter |
| Max time window | 1440 min (24h) | Caps `minutes` parameter |
| Max top sources | 100 | Caps `top_n` parameter |
| Source analysis cap | 10,000 events | Max events scanned for `get_top_event_sources` |
| Request line size | 64 KB | Max JSON-RPC message length |

These are not configurable — they are safety boundaries.

## Tools

### get_events_since_boot

Events from the current boot session. Useful for "what went wrong since I turned on my PC?"

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| log_name | string | System | Event log (must be in allowlist) |
| level | integer | — | 1=Critical, 2=Error, 3=Warning, 4=Info, 5=Verbose |
| max_results | integer | 50 | Maximum events to return (capped at 500) |

### get_recent_events

Events from the last N minutes. Good for "my app crashed 10 minutes ago, what happened?"

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| log_name | string | System | Event log (must be in allowlist) |
| minutes | integer | 60 | Look back this many minutes (1-1440) |
| level | integer | — | 1=Critical, 2=Error, 3=Warning, 4=Info, 5=Verbose |
| max_results | integer | 50 | Maximum events to return (capped at 500) |

### get_top_event_sources

Most frequent event sources over a time window. Identifies noisy or problematic components.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| log_name | string | System | Event log (must be in allowlist) |
| minutes | integer | 60 | Look back this many minutes (1-1440) |
| top_n | integer | 10 | Number of top sources to return (capped at 100) |

### get_event_detail

Full detail for a single event by RecordId. Use after browsing to drill into one entry.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| log_name | string | System | Event log (must be in allowlist) |
| record_id | integer | — | **Required.** The RecordId of the event |

## Example Prompts

- "Show me any critical errors since I booted up"
- "What crashed in the last 30 minutes? Check the Application log"
- "Which event sources are generating the most noise in the System log?"
- "Get me the full details for event record 12345"

## Testing

Run the test fixtures against the server:

```powershell
Get-Content test-requests.jsonl | pwsh -NoProfile -File server/server.ps1
```

You should see two JSON responses (initialize + tools/list) and no response for the notification.

## License

[GNU General Public License v3.0](LICENSE)
