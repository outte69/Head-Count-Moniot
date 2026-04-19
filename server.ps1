param(
  [int]$Port = 4567,
  [string]$BindHost = "localhost"
)

$ErrorActionPreference = "Stop"

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PublicDir = Join-Path $AppDir "public"
$RecordsFile = Join-Path $AppDir "records.json"
$UsersFile = Join-Path $AppDir "users.json"
$AuditFile = Join-Path $AppDir "audit_log.json"
$Sessions = @{}

function Ensure-JsonFile {
  param(
    [string]$Path,
    [object]$DefaultValue
  )

  if (-not (Test-Path $Path)) {
    $DefaultValue | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
  }
}

function Get-FileJson {
  param([string]$Path)

  Ensure-JsonFile -Path $Path -DefaultValue @()
  $raw = Get-Content -Path $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $parsed = $raw | ConvertFrom-Json
  if ($null -eq $parsed) { return @() }
  if ($parsed -is [System.Array]) { return @($parsed) }
  return @($parsed)
}

function Save-FileJson {
  param(
    [string]$Path,
    [object]$Value
  )

  $Value | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Get-Sha256Hash {
  param([string]$Value)

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = $sha.ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
  }
  finally {
    $sha.Dispose()
  }
}

function New-PasswordHash {
  param(
    [string]$Password,
    [string]$Salt
  )

  return Get-Sha256Hash("$Salt::$Password")
}

function Ensure-UsersFile {
  if (-not (Test-Path $UsersFile)) {
    $salt = [guid]::NewGuid().ToString("N")
    $defaultUsers = @(
      @{
        username = "Supervisor"
        role = "admin"
        passwordSalt = $salt
        passwordHash = (New-PasswordHash -Password "Cross@119" -Salt $salt)
        createdAt = ([DateTime]::UtcNow.ToString("o"))
      }
    )
    Save-FileJson -Path $UsersFile -Value $defaultUsers
  }
}

function Initialize-Storage {
  Ensure-JsonFile -Path $RecordsFile -DefaultValue @()
  Ensure-UsersFile
  Ensure-JsonFile -Path $AuditFile -DefaultValue @()
}

function Read-RequestBody {
  param($Request)

  $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
  try {
    return $reader.ReadToEnd()
  }
  finally {
    $reader.Dispose()
  }
}

function Parse-JsonBody {
  param($Request)

  $body = Read-RequestBody -Request $Request
  if ([string]::IsNullOrWhiteSpace($body)) { return @{} }
  return $body | ConvertFrom-Json
}

function Get-CookiesMap {
  param($Request)

  $map = @{}
  foreach ($cookie in $Request.Cookies) {
    $map[$cookie.Name] = $cookie.Value
  }
  return $map
}

function Get-CurrentUser {
  param($Request)

  $cookies = Get-CookiesMap -Request $Request
  $token = $cookies["visitor_monitor_session"]
  if (-not $token) { return $null }
  return $Sessions[$token]
}

function Require-User {
  param($User)
  if ($null -eq $User) { throw "401|Please sign in to continue" }
}

function Require-Admin {
  param($User)
  Require-User -User $User
  if ($User.role -ne "admin") { throw "403|Admin access is required" }
}

function Get-NumberValue {
  param($Value)
  try { return [int][double]$Value } catch { return 0 }
}

function Normalize-Time {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { throw "400|Missing required fields: time" }
  if ($Value -notmatch '^([01]?\d|2[0-3]):([0-5]\d)$') { throw "400|Time must use 24-hour HH:MM format" }
  return "{0:D2}:{1}" -f [int]$Matches[1], $Matches[2]
}

function Normalize-Record {
  param(
    $Payload,
    [string]$ExistingId = $null
  )

  $required = @("date", "movement", "section", "boat", "user")
  $missing = @()
  foreach ($field in $required) {
    $value = [string]$Payload.$field
    if ([string]::IsNullOrWhiteSpace($value)) { $missing += $field }
  }
  if ($missing.Count -gt 0) { throw "400|Missing required fields: $($missing -join ', ')" }

  return @{
    id = $(if ($ExistingId) { $ExistingId } elseif ($Payload.id) { [string]$Payload.id } else { [guid]::NewGuid().ToString() })
    date = [string]$Payload.date
    time = Normalize-Time -Value ([string]$Payload.time)
    movement = $(if ([string]$Payload.movement -eq "departure") { "departure" } else { "arrival" })
    section = ([string]$Payload.section).Trim()
    boat = ([string]$Payload.boat).Trim()
    visitors = Get-NumberValue $Payload.visitors
    staffs = Get-NumberValue $Payload.staffs
    guests = Get-NumberValue $Payload.guests
    eventVisitors = Get-NumberValue $Payload.eventVisitors
    contractors = Get-NumberValue $Payload.contractors
    yachtGuests = Get-NumberValue $Payload.yachtGuests
    fnf = Get-NumberValue $Payload.fnf
    serviceJetty = Get-NumberValue $Payload.serviceJetty
    remarks = ([string]$Payload.remarks).Trim()
    user = ([string]$Payload.user).Trim()
    updatedAt = [DateTime]::UtcNow.ToString("o")
  }
}

function Get-RecordSummary {
  param($Record)
  if ($null -eq $Record) { return @{} }
  return @{
    date = $Record.date
    time = $Record.time
    movement = $Record.movement
    section = $Record.section
    boat = $Record.boat
    visitors = $Record.visitors
    staffs = $Record.staffs
    guests = $Record.guests
    eventVisitors = $Record.eventVisitors
    contractors = $Record.contractors
    yachtGuests = $Record.yachtGuests
    fnf = $Record.fnf
    serviceJetty = $Record.serviceJetty
    remarks = $Record.remarks
    user = $Record.user
  }
}

function Write-AuditEvent {
  param(
    [string]$EventType,
    [string]$Actor,
    [string]$TargetType,
    [string]$TargetId,
    $Details
  )

  $audit = Get-FileJson -Path $AuditFile
  $audit += @{
    id = [guid]::NewGuid().ToString()
    eventType = $EventType
    actor = $Actor
    targetType = $TargetType
    targetId = $TargetId
    details = $Details
    createdAt = [DateTime]::UtcNow.ToString("o")
  }
  Save-FileJson -Path $AuditFile -Value @($audit | Select-Object -Last 1000)
}

function Get-PublicUser {
  param($User)
  return @{
    username = $User.username
    role = $(if ($User.role) { $User.role } else { "user" })
    createdAt = $User.createdAt
  }
}

function To-DisplayDate {
  param([string]$IsoDate)
  if ([string]::IsNullOrWhiteSpace($IsoDate)) { return "" }
  return (($IsoDate -split "-")[2], ($IsoDate -split "-")[1], ($IsoDate -split "-")[0]) -join "."
}

function Get-MonthKey {
  param([string]$IsoDate)
  if ([string]::IsNullOrWhiteSpace($IsoDate)) { return "" }
  return $IsoDate.Substring(0, 7)
}

function Get-Totals {
  param($Pool)

  $totals = @{
    visitorArrivals = 0; visitorDepartures = 0; visitorsOnIsland = 0
    staffArrivals = 0; staffDepartures = 0; staffsOnIsland = 0
    guestArrivals = 0; guestDepartures = 0; guestsOnIsland = 0
    eventVisitorArrivals = 0; eventVisitorDepartures = 0; eventVisitorsOnIsland = 0
    contractorArrivals = 0; contractorDepartures = 0
    yachtGuestArrivals = 0; yachtGuestDepartures = 0
    fnfArrivals = 0; fnfDepartures = 0
    serviceJettyVisitors = 0
  }

  foreach ($record in $Pool) {
    $arrival = $record.movement -eq "arrival"
    $direction = $(if ($arrival) { 1 } else { -1 })
    if ($arrival) {
      $totals.visitorArrivals += [int]$record.visitors
      $totals.staffArrivals += [int]$record.staffs
      $totals.guestArrivals += [int]$record.guests
      $totals.eventVisitorArrivals += [int]$record.eventVisitors
      $totals.contractorArrivals += [int]$record.contractors
      $totals.yachtGuestArrivals += [int]$record.yachtGuests
      $totals.fnfArrivals += [int]$record.fnf
    } else {
      $totals.visitorDepartures += [int]$record.visitors
      $totals.staffDepartures += [int]$record.staffs
      $totals.guestDepartures += [int]$record.guests
      $totals.eventVisitorDepartures += [int]$record.eventVisitors
      $totals.contractorDepartures += [int]$record.contractors
      $totals.yachtGuestDepartures += [int]$record.yachtGuests
      $totals.fnfDepartures += [int]$record.fnf
    }
    $totals.visitorsOnIsland += $direction * [int]$record.visitors
    $totals.staffsOnIsland += $direction * [int]$record.staffs
    $totals.guestsOnIsland += $direction * [int]$record.guests
    $totals.eventVisitorsOnIsland += $direction * [int]$record.eventVisitors
    $totals.serviceJettyVisitors += [int]$record.serviceJetty
  }

  return $totals
}

function Convert-ToCsvCell {
  param($Value)
  return '"' + ([string]$Value).Replace('"', '""') + '"'
}

function Build-Csv {
  param(
    $Rows,
    $SummaryBlocks
  )

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($block in $SummaryBlocks) {
    foreach ($row in $block) {
      $cells = @()
      foreach ($value in $row) { $cells += (Convert-ToCsvCell $value) }
      $lines.Add(($cells -join ","))
    }
  }

  $header = @("Date","Time","Movement","Section","Boat","Visitors","Staffs","Guests","Event Visitors","Contractors","Yacht Guests","F&F","Service Jetty","Remarks","Saved By")
  $lines.Add((($header | ForEach-Object { Convert-ToCsvCell $_ }) -join ","))

  foreach ($record in $Rows) {
    $row = @(
      (To-DisplayDate $record.date), $record.time, $record.movement, $record.section, $record.boat,
      $record.visitors, $record.staffs, $record.guests, $record.eventVisitors, $record.contractors,
      $record.yachtGuests, $record.fnf, $record.serviceJetty, $record.remarks, $record.user
    )
    $lines.Add((($row | ForEach-Object { Convert-ToCsvCell $_ }) -join ","))
  }

  return ($lines -join "`n")
}

function Summary-Block {
  param(
    [string]$Title,
    $Entries
  )

  $block = New-Object System.Collections.Generic.List[object]
  $block.Add(@($Title))
  foreach ($entry in $Entries) { $block.Add($entry) }
  $block.Add(@())
  return $block
}

function Apply-Filters {
  param(
    $Records,
    $Filters
  )

  $month = if ($Filters.month) { [string]$Filters.month } else { "all" }
  $date = if ($Filters.date) { [string]$Filters.date } else { "all" }
  $section = if ($Filters.section) { [string]$Filters.section } else { "all" }
  $movement = if ($Filters.movement) { [string]$Filters.movement } else { "all" }
  $query = if ($Filters.query) { ([string]$Filters.query).ToLowerInvariant() } else { "" }

  return @($Records | Where-Object {
    $monthOk = ($month -eq "all") -or ((Get-MonthKey $_.date) -eq $month)
    $dateOk = ($date -eq "all") -or ($_.date -eq $date)
    $sectionOk = ($section -eq "all") -or ($_.section -eq $section)
    $movementOk = ($movement -eq "all") -or ($_.movement -eq $movement)
    $text = @((To-DisplayDate $_.date), $_.time, $_.movement, $_.section, $_.boat, $_.remarks, $_.user) -join " "
    $textOk = ([string]::IsNullOrWhiteSpace($query)) -or $text.ToLowerInvariant().Contains($query)
    $monthOk -and $dateOk -and $sectionOk -and $movementOk -and $textOk
  })
}

function Write-JsonResponse {
  param(
    $Response,
    [int]$StatusCode,
    $Payload,
    $ExtraHeaders = @{}
  )

  $json = $Payload | ConvertTo-Json -Depth 10
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $Response.StatusCode = $StatusCode
  $Response.ContentType = "application/json; charset=utf-8"
  $Response.Headers["Cache-Control"] = "no-store"
  $Response.Headers["X-Content-Type-Options"] = "nosniff"
  $Response.Headers["X-Frame-Options"] = "SAMEORIGIN"
  $Response.Headers["Referrer-Policy"] = "same-origin"
  foreach ($key in $ExtraHeaders.Keys) { $Response.Headers[$key] = $ExtraHeaders[$key] }
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Response.Close()
}

function Write-TextResponse {
  param(
    $Response,
    [int]$StatusCode,
    [string]$ContentType,
    [byte[]]$Bytes
  )

  $Response.StatusCode = $StatusCode
  $Response.ContentType = $ContentType
  $Response.Headers["Cache-Control"] = "no-store"
  $Response.Headers["X-Content-Type-Options"] = "nosniff"
  $Response.Headers["X-Frame-Options"] = "SAMEORIGIN"
  $Response.Headers["Referrer-Policy"] = "same-origin"
  $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
  $Response.Close()
}

function Serve-StaticFile {
  param($Context)

  $path = $Context.Request.Url.AbsolutePath
  if ($path -eq "/") { $path = "/index.html" }
  $relative = $path.TrimStart("/") -replace '/', [IO.Path]::DirectorySeparatorChar
  $fullPath = Join-Path $PublicDir $relative

  if (-not (Test-Path $fullPath -PathType Leaf)) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("Not found")
    Write-TextResponse -Response $Context.Response -StatusCode 404 -ContentType "text/plain; charset=utf-8" -Bytes $bytes
    return
  }

  $extension = [IO.Path]::GetExtension($fullPath).ToLowerInvariant()
  $contentType = switch ($extension) {
    ".html" { "text/html; charset=utf-8" }
    ".css"  { "text/css; charset=utf-8" }
    ".js"   { "application/javascript; charset=utf-8" }
    ".json" { "application/json; charset=utf-8" }
    ".svg"  { "image/svg+xml" }
    ".png"  { "image/png" }
    ".jpg"  { "image/jpeg" }
    ".jpeg" { "image/jpeg" }
    default { "application/octet-stream" }
  }

  $bytes = [IO.File]::ReadAllBytes($fullPath)
  Write-TextResponse -Response $Context.Response -StatusCode 200 -ContentType $contentType -Bytes $bytes
}

Initialize-Storage

$listener = [System.Net.HttpListener]::new()
$isLocalOnly = $BindHost -eq "localhost" -or $BindHost -eq "127.0.0.1"
$prefix = if ($isLocalOnly) { "http://localhost:$Port/" } else { "http://$BindHost`:$Port/" }
$listener.Prefixes.Add($prefix)

try {
  $listener.Start()
}
catch {
  if (-not $isLocalOnly) {
    throw "403|Windows blocked network access for $BindHost:$Port. Ask IT to reserve the URL with netsh http add urlacl url=http://$BindHost`:$Port/ user=%USERNAME% or run the localhost-only launcher."
  }
  throw
}

if ($isLocalOnly) {
  Write-Host "Visitor Island Monitor PowerShell server running on http://localhost:$Port"
}
else {
  Write-Host "Visitor Island Monitor PowerShell server running on http://$BindHost:$Port"
}

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      $request = $context.Request
      $response = $context.Response
      $path = $request.Url.AbsolutePath
      $method = $request.HttpMethod.ToUpperInvariant()

      if (-not $path.StartsWith("/api/")) {
        Serve-StaticFile -Context $context
        continue
      }

      $currentUser = Get-CurrentUser -Request $request

      switch ($path) {
        "/api/health" {
          if ($method -ne "GET") { throw "405|Method not allowed" }
          Write-JsonResponse -Response $response -StatusCode 200 -Payload @{ status = "ok"; app = "visitor-island-monitor-powershell" }
          continue
        }
        "/api/session" {
          if ($method -ne "GET") { throw "405|Method not allowed" }
          Require-User -User $currentUser
          Write-JsonResponse -Response $response -StatusCode 200 -Payload @{ user = (Get-PublicUser $currentUser) }
          continue
        }
        "/api/login" {
          if ($method -ne "POST") { throw "405|Method not allowed" }
          $payload = Parse-JsonBody -Request $request
          $username = ([string]$payload.username).Trim().ToLowerInvariant()
          $password = [string]$payload.password
          $users = Get-FileJson -Path $UsersFile
          $user = $users | Where-Object { ([string]$_.username).ToLowerInvariant() -eq $username } | Select-Object -First 1
          if ($null -eq $user) { throw "401|Invalid username or password" }
          if ((New-PasswordHash -Password $password -Salt ([string]$user.passwordSalt)) -ne [string]$user.passwordHash) { throw "401|Invalid username or password" }
          $token = [guid]::NewGuid().ToString("N")
          $Sessions[$token] = Get-PublicUser $user
          $cookie = [System.Net.Cookie]::new("visitor_monitor_session", $token, "/")
          $cookie.HttpOnly = $true
          $context.Response.Cookies.Add($cookie)
          Write-JsonResponse -Response $response -StatusCode 200 -Payload @{ user = (Get-PublicUser $user) }
          continue
        }
        "/api/logout" {
          if ($method -ne "POST") { throw "405|Method not allowed" }
          $cookies = Get-CookiesMap -Request $request
          $token = $cookies["visitor_monitor_session"]
          if ($token) { $Sessions.Remove($token) | Out-Null }
          $cookie = [System.Net.Cookie]::new("visitor_monitor_session", "", "/")
          $cookie.Expires = [DateTime]::UtcNow.AddDays(-1)
          $context.Response.Cookies.Add($cookie)
          Write-JsonResponse -Response $response -StatusCode 200 -Payload @{ success = $true }
          continue
        }
      }

      if ($path -eq "/api/records") {
        Require-User -User $currentUser
        if ($method -eq "GET") {
          $records = @(Get-FileJson -Path $RecordsFile | Sort-Object -Property @{ Expression = { $_.date } ; Descending = $true }, @{ Expression = { $_.time } ; Descending = $true })
          Write-JsonResponse -Response $response -StatusCode 200 -Payload $records
          continue
        }
        if ($method -eq "POST") {
          $payload = Parse-JsonBody -Request $request
          $records = Get-FileJson -Path $RecordsFile
          $record = Normalize-Record -Payload $payload
          $records += $record
          Save-FileJson -Path $RecordsFile -Value $records
          Write-AuditEvent -EventType "record_created" -Actor $record.user -TargetType "record" -TargetId $record.id -Details (Get-RecordSummary $record)
          Write-JsonResponse -Response $response -StatusCode 201 -Payload $record
          continue
        }
        throw "405|Method not allowed"
      }

      if ($path.StartsWith("/api/record/")) {
        Require-User -User $currentUser
        $id = $path.Substring("/api/record/".Length)
        if ([string]::IsNullOrWhiteSpace($id)) { throw "400|Missing record id" }
        $records = Get-FileJson -Path $RecordsFile
        $match = $records | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if ($null -eq $match) { throw "404|Record not found" }
        if ($method -eq "PUT") {
          $payload = Parse-JsonBody -Request $request
          $updated = Normalize-Record -Payload $payload -ExistingId $id
          $newRecords = foreach ($record in $records) { if ($record.id -eq $id) { $updated } else { $record } }
          Save-FileJson -Path $RecordsFile -Value @($newRecords)
          Write-AuditEvent -EventType "record_updated" -Actor $updated.user -TargetType "record" -TargetId $updated.id -Details @{ before = (Get-RecordSummary $match); after = (Get-RecordSummary $updated) }
          Write-JsonResponse -Response $response -StatusCode 200 -Payload $updated
          continue
        }
        if ($method -eq "DELETE") {
          Require-Admin -User $currentUser
          $newRecords = @($records | Where-Object { $_.id -ne $id })
          Save-FileJson -Path $RecordsFile -Value $newRecords
          Write-AuditEvent -EventType "record_deleted" -Actor $currentUser.username -TargetType "record" -TargetId $match.id -Details (Get-RecordSummary $match)
          Write-JsonResponse -Response $response -StatusCode 200 -Payload $match
          continue
        }
        throw "405|Method not allowed"
      }

      if ($path -eq "/api/users") {
        Require-Admin -User $currentUser
        if ($method -eq "GET") {
          $users = Get-FileJson -Path $UsersFile | ForEach-Object { Get-PublicUser $_ }
          Write-JsonResponse -Response $response -StatusCode 200 -Payload $users
          continue
        }
        if ($method -eq "POST") {
          $payload = Parse-JsonBody -Request $request
          $username = ([string]$payload.username).Trim()
          $password = [string]$payload.password
          $role = if ([string]$payload.role -eq "admin") { "admin" } else { "user" }
          if ([string]::IsNullOrWhiteSpace($username)) { throw "400|Username is required" }
          if ($password.Length -lt 8) { throw "400|Password must be at least 8 characters" }
          $users = Get-FileJson -Path $UsersFile
          if ($users | Where-Object { ([string]$_.username).ToLowerInvariant() -eq $username.ToLowerInvariant() }) { throw "409|That username already exists" }
          $salt = [guid]::NewGuid().ToString("N")
          $user = @{
            username = $username
            role = $role
            passwordSalt = $salt
            passwordHash = (New-PasswordHash -Password $password -Salt $salt)
            createdAt = [DateTime]::UtcNow.ToString("o")
          }
          $users += $user
          Save-FileJson -Path $UsersFile -Value $users
          Write-AuditEvent -EventType "user_created" -Actor $currentUser.username -TargetType "user" -TargetId $username -Details (Get-PublicUser $user)
          Write-JsonResponse -Response $response -StatusCode 201 -Payload (Get-PublicUser $user)
          continue
        }
        throw "405|Method not allowed"
      }

      if ($path -eq "/api/audit-log") {
        Require-Admin -User $currentUser
        if ($method -ne "GET") { throw "405|Method not allowed" }
        $audit = @(Get-FileJson -Path $AuditFile | Sort-Object -Property @{ Expression = { $_.createdAt } ; Descending = $true } | Select-Object -First 250)
        Write-JsonResponse -Response $response -StatusCode 200 -Payload $audit
        continue
      }

      if ($path -eq "/api/admin/export") {
        Require-Admin -User $currentUser
        if ($method -ne "POST") { throw "405|Method not allowed" }
        $payload = Parse-JsonBody -Request $request
        $filters = if ($payload.filters) { $payload.filters } else { @{} }
        $today = if ($payload.today) { [string]$payload.today } else { (Get-Date).ToString("yyyy-MM-dd") }
        $scope = [string]$payload.scope
        $records = @(Get-FileJson -Path $RecordsFile | Sort-Object -Property @{ Expression = { $_.date } ; Descending = $true }, @{ Expression = { $_.time } ; Descending = $true })
        $selectedMonth = if ($filters.month -and [string]$filters.month -ne "all") { [string]$filters.month } else { Get-MonthKey $today }

        $rows = switch ($scope) {
          "current_date" { @($records | Where-Object { $_.date -eq $today }) }
          "current_month" { @($records | Where-Object { (Get-MonthKey $_.date) -eq $selectedMonth }) }
          default { @(Apply-Filters -Records $records -Filters $filters) }
        }

        if ($rows.Count -eq 0) { throw "400|There are no records to export" }

        $summaryBlocks = @()
        if ($scope -eq "current_date") {
          $totals = Get-Totals -Pool $rows
          $summaryBlocks += ,(Summary-Block -Title "Current Date Totals" -Entries @(
            @("Date", (To-DisplayDate $today)),
            @("Visitor arrivals", $totals.visitorArrivals),
            @("Visitor departures", $totals.visitorDepartures),
            @("Visitors remaining", $totals.visitorsOnIsland),
            @("Event visitors on island", $totals.eventVisitorsOnIsland),
            @("Contractor arrivals", $totals.contractorArrivals),
            @("Contractor departures", $totals.contractorDepartures)
          ))
          $filename = "visitor-monitor-date-$today.csv"
        }
        elseif ($scope -eq "current_month") {
          $totals = Get-Totals -Pool $rows
          $summaryBlocks += ,(Summary-Block -Title "Monthly Totals" -Entries @(
            @("Month", $selectedMonth),
            @("Visitor arrivals", $totals.visitorArrivals),
            @("Visitor departures", $totals.visitorDepartures),
            @("Visitors remaining", $totals.visitorsOnIsland),
            @("Event visitor arrivals", $totals.eventVisitorArrivals),
            @("Event visitor departures", $totals.eventVisitorDepartures),
            @("Yacht guest arrivals", $totals.yachtGuestArrivals),
            @("Yacht guest departures", $totals.yachtGuestDepartures),
            @("F&F arrivals", $totals.fnfArrivals),
            @("F&F departures", $totals.fnfDepartures)
          ))
          $filename = "visitor-monitor-month-$selectedMonth.csv"
        }
        else {
          $currentRows = @($records | Where-Object { $_.date -eq $today })
          $monthRows = @($records | Where-Object { (Get-MonthKey $_.date) -eq $selectedMonth })
          $filteredTotals = Get-Totals -Pool $rows
          $currentTotals = Get-Totals -Pool $currentRows
          $monthTotals = Get-Totals -Pool $monthRows
          $dateFilter = if ($filters.date) { [string]$filters.date } else { "all" }
          $summaryBlocks += ,(Summary-Block -Title "Current Date Totals" -Entries @(
            @("Date", (To-DisplayDate $today)),
            @("Visitor arrivals", $currentTotals.visitorArrivals),
            @("Visitor departures", $currentTotals.visitorDepartures),
            @("Visitors remaining", $currentTotals.visitorsOnIsland)
          ))
          $summaryBlocks += ,(Summary-Block -Title "Selected Month Totals" -Entries @(
            @("Month", $selectedMonth),
            @("Visitor arrivals", $monthTotals.visitorArrivals),
            @("Visitor departures", $monthTotals.visitorDepartures),
            @("Visitors remaining", $monthTotals.visitorsOnIsland)
          ))
          $summaryBlocks += ,(Summary-Block -Title "Filtered View Totals" -Entries @(
            @("Month filter", $(if ($filters.month -and [string]$filters.month -ne "all") { [string]$filters.month } else { $selectedMonth })),
            @("Date filter", $(if ($dateFilter -eq "all") { "All Dates" } else { To-DisplayDate $dateFilter })),
            @("Visitor arrivals", $filteredTotals.visitorArrivals),
            @("Visitor departures", $filteredTotals.visitorDepartures),
            @("Visitors remaining", $filteredTotals.visitorsOnIsland)
          ))
          $filename = "visitor-monitor-visible-$today.csv"
        }

        Write-JsonResponse -Response $response -StatusCode 200 -Payload @{ filename = $filename; csv = (Build-Csv -Rows $rows -SummaryBlocks $summaryBlocks) }
        continue
      }

      Write-JsonResponse -Response $response -StatusCode 404 -Payload @{ error = "Not found" }
    }
    catch {
      $parts = $_.Exception.Message -split '\|', 2
      if ($parts.Count -eq 2 -and $parts[0] -match '^\d+$') {
        Write-JsonResponse -Response $context.Response -StatusCode ([int]$parts[0]) -Payload @{ error = $parts[1] }
      }
      else {
        Write-JsonResponse -Response $context.Response -StatusCode 500 -Payload @{ error = $_.Exception.Message }
      }
    }
  }
}
finally {
  if ($listener.IsListening) { $listener.Stop() }
}
