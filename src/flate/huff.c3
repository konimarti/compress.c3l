// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate::huff;

import std::bits, compress::flate::pkgmerge;

const MAX_BITS = 16;

faultdef ERR_CODEGEN;

struct HuffTree
{
	char[288] blen;
	uint[288] codes;
	int max_sym;
}

<*
 Reverses the bit ordering in the codes which is useful for data compression
 step. This is not necessary for decompression.
*>
fn void HuffTree.reverse(&self)
{
	foreach (i, &code: self.codes)
	{
		if (self.blen[i] == 0) continue;
		uint shift = $typeof(*code).sizeof * 8 - self.blen[i];
		*code = bits::reverse(*code << shift);
	}
}

<*
 Gernate a Huffman tree from symbol frequencies.

 @require freqs.len <= 288 : "Cannot be larger than 288"
*>
fn HuffTree? generate(uint[] freqs, uint max_bits = MAX_BITS, bool reverse = false) => @pool()
{
	char[] codelen = pkgmerge::codelen(tmem, freqs, max_bits);
	return generate_from_lengths(codelen: codelen, reverse: reverse);
}

<*
 Make a Huffman tree from code lengths.

 @require codelen.len <= 288 : "Cannot be larger than 288"
*>
fn HuffTree? generate_from_lengths(char[] codelen, bool reverse = false)
{
	HuffTree h;
	h.blen[:codelen.len] = codelen[..];
	h.max_sym = canonical_codes(&h.codes, &h.blen)!;
	if (reverse) h.reverse();
	return h;
}

<*
 Generate canonical Huffman codes according to RFC section 3.2.2.

 @param [out] codes : "Canonical Huffman codes."
 @param [in] blen   : "Bit lengths for Huffman codes"
 @return "Max symbol for generated Huffman codes."
*>
fn int? canonical_codes(uint[] codes, char[] blen)
{
	uint[16] bl_count, next_code;
	int max_sym = -1;

	foreach (len: blen)
	{
		assert(len < 16, "got: %d", len);
		bl_count[len]++;
	}

	if (bl_count[0] == blen.len) return 0;
	bl_count[0] = 0;

	uint code = 0;
	for (uint bits = 1; bits <= MAX_BITS; bits++)
	{
	        code = (code + bl_count[bits-1]) << 1;
		next_code[bits-1] = code;
	}

	foreach (int i, len: blen)
	{
		if (len == 0) continue;
		codes[i] = next_code[len-1];
		next_code[len-1]++;
		max_sym = i;
	}
	if (max_sym < 0) return ERR_CODEGEN~;
	return max_sym;
}

fn void test_huff_codegen() @test
{
	char[4] blen = { 2, 1, 3, 3 };
	uint[4] want= { 0b10, 0b0, 0b110, 0b111 };
	uint[4] codes;
	assert(canonical_codes(&codes, &blen)!! == 3);
	assert(codes == want);
}


<*
 Fixed Huffman code trees according to RFC 1951.
*>
fn void? generate_fixed_trees(HuffTree *lt, HuffTree *dt, bool reverse = false)
{
	*lt = huff::generate_from_lengths({
		[  0..143] = 8,
		[144..255] = 9,
		[256..279] = 7,
		[280..287] = 8,
	})!;

	*dt = huff::generate_from_lengths({
		[0..31] = 5,
	})!;

	if (reverse)
	{
		lt.reverse();
		dt.reverse();
	}
}
