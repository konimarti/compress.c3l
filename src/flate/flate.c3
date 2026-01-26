// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;
import std::io;

fn char[]? compress(Allocator allocator, char[] bytes) @inline
{
	if (bytes.len < 32)
	{
		return deflate(allocator, bytes, &store_block);
	}
	return deflate(allocator, bytes, &dynamic_block, 1<<16);
}
fn char[]? tcompress(char[] bytes) @inline => compress(tmem, bytes);
fn char[]? uncompress(Allocator allocator, char[] bytes) @inline => inflate(allocator, bytes);
fn char[]? tuncompress(char[] bytes) @inline => inflate(tmem, bytes);

faultdef INVALID_BLOCK_TYPE;
<*
@return? INVALID_BLOCK_TYPE
*>
fn char[]? inflate(Allocator allocator, char[] bytes)
{
	ByteReader byte_reader;
	byte_reader.init(bytes);

	ByteWriter byte_writer;
	byte_writer.init(allocator);

	FlateDecompressor decomp;
	decomp.init(&byte_reader, &byte_writer);

	uint final, type;
	while (true)
	{
		final = decomp.getbits(1)!;
		type  = decomp.getbits(2)!;

		switch(type)
		{
			case 0: decomp.store_block()!;
			case 1: decomp.fixed_block()!;
			case 2: decomp.dynamic_block()!;
			default: return INVALID_BLOCK_TYPE~;
		}
		if (final) break;
	}
	return byte_writer.array_view();
}

const MAX_BLOCK_SIZE = 65_535;

alias DeflateBlockFn = fn void?(FlateCompressor *c, char[] bytes, bool final);

<*
 Compresses the given input using the DEFLATE algorithm (RFC 1951).

 The input is processed in one or more consecutive blocks. For each block,
 this function calls the user‑supplied `deflate_block` callback, which is
 responsible for:
   - performing LZ77 tokenization,
   - emitting one (or more) DEFLATE blocks into the compressor stream, and
   - setting the BFINAL flag on the last block when `final == true`.

 The callback is expected to append encoded DEFLATE data to the provided
 `FlateCompressor` and may emit one or more DEFLATE blocks per call. The `final`
 argument indicates whether this call must produce the final DEFLATE block of
 the stream.

 The DEFLATE bitstream is accumulated in the compressor and finally flushed
 into an allocated buffer that is returned to the caller. The caller is
 responsible for freeing this buffer.

 Notes:
   - The `FlateCompressor` instance is initialized once and reused across all
     blocks so that streaming use cases and a continuous LZ77 history window
     could be supported.

 @param [&inout] allocator: "Allocator for compressed data."
 @param [in] bytes:         "Input data to be compressed."
 @param deflate_block:      "Callback invoked for each logical input block."
 @param max_block_len:      "Maximum number of input bytes to pass to `deflate_block`."

 @return "A newly allocated char[] containing the complete DEFLATE stream."

*>
fn char[]? deflate(Allocator allocator, char[] bytes,
	DeflateBlockFn deflate_block = &dynamic_block,
	usz max_block_len = MAX_BLOCK_SIZE) => @pool()
{
	bool final;
	usz offset, remaining, block_len;

	ByteWriter bw;
	bw.init(allocator);

	FlateCompressor c;
	c.init(&bw);

	offset = 0;
	while (offset < bytes.len)
	{
		remaining = bytes.len - offset;
		block_len = remaining > max_block_len ? max_block_len : remaining;
		final = (offset + block_len) >= bytes.len;
		deflate_block(&c, bytes[offset:block_len], final)!;
		offset += block_len;
	}

	c.writer.flush()!;

	return bw.array_view();
}

<*
 Store data uncompressed.
 See RFC 1951 Section 3.2.4
*>
fn void? store_block(FlateCompressor *c, char[] bytes, bool final)
{
	uint n = (uint)bytes.len;

	// Set non-compressed block header: Either BFINAL (0b1 or 0b0)
	// and BTYPE (0b00) for non-compressed blocks.
	c.setbits(final ? 1 : 0, 8)!;

	// Set block length.
	c.setbits(n, 16)!;
	c.setbits(~n, 16)!;

	// Write uncompressed bytes.
	for (usz i = 0; i < n; i++)
	{
		c.setbits(bytes[i], 8)!;
	}
}

<*
 Compression with dynamic Huffman codes.
 See RFC 1951 Section 3.2.7
*>
fn void? dynamic_block(FlateCompressor *c, char[] bytes, bool final) => @pool()
{
	Token[] tokens = lz77::tokenize(tmem, bytes);
	c.build_trees(tokens)!;
	c.write_dynamic_header(final)!;
	c.write_compressed_data(tokens)!;
	c.write_end_of_block()!;
}

<*
 Compression with fixed Huffman codes.
 See RFC 1951 Section 3.2.6
*>
fn void? fixed_block(FlateCompressor *c, char[] bytes, bool final) => @pool()
{
	Token[] tokens = lz77::tokenize(tmem, bytes);
	c.build_fixed_trees()!;
	c.write_fixed_header(final)!;
	c.write_compressed_data(tokens)!;
	c.write_end_of_block()!;
}

module compress::deflate::test @test;
import compress::flate;

import std;
fn void test_deflate_dynamic() => @pool()
{
	char[] bytes = "hello world world hello";
	char[] comp = flate::deflate(tmem, bytes, &flate::dynamic_block)!!;
	char[] want = x`2de8b1090000080341ace2700a160f011bd70f88cd15d7058ad590ef8d01`;
	assert(comp == want);

	char[] inflate = flate::inflate(tmem, comp)!!;
	assert(inflate == bytes, "got: '%s', want '%s'", (String)inflate, (String)bytes);
}

fn void test_flate_fixed() => @pool()
{
	char[] bytes = "hello world world hello";
	char[] fixed = flate::deflate(tmem, bytes, &flate::fixed_block)!!;
	char[] want = x`cb48cdc9c95728cf2fca498192601100`;
	assert(fixed == want);

	char[] inflate = flate::inflate(tmem, fixed)!!;
	assert(inflate == bytes, "got: '%s', want: '%s'", (String)inflate, (String)bytes);
}

fn void test_flate_store() => @pool()
{
	char[] bytes = "hello world";
	char[] non_comp = flate::deflate(tmem, bytes, &flate::store_block)!!;
	assert(non_comp.len == 1 + 2 + 2 + bytes.len);
	assert(non_comp[0] == 1);
	assert(non_comp[5..] == bytes[..]);

	char[] inflate = flate::inflate(tmem, non_comp)!!;
	assert(inflate == bytes);
}

