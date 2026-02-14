module zcat;
import std::io, compress::gzip;

fn void main(String[] args)
{
	char[] bytes = io::read_fully(mem, io::stdin())!!;

	char[] out;
	if (args.len > 1 && args[1] == "-c")
	{
		out = gzip::compress(mem, bytes)!!;
	}
	else
	{
		out = gzip::uncompress(mem, bytes)!!;
	}

	io::printf("%s", (String)out);
}

