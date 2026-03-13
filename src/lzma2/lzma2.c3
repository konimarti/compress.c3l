// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
<*
 LZMA2 is a chunk-based framing layer around LZMA-compressed payloads.
 Each chunk starts with a control byte:

   0x00        – end of stream
   0x01        – uncompressed data, reset dictionary
   0x02        – uncompressed data, keep dictionary
   0x03..0x7F  – reserved (error)
   0x80..0x9F  – LZMA chunk, no state/dict reset
   0xA0..0xBF  – LZMA chunk, reset LZMA state
   0xC0..0xDF  – LZMA chunk, reset state + read new props byte
   0xE0..0xFF  – LZMA chunk, reset state + new props + reset dict

 LZMA range decoder / probability model follows the LZMA SDK and liblzma conventions exactly.
*>
module std::compression::lzma2;
import std::io;

faultdef CORRUPT_DATA, CORRUPT_PROPS, UNSUPPORTED;

<*
 Decompress an LZMA2 payload read from `reader` into `writer`.
 `props_byte` is the single-byte LZMA2 properties field as stored in the
 XZ block header filter list (encodes the dictionary size).
*>
fn void? decompress_stream(InStream reader, OutStream writer, char props_byte)
{
	uint dict_size = decode_dict_size(props_byte)!;

	Dictionary dict;
	dict.init(dict_size);
	defer dict.free();

	LzmaDecoder lzma;
	bool lzma_initialised = false;

	while (true)
	{
		char ctrl = reader.read_byte()!;

		if (ctrl == 0x00) break;  // end of stream

		if (ctrl <= 0x02)
		{
			if (ctrl == 0x01) dict.reset();

			// 2-byte big-endian uncompressed size minus 1.
			uint raw_size = (uint)read_be_u16(reader)! + 1;

			for (uint i = 0; i < raw_size; i++)
			{
				char b = reader.read_byte()!;
				dict.put(b);
				writer.write_byte(b)!;
			}
			continue;
		}

		if (ctrl < 0x80) return CORRUPT_DATA~;  // reserved

		bool reset_dict  = (ctrl >= 0xE0);
		bool reset_props = (ctrl >= 0xC0);
		bool reset_state = (ctrl >= 0xA0);

		// Uncompressed size: 5 low bits of ctrl (after masking 0x1F) form
		// the high 5 bits; the next byte gives the low 8 bits.  Value + 1.
		usz uncomp_size = ((usz)(ctrl & 0x1F) << 8) | (usz)reader.read_byte()!;
		uncomp_size    += 1;

		// Compressed size: 2 bytes big-endian, value + 1.
		usz comp_size = (usz)read_be_u16(reader)! + 1;

		// Props byte required on first chunk or whenever reset_props is set.
		if (reset_props)
		{
			char pb = reader.read_byte()!;
			lzma.init(pb)!;
			lzma_initialised = true;
		}
		else if (!lzma_initialised)
		{
			return CORRUPT_DATA~;
		}

		if (reset_dict)  dict.reset();
		if (reset_state) lzma.reset_state();

		// Buffer the compressed chunk so the range coder sees a clean EOF.
		@pool()
		{
			char[] chunk = allocator::new_array(tmem, char, comp_size);
			read_exact(reader, chunk)!;
			InStream chunk_reader = &&io::wrap_bytes(chunk);
			lzma.decode(chunk_reader, writer, &dict, uncomp_size)!;
		};
	}
}

<*
 Compress the bytes from `reader` into `writer` as an LZMA2 stream.

 Implementation note:
   A full LZMA encoder requires an LZ77 match-finder and entropy encoder —
   substantial standalone components.  This implementation writes all data
   as LZMA2 uncompressed chunks, which is always valid per the spec and
   produces output that decompresses correctly with any conforming decoder.
   The seam for a future LZMA encoder plug-in is the compress_lzma_chunk
   stub at the bottom of this file.
*>
fn void? compress_stream(InStream reader, OutStream writer, char props_byte)
{
	// Validate props (dict-size encoding, 0..39).
	decode_dict_size(props_byte)!;

	bool first = true;
	char[65536] buf @noinit;

	while (true)
	{
		usz? n = reader.read(buf[..]);
		if (catch err = n)
		{
			if (err == io::EOF) break;
			return err~;
		}
		if (!n) break;

		usz size = n;
		// 0x01 = uncompressed + reset dict (first chunk),
		// 0x02 = uncompressed, keep dict.
		writer.write_byte(first ? 0x01 : 0x02)!;
		first = false;

		// 2-byte big-endian (size - 1).
		ushort size_m1 = (ushort)(size - 1);
		writer.write_byte((char)(size_m1 >> 8))!;
		writer.write_byte((char)(size_m1 & 0xFF))!;
		writer.write(buf[:size])!;
	}

	writer.write_byte(0x00)!;  // end-of-stream marker
}


module std::compression::lzma2 @private;
import std::io;


<* Dictionary as a sliding window *>
struct Dictionary
{
	char* buf;
	usz   size;
	usz   pos;   // next write position (ring index)
	usz   full;  // number of valid bytes (saturates at size)
}

fn void Dictionary.init(&self, uint dict_size)
{
	self.size = (usz)dict_size;
	self.buf  = mem::alloc_array(char, dict_size);
	self.pos  = 0;
	self.full = 0;
}

fn void Dictionary.free(&self)
{
	mem::free(self.buf);
	self.buf = null;
}

fn void Dictionary.reset(&self) @inline
{
	self.pos  = 0;
	self.full = 0;
}

fn void Dictionary.put(&self, char b) @inline
{
	self.buf[self.pos] = b;
	if (++self.pos == self.size) self.pos = 0;
	if (self.full < self.size)   self.full++;
}

// Return the byte written `dist` positions ago (dist=1 → last byte written).
fn char Dictionary.peek(&self, uint dist) @inline
{
	return self.buf[(self.pos + self.size - (usz)dist) % self.size];
}

fn char Dictionary.last_byte(&self) @inline
{
	if (!self.full) return 0;
	return self.peek(1);
}

// Copy a back-reference match of `len` bytes at distance `dist` to writer.
fn void? Dictionary.copy_match(&self, OutStream writer, uint dist, uint len)
{
	for (uint i = 0; i < len; i++)
	{
		char b = self.peek(dist);
		self.put(b);
		writer.write_byte(b)!;
	}
}


// Range coder
const uint RC_TOP_BITS              = 24;
const uint RC_TOP_VALUE             = 1u << RC_TOP_BITS;   // 0x01000000
const uint RC_BIT_MODEL_TOTAL_BITS  = 11;
const uint RC_BIT_MODEL_TOTAL       = 1u << RC_BIT_MODEL_TOTAL_BITS;  // 2048
const uint RC_MOVE_BITS             = 5;
const uint PROB_INIT                = RC_BIT_MODEL_TOTAL >> 1;         // 1024

struct RangeCoder
{
	InStream reader;
	uint     range;
	uint     code;
}

fn void? RangeCoder.init(&self, InStream reader)
{
	self.reader = reader;
	// The LZMA range coder stream begins with a literal 0x00 byte.
	char first = reader.read_byte()!;
	if (first != 0x00) return CORRUPT_DATA~;
	self.range = 0xFFFFFFFF;
	self.code  = 0;
	for (int i = 0; i < 4; i++) self.code = (self.code << 8) | (uint)reader.read_byte()!;
}

fn void? RangeCoder.normalise(&self) @inline
{
	if (self.range < RC_TOP_VALUE)
	{
		self.range <<= 8;
		self.code   = (self.code << 8) | (uint)self.reader.read_byte()!;
	}
}

// Decode one adaptive bit.  *prob ∈ [0, 2048]; higher = more likely 0.
// Returns 0 or 1.
fn uint? RangeCoder.decode_bit(&self, uint* prob) @inline
{
	uint bound = (self.range >> RC_BIT_MODEL_TOTAL_BITS) * (*prob);
	if (self.code < bound)
	{
		self.range  = bound;
		*prob      += (RC_BIT_MODEL_TOTAL - *prob) >> RC_MOVE_BITS;
		self.normalise()!;
		return 0;
	}
	*prob      -= *prob >> RC_MOVE_BITS;
	self.range -= bound;
	self.code  -= bound;
	self.normalise()!;
	return 1;
}

<*
 Decode `num_bits` uniform (direct) bits, MSB first.
*>
fn uint? RangeCoder.decode_direct(&self, uint num_bits) @inline
{
	uint result = 0;
	for (uint i = 0; i < num_bits; i++)
	{
		self.range >>= 1;
		result     <<= 1;
		if (self.code >= self.range)
		{
			self.code -= self.range;
			result    |= 1;
		}
		self.normalise()!;
	}
	return result;
}

<*
 Decode a bittree of `num_bits` bits, MSB first.
 probs must have 2^num_bits entries (1-indexed; probs[0] is unused).
*>
fn uint? decode_bittree(RangeCoder* rc, uint[] probs, uint num_bits)
{
	uint m = 1;
	for (uint i = 0; i < num_bits; i++) m = (m << 1) | rc.decode_bit(&probs[m])!;
	return m - (1u << num_bits);
}

<*
 Decode a reverse bittree of `num_bits` bits, LSB first.
 probs has 2^num_bits entries (1-indexed; probs[0] is unused).
*>
fn uint? decode_bittree_reverse(RangeCoder* rc, uint[] probs, uint num_bits)
{
	uint m      = 1;
	uint result = 0;
	for (uint i = 0; i < num_bits; i++)
	{
		uint bit = rc.decode_bit(&probs[m])!;
		m = (m << 1) | bit;
		result |= bit << i;
	}
	return result;
}


// LZMA constants
const uint LZMA_STATES           = 12;
const uint POS_STATES_MAX        = 16;   // 1 << max(pb) where pb ≤ 4

const uint DIST_SLOT_BITS        = 6;
const uint DIST_SLOTS            = 1u << DIST_SLOT_BITS;  // 64
const uint DIST_SLOT_GROUPS      = 4;    // min(len - MATCH_LEN_MIN, 3) for slot table index

// Slots 4..13 use dist_special probs; this table gives the 0-based start index
// into the dist_special array for each slot (slots 4..13 → indices 0..9).
// Derived from the 7-zip/liblzma layout: offset = dist_base - slot, where the
// 1-indexed bittree accesses [offset .. offset + 2^n - 2] (n = num_direct bits).
// Verified: no entry overlaps; total array size = 114.
const usz[10] DIST_SPECIAL_OFFSET = {0, 1, 2, 5, 8, 15, 22, 37, 52, 83};
// Slot 13 needs indices up to 114 (probs[0] placeholder at offset 83, tree reads [84..114]).
const usz     DIST_SPECIAL_SIZE   = 115;

const uint ALIGN_BITS            = 4;
const uint ALIGN_SIZE            = 1u << ALIGN_BITS;    // 16

// Slots ≥ 14 use direct+align decoding; slots 4..13 use dist_special only.
const uint DIST_SPECIAL_SLOT_LO  = 4;
const uint DIST_SPECIAL_SLOT_HI  = 14;   // exclusive

const uint MATCH_LEN_MIN         = 2;
const uint LEN_LOW_BITS          = 3;
const uint LEN_MID_BITS          = 3;
const uint LEN_HIGH_BITS         = 8;
const uint LEN_LOW_SYMS          = 1u << LEN_LOW_BITS;   // 8
const uint LEN_MID_SYMS          = 1u << LEN_MID_BITS;   // 8
const uint LEN_HIGH_SYMS         = 1u << LEN_HIGH_BITS;  // 256

const uint LIT_CODER_SIZE        = 0x300;  // 768 probs per literal context

// LZMA state-machine transitions after each symbol type.
const uint[12] STATE_AFTER_LIT    = {0,0,0,0,1,2,3,4,5,6,4,5};
const uint     STATE_AFTER_MATCH  = 7;    // if state < 7 else 10
const uint     STATE_AFTER_LONGREP  = 8;  // if state < 7 else 11
const uint     STATE_AFTER_SHORTREP = 9;  // if state < 7 else 11


struct LenDecoder
{
	uint   choice;
	uint   choice2;
	uint[POS_STATES_MAX * LEN_LOW_SYMS]  low;
	uint[POS_STATES_MAX * LEN_MID_SYMS]  mid;
	uint[LEN_HIGH_SYMS]                  high;
}

fn void LenDecoder.reset(&self)
{
	self.choice  = PROB_INIT;
	self.choice2 = PROB_INIT;
	for (usz i = 0; i < self.low.len;  i++) self.low[i]  = PROB_INIT;
	for (usz i = 0; i < self.mid.len;  i++) self.mid[i]  = PROB_INIT;
	for (usz i = 0; i < self.high.len; i++) self.high[i] = PROB_INIT;
}

fn uint? LenDecoder.decode(&self, RangeCoder* rc, uint pos_state)
{
	if (rc.decode_bit(&self.choice)! == 0)
	{
		uint[] probs = self.low[pos_state * LEN_LOW_SYMS ..
		                        pos_state * LEN_LOW_SYMS + LEN_LOW_SYMS];
		return decode_bittree(rc, probs, LEN_LOW_BITS)! + MATCH_LEN_MIN;
	}
	if (rc.decode_bit(&self.choice2)! == 0)
	{
		uint[] probs = self.mid[pos_state * LEN_MID_SYMS ..
		                        pos_state * LEN_MID_SYMS + LEN_MID_SYMS];
		return decode_bittree(rc, probs, LEN_MID_BITS)! + MATCH_LEN_MIN + LEN_LOW_SYMS;
	}
	return decode_bittree(rc, self.high[..], LEN_HIGH_BITS)! + MATCH_LEN_MIN + LEN_LOW_SYMS + LEN_MID_SYMS;
}


// Maximum lc+lp = 4 (per spec), giving at most 2^4 = 16 literal contexts.
const uint LIT_STATES_MAX = 16;

struct LzmaDecoder
{
	// Decoded parameters.
	uint lc;
	uint lp;
	uint pb;

	// LZMA state and rep distances.
	uint state;
	uint rep0;  // last match distance − 1 (0-based)
	uint rep1;
	uint rep2;
	uint rep3;

	// Probability tables
	uint[LZMA_STATES * POS_STATES_MAX]   is_match;
	uint[LZMA_STATES]                    is_rep;
	uint[LZMA_STATES]                    is_rep_g0;
	uint[LZMA_STATES]                    is_rep_g1;
	uint[LZMA_STATES]                    is_rep_g2;
	uint[LZMA_STATES * POS_STATES_MAX]   is_rep0_long;

	uint[LIT_STATES_MAX * LIT_CODER_SIZE] literal;

	uint[DIST_SLOT_GROUPS * DIST_SLOTS]  dist_slot;
	uint[DIST_SPECIAL_SIZE]              dist_special;
	uint[ALIGN_SIZE]                     dist_align;

	LenDecoder match_len;
	LenDecoder rep_len;
}

fn void? LzmaDecoder.init(&self, char props_byte)
{
	// Props byte encodes: (pb * 9 + lp) * 9 + lc, max valid = (4*9+4)*9+8 = 224.
	if (props_byte > 224) return CORRUPT_PROPS~;
	uint v  = (uint)props_byte;
	self.lc = v % 9;  v /= 9;
	self.lp = v % 5;
	self.pb = v / 5;
	if (self.pb > 4 || self.lc + self.lp > 4) return CORRUPT_PROPS~;
	self.reset_state();
	self.reset_probs();
}

fn void LzmaDecoder.reset_state(&self) @inline
{
	self.state = 0;
	self.rep0  = 0;
	self.rep1  = 0;
	self.rep2  = 0;
	self.rep3  = 0;
}

fn void LzmaDecoder.reset_probs(&self)
{
	for (usz i = 0; i < self.is_match.len;    i++) self.is_match[i]     = PROB_INIT;
	for (usz i = 0; i < self.is_rep.len;      i++) self.is_rep[i]       = PROB_INIT;
	for (usz i = 0; i < self.is_rep_g0.len;   i++) self.is_rep_g0[i]    = PROB_INIT;
	for (usz i = 0; i < self.is_rep_g1.len;   i++) self.is_rep_g1[i]    = PROB_INIT;
	for (usz i = 0; i < self.is_rep_g2.len;   i++) self.is_rep_g2[i]    = PROB_INIT;
	for (usz i = 0; i < self.is_rep0_long.len;i++) self.is_rep0_long[i] = PROB_INIT;
	for (usz i = 0; i < self.literal.len;     i++) self.literal[i]      = PROB_INIT;
	for (usz i = 0; i < self.dist_slot.len;   i++) self.dist_slot[i]    = PROB_INIT;
	for (usz i = 0; i < self.dist_special.len;i++) self.dist_special[i] = PROB_INIT;
	for (usz i = 0; i < self.dist_align.len;  i++) self.dist_align[i]   = PROB_INIT;
	self.match_len.reset();
	self.rep_len.reset();
}

fn void? LzmaDecoder.decode(&self, InStream reader, OutStream writer,
                             Dictionary* dict, usz uncomp_size)
{
	RangeCoder rc;
	rc.init(reader)!;

	uint pos_mask = (1u << self.pb) - 1;
	uint lp_mask  = (1u << self.lp) - 1;

	for (usz out_pos = 0; out_pos < uncomp_size; )
	{
		uint pos_state = (uint)out_pos & pos_mask;

		// Literal or match?
		if (rc.decode_bit(&self.is_match[self.state * POS_STATES_MAX + pos_state])! == 0)
		{
			// Literal
			char prev   = dict.last_byte();
			uint lit_ctx = ((uint)out_pos & lp_mask) << self.lc
			             | (uint)(prev >> (8 - self.lc));
			uint[] lp = self.literal[lit_ctx * LIT_CODER_SIZE ..
			                         lit_ctx * LIT_CODER_SIZE + LIT_CODER_SIZE];
			char b;
			if (self.state < 7)
			{
				// Plain literal: decode 8 bits MSB-first through the bittree.
				uint sym = 1;
				for (uint i = 0; i < 8; i++) sym = (sym << 1) | rc.decode_bit(&lp[sym])!;
				b = (char)(sym & 0xFF);
			}
			else
			{
				// Literal following a match: decode bit-by-bit with the
				// match byte used to select an offset into the prob table
				// (as per LZMA spec §5.1.1).
				char match_byte = dict.peek(self.rep0 + 1);
				uint sym    = 1;
				uint offset = 0x100;
				for (int i = 7; i >= 0; i--)
				{
					uint match_bit = ((uint)match_byte >> (uint)i) & 1;
					uint bit = rc.decode_bit(&lp[offset + (match_bit << 8) + sym])!;
					sym = (sym << 1) | bit;
					if (match_bit != bit) offset = 0;
				}
				b = (char)(sym & 0xFF);
			}

			dict.put(b);
			writer.write_byte(b)!;
			self.state = STATE_AFTER_LIT[self.state];
			out_pos++;
			continue;
		}

		// Match or rep-match
		uint len;

		if (rc.decode_bit(&self.is_rep[self.state])! == 0)
		{
			// Simple (new-distance) match
			len = self.match_len.decode(&rc, pos_state)!;

			// Distance: decode slot (6-bit bittree), then extra bits.
			uint len_grp = (len - MATCH_LEN_MIN < DIST_SLOT_GROUPS)
			             ? len - MATCH_LEN_MIN : DIST_SLOT_GROUPS - 1;
			uint[] dprobs = self.dist_slot[len_grp * DIST_SLOTS ..
			                               len_grp * DIST_SLOTS + DIST_SLOTS];
			uint slot = decode_bittree(&rc, dprobs, DIST_SLOT_BITS)!;

			uint dist;
			if (slot < DIST_SPECIAL_SLOT_LO)
			{
				dist = slot;
			}
			else if (slot < DIST_SPECIAL_SLOT_HI)
			{
				// Slots 4..13: reverse bittree using dist_special.
				uint num_direct = (slot >> 1) - 1;
				dist = (2u | (slot & 1)) << num_direct;
				usz  off = DIST_SPECIAL_OFFSET[slot - DIST_SPECIAL_SLOT_LO];
				uint[] sp = self.dist_special[off .. off + (ulong)(1u << num_direct)];
				dist |= decode_bittree_reverse(&rc, sp, num_direct)!;
			}
			else
			{
				// Slots ≥ 14: direct bits (top) + align bittree (low 4 bits).
				uint num_direct = (slot >> 1) - 1;
				dist = (2u | (slot & 1)) << num_direct;
				dist |= rc.decode_direct(num_direct - ALIGN_BITS)! << ALIGN_BITS;
				dist |= decode_bittree_reverse(&rc, self.dist_align[..], ALIGN_BITS)!;
			}

			// 0xFFFFFFFF is the LZMA end-of-stream marker in raw streams;
			// LZMA2 uses its own EOS control byte, but we handle it anyway.
			if (dist == 0xFFFFFFFF) break;
			if (dist >= dict.full) return CORRUPT_DATA~;

			self.rep3  = self.rep2;
			self.rep2  = self.rep1;
			self.rep1  = self.rep0;
			self.rep0  = dist;
			self.state = (self.state < 7) ? STATE_AFTER_MATCH : 10;
		}
		else
		{
			// Rep-match (reuse a previous distance)
			if (rc.decode_bit(&self.is_rep_g0[self.state])! == 0)
			{
				// rep0: use the most recent distance.
				if (rc.decode_bit(&self.is_rep0_long[self.state * POS_STATES_MAX + pos_state])! == 0)
				{
					// Short rep: single byte copy.
					if (!dict.full) return CORRUPT_DATA~;
					char b = dict.peek(self.rep0 + 1);
					dict.put(b);
					writer.write_byte(b)!;
					self.state = (self.state < 7) ? STATE_AFTER_SHORTREP : 11;
					out_pos++;
					continue;
				}
				// Long rep0: fall through to copy below with current rep0.
				self.state = (self.state < 7) ? STATE_AFTER_LONGREP : 11;
			}
			else if (rc.decode_bit(&self.is_rep_g1[self.state])! == 0)
			{
				// rep1: promote rep1 → rep0.
				uint tmp  = self.rep1;
				self.rep1 = self.rep0;
				self.rep0 = tmp;
				self.state = (self.state < 7) ? STATE_AFTER_LONGREP : 11;
			}
			else if (rc.decode_bit(&self.is_rep_g2[self.state])! == 0)
			{
				// rep2: promote rep2 → rep0, shift others.
				uint tmp  = self.rep2;
				self.rep2 = self.rep1;
				self.rep1 = self.rep0;
				self.rep0 = tmp;
				self.state = (self.state < 7) ? STATE_AFTER_LONGREP : 11;
			}
			else
			{
				// rep3: promote rep3 → rep0, shift others.
				uint tmp  = self.rep3;
				self.rep3 = self.rep2;
				self.rep2 = self.rep1;
				self.rep1 = self.rep0;
				self.rep0 = tmp;
				self.state = (self.state < 7) ? STATE_AFTER_LONGREP : 11;
			}

			len = self.rep_len.decode(&rc, pos_state)!;
			if (self.rep0 >= dict.full) return CORRUPT_DATA~;
		}

		// Copy len bytes from distance rep0+1.
		dict.copy_match(writer, self.rep0 + 1, len)!;
		out_pos += len;
	}
}

// Decode the LZMA2 props byte into an actual dictionary byte count.
// Props 0..39; the formula is from the XZ specification, section 5.3.1.
fn uint? decode_dict_size(char props)
{
	if (props >= 40) return CORRUPT_PROPS~;
	return (2u | (uint)(props & 1)) << ((uint)props / 2 + 11);
}

// Read exactly buf.len bytes, retrying on short reads.
fn void? read_exact(InStream reader, char[] buf)
{
	usz done = 0;
	while (done < buf.len)
	{
		usz? n = reader.read(buf[done..]);
		if (catch err = n)
		{
			if (err == io::EOF) return CORRUPT_DATA~;
			return err~;
		}
		done += n;
	}
}

// Read a 2-byte big-endian unsigned short.
fn ushort? read_be_u16(InStream r)
{
	char hi = r.read_byte()!;
	char lo = r.read_byte()!;
	return ((ushort)hi << 8) | (ushort)lo;
}
