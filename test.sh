#!/bin/bash
# set -x
c3c -O3 build ffup
ffup="./build/ffup"

## Compress some files in the current source directory.
for file in $(find src -type f)
do
	$ffup -dxf $file | xxd -r -p | puff -w | diff -s $file -
	echo ""
done

## Compress large chunks of random data.
dd if=/dev/random bs=1M count=32 | $ffup -dx | xxd -r -p | puff
