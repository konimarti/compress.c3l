// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;
import std::collections::list, std::io;

const END_OF_BLOCK = 256;

struct FlateCompressor
{
	FlateWriter writer;
	HuffTree lt; // Literal/Length tree
	HuffTree dt; // Distance tree
}

fn void FlateCompressor.init(&self, OutStream wrapped)
{
	self.writer.init(wrapped);
}

fn void? FlateCompressor.setbits(&self, uint bits, uint nbits) @inline
{
	self.writer.write_bits(bits, nbits)!;
}

fn void? FlateCompressor.build_trees(&self, Token[] tokens)
{
	// Calculate literal, length and distance frequencies.
	uint[288] lt_freqs;
	uint[30] dt_freqs;
	usz i;
	foreach (token: tokens)
	{
		switch (token.type)
		{
			case LITERAL:
				// Overflow check.
				if (lt_freqs[token.lit] == uint.max) continue;
				lt_freqs[token.lit]++;

			case MATCH:
				i = huff_index_lookup(&len_base, token.length());
				if (lt_freqs[257+i] == uint.max) continue;
				lt_freqs[257+i]++;

				i = huff_index_lookup(&dist_base, token.offset());
				if (dt_freqs[i] == uint.max) continue;
				dt_freqs[i]++;

			default:
				unreachable("invalid token encountered");
		}
	}

 	// Don't forget the end of block marker.
	lt_freqs[END_OF_BLOCK]++;

	// Generate Huffman codes
	self.lt = huff::generate(&lt_freqs, reverse: true)!;
	self.dt = huff::generate(&dt_freqs, reverse: true)!;
}

struct CodeLengthEncoder
{
	ByteWriter enc;
	HuffTree ct;
	int max_sym;
}

fn void CodeLengthEncoder.init(&self, Allocator allocator)
{
	self.enc.init(allocator);
	self.ct = {};
	self.max_sym = -1;
}

fn void CodeLengthEncoder.free(&self)
{
	(void)self.enc.destroy();
}

<*
 Encode literal/length and distance bit lengths and return a Huffman tree.
*>
fn void? CodeLengthEncoder.encode(&self, char[] lt_len, char[] dt_len)
{
	usz i, n;
	char sym;
	uint[19] freqs;

	n = lt_len.len + dt_len.len;
	self.enc.ensure_capacity(n)!;
	@pool()
	{
		// Combine literal/length and distance code lengths.
		char[] lengths = mem::temp_array(char, n);
		lengths[:lt_len.len] = lt_len[:lt_len.len];
		lengths[lt_len.len:dt_len.len] = dt_len[:dt_len.len];

		// Encode the code lengths.
		encode_code_lengths(&self.enc, lengths)!;
	};

	// Calculate frequencies of the encoded code lengths.
	char[] enc = self.enc.array_view();
	self.max_sym = -1;
	i = 0;
	while (i < enc.len)
	{
		sym = enc[i++];
		if (sym > 15) i++; // Skip extra bits for symbols 16,17,18
		if (hc_order[sym] > self.max_sym) self.max_sym = hc_order[sym];
		freqs[sym]++;
	}

	assert(self.max_sym >= 0);

	self.ct = huff::generate(freqs[..], 5, reverse: true)!;
}

fn void? encode_code_lengths(ByteWriter *enc, char[] seq) @private => @pool()
{
	usz i, r, rem;
	while (i < seq.len)
	{
		char sym = seq[i]; // Code length symbol.
		assert(sym < huff::MAX_BITS);

		// Count repetitions of length len.
		r = 1;
		while (i+r < seq.len && seq[i+r] == sym) r++;
		switch
		{
			case (sym != 0 && r <= 3) || (sym == 0 && r < 3):
				rem = r;
				while (rem--) enc.write_byte(sym)!;
				i += r;
			case sym != 0 && r > 3:
				enc.write_byte(sym)!;
				i++; r--;
				while (r > 2)
				{
					rem = r > 6 ? 6 : r;
					enc.write_byte(16)!;
					enc.write_byte((char)rem-3)!;
					r -= rem;
					i += rem;
				}
			case sym == 0 && r >= 3 && r < 11:
				enc.write_byte(17)!;
				enc.write_byte((char)r-3)!;
				i += r;
			case sym == 0 && r >= 11:
				while (r > 10)
				{
					rem = r > 138 ? 138 : r;
					enc.write_byte(18)!;
					enc.write_byte((char)rem-11)!;
					r -= rem;
					i += rem;
				}
			default: unreachable("internal error");
		}
	}
}

struct CodeLengthTestCase @private
{
	char[] input;
	char[] want;
}

fn void test_encode_code_lengths() @test => @pool()
{
	CodeLengthTestCase[*] tests = {
		{
			.input = {1,2,3,4},
			.want  = {1,2,3,4},
		},
		{
			.input = {1,1},
			.want  = {1,1},
		},
		{
			.input = {1,1,1},
			.want  = {1,1,1},
		},
		{
			.input = {1,1,1,1},
			.want  = {1,16,0},
		},
		{
			.input = {1,1,1,1,1,1,1},
			.want  = {1,16,3},
		},
		{
			.input = {1,1,1,1,1,1,1,1},
			.want  = {1,16,3,1},
		},
		{
			.input = {0,0},
			.want  = {0,0},
		},
		{
			.input = {0,0,0},
			.want  = {17,0},
		},
		{
			.input = {0,0,0,0,0},
			.want  = {17,2},
		},
		{
			.input = {[9]=0},
			.want  = {17,7},
		},
		{
			.input = {[10]=0},
			.want  = {18,0},
		},
		{
			.input = {[11]=0},
			.want  = {18,1},
		},
		{
			.input = {[137]=0},
			.want  = {18,127},
		},
		{
			.input = {[138]=0},
			.want  = {18,127,0},
		},
	};

	foreach (j, test: tests)
	{
		ByteWriter bw;
		bw.tinit();
		encode_code_lengths(&bw, test.input)!!;
		char[] enc = bw.array_view();
		test::eq(enc.len, test.want.len);
		foreach (i, got: enc)
		{
			test::eq(got, test.want[i]);
		}
	}
}

fn void? FlateCompressor.write_dynamic_header(&self, bool final = true) => @pool()
{
	char sym;
	uint i, hlit, hdist, hclen;

	hlit = (self.lt.max_sym < 257) ? 0 : self.lt.max_sym + 1 - 257;
	hdist = self.dt.max_sym;

	// Create run-length encoder.
	CodeLengthEncoder encoder;
	encoder.init(tmem);
	encoder.encode(self.lt.blen[:hlit+257], self.dt.blen[:hdist+1])!;

	hclen = encoder.max_sym + 1 - 4;

	// Write dynamic block header.
	// Push BFINAL (0b1 or 0b0) and BTYPE (0b10).
	self.setbits(final ? 1 : 0, 1)!;
	self.setbits(0b10, 2)!;

	// Write 5 bits HLIT (# of literal/length codes - 257)
	assert(hlit <= 31);
	self.setbits(hlit, 5)!;

	// Write 5 bits HDIST (# of distance codes - 1)
	assert(hdist+1 > 0 && hdist < 30);
	self.setbits(hdist, 5)!;

	// Push 4 bits HCLEN (# of code length codes - 4)
	assert(hclen >= 4);
	self.setbits(hclen, 4)!;

	for (i = 0; i < hclen + 4; i++)
	{
		self.setbits(encoder.ct.blen[hc_order[i]], 3)!;
	}

	// Write encoded code length.
	char[] enc = encoder.enc.array_view();
	for (i = 0; i < enc.len; )
	{
		sym = enc[i++];
		self.setbits(encoder.ct.codes[sym], encoder.ct.blen[sym])!;
		switch (sym)
		{
			case 16: self.setbits(enc[i++], 2)!;
			case 17: self.setbits(enc[i++], 3)!;
			case 18: self.setbits(enc[i++], 7)!;
		}
	}

}

fn void? FlateCompressor.build_fixed_trees(&self)
{
	huff::generate_fixed_trees(&self.lt, &self.dt, reverse: true)!;
}

fn void? FlateCompressor.write_fixed_header(&self, bool final = true) => @pool()
{
	// Write fixed block header.
	// Push BFINAL (0b1 or 0b0) and BTYPE (0b01).
	self.setbits(final ? 1 : 0, 1)!;
	self.setbits(0b01, 2)!;
}


fn void? FlateCompressor.write_compressed_data(&self, Token[] tokens)
{
	foreach (token: tokens)
	{
		switch (token.type)
		{
			case LITERAL: self.write_literal(token.lit)!;
			case MATCH:   self.write_match(token.length(), token.offset())!;
			default: unreachable("invalid token type encountered");
		}
	}
}

fn void? FlateCompressor.write_distance(&self, usz l) @inline
{
	char len = self.dt.blen[l];
	uint code = self.dt.codes[l];
	self.setbits(code, len)!;
}

fn void? FlateCompressor.write_literal(&self, usz c) @inline
{
	char len = self.lt.blen[c];
	uint code = self.lt.codes[c];
	self.setbits(code, len)!;
}

fn void? FlateCompressor.write_end_of_block(&self) @inline
{
	self.write_literal(END_OF_BLOCK)!;
}

fn void? FlateCompressor.write_match(&self, uint len, uint dist)
{
	usz i;

	// Write length code.
	i = huff_index_lookup(&len_base, len);
	self.write_literal(i+257)!;

	// Write extra bit.
	if (len_extra[i])
	{
		self.setbits(len-len_base[i], len_extra[i])!;
	}

	// Write distance code.
	i = huff_index_lookup(&dist_base, dist);
	self.write_distance(i)!;

	// Write extra bit.
	if (dist_extra[i])
	{
		self.setbits(dist-dist_base[i], dist_extra[i])!;
	}
}

// Create code-length Huff codes
char[*] hc_order = {
	16, 17, 18,  0,  8, 7,  9,  6, 10,  5,
	11,  4, 12,  3, 13, 2, 14,  1, 15,
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
fn usz huff_index_lookup(uint[] base, uint v) @inline
{
	usz i;
	while (i < base.len - 1)
	{
		if (v < base[i+1]) break;
		i++;
	}
	return i;
}

