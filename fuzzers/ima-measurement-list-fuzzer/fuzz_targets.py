"""Shared fuzzing targets for keylime's IMA measurement-list line parser.

This module is imported both by the coverage-guided atheris harness
(``fuzz_harness.py``) and by the atheris-independent corpus replayer
(``replay.py``), so that both drive the keylime parser through *exactly* the
same decoding and the same crash policy.

Trust-boundary context (keylime/keylime#1139)
---------------------------------------------
``keylime.ima.ast.Entry(data: str)`` parses a single IMA measurement-list line
supplied by a (potentially compromised) agent. The verifier calls it in a loop
in ``keylime.ima.ima._process_measurement_list`` wrapped in::

        try:
            entry = ast.Entry(line, ...)
            ...
        except ast.ParserError:
            ...   # line rejected, keep going

i.e. the caller only catches ``ParserError``. Therefore the contract of the
parser is: *reject any malformed line by raising ``ParserError`` and nothing
else.* Any other exception type escaping ``Entry()`` (and the component
parsers it drives) is NOT graceful rejection -- it propagates out of the loop
and crashes the whole quote-verification pipeline, i.e. a remote DoS of the
verifier. That is exactly the class of finding issue #1139 calls out for this
parser (e.g. the legacy "n" name path computing
``TCG_EVENT_NAME_LEN_MAX - len(name_bytes)`` and raising on an over-long name).

Crash policy
------------
This is the INVERSE of a hand-written binary parser that is allowed to raise
anything: here the parser has a declared exception type for bad input, so

  * ``ast.ParserError``  -> graceful rejection of hostile input. Swallowed.
  * every other ``Exception`` (``ValueError``, ``struct.error``,
    ``UnicodeEncodeError``, a bare ``Exception``, ...) -> re-raised, so the
    fuzzer records a finding. This is a line the verifier's ``except
    ParserError`` would NOT catch -> verifier crash.
  * ``MemoryError`` / ``RecursionError`` / ``SystemError`` -> re-raised too
    (they are not ``ParserError`` either); kept named in ``SERIOUS`` so the
    replayer can label resource exhaustion distinctly. They correspond to the
    input-controlled-size / unbounded-recursion DoS classes from #1139.
  * a hang is caught out-of-band by the atheris/libFuzzer ``-timeout`` and the
    replayer's SIGALRM; a hard interpreter crash (segfault in a C extension)
    terminates the process regardless of this handling.

Targets
-------
  * entry      -> ast.Entry(line)                     (the real trust boundary)
  * digest     -> ast.Digest(field, legacy).struct()  (hex / alg:hash parser)
  * name       -> ast.Name(field, legacy).struct()    (legacy fixed-len packing)
  * signature  -> ast.Signature(hexdata).struct()     (binary sig-header unpack)

``entry`` alone reaches every component; the component targets exist so the
coverage-guided campaign can drive each parser directly (faster to reach deep
states) and so a reproducer pins the blame on one component.
"""

import struct

# Importing keylime is done by the caller (the atheris harness wraps it in
# atheris.instrument_imports()) so that atheris gets coverage feedback.
from keylime.ima import ast

# The one exception type that means "hostile line gracefully rejected". Only
# this is swallowed; see module docstring for the rationale (it is the only
# type the verifier's own loop catches).
GRACEFUL = (ast.ParserError,)

# Not graceful, but worth labelling distinctly as resource exhaustion rather
# than a plain uncaught-exception finding. These are re-raised like any other
# non-ParserError exception; the replayer uses this tuple only for reporting.
SERIOUS = (MemoryError, RecursionError, SystemError)

TARGETS = ("entry", "digest", "name", "signature")


def _as_str(data):
    """Map arbitrary fuzz bytes to a str the way agent-supplied data reaches
    the parser: total, reversible, and able to produce lone surrogates (via
    ``surrogateescape``) so the UTF-8 re-encode paths in ``Name.struct`` are
    reachable.
    """
    return bytes(data).decode("utf-8", "surrogateescape")


def _call(target, data):
    """Decode ``data`` for ``target`` and invoke the parser under test.

    Raises the parser's own exception unchanged (no policy applied here).
    """
    data = bytes(data)
    if target == "entry":
        ast.Entry(_as_str(data))
    elif target == "digest":
        # First byte selects the legacy ("d") fixed-length path; the remainder
        # is the digest field ("<hex>" or "<alg>:<hex>").
        legacy = bool(data[:1] and (data[0] & 1))
        ast.Digest(_as_str(data[1:]), legacy=legacy).struct()
    elif target == "name":
        # First byte selects the legacy ("n") fixed-length path (the #1139
        # bug); the remainder is the name/path field.
        legacy = bool(data[:1] and (data[0] & 1))
        ast.Name(_as_str(data[1:]), legacy=legacy).struct()
    elif target == "signature":
        # Signature parses a hex string into bytes, then struct-unpacks a
        # fixed header. Hexlify the raw fuzz bytes so the hex decode always
        # succeeds and the fuzzer reaches the header-parsing logic.
        ast.Signature(data.hex()).struct()
    else:
        raise ValueError(f"unknown fuzz target: {target}")


def run_one(target, data):
    """Run one input through ``target`` applying the crash policy.

    Returns None on graceful handling (a ``ParserError``). Re-raises on any
    other exception so the caller (atheris harness or replayer) records a
    finding.
    """
    try:
        _call(target, data)
    except GRACEFUL:
        # Declared rejection of a malformed line - not a crash.
        return


# --------------------------------------------------------------------------
# Seed corpus generation
# --------------------------------------------------------------------------
_GOOD_SHA1 = "a" * 40
_GOOD_SHA256 = "sha256:" + "b" * 64


def _good_signature_hex():
    """Hex of a well-formed IMA signature blob (header + body)."""
    body = b"SIGNATURE-BODY"
    header = struct.pack(">BBBIH", 0x03, 0x02, 0x01, 0, len(body))
    return (header + body).hex()


def make_seeds():
    """Return {target: [seed_bytes, ...]}.

    Includes valid lines/fields (to seed coverage) and known-adversarial ones
    that target the issue #1139 findings for this parser:
      * legacy "n"/"d" fixed-length packing with an over-long field,
      * lone surrogates that break the UTF-8 re-encode in Name.struct,
      * malformed token counts, bad hex and truncated signature headers.

    These double as a deterministic regression corpus for replay.py: every
    seed must be either parsed or rejected with ``ParserError``; anything that
    escapes as another exception is a finding and fails the replay.

    NOTE: against a keylime build where #1139 is not yet fixed, the over-long
    legacy-name and lone-surrogate seeds reproduce real findings and the
    replay will (correctly) fail. See README.md.
    """
    seeds = {t: [] for t in TARGETS}

    # ---- entry: full measurement lines ----------------------------------
    e = seeds["entry"]
    # Valid lines, one per template mode.
    e.append(f"10 {_GOOD_SHA1} ima-ng {_GOOD_SHA256} /usr/bin/ls".encode())
    e.append(f"10 {_GOOD_SHA1} ima {_GOOD_SHA1} /usr/bin/ls".encode())
    e.append(f"10 {_GOOD_SHA1} ima-sig {_GOOD_SHA256} /usr/bin/ls ".encode())
    e.append(f"10 {_GOOD_SHA1} ima-buf {_GOOD_SHA256} eventname {b'buf'.hex()}".encode())
    e.append(f"10 {_GOOD_SHA1} ima-sig {_GOOD_SHA256} /usr/bin/ls {_good_signature_hex()}".encode())
    # #1139: legacy "ima" with an over-long path -> negative struct count.
    e.append(f"10 {_GOOD_SHA1} ima {_GOOD_SHA1} /{'A' * 300}".encode())
    # Lone surrogate in an ima-ng path -> UTF-8 re-encode failure.
    e.append("10 {} ima-ng {} /\udcff".format(_GOOD_SHA1, _GOOD_SHA256).encode("utf-8", "surrogateescape"))
    # Boundary: exactly 255 then 256 bytes in the legacy name.
    e.append(f"10 {_GOOD_SHA1} ima {_GOOD_SHA1} {'A' * 255}".encode())
    e.append(f"10 {_GOOD_SHA1} ima {_GOOD_SHA1} {'A' * 256}".encode())
    # Malformed: wrong token counts, bad template hash, unknown mode, bad hex.
    e.append(b"")
    e.append(b"10")
    e.append(b"10 aa ima-ng")
    e.append(f"10 ZZZZ ima-ng {_GOOD_SHA256} /x".encode())
    e.append(b"10 " + _GOOD_SHA1.encode() + b" bogus-mode foo bar")
    e.append(f"10 {_GOOD_SHA1} ima-ng sha256:ZZ /x".encode())

    # ---- digest: "<hex>" or "<alg>:<hex>", byte0 bit0 = legacy ----------
    d = seeds["digest"]
    d.append(b"\x00" + _GOOD_SHA256.encode())
    d.append(b"\x00" + _GOOD_SHA1.encode())
    d.append(b"\x01" + _GOOD_SHA1.encode())  # legacy
    d.append(b"\x00" + b"sha256:ZZ")  # bad hex
    d.append(b"\x00" + b"a:b:c")  # too many tokens
    d.append(b"\x00" + b"abcd")  # unknown bare-hash length
    d.append(b"\x00")

    # ---- name: path field, byte0 bit0 = legacy -------------------------
    n = seeds["name"]
    n.append(b"\x00" + b"/usr/bin/ls")
    n.append(b"\x01" + b"/usr/bin/ls")  # legacy, short -> ok
    n.append(b"\x01" + b"A" * 255)  # legacy boundary ok
    n.append(b"\x01" + b"A" * 256)  # #1139: legacy over-long -> negative count
    n.append(b"\x01" + b"A" * 400)
    n.append(b"\x00" + "\udcff".encode("utf-8", "surrogateescape"))  # surrogate, non-legacy
    n.append(b"\x00")

    # ---- signature: raw bytes, hexlified into Signature ----------------
    s = seeds["signature"]
    s.append(bytes.fromhex(_good_signature_hex()))
    s.append(b"")  # header too short
    s.append(b"\x03\x02\x01")  # header too short
    s.append(struct.pack(">BBBIH", 3, 2, 1, 0, 9) + b"XX")  # size mismatch
    s.append(struct.pack(">BBBIH", 0, 0, 0, 0xFFFFFFFF, 0xFFFF))  # huge declared size
    s.append(b"\x00" * 9)

    return seeds
