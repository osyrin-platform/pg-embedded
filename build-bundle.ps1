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

  # --- LGPL removal: stub out libintl, drop libiconv -------------------------
  step "Removing LGPL (stub out libintl; drop libiconv)"
  # On Windows the GNU libintl (message translation) is hard-linked by postgres/initdb/
  # pg_ctl, and GNU libiconv is pulled in ONLY by libintl (libxml2 doesn't use it here).
  # We run NLS-off (C locale), so gettext only ever returns messages untranslated -- which
  # is precisely what a no-op stub returns. Replacing libintl-9.dll with a tiny permissive
  # no-op DLL (the 7 gettext symbols the consumers import) removes BOTH LGPL libs at once,
  # with zero behaviour change. x64-only, so exported names are undecorated; /MT static-links
  # the CRT so the stub adds no vcruntime/ucrt dependency the (MinGW-built) tree lacks.
  $stub = @'
/* No-op libintl-9.dll. NLS is off locally, so these return the message untranslated --
   the existing behaviour -- and carry NO libiconv dependency. From build-bundle.ps1. */
#define API __declspec(dllexport)
API char *libintl_gettext(const char *msgid){ return (char*)msgid; }
API char *libintl_dgettext(const char *d, const char *msgid){ (void)d; return (char*)msgid; }
API char *libintl_ngettext(const char *m1, const char *m2, unsigned long n){ return (char*)(n==1?m1:m2); }
API char *libintl_dngettext(const char *d, const char *m1, const char *m2, unsigned long n){ (void)d; return (char*)(n==1?m1:m2); }
API char *libintl_textdomain(const char *d){ return (char*)(d?d:"messages"); }
API char *libintl_bindtextdomain(const char *d, const char *dir){ (void)d; return (char*)dir; }
API char *libintl_bind_textdomain_codeset(const char *d, const char *cs){ (void)d; return (char*)cs; }
'@
  Set-Content -Path "$WORK\libintl_stub.c" -Value $stub -Encoding ascii
  Push-Location $WORK
  try { cl /nologo /O2 /MT /LD libintl_stub.c /Fe:libintl-9.dll } finally { Pop-Location }
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$WORK\libintl-9.dll")) { throw "stub libintl-9.dll build failed." }
  Get-ChildItem $PGTREE -Recurse -Filter 'libintl-9.dll' | ForEach-Object { Copy-Item "$WORK\libintl-9.dll" $_.FullName -Force }

  # Recompute the runtime DLL closure now that libintl is the dependency-free stub, drop what
  # is no longer reachable (libiconv -- its only consumer was GNU libintl -- and libxml2 if
  # unused), and assert nothing GNU-LGPL remains reachable.
  $bundled = @{}
  Get-ChildItem $PGTREE -Recurse -Filter *.dll | ForEach-Object { $bundled[$_.Name.ToLower()] = $_.FullName }
  function Deps($file) {
    (dumpbin /dependents $file 2>$null) |
      Select-String -Pattern '^\s+(\S+\.dll)\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value.ToLower() }
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
  # Remove UNUSED (outside the closure) DLLs whose licences the bundle's LICENSES/ do not cover, rather than carry extra
  # attribution for code we never load: libiconv/libxml2 (dropped with libintl), plus curl (libcurl), the mingw-w64
  # runtime (libwinpthread) and wxWidgets (wxbase* — copyleft-flavoured wxWindows licence). zonky ships these on Windows
  # but nothing we run imports them. Everything still shipped is covered by the existing licence texts.
  $dropPatterns = @('libiconv-2.dll','libxml2.dll','libcurl.dll','libwinpthread-1.dll','wxbase*.dll','wxmsw*.dll')
  $removed = @()
  foreach ($f in (Get-ChildItem $PGTREE -Recurse -Include $dropPatterns)) {
    if (-not $needed.Contains($f.Name.ToLower())) { Remove-Item $f.FullName -Force; $removed += $f.Name }
  }
  Write-Host "removed (unused, uncovered): $(if ($removed) { $removed -join ', ' } else { '(none)' })"
  if ($needed.Contains('libiconv-2.dll')) { throw "libiconv still reachable after stubbing libintl." }
  if ((Deps "$PGTREE\bin\libintl-9.dll") -contains 'libiconv-2.dll') { throw "the stub libintl still imports libiconv." }
  Write-Host "LGPL-free: libintl replaced with a no-op stub; libiconv removed"

  # --- Microsoft Visual C++ runtime, app-local --------------------------------
  step "Carrying the Microsoft Visual C++ runtime beside the binaries (app-local)"
  # zonky's Windows Postgres is an MSVC build: postgres.exe, initdb.exe, pg_ctl.exe and nearly every DLL import
  # VCRUNTIME140.dll, and ICU (icuuc/icuio/icutu) imports MSVCP140.dll -- and the tree carries NEITHER. Revisions
  # 3 and 4 shipped that way, so on a Windows with no "Visual C++ Redistributable" installed the server could not
  # start at all ("VCRUNTIME140.dll was not found"), before a line of ours ran. Most machines have the
  # redistributable from other software; a clean one does not, and the smoke test below could never see it,
  # because every build runner has Visual Studio.
  #
  # Windows looks for a DLL in the folder of the EXE that is starting before it looks in System32, so the three
  # files beside the three programs (bin\) are what they load -- and what the extension DLLs under lib\ get too,
  # since they are loaded INTO postgres.exe, which already holds them. msvcp140.dll itself imports
  # vcruntime140_1.dll, which is why the third file comes along though nothing of zonky's names it.
  #
  # They are Microsoft's files, taken unmodified from this Visual Studio's own redistributable folder
  # (%VCToolsRedistDir%x64\Microsoft.VC14x.CRT -- the folder Microsoft documents for app-local deployment), under
  # the "Distributable Code" terms of the Visual Studio licence (the REDIST list names these files). The exact
  # folder and file versions are written into the bundle (LICENSES\microsoft-vc-runtime.txt).
  if (-not $env:VCToolsRedistDir) { throw "VCToolsRedistDir is not set after vcvars64: cannot locate the redistributable CRT." }
  $crtDir = Get-ChildItem (Join-Path $env:VCToolsRedistDir 'x64') -Directory -Filter 'Microsoft.VC*.CRT' |
              Sort-Object Name -Descending | Select-Object -First 1
  if (-not $crtDir) { throw "no x64\Microsoft.VC*.CRT folder under $($env:VCToolsRedistDir)." }
  $crtFiles = @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll')
  $crtNote  = @()
  foreach ($f in $crtFiles) {
    $src = Join-Path $crtDir.FullName $f
    if (-not (Test-Path $src)) { throw "the redistributable folder $($crtDir.FullName) has no $f." }
    Copy-Item $src (Join-Path $PGTREE 'bin') -Force
    $ver = (Get-Item $src).VersionInfo.FileVersion
    $sha = (Get-FileHash $src -Algorithm SHA256).Hash.ToLower()
    $crtNote += "  bin\$f   file version $ver   sha256 $sha"
    Write-Host "  $f  $ver"
  }

  # The closure again, now that the runtime is in the tree: every C/C++ runtime DLL the three programs (and
  # pgvector) reach must be one the bundle CARRIES. This is the check revisions 3 and 4 did not have -- it reads
  # the import tables, so it does not depend on what happens to be installed on the machine that builds.
  $bundled = @{}
  Get-ChildItem $PGTREE -Recurse -Filter *.dll | ForEach-Object { $bundled[$_.Name.ToLower()] = $_.FullName }
  $reach  = [System.Collections.Generic.HashSet[string]]::new()
  $queue  = [System.Collections.Generic.Queue[string]]::new()
  $absent = @()
  foreach ($r in 'bin\postgres.exe','bin\initdb.exe','bin\pg_ctl.exe','lib\vector.dll') { $queue.Enqueue((Join-Path $PGTREE $r)) }
  while ($queue.Count -gt 0) {
    $from = $queue.Dequeue()
    foreach ($d in (Deps $from)) {
      if ($bundled.ContainsKey($d)) { if ($reach.Add($d)) { $queue.Enqueue($bundled[$d]) } }
      elseif ($d -match '^(vcruntime|msvcp|concrt|vcomp|vccorlib|msvcr)\d') { $absent += "$d (imported by $(Split-Path $from -Leaf))" }
    }
  }
  if ($absent) { throw "the bundle's programs import a Visual C++ runtime DLL the bundle does not carry: $($absent -join '; ')" }
  foreach ($f in 'vcruntime140.dll','msvcp140.dll') { if (-not $reach.Contains($f)) { throw "$f was copied in but nothing in the bundle reaches it -- the runtime the programs need has changed; re-read their imports." } }
  if (-not $reach.Contains('vcruntime140_1.dll')) { Write-Host "note: nothing reaches vcruntime140_1.dll in this build (msvcp140.dll usually imports it); carried all the same." }
  foreach ($f in $crtFiles) { if (-not (Test-Path (Join-Path $PGTREE "bin\$f"))) { throw "bin\$f is missing from the tree." } }
  Write-Host "Visual C++ runtime carried app-local: $($crtFiles -join ', ') -- and nothing in the closure imports one that is not"

  # --- licences (no LGPL ships) ----------------------------------------------
  step "Baking third-party licence notices"
  New-Item -ItemType Directory -Force -Path "$PGTREE\LICENSES" | Out-Null
  Copy-Item "$PSScriptRoot\licenses\*.txt" "$PGTREE\LICENSES\"
  Copy-Item "$WORK\pgvector\LICENSE" "$PGTREE\LICENSES\pgvector.txt"
  Copy-Item "$PSScriptRoot\THIRD-PARTY-NOTICES.md" "$PGTREE\"
  Add-Content -Path "$PGTREE\LICENSES\microsoft-vc-runtime.txt" -Encoding ascii -Value (@(
    '', 'The files in this bundle, as built:', "  taken from: $($crtDir.FullName)") + $crtNote)

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
  # The server that just started must be running on the runtime THIS BUNDLE carries, not the one Visual Studio put in
  # System32 -- a runner always has that one, so "it started" proves nothing about a machine without it. Read from
  # the running process: which file each runtime DLL was loaded from.
  $binDir = (Resolve-Path (Join-Path $PGTREE 'bin')).Path
  $server = Get-Process postgres -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($binDir, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
  if (-not $server) { & "$PGTREE\bin\pg_ctl.exe" -D $DATA -w stop | Out-Null; throw "no postgres.exe of this bundle is running after pg_ctl start." }
  $loaded = @{}
  foreach ($m in $server.Modules) { $loaded[$m.ModuleName.ToLower()] = $m.FileName }
  foreach ($f in 'vcruntime140.dll','msvcp140.dll') {
    if (-not $loaded.ContainsKey($f)) { & "$PGTREE\bin\pg_ctl.exe" -D $DATA -w stop | Out-Null; throw "the running server has not loaded $f at all -- its imports are not what this script reads." }
    if (-not $loaded[$f].StartsWith($binDir, [StringComparison]::OrdinalIgnoreCase)) {
      & "$PGTREE\bin\pg_ctl.exe" -D $DATA -w stop | Out-Null
      throw "the running server loaded $f from $($loaded[$f]), not from the bundle's bin\ -- on a machine without the redistributable it would not start."
    }
  }
  Write-Host "the running server loaded vcruntime140.dll and msvcp140.dll from the bundle's own bin\"
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
  Write-Host "vector $ver loaded, inherited via template1, hnsw scan correct; builtin C.UTF-8; LGPL-free; VC++ runtime app-local"

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
