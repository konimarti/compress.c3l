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

fn Gzip? uncompress(Allocator allocator, char[] src) @inline
{
	return uncompress_from_stream(allocator, &&io::wrap_bytes(src));
}

fn char[]? uncompress_bytes(Allocator allocator, char[] src) @inline => @pool()
{
	Gzip gz = uncompress_from_stream(tmem, &&io::wrap_bytes(src))!;
	return allocator::clone_slice(allocator, gz.uncompressed);
}

fn Gzip? uncompress_from_stream(Allocator allocator, InStream reader)
{
	Gzip gz = { .allocator = allocator };
	defer catch gz.free();

	reader.read((char[GzipHeader.sizeof]*)&gz.header)!;

	if (gz.header.id.val != GZIP_MAGIC) return CORRUPT_HEADER~;
	if (gz.header.cm != 8) return CORRUPT_HEADER~;
	if (gz.header.flg & 0xE0) return CORRUPT_HEADER~;

	Crc32 hash;
	hash.init();
	hash.update((char[GzipHeader.sizeof]*)&gz.header);

	if (gz.header.flg & FEXTRA)
	{
		ushort xlen = io::read_le_ushort(reader)!;
		hash.update((char[2]*)&xlen);
		gz.extra = allocator::malloc(allocator, xlen)[:xlen];
		reader.read(gz.extra)!;
		hash.update(gz.extra);
	}

	if (gz.header.flg & FNAME)
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
			gz.filename = codepage::decode(allocator, name.array_view(), CodePage.ISO_8859_1)!;
		};
	}

	if (gz.header.flg & FCOMMENT)
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
			gz.comment = codepage::decode(allocator, comment.array_view(), CodePage.ISO_8859_1)!;
		};
	}

	if (gz.header.flg & FHCRC)
	{
		ushort crc16 = (ushort)(hash.final() & 0xFFFF);
		ushort hcrc = io::read_le_ushort(reader)!;
		if (crc16 != hcrc) return CORRUPT_HEADER~;
	}

	gz.uncompressed = flate::inflate_stream(allocator, reader)!;

	uint crc32 = io::read_le_uint(reader)!;
	if (crc32 != crc32::hash(gz.uncompressed)) return CORRUPT_DATA~;

	uint isize = io::read_le_uint(reader)!;
	if (isize != (gz.uncompressed.len & 0xFFFFFFFF)) return CORRUPT_DATA~;

	return gz;
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
	char[*] data =
	x"1F8B080200000000020B179D010100FEFF008DEF02D201000000";

	Gzip gz = uncompress(mem, &data)!!;
	defer gz.free();
	io::printn(gz);
}

fn void gzip_fextra() @test
{
	char[*] data =
	x"1F8B080400000000020B040064617461010100FEFF008DEF02D201000000";

	Gzip gz = uncompress(mem, &data)!!;
	defer gz.free();
	io::printn(gz);
}

fn void gzip_fname() @test
{
	char[*] data =
	x"1F8B080800000000020B666F6F2E6300010100FEFF008DEF02D201000000";

	Gzip gz = uncompress(mem, &data)!!;
	defer gz.free();
	io::printn(gz);
}

fn void gzip_fcomment() @test
{
	char[*] data =
	x"1F8B081000000000020B68656C6C6F00010100FEFF008DEF02D201000000";

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
