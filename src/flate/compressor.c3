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

struct CodeLength
{
	char len;   // Code lengths [0..18]
	char extra; // Extra bits (depening on code length code)
}
alias CodeLengthList = List{CodeLength};

struct CodeLengthEncoder
{
	CodeLength[] enc;
	HuffTree ct;
	int max_sym;
}

fn void? CodeLengthEncoder.init(&self, Allocator allocator, char[] lt_len, char[] dt_len) => @pool()
{
	usz i, n;
	char[] seq;

	// Combine literal/length and distance code lengths.
	n = lt_len.len + dt_len.len;
	seq = mem::temp_array(char, n);
	foreach (len: lt_len) seq[i++] = len;
	foreach (len: dt_len) seq[i++] = len;

	// Encode the code lengths.
	CodeLengthList enc;
	enc.tinit(); // Allocate a bit more than necessary
	encode_code_lengths(&enc, seq);
	self.enc = enc.to_array(allocator);

	// Calculate frequencies of the encoded code lengths.
	self.max_sym = -1;
	uint[19] freqs;
	foreach (cl: self.enc)
	{
		assert(cl.len < 19);
		freqs[cl.len]++;
		if (hc_order[cl.len] > self.max_sym)
		{
			self.max_sym = hc_order[cl.len];
		}
	}
	assert(self.max_sym >= 0);

	// Create code length codes.
	self.ct = huff::make_tree(freqs[..], 5)!;
}

fn void encode_code_lengths(CodeLengthList *cl, char[] seq)
{
	usz r, rem;
	for (usz i = 0; i < seq.len;)
	{
		assert(seq[i] < huff::MAX_BITS);
		char len = seq[i];

		// Count repetitions of length len.
		r = 1;
		while (i+r < seq.len && seq[(usz)(i+r)] == len) r++;

		if (len == 0)
		{
			// Encode code length 0 with r repetitions.
			switch
			{
				case r < 3:
					while (r--)
					{
						cl.push({len, 0});
						i++;
					}
				case r >= 3 && r < 11:
					cl.push({17, (char)r - 3});
					i += r;
				case r >= 11:
					while (r > 10)
					{
						rem = r > 138 ? 138 : r;
						cl.push({18, (char)rem - 11});
						r -= rem;
						i += rem;
					}
			}
		}
		else
		{
			// Encode code length != 0 with r repetitions.
			if (r > 3)
			{
				// Emit code length.
				cl.push({len, 0});
				i++; r--;

				// Emit code 16.
				while (r > 2)
				{
					rem = r > 6 ? 6 : r;
					cl.push({16, (char)rem - 3});
					r -= rem;
					i += rem;
				}
			}
			else
			{
				// Emit code lengths.
				while (r--)
				{
					cl.push({len, 0});
					i++;
				}
			}
		}
	}
}

struct CodeLengthTestCase
{
	char[] input;
	CodeLength[] want;
}

fn void test_code_length_encoding() @test => @pool()
{
	CodeLengthTestCase[*] tests = {
		{
			.input = {1,2,3,4},
			.want = {{1,0},{2,0},{3,0},{4,0}},
		},
		{
			.input = {1,1},
			.want = {{1,0},{1,0}},
		},
		{
			.input = {1,1,1},
			.want = {{1,0},{1,0},{1,0}},
		},
		{
			.input = {1,1,1,1},
			.want = {{1,0},{16,0}},
		},
		{
			.input = {1,1,1,1,1,1,1},
			.want = {{1,0},{16,3}},
		},
		{
			.input = {1,1,1,1,1,1,1,1},
			.want = {{1,0},{16,3},{1,0}},
		},
		{
			.input = {0,0},
			.want = {{0,0},{0,0}},
		},
		{
			.input = {0,0,0},
			.want = {{17,0}},
		},
		{
			.input = {0,0,0,0,0},
			.want = {{17,2}},
		},
		{
			.input = {[9]=0},
			.want = {{17,7}},
		},
		{
			.input = {[10]=0},
			.want = {{18,0}},
		},
		{
			.input = {[11]=0},
			.want = {{18,1}},
		},
		{
			.input = {[137]=0},
			.want = {{18,127}},
		},
		{
			.input = {[138]=0},
			.want = {{18,127},{0,0}},
		},
	};

	foreach (j, test: tests)
	{
		CodeLengthList enc;
		encode_code_lengths(&enc, test.input);
		test::eq(enc.len(), test.want.len);
		foreach (i, got: enc)
		{
			test::eq(got.len, test.want[i].len);
			test::eq(got.extra, test.want[i].extra);
		}
	}
}


fn void? HuffCompressor.write_dynamic_header(&self, bool final = true) => @pool()
{
	uint i, hlit, hdist, hclen;

	hlit = (self.lt.max_sym < 257) ? 0 : self.lt.max_sym + 1 - 257;
	hdist = self.dt.max_sym;

	// Create run-length codes.
	CodeLengthEncoder cle;
	cle.init(tmem, self.lt.blen[:hlit+257], self.dt.blen[:hdist+1])!;
	hclen = cle.max_sym + 1 - 4;

	// Write dynamic block header.
	// Push BFINAL (0b1 or 0b0) and BTYPE (0b10).
	self.stream.write(final ? 1 : 0, 1);
	self.stream.write(0b10, 2);

	// Write 5 bits HLIT (# of literal/length codes - 257)
	assert(hlit <= 31);
	self.stream.write(hlit, 5);

	// Write 5 bits HDIST (# of distance codes - 1)
	assert(hdist+1 > 0 && hdist < 30);
	self.stream.write(hdist, 5);

	// Push 4 bits HCLEN (# of code length codes - 4)
	assert(hclen >= 4);
	self.stream.write(hclen, 4);

	for (i = 0; i < hclen + 4; i++)
	{
		self.stream.write(cle.ct.blen[hc_order[i]], 3);
	}

	// Write encoded code length.
	foreach (c: cle.enc)
	{
		self.stream.write(cle.ct.codes[c.len], cle.ct.blen[c.len]);
		switch (c.len)
		{
			case 16: self.stream.write(c.extra, 2);
			case 17: self.stream.write(c.extra, 3);
			case 18: self.stream.write(c.extra, 7);
		}
	}

}

fn void? HuffCompressor.build_fixed_trees(&self)
{
	self.lt = huff::make_tree_from_lengths({
		[  0..143] = 8,
		[144..255] = 9,
		[256..279] = 7,
		[280..287] = 8,
	})!;
	self.dt = huff::make_tree_from_lengths({
		[0..31] = 5,
	})!;
}

fn void? HuffCompressor.write_fixed_header(&self, bool final = true) => @pool()
{
	// Write fixed block header.
	// Push BFINAL (0b1 or 0b0) and BTYPE (0b01).
	self.stream.write(final ? 1 : 0, 1);
	self.stream.write(0b01, 2);
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

