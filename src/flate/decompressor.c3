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

const usz INFLATE_CAP = 1U << 20;   // Output buffer of the streaming modes.
const usz INFLATE_WINDOW = 1U << 15;  // History that must stay available.
const usz INFLATE_CHUNK = 1U << 15;   // Input read-ahead of the streaming modes.
const usz INFLATE_HEADROOM = 8;       // Bytes of the previous chunk kept in front of inbuf.

enum InflateState : char
{
	BLOCK_HEADER,
	BLOCK_CODES,
	DONE,
}

<*
 Inflater holds the complete state of one DEFLATE decode.

 Input comes from a slice (bulk refills), from a buffered InStream
 (read ahead in chunks), or from an InStream byte by byte (exact: nothing
 past the DEFLATE stream is consumed).

 Output either accumulates in a growing buffer (one-shot), is flushed to a
 sink when the buffer fills, or is handed out incrementally by InflateReader.
 The streaming variants keep the last 32 KiB around as match history.
*>
struct Inflater
{
	char[] src;
	usz pos;
	InStream stream;
	bool exact;
	char[] inbuf;
	ulong bits;
	uint nbits;
	char[] buf;
	usz n;
	usz emitted;      // Output before this offset has been handed out.
	OutStream sink;
	bool fixed_buf;   // Output buffer must not grow (reader mode).
	usz yield_at;     // Stop decoding once n reaches this (reader mode).
	Allocator allocator;
	InflateState state;
	bool last;
	HuffDecoder lit;
	HuffDecoder dist;
}

fn void Inflater.refill(&self) @inline
{
	if (self.exact) return;
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

<* Reads the next chunk of a buffered stream into src; false at the end. *>
fn bool Inflater.fetch(&self)
{
	if (!self.stream || self.exact) return false;
	// Keep the tail of the previous chunk right before the new one so that
	// leftover() can reach bytes that were already moved into the bit buffer.
	usz tail = self.src.len < INFLATE_HEADROOM ? self.src.len : INFLATE_HEADROOM;
	if (tail > 0) mem::move(self.inbuf.ptr + (sz)(INFLATE_HEADROOM - tail), self.src.ptr + (sz)(self.src.len - tail), (sz)tail);
	sz? k = self.stream.read(self.inbuf[INFLATE_HEADROOM..]);
	if (catch k) return false;
	if (k <= 0) return false;
	self.src = self.inbuf[INFLATE_HEADROOM:k];
	self.pos = 0;
	return true;
}

<* Pulls one more byte into the bit buffer; false on end of input. *>
fn bool Inflater.pull(&self)
{
	if (self.exact)
	{
		char? c = self.stream.read_byte();
		if (catch c) return false;
		self.bits |= (ulong)c << self.nbits;
		self.nbits += 8;
		return true;
	}
	if (self.pos >= self.src.len)
	{
		if (!self.fetch()) return false;
	}
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

<* Hands the unflushed output to the sink and keeps the last window as history. *>
fn void? Inflater.flush_sink(&self)
{
	char[] out = self.buf[self.emitted:self.n - self.emitted];
	while (out.len > 0)
	{
		sz k = self.sink.write(out)!;
		out = out[k..];
	}
	usz keep = self.n < INFLATE_WINDOW ? self.n : INFLATE_WINDOW;
	mem::move(self.buf.ptr, self.buf.ptr + (self.n - keep), (sz)keep);
	self.n = keep;
	self.emitted = keep;
}

fn void? Inflater.reserve(&self, usz extra) @inline
{
	if (self.n + extra + 16 <= self.buf.len) return;
	self.make_room(extra)!;
}

fn void? Inflater.make_room(&self, usz extra)
{
	if (self.sink)
	{
		self.flush_sink()!;
		return;
	}
	assert(!self.fixed_buf, "output buffer overrun");
	usz cap = self.buf.len * 2;
	if (cap < self.n + extra + 16) cap = self.n + extra + 16;
	self.buf = alloc::realloc_array(self.allocator, self.buf.ptr, char, (sz)cap)[:cap];
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

	// Bytes still sitting in the bit buffer come first.
	while (length > 0 && self.nbits > 0)
	{
		self.reserve(1)!;
		self.buf[self.n++] = (char)self.getbits(8)!;
		length--;
	}
	while (length > 0)
	{
		if (self.exact)
		{
			self.reserve(1)!;
			self.buf[self.n++] = self.stream.read_byte()!;
			length--;
			continue;
		}
		if (self.pos >= self.src.len)
		{
			if (!self.fetch()) return TRUNCATED_INPUT~;
		}
		usz k = self.src.len - self.pos;
		if (k > length) k = length;
		self.reserve(k)!;
		self.buf[self.n:k] = self.src[self.pos:k];
		self.n += k;
		self.pos += k;
		length -= (uint)k;
	}
	// Drop stale look-ahead bits left by the bulk refill.
	self.bits = 0;
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
}

<*
 Decodes the symbols of the current block. Returns true at the end of the
 block, false if decoding paused because yield_at was reached.
*>
fn bool? Inflater.codes(&self)
{
	while (true)
	{
		if (self.n >= self.yield_at) return false;
		int sym = self.decode(&self.lit)!;
		if (sym < 256)
		{
			self.reserve(1)!;
			self.buf[self.n++] = (char)sym;
			continue;
		}
		if (sym == END_OF_BLOCK) return true;
		sym -= 257;
		if (sym >= 29) return INVALID_CODE~;
		uint length = len_base[sym] + self.getbits(len_extra[sym])!;

		int ds = self.decode(&self.dist)!;
		if (ds >= 30) return INVALID_CODE~;
		uint off = dist_base[ds] + self.getbits(dist_extra[ds])!;
		if (off > self.n) return INVALID_DISTANCE~;

		self.reserve(length)!;
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
 Decodes blocks until the stream ends or yield_at is reached.
*>
fn void? Inflater.step(&self)
{
	while (self.state != DONE)
	{
		if (self.n >= self.yield_at) return;
		if (self.state == BLOCK_HEADER)
		{
			if (self.last)
			{
				self.state = DONE;
				break;
			}
			self.last = self.getbits(1)! == 1;
			switch (self.getbits(2)!)
			{
				case 0:
					self.stored_block()!;
				case 1:
					self.lit.build(huff::FIXED_LITERAL_LENGTH_CODE_LENGTHS)!;
					self.dist.build(huff::FIXED_DISTANCE_CODE_LENGTHS)!;
					self.state = BLOCK_CODES;
				case 2:
					self.dynamic_block()!;
					self.state = BLOCK_CODES;
				default:
					return INVALID_BLOCK_TYPE~;
			}
			continue;
		}
		if (self.codes()!) self.state = BLOCK_HEADER;
	}
}

<*
 Runs the whole stream and returns the accumulated output (one-shot mode).
*>
fn char[]? Inflater.run(&self)
{
	self.yield_at = usz::max;
	if (self.buf.len == 0) self.reserve(self.src.len * 4 + 1024)!;
	self.step()!;
	return self.buf[:self.n];
}

<* Number of whole input bytes read but not part of the DEFLATE stream. *>
fn usz Inflater.unused(&self) @inline => self.nbits / 8;

// ------------------------------------------------------------- streaming

<*
 InflateReader is an InStream that decompresses a DEFLATE stream read from
 another InStream, using constant memory (about 1 MiB) however large the data
 is. The source is read ahead in chunks, so more than the DEFLATE stream may be
 consumed from it; leftover() returns the surplus once the stream has ended.
 Call free() when done.
*>
struct InflateReader (InStream)
{
	Inflater inf;
	Allocator allocator;
}

fn void InflateReader.init(&self, Allocator allocator, InStream source)
{
	*self = {};
	self.allocator = allocator;
	self.inf.allocator = allocator;
	self.inf.stream = source;
	self.inf.fixed_buf = true;
	self.inf.buf = alloc::new_array(allocator, char, (sz)INFLATE_CAP)[:INFLATE_CAP];
	self.inf.inbuf = alloc::new_array(allocator, char, (sz)(INFLATE_CHUNK + INFLATE_HEADROOM))[:INFLATE_CHUNK + INFLATE_HEADROOM];
}

fn void InflateReader.free(&self)
{
	alloc::free(self.allocator, self.inf.buf.ptr);
	alloc::free(self.allocator, self.inf.inbuf.ptr);
	*self = {};
}

<*
 Bytes that were read from the source but are not part of the DEFLATE stream.
 Only meaningful after read() has returned 0. Valid until the next read.
*>
fn char[] InflateReader.leftover(&self)
{
	Inflater* f = &self.inf;
	if (f.state != DONE) return {};
	usz back = f.unused();
	return (f.src.ptr + (sz)(f.pos - back))[:f.src.len - f.pos + back];
}

fn sz? InflateReader.read(&self, char[] out) @dynamic
{
	if (out.len == 0) return 0;
	Inflater* f = &self.inf;
	while (f.emitted == f.n)
	{
		if (f.state == DONE) return 0;
		// Everything was handed out: make room, keeping the history window.
		if (f.n + 100_000 > f.buf.len)
		{
			usz keep = f.n < INFLATE_WINDOW ? f.n : INFLATE_WINDOW;
			mem::move(f.buf.ptr, f.buf.ptr + (f.n - keep), (sz)keep);
			f.n = keep;
			f.emitted = keep;
		}
		f.yield_at = f.n + INFLATE_WINDOW;
		f.step()!;
	}
	usz k = f.n - f.emitted;
	if (k > out.len) k = out.len;
	out[:k] = f.buf[f.emitted:k];
	f.emitted += k;
	return (sz)k;
}

fn char? InflateReader.read_byte(&self) @dynamic
{
	char[1] one;
	if (self.read(&one)! == 0) return io::EOF~;
	return one[0];
}

<*
 Decompresses the DEFLATE stream read from source and writes it to out using
 constant memory. The source is read ahead in chunks (see InflateReader).
*>
fn void? inflate_to(Allocator allocator, OutStream out, InStream source)
{
	Inflater f;
	f.allocator = allocator;
	f.stream = source;
	f.sink = out;
	f.buf = alloc::new_array(allocator, char, (sz)INFLATE_CAP)[:INFLATE_CAP];
	f.inbuf = alloc::new_array(allocator, char, (sz)(INFLATE_CHUNK + INFLATE_HEADROOM))[:INFLATE_CHUNK + INFLATE_HEADROOM];
	defer alloc::free(allocator, f.buf.ptr);
	defer alloc::free(allocator, f.inbuf.ptr);
	f.yield_at = usz::max;
	f.step()!;
	f.flush_sink()!;
}
