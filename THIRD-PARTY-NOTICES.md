# Third-party notices

This bundle redistributes PostgreSQL and its dependencies as **binaries**, together with the pgvector extension. The
full licence text of every component is in the `LICENSES/` directory beside this file.

The PostgreSQL binaries are repackaged, unmodified, from
[zonky-io/embedded-postgres-binaries](https://github.com/zonkyio/embedded-postgres-binaries). The only thing this bundle
adds is the pgvector extension, compiled against PostgreSQL 16 server headers.

Every bundle carries the **union** of these notices, not a per-platform subset. Shipping one licence text too many is
harmless; omitting one is a compliance bug. The "Platforms" column records where each component actually appears.

| Component | Licence | `LICENSES/` | Platforms | Upstream |
|---|---|---|---|---|
| PostgreSQL (server, contrib, libpq, libecpg, libpgtypes) | PostgreSQL Licence | `postgresql.txt` | all | <https://www.postgresql.org/> |
| pgvector | PostgreSQL Licence | `pgvector.txt` | all | <https://github.com/pgvector/pgvector> |
| OpenSSL 3 (`libssl`, `libcrypto`) | Apache-2.0 | `openssl.txt` | all | <https://www.openssl.org/> |
| ICU (`libicuuc`, `libicui18n`, `libicudata`) | Unicode/ICU | `icu-60.txt`, `icu-68.txt` | all (60 on Linux, 68 on macOS) | <https://icu.unicode.org/> |
| libxml2 | MIT | `libxml2.txt` | all | <https://gitlab.gnome.org/GNOME/libxml2> |
| zlib | zlib | `zlib.txt` | all | <https://zlib.net/> |
| libxslt | MIT | `libxslt.txt` | Linux | <https://gitlab.gnome.org/GNOME/libxslt> |
| xz / liblzma | 0BSD | `xz-liblzma.txt` | Linux | <https://tukaani.org/xz/> |
| OSSP uuid | MIT-style | `ossp-uuid.txt` | Linux | <http://www.ossp.org/pkg/lib/uuid/> |
| zstd | BSD-3-Clause | `zstd.txt` | macOS | <https://github.com/facebook/zstd> |
| lz4 | BSD-2-Clause | `lz4.txt` | macOS | <https://github.com/lz4/lz4> |
| libedit | BSD-3-Clause | `libedit.txt` | macOS | <https://www.thrysoee.dk/editline/> |
| MIT Kerberos (`krb5`, `gssapi_krb5`, `com_err`, `k5crypto`, `krb5support`) | MIT | `krb5.txt` | macOS | <https://web.mit.edu/kerberos/> |
| util-linux `libuuid` | BSD-3-Clause | `libuuid-bsd3.txt` | macOS | <https://github.com/util-linux/util-linux> |
| GNU libiconv | **LGPL-2.1-or-later** | `lgpl-2.1.txt` | macOS | <https://www.gnu.org/software/libiconv/> |
| GNU gettext runtime (`libintl`) | **LGPL-2.1-or-later** | `lgpl-2.1.txt` | macOS | <https://www.gnu.org/software/gettext/> |

## A note on the LGPL components

`libiconv` and `libintl` are covered by the GNU Lesser General Public License, version 2.1 or later. They are
redistributed here **unmodified**, as **separate dynamically-linked shared libraries** (`libiconv.2.dylib`,
`libintl.8.dylib`) rather than statically linked into any executable.

A recipient may therefore replace either library with a modified version by substituting the file in `lib/`, which is
the relinking freedom the LGPL exists to protect. Complete corresponding source for both libraries is available from the
upstream projects linked above; the specific builds are those produced by the zonky project, whose build definition is
public at the repository linked at the top of this file.
