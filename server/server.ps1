# Windows Event Log MCP Server
# Pure PowerShell, stdio JSON-RPC 2.0 transport
#
# Copyright (C) 2025 cleggypdc
# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Security limits
# ---------------------------------------------------------------------------
$script:MaxResults    = 500
$script:MaxMinutes    = 1440   # 24 hours
$script:MaxTopN       = 100
$script:MaxLineLength = 65536
$script:TopSourcesCap = 10000

# Default allowlist — override via EVENTLOG_ALLOWED_LOGS env var (comma-separated)
$script:AllowedLogs = @('System', 'Application')
$envLogs = $env:EVENTLOG_ALLOWED_LOGS
if ($envLogs) {
    $script:AllowedLogs = ($envLogs -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
}

# ---------------------------------------------------------------------------
# Cached boot time (WMI query once, not per-invocation)
# ---------------------------------------------------------------------------
$script:BootTime = $null
function Get-BootTime {
    if (-not $script:BootTime) {
        $script:BootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    }
    return $script:BootTime
}

# ---------------------------------------------------------------------------
# Input validation helpers
# ---------------------------------------------------------------------------
function Assert-LogAllowed {
    param([string]$LogName)
    if ($LogName -notin $script:AllowedLogs) {
        throw "Log '$LogName' is not in the allowed list: $($script:AllowedLogs -join ', '). Set EVENTLOG_ALLOWED_LOGS to configure."
    }
}

function Assert-Level {
    param($RawLevel)
    $lvl = [int]$RawLevel
    if ($lvl -lt 1 -or $lvl -gt 5) {
        throw "level must be between 1 and 5, got $lvl"
    }
    return $lvl
}

# ---------------------------------------------------------------------------
# Tool definitions (shared between tools/list and tools/call)
# ---------------------------------------------------------------------------
$script:AllowedLogsDesc = $script:AllowedLogs -join ', '

$ToolDefinitions = @(
    @{
        name = 'get_events_since_boot'
        description = "Get Windows Event Log entries since the last system boot. Allowed logs: $script:AllowedLogsDesc. Level filters: 1=Critical, 2=Error, 3=Warning, 4=Informational, 5=Verbose."
        inputSchema = @{
            type = 'object'
            properties = @{
                log_name    = @{ type = 'string';  description = "Event log name. Allowed: $script:AllowedLogsDesc"; default = 'System' }
                level       = @{ type = 'integer'; description = 'Filter by level: 1=Critical, 2=Error, 3=Warning, 4=Informational, 5=Verbose' }
                max_results = @{ type = 'integer'; description = "Maximum events to return (max $script:MaxResults)"; default = 20 }
            }
            required = @()
        }
        annotations = @{ readOnlyHint = $true; destructiveHint = $false; idempotentHint = $true; openWorldHint = $false }
    },
    @{
        name = 'get_recent_events'
        description = "Get Windows Event Log entries from the last N minutes (max ${script:MaxMinutes}). Useful for diagnosing recent issues. Check the Application log for app crashes and the System log for OS/driver problems. Level filters: 1=Critical, 2=Error, 3=Warning, 4=Informational, 5=Verbose."
        inputSchema = @{
            type = 'object'
            properties = @{
                log_name    = @{ type = 'string';  description = "Event log name. Allowed: $script:AllowedLogsDesc"; default = 'System' }
                minutes     = @{ type = 'integer'; description = "Look back this many minutes (1-$script:MaxMinutes)"; default = 60 }
                level       = @{ type = 'integer'; description = 'Filter by level: 1=Critical, 2=Error, 3=Warning, 4=Informational, 5=Verbose' }
                max_results = @{ type = 'integer'; description = "Maximum events to return (max $script:MaxResults)"; default = 20 }
            }
            required = @()
        }
        annotations = @{ readOnlyHint = $true; destructiveHint = $false; idempotentHint = $true; openWorldHint = $false }
    },
    @{
        name = 'get_top_event_sources'
        description = "Get the most frequent event sources in a log over the last N minutes (max ${script:MaxMinutes}). Helps identify noisy or problematic components quickly."
        inputSchema = @{
            type = 'object'
            properties = @{
                log_name = @{ type = 'string';  description = "Event log name. Allowed: $script:AllowedLogsDesc"; default = 'System' }
                minutes  = @{ type = 'integer'; description = "Look back this many minutes (1-$script:MaxMinutes)"; default = 60 }
                top_n    = @{ type = 'integer'; description = "Number of top sources to return (max $script:MaxTopN)"; default = 10 }
            }
            required = @()
        }
        annotations = @{ readOnlyHint = $true; destructiveHint = $false; idempotentHint = $true; openWorldHint = $false }
    },
    @{
        name = 'get_event_detail'
        description = 'Get full detail for a single event by its RecordId. Use this after browsing events to drill into a specific entry.'
        inputSchema = @{
            type = 'object'
            properties = @{
                log_name  = @{ type = 'string';  description = "Event log name. Allowed: $script:AllowedLogsDesc"; default = 'System' }
                record_id = @{ type = 'integer'; description = 'The RecordId of the event to retrieve' }
            }
            required = @('record_id')
        }
        annotations = @{ readOnlyHint = $true; destructiveHint = $false; idempotentHint = $true; openWorldHint = $false }
    }
)

# ---------------------------------------------------------------------------
# Helper: write a JSON-RPC response to stdout
# ---------------------------------------------------------------------------
function Send-Response {
    param([object]$Id, [object]$Result)
    $resp = @{ jsonrpc = '2.0'; id = $Id; result = $Result }
    $json = $resp | ConvertTo-Json -Depth 10 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Send-Error {
    param([object]$Id, [int]$Code, [string]$Message)
    $resp = @{
        jsonrpc = '2.0'
        id      = $Id
        error   = @{ code = $Code; message = $Message }
    }
    $json = $resp | ConvertTo-Json -Depth 10 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

# ---------------------------------------------------------------------------
# Helper: resolve parameter with null-safe default
# ---------------------------------------------------------------------------
function Resolve-Param {
    param([hashtable]$Source, [string]$Name, $Default)
    if ($null -ne $Source[$Name]) { return $Source[$Name] }
    return $Default
}

# ---------------------------------------------------------------------------
# Helper: strip bloat fields from event objects
# ---------------------------------------------------------------------------
$script:EventFields = @(
    'Id', 'RecordId', 'TimeCreated',
    'ProviderName', 'LogName',
    'Level', 'LevelDisplayName',
    'Message', 'ProcessId'
)

function Select-EventFields {
    param([array]$Events)
    $Events | ForEach-Object {
        $obj = $_ | Select-Object $script:EventFields
        $props = $_.Properties | ForEach-Object { $_.Value }
        $obj | Add-Member -NotePropertyName 'Properties' -NotePropertyValue $props
        $obj
    }
}

# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------
function Invoke-GetEventsSinceBoot {
    param([hashtable]$ToolArgs)
    $logName    = Resolve-Param $ToolArgs 'log_name'    'System'
    $maxResults = [Math]::Min([int](Resolve-Param $ToolArgs 'max_results' 20), $script:MaxResults)

    Assert-LogAllowed $logName

    $bootTime = Get-BootTime
    $filter = @{ LogName = $logName; StartTime = $bootTime }
    if ($null -ne $ToolArgs['level']) { $filter['Level'] = Assert-Level $ToolArgs['level'] }

    $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $maxResults -ErrorAction SilentlyContinue)
    if ($events.Count -eq 0) { return '[]' }
    $slim = @(Select-EventFields $events)
    return (,$slim | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-GetRecentEvents {
    param([hashtable]$ToolArgs)
    $logName    = Resolve-Param $ToolArgs 'log_name'    'System'
    $minutes    = [Math]::Clamp([int](Resolve-Param $ToolArgs 'minutes' 60), 1, $script:MaxMinutes)
    $maxResults = [Math]::Min([int](Resolve-Param $ToolArgs 'max_results' 20), $script:MaxResults)

    Assert-LogAllowed $logName

    $startTime = (Get-Date).AddMinutes(-$minutes)
    $filter = @{ LogName = $logName; StartTime = $startTime }
    if ($null -ne $ToolArgs['level']) { $filter['Level'] = Assert-Level $ToolArgs['level'] }

    $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $maxResults -ErrorAction SilentlyContinue)
    if ($events.Count -eq 0) { return '[]' }
    $slim = @(Select-EventFields $events)
    return (,$slim | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-GetTopEventSources {
    param([hashtable]$ToolArgs)
    $logName = Resolve-Param $ToolArgs 'log_name' 'System'
    $minutes = [Math]::Clamp([int](Resolve-Param $ToolArgs 'minutes' 60), 1, $script:MaxMinutes)
    $topN    = [Math]::Min([int](Resolve-Param $ToolArgs 'top_n' 10), $script:MaxTopN)

    Assert-LogAllowed $logName

    $startTime = (Get-Date).AddMinutes(-$minutes)
    $filter = @{ LogName = $logName; StartTime = $startTime }

    $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $script:TopSourcesCap -ErrorAction SilentlyContinue)
    if ($events.Count -eq 0) { return '[]' }

    $grouped = $events | Group-Object -Property ProviderName |
        Sort-Object -Property Count -Descending |
        Select-Object -First $topN -Property @(
            @{ Name = 'source'; Expression = { $_.Name } },
            @{ Name = 'count';  Expression = { $_.Count } }
        )
    return (,@($grouped) | ConvertTo-Json -Depth 5 -Compress)
}

function Invoke-GetEventDetail {
    param([hashtable]$ToolArgs)
    $logName = Resolve-Param $ToolArgs 'log_name' 'System'

    Assert-LogAllowed $logName

    if ($null -eq $ToolArgs['record_id']) { throw 'record_id is required' }
    $recordId = [long]$ToolArgs['record_id']

    $xpath = "*[System[EventRecordID=$recordId]]"
    $event = Get-WinEvent -LogName $logName -FilterXPath $xpath -MaxEvents 1
    $slim = @(Select-EventFields @($event))
    return (,$slim | ConvertTo-Json -Depth 5 -Compress)
}

# ---------------------------------------------------------------------------
# MCP method dispatch
# ---------------------------------------------------------------------------
function Invoke-McpRequest {
    param([hashtable]$Req)

    $method = $Req.method

    switch ($method) {
        'initialize' {
            Send-Response -Id $Req.id -Result @{
                protocolVersion = '2025-06-18'
                capabilities    = @{ tools = @{} }
                serverInfo      = @{
                    name    = 'windows-eventlog-mcp'
                    version = '1.0.0'
                }
            }
        }

        'tools/list' {
            Send-Response -Id $Req.id -Result @{
                tools = $ToolDefinitions
            }
        }

        'tools/call' {
            if (-not $Req.params) {
                Send-Error -Id $Req.id -Code -32602 -Message 'Missing params'
                return
            }

            $toolName = $Req.params.name
            $toolArgs = $Req.params.arguments
            if (-not $toolArgs -or $toolArgs -isnot [hashtable]) { $toolArgs = @{} }

            try {
                $output = switch ($toolName) {
                    'get_events_since_boot' { Invoke-GetEventsSinceBoot -ToolArgs $toolArgs }
                    'get_recent_events'     { Invoke-GetRecentEvents    -ToolArgs $toolArgs }
                    'get_top_event_sources' { Invoke-GetTopEventSources -ToolArgs $toolArgs }
                    'get_event_detail'      { Invoke-GetEventDetail     -ToolArgs $toolArgs }
                    default                 { throw "Unknown tool: $toolName" }
                }
                Send-Response -Id $Req.id -Result @{
                    content = @(@{ type = 'text'; text = $output })
                }
            }
            catch {
                Send-Response -Id $Req.id -Result @{
                    content = @(@{ type = 'text'; text = "Error: $($_.Exception.Message)" })
                    isError = $true
                }
            }
        }

        default {
            if ($null -ne $Req.id) {
                Send-Error -Id $Req.id -Code -32601 -Message "Method not found: $method"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Main loop: read JSON-RPC messages from stdin, one per line
# ---------------------------------------------------------------------------
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $line = $line.Trim()
    if ($line -eq '') { continue }

    if ($line.Length -gt $script:MaxLineLength) {
        Send-Error -Id $null -Code -32600 -Message 'Request too large'
        continue
    }

    try {
        $request = $line | ConvertFrom-Json -AsHashtable
    }
    catch {
        Send-Error -Id $null -Code -32700 -Message 'Parse error'
        continue
    }

    # Notifications have no id — do not respond
    if ($null -eq $request.id) { continue }

    Invoke-McpRequest -Req $request
}
