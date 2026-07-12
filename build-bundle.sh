#!/usr/bin/env bash
#
# Build one embedded-Postgres bundle: zonky's stripped Postgres tree with pgvector
# compiled into it, tarred and checksummed.
#
#   ./build-bundle.sh <rid> [outdir]
#
# rid: osx-universal | linux-x64 | linux-arm64
#
# The bundle is downloaded once by a consumer and then run offline. Because the consumer
# executes binaries out of it, this script prints the tarball's SHA-256; consumers are
# expected to pin that digest and verify it after download.
#
# Requires: curl, tar, make, a C compiler, and PostgreSQL server headers of the SAME
# MAJOR version as PG_VERSION (pg_config).
# Override header discovery with PG_CONFIG=/path/to/pg_config.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$HERE/versions.env"

PG_MAJOR="${PG_VERSION%%.*}"

RID="${1:-}"
OUTDIR="${2:-$HERE/dist}"
[ -n "$RID" ] || { echo "usage: $0 <osx-universal|linux-x64|linux-arm64> [outdir]" >&2; exit 2; }

case "$RID" in
  osx-universal) ZONKY_PLATFORM=darwin;  ZONKY_ARCH=arm64v8; MODULE=vector.dylib ;;
  linux-x64)     ZONKY_PLATFORM=linux;   ZONKY_ARCH=amd64;   MODULE=vector.so ;;
  linux-arm64)   ZONKY_PLATFORM=linux;   ZONKY_ARCH=arm64v8; MODULE=vector.so ;;
  win-x64)
    echo "win-x64 is not built yet — pgvector needs an MSVC (nmake) build." >&2
    echo "See README.md -> 'Not yet built: win-x64'." >&2
    exit 3 ;;
  *) echo "unknown rid: $RID" >&2; exit 2 ;;
esac

# Postgres refuses to run as root, and this script smoke-tests the server it just built.
if [ "$(id -u)" = "0" ]; then
  echo "refusing to run as root: initdb/postgres will not start as uid 0." >&2
  echo "run as a normal user (e.g. docker run --user \$(id -u))." >&2
  exit 4
fi

TAG="pg${PG_VERSION}-pgvector${PGVECTOR_VERSION}-r${BUNDLE_REVISION}"
BUNDLE="osy-${TAG}-${RID}.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PGROOT="$WORK/pgroot"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
step "Fetching zonky Postgres ${PG_VERSION} (${ZONKY_PLATFORM}-${ZONKY_ARCH})"

JAR="embedded-postgres-binaries-${ZONKY_PLATFORM}-${ZONKY_ARCH}-${PG_VERSION}.jar"
URL="https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-${ZONKY_PLATFORM}-${ZONKY_ARCH}/${PG_VERSION}/${JAR}"
curl -sSfL -o "$WORK/pg.jar" "$URL"

mkdir -p "$WORK/jar" "$PGROOT"
( cd "$WORK/jar" && unzip -oq "$WORK/pg.jar" )
TXZ="$(find "$WORK/jar" -name '*.txz' | head -1)"
[ -n "$TXZ" ] || { echo "no .txz inside $JAR" >&2; exit 1; }
tar -xJf "$TXZ" -C "$PGROOT"

# The zonky tree ships only initdb/pg_ctl/postgres — no pg_config, no include/.
# That is why pgvector must be built against headers obtained separately.
for d in bin/postgres lib/postgresql share/postgresql/extension; do
  [ -e "$PGROOT/$d" ] || { echo "unexpected zonky layout: missing $d" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
step "Locating PostgreSQL ${PG_MAJOR} server headers"

if [ -z "${PG_CONFIG:-}" ]; then
  for c in \
    "/opt/homebrew/opt/postgresql@${PG_MAJOR}/bin/pg_config" \
    "/usr/local/opt/postgresql@${PG_MAJOR}/bin/pg_config" \
    "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config" \
    "$(command -v pg_config 2>/dev/null || true)"
  do
    [ -x "$c" ] && { PG_CONFIG="$c"; break; }
  done
fi
[ -n "${PG_CONFIG:-}" ] && [ -x "$PG_CONFIG" ] || { echo "no pg_config found; set PG_CONFIG=" >&2; exit 1; }

# Any minor of the right major works: PG_MODULE_MAGIC compares PG_VERSION_NUM / 100,
# which is identical across every 17.x (or 16.x) release.
HDR_VER="$("$PG_CONFIG" --version)"
case "$HDR_VER" in
  *" ${PG_MAJOR}."*) ;;
  *) echo "pg_config is '$HDR_VER'; PostgreSQL ${PG_MAJOR} headers required." >&2; exit 1 ;;
esac
echo "headers: $HDR_VER  ($PG_CONFIG)"
echo "server:  ${PG_VERSION} (zonky)"

# ---------------------------------------------------------------------------
step "Building pgvector ${PGVECTOR_VERSION}"

git -c advice.detachedHead=false clone -q --branch "v${PGVECTOR_VERSION}" --depth 1 \
  https://github.com/pgvector/pgvector.git "$WORK/pgvector"

# OPTFLAGS="" is mandatory: pgvector defaults to -march=native, which would bake this
# build machine's ISA into a binary that runs on other people's CPUs. Nothing at
# runtime or in any test would catch that — it surfaces as SIGILL on a user's laptop.
#
# with_llvm=no because the Postgres we ship has no JIT provider (there is no
# llvmjit.so in the tree), so the LLVM bitcode PGXS would emit could never be loaded,
# and we install none of it. Debian/Ubuntu's server headers are configured
# with_llvm=yes and would demand a clang that need not exist on the build machine.
MAKE_ARGS=(PG_CONFIG="$PG_CONFIG" OPTFLAGS="" with_llvm=no)

if [ "$RID" = "osx-universal" ]; then
  # PGXS links modules with `-bundle_loader $(bindir)/postgres`. Homebrew's postgres is
  # arm64-only, so the x86_64 slice would fail to link. zonky's own postgres is a
  # universal binary — and is the exact executable this module gets loaded into.
  MAKE_ARGS+=(COPT="-arch arm64 -arch x86_64" BE_DLLLIBS="-bundle_loader $PGROOT/bin/postgres")
fi

make -s -C "$WORK/pgvector" "${MAKE_ARGS[@]}"
[ -f "$WORK/pgvector/$MODULE" ] || { echo "pgvector did not produce $MODULE" >&2; exit 1; }

if [ "$RID" = "osx-universal" ]; then
  archs="$(lipo -archs "$WORK/pgvector/$MODULE")"
  [ "$archs" = "x86_64 arm64" ] || [ "$archs" = "arm64 x86_64" ] \
    || { echo "expected a universal module, got: $archs" >&2; exit 1; }
  echo "module archs: $archs"
fi

# ---------------------------------------------------------------------------
step "Installing pgvector into the Postgres tree"

# SHAREDIR is share/postgresql, PKGLIBDIR is lib/postgresql — not the share/extension
# layout a stock source build produces.
cp "$WORK/pgvector/$MODULE"            "$PGROOT/lib/postgresql/"
cp "$WORK/pgvector/vector.control"     "$PGROOT/share/postgresql/extension/"
cp "$WORK/pgvector"/sql/vector--*.sql  "$PGROOT/share/postgresql/extension/"

# ---------------------------------------------------------------------------
step "Removing the LGPL libraries (macOS)"

# The only LGPL-2.1 components in any bundle are macOS's bundled GNU libintl and libiconv;
# the Linux trees link glibc's gettext/iconv and ship neither (verified). Dropping them
# removes the product's sole copyleft obligation entirely -- and needs NO Postgres rebuild:
#   - libintl is linked by nothing in the tree (verified with otool), i.e. dead weight.
#   - libiconv is used only by libxml2, via a relocatable @loader_path path; macOS ships an
#     ABI-compatible /usr/lib/libiconv.2.dylib, so we repoint libxml2 at the system copy.
# install_name_tool invalidates the signature and arm64 dylibs must be signed to load, so
# each edited dylib is re-signed ad-hoc. The smoke test below then parses XML -- including a
# non-UTF-8 document, which forces libxml2 through iconv -- against the system library, so a
# break here fails the build rather than a user's laptop.
if [ "$RID" = "osx-universal" ]; then
  rm -f "$PGROOT/lib/libintl.8.dylib"
  for f in "$PGROOT"/lib/*.dylib "$PGROOT"/lib/postgresql/*.dylib; do
    [ -f "$f" ] || continue
    if otool -L "$f" | grep -q '@loader_path/../lib/libiconv.2.dylib'; then
      install_name_tool -change @loader_path/../lib/libiconv.2.dylib /usr/lib/libiconv.2.dylib "$f"
      codesign -f -s - "$f"
    fi
  done
  rm -f "$PGROOT/lib/libiconv.2.dylib"

  # Nothing may still reference libintl (that would mean it was NOT dead weight), and every
  # remaining libiconv reference must be the SYSTEM one -- no bundled copy left dangling.
  refs="$(find "$PGROOT/bin" "$PGROOT/lib" -type f -exec otool -L {} + 2>/dev/null)"
  if grep -q 'libintl' <<<"$refs"; then
    echo "libintl is still referenced after removal -- it was not unused; do not ship." >&2; exit 1
  fi
  if grep 'libiconv' <<<"$refs" | grep -qv '/usr/lib/libiconv'; then
    echo "a bundled libiconv reference remains -- do not ship." >&2; exit 1
  fi
  echo "libintl deleted; libxml2 -> /usr/lib/libiconv.2.dylib; bundled libiconv deleted"
fi

# ---------------------------------------------------------------------------
step "Baking third-party licence notices into the bundle"

# We redistribute PostgreSQL, OpenSSL, ICU and friends as binaries. zonky's tree carries
# no licence text of its own, so the obligation to retain copyright notices is ours to
# meet. Every bundle gets the union of the texts, not a per-platform subset: shipping one
# licence too many is harmless, omitting one is a compliance bug. (No LGPL text ships any
# more -- the two LGPL libs were removed from the macOS tree above, and Linux never had
# them.)
mkdir -p "$PGROOT/LICENSES"
cp "$HERE/licenses/"*.txt "$PGROOT/LICENSES/"
cp "$WORK/pgvector/LICENSE" "$PGROOT/LICENSES/pgvector.txt"   # version-accurate, from the source we just built
cp "$HERE/THIRD-PARTY-NOTICES.md" "$PGROOT/"

for required in postgresql.txt pgvector.txt openssl.txt; do
  [ -s "$PGROOT/LICENSES/$required" ] || { echo "missing licence text: $required" >&2; exit 1; }
done
echo "$(ls "$PGROOT/LICENSES" | wc -l | tr -d ' ') licence texts + THIRD-PARTY-NOTICES.md"

# ---------------------------------------------------------------------------
step "Smoke test: the bundle's OWN server must load the extension"

DATA="$WORK/data"
PORT=$(( 55000 + (RANDOM % 2000) ))
PSQL="${PSQL:-$("$PG_CONFIG" --bindir)/psql}"
[ -x "$PSQL" ] || { echo "no psql at $PSQL; set PSQL=" >&2; exit 1; }

# The builtin locale provider (PostgreSQL 17+) implements C.UTF-8 inside the server,
# with no dependence on the host's libc locales or on the bundled ICU major -- which
# differs across platforms. This is byte-for-byte the configuration the hosted platform
# runs, so a database created here sorts exactly as it does in production.
# Under the builtin provider, datlocale governs BOTH collation and ctype; lc_collate and
# lc_ctype are inert metadata. Pin them to C anyway, so initdb cannot inherit the build
# machine's LANG -- and to C rather than C.UTF-8 because initdb validates these against
# libc, and macOS 14 has no C.UTF-8 libc locale (macOS 15+ does; the runner does not).
# Verified against production: identical sort order, upper(), lower() and initcap().
"$PGROOT/bin/initdb" -D "$DATA" -U postgres -A trust -E UTF8 \
  --locale-provider=builtin --builtin-locale=C.UTF-8 \
  --lc-collate=C --lc-ctype=C >/dev/null

# unix_socket_directories='' is not incidental: socket paths are capped at 103 bytes
# and a normal project path blows past it. The bundle is TCP-loopback only.
"$PGROOT/bin/pg_ctl" -D "$DATA" -w -l "$WORK/pg.log" \
  -o "-p $PORT -h 127.0.0.1 -c unix_socket_directories=" start >/dev/null \
  || { echo "server failed to start:" >&2; cat "$WORK/pg.log" >&2; exit 1; }

q() { "$PSQL" -h 127.0.0.1 -p "$PORT" -U postgres -d "$1" -v ON_ERROR_STOP=1 -tAc "$2"; }

# Into template1, so every database the platform later creates inherits it — including
# CopyDatabaseAsync's `CREATE DATABASE ... WITH TEMPLATE`.
q template1 "CREATE EXTENSION vector;" >/dev/null
q postgres  "CREATE DATABASE smoke;"   >/dev/null

q smoke "
  CREATE TABLE t(id int, e vector(3));
  INSERT INTO t VALUES (1,'[1,2,3]'),(2,'[4,5,6]');
  CREATE INDEX ON t USING hnsw (e vector_cosine_ops);" >/dev/null

got="$(q smoke "SELECT id FROM t ORDER BY e <=> '[1,2,3]' LIMIT 1;")"
ver="$(q smoke "SELECT extversion FROM pg_extension WHERE extname='vector';")"

# Assert the collation the hosted platform actually uses, not merely that the server
# started. A local database that sorts differently from production is the one defect
# that would discredit a local-dev runtime.
# datlocprovider is "char"; `"char" || text` is ambiguous in PG17 -- cast it.
loc="$(q smoke "select datlocprovider::text||' '||datlocale from pg_database where datname='smoke';")"

# And assert the OUTCOME, not the metadata. C.UTF-8 sorts by code point, so uppercase
# precedes lowercase; a dictionary collation would return 'a A b B'. upper() proves the
# builtin locale supplies full Unicode ctype despite lc_ctype=C.
srt="$(q smoke "select string_agg(w,' ' order by w) from (values ('a'),('B'),('b'),('A')) v(w);")"
ctype="$(q smoke "select upper('é');")"

# XML must work: libxml2 has to load (proving its libiconv symbols resolve -- against the
# SYSTEM libiconv on macOS after the relink above) and convert charsets. xmlx exercises the
# load + an xpath; xmliso parses a non-UTF-8-declared document, forcing the iconv path.
xmlx="$(q smoke "select (xpath('/a/text()','<a>ok</a>'::xml))[1]::text;")"
xmliso="$(q smoke "select xml_is_well_formed(convert_from(decode('3c3f786d6c2076657273696f6e3d22312e302220656e636f64696e673d2249534f2d383835392d31223f3e3c613ee93c2f613e','hex'),'LATIN1'));")"

"$PGROOT/bin/pg_ctl" -D "$DATA" -w stop >/dev/null

[ "$got" = "1" ] || { echo "hnsw nearest-neighbour returned '$got', expected '1'" >&2; exit 1; }
[ "$ver" = "$PGVECTOR_VERSION" ] || { echo "pg_extension says '$ver', expected '$PGVECTOR_VERSION'" >&2; exit 1; }
[ "$loc" = "b C.UTF-8" ] || { echo "locale is '$loc', expected 'b C.UTF-8' (builtin provider)" >&2; exit 1; }
[ "$srt" = "A B a b" ] || { echo "sort order is '$srt', expected code-point order 'A B a b'" >&2; exit 1; }
[ "$ctype" = "É" ] || { echo "upper('é') is '$ctype', expected 'É' (Unicode ctype)" >&2; exit 1; }
[ "$xmlx" = "ok" ] || { echo "xpath returned '$xmlx', expected 'ok' — libxml2 failed to load/run" >&2; exit 1; }
[ "$xmliso" = "t" ] || { echo "non-UTF-8 XML parse returned '$xmliso', expected 't' — libxml2/iconv broken" >&2; exit 1; }
echo "vector $ver loaded, inherited via template1, hnsw scan correct"
echo "collation: builtin C.UTF-8 — code-point sort, Unicode ctype; matches the hosted platform"
echo "libxml2 loads + parses (incl. non-UTF-8 → iconv); on macOS via the system libiconv"

# ---------------------------------------------------------------------------
step "Packing"

rm -rf "$DATA"
mkdir -p "$OUTDIR"
tar -czf "$OUTDIR/$BUNDLE" -C "$PGROOT" .

if command -v sha256sum >/dev/null; then
  ( cd "$OUTDIR" && sha256sum "$BUNDLE" > "$BUNDLE.sha256" )
else
  ( cd "$OUTDIR" && shasum -a 256 "$BUNDLE" > "$BUNDLE.sha256" )
fi

echo
echo "  $OUTDIR/$BUNDLE"
echo "  $(du -h "$OUTDIR/$BUNDLE" | cut -f1)  $(cut -d' ' -f1 < "$OUTDIR/$BUNDLE.sha256")"
