[CmdletBinding()]
param(
    [string]$StateDir = ".codex-task-state",
    [string]$Model = "gpt-5.6-terra",
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3
)

$ErrorActionPreference = "Stop"

$TaskDirectory = $PSScriptRoot
$SetupDocument = Join-Path $TaskDirectory "setup.md"

# Completed tasks 00-16 are intentionally omitted. Keep remaining work explicit.
$TaskDocuments = @(
    "17-workflow-sqlite-worker.md",
    "18-activity-timer-messaging.md",
    "19-workflow-local-recovery.md",
    "20-workflow-child-compensation.md",
    "21-workflow-migration-archival.md",
    "22-runtime-integration.md"
)

$RepositoryRoot = (git -C $TaskDirectory rev-parse --show-toplevel).Trim()
if (-not $RepositoryRoot) {
    throw "Unable to determine the repository root."
}

$StateDirectory = Join-Path $RepositoryRoot $StateDir
New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null

if (-not (Test-Path -LiteralPath $SetupDocument -PathType Leaf)) {
    throw "Missing setup document: $SetupDocument"
}

function Get-HeadCommit {
    return (git -C $RepositoryRoot rev-parse HEAD).Trim()
}

function Get-WorkingTreeStatus {
    return git -C $RepositoryRoot status --porcelain
}

function Test-TaskCommit {
    param(
        [Parameter(Mandatory)][string]$InitialHead,
        [Parameter(Mandatory)][string]$TaskId
    )

    $currentHead = Get-HeadCommit
    $commitSubject = (git -C $RepositoryRoot log -1 --pretty=%s).Trim()
    $expectedSubject = "$TaskId done"

    git -C $RepositoryRoot merge-base --is-ancestor $InitialHead $currentHead
    $isDescendant = $LASTEXITCODE -eq 0

    return [PSCustomObject]@{
        CurrentHead = $currentHead
        CommitSubject = $commitSubject
        ExpectedSubject = $expectedSubject
        IsComplete = $currentHead -ne $InitialHead -and
            $isDescendant -and
            $commitSubject -eq $expectedSubject
    }
}

function Get-DocumentText {
    param([string]$Path)

    return [System.IO.File]::ReadAllText($Path)
}

function Get-CodexThreadId {
    param([Parameter(Mandatory)][string]$EventsPath)

    if (-not (Test-Path -LiteralPath $EventsPath -PathType Leaf)) {
        return $null
    }

    foreach ($line in Get-Content -LiteralPath $EventsPath) {
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
            if ($event.type -eq "thread.started" -and $event.thread_id) {
                return $event.thread_id.ToString()
            }
        }
        catch {
            # Codex writes a non-JSON "Reading prompt" line before JSONL events.
        }
    }

    return $null
}

function Invoke-CodexTask {
    param(
        [System.IO.FileInfo]$Task,
        [int]$Attempt
    )

    $taskId = $Task.BaseName
    $resultPath = Join-Path $StateDirectory "$taskId.attempt-$Attempt.result.md"
    $eventsPath = Join-Path $StateDirectory "$taskId.attempt-$Attempt.jsonl"
    $setupText = Get-DocumentText -Path $SetupDocument
    $taskText = Get-DocumentText -Path $Task.FullName

    $prompt = @"
Implement exactly one task in the repository at:
$RepositoryRoot

You have been given two complete documents. The setup document is authoritative for
shared constraints; the task document defines the work for this invocation.

===== SETUP DOCUMENT: $SetupDocument =====
$setupText
===== END SETUP DOCUMENT =====

===== TASK DOCUMENT: $($Task.FullName) =====
$taskText
===== END TASK DOCUMENT =====

Required procedure:
1. Read AGENTS.md if it exists, then re-read both documents above.
2. Inspect the relevant implementation and tests before changing anything.
3. Implement only $taskId. Do not begin later tasks or unrelated refactors.
4. Preserve unrelated working-tree changes already present.
5. Add or update tests required by the task.
6. Run every acceptance command required by the task and fix failures caused by it.
7. Review git diff for unintended changes.
8. Commit only when every acceptance criterion passes, using exactly this subject:

$taskId done

Do not run destructive Git commands, including git reset, git restore, git clean,
force checkout, or history rewriting.

If blocked, do not create the success commit. Leave useful work in the working tree
and explain the blocker and exact next action in the final response.

Your final response must include implementation summary, files changed, commands run,
test results, commit hash, and remaining risks.
"@

    # Codex emits normal progress messages on stderr. Do not let a global Stop
    # preference turn those messages into terminating PowerShell errors.
    $codexArguments = @(
        "exec",
        "--cd", $RepositoryRoot,
        "--model", $Model,
        "--yolo",
        "--json",
        "--output-last-message", $resultPath
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $previousNativeCommandPreference = $PSNativeCommandUseErrorActionPreference
    $exitCode = $null

    try {
        $ErrorActionPreference = "Continue"
        $PSNativeCommandUseErrorActionPreference = $false

        $prompt |
            & codex @codexArguments 2>&1 |
            ForEach-Object { $_.ToString() } |
            Tee-Object -FilePath $eventsPath |
            Out-Host

        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $previousNativeCommandPreference
    }

    return $exitCode
}

function Resume-CodexTask {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Task,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][string]$SessionId
    )

    $taskId = $Task.BaseName
    $resultPath = Join-Path $StateDirectory "$taskId.resume-$Attempt.result.md"
    $eventsPath = Join-Path $StateDirectory "$taskId.resume-$Attempt.jsonl"
    $setupText = Get-DocumentText -Path $SetupDocument
    $taskText = Get-DocumentText -Path $Task.FullName
    $prompt = @"
Continue only the current task $taskId in the repository at:
$RepositoryRoot

===== SETUP DOCUMENT: $SetupDocument =====
$setupText
===== END SETUP DOCUMENT =====

===== TASK DOCUMENT: $($Task.FullName) =====
$taskText
===== END TASK DOCUMENT =====

Inspect the current working-tree diff and prior command output. Determine why the
previous attempt did not satisfy completion validation, then finish this task only.
Run every required acceptance check, review the diff, and create exactly this commit:

$taskId done

Do not start another task or discard useful existing changes.
"@

    $codexArguments = @(
        "exec",
        "resume",
        "--yolo",
        "--json",
        "--output-last-message", $resultPath,
        $SessionId,
        "-"
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $previousNativeCommandPreference = $PSNativeCommandUseErrorActionPreference
    $exitCode = $null

    try {
        $ErrorActionPreference = "Continue"
        $PSNativeCommandUseErrorActionPreference = $false

        $prompt |
            & codex @codexArguments 2>&1 |
            ForEach-Object { $_.ToString() } |
            Tee-Object -FilePath $eventsPath |
            Out-Host

        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $previousNativeCommandPreference
    }

    return $exitCode
}

$tasks = foreach ($taskName in $TaskDocuments) {
    $taskPath = Join-Path $TaskDirectory $taskName
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        throw "Missing task document: $taskPath"
    }

    Get-Item -LiteralPath $taskPath
}

if ($tasks.Count -eq 0) {
    throw "TaskDocuments must contain at least one task document."
}

foreach ($task in $tasks) {
    $taskId = $task.BaseName
    $donePath = Join-Path $StateDirectory "$taskId.done"
    $failurePath = Join-Path $StateDirectory "$taskId.failed.md"

    if (Test-Path -LiteralPath $donePath -PathType Leaf) {
        Write-Host "[SKIP] $taskId"
        continue
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host "[TASK] $taskId"
    Write-Host "========================================"

    $initialHead = Get-HeadCommit
    $success = $false
    $sessionId = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "[ATTEMPT] $attempt / $MaxAttempts"
        if (-not $sessionId) {
            $exitCode = Invoke-CodexTask -Task $task -Attempt $attempt
            $eventsPath = Join-Path $StateDirectory "$taskId.attempt-$attempt.jsonl"
            $sessionId = Get-CodexThreadId -EventsPath $eventsPath
        }
        else {
            $exitCode = Resume-CodexTask -Task $task -Attempt $attempt -SessionId $sessionId
        }

        if ($exitCode -ne 0) {
            Write-Warning "Codex exited with code $exitCode"
        }

        $commit = Test-TaskCommit -InitialHead $initialHead -TaskId $taskId
        if ($exitCode -eq 0 -and $commit.IsComplete) {
            @"
task=$taskId
commit=$($commit.CurrentHead)
completed_at=$(Get-Date -Format o)
attempt=$attempt
"@ | Set-Content -LiteralPath $donePath -Encoding utf8

            Remove-Item -LiteralPath $failurePath -ErrorAction SilentlyContinue
            Write-Host "[DONE] $taskId"
            Write-Host "[COMMIT] $($commit.CurrentHead)"
            $success = $true
            break
        }

        $status = Get-WorkingTreeStatus
        @"
# Task failure

Task: $taskId
Attempt: $attempt
Exit code: $exitCode
Initial HEAD: $initialHead
Current HEAD: $($commit.CurrentHead)
Expected commit: $($commit.ExpectedSubject)
Actual commit: $($commit.CommitSubject)

## Working tree

~~~text
$status
~~~
"@ | Set-Content -LiteralPath $failurePath -Encoding utf8

        if ($attempt -lt $MaxAttempts) {
            if ($sessionId) {
                Write-Warning "Task incomplete; resuming Codex session $sessionId."
            }
            else {
                Write-Warning "Task incomplete before a Codex session started; retrying with a new session."
            }
        }
    }

    if (-not $success) {
        throw "Task $taskId failed after $MaxAttempts attempts. See $failurePath"
    }
}

Write-Host ""
Write-Host "All listed tasks completed."
