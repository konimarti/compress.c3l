// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;
import std::collections::list, std::io;

struct HuffSym
{
	uint[huff::MAX_BITS] counts; // Number of symbols of each lengths.
	uint[288] symbols;           // Canonically ordered symbols.
}

fn HuffSym gen_symbols(char[] lengths)
{
	uint[huff::MAX_BITS+1] offs;

	HuffSym h = {};
	foreach (len : lengths) h.counts[len]++;
	if (h.counts[0] == lengths.len) return h; // No codes.

	offs[1] = 0;
	for (int len = 1; len < huff::MAX_BITS; len++)
	{
		offs[len+1] = offs[len] + h.counts[len];
	}

	foreach (int sym, len: lengths)
	{
		if (len != 0) h.symbols[offs[len]++] = sym;
	}
	return h;
}

struct FlateDecompressor
{
	FlateReader reader;
	ByteWriter *writer;
	HuffSym ls; // Literal/Length symbols
	HuffSym ds; // Distance symbols
}

fn void FlateDecompressor.init(&self, InStream r, ByteWriter *w)
{
	self.reader.init(r);
	self.writer = w;
}

fn void FlateDecompressor.free(&self)
{
	*self = {};
}

fn uint? FlateDecompressor.getbits(&self, uint nbits) @inline
{
	return self.reader.read_bits(nbits);
}

faultdef INVALID_LENGTH;
fn void? FlateDecompressor.store_block(&self)
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

	LimitReader lr;
	lr.init(&self.reader, length);
	io::copy_to(&lr, self.writer)!;
}

fn void? FlateDecompressor.fixed_block(&self)
{
	self.ls = gen_symbols({
		[  0..143] = 8,
		[144..255] = 9,
		[256..279] = 7,
		[280..287] = 8,
	});

	self.ds = gen_symbols({[0..31] = 5});

	return self.inflate_block();
}

fn void? FlateDecompressor.dynamic_block(&self)
{
	self.decode_trees()!;
	return self.inflate_block();
}

fn void? FlateDecompressor.decode_trees(&self)
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
	HuffSym code_length = gen_symbols(lengths[:19]);

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

	self.ls = gen_symbols(lengths[0:nlit]);
	self.ds = gen_symbols(lengths[nlit:ndist]);
}

fn void? FlateDecompressor.inflate_block(&self)
{
	uint length, off;
	while (try sym = self.decode_symbol(&self.ls))
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

		if (try dist = self.decode_symbol(&self.ds))
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

fn int? FlateDecompressor.decode_symbol(&self, HuffSym *h)
{
	int code, first, count, index;
	code = 0; first = 0; index = 0;
	for (int len = 1; len <= huff::MAX_BITS; len++)
	{
		code = code << 1 + self.getbits(1)!;
		count = h.counts[len];
		if (code - count < first)
		{
			return h.symbols[index + (code - first)];
		}
		index += count;
		first += count;
		first <<= 1;
	}
	return NOT_FOUND~;
}


