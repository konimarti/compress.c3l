module zcat;
import std::io, compress::gzip;

fn void main(String[] args) => @assert_leak()
{
	char[] bytes = io::read_fully(mem, io::stdin())!!;
	defer allocator::free(mem, bytes.ptr);

	if (args.len > 1 && args[1] == "-c")
	{
		char[] out = gzip::compress(mem, bytes)!!;
		io::printf("%s", (String)out);
		allocator::free(mem, out.ptr);
	}
	else
	{
		Gzip gz_data = gzip::uncompress(mem, bytes)!!;
		defer gz_data.free();
		io::eprint("header: ");
		io::eprintn(gz_data.header);
		io::eprintfn("filename: %s", gz_data.filename);
		io::eprintfn("comment : %s", gz_data.comment);
		io::printf("%s", (String)gz_data.uncompressed);
	}
}

