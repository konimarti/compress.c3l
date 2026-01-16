// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate::huff;

import std::bits;

const MAX_BITS = 16;

faultdef ERR_CODEGEN;

struct HuffTree
{
	char[288] blen;
	uint[288] codes;
	int max_sym;
}

<*
 @require blen.len <= 288 : "Cannot be larger than 288"
*>
fn void? HuffTree.init(&self, char[] blen)
{
	self.blen[:16] = blen[:16];
	self.max_sym = codegen(&self.codes, &self.blen)!;
}

<*
 Generate canoncial Huffman codes according to RFC section 3.2.2.

 @param [out] codes : "Canonical Huffman codes."
 @param [in] blen   : "Bit lengths for Huffman codes"
 @return "Max symbol for generated Huffman codes."
*>
fn int? codegen(uint[] codes, char[] blen)
{
	uint[16] bl_count, next_code;
	int max_sym = -1;

	foreach (len: blen)
	{
		assert(len < 16);
		bl_count[len]++;
	}
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
		codes[i] = bits::reverse(next_code[len-1] << (32-len));
		next_code[len-1]++;
		max_sym = i;
	}
	if (max_sym < 0) return ERR_CODEGEN?;
	return max_sym;
}

fn void test_huff_codegen() @test
{
	char[4] blen = { 2, 1, 3, 3 };
	uint[4] want= { 0b01, 0b0, 0b011, 0b111 };
	uint[4] codes;
	assert(codegen(&codes, &blen)!! == 3);
	assert(codes == want);
}

