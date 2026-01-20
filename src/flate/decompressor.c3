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
	huff::generate_fixed_trees(&self.lt, &self.dt)!;
	return self.inflate_block();
}

fn void? HuffDecompressor.dynamic_block(&self)
{
}

fn void? HuffDecompressor.inflate_block(&self)
{
	uint length, off;
	while (try sym = self.decode_symbol(&self.lt))
	{
		if (sym < END_OF_BLOCK)
		{
			self.out.push((char)sym);
			continue;
		}
		if (sym == END_OF_BLOCK) break;

		sym -= 257;

		length = len_base[sym];
		if (len_extra[sym])
		{
			length += self.getbits(len_extra[sym])!;
		}

		if (try dist = self.decode_symbol(&self.dt))
		{
			off = dist_base[dist];
			if (dist_extra[dist])
			{
				off += self.getbits(dist_extra[dist])!;
			}
		}

		for (usz i = 0; i < length; i++)
		{
			usz n = self.out.len() - off;
			char b = self.out.array_view()[n];
			self.out.push(b);
		}
	}
}

fn int? HuffDecompressor.decode_symbol(&self, HuffTree *tree) => @pool()
{
	uint code = 0;
	for (int len = 1; len < huff::MAX_BITS; len++)
	{
		code = code << 1 + self.getbits(1)!;
		foreach (int i, bits: tree.blen)
		{
			if (bits != len) continue;
			uint tcode = bits::reverse(tree.codes[i]) >> (32 - bits);
			if (code != tcode) continue;
			// io::printfn("symbol found: %c", i);
			return i;
		}
	}
	return NOT_FOUND?;
}

