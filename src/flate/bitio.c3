// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
<*
 @require Type.kindof == UNSIGNED_INT
*>
module compress::flate::bitio<Type>;
import std::io, std::collections::list, std::encoding::hex;

const BITS = Type.sizeof * 8;

faultdef NOT_ENOUGH_BITS;

struct BitWriter (Printable)
{
	List{Type} list;
	usz bitpos;
}

fn void BitWriter.init(&self, Allocator allocator) => self.list.init(allocator);
fn void BitWriter.tinit(&self) => self.init(tmem);
fn void BitWriter.free(&self) => self.list.free();

fn usz? BitWriter.to_format(&self, Formatter *f) @dynamic => @pool()
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
 @param bits             : "Bits data to be written to bit stream"
 @param num_bits         : "Number of bits to write"
 @require num_bits >= 1  : "Number of bits must be at least 1"
 @require num_bits <= 32 : "Number of bits can not be larger than 32"
*>
fn void BitWriter.write(&self, uint bits, isz num_bits)
{
	isz consumed, offset, n;

	bits &= (1U << num_bits) - 1;
	// io::printfn("write %d bits: %4d %0*b", num_bits, bits, num_bits, bits);

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
fn void BitWriter.fill(&self)
{
	usz offset = self.bitpos % BITS;
	if (offset > 0) self.bitpos += BITS - offset;
}

<*
 Flush the internal buffer and return the data as a Type[].
 Unfinished elements are only flushed if fill is true.

 @param allocator : "Allocate returned Type[]"
 @param fill      : "Fill up unfinished elements befure flushing"
*>
fn Type[]? BitWriter.flush(&self, Allocator allocator, bool fill = false)
{
	if (fill) self.fill();
	usz q = self.bitpos % BITS;
	usz len = self.bitpos / BITS;
	if (len == 0) return NOT_ENOUGH_BITS~;
	Type[] array = self.list.to_array(allocator)[:len];
	Type last = self.list[^1];
	self.bitpos -= BITS * len;
	self.list.clear();
	if (!fill && q > 0) self.list.push(last);
	return array;
}

struct BitReader (InStream)
{
	InStream reader;
	ulong bits;
	isz   nbits;
}

fn void BitReader.init(&self, InStream reader)
{
	*self = { .reader = reader, .bits = 0, .nbits = 0};
}

fn char? BitReader.read_byte(&self) @dynamic
{
	assert(self.nbits % 8 == 0);
	return self.reader.read_byte();
}

fn usz? BitReader.read(&self, char[] buf) @dynamic
{
	assert(self.nbits % 8 == 0);
	return self.reader.read(buf);
}

fn uint? BitReader.peek_bits(&self, isz num_bits)
{
	while (self.nbits < num_bits)
	{
		// New bits are appended on the left
		char c = self.reader.read_byte() ?? 0;
		self.bits |= (ulong)c << self.nbits;
		self.nbits += 8;
	}

	ulong mask = (1UL << num_bits) - 1;
	return (uint)(self.bits & mask);
}

<*
 @param num_bits         : "Number of bits to read"
 @require num_bits >= 1  : "Number of bits must be at least 1"
 @require num_bits <= 32 : "Number of bits can not be larger than 32"
*>
fn uint? BitReader.read_bits(&self, isz num_bits)
{
	uint v = self.peek_bits(num_bits)!;
	self.bits >>= num_bits;
	self.nbits -= num_bits;
	return v;
}

module compress::flate::bench @benchmark;
import compress::flate::bitio;

fn void test_bitwriter_bench() @benchmark
{
	BitWriter{char} bw;
	bw.init(mem);
	defer bw.free();

	for (uint i = 0; i < (1<<9); i++)
	{
		bw.write(0b1010011, 7);
	}
}

module compress::flate::test @test;
import compress::flate::bitio, std::io;

fn void test_bitwriter_char() => @pool()
{
	bitio::BitWriter{char} bw;
	bw.tinit();

	bw.write(0b1111101, 3);
	assert(bw.list.len() == 1);
	assert(bw.list[0] == 0b101, "byte[0]: %08b", bw.list[0]);

	bw.write(0b1001001, 7);
	assert(bw.list.len() == 2);
	assert(bw.list[0] == 0b01001101, "byte[0]: %08b", bw.list[0]);
	assert(bw.list[1] == 0b10, "byte[1]: %08b", bw.list[1]);

	bw.write(0b110011, 6);
	assert(bw.list.len() == 2);
	assert(bw.list[0] == 0b01001101, "byte[0]: %08b", bw.list[0]);
	assert(bw.list[1] == 0b11001110, "byte[1]: %08b", bw.list[1]);

	char[] flushed = bw.flush(tmem)!!;
	assert(bw.list.len() == 0);
	assert(flushed.len == 2);
	assert(flushed[0] == 0b01001101);
	assert(flushed[1] == 0b11001110);
}

fn void test_bitwriter_ushort() => @pool()
{
	bitio::BitWriter{ushort} bshort;
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

fn void test_bitreader_char()
{
	ByteReader r = io::wrap_bytes({0b10000001, 0b1110});
	bitio::BitReader{char} br;
	br.init(&r);
	assert(br.read_bits(1)!! == 1);
	assert(br.read_bits(2)!! == 0);
	assert(br.read_bits(3)!! == 0);
	assert(br.read_bits(1)!! == 0);
	assert(br.read_bits(1)!! == 1);
	assert(br.read_bits(2)!! == 2);
	assert(br.read_bits(2)!! == 3);
}

fn void test_bitreader_boundary()
{
	ByteReader r = io::wrap_bytes({0b10000011, 0b101110});
	bitio::BitReader{char} br;
	br.init(&r);
	assert(br.read_bits(5)!! == 3);
	assert(br.read_bits(9)!! == 0b101110100);
}

fn void test_bitreader_example()
{
	ByteReader r = io::wrap_bytes(x`2de8b1090000080341ace2700a160f011bd70f88cd15d7058ad590ef8d01`);
	bitio::BitReader{char} br;
	br.init(&r);
	assert(br.read_bits(1)!! == 1);
	assert(br.read_bits(2)!! == 0b10);
	assert(br.read_bits(5)!! == 5);  // HLIT
	assert(br.read_bits(5)!! == 8);  // HDIST
	assert(br.read_bits(4)!! == 15); // HDIST
}

