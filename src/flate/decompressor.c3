// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;
import std::collections::list, std::io;

struct HuffDecompressor
{
	bitio::BitReader{char} reader;
	ByteWriter *writer;
	HuffTree lt; // Literal/Length tree
	HuffTree dt; // Distance tree
}

fn void HuffDecompressor.init(&self, InStream r, ByteWriter *w)
{
	self.reader.init(r);
	self.writer = w;
}

fn void HuffDecompressor.free(&self)
{
	*self = {};
}

fn uint? HuffDecompressor.getbits(&self, isz nbits) @inline
{
	return self.reader.read_bits(nbits);
}

faultdef INVALID_LENGTH;
fn void? HuffDecompressor.store_block(&self)
{
	self.getbits(5)!;

	// Lengths are stored in 16bits in little endian (LSB).
	uint length = self.getbits(8)! | self.getbits(8)! << 8;
	uint inv_length = self.getbits(8)! | self.getbits(8)! << 8;

	// Sanity check: compare length with the inverse.
	if (length != (~inv_length & 0x0000FFFF))
	{
		return INVALID_LENGTH~;
	}

	while (length--)
	{
		self.writer.write_byte((char)self.getbits(8)!)!;
	}

	// LimitReader lr;
	// lr.init(&self.reader, length);
	// io::copy_to(&lr, self.writer)!;
}

fn void? HuffDecompressor.fixed_block(&self)
{
	huff::generate_fixed_trees(&self.lt, &self.dt)!;
	return self.inflate_block();
}

fn void? HuffDecompressor.dynamic_block(&self)
{
	self.decode_trees()!;
	return self.inflate_block();
}

fn void? HuffDecompressor.decode_trees(&self)
{
	char[288 + 32] lengths;
	uint nlit, ndist, nclen;
	int sym, len;

	nlit = self.getbits(5)! + 257;
	ndist = self.getbits(5)! + 1;
	nclen = self.getbits(4)! + 4;

	// Read bit lengths for code length codes.
	lengths[:19] = 0;
	for (usz i = 0; i < nclen; i++)
	{
		lengths[hc_order[i]] = (char)self.getbits(3)!;
	}

	// Build code length tree.
	HuffTree code_length =
		huff::generate_from_lengths(lengths[:19])!;

	lengths[:19] = 0;
	// Decode code length for the dynamic trees.
	for (uint num = 0; num < nlit + ndist;)
	{
		len = 1;
		sym = self.decode_symbol(&code_length)!!;
		switch (sym)
		{
			case 16:
				sym = lengths[num-1];
				len = self.getbits(2)! + 3;
			case 17:
				sym = 0;
				len = self.getbits(3)! + 3;
			case 18:
				sym = 0;
				len = self.getbits(7)! + 11;
		}
		while (len--) lengths[num++] = (char)sym;
	}

	self.lt = huff::generate_from_lengths(lengths[0:nlit])!;
	self.dt = huff::generate_from_lengths(lengths[nlit:ndist])!;
}

fn void? HuffDecompressor.inflate_block(&self)
{
	uint length, off;
	while (try sym = self.decode_symbol(&self.lt))
	{
		if (sym < END_OF_BLOCK)
		{
			self.writer.write_byte((char)sym)!;
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
			char[] out = self.writer.array_view();
			self.writer.write_byte(out[^off])!;
		}
	}
}

fn int? HuffDecompressor.decode_symbol(&self, HuffTree *tree)
{
	uint code = 0;
	for (int len = 1; len <= huff::MAX_BITS; len++)
	{
		code = code << 1 + self.getbits(1)!;
		foreach (int i, bits: tree.blen)
		{
			if (bits != len) continue;
			if (code != tree.codes[i]) continue;
			return i;
		}
	}
	return NOT_FOUND~;
}

