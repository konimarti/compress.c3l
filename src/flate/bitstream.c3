// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
<*
 @require Type.kindof == UNSIGNED_INT
*>
module compress::flate::bitstream{Type};
import std::io, std::collections::list, std::encoding::hex;

const BITS = Type.sizeof * 8;

faultdef NOT_ENOUGH_BITS;

struct BitStream (Printable)
{
	List{Type} list;
	usz bitpos;
}

fn void BitStream.init(&self, Allocator allocator) => self.list.init(allocator);
fn void BitStream.tinit(&self) => self.init(tmem);
fn void BitStream.free(&self) => self.list.free();

fn void BitStream.init_with_array(&self, Allocator allocator, Type[] values)
{
	self.list.init_with_array(allocator, values);
}
fn void BitStream.tinit_with_array(&self, Type[] values) => self.init_with_array(tmem, values);

fn usz? BitStream.to_format(&self, Formatter *f) @dynamic => @pool()
{
	$if Type == char:
	// Hex-encoded output is useful for debugging, e.g. with puff:
	// https://github.com/gcc-mirror/gcc/tree/master/zlib/contrib/puff
	return f.printf("%s", hex::tencode(self.list.array_view()));
	$else
	return f.printf("%s", self.list);
	$endif
}

<*
 @param num_bits         : "Number of bits to read"
 @require num_bits >= 1  : "Number of bits must be at least 1"
 @require num_bits <= 32 : "Number of bits can not be larger than 32"
*>
fn uint BitStream.read(&self, isz num_bits)
{
	if (self.list.len() == 0) return 0;

	uint v;
	usz available, rem;
	Type cur;

	while (num_bits && self.list.len())
	{
		cur = self.list[0];
		available = BITS - self.bitpos; // Available in current byte
		rem = num_bits > available ? available : num_bits;
		v = (v << rem) & (cur & ( ((1<<(self.bitpos+rem))-1) ^ ((1<<self.bitpos)-1)));

		self.bitpos += rem;
		while (self.bitpos > BITS)
		{
			(void)self.list.pop_first();
			self.bitspos -= BITS;
		}

		num_bits -= rem;
	}
	return v;
}

<*
 @param bits             : "Bits data to be written to bit stream"
 @param num_bits         : "Number of bits to write"
 @require num_bits >= 1  : "Number of bits must be at least 1"
 @require num_bits <= 32 : "Number of bits can not be larger than 32"
*>
fn void BitStream.write(&self, uint bits, isz num_bits)
{
	isz consumed, offset, n;

	bits &= (1U << num_bits) - 1;

	consumed = 0;
	offset = self.bitpos % BITS;
	if (offset > 0)
	{
		n = BITS - offset;
		if (n > num_bits) n = num_bits;
		self.list[^1] |= (Type)(bits<<offset);
		bits >>= n;
		consumed += n;
		num_bits -= n;
	}

	while (num_bits > 0)
	{
		self.list.push((Type)bits);
		n = (num_bits > BITS) ? BITS : num_bits;
		bits >>= n;
		consumed += n;
		num_bits -= n;
	}

	self.bitpos += consumed;
}

<*
 Fills up any unfinished data block with zeros. This is usually done before a
 flush.
*>
fn void BitStream.fill(&self)
{
	usz offset = self.bitpos % BITS;
	if (offset > 0) self.bitpos += BITS - offset;
}

<*
 Flush the internal bit stream buffer and return the data as a Type[].
 Unfinished elements are only flushed if fill is true.

 @param allocator : "Allocate returned Type[]"
 @param fill      : "Fill up unfinished elements befure flushing"
*>
fn Type[]? BitStream.flush(&self, Allocator allocator, bool fill = false)
{
	if (fill) self.fill();
	usz q = self.bitpos % BITS;
	usz len = self.bitpos / BITS;
	if (len == 0) return NOT_ENOUGH_BITS?;
	Type[] array = self.list.to_array(allocator)[:len];
	Type last = self.list[^1];
	self.bitpos -= BITS * len;
	self.list.clear();
	if (!fill && q > 0) self.list.push(last);
	return array;
}

module compress::flate::bench @benchmark;
import compress::flate::bitstream;

fn void test_bitstream_bench() @benchmark
{
	BitStream bs;
	bs.init(mem);
	defer bs.free();

	for (uint i = 0; i < (1<<9); i++)
	{
		bs.write(0b1010011, 7);
	}
}

module compress::flate::test @test;
import compress::flate::bitstream;

fn void test_bitstream_char() => @pool()
{
	BitStream{char} bs;
	bs.tinit();

	bs.write(0b1111101, 3);
	assert(bs.list.len() == 1);
	assert(bs.list[0] == 0b101, "byte[0]: %08b", bs.list[0]);

	bs.write(0b1001001, 7);
	assert(bs.list.len() == 2);
	assert(bs.list[0] == 0b01001101, "byte[0]: %08b", bs.list[0]);
	assert(bs.list[1] == 0b10, "byte[1]: %08b", bs.list[1]);

	bs.write(0b110011, 6);
	assert(bs.list.len() == 2);
	assert(bs.list[0] == 0b01001101, "byte[0]: %08b", bs.list[0]);
	assert(bs.list[1] == 0b11001110, "byte[1]: %08b", bs.list[1]);

	char[] flushed = bs.flush(tmem)!!;
	assert(bs.list.len() == 0);
	assert(flushed.len == 2);
	assert(flushed[0] == 0b01001101);
	assert(flushed[1] == 0b11001110);
}

fn void test_bitstream_ushort() => @pool()
{
	BitStream{ushort} bshort;
	bshort.tinit();

	bshort.write(0b1111101, 3);
	assert(bshort.list.len() == 1);
	assert(bshort.list[0] == 0b101, "ushort[0]: %08b", bshort.list[0]);

	bshort.write(0b1111101, 13);
	assert(bshort.list.len() == 1);
	assert(bshort.list[0] == 0b1111101101, "ushort[0]: %08b", bshort.list[0]);

	bshort.write(0b1, 1);
	assert(bshort.list.len() == 2);
	assert(bshort.list[1] == 0b1, "ushort[1]: %08b", bshort.list[1]);

	ushort[] fl = bshort.flush(tmem)!!;
	assert(bshort.list.len() == 1);
	assert(fl.len == 1);

	fl = bshort.flush(tmem, true)!!;
	assert(bshort.list.len() == 0);
	assert(fl.len == 1);
}

