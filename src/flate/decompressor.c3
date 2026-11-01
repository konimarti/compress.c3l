// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;
import std::io, std::bits;

faultdef INVALID_LENGTH, INVALID_BLOCK_TYPE, INVALID_CODE, INVALID_DISTANCE, TRUNCATED_INPUT;

const FAST_BITS = 10;

<*
 Table driven Huffman decoder. Codes up to FAST_BITS long are resolved with a
 single lookup; longer codes fall back to the canonical (counts/symbols)
 walk. A fast entry is (symbol << 4) | length, 0 meaning "use slow path".
*>
struct HuffDecoder
{
	ushort[1 << FAST_BITS] fast;
	HuffOrder order;
}

<*
 Builds the decoder from code lengths. Over-subscribed codes are rejected.
*>
fn void? HuffDecoder.build(&self, char[] lengths)
{
	*self = {};
	self.order = huff::build_canonical_symbols(lengths);

	int left = 1;
	for (usz len = 1; len <= huff::MAX_CODE_BITS; len++)
	{
		left <<= 1;
		left -= (int)self.order.counts[len];
		if (left < 0) return INVALID_CODE~;
	}

	uint[huff::MAX_CODE_BITS + 2] next;
	uint code = 0;
	for (usz len = 1; len <= huff::MAX_CODE_BITS; len++)
	{
		code = (code + self.order.counts[len - 1] * (len > 1 ? 1 : 0)) << 1;
		next[len] = code;
	}
	foreach (uint sym, len : lengths)
	{
		if (len == 0 || len > FAST_BITS) continue;
		uint c = next[len]++;
		uint rev = bits::reverse(c) >> (32 - len);
		ushort entry = (ushort)((sym << 4) | len);
		for (uint i = rev; i < (1U << FAST_BITS); i += 1U << len) self.fast[i] = entry;
	}
}

<*
 Inflater holds the complete state of one DEFLATE decode. Input comes either
 from a slice (fast path, bulk refills) or from a generic InStream, in which
 case bytes are pulled strictly on demand so nothing past the stream is read.
*>
struct Inflater
{
	char[] src;
	usz pos;
	InStream stream;
	ulong bits;
	uint nbits;
	char[] buf;
	usz n;
	Allocator allocator;
	HuffDecoder lit;
	HuffDecoder dist;
}

fn void Inflater.refill(&self) @inline
{
	if (self.stream) return;
	if (self.pos + 8 <= self.src.len)
	{
		self.bits |= mem::load((ulong*)&self.src[self.pos], 1) << self.nbits;
		self.pos += (usz)((63 - self.nbits) >> 3);
		self.nbits |= 56;
		return;
	}
	while (self.nbits <= 56 && self.pos < self.src.len)
	{
		self.bits |= (ulong)self.src[self.pos++] << self.nbits;
		self.nbits += 8;
	}
}

<* Pulls one more byte into the bit buffer; false on end of input. *>
fn bool Inflater.pull(&self)
{
	if (self.stream)
	{
		char? c = self.stream.read_byte();
		if (catch c) return false;
		self.bits |= (ulong)c << self.nbits;
		self.nbits += 8;
		return true;
	}
	if (self.pos >= self.src.len) return false;
	self.bits |= (ulong)self.src[self.pos++] << self.nbits;
	self.nbits += 8;
	return true;
}

<* Reads n (0..16) bits. *>
fn uint? Inflater.getbits(&self, uint n) @inline
{
	if (self.nbits < n)
	{
		self.refill();
		while (self.nbits < n)
		{
			if (!self.pull()) return TRUNCATED_INPUT~;
		}
	}
	uint v = (uint)(self.bits & ((1UL << n) - 1));
	self.bits >>= n;
	self.nbits -= n;
	return v;
}

fn int? Inflater.decode(&self, HuffDecoder *h) @inline
{
	self.refill();
	uint e = h.fast[(uint)(self.bits & ((1 << FAST_BITS) - 1))];
	if (e != 0 && (e & 15) <= self.nbits)
	{
		self.bits >>= e & 15;
		self.nbits -= e & 15;
		return (int)(e >> 4);
	}
	return self.decode_slow(h);
}

<* Canonical walk, one bit at a time; pulls input when bits run out. *>
fn int? Inflater.decode_slow(&self, HuffDecoder *h)
{
	int code = 0;
	int first = 0;
	int index = 0;
	for (uint len = 1; len <= huff::MAX_CODE_BITS; len++)
	{
		if (self.nbits < len)
		{
			if (!self.pull()) return TRUNCATED_INPUT~;
		}
		code |= (int)((self.bits >> (len - 1)) & 1);
		int count = (int)h.order.counts[len];
		if (code - count < first)
		{
			self.bits >>= len;
			self.nbits -= len;
			return (int)h.order.symbols[index + (code - first)];
		}
		index += count;
		first += count;
		first <<= 1;
		code <<= 1;
	}
	return INVALID_CODE~;
}

fn void Inflater.reserve(&self, usz extra) @inline
{
	if (self.n + extra + 16 > self.buf.len)
	{
		usz cap = self.buf.len * 2;
		if (cap < self.n + extra + 16) cap = self.n + extra + 16;
		self.buf = alloc::realloc_array(self.allocator, self.buf.ptr, char, (sz)cap);
	}
}

fn void? Inflater.stored_block(&self)
{
	// Drop the remaining bits of the current byte.
	uint drop = self.nbits & 7;
	self.bits >>= drop;
	self.nbits -= drop;

	uint length = self.getbits(16)!;
	uint inv = self.getbits(16)!;
	if (length != (~inv & 0xFFFF)) return INVALID_LENGTH~;

	self.reserve(length);
	// Bytes still sitting in the bit buffer come first.
	while (length > 0 && self.nbits > 0)
	{
		self.buf[self.n++] = (char)self.getbits(8)!;
		length--;
	}
	if (length == 0) return;
	if (self.stream)
	{
		while (length > 0)
		{
			self.buf[self.n++] = self.stream.read_byte()!;
			length--;
		}
		return;
	}
	if (self.pos + length > self.src.len) return TRUNCATED_INPUT~;
	self.buf[self.n:length] = self.src[self.pos:length];
	self.n += length;
	self.pos += length;
	// Drop stale look-ahead bits left by the bulk refill.
	self.bits = 0;
}

fn void? Inflater.fixed_block(&self)
{
	self.lit.build(huff::FIXED_LITERAL_LENGTH_CODE_LENGTHS)!;
	self.dist.build(huff::FIXED_DISTANCE_CODE_LENGTHS)!;
	return self.codes();
}

fn void? Inflater.dynamic_block(&self)
{
	char[288 + 32] lengths;
	uint nlit = self.getbits(5)! + 257;
	uint ndist = self.getbits(5)! + 1;
	uint nclen = self.getbits(4)! + 4;
	if (nlit > 286 || ndist > 30) return INVALID_CODE~;

	char[19] cl;
	for (usz i = 0; i < nclen; i++) cl[hc_order[i]] = (char)self.getbits(3)!;
	HuffDecoder clh;
	clh.build(&cl)!;

	uint total = nlit + ndist;
	uint num = 0;
	while (num < total)
	{
		int sym = self.decode(&clh)!;
		if (sym < 16)
		{
			lengths[num++] = (char)sym;
			continue;
		}
		char val = 0;
		uint rep;
		switch (sym)
		{
			case 16:
				if (num == 0) return INVALID_CODE~;
				val = lengths[num - 1];
				rep = self.getbits(2)! + 3;
			case 17:
				rep = self.getbits(3)! + 3;
			default:
				rep = self.getbits(7)! + 11;
		}
		if (num + rep > total) return INVALID_CODE~;
		while (rep--) lengths[num++] = val;
	}
	self.lit.build(lengths[0:nlit])!;
	self.dist.build(lengths[nlit:ndist])!;
	return self.codes();
}

<*
 Decodes the symbols of one compressed block using the current tables.
*>
fn void? Inflater.codes(&self)
{
	while (true)
	{
		int sym = self.decode(&self.lit)!;
		if (sym < 256)
		{
			self.reserve(1);
			self.buf[self.n++] = (char)sym;
			continue;
		}
		if (sym == END_OF_BLOCK) return;
		sym -= 257;
		if (sym >= 29) return INVALID_CODE~;
		uint length = len_base[sym] + self.getbits(len_extra[sym])!;

		int ds = self.decode(&self.dist)!;
		if (ds >= 30) return INVALID_CODE~;
		uint off = dist_base[ds] + self.getbits(dist_extra[ds])!;
		if (off > self.n) return INVALID_DISTANCE~;

		self.reserve(length);
		char* dst = &self.buf[self.n];
		char* from = dst - off;
		if (off >= 8)
		{
			for (uint i = 0; i < length; i += 8)
			{
				mem::store((ulong*)(dst + i), mem::load((ulong*)(from + i), 1), 1);
			}
		}
		else
		{
			for (uint i = 0; i < length; i++) dst[i] = from[i];
		}
		self.n += length;
	}
}

<*
 Runs the block loop until BFINAL; returns the output buffer.
*>
fn char[]? Inflater.run(&self)
{
	if (self.buf.len == 0) self.reserve(self.src.len * 4 + 1024);
	uint bfinal;
	do
	{
		bfinal = self.getbits(1)!;
		switch (self.getbits(2)!)
		{
			case 0: self.stored_block()!;
			case 1: self.fixed_block()!;
			case 2: self.dynamic_block()!;
			default: return INVALID_BLOCK_TYPE~;
		}
	} while (!bfinal);
	return self.buf[:self.n];
}
