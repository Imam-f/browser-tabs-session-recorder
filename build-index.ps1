param(
    [string]$InputPath = (Join-Path $PSScriptRoot 'tabs.md'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'index.html'),
    [string]$TemplatePath = (Join-Path $PSScriptRoot 'index.template.html')
)

$ErrorActionPreference = 'Stop'
$InputPath = [IO.Path]::GetFullPath($InputPath)
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$TemplatePath = [IO.Path]::GetFullPath($TemplatePath)

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "Markdown file not found: $InputPath"
}
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
    throw "Viewer template not found: $TemplatePath"
}

$inputDirectory = Split-Path -Parent $InputPath
$outputDirectory = Split-Path -Parent $OutputPath
$lines = [IO.File]::ReadAllLines($InputPath, [Text.Encoding]::UTF8)
$desktops = @()
$desktop = $null
$window = $null
$tab = $null
$capturedAt = $null

function Get-RelativeFilePath([string]$BaseDirectory, [string]$FilePath) {
    $separator = [IO.Path]::DirectorySeparatorChar
    $base = [IO.Path]::GetFullPath($BaseDirectory).TrimEnd($separator) + $separator
    $file = [IO.Path]::GetFullPath($FilePath)
    $relativeUri = (New-Object Uri($base)).MakeRelativeUri((New-Object Uri($file)))
    return [Uri]::UnescapeDataString($relativeUri.ToString())
}

foreach ($line in $lines) {
    if ($line -match '^# Helium Tabs - (\d{4}-\d{2}-\d{2}) (\d{2})[:.](\d{2})\s*$') {
        $capturedAt = '{0}T{1}:{2}:00' -f $Matches[1], $Matches[2], $Matches[3]
        continue
    }

    if ($line -match '^## (.+)$' -and $Matches[1] -ne 'Contents') {
        $desktopName = $Matches[1].Trim()
        $desktopNumber = if ($desktopName -match '(\d+)\s*$') { [int]$Matches[1] - 1 } else { $desktops.Count }
        $desktop = [ordered]@{
            index = $desktopNumber
            name = $desktopName
            windows = @()
            tabCount = 0
        }
        $desktops += $desktop
        $window = $null
        $tab = $null
        continue
    }

    if ($line -match '^### Window: (.*) \(hwnd ([^,]+), (\d+) tabs\)\s*$') {
        if ($null -eq $desktop) { throw "Window found before a desktop heading: $line" }
        $window = [ordered]@{
            hwnd = $Matches[2]
            title = $Matches[1]
            expectedTabs = [int]$Matches[3]
            tabs = @()
        }
        $desktop.windows += $window
        $tab = $null
        continue
    }

    if ($line -match '^#### (\d+)\. (.*)$') {
        if ($null -eq $window) { throw "Tab found before a window heading: $line" }
        $tab = [ordered]@{
            index = [int]$Matches[1]
            title = $Matches[2]
            url = ''
            screenshot = ''
            inactive = $false
            paused = $false
        }
        $window.tabs += $tab
        continue
    }

    if ($null -ne $tab -and $line -match '^- URL: `(.*)`\s*$') {
        $tab.url = $Matches[1]
        continue
    }

    if ($null -ne $tab -and $line -match '^- Notes: (.*)$') {
        $tab.inactive = $Matches[1] -match 'frozen/discarded'
        $tab.paused = $Matches[1] -match '(^|; )paused:'
        continue
    }

    if ($null -ne $tab -and $line -match '^!\[.*\]\((.+)\)\s*$') {
        $sourceImage = Join-Path $inputDirectory ($Matches[1] -replace '/', [IO.Path]::DirectorySeparatorChar)
        $tab.screenshot = Get-RelativeFilePath $outputDirectory $sourceImage
    }
}

if ($desktops.Count -eq 0) { throw 'No desktop headings were found in the Markdown file.' }

$windowCount = 0
$tabCount = 0
foreach ($desktopItem in $desktops) {
    $desktopItem.tabCount = 0
    foreach ($windowItem in $desktopItem.windows) {
        if ($windowItem.tabs.Count -ne $windowItem.expectedTabs) {
            throw "Expected $($windowItem.expectedTabs) tabs for HWND $($windowItem.hwnd), parsed $($windowItem.tabs.Count)."
        }
        foreach ($tabItem in $windowItem.tabs) {
            if (-not $tabItem.screenshot) {
                Write-Warning "No screenshot found for HWND $($windowItem.hwnd), tab $($tabItem.index): $($tabItem.title)"
            }
        }
        $windowItem.Remove('expectedTabs')
        $desktopItem.tabCount += $windowItem.tabs.Count
        $windowCount++
        $tabCount += $windowItem.tabs.Count
    }
}

if (-not $capturedAt) {
    $capturedAt = [IO.File]::GetLastWriteTime($InputPath).ToString('yyyy-MM-ddTHH:mm:ss')
}

$meta = [ordered]@{
    capturedAt = $capturedAt
    desktops = $desktops.Count
    windows = $windowCount
    tabs = $tabCount
}
$dataJson = ConvertTo-Json -InputObject $desktops -Depth 8 -Compress
$metaJson = ConvertTo-Json -InputObject $meta -Depth 3 -Compress
$payload = "window.HELIUM_DATA=$dataJson;window.HELIUM_META=$metaJson;" -replace '<', '\u003c'
$template = [IO.File]::ReadAllText($TemplatePath, [Text.Encoding]::UTF8)
$marker = '/*__HELIUM_ARCHIVE_DATA__*/'
if (-not $template.Contains($marker)) { throw "Template data marker is missing: $marker" }

$html = $template.Replace($marker, $payload)
[IO.File]::WriteAllText($OutputPath, $html, (New-Object Text.UTF8Encoding $false))
Write-Host "Generated $OutputPath ($($desktops.Count) desktops, $windowCount windows, $tabCount tabs)."
