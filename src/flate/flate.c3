// Copyright (c) 2026 Koni Marti. All rights reserved.
// Use of this source code is governed by the MIT license.
module compress::flate;

fn char[]? compress(Allocator allocator, char[] bytes)
{
	unreachable("To be implemented soon.");
}

fn char[]? tcompress(char[] bytes) @inline => compress(tmem, bytes);

fn char[]? uncompress(Allocator allocator, char[] bytes)
{
	unreachable("To be implemented soon.");
}

fn char[]? tuncompress(char[] bytes) @inline => uncompress(tmem, bytes);
