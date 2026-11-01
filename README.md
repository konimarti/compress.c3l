## DEFLATE compression in C3

A C3 implementation of the DEFLATE (RFC 1951) and GZIP (RFC 1952) compression
format.

The library provides both a simple API (`compress` / `uncompress`)
and lower‑level building blocks (`deflate` / `inflate`).

### Features

- DEFLATE encode and decode (raw DEFLATE stream), and GZIP format.
- Canonical Huffman code generation (fixed and dynamic trees)
- LZ77 matching with lazy evaluation and hash chains
- Per‑block choice between stored, fixed and dynamic coding

### Getting Started

1. Copy or add this repository as a submodule, e.g.:

```bash
git submodule add https://github.com/konimarti/compress.c3l.git lib/compress.c3l
```

2. Reference it from your project configuration:

```jsonc
{
  "dependencies": [
    "compress" // provided by compress.c3l
  ]
}
```

The library itself exports the `compress` package with the `compress::flate` module.

### High‑Level API

The simplest way to use the library is via the high‑level buffer API:

```c
import compress::flate;

fn void example_compress_uncompress() => @pool()
{
    char[] input = "hello world world hello";

    // Compress
    char[] compressed = flate::compress(tmem, input)!!;

    // Decompress
    char[] output = flate::uncompress(tmem, compressed)!!;

    assert(output == input);
}
```

#### Functions

```c
// Compresses a buffer using DEFLATE.
// Chooses a block strategy (stored vs compressed) based on the input.
fn char[]? compress(Allocator allocator, char[] bytes);

// Convenience wrapper using the temporary allocator.
fn char[]? tcompress(char[] bytes);

// Decompresses a complete DEFLATE stream into a new buffer.
fn char[]? uncompress(Allocator allocator, char[] bytes);

// Convenience wrapper using the temporary allocator.
fn char[]? tuncompress(char[] bytes);
```

### Low‑Level DEFLATE API

`deflate` takes a block coding strategy; `inflate` / `inflate_stream` decode.

```c
import compress::flate;

enum DeflateMode { AUTO, STORED, FIXED, DYNAMIC }

// DEFLATE compressor. AUTO picks stored, fixed or dynamic Huffman per block,
// whichever is smallest; the other modes force one coding.
fn char[]? deflate(Allocator allocator, char[] bytes, DeflateMode mode = AUTO);

// Same, but writes to an OutStream.
fn void? deflate_stream(OutStream out, char[] bytes, DeflateMode mode = AUTO);

// DEFLATE decompressor.
fn char[]? inflate(Allocator allocator, char[] bytes);

// Reads from an InStream and consumes exactly the DEFLATE stream.
fn char[]? inflate_stream(Allocator allocator, InStream stream);
```

Example: force fixed‑Huffman encoding for a buffer:

```c
fn void example_fixed_block() => @pool()
{
    char[] input = "hello world world hello";
    char[] compressed = flate::deflate(tmem, input, FIXED)!!;
    char[] output = flate::inflate(tmem, compressed)!!;
    assert(output == input);
}
```

### Streaming API

For data that should not be held in memory, `DeflateWriter` and
`InflateReader` wrap streams and use constant memory (about 1 MiB each)
however much data passes through.

```c
import compress::flate, std::io;

// Compress: everything written to the writer ends up compressed in `out`.
DeflateWriter w;
w.init(mem, &out);          // out: any OutStream
io::copy_to(&in, &w)!!;     // or w.write(...) as often as needed
w.close()!!;                // writes the final block; must be called
w.free();

// Decompress: reading from the reader yields the original bytes.
InflateReader r;
r.init(mem, &compressed);   // compressed: any InStream
io::copy_to(&r, &out)!!;
r.free();
```

Shortcuts: `deflate_from(allocator, out, in, mode)` and
`inflate_to(allocator, out, in)` run the whole copy.

`InflateReader` reads its source in chunks, so it may consume more than the
DEFLATE stream; `leftover()` returns the surplus after the stream ended (e.g.
a gzip trailer). `inflate_stream` is the exact alternative: it reads a byte at
a time and stops precisely at the end of the stream, but holds the output in
memory. A 4.7 GB file compresses and decompresses through the streams with
about 3 MB of resident memory, at roughly 95 MB/s and 450 MB/s on the test
machine below.

### Performance

The encoder uses a whole‑input hash‑chain matcher with lazy matching and picks
stored, fixed or dynamic coding per block; the decoder is table driven with a
64‑bit bit buffer.

Benchmark against `std::compression::deflate` (default settings). Median of at
least 5 runs after a warm‑up, MB/s of uncompressed data. Each library's output
is also decoded by the other library to check interoperability.

| input | size | lib | ratio | compress MB/s | decompress MB/s |
|---|---:|---|---:|---:|---:|
| text (c3 stdlib sources) | 3.1 MB | compress.c3l | **23.82%** | **129.8** | **745.2** |
| | | std | 24.87% | 121.4 | 431.9 |
| binary (c3c executable) | 16 MB | compress.c3l | **39.52%** | **83.8** | **508.6** |
| | | std | 40.39% | 79.5 | 295.0 |
| skewed random bytes (synthetic) | 8 MB | compress.c3l | **56.97%** | **64.9** | **310.7** |
| | | std | 61.39% | 64.1 | 271.8 |
| random bytes (synthetic) | 8 MB | compress.c3l | **100.02%** | **649.4** | **32 743** |
| | | std | 100.10% | 89.2 | 338.8 |
| zeros (synthetic) | 8 MB | compress.c3l | 0.10% | **5 892** | **1 015** |
| | | std | 0.10% | 1 454 | 580.6 |
| large mixed (text + binary) | 519 MB | compress.c3l | **31.57%** | **100.5** | **536.5** |
| | | std | 32.54% | 93.4 | 269.6 |

Speed ratio compress.c3l/std: compression 1.01x–7.3x on the non‑trivial inputs
(1.05–1.07x on text and binary), decompression 1.14x–1.75x on compressible
data. The decompression figure for random data is a plain copy of stored
blocks. The gains on compression are modest on real data; the match finder is
the same class of algorithm as std's, and the biggest wins come from the
decoder and from handling incompressible and highly repetitive input.

The large input is 85 copies of the text file followed by 16 copies of the
binary. The encoder works on inputs of any size: it processes them in segments
of 1 GiB (a 4.7 GB test input roundtrips), so matches do not cross a segment
boundary.

Setup: Intel Core i7‑14700, WSL2 (Linux 6.18), c3c 0.8.6 with `-O3`, single
thread. Numbers vary by machine; reproduce with:

```bash
c3c -O3 build bench
./build/bench --gen path/to/file1 path/to/file2   # --gen adds the synthetic inputs
```

### Internal Modules Overview

#### `compress::flate::huff`

Canonical Huffman helpers:

- `HuffCodes`: bit‑reversed canonical codes and lengths for encoding
- `HuffOrder`: canonical symbol ordering and per‑length counts for decoding

#### `compress::flate::pkgmerge`

Length‑limited Huffman code lengths via package‑merge.

### Roadmap / TODO

Potential future enhancements:

- zlib and gzip container support (headers, checksums)
- Compression levels (trade‑off between speed and ratio)
- Streaming gzip (the gzip module still buffers the whole payload)
- More advanced block‑splitting heuristics and match‑finding tuning

## License

This project is licensed under the **MIT License**.  
See `LICENSE` for details.
