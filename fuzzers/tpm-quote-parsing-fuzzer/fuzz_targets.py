"""Shared fuzzing targets for keylime TPM quote / TPM2B structure parsing.

This module is imported both by the coverage-guided atheris harness
(``fuzz_harness.py``) and by the atheris-independent corpus replayer
(``replay.py``), so that both drive the keylime parsers through *exactly* the
same decoding and the same crash policy.

Trust-boundary context (keylime/keylime#1139): the inputs parsed here all
originate from a potentially compromised agent (TPM quotes, attestation
blobs, TPM2B_PUBLIC key structures). They are hand-written binary offset
walkers with input-controlled lengths/loop counts, so they are the highest
priority fuzzing target in keylime.

Targets:
  * tpms_attest   -> tpm2_objects.unmarshal_tpms_attest(bytes)
  * tpm2b_public  -> tpm2_objects.pubkey_from_tpm2b_public(bytes)
  * quote_params  -> Tpm._get_quote_parameters(str, compressed) (integration)

Crash policy
------------
A binary parser fed adversarial garbage is *expected* to reject it by raising
an ordinary exception (struct.error, ValueError, IndexError, ...). That is
graceful behaviour, not a bug, so we swallow it.

What we do NOT tolerate - these are re-raised so the fuzzer records a crash:
  * MemoryError / RecursionError / SystemError
        -> resource exhaustion from input-controlled sizes/counts, or a
           parser walking off into unbounded recursion. This is the concrete
           "input-controlled loop counts -> CPU/memory DoS" and
           "decompression bomb" class of findings from issue #1139.
  * a hard interpreter crash (segfault via a C extension), which terminates
    the process regardless of this try/except.
  * a hang, which the atheris/libFuzzer ``-timeout`` and the replayer's
    SIGALRM both turn into a reported failure.
"""

import base64
import struct
import zlib

# Importing keylime is done by the caller (the atheris harness wraps it in
# atheris.instrument_imports()). We only reference the modules lazily so that
# this file itself can be imported before deciding whether keylime is present.
from keylime.tpm import tpm2_objects

# Tpm pulls in a lot of keylime (config, logging, ...). It is optional: the
# quote_params target is skipped if it cannot be imported.
try:
    from keylime.tpm.tpm_main import Tpm

    _HAVE_TPM = True
except Exception:  # pragma: no cover - environment dependent
    _HAVE_TPM = False


# Exceptions that always indicate a real robustness problem, even though they
# are subclasses of Exception. These are re-raised, never swallowed, so the
# fuzzer records a finding. They correspond to the issue #1139 DoS classes:
# input-controlled sizes/counts exhausting memory, decompression bombs
# (MemoryError), and a parser walking off into unbounded recursion
# (RecursionError). SystemError flags a broken C-level invariant.
#
# Every *other* Exception (struct.error, ValueError, IndexError and even the
# bare Exception these hand-written parsers raise on bad magic / wrong token
# count) is graceful rejection of hostile input and is swallowed. A hang or a
# hard interpreter crash (segfault in a C extension) is caught out-of-band by
# the atheris/libFuzzer -timeout and the replayer's SIGALRM, regardless of
# this handling.
SERIOUS = (MemoryError, RecursionError, SystemError)

TARGETS = ("tpms_attest", "tpm2b_public", "quote_params")


def _call(target, data):
    """Decode ``data`` for ``target`` and invoke the parser under test.

    Raises the parser's own exception unchanged (no policy applied here).
    """
    if target == "tpms_attest":
        tpm2_objects.unmarshal_tpms_attest(bytes(data))
    elif target == "tpm2b_public":
        tpm2_objects.pubkey_from_tpm2b_public(bytes(data))
    elif target == "quote_params":
        if not _HAVE_TPM:
            return
        # First byte selects the zlib-compressed code path; the remainder is
        # the quote string ("r<b64>:<b64>:<b64>"). latin-1 keeps the mapping
        # total and byte-for-byte reversible so the fuzzer can reach the
        # base64/zlib decoders with arbitrary bytes.
        data = bytes(data)
        compressed = bool(data[:1] and (data[0] & 1))
        quote = data[1:].decode("latin-1")
        Tpm._get_quote_parameters(quote, compressed)
    else:
        raise ValueError(f"unknown fuzz target: {target}")


def run_one(target, data):
    """Run one input through ``target`` applying the crash policy.

    Returns None on graceful handling. Re-raises on a crash-worthy condition
    so the caller (atheris harness or replayer) records a failure.
    """
    try:
        _call(target, data)
    except SERIOUS:
        raise
    except Exception:
        # Graceful rejection of malformed input - not a crash.
        return


# --------------------------------------------------------------------------
# Seed corpus generation
# --------------------------------------------------------------------------
def _valid_tpms_attest():
    """A well-formed TPMS_ATTEST quote blob (seeds coverage of the happy path)."""
    magic = tpm2_objects.TPM_GENERATED_VALUE
    typ = tpm2_objects.TPM_ST_ATTEST_QUOTE

    qualified_signer = b"\x00\x0b" + b"\x11" * 32  # TPM2B_NAME (alg + sha256)
    extra_data = b"nonce-extradata"
    clock_info = struct.pack(">QIIB", 1234, 5, 6, 1)  # clock,reset,restart,safe
    firmware = struct.pack(">Q", 0xDEADBEEF)

    # TPMS_QUOTE_INFO = TPML_PCR_SELECTION + TPM2B_DIGEST
    pcr_select = struct.pack(">HB", tpm2_objects.TPM_ALG_SHA256, 3) + b"\xff\xff\xff"
    tpml_pcr_selection = struct.pack(">I", 1) + pcr_select
    pcr_digest = struct.pack(">H", 32) + b"\xaa" * 32
    quote_info = tpml_pcr_selection + pcr_digest

    return (
        struct.pack(">IH", magic, typ)
        + struct.pack(">H", len(qualified_signer))
        + qualified_signer
        + struct.pack(">H", len(extra_data))
        + extra_data
        + clock_info
        + firmware
        + quote_info
    )


def _valid_tpm2b_public():
    """Well-formed TPM2B_PUBLIC blobs for an RSA and an ECC key."""
    from cryptography.hazmat.primitives.asymmetric import ec, rsa

    out = []
    # The EK "low" template builder handles both RSA and ECC keys, producing a
    # TPM2B_PUBLIC that pubkey_from_tpm2b_public can parse back.
    rsa_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    out.append(tpm2_objects.ek_low_tpm2b_public_from_pubkey(rsa_key.public_key()))
    try:
        ecc_key = ec.generate_private_key(ec.SECP256R1())
        out.append(tpm2_objects.ek_low_tpm2b_public_from_pubkey(ecc_key.public_key()))
    except Exception:
        pass
    return out


def make_seeds():
    """Return {target: [seed_bytes, ...]}.

    Includes valid blobs (to seed coverage) and known-adversarial blobs that
    target the issue #1139 findings: input-controlled 32-bit loop counts,
    oversized TPM2B length fields, truncated structures and decompression
    bombs. These double as a deterministic regression corpus for replay.py.
    """
    seeds = {t: [] for t in TARGETS}

    # ---- tpms_attest -----------------------------------------------------
    valid = _valid_tpms_attest()
    seeds["tpms_attest"].append(valid)
    # 32-bit loop count = 0xFFFFFFFF in the TPML_PCR_SELECTION (DoS probe).
    header = struct.pack(">IH", tpm2_objects.TPM_GENERATED_VALUE, tpm2_objects.TPM_ST_ATTEST_QUOTE)
    header += struct.pack(">H", 0)  # empty qualified signer
    header += struct.pack(">H", 0)  # empty extra data
    header += struct.pack(">QIIB", 0, 0, 0, 0)  # clock info
    header += struct.pack(">Q", 0)  # firmware
    seeds["tpms_attest"].append(header + struct.pack(">I", 0xFFFFFFFF) + b"\x00\x0b\x03\xff\xff\xff")
    # Oversized TPM2B_NAME length pointing past end of buffer.
    seeds["tpms_attest"].append(
        struct.pack(">IH", tpm2_objects.TPM_GENERATED_VALUE, tpm2_objects.TPM_ST_ATTEST_QUOTE)
        + struct.pack(">H", 0xFFFF)
    )
    # Truncated variants of the valid blob.
    for cut in (1, 6, 8, 20, len(valid) - 1):
        if 0 < cut < len(valid):
            seeds["tpms_attest"].append(valid[:cut])
    seeds["tpms_attest"].append(b"")

    # ---- tpm2b_public ----------------------------------------------------
    for blob in _valid_tpm2b_public():
        seeds["tpm2b_public"].append(blob)
    # Oversized outer TPM2B length field.
    seeds["tpm2b_public"].append(struct.pack(">H", 0xFFFF) + b"\x00" * 8)
    # RSA type with keybits that will not match the modulus length.
    seeds["tpm2b_public"].append(
        struct.pack(">H", 12)  # outer length
        + struct.pack(">HHI", tpm2_objects.TPM_ALG_RSA, tpm2_objects.TPM_ALG_SHA256, 0)
        + struct.pack(">H", 0)  # empty auth policy
        + struct.pack(">H", 0xFFFF)  # huge keybits
    )
    seeds["tpm2b_public"].append(b"")
    seeds["tpm2b_public"].append(b"\x00\x02\xff\xff")

    # ---- quote_params ----------------------------------------------------
    b64 = base64.b64encode
    good_quote = b"\x00r" + b64(valid) + b":" + b64(b"sigblob") + b":" + b64(b"pcrblob")
    seeds["quote_params"].append(good_quote)
    # Decompression bomb: zlib stream that inflates to ~100 MiB, compressed path.
    bomb = zlib.compress(b"\x00" * (100 * 1024 * 1024))
    seeds["quote_params"].append(b"\x01r" + b64(bomb) + b":" + b64(bomb) + b":" + b64(bomb))
    # Malformed: wrong leading char, too few tokens, bad base64.
    seeds["quote_params"].append(b"\x00xnotaquote")
    seeds["quote_params"].append(b"\x00ronly:two")
    seeds["quote_params"].append(b"\x00r!!!:@@@:###")
    seeds["quote_params"].append(b"")

    return seeds
