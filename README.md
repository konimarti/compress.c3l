## DEFLATE compression in C3

A C3 implementation of the DEFLATE (RFC 1951) and GZIP (RFC 1952) compression
format.

The library provides both a simple API (`compress` / `uncompress`)
and lower‑level building blocks (`deflate` / `inflate`).

### Features

- DEFLATE encode and decode (raw DEFLATE stream), and GZIP format.
- Canonical Huffman code generation (fixed and dynamic trees)
- LZ77 tokenizer with sliding window and hash‑chain match finder
- Bit‑level I/O in LSB‑first order for DEFLATE’s bitstream

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

For more control over block structure and strategies, use `deflate` and `inflate`.

```c
import compress::flate;

alias DeflateBlockFn =
    fn void?(FlateCompressor *c, char[] input_chunk, bool is_last_chunk);

// Core DEFLATE compressor with pluggable block encoder.
fn char[]? deflate(Allocator allocator,
                   char[] bytes,
                   DeflateBlockFn block_fn = &flate::encode_dynamic_block,
                   usz max_block_len = 65_535);

// Core DEFLATE decompressor.
fn char[]? inflate(Allocator allocator, char[] bytes);
```

#### Built‑in block encoders

The library exposes three encoder strategies:

```c
// Stored (uncompressed) block.
fn void? encode_stored_block(FlateCompressor *c, char[] chunk, bool is_last_chunk);

// Fixed Huffman block (RFC 1951 §3.2.6).
fn void? encode_fixed_block(FlateCompressor *c, char[] chunk, bool is_last_chunk);

// Dynamic Huffman block (RFC 1951 §3.2.7).
fn void? encode_dynamic_block(FlateCompressor *c, char[] chunk, bool is_last_chunk);
```

Example: force fixed‑Huffman encoding for a buffer:

```c
fn void example_fixed_block() => @pool()
{
    char[] input = "hello world world hello";
    char[] compressed = flate::deflate(tmem, input, &flate::encode_fixed_block)!!;
    char[] output = flate::inflate(tmem, compressed)!!;
    assert(output == input);
}
```

### Internal Modules Overview

#### `compress::flate::bitio`

Bit‑level I/O utilities:

- `FlateWriter`: LSB‑first bit writer, flushes to an `OutStream`
- `FlateReader`: LSB‑first bit reader on an `InStream`

Used by both compressor and decompressor to match DEFLATE’s bit layout.

#### `compress::flate::huff`

Canonical Huffman helpers:

- `HuffCodes`: bit‑reversed canonical codes and lengths for encoding
- `HuffOrder`: canonical symbol ordering and per‑length counts for decoding

#### `compress::flate::lz77`

LZ77 tokenizer and match finder:

- Sliding‑window match finding with hash chains
- `LzToken` type (literal and match tokens)
- `tokenize(...)` to convert a byte slice to LZ77 tokens

This module is intentionally focused and can be reused for other LZ77‑style compressors.

### Roadmap / TODO

Potential future enhancements:

- zlib and gzip container support (headers, checksums)
- Compression levels (trade‑off between speed and ratio)
- Streaming interfaces (incremental compression/decompression)
- More advanced block‑splitting heuristics and match‑finding tuning

## License

This project is licensed under the **MIT License**.  
See `LICENSE` for details.
