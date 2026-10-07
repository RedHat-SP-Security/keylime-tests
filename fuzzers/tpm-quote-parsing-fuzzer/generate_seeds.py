#!/usr/bin/env python3
"""Write the seed corpus for each fuzz target into <basedir>/<target>/.

Each seed is stored in its own file named by the sha1 of its contents, which
is the layout libFuzzer/atheris expects for a corpus directory.

Usage:
    python3 generate_seeds.py <basedir>
"""

import hashlib
import os
import sys

import fuzz_targets


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: generate_seeds.py <basedir>")
    basedir = sys.argv[1]

    seeds = fuzz_targets.make_seeds()
    total = 0
    for target, blobs in seeds.items():
        d = os.path.join(basedir, target)
        os.makedirs(d, exist_ok=True)
        for blob in blobs:
            name = hashlib.sha1(blob).hexdigest()
            with open(os.path.join(d, name), "wb") as f:
                f.write(blob)
            total += 1
        print(f"{target}: wrote {len(blobs)} seeds into {d}")
    print(f"total seeds: {total}")


if __name__ == "__main__":
    main()
