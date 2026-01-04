[CmdletBinding()]
param(
  [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
  [string]$AppsList,
  [Parameter(Mandatory = $false)]
  [string]$DownloadPath = "$env:TEMP\AppInstaller",
  [Parameter(Mandatory = $false)]
  [string]$DestinationPath = (Join-Path -Path (Get-Location) -ChildPath "apps"),
  [Parameter(Mandatory = $false)]
  [int]$ThrottleLimit = 5,
  [Parameter(Mandatory = $false)]
  [switch]$Parallel
)

function Get-YandexDiskFileLink {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$YandexURL
  )
  $baseUrl = "https://cloud-api.yandex.net:443/v1/disk/public/resources/download?public_key="

  $encodedUrl = [System.Uri]::EscapeDataString($YandexURL)

  $fullUrl = $baseUrl + $encodedUrl

  $response = Invoke-RestMethod -Uri $fullUrl -Method Get
  $downloadUrl = $response.href
  $uri = [System.Uri]$downloadUrl
  $queryParams = [System.Web.HttpUtility]::ParseQueryString($uri.Query)

  return [tuple]::Create($downloadUrl, $queryParams['filename'])
}

function Get-GithubFileLink {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryAuthor,
    [Parameter(Mandatory = $true)]
    [string]$RepositoryName,
    [ValidateSet("None", "Match", "Like")]
    [string]$AssetFilterMode = "None",
    [Parameter(Mandatory = $false)]
    [string]$AssetPattern
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
  return [tuple]::Create($asset.browser_download_url, $asset.name)
}

function Get-SourceforgeFileLink {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Repository
  )

  $arguments = @{
    Uri             = "https://sourceforge.net/projects/$Repository/best_release.json"
    UseBasicParsing = $true
    # Verbose         = $true
  }
  $bestRelease = (Invoke-RestMethod @arguments).platform_releases.windows.filename
  return [tuple]::Create("https://unlimited.dl.sourceforge.net/project/$Repository$($bestRelease)?viasf=1", $(Split-Path $bestRelease -Leaf))
}

function Get-WebPageFileLink {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    $PageUrl,
    [ValidateSet("Match", "Like")]
    [string]$FilterMode = "Like",
    [Parameter(Mandatory = $true)]
    [string]$Pattern,
    [Parameter(Mandatory = $false)]
    $Index = 1
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
      throw "Неправильный FilterMode"
    }
  }

  if (-not $downloadLink) {
    throw "Download link not found"
  }

  if ($downloadLink -notlike "http*") {
    $downloadLink = "$PageUrl$downloadLink"
  }
  return [tuple]::Create($downloadLink, $(Split-Path $downloadLink -Leaf))
}

function Get-Apps {
  [CmdletBinding()]
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

function Get-AppLink {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory = $true)]
    $Item
  )
  if (-not $Item.Type) {
    throw "У элемента не задано свойство 'Type'"
  }
  $arguments = @{}
  switch ($Item.Type) {
    "github" {
      if (-not $Item.RepositoryAuthor) {
        throw "У выбранного элемента '$($Item.Name)' не задано свойство 'RepositoryAuthor'."
      }

      if (-not $Item.RepositoryName) {
        throw "У выбранного элемента '$($Item.Name)' не задано свойство 'RepositoryName'."
      }

      $arguments.RepositoryAuthor = $Item.RepositoryAuthor
      $arguments.RepositoryName = $Item.RepositoryName
      $arguments.AssetFilterMode = if ($Item.AssetFilterMode) { $Item.AssetFilterMode } else { 'None' }
      $arguments.AssetPattern = if ($Item.AssetPattern) { $Item.AssetPattern } else { '' }
      return Get-GithubFileLink @arguments
    }
    "direct" {
      if ($Item.DownloadUrl) {
        return [tuple]::Create($Item.DownloadUrl, $(Split-Path $Item.DownloadUrl -Leaf))
      }
      if (-not $Item.PageUrl -or -not $Item.FilterMode -or -not $Item.Pattern) {
        throw "У выбранного элемента '$($Item.Name)' не задано свойство 'DownloadUrl'."
      }
      $arguments.PageUrl = $Item.PageUrl
      $arguments.FilterMode = if ($Item.FilterMode) { $Item.FilterMode } else { 'Like' }
      $arguments.Pattern = $Item.Pattern
      $arguments.Index = if ($Item.Index) { $Item.Index } else { 1 }
      return Get-WebPageFileLink @arguments
    }
    "sourceforge" {
      if (-not $Item.Repository) {
        throw "У выбранного элемента '$($Item.Name)' не задано свойство 'Repository'."
      }
      $arguments.Repository = $Item.Repository
      return Get-SourceforgeFileLink @arguments
    }
    "yandex" {
      if (-not $Item.DownloadUrl) {
        throw "У выбранного элемента '$($Item.Name)' не задано свойство 'DownloadUrl'."
      }
      $arguments.YandexURL = $Item.DownloadUrl
      return Get-YandexDiskFileLink @arguments
    }
    Default {
      return $null
    }
  }
}

function Resolve-AppsLinks {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [PSCustomObject[]]$Apps
  )

  process {
    foreach ($app in $Apps) {
      # Проверяем, что у элемента есть Name (обязательно для идентификации)
      if (-not $app.Name) {
        Write-Warning "Пропуск элемента без свойства 'Name'"
        continue
      }

      try {
        $linkTuple = Get-AppLink -Item $app

        if (-not $linkTuple) {
          Write-Warning "Не удалось получить ссылку для приложения '$($app.Name)' (неподдерживаемый тип или ошибка)"
          continue
        }

        $downloadUrl, $fileName = $linkTuple.Item1, $linkTuple.Item2

        [PSCustomObject]@{
          Name        = $app.Name
          Arguments   = $app.Arguments  # Может быть $null — это нормально
          DownloadUrl = $downloadUrl
          FilePath    = $(Join-Path -Path $DownloadPath -ChildPath $fileName)
        }
      }
      catch {
        Write-Warning "Ошибка при обработке приложения '$($app.Name)': $_"
      }
    }
  }
}

function Get-DownloadedApp {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    $App,
    [Parameter(Mandatory = $false)]
    [switch]$ForceDownload
  )
  try {
    if ((Test-Path $App.FilePath) -and (-not $ForceDownload)) {
      return $App
    }
    Write-Host "Скачивание: $($App.Name)" -ForegroundColor Yellow
    $arguments = @{
      Uri             = $App.DownloadURL
      OutFile         = $App.FilePath
      UseBasicParsing = $true
      # Verbose         = $true
    }
    Invoke-WebRequest @arguments
    Write-Host "Завершено: $($App.Name) -> $($App.FilePath)" -ForegroundColor Green
    return $true
  }
  catch {
    Write-Error "Ошибка при скачивании $($App.Name): $_"
    return $false
  }
}

function Get-DownloadedApps {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Apps,
    [Parameter(Mandatory = $false)]
    [int]$ThrottleLimit = 5,
    [Parameter(Mandatory = $false)]
    [switch]$Parallel,
    [Parameter(Mandatory = $false)]
    [switch]$ForceDownload
  )
  $successfulApps = @()

  if ($Parallel) {
    Write-Host "Параллельное скачивание (ThrottleLimit: $ThrottleLimit)" -ForegroundColor Cyan

    $funcDef = ${function:Get-DownloadedApp}.ToString()

    $successfulApps = $Apps | ForEach-Object -Parallel {
      $app = $_
      $force = $using:ForceDownload
      ${function:Get-DownloadedApp} = $using:funcDef
      $arguments = @{
        App = $app
      }
      if($force) {
        $arguments.ForceDownload = $true
      }
      $result = Get-DownloadedApp @arguments;
      if($result) { return $app } else { return $null }
    } -ThrottleLimit $ThrottleLimit | Where-Object { $_ -ne $null }
  }
  else {
    Write-Host "Последовательное скачивание" -ForegroundColor Cyan
    foreach ($app in $Apps) {
      $arguments = @{
        App = $app
      }
      if($ForceDownload) {
        $arguments.ForceDownload = $true
      }
      if(Get-DownloadedApp @arguments) {
        $successfulApps += $app
      }
    }
  }

  return $successfulApps
}

function Get-7z {
  $possibleBases += @(
    "${env:ProgramFiles}\7-Zip"
    "${env:ProgramFiles(x86)}\7-Zip"
    "C:\Program Files\7-Zip"
    "C:\Program Files (x86)\7-Zip"
  )

  $currentDir = (Get-Location).Path
  $possibleBases += $currentDir

  $possibleBases += Get-ChildItem -Path $currentDir -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^7.?[Zz]ip$|^7[zZ]$' } |
  Select-Object -ExpandProperty FullName

  if ($PSScriptRoot) {
    $possibleBases += $PSScriptRoot

    $possibleBases += Get-ChildItem -Path $PSScriptRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^7.?[Zz]ip$|^7[zZ]$' } |
    Select-Object -ExpandProperty FullName
  }

  $possibleBases = $possibleBases | Sort-Object -Unique

  $exeNames = @("7z.exe", "7Z.exe", "7zip.exe", "7ZIP.exe", "7za.exe", "7Za.exe", "7ZA.exe")

  foreach ($base in $possibleBases) {
    if (-not (Test-Path $base)) { continue }
    foreach ($exe in $exeNames) {
      $fullPath = Join-Path $base $exe
      if (Test-Path $fullPath) {
        return $fullPath
      }
    }
  }
  return $null
}

function Expand-Archive-Power {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $false)]
    [string]$DestinationPath = (Get-Location),
    [Parameter(Mandatory = $false)]
    [switch]$Force
  )

  if (-not (Test-Path $Path)) {
    throw "Архив не найден: $Path"
  }

  if (-not (Test-Path $DestinationPath)) {
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
  }

  $fileExtension = [System.IO.Path]::GetExtension($Path).ToLower()

  try {
    if ($fileExtension -eq ".zip") {
      $arguments = @{
        Path            = $Path
        DestinationPath = $DestinationPath
      }
      if ($Force) {
        $arguments.Force = $true
      }
      Expand-Archive @arguments
    }
    else {
      $7zipExe = Get-7z

      if (-not $7zipExe) {
        $7zipExe = (Get-Command "7z.exe" -ErrorAction SilentlyContinue).Source
      }

      if (-not $7zipExe) {
        throw "7-Zip не найден на компьютере. Установите 7-Zip для распаковки архивов с расширением '$fileExtension' или используйте ZIP-архив."
      }
      $arguments = @(
        "x",
        "`"$Path`"",
        "-o`"$DestinationPath`"",
        "-y"
      )

      if ($Force) {
        $arguments += "-aoa"
      }
      $process = Start-Process -FilePath $7zipExe -ArgumentList $arguments -NoNewWindow -Wait -PassThru

      if ($process.ExitCode -ne 0) {
        throw "7-Zip завершился с ошибкой. Код выхода: $($process.ExitCode)"
      }
    }
  }
  catch {
    throw "Ошибка при распаковке архива '$Path': $($_.Exception.Message)"
  }
}

function Install-Apps {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Apps,
    [Parameter(Mandatory = $false)]
    [string]$DestinationPath = (Join-Path -Path (Get-Location) -ChildPath "apps")
  )
  $executableExtensions = @('.exe', '.msi')
  foreach ($app in $Apps) {
    Write-Host "Установка: $($App.Name)" -ForegroundColor Yellow
    if (-not (Test-Path $app.FilePath)) {
      Write-Error "Файл не найден: $($app.FilePath)"
      continue
    }
    $fileExtension = [System.IO.Path]::GetExtension($app.FilePath).ToLower()
    if ($fileExtension -in $executableExtensions) {
      Write-Host "Установка: $($App.Name)" -ForegroundColor Yellow
      $rawArgs = @($Item.Arguments)
      $argsForInstaller = foreach ($a in $rawArgs) {
        $a.ToString().
        Replace('$DestinationPath', $DestinationPath).
        Replace('$Name', $Item.Name)
      }
      $process = Start-Process -FilePath $app.FilePath -ArgumentList $argsForInstaller -Wait -PassThru

      if ($process.ExitCode -ne 0) {
        throw "Ошибка при установке. Код выхода: $($process.ExitCode)"
      }
      else {
        Write-Host "Приложение $($App.Name) установлено" -ForegroundColor Green
      }

    }
    else {
      Write-Host "Распаковка: $($App.Name)" -ForegroundColor Yellow
      try {
        Expand-Archive-Power -Path $app.FilePath -DestinationPath $DestinationPath -Force
        Write-Host "Архив $($App.Name) успешно распакован" -ForegroundColor Green
      }
      catch {

      }
    }
  }
}

$apps = $(Resolve-AppsLinks $(Get-Apps -AppsList $AppsList))

$arguments = @{
  Apps          = $apps
  ThrottleLimit = $ThrottleLimit
  ForceDownload = $true
}

if ($Parallel) {
  $arguments.Parallel = $true
}

Install-Apps -Apps $(Get-DownloadedApps @arguments) -DestinationPath $DestinationPath
