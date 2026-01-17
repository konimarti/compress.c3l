// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;
import std::collections::list;

const END_OF_BLOCK = 256;

struct HuffCompressor
{
	BitStream{char} stream;
	HuffTree lt; // Literal/Length tree
	HuffTree dt; // Distance tree
}

fn void HuffCompressor.init(&self, Allocator allocator)
{
	self.stream.init(allocator);
}

fn void? HuffCompressor.build_trees(&self, Token[] tokens)
{
	// Calculate literal, length and distance frequencies.
	uint[288] lt_freqs;
	uint[30] dt_freqs;
	usz idx;
	foreach (token: tokens)
	{
		switch (token.type)
		{
			case LITERAL:
				lt_freqs[token.lit]++;
			case MATCH:
				idx = huff_index_lookup(&len_base, token.length())!;
				lt_freqs[257+idx]++;
				idx = huff_index_lookup(&dist_base, token.offset())!;
				dt_freqs[idx]++;
			default:
				unreachable("invalid token encountered");
		}
	}

 	// Don't forget the end of block marker.
	lt_freqs[END_OF_BLOCK]++;

	@pool()
	{
		self.lt = huff::make_tree(&lt_freqs)!;
		self.dt = huff::make_tree(&dt_freqs)!;
	};

}

fn void? HuffCompressor.write_dynamic_header(&self, bool final = true) => @pool()
{
	uint i, hlit, hdist, hclen;

	// Create run-length codes.
	uint[*] rl_freqs = {
		[0..18] = 0,
	};
	foreach (len: self.lt.blen)
	{
		if (hc_order[len] > hclen) hclen = hc_order[len];
		rl_freqs[len]++;
	}
	foreach (len: self.dt.blen)
	{
		if (hc_order[len] > hclen) hclen = hc_order[len];
		rl_freqs[len]++;
	}

	HuffTree rl = huff::make_tree(&rl_freqs, 5)!;

	// Write dynamic block header.
	// Push BFINAL (0b1 or 0b0) and BTYPE (0b10).
	self.stream.write(final ? 1 : 0, 1);
	self.stream.write(0b10, 2);

	// Write 5 bits HLIT (# of literal/length codes - 257)
	hlit = (self.lt.max_sym < 257) ? 0 : self.lt.max_sym + 1 - 257;
	assert(hlit <= 31);
	self.stream.write(hlit, 5);

	// Write 5 bits HDIST (# of distance codes - 1)
	hdist = self.dt.max_sym;
	assert(hdist+1 > 0 && hdist < 30);
	self.stream.write(hdist, 5);

	// Push 4 bits HCLEN (# of code length codes - 4)
	assert(hclen >= 4);
	hclen -= 4;
	self.stream.write(hclen, 4);

	for (i = 0; i < hclen + 4; i++)
	{
		self.stream.write(rl.blen[hc_order[i]], 3);
	}

	// TODO: Repetitions in sequence should be encoded with 16, 17, 18
	List{char} seq;
	seq.tinit((usz)(hlit + hdist + 258));
	seq.push_all(self.lt.blen[0:hlit+257]);
	seq.push_all(self.dt.blen[0:hdist+1]);
	foreach (len: seq)
	{
		self.stream.write(rl.codes[len], rl.blen[len]);
	}
}

fn void? HuffCompressor.write_compressed_data(&self, Token[] tokens)
{
	foreach (token: tokens)
	{
		switch (token.type)
		{
			case LITERAL: self.write_literal(token.lit);
			case MATCH:   self.write_match(token.length(), token.offset())!;
			default: unreachable("invalid token type encountered");
		}
	}
}

fn void HuffCompressor.write_distance(&self, usz l)
{
	char len = self.dt.blen[l];
	uint code = self.dt.codes[l];
	self.stream.write(code, len);
}

fn void HuffCompressor.write_literal(&self, usz c)
{
	char len = self.lt.blen[c];
	uint code = self.lt.codes[c];
	self.stream.write(code, len);
}

fn void HuffCompressor.write_end_of_block(&self)
{
	self.write_literal(END_OF_BLOCK);
}

fn void? HuffCompressor.write_match(&self, ushort len, uint dist)
{
	usz idx;

	// Write length code.
	idx = huff_index_lookup(&len_base, len)!;
	self.write_literal(idx+257);

	// Write extra bit.
	if (len_extra[idx])
	{
		self.stream.write(len-len_base[idx], len_extra[idx]);
	}

	// Write distance code.
	idx = huff_index_lookup(&dist_base, dist)!;
	self.write_distance(idx);

	// Write extra bit.
	if (dist_extra[idx])
	{
		self.stream.write(dist-dist_base[idx], dist_extra[idx]);
	}
}

// Create code-length Huff codes
char[*] hc_order = {
	16, 17, 18,  0,  8,
	 7,  9,  6, 10,  5,
	11,  4, 12,  3, 13,
	 2, 14,  1, 15,
 };

<* Lengths base values *>
uint[*] len_base = {
	3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17,
	19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
	99, 115, 131, 163, 195, 227, 258,
};

<* Extra bits for lengths. *>
char[*] len_extra = {
	0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1,
	2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
	5, 5, 5, 5, 0,
};

<* Distance base values *>
uint[*] dist_base = {
	1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97,
	129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
	4097, 6145, 8193, 12289, 16385, 24577,
	32768 /* range end marker */,
};

<* Extra bits for distance. *>
char[*] dist_extra = {
	0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4,
	5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
	11, 11, 12, 12, 13, 13,
};

<*
 Returns the index for the the value v in the provided set of base values.
*>
fn usz? huff_index_lookup(uint[] base, uint off)
{
	for (usz i = 0; i < base.len - 1; i++)
	{
		if (off < base[i+1]) return i;
	}
	return NOT_FOUND?;
}

