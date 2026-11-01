// Benchmark of compress::flate against std::compression::deflate.
//
//   c3c -O3 build bench && ./build/bench [--gen] <file>...
//
// For every input and library the compressor and decompressor are run
// repeatedly (at least MIN_RUNS, until MIN_TOTAL_NS has elapsed, at most
// MAX_RUNS) after one warm-up run; the median time is reported. Each library's
// output is also decoded by the other library to verify interoperability.
module bench;
import std::io, std::time, std::sort, std::compression::deflate, compress::flate;

const MIN_RUNS = 5;
const MAX_RUNS = 40;
const ulong MIN_TOTAL_NS = 2_000_000_000;

alias CompressFn = fn char[]?(char[] data);
alias DecompressFn = fn char[]?(char[] data);

fn char[]? c3l_compress(char[] d) => flate::compress(mem, d);
fn char[]? c3l_decompress(char[] d) => flate::inflate(mem, d);
fn char[]? std_compress(char[] d) => deflate::compress(mem, d);
fn char[]? std_decompress(char[] d) => deflate::decompress(mem, d);

struct Lib
{
	String name;
	CompressFn compress;
	DecompressFn decompress;
}

struct Result
{
	usz comp_len;
	double comp_mbps;
	double decomp_mbps;
}

fn double median(double[] v)
{
	sort::quicksort(v);
	return v[v.len / 2];
}

<*
 Times fn over data, returning the median seconds. The last result of the
 timed function is kept in out (the caller frees it).
*>
macro double time_runs(fn_, char[] data, char[]* out)
{
	double[MAX_RUNS] times;
	usz n;
	ulong total;
	// Warm-up.
	char[] w = fn_(data)!!;
	free(w.ptr);
	while (n < MAX_RUNS && (n < MIN_RUNS || total < MIN_TOTAL_NS))
	{
		if (*out) free(out.ptr);
		Clock c = clock::now();
		*out = fn_(data)!!;
		NanoDuration d = c.to_now();
		times[n++] = (double)d / 1e9;
		total += (ulong)d;
	}
	return median(times[:n]);
}

fn Result run(Lib lib, char[] data, char[]* comp_out)
{
	char[] comp;
	double tc = time_runs(lib.compress, data, &comp);
	char[] dec;
	double td = time_runs(lib.decompress, comp, &dec);
	assert(dec == data, "%s roundtrip mismatch", lib.name);
	free(dec.ptr);
	*comp_out = comp;
	double mb = (double)data.len / 1e6;
	return { comp.len, mb / tc, mb / td };
}

fn void bench_one(String name, char[] data)
{
	Lib[2] libs = {
		{ "compress.c3l", &c3l_compress, &c3l_decompress },
		{ "std", &std_compress, &std_decompress },
	};
	Result[2] res;
	char[][2] comps;
	foreach (i, lib : libs) res[i] = run(lib, data, &comps[i]);

	// Interoperability: each library must read the other's output.
	char[] a = std_decompress(comps[0])!!;
	assert(a == data, "std cannot read c3l output");
	free(a.ptr);
	char[] b = c3l_decompress(comps[1])!!;
	assert(b == data, "c3l cannot read std output");
	free(b.ptr);

	foreach (i, lib : libs)
	{
		io::printfn("%-14s %10d  %-12s %7.2f%% %10.1f %12.1f",
			name, data.len, lib.name, 100.0 * res[i].comp_len / data.len,
			res[i].comp_mbps, res[i].decomp_mbps);
		free(comps[i].ptr);
	}
	io::printfn("%-14s %10s  %-12s %7s  %9.2fx %11.2fx", "", "", "speedup",
		"", res[0].comp_mbps / res[1].comp_mbps, res[0].decomp_mbps / res[1].decomp_mbps);
}

fn char[] gen_data(String kind, usz size)
{
	char[] d = mem::new_array(char, (sz)size);
	uint x = 0x1234567;
	foreach (i, &c : d)
	{
		x = x * 1664525 + 1013904223;
		switch (kind)
		{
			case "zeros":  *c = 0;
			case "random": *c = (char)(x >> 24);
			default:       *c = (char)((x >> 24) & 0x0F) + (char)(i % 7);
		}
	}
	return d;
}

fn int main(String[] args)
{
	bool gen;
	foreach (a : args[1..]) if (a == "--gen") gen = true;
	if (args.len < 2)
	{
		io::printn("usage: bench [--gen] <file>...");
		return 1;
	}
	io::printfn("%-14s %10s  %-12s %8s %10s %12s", "input", "bytes", "lib", "ratio", "comp MB/s", "decomp MB/s");
	if (gen)
	{
		String[*] kinds = { "zeros", "random", "skewed" };
		foreach (kind : kinds)
		{
			char[] d = gen_data(kind, 8_000_000);
			bench_one(kind, d);
			free(d.ptr);
		}
	}
	foreach (path : args[1..])
	{
		if (path == "--gen") continue;
		char[] data = file::load(mem, path)!!;
		defer free(data.ptr);
		sz i = path.rindex_of("/") ?? 0;
		bench_one(i > 0 ? path[i + 1..] : path, data);
	}
	return 0;
}
