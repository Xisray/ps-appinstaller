param(
  [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
  [string]$AppsList,

  [Parameter(Mandatory = $false)]
  [string]$DownloadPath = "$env:TEMP\AppInstaller"
)
function Get-DownloadedFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DownloadURL,
    [Parameter(Mandatory = $false)]
    [bool]$ForceDownload = $false,
    [Parameter(Mandatory = $false)]
    [string]$DownloadPath = "$env:TEMP",
    [Parameter(Mandatory = $false)]
    [string]$Filename = $null
  )
  if (-not (Test-Path $DownloadPath)) {
    New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
  }

  if ([string]::IsNullOrWhiteSpace($Filename)) {
    $Filename = Split-Path $DownloadURL -Leaf
  }

  $path = Join-Path -Path $DownloadPath -ChildPath $Filename

  if ((Test-Path $path) -and (-not $ForceDownload)) {
    return $path
  }

  $Parameters = @{
    Uri             = "$DownloadURL"
    OutFile         = "$path"
    UseBasicParsing = $true
    Verbose         = $true
  }
  Invoke-WebRequest @Parameters
  return $path
}

function Get-YandexDiskFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$YandexURL,
    [Parameter(Mandatory = $false)]
    [bool]$ForceDownload = $false,
    [Parameter(Mandatory = $false)]
    [string]$DownloadPath = "$env:TEMP"
  )
  $baseUrl = "https://cloud-api.yandex.net:443/v1/disk/public/resources/download?public_key="

  $encodedUrl = [System.Uri]::EscapeDataString($YandexURL)

  $fullUrl = $baseUrl + $encodedUrl

  $response = Invoke-RestMethod -Uri $fullUrl -Method Get
  $downloadUrl = $response.href
  $uri = [System.Uri]$downloadUrl
  $queryParams = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
  $filename = $queryParams['filename']
  return Get-DownloadedFile -DownloadURL $downloadUrl -ForceDownload $ForceDownload -DownloadPath $DownloadPath -Filename $filename
}

function Get-GithubFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryAuthor,
    [Parameter(Mandatory = $true)]
    [string]$RepositoryName,
    [ValidateSet("None", "Match", "Like")]
    [string]$AssetFilterMode = "None",
    [Parameter(Mandatory = $false)]
    [string]$AssetPattern,
    [Parameter(Mandatory = $false)]
    [bool]$ForceDownload = $false,
    [Parameter(Mandatory = $false)]
    [string]$DownloadPath = "$env:TEMP"
  )
  $releasesUri = "https://api.github.com/repos/$RepositoryAuthor/$RepositoryName/releases/latest"
  $releaseJson = Invoke-RestMethod $releasesUri

  if ($AssetFilterMode -eq "None" -or [string]::IsNullOrWhiteSpace($AssetPattern)) {
    if ($AssetFilterMode -ne "None" -and [string]::IsNullOrWhiteSpace($AssetPattern)) {
      throw "AssetPattern не может быть пустым при режиме Match или Like."
    }

    $asset = $releaseJson.assets | Select-Object -First 1
  }
  else {
    switch ($AssetFilterMode) {
      "Match" {
        $asset = $releaseJson.assets |
        Where-Object { $_.name -match $AssetPattern } |
        Select-Object -First 1
      }

      "Like" {
        $asset = $releaseJson.assets |
        Where-Object { $_.name -like $AssetPattern } |
        Select-Object -First 1
      }
    }

    if (-not $asset) {
      throw "Не найден ни один asset, соответствующий фильтру '$AssetPattern' ($AssetFilterMode)."
    }
  }

  $downloadUrl = $asset.browser_download_url
  return Get-DownloadedFile -DownloadURL $downloadUrl -ForceDownload $ForceDownload -DownloadPath $DownloadPath -Filename $asset.name
}

function Get-SourceforgeFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,
    [Parameter(Mandatory = $false)]
    [bool]$ForceDownload = $false,
    [Parameter(Mandatory = $false)]
    [string]$DownloadPath = "$env:TEMP"
  )

  $Parameters = @{
    Uri             = "https://sourceforge.net/projects/$Repository/best_release.json"
    UseBasicParsing = $true
    Verbose         = $true
  }
  $bestRelease = (Invoke-RestMethod @Parameters).platform_releases.windows.filename

  return Get-DownloadedFile -DownloadURL "https://unlimited.dl.sourceforge.net/project/$Repository$($bestRelease)?viasf=1" -ForceDownload $ForceDownload -DownloadPath $DownloadPath -Filename $(Split-Path $bestRelease -Leaf)
}

function Get-FileFromWebPage {
  param(
    [Parameter(Mandatory = $true)]
    $PageUrl,
    [ValidateSet("Match", "Like")]
    [string]$FilterMode = "Like",
    [Parameter(Mandatory = $true)]
    [string]$Pattern,
    [Parameter(Mandatory = $false)]
    $Index = 1,
    [Parameter(Mandatory = $false)]
    [bool]$ForceDownload = $false,
    [Parameter(Mandatory = $false)]
    [string]$DownloadPath = "$env:TEMP"
  )
  $pageContent = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing
  $skipCount = $Index - 1
  switch ($FilterMode) {
    "Like" {
      $downloadLink = $pageContent.Links | Where-Object {
        $_.href -like $Pattern
      } | Select-Object -Skip $skipCount -First 1 -ExpandProperty href
    }
    "Match" {
      $downloadLink = $pageContent.Links | Where-Object {
        $_.href -match $Pattern
      } | Select-Object -Skip $skipCount -First 1 -ExpandProperty href
    }
    Default {
      throw "Daun"
    }
  }

  if (-not $downloadLink) {
    throw "Download link not found"
  }

  if ($downloadLink -notlike "http*") {
    $downloadLink = "$PageUrl$downloadLink"
  }
  return Get-DownloadedFile -DownloadURL $downloadLink -ForceDownload $ForceDownload -DownloadPath $DownloadPath
}

function Get-Apps {
  param(
    [Parameter(Mandatory = $false)]
    [string]$AppsList
  )

  # Если путь не указан, ищем apps.json рядом со скриптом
  if ([string]::IsNullOrWhiteSpace($AppsList)) {
    if ($PSScriptRoot) {
      $AppsList = Join-Path -Path $PSScriptRoot -ChildPath "apps.json"
    }
    else {
      $AppsList = Join-Path -Path (Get-Location) -ChildPath "apps.json"
    }

    if (-not (Test-Path $AppsList)) {
      throw "Файл конфигурации не найден: $AppsList"
    }

    Write-Verbose "Используется конфигурация по умолчанию: $AppsList"
  }

  # Проверяем, является ли путь URL
  if ($AppsList -match '^https?://') {
    Write-Verbose "Загрузка конфигурации из URL: $AppsList"
    try {
      $jsonContent = Invoke-RestMethod -Uri $AppsList -UseBasicParsing
      return $jsonContent
    }
    catch {
      throw "Не удалось загрузить конфигурацию из URL: $_"
    }
  }
  # Локальный файл
  else {
    if (-not (Test-Path $AppsList)) {
      throw "Файл конфигурации не найден: $AppsList"
    }

    Write-Verbose "Чтение локального файла конфигурации: $AppsList"
    try {
      $jsonContent = Get-Content -Path $AppsList -Raw | ConvertFrom-Json
      return $jsonContent
    }
    catch {
      throw "Не удалось прочитать файл конфигурации: $_"
    }
  }
}
Write-Host $(Get-Apps -AppsList $AppsList)
