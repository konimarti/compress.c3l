// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate::bitio;
import std::io;

struct FlateWriter
{
	OutStream writer;
	uint bits;
	uint nbits;
}

fn void FlateWriter.init(&self, OutStream w)
{
	*self = { .writer = w, .bits = 0, .nbits = 0 };
}

<*
 @param bits             : "Bits data to be written to bit stream"
 @param num_bits         : "Number of bits to write"
 @require num_bits >= 1  : "Number of bits must be at least 1"
 @require num_bits <= 32 : "Number of bits can not be larger than 32"
*>
fn void? FlateWriter.write_bits(&self, uint bits, uint num_bits)
{
	while (self.nbits + num_bits >= 32)
	{
		self.writer.write_byte((char)(self.bits & 0xff))!;
		self.bits >>= 8;
		self.nbits -= 8;
	}

	bits &= (1 << num_bits) - 1;
	self.bits |= bits << self.nbits;
	self.nbits += num_bits;
}

<*
 Flushes all bits written to `bits` to the underlying writer with zero padding.
*>
fn void? FlateWriter.flush(&self)
{
	int rem;
	while (self.nbits)
	{
		rem = self.nbits > 8 ? 8 : self.nbits;
		self.writer.write_byte((char)(self.bits & 0xff))!;
		self.bits >>= rem;
		self.nbits -= rem;
	}
	assert(self.nbits == 0);
}

<*
 FlateReader is a little-endian bit reader.
*>
struct FlateReader (InStream)
{
	InStream reader;
	ulong bits;
	uint  nbits;
}

fn void FlateReader.init(&self, InStream reader)
{
	*self = { .reader = reader, .bits = 0, .nbits = 0};
}

fn char? FlateReader.read_byte(&self) @dynamic
{
	assert(self.nbits == 0);
	return self.reader.read_byte();
}

fn usz? FlateReader.read(&self, char[] buf) @dynamic
{
	assert(self.nbits == 0);
	return self.reader.read(buf);
}

fn uint? FlateReader.peek_bits(&self, isz num_bits)
{
	while (self.nbits < num_bits)
	{
		// New bits are appended on the left
		char c = self.reader.read_byte()!;
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
fn uint? FlateReader.read_bits(&self, uint num_bits)
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
	ByteWriter byte_writer;
	byte_writer.init(mem);
	defer byte_writer.free();

	FlateWriter bw;
	bw.init(&byte_writer);

	for (uint i = 0; i < (1<<9); i++)
	{
		bw.write(0b1010011, 7);
	}
}

module compress::flate::test @test;
import compress::flate::bitio, std::io;

fn void test_bitwriter() => @pool()
{
	ByteWriter byte_writer;
	byte_writer.tinit();

	FlateWriter bw;
	bw.init(&byte_writer);

	bw.write_bits(0b1111101, 3)!!;
	assert(bw.nbits == 3);
	assert(bw.bits == 0b101);

	bw.write_bits(0b1001001, 7)!!;
	assert(bw.nbits == 10);
	assert(bw.bits == 0b1001001_101);

	bw.write_bits(0b10011, 5)!!;
	assert(bw.nbits == 15);
	assert(bw.bits == 0b10011_1001001_101);

	bw.flush()!!;
	char[] out = byte_writer.array_view();
	assert(out.len == 2);
	assert(out[0] == 0b01001101);
	assert(out[1] == 0b01001110);
}

fn void test_bitreader()
{
	ByteReader r = io::wrap_bytes({0b10000001, 0b1110});
	FlateReader br;
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
	FlateReader br;
	br.init(&r);
	assert(br.read_bits(5)!! == 3);
	assert(br.read_bits(9)!! == 0b101110100);
}

fn void test_bitreader_example()
{
	ByteReader r = io::wrap_bytes(x`2de8b1090000080341ace2700a160f011bd70f88cd15d7058ad590ef8d01`);
	FlateReader br;
	br.init(&r);
	assert(br.read_bits(1)!! == 1);
	assert(br.read_bits(2)!! == 0b10);
	assert(br.read_bits(5)!! == 5);  // HLIT
	assert(br.read_bits(5)!! == 8);  // HDIST
	assert(br.read_bits(4)!! == 15); // HDIST
}

