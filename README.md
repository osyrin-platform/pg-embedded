# pg-embedded

Prebuilt, self-contained **PostgreSQL 17 + [pgvector](https://github.com/pgvector/pgvector)** bundles: one tarball per
platform, containing a real PostgreSQL server you can start from a directory, with the `vector` extension already
installed.

They exist so a development tool can bring up a genuine PostgreSQL — vectors, HNSW indexes and all — with **no Docker,
no package manager, and no system PostgreSQL**. Download once, run offline thereafter.

## Using a bundle

Grab a release asset and its `.sha256`, verify, extract:

```bash
TAG=pg17.10.0-pgvector0.8.0-r1
BUNDLE=osy-$TAG-linux-x64.tar.gz

curl -sSfLO https://github.com/osyrin-platform/pg-embedded/releases/download/$TAG/$BUNDLE
curl -sSfLO https://github.com/osyrin-platform/pg-embedded/releases/download/$TAG/$BUNDLE.sha256
sha256sum -c $BUNDLE.sha256

mkdir pg && tar -xzf $BUNDLE -C pg
```

Then start it. Two flags are not optional:

```bash
pg/bin/initdb -D data -U postgres -A trust -E UTF8 \
  --locale-provider=builtin --builtin-locale=C.UTF-8 \
  --lc-collate=C --lc-ctype=C
pg/bin/pg_ctl -D data -o "-p 5599 -h 127.0.0.1 -c unix_socket_directories=" -w start
```

The **builtin** locale provider (new in PostgreSQL 17) implements `C.UTF-8` inside the server, so collation *and*
character classification depend on neither the host's libc locales nor the bundled ICU. Sort order and `upper()` are then
identical on every platform.

`--lc-collate`/`--lc-ctype` are inert under this provider — `datlocale` governs — but `initdb` still validates them
against libc and would otherwise inherit your `LANG`. Pin them to `C`, which exists everywhere; `C.UTF-8` is *not* a
libc locale on macOS 14 and earlier.

`unix_socket_directories=` forces TCP-only. Postgres caps a Unix socket path at **103 bytes**, and an ordinary project
directory will exceed it — the server then refuses to start with a message that does not obviously point at path length.

Install the extension into `template1` once, and every database created afterwards inherits it, including databases made
with `CREATE DATABASE … WITH TEMPLATE`:

```bash
psql -h 127.0.0.1 -p 5599 -U postgres -d template1 -c 'CREATE EXTENSION vector;'
```

**Verify the digest before you extract.** You are about to execute binaries out of this archive.

## What is in a bundle

```
bin/     initdb, pg_ctl, postgres        <- that is all; see below
lib/     server libraries + lib/postgresql/vector.{so,dylib}
share/   share/postgresql/extension/vector*
LICENSES/
THIRD-PARTY-NOTICES.md
```

| Platform | Asset | Notes |
|---|---|---|
| macOS (Apple Silicon **and** Intel) | `osx-universal` | One universal binary serves both |
| Linux x86-64 | `linux-x64` | |
| Linux arm64 | `linux-arm64` | |

## Things worth knowing

**`bin/` contains only `initdb`, `pg_ctl` and `postgres`.** There is no `psql`, and no `pg_dump` or `pg_restore` — so a
bundle cannot back up or restore a database. That is a property of these binaries, not an oversight.

**`select version()` misreports the architecture on Apple Silicon.** It prints `x86_64-apple-darwin` because the
compile-time triple is baked into both slices of a universal binary. The server really is running arm64. Never infer the
running architecture from it.

**ICU major versions differ across platforms** (60 on Linux, 68 on macOS), and collation ordering can shift between ICU
majors. Prefer the builtin provider above; reach for `--locale-provider=icu` only if you need real dictionary collation,
and then pin the ICU locale explicitly.

## Building

```bash
./build-bundle.sh osx-universal      # also: linux-x64, linux-arm64
```

Needs `curl`, `tar`, `make`, a C compiler, and PostgreSQL **server headers of the same major version** (Homebrew
`postgresql@17`, apt `postgresql-server-dev-17`). The bundled binaries carry no `pg_config` and no `include/`, so
pgvector cannot be built against the tree that ships — it is compiled against separately-obtained headers of that major
and dropped in. That is safe because PostgreSQL's module ABI check compares `PG_VERSION_NUM / 100`, which is identical
for every release within a major.

The script **refuses to pack a bundle it could not load**: before creating the tarball it starts the bundle's own
server, runs `CREATE EXTENSION vector`, asserts an HNSW nearest-neighbour scan returns the expected row, and asserts the
database really came up as builtin `C.UTF-8`.

Versions are pinned in `versions.env`. Releases are cut by `.github/workflows/build.yml`; bump `BUNDLE_REVISION` to
republish, since the publish step refuses to overwrite an existing tag.

Tarballs are **not bit-reproducible** (`tar.gz` records mtimes), so take a digest from a published asset, never from a
local rebuild.

### Not yet built: `win-x64`

pgvector on Windows requires an MSVC `nmake` build rather than the PGXS path the other platforms share.
`./build-bundle.sh win-x64` exits with a pointer here rather than producing an untested artifact.

## Licensing

The build scripts in this repository are MIT-licensed (`LICENSE`).

The **bundles** redistribute PostgreSQL, pgvector, OpenSSL, ICU and several other libraries as binaries. Each bundle
carries the full licence text of every component in `LICENSES/`, and `THIRD-PARTY-NOTICES.md` maps component → licence →
upstream source. **No bundle redistributes any LGPL-licensed code**: the macOS tree's GNU `libintl` (unused) and
`libiconv` are removed at build time — `libxml2` is repointed to macOS's own `/usr/lib/libiconv.2.dylib` — and the Linux
trees link glibc's iconv/gettext and never shipped them.

PostgreSQL binaries are repackaged from
[zonky-io/embedded-postgres-binaries](https://github.com/zonkyio/embedded-postgres-binaries), unmodified except for that
macOS LGPL-removal relink. This project is not affiliated with the PostgreSQL Global Development Group.
