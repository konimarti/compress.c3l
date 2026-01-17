// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module ffup;
import std, getopt, compress::flate;

fn void usage()
{
	io::printn(`
	ffup - the opposite of zlib's puff. Compresses data using the Deflate
	compression method.

	Writes the deflated data of a file (or from stdin) in hex to stdout.

	ffup [-f <file>] [ -n | -d | -x ]

	-f <file>       File to deflate. If not set, read from stdin.
	-n              Non-compressed blocks.
	-d              Use dynamic Huffman codes.
	-x              Use fixed Huffman codes.

	Example usage: ffup -df main.c3 | xxd -r -p | puff -w

	`);
}

enum CompressMethod
{
	NONCOMP,
	DYNAMIC,
	FIXED
}

fn void main(String[] args) => @pool()
{
	CompressMethod m = FIXED;
	String f;
	if (try opts = getopt::getopts(tmem, args, "ndxf:"))
	{
		foreach (opt: opts)
		{
			switch (opt.flag)
			{
				case 'n': m = CompressMethod.NONCOMP;
				case 'd': m = CompressMethod.DYNAMIC;
				case 'x': m = CompressMethod.FIXED;
				case 'f': f = opt.arg;
			}
		}
	}
	else
	{
		usage();
		return;
	}

	char[] bytes, out;
	InStream reader = f.len ? &&file::open(f, "rb+")!! : io::stdin();
	bytes = io::read_fully(tmem, reader)!!;
	switch (m)
	{
		case NONCOMP: out = flate::deflate_non_compressed_blocks(tmem, bytes)!!;
		case DYNAMIC: out = flate::deflate_dynamic_block(tmem, bytes)!!;
		case FIXED  : out = flate::deflate_fixed_block(tmem, bytes)!!;
	}
	io::printfn("%s", hex::tencode(out));
}


// getopt implements a POSIX-compliant command-line parser.
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
					return MISSING_ARGUMENT?;
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
