// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;

fn char[]? compress(Allocator allocator, char[] bytes)
{
	if (bytes.len < 32)
	{
		return deflate_non_compressed_blocks(allocator, bytes);
	}
	// return deflate_dynamic_block(allocator, bytes);
	return {};
}
fn char[]? tcompress(char[] bytes) @inline => compress(tmem, bytes);

fn char[]? uncompress(Allocator allocator, char[] bytes)
{
	unreachable("To be implemented soon.");
}
fn char[]? tuncompress(char[] bytes) @inline => uncompress(tmem, bytes);


const MAX_BLOCK_SIZE = 65_535;

<*
 Write header for the non-compressed blocks, split the input data into chunks
 of MAX_BLOCK_SIZE bytes. See RFC 1951 Section 3.2.4
*>
fn char[]? deflate_non_compressed_blocks(Allocator allocator, char[] bytes)
{
	bool final;
	uint offset, remaining, block_len;

	BitStream{char} stream;
	stream.tinit();

	offset = 0;
	while (offset < bytes.len)
	{
		remaining = bytes.len - offset;
		block_len = remaining > MAX_BLOCK_SIZE ? MAX_BLOCK_SIZE : remaining;
		final = (offset + block_len) >= (uint)bytes.len;

		deflate_non_compressed_block(&stream, final, block_len,
			bytes[offset:block_len]);

		offset += block_len;
	}

	return stream.flush(allocator, true)!;
}

fn void deflate_non_compressed_block(BitStream{char} *stream, bool final,
	uint block_len, char[] bytes)
{
	// Set non-compressed block header: Either BFINAL (0b1 or 0b0)
	// and BTYPE (0b00) for non-compressed blocks.
	stream.write(final ? 1 : 0, 8);

	// Set block length.
	stream.write(block_len, 16);
	stream.write(~block_len, 16);

	// Write uncompressed bytes.
	for (usz i = 0; i < block_len; i++)
	{
		stream.write(bytes[i], 8);
	}
}

fn void test_deflate_non_compressed_blocks() @test => @pool()
{
	char[] bytes = "hello world";
	char[] uncompressed = deflate_non_compressed_blocks(tmem, bytes)!!;
	assert(uncompressed.len == 1+2+2+bytes.len);
	assert(uncompressed[0] == 1);
	assert(uncompressed[5..] == bytes[..]);
}
