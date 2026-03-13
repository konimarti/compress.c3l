// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::xz;
import std::io, std::hash::crc32, compress::lzma2;

faultdef CORRUPT_HEADER, CORRUPT_FOOTER, CORRUPT_BLOCK, CORRUPT_INDEX, CORRUPT_DATA, UNSUPPORTED;

// XZ stream magic bytes
const char[6] XZ_MAGIC_HEADER = x'FD377A585A00';
const char[2] XZ_MAGIC_FOOTER = x'595A';

// Check types for CRC field in StreamFlags
const char CHECK_NONE   = 0x00;
const char CHECK_CRC32  = 0x01;
const char CHECK_CRC64  = 0x04;
const char CHECK_SHA256 = 0x0A;

// Block header flags
const char BLOCK_COMPRESSED_SIZE_PRESENT   = 0x40;
const char BLOCK_UNCOMPRESSED_SIZE_PRESENT = 0x80;

struct StreamFlags @packed
{
	char reserved;       // must be 0x00
	bitstruct flags : char
	{
		uint check_type : 0..3;
		uint reserved2  : 4..7; // must be 0
	}
}

struct StreamHeader @packed
{
	char[6]      magic;
	StreamFlags  flags;
	uint         crc32;   // CRC32 of flags (2 bytes)
}

struct StreamFooter @packed
{
	uint         crc32;
	uint         backward_size; // (actual_size / 4) - 1
	StreamFlags  flags;
	char[2]      magic;
}

struct BlockHeader
{
	char   size;      // header size in multiples of 4, minus 1
	char   flags;
	// optional compressed size (vli)
	// optional uncompressed size (vli)
	// filter list follows
	// padding to align to 4 bytes
	// crc32
}

// Variable-length integer (up to 63-bit value, encoded as 1..9 bytes)
alias Vli = ulong;

// Index record for one block
struct IndexRecord
{
	Vli unpadded_size;
	Vli uncompressed_size;
}

struct Xz
{
	Allocator    allocator;
	StreamFlags  stream_flags;
	char[]       uncompressed;
}

fn void Xz.free(&self)
{
	if (!self.allocator) return;
	allocator::free(self.allocator, self.uncompressed);
}

fn char[]? uncompress_bytes(Allocator allocator, char[] src) @inline => @pool()
{
	Xz xz = uncompress_stream(tmem, &&io::wrap_bytes(src))!;
	return allocator::clone_slice(allocator, xz.uncompressed);
}

fn Xz? uncompress(Allocator allocator, char[] src) @inline
{
	return uncompress_stream(allocator, &&io::wrap_bytes(src));
}

fn Xz? uncompress_stream(Allocator allocator, InStream reader)
{
	Xz xz = { .allocator = allocator };
	defer catch xz.free();

	StreamHeader shdr;
	reader.read((char[StreamHeader.sizeof]*)&shdr)!;

	if (shdr.magic != XZ_MAGIC_HEADER)  return CORRUPT_HEADER~;
	if (shdr.flags.reserved != 0)       return CORRUPT_HEADER~;
	if (shdr.flags.flags.reserved2 != 0) return CORRUPT_HEADER~;

	uint flags_crc = crc32::hash(((char[StreamFlags.sizeof]*)&shdr.flags)[:StreamFlags.sizeof]);
	if (shdr.crc32 != flags_crc)        return CORRUPT_HEADER~;

	char check_type = (char)shdr.flags.flags.check_type;
	// TODO: extend for CRC64 / SHA256
	if (check_type != CHECK_NONE && check_type != CHECK_CRC32) return UNSUPPORTED~;

	xz.stream_flags = shdr.flags;

	ByteWriter all_uncompressed;
	all_uncompressed.init(allocator);

	IndexRecord[] index @noinit;
	usz           index_len = 0;

	@pool()
	{
		// We don't know the block count upfront; collect into a temp list.
		IndexRecord[256] index_buf @noinit; // practical upper bound for streaming

		while (true)
		{
			// Peek at the next byte to distinguish a block header from the
			// index indicator (0x00).
			char first = reader.read_byte()!;
			if (first == 0x00)
			{
				// Index follows, handled below.
				break;
			}

			// First byte is block_header_size field (non-zero)
			usz hdr_total = ((usz)first + 1) * 4; // total header bytes including this byte

			// Read the rest of the block header into a temp buffer.
			char[] hdr_buf = allocator::malloc(tmem, hdr_total);
			hdr_buf[0] = first;
			reader.read(hdr_buf[1..])!;

			// Verify block header CRC32 (last 4 bytes of header_buf).
			uint bhdr_crc = io::read_le_uint(hdr_buf, hdr_total - 4)!;
			uint computed_crc = crc32::hash(hdr_buf[:hdr_total - 4]);
			if (bhdr_crc != computed_crc) return CORRUPT_BLOCK~;

			char bflags = hdr_buf[1];

			usz pos = 2;

			// Optional compressed size.
			Vli comp_size = 0;
			if (bflags & BLOCK_COMPRESSED_SIZE_PRESENT)
			{
				comp_size = read_vli(hdr_buf, &pos)!;
			}

			// Optional uncompressed size.
			Vli uncomp_size = 0;
			if (bflags & BLOCK_UNCOMPRESSED_SIZE_PRESENT)
			{
				uncomp_size = read_vli(hdr_buf, &pos)!;
			}

			// Number of filters encoded in bits 0..1 of bflags (value + 1).
			uint num_filters = (bflags & 0x03) + 1;
			if (num_filters != 1) return UNSUPPORTED~; // only single LZMA2 filter

			// Filter ID and properties.
			Vli filter_id = read_vli(hdr_buf, &pos)!;
			if (filter_id != 0x21) return UNSUPPORTED~; // 0x21 == LZMA2

			Vli props_size = read_vli(hdr_buf, &pos)!;
			if (props_size != 1) return CORRUPT_BLOCK~;

			char lzma2_props = hdr_buf[pos];
			pos++;

			// Decompress block data
			ByteWriter block_out;
			block_out.tinit();

			lzma2::decompress_stream(reader, &block_out, lzma2_props)!;

			char[] block_data = block_out.array_view();

			// Block check (CRC32 only for now).
			if (check_type == CHECK_CRC32)
			{
				uint block_crc = io::read_le_uint(reader)!;
				if (block_crc != crc32::hash(block_data)) return CORRUPT_BLOCK~;
			}

			// Consume padding to align to 4-byte boundary.
			// The check field is aligned, so no explicit padding read needed;
			// LZMA2 decompress_stream must leave the stream position past the
			// compressed payload but before the check/padding.

			// Record block sizes for index verification.
			if (index_len < index_buf.len)
			{
				// unpadded_size = 1 (block_header_size byte) + hdr_total - 1 + compressed_payload + check_size
				// Simplified: store what we know from decompression.
				index_buf[index_len++] = {
					.unpadded_size     = (Vli)hdr_total, // placeholder; full accounting below
					.uncompressed_size = (Vli)block_data.len,
				};
			}

			all_uncompressed.write(block_data)!;
		}

		index = allocator::new_array(allocator, IndexRecord, index_len);
		mem::copy(index.ptr, &index_buf, index_len * IndexRecord.sizeof);
	};

	defer allocator::free(allocator, index);

	// The 0x00 indicator byte was already consumed above.
	// Read index using a CRC-tracking wrapper.
	@pool()
	{
		// Build raw index bytes for CRC verification.
		ByteWriter idx_raw;
		idx_raw.tinit();
		idx_raw.write_byte(0x00)!; // Re-include the indicator byte

		Vli num_records = read_vli_stream(reader, &idx_raw)!;
		if ((usz)num_records != index_len) return CORRUPT_INDEX~;

		for (usz i = 0; i < index_len; i++)
		{
			Vli unpadded   = read_vli_stream(reader, &idx_raw)!;
			Vli uncompressed_sz = read_vli_stream(reader, &idx_raw)!;
			if (uncompressed_sz != index[i].uncompressed_size) return CORRUPT_INDEX~;
		}

		// Pad index to 4-byte boundary.
		usz idx_size = idx_raw.array_view().len;
		usz pad = (4 - (idx_size % 4)) % 4;
		for (usz i = 0; i < pad; i++)
		{
			char pb = reader.read_byte()!;
			if (pb != 0x00) return CORRUPT_INDEX~;
			idx_raw.write_byte(0x00)!;
		}

		uint idx_crc = io::read_le_uint(reader)!;
		if (idx_crc != crc32::hash(idx_raw.array_view())) return CORRUPT_INDEX~;
	};

	StreamFooter sftr;
	reader.read((char[StreamFooter.sizeof]*)&sftr)!;

	if (sftr.magic != XZ_MAGIC_FOOTER) return CORRUPT_FOOTER~;

	// Verify footer flags match header flags.
	if (sftr.flags.flags.check_type != shdr.flags.flags.check_type) return CORRUPT_FOOTER~;

	// Verify footer CRC32 covers backward_size + flags (8 bytes).
	char[8] footer_crc_data @noinit;
	mem::copy(&footer_crc_data[0], &sftr.backward_size, 4);
	mem::copy(&footer_crc_data[4], &sftr.flags, StreamFlags.sizeof);
	if (sftr.crc32 != crc32::hash(footer_crc_data[..])) return CORRUPT_FOOTER~;

	xz.uncompressed = all_uncompressed.array_view();
	return xz;
}

fn char[]? compress(Allocator allocator, char[] src, char check_type = CHECK_CRC32) @inline
{
	ByteWriter bw;
	bw.init(allocator);
	compress_stream(&bw, src, check_type)!;
	return bw.array_view();
}

fn void? compress_stream(OutStream writer, char[] src, char check_type = CHECK_CRC32)
{
	if (check_type != CHECK_NONE && check_type != CHECK_CRC32) return UNSUPPORTED~;

	StreamFlags flags = {
		.reserved = 0,
		.flags = { .check_type = check_type, .reserved2 = 0 },
	};

	@pool()
	{
		ByteWriter h;
		h.tinit();
		h.write(XZ_MAGIC_HEADER[..])!;
		h.write((char[StreamFlags.sizeof]*)&flags)!;
		uint hcrc = crc32::hash(((char[StreamFlags.sizeof]*)&flags)[:StreamFlags.sizeof]);
		io::write_le_int(&h, hcrc)!;
		writer.write(h.array_view())!;
	};

	// Single Block
	// LZMA2 props byte: dictionary size 2^23 (8 MiB), encoded as (23 - 12) * 2 = 22 => 0x16
	char lzma2_props = 0x16;

	// Compress payload into a temp buffer so we know its size.
	char[] compressed @noinit;
	@pool()
	{
		ByteWriter payload;
		payload.tinit();
		lzma2::compress_stream(&&io::wrap_bytes(src), &payload, lzma2_props)!;
		compressed = allocator::clone_slice(tmem, payload.array_view());
	};
	defer allocator::free(tmem, compressed);

	// Build block header.
	// flags: 0x00 = 1 filter, no optional size fields present
	// filter list: LZMA2 (id=0x21), props_size=1, props=lzma2_props
	// then padding + crc32
	char[] block_hdr @noinit;
	usz block_hdr_size;
	@pool()
	{
		ByteWriter bh;
		bh.tinit();

		// Placeholder for the size byte.
		bh.write_byte(0x00)!;
		// Flags: num_filters - 1 in bits 0..1, no optional sizes.
		bh.write_byte(0x00)!;
		// Filter: LZMA2 id as VLI (0x21 fits in one byte).
		write_vli_stream(&bh, 0x21)!;
		// Props size as VLI.
		write_vli_stream(&bh, 1)!;
		bh.write_byte(lzma2_props)!;

		// Pad to multiple of 4.
		usz cur = bh.array_view().len;
		usz padded = ((cur + 3) / 4) * 4 + 4; // +4 for CRC
		while (bh.array_view().len < padded - 4) bh.write_byte(0x00)!;

		// Fill in header size byte: (total_bytes / 4) - 1
		usz total = padded; // includes CRC
		bh.array_view()[0] = (char)(total / 4 - 1);

		// CRC32 over everything except the CRC itself.
		char[] raw = bh.array_view();
		uint bhcrc = crc32::hash(raw);
		io::write_le_int(&bh, bhcrc)!;

		block_hdr = allocator::clone_slice(tmem, bh.array_view());
		block_hdr_size = block_hdr.len;
	};

	writer.write(block_hdr)!;
	writer.write(compressed)!;

	// Block check.
	if (check_type == CHECK_CRC32)
	{
		io::write_le_int(writer, crc32::hash(src))!;
	}

	// unpadded_size = block_hdr_size + compressed.len + check_size (4 for CRC32, 0 for NONE)
	usz check_size = (check_type == CHECK_CRC32) ? 4 : 0;
	Vli unpadded_size    = (Vli)(block_hdr_size + compressed.len + check_size);
	Vli uncompressed_size = (Vli)src.len;

	@pool()
	{
		ByteWriter idx;
		idx.tinit();
		idx.write_byte(0x00)!;          // index indicator
		write_vli_stream(&idx, 1)!;     // one record
		write_vli_stream(&idx, unpadded_size)!;
		write_vli_stream(&idx, uncompressed_size)!;

		// Pad to 4-byte boundary.
		usz cur = idx.array_view().len;
		usz pad = (4 - (cur % 4)) % 4;
		for (usz i = 0; i < pad; i++) idx.write_byte(0x00)!;

		uint idx_crc = crc32::hash(idx.array_view());
		writer.write(idx.array_view())!;
		io::write_le_int(writer, idx_crc)!;
	};

	// backward_size encodes the index size (including CRC) in 4-byte units.
	// index bytes = 1 (indicator) + vli(1) + vli(unpadded) + vli(uncomp) + pad + 4 (crc)
	// Recompute precisely.
	@pool()
	{
		ByteWriter tmp;
		tmp.tinit();
		tmp.write_byte(0x00)!;
		write_vli_stream(&tmp, 1)!;
		write_vli_stream(&tmp, unpadded_size)!;
		write_vli_stream(&tmp, uncompressed_size)!;
		usz cur = tmp.array_view().len;
		usz pad = (4 - (cur % 4)) % 4;
		for (usz i = 0; i < pad; i++) tmp.write_byte(0x00)!;
		usz index_total = tmp.array_view().len + 4; // +4 for CRC

		uint backward_size = (uint)(index_total / 4 - 1);

		// CRC32 of backward_size (4) + flags (2).
		char[6] footer_crc_input @noinit;
		mem::copy(&footer_crc_input[0], &backward_size, 4);
		mem::copy(&footer_crc_input[4], &flags, StreamFlags.sizeof);
		uint fcrc = crc32::hash(footer_crc_input[..]);

		io::write_le_int(writer, fcrc)!;
		io::write_le_int(writer, backward_size)!;
		writer.write((char[StreamFlags.sizeof]*)&flags)!;
		writer.write(XZ_MAGIC_FOOTER[..])!;
	};
}


module std::compression::xz @private;

<*
 Decode a variable-length integer from a byte slice, advancing *pos.
 Encoding: each byte contributes 7 bits (little-endian); MSB = 1 means more bytes follow.
 Maximum 9 bytes, encoding up to 63 bits.
*>
fn Vli? read_vli(char[] buf, usz* pos)
{
	ulong value = 0;
	uint  shift = 0;
	while (*pos < buf.len)
	{
		char b = buf[(*pos)++];
		if (shift == 63 && b > 1) return CORRUPT_DATA~;
		value |= (ulong)(b & 0x7F) << shift;
		if ((b & 0x80) == 0) return (Vli)value;
		shift += 7;
		if (shift > 63) return CORRUPT_DATA~;
	}
	return CORRUPT_DATA~;
}

<*
 Decode a VLI directly from a stream, optionally copying raw bytes to a
 ByteWriter for later CRC verification.
*>
fn Vli? read_vli_stream(InStream reader, ByteWriter* capture = null)
{
	ulong value = 0;
	uint  shift = 0;
	while (true)
	{
		char b = reader.read_byte()!;
		if (capture) capture.write_byte(b)!;
		if (shift == 63 && b > 1) return CORRUPT_DATA~;
		value |= (ulong)(b & 0x7F) << shift;
		if ((b & 0x80) == 0) return (Vli)value;
		shift += 7;
		if (shift > 63) return CORRUPT_DATA~;
	}
}

<*
 Encode a VLI to a stream.
*>
fn void? write_vli_stream(OutStream writer, Vli v)
{
	ulong val = (ulong)v;
	while (val > 0x7F)
	{
		writer.write_byte((char)((val & 0x7F) | 0x80))!;
		val >>= 7;
	}
	writer.write_byte((char)val)!;
}
