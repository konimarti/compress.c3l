#!/bin/bash
# set -x
c3c -O3 build ffup
ffup="./build/ffup"

## Compress some files in the current source directory.
for file in $(find src -type f)
do
	# $ffup -2wf $file | xxd -r -p | puff -w | diff -s $file -
	$ffup -2wf $file | xxd -r -p | $ffup -w | diff -s $file -
	echo ""
done

## Compress large chunks of random data.
dd if=/dev/random bs=1M count=32 | $ffup -2w | xxd -r -p | puff
