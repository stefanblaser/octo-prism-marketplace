<#
.SYNOPSIS
    Validates and publishes an exported DocType definition to the OCTO Prism Marketplace.

.DESCRIPTION
    Takes a path to an exported DocType JSON file, validates it against the marketplace
    package schema, copies it into packages/<packageId>/package.json, commits, and pushes
    to a new branch. Optionally opens a pull request via the GitHub CLI (gh).

.PARAMETER Path
    Path to the exported DocType JSON file.

.PARAMETER CreatePR
    If set, creates a pull request against main using the GitHub CLI (gh).

.PARAMETER BaseBranch
    Target branch for the pull request. Defaults to 'main'.

.PARAMETER DryRun
    Validate and preview the changes without writing, committing, or pushing anything.

.EXAMPLE
    .\Publish-DocType.ps1 -Path .\my-invoice.json
    # Validates, copies into packages/, commits, and pushes a branch.

.EXAMPLE
    .\Publish-DocType.ps1 -Path .\my-invoice.json -CreatePR
    # Same as above, plus opens a PR against main.

.EXAMPLE
    .\Publish-DocType.ps1 -Path .\my-invoice.json -DryRun
    # Validates the file and shows what would happen, without making changes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [switch]$CreatePR,

    [string]$BaseBranch = 'main',

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- helpers ----------

function Write-Step  { param([string]$Msg) Write-Host ">> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "   [OK] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "   [WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Msg) Write-Host "   [FAIL] $Msg" -ForegroundColor Red }

# ---------- resolve paths ----------

$RepoRoot = Split-Path -Parent $PSCommandPath
$PackagesDir = Join-Path $RepoRoot 'packages'

if (-not (Test-Path $Path)) {
    Write-Fail "File not found: $Path"
    exit 1
}

$FullPath = (Resolve-Path $Path).Path

# ---------- parse JSON ----------

Write-Step 'Reading and parsing JSON file...'

try {
    $RawJson  = Get-Content -Raw -Encoding utf8 $FullPath
    $Package  = $RawJson | ConvertFrom-Json
} catch {
    Write-Fail "Invalid JSON: $_"
    exit 1
}

Write-Ok "Parsed $FullPath"

# ---------- validation ----------

Write-Step 'Validating package definition...'

$Errors   = [System.Collections.Generic.List[string]]::new()
$Warnings = [System.Collections.Generic.List[string]]::new()

# Required top-level fields
$RequiredFields = @('packageId', 'name', 'description', 'version', 'language', 'fields')
foreach ($field in $RequiredFields) {
    $value = $Package.PSObject.Properties[$field]
    if (-not $value -or $null -eq $value.Value -or ($value.Value -is [string] -and [string]::IsNullOrWhiteSpace($value.Value))) {
        $Errors.Add("Missing required field: '$field'")
    }
}

# packageId format: lowercase, dot-separated, e.g. de.invoice or generic.receipt
if ($Package.packageId) {
    if ($Package.packageId -cne $Package.packageId.ToLower()) {
        $Errors.Add("packageId must be lowercase (got '$($Package.packageId)')")
    }
    if ($Package.packageId -notmatch '^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$') {
        $Errors.Add("packageId must be dot-separated lowercase segments, e.g. 'de.invoice' or 'generic.receipt' (got '$($Package.packageId)')")
    }
}

# version format
if ($Package.version -and $Package.version -notmatch '^\d+(\.\d+){0,2}$') {
    $Errors.Add("version must be numeric (e.g. '1.0' or '1.2.3'), got '$($Package.version)'")
}

# language code (ISO 639-1, 2-letter)
if ($Package.language -and $Package.language -notmatch '^[a-z]{2}$') {
    $Warnings.Add("language should be a 2-letter ISO 639-1 code (got '$($Package.language)')")
}

# region code if present (ISO 3166-1 alpha-2, uppercase)
if ($Package.PSObject.Properties['region'] -and $Package.region) {
    if ($Package.region -notmatch '^[A-Z]{2}$') {
        $Warnings.Add("region should be a 2-letter uppercase ISO 3166-1 code (got '$($Package.region)')")
    }
}

# Allowed data types
$AllowedDataTypes = @('String', 'Integer', 'Decimal', 'Date', 'Boolean')

# fields validation
if ($Package.fields -and $Package.fields.Count -gt 0) {
    $fieldNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in $Package.fields) {
        if (-not $f.name) {
            $Errors.Add("Every field must have a 'name' property")
            continue
        }
        if (-not $fieldNames.Add($f.name)) {
            $Errors.Add("Duplicate field name: '$($f.name)'")
        }
        if (-not $f.dataType) {
            $Errors.Add("Field '$($f.name)' is missing 'dataType'")
        } elseif ($f.dataType -notin $AllowedDataTypes) {
            $Errors.Add("Field '$($f.name)' has invalid dataType '$($f.dataType)'. Allowed: $($AllowedDataTypes -join ', ')")
        }
    }
    Write-Ok "$($Package.fields.Count) field(s) validated"
} elseif ($Package.fields) {
    $Errors.Add("'fields' array is empty - at least one field is required")
}

# tables validation (optional)
if ($Package.tables -and $Package.tables.Count -gt 0) {
    foreach ($t in $Package.tables) {
        if (-not $t.name) {
            $Errors.Add("Every table must have a 'name' property")
            continue
        }
        if (-not $t.columns -or $t.columns.Count -eq 0) {
            $Errors.Add("Table '$($t.name)' has no columns")
            continue
        }
        foreach ($c in $t.columns) {
            if (-not $c.name) {
                $Errors.Add("Table '$($t.name)' has a column without a 'name'")
            }
            if ($c.dataType -and $c.dataType -notin $AllowedDataTypes) {
                $Errors.Add("Table '$($t.name)' column '$($c.name)' has invalid dataType '$($c.dataType)'")
            }
        }
    }
    Write-Ok "$($Package.tables.Count) table(s) validated"
}

# Warn on missing optional but recommended fields
foreach ($opt in @('tags', 'author', 'meta')) {
    if (-not $Package.PSObject.Properties[$opt]) {
        $Warnings.Add("Optional field '$opt' is not set - consider adding it")
    }
}

# Report
foreach ($w in $Warnings) { Write-Warn $w }
foreach ($e in $Errors)   { Write-Fail $e }

if ($Errors.Count -gt 0) {
    Write-Host ''
    Write-Fail "Validation failed with $($Errors.Count) error(s). Fix the issues above and try again."
    exit 1
}

Write-Ok 'Validation passed!'

# ---------- summary ----------

Write-Step 'Package summary'
Write-Host "   Package ID:  $($Package.packageId)"
Write-Host "   Name:        $($Package.name)"
Write-Host "   Version:     $($Package.version)"
Write-Host "   Language:    $($Package.language)"
Write-Host "   Region:      $(if ($Package.region) { $Package.region } else { '(none)' })"
Write-Host "   Fields:      $($Package.fields.Count)"
Write-Host "   Tables:      $(if ($Package.tables) { $Package.tables.Count } else { 0 })"
Write-Host ''

# ---------- check for existing package ----------

$TargetDir  = Join-Path $PackagesDir $Package.packageId
$TargetFile = Join-Path $TargetDir 'package.json'

if (Test-Path $TargetFile) {
    $Existing = Get-Content -Raw $TargetFile | ConvertFrom-Json
    Write-Warn "Package '$($Package.packageId)' already exists (current version: $($Existing.version))."
    if ($Package.version -le $Existing.version) {
        Write-Warn "New version ($($Package.version)) is not greater than existing ($($Existing.version)). Consider bumping the version."
    }
}

# ---------- dry-run exit ----------

if ($DryRun) {
    Write-Step 'Dry-run mode - no changes made.'
    Write-Host "   Would write:  $TargetFile"
    Write-Host "   Would commit and push branch: publish/$($Package.packageId)"
    exit 0
}

# ---------- write package ----------

Write-Step "Writing package to $TargetDir ..."

if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

# Pretty-print the JSON to ensure consistent formatting
$Package | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 $TargetFile

Write-Ok "Written $TargetFile"

# ---------- git operations ----------

Write-Step 'Preparing git branch and commit...'

Push-Location $RepoRoot
try {
    $BranchName = "publish/$($Package.packageId)"

    # Create branch from latest base
    git fetch origin $BaseBranch 2>$null
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($currentBranch -ne $BranchName) {
        git checkout -b $BranchName "origin/$BaseBranch" 2>$null
        if ($LASTEXITCODE -ne 0) {
            # Branch may already exist locally
            git checkout $BranchName 2>$null
        }
    }

    git add $TargetFile

    $IsNew = -not (Test-Path (Join-Path $PackagesDir "$($Package.packageId)/package.json") -PathType Leaf) -or
             (git diff --cached --name-only | Select-String "packages/$($Package.packageId)/package.json")

    $Action = if (Test-Path (Join-Path $PackagesDir "$($Package.packageId)/package.json")) { 'update' } else { 'add' }
    $CommitMsg = "feat: $Action DocType '$($Package.packageId)' v$($Package.version)"

    git commit -m $CommitMsg
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'Nothing to commit (file unchanged?).'
    } else {
        Write-Ok "Committed: $CommitMsg"
    }

    # Push with retry
    $MaxRetries = 4
    $Delay = 2
    for ($i = 1; $i -le $MaxRetries; $i++) {
        git push -u origin $BranchName 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Pushed branch '$BranchName' to origin."
            break
        }
        if ($i -lt $MaxRetries) {
            Write-Warn "Push failed (attempt $i/$MaxRetries). Retrying in ${Delay}s..."
            Start-Sleep -Seconds $Delay
            $Delay *= 2
        } else {
            Write-Fail "Push failed after $MaxRetries attempts."
            exit 1
        }
    }

    # ---------- optional PR ----------

    if ($CreatePR) {
        Write-Step 'Creating pull request...'

        $PrTitle = "feat: $Action DocType '$($Package.packageId)' v$($Package.version)"
        $PrBody  = @"
## Summary

- **Package ID:** ``$($Package.packageId)``
- **Name:** $($Package.name)
- **Version:** $($Package.version)
- **Language:** $($Package.language)
- **Region:** $(if ($Package.region) { $Package.region } else { 'generic' })
- **Fields:** $($Package.fields.Count)
- **Tables:** $(if ($Package.tables) { $Package.tables.Count } else { 0 })

Published via ``Publish-DocType.ps1``.
"@

        gh pr create --base $BaseBranch --head $BranchName --title $PrTitle --body $PrBody 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'Pull request created.'
        } else {
            Write-Warn 'Could not create PR. Make sure the GitHub CLI (gh) is installed and authenticated.'
            Write-Host "   You can create a PR manually at: https://github.com/stefanblaser/octo-prism-marketplace/compare/$($BranchName)?expand=1"
        }
    } else {
        Write-Host ''
        Write-Host "   Branch '$BranchName' is ready. Next steps:" -ForegroundColor White
        Write-Host "   - Create a PR: gh pr create --base $BaseBranch --head $BranchName"
        Write-Host "   - Or re-run with -CreatePR to do it automatically."
        Write-Host "   - Or open: https://github.com/stefanblaser/octo-prism-marketplace/compare/$($BranchName)?expand=1"
    }
} finally {
    Pop-Location
}

Write-Host ''
Write-Ok 'Done!'
