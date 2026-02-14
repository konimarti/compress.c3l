// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::gzip;
import std::io, std::hash::crc32, compress::flate;

//  A compliant compressor must produce files with correct ID1,
//  ID2, CM, CRC32, and ISIZE, but may set all the other fields in
//  the fixed-length part of the header to default values (255 for
//  OS, 0 for all others).  The compressor must set all reserved
//  bits to zero

struct GzipHeader @packed
{
	UShortLE id;
	char cm;
	char flg;
	UIntLE mtime;
	char xfl;
	char os;
}

faultdef CORRUPT_HEADER, CORRUPT_DATA;

const char FHCRC    = 1 << 1;
const char FEXTRA   = 1 << 2;
const char FNAME    = 1 << 3;
const char FCOMMENT = 1 << 4;
const ushort MAGIC  = 0x8b1f;

fn char[]? uncompress(Allocator allocator, char[] src)
{
	ByteReader reader = { .bytes = src };
	return uncompress_stream(allocator, &reader);
}

fn char[]? uncompress_stream(Allocator allocator, InStream _reader)
{
	CrcReader reader;
	reader.init(_reader);

	GzipHeader header;
	reader.read(((char*)&header)[:GzipHeader.sizeof])!;

	if (header.id.val != MAGIC) return CORRUPT_HEADER~;
	if (header.cm != 8) return CORRUPT_HEADER~;
	if (header.flg & 0xE0) return CORRUPT_HEADER~;

	if (header.flg & FEXTRA)
	{
		// Skip extra data.
		ushort xlen = io::read_le_ushort(&reader)!;
		while (xlen--) reader.read_byte()!;
	}

	if (header.flg & FNAME)
	{
		// Skip filename.
		while (reader.read_byte()!);
	}

	if (header.flg & FCOMMENT)
	{
		// Skip filename.
		while (reader.read_byte()!);
	}

	if (header.flg & FHCRC)
	{
		ushort crc16 = (ushort)(reader.crc32() & 0xFFFF);
		ushort hcrc = io::read_le_ushort(&reader)!;
		if (crc16 != hcrc) return CORRUPT_HEADER~;
	}

	char[] data = flate::inflate_stream(allocator, &reader)!;

	uint crc32 = io::read_le_uint(&reader)!;
	if (crc32 != crc32::hash(data)) return CORRUPT_DATA~;

	return data;
}

fn void gzip_fhcrc() @test
{
	char[*] data = {
	    0x1F, 0x8B, 0x08, 0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
	    0x0B, 0x17, 0x9D, 0x01, 0x01, 0x00, 0xFE, 0xFF, 0x00,
	    0x8D, 0xEF, 0x02, 0xD2, 0x01, 0x00, 0x00, 0x00
	};
	@pool() { uncompress(tmem, &data)!!; };
}

fn void gzip_fextra() @test
{
	char[*] data = {
	    0x1F, 0x8B, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x02, 0x0B,
	    0x04, 0x00, 0x64, 0x61, 0x74, 0x61, 0x01, 0x01, 0x00, 0xFE,
	    0xFF, 0x00, 0x8D, 0xEF, 0x02, 0xD2, 0x01, 0x00, 0x00, 0x00
	};
	@pool() { uncompress(tmem, &data)!!; };
}

fn void gzip_fname() @test
{
	char[*] data = {
	    0x1F, 0x8B, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x02, 0x0B,
	    0x66, 0x6F, 0x6F, 0x2E, 0x63, 0x00, 0x01, 0x01, 0x00, 0xFE,
	    0xFF, 0x00, 0x8D, 0xEF, 0x02, 0xD2, 0x01, 0x00, 0x00, 0x00
	};
	@pool() { uncompress(tmem, &data)!!; };
}

fn void gzip_fcomment() @test
{
	char[*] data = {
	    0x1F, 0x8B, 0x08, 0x10, 0x00, 0x00, 0x00, 0x00, 0x02, 0x0B,
	    0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0x01, 0x01, 0x00, 0xFE,
	    0xFF, 0x00, 0x8D, 0xEF, 0x02, 0xD2, 0x01, 0x00, 0x00, 0x00
	};
	@pool() { uncompress(tmem, &data)!!; };
}

fn char[]? compress(Allocator allocator, char[] src)
{
	ByteWriter bw;
	bw.init(allocator);

	GzipHeader header = {
		.cm    = 8,
		.os    = 0xff,
	};
	header.id.val = MAGIC;

	bw.write(((char*)&header)[:GzipHeader.sizeof])!;

	flate::deflate_stream(&bw, src)!;

	io::write_le_int(&bw, crc32::hash(src))!;
	io::write_le_int(&bw, src.len & 0xFFFFFFFF)!;

	return bw.array_view();
}

struct CrcReader (InStream)
{
	InStream reader;
	Crc32 crc;
}

fn void CrcReader.init(&self, InStream reader)
{
	self.reader = reader;
	self.crc.init();
}

fn char? CrcReader.read_byte(&self) @dynamic
{
	char c = self.reader.read_byte()!;
	self.crc.updatec(c);
	return c;
}


fn usz? CrcReader.read(&self, char[] bytes) @dynamic
{
	usz n = self.reader.read(bytes)!;
	self.crc.update(bytes[:n]);
	return n;
}

fn uint CrcReader.crc32(&self) =>self.crc.final();
fn void CrcReader.reset_crc(&self) => self.crc.init();
