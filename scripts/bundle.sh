#!/usr/bin/env bash
#
# bundle.sh: build the self-contained "bundle" release asset.
#
# The static_* zips ship libwebp as separate archives (libwebp, libwebpdecoder, libwebpdemux, libwebpmux,
# libsharpyuv). Programs that also statically link another copy of libwebp (e.g. a full FFmpeg build, which bundles
# its own libwebp and libsharpyuv) end up with two definitions of the same symbols: either a duplicate-symbol error
# or, worse, the linker silently mixing code from two different versions.
#
# This script merges libwebp and the libraries it actually needs into ONE static library in which EVERY symbol is
# renamed with a unique prefix (WebPDecode -> webprs_WebPDecode), so it can never collide with another copy of the
# same library, whatever its version. Unlike libheif or libavif, libwebp's public API is renamed too: FFmpeg links
# libwebp itself, so WebP* collides as much as the internals do. It then verifies the result and zips it:
#
#   bundle_<os>_<arch>.zip
#   ├── include/...    libwebp's public headers (same layout as the static zip) + README about the prefix
#   └── lib/libwebp.a  (webp.lib with MSVC) libwebp + libwebpdemux + libwebpmux + libsharpyuv, every symbol prefixed
#
# It runs under bash on every platform: macOS, Linux, MSYS2 (MinGW) and Git Bash (MSVC). Only LLVM tools are used to
# read and rewrite objects, so the logic is the same everywhere; the platform only picks the archiver and the
# compiler used for the link tests:
#
#   os       objects  merge                    link tests
#   osx      Mach-O   libtool -static          cc / c++ (Apple clang)
#   linux    ELF      llvm-ar -M (MRI script)  cc / c++
#   mingw    COFF     llvm-ar -M (MRI script)  gcc / g++ of the MSYS2 environment
#   windows  COFF     llvm-lib                 clang-cl + lld-link (system libs from the MSVC developer environment)
#
# Usage:
#   scripts/bundle.sh --os <osx|linux|mingw|windows> --arch <x64|arm64> --static-dir <dir> --output <zip>
#
#   --static-dir  the static_<arch> directory the static zip is made from (include/ + stripped lib/); it is only read
#   --output      path of the zip to create
#   --skip-link-tests  skip the smoke and collision link tests (local debugging only, CI never passes it)
#
# Environment:
#   LLVM_BIN  directory with llvm-nm, llvm-objcopy, llvm-readobj and llvm-ar/llvm-ranlib or llvm-lib, clang-cl, lld-link
#             (default: look them up on PATH)
#   CC, CXX   C compiler and C++ link driver for the link tests (default: cc/c++, gcc/g++ on MinGW)
#   LIBTOOL   Apple's libtool (default: /usr/bin/libtool)
#
# Every step is fatal on failure: a bundle that is not verified is never produced.

set -euo pipefail

# ---------------------------------------------------------------------------------------------------------------------
# Per-repo configuration
# ---------------------------------------------------------------------------------------------------------------------

# Main library; it names the output archive (lib<name>.a / <name>.lib).
MAIN_LIB=webp

# Libraries that must end up in the bundle; the closure of their undefined symbols decides what else is merged in
# (libsharpyuv). libwebpdecoder is a subset of libwebp, so the closure never needs it.
ROOT_LIBS=(webp webpdemux webpmux)

# Prefix given to every private symbol.
PREFIX=webprs_

# Symbols that keep their name: the main library's public C API. Extended regex, matched against the C-level name (the
# leading "_" of Mach-O removed). Empty means "nothing is public, rename everything", which is what libwebp needs.
PUBLIC_REGEX=''

# Extra safety net for the undefined-symbol check: references to these (C-level names) must never stay unprefixed.
PRIVATE_API_REGEX='^(WebP|VP8|SharpYuv)'

# Entries of include/ shipped in the bundle. The static zip's include/ holds libwebp's headers directly (decode.h,
# ..., sharpyuv/), so the bundle keeps that layout.
PUBLIC_HEADERS=(decode.h demux.h encode.h mux.h mux_types.h types.h sharpyuv)

# Shipped as include/README: the headers still declare the unprefixed names.
write_include_readme() {
  cat > "$1" <<EOF
These are libwebp's public headers, unchanged. In the library of this bundle EVERY symbol carries the prefix
"${PREFIX}", the public API included: WebPDecodeRGBA is ${PREFIX}WebPDecodeRGBA, WebPGetEncoderVersion is
${PREFIX}WebPGetEncoderVersion, and so on. Use the headers for the types and constants, and declare (or bind) the
functions under their prefixed names. The static inline helpers of the headers (WebPConfigInit, WebPPictureInit,
WebPMuxNew, WebPDemux, WebPDataClear, ...) call the unprefixed names, so call the ${PREFIX}...Internal functions they
wrap instead.

The library merges libwebp, libwebpdemux, libwebpmux and libsharpyuv.
EOF
}

# Smoke test: encodes a small image lossy (with sharp YUV, so libsharpyuv runs) and lossless, wraps it in a container
# with an extra chunk (libwebpmux), parses it back (libwebpdemux) and decodes everything, so the renamed code of every
# bundled library actually runs (CPU dispatch, function pointer tables, SIMD). The bundle renames the whole API, so the
# prefixed functions are declared by hand; the headers only supply types and constants. With BUNDLE_COLLIDE it also
# uses the original, unprefixed libraries linked into the same program (collision test).
write_smoke_source() {
  cat > "$1" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "decode.h"
#include "demux.h"
#include "encode.h"
#include "mux.h"
#include "sharpyuv/sharpyuv.h"

int webprs_WebPGetEncoderVersion(void);
int webprs_WebPGetDecoderVersion(void);
int webprs_WebPGetMuxVersion(void);
int webprs_WebPGetDemuxVersion(void);
int webprs_SharpYuvGetVersion(void);
int webprs_WebPConfigInitInternal(WebPConfig* config, WebPPreset preset, float quality, int version);
int webprs_WebPValidateConfig(const WebPConfig* config);
int webprs_WebPPictureInitInternal(WebPPicture* picture, int version);
int webprs_WebPPictureImportRGBA(WebPPicture* picture, const uint8_t* rgba, int stride);
void webprs_WebPPictureFree(WebPPicture* picture);
void webprs_WebPMemoryWriterInit(WebPMemoryWriter* writer);
void webprs_WebPMemoryWriterClear(WebPMemoryWriter* writer);
int webprs_WebPMemoryWrite(const uint8_t* data, size_t data_size, const WebPPicture* picture);
int webprs_WebPEncode(const WebPConfig* config, WebPPicture* picture);
size_t webprs_WebPEncodeLosslessRGBA(const uint8_t* rgba, int width, int height, int stride, uint8_t** output);
uint8_t* webprs_WebPDecodeRGBA(const uint8_t* data, size_t data_size, int* width, int* height);
void webprs_WebPFree(void* ptr);
WebPMux* webprs_WebPNewInternal(int version);
WebPMuxError webprs_WebPMuxSetImage(WebPMux* mux, const WebPData* bitstream, int copy_data);
WebPMuxError webprs_WebPMuxSetChunk(WebPMux* mux, const char fourcc[4], const WebPData* chunk_data, int copy_data);
WebPMuxError webprs_WebPMuxAssemble(WebPMux* mux, WebPData* assembled_data);
void webprs_WebPMuxDelete(WebPMux* mux);
WebPDemuxer* webprs_WebPDemuxInternal(const WebPData* data, int allow_partial, WebPDemuxState* state, int version);
uint32_t webprs_WebPDemuxGetI(const WebPDemuxer* dmux, WebPFormatFeature feature);
int webprs_WebPDemuxGetChunk(const WebPDemuxer* dmux, const char fourcc[4], int chunk_number, WebPChunkIterator* iter);
void webprs_WebPDemuxReleaseChunkIterator(WebPChunkIterator* iter);
void webprs_WebPDemuxDelete(WebPDemuxer* dmux);

#define W 64
#define H 64

#define FAIL(what)                                                              \
  do {                                                                          \
    fprintf(stderr, "%s failed\n", what);                                       \
    return 1;                                                                   \
  } while (0)

int main(void) {
  static uint8_t rgba[W * H * 4];
  static const char exif[] = "bundle smoke test";
  WebPConfig config;
  WebPPicture picture;
  WebPMemoryWriter writer;
  WebPMux* mux;
  WebPDemuxer* demux;
  WebPChunkIterator chunk;
  WebPData image, chunk_data, assembled;
  uint8_t* lossless;
  uint8_t* decoded;
  size_t lossless_size;
  int x, y, w, h;

  printf("libwebp encoder %06x, decoder %06x, mux %06x, demux %06x, sharpyuv %06x\n",
         webprs_WebPGetEncoderVersion(), webprs_WebPGetDecoderVersion(), webprs_WebPGetMuxVersion(),
         webprs_WebPGetDemuxVersion(), webprs_SharpYuvGetVersion());
#ifdef BUNDLE_COLLIDE
  printf("unprefixed copies linked alongside: libwebp %06x, mux %06x, demux %06x, sharpyuv %06x\n",
         WebPGetEncoderVersion(), WebPGetMuxVersion(), WebPGetDemuxVersion(), SharpYuvGetVersion());
#endif

  for (y = 0; y < H; y++)
    for (x = 0; x < W; x++) {
      uint8_t* p = rgba + (y * W + x) * 4;
      p[0] = (uint8_t) (x * 4); p[1] = (uint8_t) (y * 4); p[2] = (uint8_t) ((x + y) * 2); p[3] = 255;
    }

  /* Lossy encode with sharp RGB->YUV conversion (libsharpyuv). */
  if (!webprs_WebPConfigInitInternal(&config, WEBP_PRESET_DEFAULT, 75.f, WEBP_ENCODER_ABI_VERSION)) FAIL("config init");
  config.use_sharp_yuv = 1;
  if (!webprs_WebPValidateConfig(&config)) FAIL("validate config");
  if (!webprs_WebPPictureInitInternal(&picture, WEBP_ENCODER_ABI_VERSION)) FAIL("picture init");
  picture.width = W;
  picture.height = H;
  if (!webprs_WebPPictureImportRGBA(&picture, rgba, W * 4)) FAIL("import RGBA");
  webprs_WebPMemoryWriterInit(&writer);
  picture.writer = webprs_WebPMemoryWrite;
  picture.custom_ptr = &writer;
  if (!webprs_WebPEncode(&config, &picture)) FAIL("lossy encode");
  webprs_WebPPictureFree(&picture);

  /* Lossless round trip: the pixels must come back exactly. */
  lossless_size = webprs_WebPEncodeLosslessRGBA(rgba, W, H, W * 4, &lossless);
  if (lossless_size == 0) FAIL("lossless encode");
  decoded = webprs_WebPDecodeRGBA(lossless, lossless_size, &w, &h);
  if (!decoded || w != W || h != H || memcmp(decoded, rgba, sizeof(rgba)) != 0) FAIL("lossless round trip");
  webprs_WebPFree(decoded);
  webprs_WebPFree(lossless);

  /* Container with an EXIF chunk (libwebpmux), parsed back (libwebpdemux). */
  mux = webprs_WebPNewInternal(WEBP_MUX_ABI_VERSION);
  if (!mux) FAIL("mux new");
  image.bytes = writer.mem;
  image.size = writer.size;
  chunk_data.bytes = (const uint8_t*) exif;
  chunk_data.size = sizeof(exif);
  if (webprs_WebPMuxSetImage(mux, &image, 1) != WEBP_MUX_OK) FAIL("mux set image");
  if (webprs_WebPMuxSetChunk(mux, "EXIF", &chunk_data, 1) != WEBP_MUX_OK) FAIL("mux set chunk");
  if (webprs_WebPMuxAssemble(mux, &assembled) != WEBP_MUX_OK) FAIL("mux assemble");
  webprs_WebPMuxDelete(mux);

  demux = webprs_WebPDemuxInternal(&assembled, 0, NULL, WEBP_DEMUX_ABI_VERSION);
  if (!demux) FAIL("demux");
  if (webprs_WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH) != W || webprs_WebPDemuxGetI(demux, WEBP_FF_CANVAS_HEIGHT) != H)
    FAIL("demux canvas size");
  if (!webprs_WebPDemuxGetChunk(demux, "EXIF", 1, &chunk) || chunk.chunk.size != sizeof(exif) ||
      memcmp(chunk.chunk.bytes, exif, sizeof(exif)) != 0)
    FAIL("demux EXIF chunk");
  webprs_WebPDemuxReleaseChunkIterator(&chunk);
  webprs_WebPDemuxDelete(demux);

  /* Decode the lossy image out of the container. */
  decoded = webprs_WebPDecodeRGBA(assembled.bytes, assembled.size, &w, &h);
  if (!decoded || w != W || h != H) FAIL("lossy decode");
  webprs_WebPFree(decoded);
#ifdef BUNDLE_COLLIDE
  /* The unprefixed copy reads what the bundle wrote. */
  if (!WebPGetInfo(assembled.bytes, assembled.size, &w, &h) || w != W || h != H) FAIL("unprefixed WebPGetInfo");
#endif

  printf("OK: lossy (sharp YUV) + lossless round trips, mux/demux (%u bytes)\n", (unsigned) assembled.size);
  webprs_WebPFree((void*) assembled.bytes);
  webprs_WebPMemoryWriterClear(&writer);
  return 0;
}
EOF
}

# ---------------------------------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------------------------------

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Prints the first lines of a symbol list, for error messages and logs.
show() { sed -n "1,${2:-50}p" "$1" | sed 's/^/    /'; local n; n=$(wc -l < "$1"); [ "$n" -le "${2:-50}" ] || echo "    ... ($n total)"; }

# Path of an LLVM tool: from $LLVM_BIN when set, otherwise from PATH.
find_tool() {
  if [ -n "${LLVM_BIN:-}" ]; then
    if [ -f "$LLVM_BIN/$1.exe" ]; then echo "$LLVM_BIN/$1.exe"; return; fi
    if [ -x "$LLVM_BIN/$1" ]; then echo "$LLVM_BIN/$1"; return; fi
    die "$1 not found in LLVM_BIN=$LLVM_BIN"
  fi
  command -v "$1" || die "$1 not found on PATH (set LLVM_BIN)"
}

# MSYS2 / Git Bash may hand us Windows paths (D:\a\...); turn them into paths bash is happy with.
unix_path() { if command -v cygpath > /dev/null; then cygpath -u "$1"; else printf '%s\n' "$1"; fi; }

# Sorted, unique symbol names of an archive. llvm-nm prints an empty line and "<member>:" before each member's
# symbols, and native Windows builds print CRLF; all of that is dropped. Extra arguments are llvm-nm flags.
symbols() {
  "$NM" -j "$@" 2> nm.err | tr -d '\r' | awk 'NF && !/:$/' | LC_ALL=C sort -u \
    || { cat nm.err >&2; die "llvm-nm failed on ${*: -1}"; }
}

# Names that COFF linker directives (.drectve) refer to: /alternatename:A=B and /include:X. Section contents are not
# rewritten by llvm-objcopy, so these names must keep their spelling or the directives would point to nothing. They
# are MSVC STL/CRT plumbing (e.g. _Avx2WmemEnabledWeakValue), not library code. Prints nothing for ELF/Mach-O.
directive_symbols() {
  [ "$FORMAT" = coff ] || return 0
  "$READOBJ" --coff-directives "$@" 2> /dev/null | tr -d '\r"' | tr ' ' '\n' \
    | awk 'tolower($0) ~ /^[-\/]alternatename:/ { sub(/^[^:]*:/, ""); n = split($0, p, "="); for (i = 1; i <= n; i++) print p[i] }
           tolower($0) ~ /^[-\/]include:/ { sub(/^[^:]*:/, ""); print }' \
    | LC_ALL=C sort -u
}

# COFF weak externals, as "<alias> <target>" pairs. A weak external is an alias that resolves to <target> unless
# something else defines <alias>; recent MSVC emits every vector deleting destructor (??_E...) this way, aliased to
# the scalar one (??_G...). llvm-nm lists them as undefined, but they are definitions in all but name: an alias must
# be renamed together with its target, or the bundle would still define the unprefixed ??_E... of every class.
# Prints nothing for ELF/Mach-O.
weak_externals() {
  [ "$FORMAT" = coff ] || return 0
  "$READOBJ" --symbols "$@" 2> /dev/null | tr -d '\r' | awk '
    $1 == "Symbol" && $2 == "{" { name = ""; weak = 0 }
    $1 == "Name:" { name = $2 }
    $1 == "StorageClass:" && $2 == "WeakExternal" { weak = 1 }
    $1 == "Linked:" && weak { print name, $2 }' | LC_ALL=C sort -u
}

# Classifies symbol names (stdin, one per line) for the rename map and the verification. $1 is the output of
# directive_symbols, $2 a list of names that were renamed already (empty before renaming). Output: "<class> <name>",
# class being one of
#   public   the main library's C API, keeps its name
#   special  COFF/linker machinery that must keep its name: @feat.00, @comp.id, @vol.md, __real@/__xmm@/__ymm@ constants
#            (named by their content), __imp_ import thunks, names used by .drectve directives and other names
#            starting with "." (e.g. MinGW's .weak.__cxa_pure_virtual.* aliases)
#   prefixed carries the prefix
#   refptr   MinGW .refptr.<target>, a COMDAT keyed by its name that holds the address of <target>. It must be renamed
#            when its target is: if it kept its name, the linker would fold the bundle's .refptr with the one of another
#            copy and one of them would point to the wrong copy (see the rename map for the new name). A .refptr to a
#            symbol the bundle doesn't own (C++ runtime, public API) is "special".
#   private  everything else: gets the prefix
classify() {
  awk -v fmt="$FORMAT" -v pub="$PUBLIC_REGEX" -v prefix="$PREFIX" -v dfile="$1" -v ofile="$2" '
    BEGIN {
      while ((getline l < dfile) > 0) directive[l] = 1
      while ((getline l < ofile) > 0) old[l] = 1
    }
    function cls(name,   c) {
      c = name
      if (fmt == "macho" && substr(c, 1, 1) == "_") c = substr(c, 2)
      if (pub != "" && c ~ pub) return "public"
      if (fmt == "coff" && (name == "@feat.00" || name == "@comp.id" || name == "@vol.md" || name ~ /^\./ ||
                            name ~ /^__(real|xmm|ymm)@/ || name ~ /^__imp_/ || (name in directive))) return "special"
      if (substr(c, 1, length(prefix)) == prefix) return "prefixed"
      return "private"
    }
    { names[++n] = $0; defined[$0] = 1 }
    END {
      for (i = 1; i <= n; i++) {
        name = names[i]
        if (fmt == "coff" && name ~ /^\.refptr\./) {
          t = substr(name, 9)
          k = (t in defined) ? cls(t) : "external"
          if (k == "prefixed") print "prefixed", name
          else if (k == "private" || (t in old)) print "refptr", name
          else print "special", name
        } else print cls(name), name
      }
    }'
}

# ---------------------------------------------------------------------------------------------------------------------
# Arguments and tools
# ---------------------------------------------------------------------------------------------------------------------

OS='' ARCH='' STATIC_DIR='' OUTPUT='' SKIP_LINK_TESTS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --os) OS=$2; shift 2 ;;
    --arch) ARCH=$2; shift 2 ;;
    --static-dir) STATIC_DIR=$2; shift 2 ;;
    --output) OUTPUT=$2; shift 2 ;;
    --skip-link-tests) SKIP_LINK_TESTS=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$OS" ] && [ -n "$ARCH" ] && [ -n "$STATIC_DIR" ] && [ -n "$OUTPUT" ] \
  || die "usage: $0 --os <osx|linux|mingw|windows> --arch <x64|arm64> --static-dir <dir> --output <zip>"
case "$ARCH" in x64 | arm64) ;; *) die "unknown arch: $ARCH" ;; esac

STATIC_DIR=$(cd "$(unix_path "$STATIC_DIR")" && pwd)
OUTPUT=$(unix_path "$OUTPUT")
case "$OUTPUT" in /*) ;; *) OUTPUT="$PWD/$OUTPUT" ;; esac

case "$OS" in
  osx) FORMAT=macho EXT=a OUT_LIB="lib$MAIN_LIB.a" ;;
  linux) FORMAT=elf EXT=a OUT_LIB="lib$MAIN_LIB.a" ;;
  mingw) FORMAT=coff EXT=a OUT_LIB="lib$MAIN_LIB.a" ;;
  windows) FORMAT=coff EXT=lib OUT_LIB="$MAIN_LIB.lib" ;;
  *) die "unknown os: $OS" ;;
esac

NM=$(find_tool llvm-nm)
OBJCOPY=$(find_tool llvm-objcopy)
[ "$FORMAT" = coff ] && READOBJ=$(find_tool llvm-readobj)
case "$OS" in
  osx) LIBTOOL=${LIBTOOL:-/usr/bin/libtool} ;;
  linux | mingw) AR=$(find_tool llvm-ar); RANLIB=$(find_tool llvm-ranlib) ;;
  windows) LLVM_LIB=$(find_tool llvm-lib) ;;
esac
log "llvm-objcopy: $OBJCOPY ($("$OBJCOPY" --version | tr -d '\r' | grep -i version | head -1))"

# MSYS2 shells don't inherit the Windows PATH, so 7-Zip may only be reachable by its install location.
SEVENZIP=$(command -v 7z || true)
if [ -z "$SEVENZIP" ] && [ -f "/c/Program Files/7-Zip/7z.exe" ]; then SEVENZIP="/c/Program Files/7-Zip/7z.exe"; fi
[ -n "$SEVENZIP" ] || die "7z not found"

# Everything happens in a scratch directory, on copies; relative paths are used from here on, so native Windows tools
# never see MSYS paths.
WORK=$(mktemp -d "$(unix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")/bundle.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p in syms bundle/include bundle/lib test

# ---------------------------------------------------------------------------------------------------------------------
# a. Closure: only the archives the root libraries actually need
# ---------------------------------------------------------------------------------------------------------------------

# lib<name>.a, or <name>.lib / lib<name>.lib with MSVC.
lib_file() {
  local f
  for f in "lib$1.$EXT" "$1.$EXT"; do [ -f "in/$f" ] && { echo "$f"; return; }; done
  die "library $1 not found in $STATIC_DIR/lib"
}

cp "$STATIC_DIR"/lib/*."$EXT" in/
ALL=()
for f in in/*."$EXT"; do
  f=${f#in/}
  ALL+=("$f")
  symbols --defined-only --extern-only "in/$f" > "syms/$f.def"
  symbols --undefined-only "in/$f" > "syms/$f.undef"
  [ -s "syms/$f.def" ] || die "no symbols read from $f"
done

CLOSURE=()
for name in "${ROOT_LIBS[@]}"; do CLOSURE+=("$(lib_file "$name")"); done

in_closure() { local f; for f in "${CLOSURE[@]}"; do [ "$f" = "$1" ] && return 0; done; return 1; }

# Repeatedly add the archive that resolves the most still-undefined symbols, until nothing more can be resolved. An
# archive whose symbols are all provided already (e.g. a subset library) is never added, so two archives defining the
# same objects are never merged.
while :; do
  (cd syms && for f in "${CLOSURE[@]}"; do cat "$f.def"; done) | LC_ALL=C sort -u > closure.def
  (cd syms && for f in "${CLOSURE[@]}"; do cat "$f.undef"; done) | LC_ALL=C sort -u \
    | LC_ALL=C comm -23 - closure.def > unresolved
  best='' best_n=0
  for f in "${ALL[@]}"; do
    in_closure "$f" && continue
    n=$(LC_ALL=C comm -12 unresolved "syms/$f.def" | wc -l | tr -d ' ')
    if [ "$n" -gt "$best_n" ]; then best=$f best_n=$n; fi
  done
  [ "$best_n" -gt 0 ] || break
  log "closure: + $best (resolves $best_n symbols)"
  CLOSURE+=("$best")
done
log "closure: ${CLOSURE[*]}"
for f in "${ALL[@]}"; do in_closure "$f" || log "closure: dropped $f (not needed)"; done
log "left to the system/C++ runtime: $(wc -l < unresolved | tr -d ' ') symbols"

# ---------------------------------------------------------------------------------------------------------------------
# b + c. Rename map
# ---------------------------------------------------------------------------------------------------------------------

(cd in && directive_symbols "${CLOSURE[@]}") > directives
(cd in && weak_externals "${CLOSURE[@]}") > weak.pairs
: > none
classify directives none < closure.def > closure.classes
grep -c . closure.classes > /dev/null || die "no symbols to classify"
for class in public special private refptr prefixed; do
  log "symbols: $(grep -c "^$class " closure.classes || true) $class"
done
grep -q "^prefixed " closure.classes && die "the input already contains prefixed symbols (${PREFIX}*)"
[ -z "$PUBLIC_REGEX" ] || grep -q "^public " closure.classes || die "no public symbols found (PUBLIC_REGEX=$PUBLIC_REGEX)"

# OLD NEW, NEW being prefix + OLD, except on Mach-O where the prefix goes after the leading "_" (_WebPDecode ->
# _webprs_WebPDecode) so the C-level name stays valid. A weak external follows its target.
#
# A .refptr.<target> becomes <prefix>.refptr.<target>, NOT .refptr.<prefix><target>. llvm-objcopy can't rename COFF
# sections, so its COMDAT section keeps the name .rdata$.refptr.<target>. GNU ld merges two COMDATs only when both
# their symbol and their section name match, so with .refptr.<prefix><target> the bundle's copy would clash with
# the correctly named one (.rdata$.refptr.<prefix><target>) that gcc emits in any program taking the address of a
# bundle function: "multiple definition of .refptr.webprs_...". A symbol name gcc never generates can't clash with
# anything, and the bundle's own copies still merge, since they all agree on both names.
awk -v fmt="$FORMAT" -v prefix="$PREFIX" '
  function renamed(n) { return (fmt == "macho" && substr(n, 1, 1) == "_") ? "_" prefix substr(n, 2) : prefix n }
  FNR == 1 { file++ }
  file == 1 && $1 == "private" { new[$2] = renamed($2) }
  file == 1 && $1 == "refptr" { refptr[$2] = substr($2, 9) }
  file == 1 { defined[$2] = 1 }
  file == 2 { alias[$1] = $2 }
  END {
    for (r in refptr) if (refptr[r] in new) new[r] = prefix r
    for (a in alias) if (!(a in defined) && (alias[a] in new)) new[a] = renamed(a)
    for (n in new) print n, new[n]
  }' closure.classes weak.pairs | LC_ALL=C sort > rename.map
[ "$FORMAT" != coff ] || log "weak externals: $(wc -l < weak.pairs | tr -d ' '), renamed with their target: $(awk 'FNR == NR { w[$1] = 1; next } $1 in w' weak.pairs rename.map | wc -l | tr -d ' ')"
awk 'NF != 2 { bad = 1 } END { exit bad }' rename.map || die "symbol names with whitespace can't be renamed"
cut -d' ' -f1 rename.map > renamed.old
log "rename map: $(wc -l < rename.map | tr -d ' ') symbols"

# ---------------------------------------------------------------------------------------------------------------------
# d. Rename, in every archive of the closure (the main library too, so its references follow)
# ---------------------------------------------------------------------------------------------------------------------

for f in "${CLOSURE[@]}"; do
  log "renaming symbols in $f"
  "$OBJCOPY" --redefine-syms=rename.map "in/$f" "in/$f.renamed" || die "llvm-objcopy failed on $f"
  mv "in/$f.renamed" "in/$f"
done

# ---------------------------------------------------------------------------------------------------------------------
# e. Merge into the single output archive
# ---------------------------------------------------------------------------------------------------------------------

BUNDLE="bundle/lib/$OUT_LIB"
CLOSURE_PATHS=()
for f in "${CLOSURE[@]}"; do CLOSURE_PATHS+=("in/$f"); done
case "$OS" in
  osx)
    "$LIBTOOL" -static -no_warning_for_no_symbols -o "$BUNDLE" "${CLOSURE_PATHS[@]}"
    ;;
  linux | mingw)
    { echo "CREATE $BUNDLE"; for f in "${CLOSURE[@]}"; do echo "ADDLIB in/$f"; done; echo "SAVE"; echo "END"; } > merge.mri
    "$AR" -M < merge.mri
    "$RANLIB" "$BUNDLE"
    ;;
  windows)
    "$LLVM_LIB" -nologo -out:"$BUNDLE" "${CLOSURE_PATHS[@]}"
    ;;
esac
[ -s "$BUNDLE" ] || die "merge produced no $BUNDLE"
log "merged $BUNDLE ($(wc -c < "$BUNDLE" | tr -d ' ') bytes)"

for h in "${PUBLIC_HEADERS[@]}"; do cp -R "$STATIC_DIR/include/$h" bundle/include/; done
write_include_readme bundle/include/README

# ---------------------------------------------------------------------------------------------------------------------
# f. Verification
# ---------------------------------------------------------------------------------------------------------------------

# 1. Every defined symbol is public API, prefixed or linker machinery.
symbols --defined-only --extern-only "$BUNDLE" > bundle.def
directive_symbols "$BUNDLE" > bundle.directives
classify bundle.directives renamed.old < bundle.def > bundle.classes
grep -E '^(private|refptr) ' bundle.classes | cut -d' ' -f2 > offenders || true
if [ -s offenders ]; then
  echo "Defined symbols that are neither public nor prefixed:"; show offenders
  die "verification 1 failed"
fi
weak_externals "$BUNDLE" | awk -v prefix="$PREFIX" '
  substr($2, 1, length(prefix)) == prefix && substr($1, 1, length(prefix)) != prefix { print $1 " -> " $2 }' > offenders
[ ! -s offenders ] || { echo "Unprefixed weak externals aliasing prefixed symbols:"; show offenders; die "verification 1 failed"; }
{ grep '^public ' bundle.classes || true; } | cut -d' ' -f2 | LC_ALL=C sort > bundle.public
{ grep '^public ' closure.classes || true; } | cut -d' ' -f2 | LC_ALL=C sort | LC_ALL=C comm -23 - bundle.public > offenders
[ ! -s offenders ] || { echo "Public symbols missing from the bundle:"; show offenders; die "verification 1 failed"; }
log "verify 1 OK: $(wc -l < bundle.def | tr -d ' ') defined symbols, all public ($(grep -c '^public ' bundle.classes || true)), prefixed ($(grep -c '^prefixed ' bundle.classes)) or linker machinery ($(grep -c '^special ' bundle.classes || true))"

# 2. No reference to an unprefixed private symbol is left.
symbols --undefined-only "$BUNDLE" > bundle.undef
LC_ALL=C comm -12 bundle.undef renamed.old > offenders
[ ! -s offenders ] || { echo "References to renamed symbols under their old name:"; show offenders; die "verification 2 failed"; }
LC_ALL=C comm -23 bundle.undef bundle.def \
  | awk -v fmt="$FORMAT" -v re="$PRIVATE_API_REGEX" '
      { c = $0; sub(/^__imp_/, "", c); if (fmt == "macho") sub(/^_/, "", c); if (c ~ re) print }' > offenders
[ ! -s offenders ] || { echo "Unresolved references to private APIs:"; show offenders; die "verification 2 failed"; }
log "verify 2 OK: no reference to an unprefixed private symbol ($(LC_ALL=C comm -23 bundle.undef bundle.def | wc -l | tr -d ' ') left to the system)"

# 3 + 4. Smoke and collision tests.
#
#   smoke:     the test program against the bundle alone (plus system libs), then run.
#   collision: the same program, built with BUNDLE_COLLIDE so it also calls the original libraries, against the
#              bundle AND the original unprefixed archives from the static zip, every object of each forced in
#              (whole-archive), duplicate symbols fatal. A clean link proves the bundle can't clash with another copy
#              of the libraries it contains; running it proves both copies work side by side.
#
# With a public API (PUBLIC_REGEX set) the root libraries are left out of the collision test, since their public
# symbols are meant to clash. With nothing public, as here, every archive of the closure must be clash-free, the
# original libwebp included.
ORIGINALS=()
for f in "${CLOSURE[@]}"; do
  is_root=0
  if [ -n "$PUBLIC_REGEX" ]; then
    for name in "${ROOT_LIBS[@]}"; do [ "$f" = "$(lib_file "$name")" ] && is_root=1; done
  fi
  [ "$is_root" = 1 ] || ORIGINALS+=("orig/$f")
done

if [ "$SKIP_LINK_TESTS" = 1 ]; then
  log "skipping smoke and collision tests (--skip-link-tests)"
else
  mkdir -p orig
  # The original archives and headers the collision test is built against.
  for f in "${CLOSURE[@]}"; do cp "$STATIC_DIR/lib/$f" orig/; done
  cp -R "$STATIC_DIR/include" orig/include
  write_smoke_source test/smoke.c
  RUN=1

  case "$OS" in
    osx)
      # libwebp is plain C: the C compiler links, so the tests also prove no C++ runtime is needed.
      CC=${CC:-cc}
      [ "$ARCH" = x64 ] && ARCH_FLAGS=(-arch x86_64) || ARCH_FLAGS=(-arch arm64)
      if [ "$ARCH" = x64 ] && [ "$(uname -m)" = arm64 ] && ! /usr/bin/arch -x86_64 /usr/bin/true 2> /dev/null; then
        RUN=0; log "Rosetta unavailable: the x64 test programs are linked but not run"
      fi
      compile() { "$CC" "${ARCH_FLAGS[@]}" -O1 -Ibundle/include -Iorig/include "$@"; }
      link_smoke() { "$CC" "${ARCH_FLAGS[@]}" -o "$1" "$2" "$BUNDLE"; }
      # Duplicate symbols are errors for ld64; -fatal_warnings makes every other linker complaint fatal too.
      # shellcheck disable=SC2054 # -Wl,-force_load,<lib> is one argument
      link_collide() {
        local out=$1 obj=$2 f; shift 2
        local args=(-Wl,-fatal_warnings -Wl,-force_load,"$BUNDLE")
        for f in "$@"; do args+=(-Wl,-force_load,"$f"); done
        "$CC" "${ARCH_FLAGS[@]}" -o "$out" "$obj" "${args[@]}"
      }
      ;;
    linux | mingw)
      if [ "$OS" = linux ]; then CC=${CC:-cc} SYSLIBS=(-lpthread -lm)
      else CC=${CC:-gcc} SYSLIBS=(-lm); fi
      compile() { "$CC" -O1 -Ibundle/include -Iorig/include "$@"; }
      link_smoke() { "$CC" -o "$1" "$2" "$BUNDLE" "${SYSLIBS[@]}"; }
      link_collide() {
        local out=$1 obj=$2; shift 2
        "$CC" -o "$out" "$obj" -Wl,--whole-archive "$BUNDLE" "$@" -Wl,--no-whole-archive "${SYSLIBS[@]}"
      }
      ;;
    windows)
      CLANG_CL=$(find_tool clang-cl)
      LLD_LINK=$(find_tool lld-link)
      if [ "$ARCH" = x64 ]; then TARGET=x86_64-pc-windows-msvc MACHINE=x64; else TARGET=aarch64-pc-windows-msvc MACHINE=arm64; fi
      [ -n "${LIB:-}" ] || die "LIB is not set: run inside the MSVC developer environment (ilammy/msvc-dev-cmd)"
      # Options are spelled -opt instead of /opt so MSYS doesn't take them for paths. The C runtime comes from the
      # objects' /DEFAULTLIB directives (/MD: msvcrt); Win32 import libs are added explicitly.
      SYSLIBS=(kernel32.lib)
      compile() {
        "$CLANG_CL" --target="$TARGET" -nologo -MD -O1 -D_CRT_SECURE_NO_WARNINGS -Ibundle/include -Iorig/include "$@"
      }
      link_smoke() { "$LLD_LINK" -nologo -machine:"$MACHINE" -subsystem:console -out:"$1" "$2" "$BUNDLE" "${SYSLIBS[@]}"; }
      link_collide() {
        local out=$1 obj=$2 f; shift 2
        local args=(-wholearchive:"$BUNDLE")
        for f in "$@"; do args+=(-wholearchive:"$f"); done
        "$LLD_LINK" -nologo -machine:"$MACHINE" -subsystem:console -out:"$out" "$obj" "${args[@]}" "${SYSLIBS[@]}"
      }
      ;;
  esac

  if [ "$OS" = windows ]; then
    compile -c test/smoke.c -Fotest/smoke.obj
    compile -DBUNDLE_COLLIDE -c test/smoke.c -Fotest/collide.obj
    OBJ=obj EXE=.exe
  else
    compile -c test/smoke.c -o test/smoke.o
    compile -DBUNDLE_COLLIDE -c test/smoke.c -o test/collide.o
    OBJ=o EXE=
  fi
  [ "$OS" = mingw ] && EXE=.exe

  run() {
    if [ "$RUN" = 1 ]; then
      if [ "$OS" = osx ] && [ "$ARCH" = x64 ]; then /usr/bin/arch -x86_64 "$1"; else "$1"; fi || die "$1 failed"
    fi
  }

  log "smoke test: linking against the bundle only"
  link_smoke "test/smoke$EXE" "test/smoke.$OBJ" || die "verification 3 failed: smoke test does not link"
  run "test/smoke$EXE"
  log "verify 3 OK"

  log "collision test: bundle + original ${ORIGINALS[*]}, whole archives"
  link_collide "test/collide$EXE" "test/collide.$OBJ" ${ORIGINALS[@]+"${ORIGINALS[@]}"} \
    || die "verification 4 failed: the bundle clashes with the original libraries"
  run "test/collide$EXE"
  log "verify 4 OK"
fi

# ---------------------------------------------------------------------------------------------------------------------
# g. Zip
# ---------------------------------------------------------------------------------------------------------------------

(cd bundle && "$SEVENZIP" a -tzip -mx=9 -snl ../bundle.zip include lib > /dev/null)
mkdir -p "$(dirname "$OUTPUT")"
mv bundle.zip "$OUTPUT"
log "created $OUTPUT"
