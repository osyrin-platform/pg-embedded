#!/usr/bin/env pwsh
# Build the win-x64 embedded-Postgres bundle: zonky's Windows Postgres with pgvector
# compiled in (MSVC / nmake /F Makefile.win), verified, tarred + checksummed. The unix
# platforms use build-bundle.sh (PGXS); Windows needs the MSVC path, hence this script.
#
#   pwsh build-bundle.ps1 [-OutDir dist] [-PgRoot 'C:\Program Files\PostgreSQL\17']
#
# Requires on the runner: MSVC build tools (nmake/cl/dumpbin via vcvars64), a PostgreSQL
# 17 install for headers+import-libs (-PgRoot), and tar (bsdtar, built into Windows).
#
# Any minor of the right MAJOR works: PG_MODULE_MAGIC compares PG_VERSION_NUM/100, which
# is 1700 for every 17.x — same rule the unix build relies on.
[CmdletBinding()]
param(
  [string]$OutDir = "$PSScriptRoot\dist",
  [string]$PgRoot = $env:PGROOT
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }

# --- versions.env -----------------------------------------------------------
$vers = @{}
Get-Content "$PSScriptRoot\versions.env" | ForEach-Object {
  if ($_ -match '^\s*([A-Z_]+)=(.*)$') { $vers[$Matches[1]] = $Matches[2].Trim() }
}
$PG = $vers['PG_VERSION']; $PGV = $vers['PGVECTOR_VERSION']; $REV = $vers['BUNDLE_REVISION']
$PGMAJOR = $PG.Split('.')[0]
$BUNDLE  = "osy-pg$PG-pgvector$PGV-r$REV-win-x64.tar.gz"

if (-not $PgRoot) { throw "PgRoot not set: need a PostgreSQL $PGMAJOR install for headers+libs (set -PgRoot or `$env:PGROOT)." }
if (-not (Test-Path "$PgRoot\include\server")) { throw "no include\server under PgRoot '$PgRoot'." }

$WORK = Join-Path ([IO.Path]::GetTempPath()) ("pgbuild-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $WORK | Out-Null
$PGTREE = Join-Path $WORK 'pgroot'

try {
  # --- import the MSVC (vcvars64) environment ONCE, so nmake/cl/dumpbin are on PATH ----
  step "Setting up the MSVC build environment"
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path $vswhere)) { throw "vswhere not found; MSVC build tools required." }
  $vsPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
  $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
  if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found under $vsPath." }
  cmd /c "call `"$vcvars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
  }
  if (-not (Get-Command nmake -ErrorAction SilentlyContinue)) { throw "nmake not on PATH after vcvars." }

  # --- fetch zonky Postgres ---------------------------------------------------
  step "Fetching zonky Postgres $PG (windows-amd64)"
  $jar = "embedded-postgres-binaries-windows-amd64-$PG.jar"
  Invoke-WebRequest -Uri "https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-windows-amd64/$PG/$jar" -OutFile "$WORK\pg.jar"
  Expand-Archive -Path "$WORK\pg.jar" -DestinationPath "$WORK\jar" -Force   # a .jar is a .zip
  $txz = Get-ChildItem "$WORK\jar" -Filter *.txz | Select-Object -First 1
  if (-not $txz) { throw "no .txz inside $jar." }
  New-Item -ItemType Directory -Force -Path $PGTREE | Out-Null
  tar -xf $txz.FullName -C $PGTREE          # bsdtar handles .txz
  foreach ($d in 'bin\postgres.exe','bin\initdb.exe','bin\pg_ctl.exe','lib','share\extension') {
    if (-not (Test-Path (Join-Path $PGTREE $d))) { throw "unexpected zonky layout: missing $d." }
  }

  # --- build pgvector (nmake) -------------------------------------------------
  step "Building pgvector $PGV (nmake /F Makefile.win) against $PgRoot"
  git -c advice.detachedHead=false clone -q --branch "v$PGV" --depth 1 https://github.com/pgvector/pgvector.git "$WORK\pgvector"
  $env:PGROOT = $PgRoot
  Push-Location "$WORK\pgvector"
  try { nmake /F Makefile.win } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) { throw "nmake failed ($LASTEXITCODE)." }
  if (-not (Test-Path "$WORK\pgvector\vector.dll")) { throw "pgvector did not produce vector.dll." }

  step "Installing pgvector into the Postgres tree"
  Copy-Item "$WORK\pgvector\vector.dll"        "$PGTREE\lib\"
  Copy-Item "$WORK\pgvector\vector.control"    "$PGTREE\share\extension\"
  Copy-Item "$WORK\pgvector\sql\vector--*.sql" "$PGTREE\share\extension\"

  # --- LGPL elimination (data-driven) ----------------------------------------
  step "Eliminating the LGPL libraries (data-driven via dumpbin)"
  # The GNU libiconv/libintl are the only LGPL components. We use no PG XML
  # (libxml2 -> libiconv) and no NLS (libintl), so they should never load. Prove it:
  # compute the transitive DLL closure actually reachable from the executables we run
  # (postgres/initdb/pg_ctl) plus vector.dll (the only extension we load). Anything
  # outside that closure is never mapped and is safe to delete. STRICT: if an LGPL lib
  # IS reachable, fail -- don't silently ship copyleft; swap in MIT win-iconv instead.
  $bundled = @{}
  Get-ChildItem $PGTREE -Recurse -Filter *.dll | ForEach-Object { $bundled[$_.Name.ToLower()] = $_.FullName }
  function Deps($file) {
    (dumpbin /dependents $file 2>$null) |
      Select-String -Pattern '^\s+(\S+\.dll)\s*$' |
      ForEach-Object { $_.Matches[0].Groups[1].Value.ToLower() }
  }
  $needed = [System.Collections.Generic.HashSet[string]]::new()
  $queue  = [System.Collections.Generic.Queue[string]]::new()
  foreach ($r in 'bin\postgres.exe','bin\initdb.exe','bin\pg_ctl.exe','lib\vector.dll') { $queue.Enqueue((Join-Path $PGTREE $r)) }
  while ($queue.Count -gt 0) {
    foreach ($d in (Deps $queue.Dequeue())) {
      if ($bundled.ContainsKey($d) -and $needed.Add($d)) { $queue.Enqueue($bundled[$d]) }
    }
  }
  Write-Host "runtime DLL closure ($($needed.Count) of $($bundled.Count)): $(( $needed | Sort-Object ) -join ', ')"
  $lgpl = @('libiconv-2.dll','libintl-9.dll')
  $stillLgpl = $lgpl | Where-Object { $needed.Contains($_) }
  if ($stillLgpl) {
    # Diagnostic: who DIRECTLY imports each still-reachable LGPL lib (across every exe/dll
    # in the tree), so we know exactly what to swap (win-iconv / proxy-libintl).
    $allPe = @()
    $allPe += (Get-ChildItem $PGTREE -Recurse -Include *.exe,*.dll)
    foreach ($lg in $stillLgpl) {
      $importers = $allPe | Where-Object { (Deps $_.FullName) -contains $lg } | ForEach-Object { $_.Name }
      Write-Host "  $lg  <-  directly imported by: $(($importers | Sort-Object -Unique) -join ', ')"
    }
    throw "LGPL lib(s) still reachable at runtime: $($stillLgpl -join ', '). Swap for permissive equivalents (win-iconv / proxy-libintl) rather than ship copyleft."
  }
  # Delete the LGPL libs (unreachable) plus libxml2 if it too is unreachable (its only
  # consumer is XML, which we never use) -- keep the tree honest, not just licence-clean.
  $removed = @()
  foreach ($n in @($lgpl + 'libxml2.dll')) {
    if ($bundled.ContainsKey($n) -and -not $needed.Contains($n)) { Remove-Item $bundled[$n] -Force; $removed += $n }
  }
  Write-Host "removed (unreachable): $(if ($removed) { $removed -join ', ' } else { '(none)' })"

  # --- licences (no LGPL ships) ----------------------------------------------
  step "Baking third-party licence notices"
  New-Item -ItemType Directory -Force -Path "$PGTREE\LICENSES" | Out-Null
  Copy-Item "$PSScriptRoot\licenses\*.txt" "$PGTREE\LICENSES\"
  Copy-Item "$WORK\pgvector\LICENSE" "$PGTREE\LICENSES\pgvector.txt"
  Copy-Item "$PSScriptRoot\THIRD-PARTY-NOTICES.md" "$PGTREE\"

  # --- smoke test -------------------------------------------------------------
  step "Smoke test: the bundle's OWN server must load the extension"
  $DATA = Join-Path $WORK 'data'
  $PORT = 55000 + (Get-Random -Maximum 2000)
  $psql = Join-Path $PgRoot 'bin\psql.exe'
  if (-not (Test-Path $psql)) { throw "no psql at $psql." }
  & "$PGTREE\bin\initdb.exe" -D $DATA -U postgres -A trust -E UTF8 `
      --locale-provider=builtin --builtin-locale=C.UTF-8 --lc-collate=C --lc-ctype=C | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "initdb failed." }
  & "$PGTREE\bin\pg_ctl.exe" -D $DATA -w -l "$WORK\pg.log" -o "-p $PORT -h 127.0.0.1" start
  if ($LASTEXITCODE -ne 0) { if (Test-Path "$WORK\pg.log") { Get-Content "$WORK\pg.log" }; throw "server failed to start." }
  function q($db,$sql){ (& $psql -h 127.0.0.1 -p $PORT -U postgres -d $db -v ON_ERROR_STOP=1 -tAc $sql).Trim() }
  try {
    q template1 "CREATE EXTENSION vector;" | Out-Null    # into template1 so clones inherit it
    q postgres  "CREATE DATABASE smoke;"   | Out-Null
    q smoke "CREATE TABLE t(id int, e vector(3)); INSERT INTO t VALUES (1,'[1,2,3]'),(2,'[4,5,6]'); CREATE INDEX ON t USING hnsw (e vector_cosine_ops);" | Out-Null
    $got = q smoke "SELECT id FROM t ORDER BY e <=> '[1,2,3]' LIMIT 1;"
    $ver = q smoke "SELECT extversion FROM pg_extension WHERE extname='vector';"
    $loc = q smoke "select datlocprovider::text||' '||datlocale from pg_database where datname='smoke';"
    $srt = q smoke "select string_agg(w,' ' order by w) from (values ('a'),('B'),('b'),('A')) v(w);"
  } finally {
    & "$PGTREE\bin\pg_ctl.exe" -D $DATA -w stop | Out-Null
  }
  if ($got -ne '1')          { throw "hnsw nearest-neighbour returned '$got', expected '1'." }
  if ($ver -ne $PGV)         { throw "pg_extension says '$ver', expected '$PGV'." }
  if ($loc -ne 'b C.UTF-8')  { throw "locale is '$loc', expected 'b C.UTF-8' (builtin provider)." }
  if ($srt -ne 'A B a b')    { throw "sort order is '$srt', expected code-point order 'A B a b'." }
  Write-Host "vector $ver loaded, inherited via template1, hnsw scan correct; builtin C.UTF-8; LGPL-free"

  # --- pack -------------------------------------------------------------------
  step "Packing"
  Remove-Item -Recurse -Force $DATA
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $tarball = Join-Path $OutDir $BUNDLE
  tar -czf $tarball -C $PGTREE .
  $sha = (Get-FileHash $tarball -Algorithm SHA256).Hash.ToLower()
  Set-Content -NoNewline -Path "$tarball.sha256" -Value "$sha  $BUNDLE"
  Write-Host "`n  $tarball"
  Write-Host "  $sha"
}
finally {
  Remove-Item -Recurse -Force $WORK -ErrorAction SilentlyContinue
}
