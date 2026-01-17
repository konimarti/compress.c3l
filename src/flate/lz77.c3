// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate::lz77;
import std::io, std::collections;

const ushort MIN_MATCH_LEN   = 3;
const ushort MAX_MATCH_LEN   = 258;
const ushort MAX_WINDOW_SIZE = 1 << 15;
const uint   MIN_OFFSET_LEN  = 3;

enum TokenType : inline char
{
	INVALID,
	LITERAL,
	MATCH
}

bitstruct Token (Printable) : uint @bigendian @overlap
{
	TokenType type : 0..2;   //  2 bits: 0 = INVALID, 1 = LITERAL, 2 = MATCH, 3 = EOF
	char      len  : 3..10;  //  8 bits: len = length - MIN_MATCH_LENGTH
	uint      off  : 11..31; // 20 bits: off = offset - MIN_OFFSET_SIZE
	char      lit  : 24..31; //  8 bits: store literal
}

fn ushort Token.length(&self) => MIN_MATCH_LEN + (ushort)self.len;
fn uint Token.offset(&self) => MIN_OFFSET_LEN + self.off;

<*
 @require length >= MIN_MATCH_LEN
 @require offset >= MIN_OFFSET_LEN
*>
fn Token make_match(ushort length, uint offset)
{
	return (Token){
		.type = MATCH,
		.len = (char)(length - MIN_MATCH_LEN),
		.off = offset - MIN_OFFSET_LEN,
	};
}

fn Token make_literal(char literal)
{
	return (Token){
		.type = LITERAL,
		.lit = literal,
	};
}

fn usz? Token.to_format(&self, Formatter *f) @dynamic
{
	switch (self.type)
	{
		case LITERAL:
			return f.printf("LITERAL<%c>", self.lit);
		case MATCH:
			return f.printf("MATCH<%d:%d>", self.offset(), self.length());
		default:
			unreachable("invalid token type");
	}
}

const uint HASH_MASK = (1U << 15) - 1;
alias HashKey  = ushort;
fn HashKey lz77_hash(char[3] b)
{
	uint x = (b[0] << 16) | (b[1] << 8) | b[2];
	x ^= x >> 12;
	x ^= x << 5;
	return (HashKey)(x & HASH_MASK);
}

alias HashChain = LinkedList{ isz };
alias MatchPair = Pair{uint, ushort};

<*
 @param [&inout] chain : "Chained hash list storing positions in s"
 @param [in] bytes     : "Input dat "
 @param idx            : "Current index in bytes"
*>
fn MatchPair find_max_match(HashChain *chain, char[] bytes, usz idx) @private @inline
{
	ushort max_match_len, len;
	isz max_match_off, offset;

	max_match_len = 0;
	max_match_off = 0;

	linkedlist::Node{isz} *node, temp;
	node = chain._first;
	while (node != null)
	{
		isz hash_pos = node.value;
		assert(idx >= hash_pos);

		offset = idx - hash_pos;
		if (offset < 0) continue;
		if (offset > MAX_WINDOW_SIZE)
		{
			// Remove this node from the hash chain.
			temp = node;
			node = node.next;
			chain.unlink(temp);
			continue;
		}

		// Find max match length.
		len = 0;
		while ((idx + len) < bytes.len && bytes[hash_pos+len] == bytes[idx+len])
		{
			len++;
		}

		if (len > max_match_len ||
			(len == max_match_len && offset < max_match_off))
		{
			max_match_len = len;
			max_match_off = offset;
		}

		node = node.next;
	}

	return {(uint)max_match_off, (max_match_len > MAX_MATCH_LEN) ? MAX_MATCH_LEN : max_match_len};
}

fn HashChain make_hash_chain(Allocator allocator, usz... elements)
{
	HashChain chain;
	chain.init(allocator);
	chain.push_all(elements);
	return chain;
}

<*
 Tokenize input byte stream into literal or match tokens using the Lempel-Ziv
 compression approach.

 @param [&inout] allocator : "Allocator for the returned token array"
 @param [in] bytes         : "Input data to be compressed by LZ77"
*>
fn Token[] tokenize(Allocator allocator, char[] bytes) => @pool()
{
	usz i;
	MatchPair match, alternative;
	HashMap{ HashKey, HashChain } hash;
	hash.tinit();

	List{Token} tokens;
	tokens.tinit();

	// Prepare hash and process input.
	for (i = 0; i < bytes.len - 2; i++)
	{
		HashKey key = lz77_hash(bytes[i:3]);
		if (!hash.has_key(key))
		{
			// No hit: it's a literal!
			// Emit literal token.
			tokens.push(make_literal(bytes[i]));

			// Store current hash in a new hash chain.
			hash.set(key, make_hash_chain(tmem, i));
			continue;
		}

		// We have a hit: Find largest match in chain.
		HashChain *chain = hash.get_ref(key)!!;
		match = find_max_match(chain, bytes, i);

		// Save index in hash chain.
		chain.push_front(i);

		// If next hash has a longer match, then emit current literal
		// and go to next iteration.
		if (i+3+1 < bytes.len)
		{
			// "Lazy Matching".
			if (try alt_chain = hash.get_ref(lz77_hash(bytes[i+1:3])))
			{
				alternative = find_max_match(alt_chain, bytes, i+1);
				if (alternative.second > match.second) match = {};
			}
		}

		uint offset = match.first;
		ushort len  = match.second;
		if (len >= MIN_MATCH_LEN && offset >= MIN_OFFSET_LEN)
		{
			// Emit match token.
			tokens.push(make_match(len, offset));

			usz end = i + len - 1L; // -1 because of increment in for-loop
			for (; i < end; i++)
			{
				if (i + 3 >= bytes.len) continue;
				HashKey k = lz77_hash(bytes[i:3]);
				if (try alt_chain = hash.get_ref(k))
				{
					alt_chain.push_front(i);
					continue;
				}
				hash.set(key, make_hash_chain(tmem, i));
			}
		}
		else
		{
			// Emit literal token.
			tokens.push(make_literal(bytes[i]));
		}
	}

	// Emit remaining literal tokens.
	while (i < bytes.len)
	{
		tokens.push(make_literal(bytes[i++]));
	}

	return tokens.to_array(allocator);
}

<*
 Construct a byte array from a LZ77-compressed token stream.
*>
fn char[] construct(Allocator allocator, Token[] tokens) => @pool()
{
	DString buf;
	buf.tinit();

	foreach (token: tokens)
	{
		switch (token.type)
		{
			case LITERAL:
				buf.append_char(token.lit);
			case MATCH:
				usz start = buf.len() - token.offset();
				usz end   = start + token.length();
				for (usz i = start; i < end; i++)
				{
					buf.append_char(buf[i]);
				}
			default:
				continue;
		}
	}

	return buf.copy_str(allocator);
}

fn void test_lz77() @test => @pool()
{
	String[] tests = {
		"aaa aaaa aaaa",
 		"hello world world hello"
	};
	foreach (s: tests)
	{
		Token[] tokens = tokenize(tmem, s);
		String r = (String)construct(tmem, tokens);
		assert(r == s, "got: %s, want: %s", r, s);
	}
}

fn void test_lz77_long_text() @test => @pool()
{
	String text = `
{
  "provides" : "compress",
  "sources" : [ "src/**" ],
  "targets" : {
    "android-aarch64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "freebsd-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "linux-aarch64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "linux-riscv32" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "linux-riscv64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "linux-x86" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "linux-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "macos-aarch64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "macos-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "netbsd-aarch64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "netbsd-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "openbsd-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "wasm32" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "wasm64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "windows-aarch64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
    "windows-x64" : {
      // Extra flags to the linker for this target:
      "link-args" : [],
      // C3 libraries this target depends on:
      "dependencies" : [],
      // The external libraries to link for this target:
      "linked-libraries" : []
    },
  }
}
	`;
	Token[] tokens = tokenize(tmem, text);
	String r = (String)construct(tmem, tokens);
	test::eq(r, text);
}
