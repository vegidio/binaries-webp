# binaries-webp

A repository with static and dynamic binaries for libwebp.

It offers x64 & arm64 versions for macOS, Linux, MinGW and Windows.

## 📦 Release assets

| Asset                       | Contents                                                                                  |
|-----------------------------|-------------------------------------------------------------------------------------------|
| `static_<os>_<arch>.zip`    | libwebp, libwebpdecoder, libwebpdemux, libwebpmux and libsharpyuv as separate static libs |
| `dynamic_<os>_<arch>.zip`   | the same libraries as shared libraries (`.dylib`, `.so`, `.dll`)                           |
| `bundle_<os>_<arch>.zip`    | ONE self-contained static library with every symbol prefixed by `webprs_` (see below)     |

`<os>` is `osx`, `linux`, `mingw` or `windows` (MSVC); `<arch>` is `x64` or `arm64`.

### Bundle

The bundle is meant for programs that statically link libwebp **and** another copy of it, typically a full FFmpeg build,
which bundles its own libwebp and libsharpyuv. With the separate static libraries, two copies of libwebp end up in the
same link: either the linker fails with duplicate symbols, or it silently mixes code from two different versions.

`bundle_<os>_<arch>.zip` contains:

- `include/`: libwebp's public headers, unchanged and in the same layout as the static zip, plus a short `README`.
- `lib/libwebp.a` (`lib/webp.lib` on Windows/MSVC): libwebp, libwebpdemux, libwebpmux and libsharpyuv merged into one
  library. libwebpdecoder is left out, since it is a subset of libwebp.

**Every** symbol in that library is renamed with the prefix `webprs_`, including libwebp's public API
(`WebPDecodeRGBA` → `webprs_WebPDecodeRGBA`, `SharpYuvConvert` → `webprs_SharpYuvConvert`). The API has to be renamed
too, because FFmpeg's copy of libwebp exports the same `WebP*` functions. The bundle therefore can't clash with any other
copy of libwebp or libsharpyuv, whatever its version.

Use the headers for types and constants, and declare (or bind) the functions under their prefixed names. The headers'
static inline helpers (`WebPConfigInit`, `WebPPictureInit`, `WebPMuxNew`, `WebPDemux`, `WebPDataClear`, ...) call the
unprefixed names, so call the `webprs_...Internal` functions they wrap instead. Link the library alone, plus the system
libraries (`-lpthread -lm` on Linux, `-lm` on MinGW, nothing extra on macOS). On MSVC the C runtime comes from the
library's `/DEFAULTLIB` directives (`/MD`), plus `kernel32.lib`.

The bundle is produced by [scripts/bundle.sh](scripts/bundle.sh) from the same stripped libraries as the static zip.
Each build verifies it: no unprefixed symbol is defined or referenced, a small program encodes (lossy with sharp YUV and
lossless), muxes, demuxes and decodes an image with it, and the same program links and runs with the bundle **and** the
original unprefixed libwebp, libwebpdemux, libwebpmux and libsharpyuv forced in together.

## 👨🏾‍💻 Author

Vinicius Egidio ([vinicius.io](http://vinicius.io))
