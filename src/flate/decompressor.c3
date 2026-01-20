// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;
import std::collections::list;

struct HuffDecompressor
{
	bitio::BitReader{char} stream;
	List{char} out;
	HuffTree lt; // Literal/Length tree
	HuffTree dt; // Distance tree
}

fn void HuffDecompressor.init(&self, Allocator allocator, char[] bytes)
{
	self.stream.init(allocator, bytes);
	self.out.init(allocator);
}

fn void HuffDecompressor.free(&self)
{
	self.free();
	*self = {};
}

fn uint? HuffDecompressor.getbits(&self, isz nbits)
{
	return self.stream.read(nbits);
}

import std;
faultdef INVALID_LENGTH;
fn void? HuffDecompressor.store_block(&self)
{
	assert(self.getbits(5)! == 0);
	assert(self.stream.bitpos == 0);

	// Lengths are stored in 16bits in little endian (LSB).
	uint length = self.getbits(8)! | self.getbits(8)!! << 8;
	uint inv_length = self.getbits(8)! | self.getbits(8)!! << 8;

	// Sanity check: compare length with the inverse.
	if (length != (~inv_length & 0x0000FFFF))
	{
		return INVALID_LENGTH?;
	}

	// Copy `length` bytes to `out`.
	while (length--)
	{
		self.out.push(self.stream.pop_first())!;
	}
}

fn void? HuffDecompressor.fixed_block(&self)
{
}

fn void? HuffDecompressor.dynamic_block(&self)
{
}

