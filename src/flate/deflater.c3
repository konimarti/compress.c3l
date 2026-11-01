// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
<*
 Fast DEFLATE encoder: whole-input hash-chain matcher with lazy matching,
 tokens packed into plain uints, a 64-bit bit accumulator and a per-block
 choice between stored, fixed and dynamic Huffman coding.
*>
module compress::flate;
import std::io, std::bits;

const uint FAST_HASH_BITS = 15;
const uint FAST_WSIZE = 1U << 15;
const uint FAST_WMASK = FAST_WSIZE - 1;
const uint BLOCK_TOKENS = 1U << 15;
const uint MATCH_FLAG = 0x8000_0000;

<*
 Block coding strategy. AUTO picks the smallest of stored, fixed and dynamic
 for every block; the others force one coding for the whole stream.
*>
enum DeflateMode
{
	AUTO,
	STORED,
	FIXED,
	DYNAMIC,
}

<*
 Tunables of the match finder.
*>
struct DeflateParams
{
	uint max_chain;  // Maximum hash chain candidates examined.
	uint nice_len;   // Stop searching once a match this long is found.
	uint lazy_len;   // Do not try a lazy match if the current one is at least this long.
	usz segment;     // Inputs are processed in segments of this many bytes (at most 1 GiB).
}

const DeflateParams DEFAULT_PARAMS = { .max_chain = 16, .nice_len = 64, .lazy_len = 16, .segment = SEGMENT };

struct Deflater @private
{
	OutStream out;
	DeflateParams params;
	DeflateMode mode;
	char[] input;

	// Match finder.
	uint* head;
	ushort* prev;

	// Tokens of the current block.
	uint* tokens;
	uint ntok;
	uint block_start;  // Input offset of the first byte of the block.
	uint block_bytes;  // Input bytes covered by the tokens.
	uint extra_bits;   // Sum of extra bits of all matches in the block.
	uint[288] lfreq;
	uint[32] dfreq;

	// Bit writer.
	char* obuf;
	usz opos;
	usz total_out;
	ulong acc;
	uint nacc;

	// Symbol tables.
	char[259] len_sym;
	char[512] dist_sym;

	HuffCodes fixed_lt;
	HuffCodes fixed_dt;
}

fn void Deflater.setup(&self)
{
	uint s = 0;
	for (uint l = 3; l <= 258; l++)
	{
		while (s < 28 && l >= len_base[s + 1]) s++;
		self.len_sym[l] = (char)s;
	}
	self.len_sym[258] = 28;
	// Distances 1..256 by (d-1), larger by (d-1)>>7 offset by 256.
	s = 0;
	for (uint d = 1; d <= 256; d++)
	{
		while (s < 29 && d >= dist_base[s + 1]) s++;
		self.dist_sym[d - 1] = (char)s;
	}
	for (uint i = 2; i < 256; i++)
	{
		uint d = (i << 7) + 1;
		s = 0;
		while (s < 29 && d >= dist_base[s + 1]) s++;
		self.dist_sym[256 + i] = (char)s;
	}
	self.fixed_lt = huff::build_codes_from_lengths(huff::FIXED_LITERAL_LENGTH_CODE_LENGTHS)!!;
	self.fixed_dt = huff::build_codes_from_lengths(huff::FIXED_DISTANCE_CODE_LENGTHS)!!;
}

fn uint Deflater.dsym(&self, uint dist) @inline
{
	return dist <= 256 ? self.dist_sym[dist - 1] : self.dist_sym[256 + ((dist - 1) >> 7)];
}

// ---------------------------------------------------------------- bit writer

fn void Deflater.put(&self, uint code, uint len) @inline
{
	self.acc |= (ulong)code << self.nacc;
	self.nacc += len;
	if (self.nacc >= 32)
	{
		mem::store((uint*)(self.obuf + self.opos), (uint)self.acc, 1);
		self.opos += 4;
		self.acc >>= 32;
		self.nacc -= 32;
	}
}

<* Writes all whole bytes, optionally padding the last partial byte. *>
fn void Deflater.drain(&self, bool pad)
{
	while (self.nacc >= 8 || (pad && self.nacc > 0))
	{
		self.obuf[self.opos++] = (char)self.acc;
		self.acc >>= 8;
		self.nacc = self.nacc >= 8 ? self.nacc - 8 : 0;
	}
}

fn void? Deflater.send(&self)
{
	if (self.opos == 0) return;
	self.out.write(self.obuf[:self.opos])!;
	self.total_out += self.opos;
	self.opos = 0;
}

// ------------------------------------------------------------- match finder

fn uint Deflater.hash_at(&self, uint p) @inline
{
	uint v = mem::load((uint*)&self.input[p], 1);
	return (v * 2654435761U) >> (32 - FAST_HASH_BITS);
}

fn void Deflater.insert(&self, uint p) @inline
{
	uint h = self.hash_at(p);
	uint old = self.head[h];
	uint delta = old == 0 ? 0 : p + 1 - old;
	self.prev[p & FAST_WMASK] = delta > 0xFFFF ? 0 : (ushort)delta;
	self.head[h] = p + 1;
}

<*
 Finds the longest match for position p. Returns length in the high part and
 distance in the low 16 bits is avoided: both are returned via out params.
*>
fn uint Deflater.find(&self, uint p, uint prev_len, uint* dist_out)
{
	uint n = (uint)self.input.len;
	uint maxlen = n - p > 258 ? 258 : n - p;
	uint best = prev_len < 3 ? 3 : prev_len;
	uint best_dist = 0;
	if (best >= maxlen) { *dist_out = 0; return 0; }
	uint chain = self.params.max_chain;
	if (prev_len >= 16) chain >>= 2;

	uint h = self.hash_at(p);
	uint cand1 = self.head[h];
	char* base = self.input.ptr;
	char* cur = base + p;
	uint cur4 = mem::load((uint*)cur, 1);

	while (cand1 != 0 && chain-- > 0)
	{
		uint cand = cand1 - 1;
		uint dist = p - cand;
		if (dist > FAST_WSIZE) break;
		char* m = base + cand;
		// Quick reject: must beat best so far.
		if (m[best] == cur[best] && mem::load((uint*)m, 1) == cur4)
		{
			uint l = 4;
			while (l + 8 <= maxlen)
			{
				ulong x = mem::load((ulong*)(m + l), 1) ^ mem::load((ulong*)(cur + l), 1);
				if (x != 0)
				{
					l += (uint)(x.ctz() >> 3);
					break;
				}
				l += 8;
			}
			if (l + 8 > maxlen)
			{
				while (l < maxlen && m[l] == cur[l]) l++;
			}
			if (l > maxlen) l = maxlen;
			if (l > best)
			{
				best = l;
				best_dist = dist;
				if (l >= self.params.nice_len || l >= maxlen) break;
			}
		}
		uint step = self.prev[cand & FAST_WMASK];
		if (step == 0) break;
		cand1 = cand1 > step ? cand1 - step : 0;
	}
	*dist_out = best_dist;
	return best_dist == 0 ? 0 : best;
}

// ------------------------------------------------------------------- tokens

fn void? Deflater.add_literal(&self, char c) @inline
{
	self.tokens[self.ntok++] = c;
	self.lfreq[c]++;
	self.block_bytes++;
	if (self.ntok == BLOCK_TOKENS) self.flush_block(false)!;
}

fn void? Deflater.add_match(&self, uint len, uint dist) @inline
{
	self.tokens[self.ntok++] = MATCH_FLAG | ((len - 3) << 16) | (dist - 1);
	uint ls = self.len_sym[len];
	uint ds = self.dsym(dist);
	self.lfreq[257 + ls]++;
	self.dfreq[ds]++;
	self.extra_bits += len_extra[ls] + dist_extra[ds];
	self.block_bytes += len;
	if (self.ntok == BLOCK_TOKENS) self.flush_block(false)!;
}

// ------------------------------------------------------------- block output

<* Run-length encodes code lengths into code-length symbols (RFC 1951 3.2.7). *>
fn usz rle_lengths(char[] lens, char* syms, char* extra, uint[19]* freq)
{
	usz i, k;
	usz n = lens.len;
	while (i < n)
	{
		char v = lens[i];
		usz r = 1;
		while (i + r < n && lens[i + r] == v && r < 138) r++;
		if (v == 0)
		{
			if (r >= 11)
			{
				syms[k] = 18; extra[k++] = (char)(r - 11); (*freq)[18]++;
				i += r;
			}
			else if (r >= 3)
			{
				syms[k] = 17; extra[k++] = (char)(r - 3); (*freq)[17]++;
				i += r;
			}
			else
			{
				syms[k] = 0; extra[k++] = 0; (*freq)[0]++;
				i++;
			}
			continue;
		}
		syms[k] = v; extra[k++] = 0; (*freq)[v]++;
		i++;
		r--;
		while (r >= 3)
		{
			usz t = r > 6 ? 6 : r;
			syms[k] = 16; extra[k++] = (char)(t - 3); (*freq)[16]++;
			i += t;
			r -= t;
		}
	}
	return k;
}

fn void Deflater.write_tokens(&self, HuffCodes* lt, HuffCodes* dt)
{
	for (uint i = 0; i < self.ntok; i++)
	{
		uint t = self.tokens[i];
		if (t < 256)
		{
			self.put(lt.codes[t], lt.blen[t]);
			continue;
		}
		uint len = ((t >> 16) & 0xFF) + 3;
		uint dist = (t & 0xFFFF) + 1;
		uint ls = self.len_sym[len];
		uint ds = self.dsym(dist);
		uint sym = 257 + ls;
		uint lb = lt.blen[sym];
		uint le = len_extra[ls];
		self.put(lt.codes[sym] | ((len - len_base[ls]) << lb), lb + le);
		uint db = dt.blen[ds];
		uint de = dist_extra[ds];
		self.put(dt.codes[ds] | ((dist - dist_base[ds]) << db), db + de);
	}
	self.put(lt.codes[END_OF_BLOCK], lt.blen[END_OF_BLOCK]);
}

<* Emits stored blocks covering input[off:bytes]; BFINAL goes on the last one. *>
fn void? Deflater.write_stored(&self, uint off, uint bytes, bool last)
{
	uint left = bytes;
	do
	{
		uint chunk = left > 65535 ? 65535 : left;
		left -= chunk;
		self.put((last && left == 0) ? 1U : 0U, 1);
		self.put(0, 2);
		self.drain(true);
		self.put(chunk, 16);
		self.put(~chunk & 0xFFFF, 16);
		self.drain(false);
		if (self.opos + chunk + 64 > STREAM_BUF) self.send()!;
		self.obuf[self.opos:chunk] = self.input[off:chunk];
		self.opos += chunk;
		off += chunk;
	} while (left > 0);
}

fn void? Deflater.flush_block(&self, bool last) => @pool()
{
	self.lfreq[END_OF_BLOCK] = 1;
	uint bytes = self.block_bytes;

	// Dynamic trees.
	bool dfreq_empty = true;
	foreach (f : self.dfreq[:30]) if (f) dfreq_empty = false;
	if (dfreq_empty) self.dfreq[0] = 1;

	HuffCodes lt = huff::build_codes_from_freqs(self.lfreq[:286])!;
	HuffCodes dt = huff::build_codes_from_freqs(self.dfreq[:30])!;

	uint hlit = (uint)lt.max_sym + 1;
	if (hlit < 257) hlit = 257;
	uint hdist = (uint)dt.max_sym + 1;
	if (hdist < 1) hdist = 1;

	char[286 + 30] all;
	all[:hlit] = lt.blen[:hlit];
	all[hlit:hdist] = dt.blen[:hdist];
	char[316] syms;
	char[316] extra;
	uint[19] cfreq;
	usz nsyms = rle_lengths(all[:hlit + hdist], &syms, &extra, &cfreq);
	HuffCodes cl = huff::build_codes_from_freqs(cfreq[..], 7)!;
	uint hclen = 19;
	while (hclen > 4 && cl.blen[hc_order[hclen - 1]] == 0) hclen--;

	ulong dyn = (ulong)(17 + 3 * hclen + self.extra_bits);
	foreach (i, f : cfreq) dyn += (ulong)f * (ulong)(cl.blen[i]);
	foreach (i, f : cfreq[16:3]) dyn += (ulong)f * (ulong)(((i == 0) ? 2 : (i == 1) ? 3 : 7));
	foreach (i, f : self.lfreq[:286]) dyn += (ulong)f * (ulong)(lt.blen[i]);
	foreach (i, f : self.dfreq[:30]) dyn += (ulong)f * (ulong)(dt.blen[i]);

	ulong fix = (ulong)(3 + self.extra_bits);
	foreach (i, f : self.lfreq[:286]) fix += (ulong)f * (ulong)(self.fixed_lt.blen[i]);
	foreach (i, f : self.dfreq[:30]) fix += (ulong)f * (ulong)(5);

	ulong stored = (ulong)7 + (ulong)bytes * 8 + (ulong)32 * (ulong)((bytes + 65534) / 65535);

	uint bfinal = last ? 1 : 0;
	bool use_stored = self.mode == STORED || (self.mode == AUTO && stored < dyn && stored < fix);
	bool use_fixed = self.mode == FIXED || (self.mode == AUTO && fix <= dyn);
	if (use_stored)
	{
		self.write_stored(self.block_start, bytes, last)!;
	}
	else if (use_fixed)
	{
		self.put(bfinal, 1);
		self.put(1, 2);
		self.write_tokens(&self.fixed_lt, &self.fixed_dt);
	}
	else
	{
		self.put(bfinal, 1);
		self.put(2, 2);
		self.put(hlit - 257, 5);
		self.put(hdist - 1, 5);
		self.put(hclen - 4, 4);
		for (uint i = 0; i < hclen; i++) self.put(cl.blen[hc_order[i]], 3);
		for (usz i = 0; i < nsyms; i++)
		{
			uint s = syms[i];
			self.put(cl.codes[s], cl.blen[s]);
			switch (s)
			{
				case 16: self.put(extra[i], 2);
				case 17: self.put(extra[i], 3);
				case 18: self.put(extra[i], 7);
			}
		}
		self.write_tokens(&lt, &dt);
	}
	self.drain(false);
	self.send()!;

	self.block_start += bytes;
	self.block_bytes = 0;
	self.ntok = 0;
	self.extra_bits = 0;
	self.lfreq = {};
	self.dfreq = {};
}

// ------------------------------------------------------------------- driver

const usz SEGMENT = 1U << 30;
const usz STREAM_BUF = BLOCK_TOKENS * 6 + 4096;

<* Allocates the working memory; pass tmem for one-shot use. *>
fn void Deflater.init(&self, Allocator allocator, OutStream out, DeflateMode mode, DeflateParams params)
{
	*self = {};
	self.out = out;
	self.params = params;
	self.mode = mode;
	self.setup();
	self.head = alloc::new_array(allocator, uint, 1U << FAST_HASH_BITS);
	self.prev = alloc::new_array(allocator, ushort, FAST_WSIZE);
	self.tokens = alloc::new_array(allocator, uint, BLOCK_TOKENS);
	// Stored blocks may need up to 64K plus headers on top of the token area.
	self.obuf = alloc::new_array(allocator, char, STREAM_BUF + 65536 + 64);
}

fn void Deflater.release(&self, Allocator allocator)
{
	alloc::free(allocator, self.head);
	alloc::free(allocator, self.prev);
	alloc::free(allocator, self.tokens);
	alloc::free(allocator, self.obuf);
	self.head = null;
	self.prev = null;
	self.tokens = null;
	self.obuf = null;
}

<* Writes the final empty stored block of an empty stream. *>
fn void? Deflater.write_empty(&self)
{
	self.put(1, 1);
	self.put(0, 2);
	self.drain(true);
	self.put(0, 16);
	self.put(0xFFFF, 16);
	self.drain(true);
	self.send()!;
}

<*
 Compresses bytes into a complete DEFLATE stream written to out.
*>
fn void? deflate_fast(OutStream out, char[] bytes, DeflateMode mode = AUTO,
	DeflateParams params = DEFAULT_PARAMS) => @pool()
{
	Deflater d;
	d.init(tmem, out, mode, params);

	usz n = bytes.len;
	if (n == 0) return d.write_empty();

	// The matcher uses 32-bit positions, so huge inputs are processed in
	// segments. Matches do not cross segment boundaries, which costs at most
	// one window of history per segment.
	usz seg = params.segment;
	assert(seg > 0 && seg <= SEGMENT);
	for (usz off = 0; off < n; off += seg)
	{
		usz len = n - off > seg ? seg : n - off;
		bool last = off + len >= n;
		d.input = bytes[off:len];
		d.block_start = 0;
		if (mode == STORED)
		{
			d.write_stored(0, (uint)len, last)!;
			continue;
		}
		mem::clear(d.head, (usz)(4U << FAST_HASH_BITS));
		d.run(0, (uint)len)!;
		d.flush_block(last)!;
	}
	d.drain(true);
	d.send()!;
}

<*
 Tokenizes input[p:limit] (the matcher may look ahead up to the end of
 d.input) and returns the position where it stopped, which is at least limit.
*>
fn uint? Deflater.run(&self, uint p, uint limit)
{
	Deflater* d = self;
	char[] bytes = self.input;
	uint end = (uint)bytes.len;
	uint cl = 0;
	uint cd = 0;
	bool have = false;
	uint misses = 0;
	while (p < limit || have)
	{
		if (p + 8 > end)
		{
			d.add_literal(bytes[p])!;
			p++;
			continue;
		}
		if (!have)
		{
			cl = d.find(p, 0, &cd);
			d.insert(p);
		}
		have = false;
		if (cl < 4)
		{
			d.add_literal(bytes[p])!;
			p++;
			// Accelerate through incompressible data: after a long run of
			// misses, emit a growing number of bytes without searching.
			if (++misses > 128)
			{
				uint skip = (misses - 128) >> 5;
				if (skip > 32) skip = 32;
				while (skip-- > 0 && p + 8 < end)
				{
					d.add_literal(bytes[p])!;
					p++;
				}
			}
			continue;
		}
		misses = 0;
		bool lazy_done = false;
		if (cl < d.params.lazy_len && p + 9 <= end)
		{
			uint d2;
			uint l2 = d.find(p + 1, cl, &d2);
			d.insert(p + 1);
			lazy_done = true;
			if (l2 > cl)
			{
				d.add_literal(bytes[p])!;
				p++;
				cl = l2;
				cd = d2;
				have = true;
				continue;
			}
		}
		d.add_match(cl, cd)!;
		uint q = p + (lazy_done ? 2 : 1);
		p += cl;
		// Very long matches are mostly redundant: index the start and the
		// tail only, which keeps highly repetitive input fast.
		if (cl > 64 && q + 32 < p)
		{
			for (uint stop = q + 16; q < stop; q++) d.insert(q);
			q = p - 16;
		}
		for (; q < p; q++)
		{
			if (q + 8 <= end) d.insert(q);
		}
	}
	return p;
}

// ------------------------------------------------------------ streaming writer

faultdef STREAM_CLOSED;

const usz WRITER_BUF = (1U << 20) + FAST_WSIZE;
const uint LOOKAHEAD = 262;

<*
 DeflateWriter is an OutStream that compresses everything written to it and
 forwards the DEFLATE stream to the wrapped OutStream. Memory use is constant
 (about 1.5 MiB) regardless of the amount of data. Call close() after the last
 write to emit the final block, then free().

 Matches may reach back up to 32 KiB across internal chunk boundaries.
*>
struct DeflateWriter (OutStream)
{
	Deflater d;
	Allocator allocator;
	char[] buf;  // 32 KiB history followed by new data.
	uint fill;   // Valid bytes in buf.
	uint p;      // First byte not yet tokenized.
	bool closed;
	ulong total_in; // Bytes written so far.
}

fn void DeflateWriter.init(&self, Allocator allocator, OutStream out,
	DeflateMode mode = AUTO, DeflateParams params = DEFAULT_PARAMS)
{
	*self = {};
	self.allocator = allocator;
	self.d.init(allocator, out, mode, params);
	self.buf = alloc::new_array(allocator, char, (sz)WRITER_BUF)[:WRITER_BUF];
}

<* Releases the working memory. Does not close the stream; call close() first. *>
fn void DeflateWriter.free(&self)
{
	self.d.release(self.allocator);
	alloc::free(self.allocator, self.buf.ptr);
	*self = {};
}

fn void? DeflateWriter.process(&self, bool final)
{
	Deflater* d = &self.d;
	d.input = self.buf[:self.fill];
	d.block_start = self.p;
	if (d.mode == STORED)
	{
		if (self.fill > self.p || final) d.write_stored(self.p, self.fill - self.p, final)!;
		self.p = self.fill;
		return;
	}
	uint limit = self.fill;
	if (!final) limit = self.fill > LOOKAHEAD ? self.fill - LOOKAHEAD : 0;
	if (self.p < limit) self.p = d.run(self.p, limit)!;
	// Blocks never span chunks, so stored blocks can read their raw bytes.
	if (d.ntok > 0 || final) d.flush_block(final)!;
	if (!final) d.send()!;
}

<* Drops old history from the front of the buffer, keeping at least one window. *>
fn void DeflateWriter.slide(&self)
{
	if (self.p < 2 * FAST_WSIZE) return;
	uint delta = (self.p - FAST_WSIZE) & ~FAST_WMASK;
	mem::move(self.buf.ptr, self.buf.ptr + delta, (sz)(self.fill - delta));
	self.fill -= delta;
	self.p -= delta;
	for (usz i = 0; i < (1U << FAST_HASH_BITS); i++)
	{
		uint e = self.d.head[i];
		self.d.head[i] = e > delta ? e - delta : 0;
	}
}

fn sz? DeflateWriter.write(&self, char[] bytes) @dynamic
{
	if (self.closed) return STREAM_CLOSED~;
	sz total = bytes.len;
	self.total_in += bytes.len;
	while (bytes.len > 0)
	{
		usz room = self.buf.len - self.fill;
		if (room == 0)
		{
			self.process(false)!;
			self.slide();
			continue;
		}
		usz k = room < bytes.len ? room : bytes.len;
		self.buf[self.fill:k] = bytes[:k];
		self.fill += (uint)k;
		bytes = bytes[k..];
	}
	return total;
}

fn void? DeflateWriter.write_byte(&self, char c) @dynamic
{
	char[1] one = { c };
	self.write(&one)!;
}

<*
 Finishes the DEFLATE stream (final block, bit padding). Does not close the
 wrapped stream. Calling it again does nothing.
*>
fn void? DeflateWriter.close(&self) @dynamic
{
	if (self.closed) return;
	self.closed = true;
	if (self.total_in == 0) return self.d.write_empty();
	self.process(true)!;
	self.d.drain(true);
	self.d.send()!;
}

<*
 Compresses everything read from in and writes the DEFLATE stream to out,
 using constant memory.
*>
fn void? deflate_from(Allocator allocator, OutStream out, InStream in,
	DeflateMode mode = AUTO) => @pool()
{
	DeflateWriter w;
	w.init(allocator, out, mode);
	defer w.free();
	io::copy_to(in, &w, mem::talloc_array(char, 65536))!;
	w.close()!;
}

module compress::flate::fast_test;
import std::io;
import compress::flate;

fn void roundtrip(char[] data) => @pool()
{
	char[] comp = flate::compress(tmem, data)!!;
	char[] back = flate::inflate(tmem, comp)!!;
	assert(back == data, "roundtrip mismatch for len %d", data.len);
}

fn void test_fast_empty_and_tiny() @test => @pool()
{
	roundtrip({});
	roundtrip({ 'a' });
	roundtrip("abcabcabcabcabcabc");
}

fn void test_fast_repetitive() @test => @pool()
{
	char[] zeros = mem::talloc_array(char, 300_000);
	roundtrip(zeros);
	char[] pattern = mem::talloc_array(char, 200_000);
	foreach (i, &c : pattern) *c = (char)(i % 7);
	roundtrip(pattern);
}

fn void test_fast_random_and_mixed() @test => @pool()
{
	char[] data = mem::talloc_array(char, 400_000);
	uint x = 12345;
	foreach (i, &c : data)
	{
		x = x * 1664525 + 1013904223;
		// Alternate between random and repetitive regions to mix block types.
		*c = (i / 50_000) % 2 == 0 ? (char)(x >> 24) : (char)(i % 13);
	}
	roundtrip(data);
}

fn void test_fast_forced_modes() @test => @pool()
{
	char[] data = mem::talloc_array(char, 200_000);
	uint x = 7;
	foreach (i, &c : data)
	{
		x = x * 1664525 + 1013904223;
		*c = (i / 30_000) % 2 == 0 ? (char)(x >> 28) : (char)(i % 11);
	}
	DeflateMode[*] modes = { AUTO, STORED, FIXED, DYNAMIC };
	foreach (mode : modes)
	{
		char[] comp = flate::deflate(tmem, data, mode)!!;
		assert(flate::inflate(tmem, comp)!! == data, "mode %d", (int)mode);
	}
	// Stored mode: 3 blocks of at most 65535 bytes, 5 bytes of header each.
	assert(flate::deflate(tmem, data, STORED)!!.len == data.len + 4 * 5);
	assert(flate::deflate(tmem, "hello world", STORED)!!.len == 1 + 2 + 2 + 11);
}

fn void test_fast_segments() @test => @pool()
{
	// Tiny segments force many segment boundaries, including a partial last one.
	char[] data = mem::talloc_array(char, 400_001);
	foreach (i, &c : data) *c = (char)((i * i) >> 9);
	DeflateParams p = flate::DEFAULT_PARAMS;
	p.segment = 100_000;
	DeflateMode[*] modes = { AUTO, STORED };
	foreach (mode : modes)
	{
		ByteWriter w;
		w.tinit();
		flate::deflate_fast(&w, data, mode, p)!!;
		assert(flate::inflate(tmem, w.array_view())!! == data);
	}
}

fn void test_fast_code_length_runs() @test => @pool()
{
	// Long runs of equal lengths and zeros exercise symbols 16, 17 and 18.
	char[] data = mem::talloc_array(char, 100_000);
	foreach (i, &c : data) *c = (i % 5000 < 4000) ? 'a' : (char)(i * 31);
	char[] comp = flate::deflate(tmem, data, DYNAMIC)!!;
	assert(flate::inflate(tmem, comp)!! == data);
}

module compress::flate::stream_test;
import std::io, compress::flate;

fn char[] sample(usz size) @private
{
	char[] data = mem::talloc_array(char, (sz)size);
	uint x = 4242;
	foreach (i, &c : data)
	{
		x = x * 1664525 + 1013904223;
		// Text-like regions, runs and noise so every block type shows up.
		switch ((int)((i / 40_000) % 3))
		{
			case 0:  *c = (char)(97 + (int)((x >> 24) & 7) + (int)(i % 5));
			case 1:  *c = (char)(i % 17);
			default: *c = (char)(x >> 24);
		}
	}
	return data;
}

fn void test_stream_roundtrip() @test => @pool()
{
	// Larger than the writer buffer so several chunks and slides happen.
	char[] data = sample(3_500_000);
	ByteWriter comp;
	comp.tinit();
	DeflateWriter w;
	w.init(mem, &comp);
	defer w.free();
	// Odd write sizes, including single bytes.
	usz off;
	usz step = 1;
	while (off < data.len)
	{
		usz k = step < data.len - off ? step : data.len - off;
		w.write(data[off:k])!!;
		off += k;
		step = step * 3 + 1;
		if (step > 700_000) step = 1;
	}
	w.close()!!;

	// One-shot decoder reads what the streaming encoder produced.
	assert(flate::inflate(tmem, comp.array_view())!! == data);

	// Streaming decoder with small reads.
	ByteReader src;
	src.init(comp.array_view());
	InflateReader r;
	r.init(mem, &src);
	defer r.free();
	ByteWriter back;
	back.tinit();
	char[777] chunk;
	while (true)
	{
		sz k = r.read(&chunk)!!;
		if (k == 0) break;
		back.write(chunk[:k])!!;
	}
	assert(back.array_view() == data);
	assert(r.leftover().len == 0);

	// Sink-based decoder.
	ByteReader src2;
	src2.init(comp.array_view());
	ByteWriter back2;
	back2.tinit();
	flate::inflate_to(mem, &back2, &src2)!!;
	assert(back2.array_view() == data);
}

fn void test_stream_leftover_and_empty() @test => @pool()
{
	// Empty stream.
	ByteWriter comp;
	comp.tinit();
	DeflateWriter w;
	w.init(mem, &comp);
	w.close()!!;
	w.free();
	assert(flate::inflate(tmem, comp.array_view())!!.len == 0);

	// Bytes after the stream stay available through leftover().
	char[] text = "streaming leftovers streaming leftovers";
	ByteWriter c2;
	c2.tinit();
	ByteReader tr;
	tr.init(text);
	flate::deflate_from(mem, &c2, &tr)!!;
	c2.write("TRAILER")!!;
	ByteReader src;
	src.init(c2.array_view());
	InflateReader r;
	r.init(mem, &src);
	defer r.free();
	char[256] out;
	sz k = r.read(&out)!!;
	assert(out[:k] == text);
	assert(r.read(&out)!! == 0);
	assert((String)r.leftover() == "TRAILER");
}
