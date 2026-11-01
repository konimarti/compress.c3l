// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
<*
 This module implements the DEFLATE compression and decompression algorithm
 specified in RFC 1951.

 For normal use, call compress()/uncompress(); deflate()/inflate() are
 lower-level entry points with more control over block handling.
*>
module compress::flate;
import std::io;

<*
 Compresses the given input using the DEFLATE format (RFC 1951).  compress
 selects an appropriate block strategy (stored vs. compressed) based on the
 input and returns a single DEFLATE stream. The caller owns the returned buffer
 and must free it using the same allocator.
*>
fn char[]? compress(Allocator allocator, char[] bytes) @inline
{
	return deflate(allocator, bytes);
}

<*
 Convenience wrapper around compress() using the temporary allocator.
*>
fn char[]? tcompress(char[] bytes) @inline => compress(tmem, bytes);

<*
 Decompresses a complete DEFLATE stream into a newly allocated buffer.

 uncompress() validates block headers and reconstructs the original
 uncompressed data. The caller owns the returned buffer and must free it using
 the same allocator.
*>
fn char[]? uncompress(Allocator allocator, char[] bytes) @inline => inflate(allocator, bytes);

<*
 Convenience wrapper around uncompress() using the temporary allocator.
*>
fn char[]? tuncompress(char[] bytes) @inline => inflate(tmem, bytes);

<*
 deflate() compresses the input into a complete DEFLATE stream.

 With the default DeflateMode AUTO every block is emitted as stored, fixed or
 dynamic Huffman coding, whichever is smallest. Pass STORED, FIXED or DYNAMIC
 to force one coding for all blocks.

 @param [&inout] allocator : "Allocator for compressed data."
 @param [in] bytes         : "Input data to be compressed."
 @param mode               : "Block coding strategy."
 @return "A newly allocated char[] containing the complete DEFLATE stream."
*>
fn char[]? deflate(Allocator allocator, char[] bytes, DeflateMode mode = AUTO) => @pool()
{
	ByteWriter out;
	out.init(allocator);
	deflate_fast(&out, bytes, mode)!;
	return out.array_view();
}

<*
 Like deflate(), but writes the compressed stream to out.
*>
fn void? deflate_stream(OutStream out, char[] bytes, DeflateMode mode = AUTO) => deflate_fast(out, bytes, mode);

<*
 Parses a complete DEFLATE stream, handling stored, fixed Huffman, and
 dynamic Huffman blocks. Blocks are processed sequentially until a block
 with BFINAL = 1 is encountered or an error is detected. On success, the
 function returns a newly allocated buffer containing all uncompressed
 bytes.

 @param [&inout] allocator : "Allocator for uncompressed data."
 @param [in] bytes         : "Input data to be decompressed."
 @return? INVALID_BLOCK_TYPE, INVALID_LENGTH, INVALID_CODE, INVALID_DISTANCE, TRUNCATED_INPUT
*>
fn char[]? inflate(Allocator allocator, char[] bytes)
{
	Inflater inf = { .src = bytes, .allocator = allocator };
	return inf.run();
}

<*
 Like inflate(), but reads from a stream and consumes exactly the bytes of
 the DEFLATE stream, leaving the stream positioned right after it.
*>
fn char[]? inflate_stream(Allocator allocator, InStream stream)
{
	if (try br = anycast(stream, ByteReader))
	{
		Inflater inf = { .src = br.bytes[br.index..], .allocator = allocator };
		char[]? out = inf.run();
		// Give back the whole bytes that were buffered but not used.
		inf.pos -= inf.nbits / 8;
		br.index += (sz)inf.pos;
		return out;
	}
	Inflater inf = { .stream = stream, .exact = true, .allocator = allocator };
	return inf.run();
}

module compress::deflate::test @test;
import compress::flate;

import std;
fn void test_deflate_dynamic() => @pool()
{
	char[] bytes = "hello world world hello";
	char[] comp = flate::deflate(tmem, bytes, DYNAMIC)!!;

	char[] inflate = flate::inflate(tmem, comp)!!;
	assert(inflate == bytes, "got: '%s', want '%s'", (String)inflate, (String)bytes);
}

fn void test_flate_fixed() => @pool()
{
	char[] bytes = "hello world world hello";
	char[] fixed = flate::deflate(tmem, bytes, FIXED)!!;

	char[] inflate = flate::inflate(tmem, fixed)!!;
	assert(inflate == bytes, "got: '%s', want: '%s'", (String)inflate, (String)bytes);
}

fn void test_flate_store() => @pool()
{
	char[] bytes = "hello world";
	char[] non_comp = flate::deflate(tmem, bytes, STORED)!!;
	assert(non_comp.len == 1 + 2 + 2 + bytes.len);
	assert(non_comp[0] == 1);
	assert(non_comp[5..] == bytes[..]);

	char[] inflate = flate::inflate(tmem, non_comp)!!;
	assert(inflate == bytes);
}

fn void test_deflate_embedded_stream() => @pool()
{
	String base = "This is a streaming test for DEFLATE. ";

	char[] compressed = flate::compress(mem, base[..])!!;
	defer free(compressed.ptr);

	usz append_len = compressed.len + 1;
	char[] append = mem::malloc((sz)append_len)[:append_len];
	defer free(append.ptr);

	append[:compressed.len] = compressed[..];
	append[^1] = 'c';

	ByteReader reader;
	reader.init(append);

	char[] uncompressed = flate::inflate_stream(tmem, &reader)!!;
	assert((String)uncompressed[..] == base);

	assert(reader.read_byte()!! == 'c');
}

