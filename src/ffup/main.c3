// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module ffup;
import std, getopt, compress::flate;

fn void usage()
{
	io::printn(`
	ffup - the C3 version of zlib's puff.

	Compresses and decompress data using the DEFLATE algorithm (RFC 1951).

	ffup [-f <file>] [-0|-1|-2] [-w]

	-f <file>       Input file. If not specified, read from stdin.
	-0              Non-compressed blocks.
	-1              Use fixed Huffman codes.
	-2              Use dynamic Huffman codes.
	-w              Write data to stdout (compressed data as hexdump).

	Example usage: puffc3 -2wf main.c3 | xxd -r -p | puff -w

	`);
}

enum FlateMode
{
	INFLATE,
	STORE,
	FIXED,
	DYNAMIC,
}

fn void main(String[] args) => @pool()
{
	bool write = false;
	FlateMode mode = INFLATE;
	String f;
	if (try opts = getopt::getopts(tmem, args, "012wf:"))
	{
		foreach (opt: opts)
		{
			switch (opt.flag)
			{
				case '0': mode = STORE;
				case '1': mode = FIXED;
				case '2': mode = DYNAMIC;
				case 'w': write = true;
				case 'f': f = opt.arg;
			}
		}
	}
	else
	{
		usage();
		return;
	}

	Clock t;
	NanoDuration elapsed;

	char[] bytes, out;

	InStream reader = (f.len && f != "-") ? &&file::open(f, "rb+")!! : io::stdin();
	bytes = io::read_fully(tmem, reader)!!;

	if (mode == INFLATE)
	{
		t = clock::now();
		out = flate::inflate(tmem, bytes)!!;
		elapsed = t.mark();

		if (bytes.len)
		{
			io::eprintfn("Size: %d bytes, Uncompressed: %d bytes", bytes.len, out.len);
			io::eprintfn("%3.1f MB/sec throughput (elapsed time: %s)", bytes.len/(double)elapsed * 1000.0, elapsed);
		}
		if (write) io::printf("%s", (String)out);
	}
	else
	{
		DeflateBlockFn deflate = &flate::encode_dynamic_block;
		switch (mode)
		{
			case STORE:   deflate = &flate::encode_stored_block;
			case FIXED:   deflate = &flate::encode_fixed_block;
			case DYNAMIC: deflate = &flate::encode_dynamic_block;
			case INFLATE: unreachable("internal error");
		}

		t = clock::now();
		out = flate::deflate(tmem, bytes, deflate)!!;
		elapsed = t.mark();

		if (bytes.len)
		{
			io::eprintfn("Size: %d bytes, Compressed: %d bytes", bytes.len, out.len);
			io::eprintfn("Compression ratio: %g %%", 100.0*out.len/bytes.len);
			io::eprintfn("%3.1f MB/sec throughput (elapsed time: %s)", bytes.len/(double)elapsed * 1000.0, elapsed);
		}
		if (write) io::printf("%s", hex::tencode(out));
	}
}


// getopt module implements a POSIX-compliant command-line parser.
module getopt;
import std::collections::list;

struct Option
{
	char flag;
	String arg;
}

faultdef UNKNOWN_OPTION, MISSING_ARGUMENT;

<*
 Parses command-line arguments..

 @param [in] args : "Strings of options."
 @param [in] optstring : "Specification of options."
 @param [out] optind : "Index of the first non-option argument"

 @require args.len > 0
 @return "Slice of options. Allocated on heap by default."
 @return? MISSING_ARGUMENT

*>
fn Option[]? getopts(Allocator allocator, String[] args, String optstring, int *optind = null)
{
	int i;

	List{Option} opts;
	opts.tinit(optstring.len);

	// remove program name
	args = args[1..];
	i++;

	// parse arguments
	while LOOP: (args.len) {
		String arg = args[0];

		switch {
		case arg == "--":
			i++;
			break LOOP;
		case arg == "-":
			break LOOP;
		case arg.len == 0:
		 	break LOOP;
		case arg[0] != '-':
		 	break LOOP;
		}

		arg = arg[1..];
		foreach (c : arg) {
			usz pos = optstring.index_of_char(c)!;
			bool hasArgument = pos+1 < optstring.len && optstring[pos+1] == ':';
			if (hasArgument) {
				if (args.len >= 2) {
					args = args[1..];
					i++;
					opts.push({.flag=c, .arg=args[0]});
				} else {
					return MISSING_ARGUMENT~;
				}
			} else {
				opts.push({.flag=c, .arg=""});
			}
		}
		args = args[1..];
		i++;
	}

	if (optind) {
		*optind = i;
	}

	return opts.to_array(allocator);
}
