// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::gzip;
import std::io, std::encoding::codepage, std::hash::crc32, compress::flate;

faultdef CORRUPT_HEADER, CORRUPT_DATA;

const ushort GZIP_MAGIC  = 0x8b1f;

const char FHCRC    = 1 << 1;
const char FEXTRA   = 1 << 2;
const char FNAME    = 1 << 3;
const char FCOMMENT = 1 << 4;

struct GzipHeader @packed
{
	UShortLE id;
	char cm;
	char flg;
	UIntLE mtime;
	char xfl;
	char os;
}

struct Gzip
{
	Allocator allocator;
	GzipHeader header;
	char[] extra;
	String filename;
	String comment;
	char[] uncompressed;
}

fn void Gzip.free(&self)
{
	if (!self.allocator) return;
	if (self.extra.ptr) allocator::free(self.allocator, self.extra.ptr);
	if (self.filename.len) self.filename.free(self.allocator);
	if (self.comment.len) self.comment.free(self.allocator);
	if (self.uncompressed.ptr) allocator::free(self.allocator, self.uncompressed.ptr);
}

fn Gzip? uncompress(Allocator allocator, char[] src)
{
	ByteReader reader = { .bytes = src };
	return uncompress_from_stream(allocator, &reader);
}

fn Gzip? uncompress_from_stream(Allocator allocator, InStream reader)
{
	Gzip gzip = { .allocator = allocator };
	defer catch gzip.free();

	reader.read((char[GzipHeader.sizeof]*)&gzip.header)!;

	if (gzip.header.id.val != GZIP_MAGIC) return CORRUPT_HEADER~;
	if (gzip.header.cm != 8) return CORRUPT_HEADER~;
	if (gzip.header.flg & 0xE0) return CORRUPT_HEADER~;

	Crc32 hash;
	hash.init();
	hash.update((char[GzipHeader.sizeof]*)&gzip.header);

	if (gzip.header.flg & FEXTRA)
	{
		ushort xlen = io::read_le_ushort(reader)!;
		hash.update((char[2]*)&xlen);
		@pool()
		{
			char[] extra = allocator::malloc(tmem, xlen)[:xlen];
			reader.read(extra)!;
			hash.update(extra);
			gzip.extra = codepage::decode(allocator, extra, CodePage.ISO_8859_1)!;
		};
	}

	if (gzip.header.flg & FNAME)
	{
		@pool()
		{
			ByteWriter name;
			name.tinit();
			while (try c = reader.read_byte())
			{
				hash.updatec(c);
				if (!c) break;
				name.write_byte(c)!;
			}
			gzip.filename = codepage::decode(allocator, name.array_view(), CodePage.ISO_8859_1)!;
		};
	}

	if (gzip.header.flg & FCOMMENT)
	{
		@pool()
		{
			ByteWriter comment;
			comment.tinit();
			while (try c = reader.read_byte())
			{
				hash.updatec(c);
				if (!c) break;
				comment.write_byte(c)!;
			}
			gzip.comment = codepage::decode(allocator, comment.array_view(), CodePage.ISO_8859_1)!;
		};
	}

	if (gzip.header.flg & FHCRC)
	{
		ushort crc16 = (ushort)(hash.final() & 0xFFFF);
		ushort hcrc = io::read_le_ushort(reader)!;
		if (crc16 != hcrc) return CORRUPT_HEADER~;
	}

	gzip.uncompressed = flate::inflate_stream(allocator, reader)!;

	uint crc32 = io::read_le_uint(reader)!;
	if (crc32 != crc32::hash(gzip.uncompressed)) return CORRUPT_DATA~;

	uint isize = io::read_le_uint(reader)!;
	if (isize != (gzip.uncompressed.len & 0xFFFFFFFF)) return CORRUPT_DATA~;

	return gzip;
}

fn char[]? compress(Allocator allocator, char[] src, bool hcrc = false,
	char[] extra = {}, String name = "", String comment = "")
{
	ByteWriter bw;
	bw.init(allocator);
	compress_to_stream(&bw, src, hcrc, extra, name, comment)!;
	return bw.array_view();
}

fn void? compress_to_stream(OutStream writer, char[] src, bool hcrc = false,
	char[] extra = {}, String name = "", String comment = "")
{
	GzipHeader header = {
		.id  = { .val = GZIP_MAGIC },
		.cm  = 8,
		.os  = 0xff,
	};

	if (hcrc) header.flg |= FHCRC;
	if (extra.len) header.flg |= FEXTRA;
	if (name.len) header.flg |= FNAME;
	if (comment.len) header.flg |= FCOMMENT;

	@pool()
	{
		ByteWriter h;
		h.tinit();
		h.write((char[GzipHeader.sizeof]*)&header)!;
		if (extra.len)
		{
			io::write_le_short(&h, (ushort)extra.len)!;
			h.write(extra)!;
		}
		if (name.len)
		{
			char[] zname = name.zstr_tcopy()[:name.len+1];
			char[] enc_name = codepage::encode(tmem, zname, CodePage.ISO_8859_1)!;
			h.write(enc_name)!;
		}
		if (comment.len)
		{
			char[] zcomment = comment.zstr_tcopy()[:comment.len+1];
			char[] enc_comment = codepage::encode(tmem, zcomment, CodePage.ISO_8859_1)!;
			h.write(enc_comment)!;
		}
		if (hcrc) io::write_le_short(&h,
			(ushort)(crc32::hash(h.array_view()) & 0xFF_FF))!;
		writer.write(h.array_view())!;
	};

	flate::deflate_stream(writer, src)!;

	io::write_le_int(writer, crc32::hash(src))!;
	io::write_le_int(writer, src.len & 0xFF_FF_FF_FF)!;
}

fn void gzip_fhcrc() @test
{
	char[*] data = {
	    0x1F, 0x8B, 0x08, 0x02, 0x00, 0x00, 0x00, 0x00, 0x02,
	    0x0B, 0x17, 0x9D, 0x01, 0x01, 0x00, 0xFE, 0xFF, 0x00,
	    0x8D, 0xEF, 0x02, 0xD2, 0x01, 0x00, 0x00, 0x00
	};
	Gzip gz = uncompress(mem, &data)!!;
	defer gz.free();
	io::printn(gz);
}

fn void gzip_fextra() @test
{
	char[*] data = {
	    0x1F, 0x8B, 0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x02, 0x0B,
	    0x04, 0x00, 0x64, 0x61, 0x74, 0x61, 0x01, 0x01, 0x00, 0xFE,
	    0xFF, 0x00, 0x8D, 0xEF, 0x02, 0xD2, 0x01, 0x00, 0x00, 0x00
	};
	Gzip gz = uncompress(mem, &data)!!;
	defer gz.free();
	io::printn(gz);
}

fn void gzip_fname() @test
{
	char[*] data = {
	    0x1F, 0x8B, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00, 0x02, 0x0B,
	    0x66, 0x6F, 0x6F, 0x2E, 0x63, 0x00, 0x01, 0x01, 0x00, 0xFE,
	    0xFF, 0x00, 0x8D, 0xEF, 0x02, 0xD2, 0x01, 0x00, 0x00, 0x00
	};
	Gzip gz = uncompress(mem, &data)!!;
	defer gz.free();
	io::printn(gz);
}

fn void gzip_fcomment() @test
{
	char[*] data = {
	    0x1F, 0x8B, 0x08, 0x10, 0x00, 0x00, 0x00, 0x00, 0x02, 0x0B,
	    0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0x01, 0x01, 0x00, 0xFE,
	    0xFF, 0x00, 0x8D, 0xEF, 0x02, 0xD2, 0x01, 0x00, 0x00, 0x00
	};
	Gzip gz = uncompress(mem, &data)!!;
	defer gz.free();
	io::printn(gz);
}

fn void gzip_round_trip() @test
{
	char[] extra = "extra data";
	String filename = "filename_éä.c";
	String comment = "comment\nline";

	char[] gz = compress(mem, "hello world", hcrc: true,
	extra: extra, name: filename, comment: comment)!!;
	defer allocator::free(mem, gz.ptr);

	Gzip decode = uncompress(mem, gz)!!;
	defer decode.free();
	io::printn(decode);
	assert(decode.extra == extra);
	assert(decode.filename == filename);
	assert(decode.comment == comment);
}
