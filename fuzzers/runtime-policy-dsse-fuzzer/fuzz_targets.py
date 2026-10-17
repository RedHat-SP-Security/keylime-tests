"""Shared fuzzing targets for keylime runtime-policy / DSSE envelope parsing.

This module is imported both by the coverage-guided atheris harness
(``fuzz_harness.py``) and by the atheris-independent corpus replayer
(``replay.py``), so that both drive the keylime parsers through *exactly* the
same decoding and the same crash policy.

Trust-boundary context (keylime/keylime#1139): the inputs parsed here are the
REST-facing runtime-policy / DSSE-envelope layer. They are "semi-trusted but
network-reachable" - supplied by tenants/operators over the verifier/registrar
REST API. The issue flags this surface because the parsers call ``.get(...)``,
``[...]`` indexing and ``json.loads()`` while *assuming a dict-typed top-level
JSON object*, with no try/except around the shape assumption. Hostile scalar or
list input (``5``, ``[]``, ``"x"``, ``null``) therefore escapes as an unhandled
``AttributeError`` / ``KeyError`` / ``TypeError`` instead of the controlled
validation error, turning a bad request into a verifier-side 500 / crash (DoS).

Targets:
  * runtime_policy      -> ima.verify_runtime_policy(data, None, verify_sig=False)
  * deserialize_policy  -> ima.deserialize_runtime_policy(str)
  * dsse_envelope       -> signing.verify_dsse_envelope(bytes)

Crash policy (STRICT)
---------------------
Unlike the hand-written binary parsers in the tpm-quote fuzzer (where raising
*any* exception is acceptable rejection of garbage), these are REST request
handlers whose contract is to reject bad input with a *controlled* error, never
to leak an arbitrary exception to the caller. So the policy here is inverted:

  * We ACCEPT (swallow as graceful) only the controlled validation exception
    each function is documented to raise, listed per-target in ``ALLOWED``.
    A normal return is of course also graceful.
  * We treat EVERY OTHER exception as a finding and re-raise it so the fuzzer /
    replayer records a crash. This is precisely the issue #1139 shape-confusion
    class: a bad request that should become a 4xx but instead throws
    AttributeError / KeyError / TypeError / JSONDecodeError (a 500 / DoS).

In addition, and regardless of target:
  * MemoryError / RecursionError / SystemError are never in ``ALLOWED`` and so
    are always re-raised - the input-controlled resource-exhaustion /
    unbounded-recursion DoS class (e.g. a pathological ``exclude`` regex, an
    oversized base64 payload).
  * a hang (e.g. catastrophic-backtracking "ReDoS" regex compiled from the
    attacker-controlled exclude list) is caught out-of-band by the
    atheris/libFuzzer ``-timeout`` and the replayer's SIGALRM.
  * a hard interpreter crash (segfault in a C extension) terminates the
    process regardless of this handling.

NOTE: against a keylime that still carries the open #1139 bugs this test is
*expected to report findings* (that is its purpose - it documents them as
reproducers). It turns green once keylime guards these parsers; at that point
the only surviving exceptions are the ALLOWED controlled validation errors.
"""

import base64
import datetime
import json
import logging
import os

# Importing keylime is done here at module load; the atheris harness wraps this
# import in atheris.instrument_imports() so the parsers under test are
# instrumented for coverage feedback.
from keylime import signing
from keylime.dsse import dsse
from keylime.ima import ima
from keylime.ima.ima import ImaValidationError

# Silence keylime logging: these handlers log rejected input verbatim, which
# floods the captured campaign output (and can fail to encode surrogate-escaped
# bytes). The fuzzer judges the parsers by the exceptions they raise, not by what
# they log.
logging.disable(logging.CRITICAL)

# Resource-exhaustion / broken-invariant exceptions. They are never in ALLOWED
# (so they are already re-raised as findings); the tuple is kept so replay.py
# can label them distinctly from an ordinary shape-confusion crash.
SERIOUS = (MemoryError, RecursionError, SystemError)

TARGETS = ("runtime_policy", "deserialize_policy", "dsse_envelope")

# Per-target set of exceptions that count as *graceful* rejection of hostile
# input (swallowed). Everything else that escapes _call() is a finding.
#
#   runtime_policy / deserialize_policy -> contract is ImaValidationError
#   dsse_envelope                       -> contract is to RETURN (None or a
#                                          VerifiedPayload); it catches its own
#                                          ValueError internally, so ANY escaping
#                                          exception is a finding (empty tuple).
ALLOWED = {
    "runtime_policy": (ImaValidationError,),
    "deserialize_policy": (ImaValidationError,),
    "dsse_envelope": (),
}


def _call(target, data):
    """Decode ``data`` for ``target`` and invoke the parser under test.

    Raises the parser's own exception unchanged (no policy applied here).
    """
    data = bytes(data)
    if target == "runtime_policy":
        # REST entry point with signature verification off, which is the
        # "best single unit target" from issue #1139: it exercises json.loads,
        # the ``.get("payload")`` dict-shape assumption, DSSE payload b64dec and
        # the attacker-controlled exclude-list regex compilation in one call.
        ima.verify_runtime_policy(data, None, False)
    elif target == "deserialize_policy":
        # Takes a str. latin-1 keeps the byte->str mapping total and reversible
        # so the fuzzer can drive the unguarded json.loads() with arbitrary
        # bytes (every byte maps to a code point, nothing is lost or rejected).
        ima.deserialize_runtime_policy(data.decode("latin-1"))
    elif target == "dsse_envelope":
        # key=None path: unguarded json.loads(), ["signatures"] indexing,
        # base64 decode of ``keyid`` and X.509 cert loading on attacker bytes.
        signing.verify_dsse_envelope(data)
    else:
        raise ValueError(f"unknown fuzz target: {target}")


def run_one(target, data):
    """Run one input through ``target`` applying the strict crash policy.

    Returns None on graceful handling (a controlled validation error or a
    normal return). Re-raises on anything else so the caller (atheris harness or
    replayer) records a finding.
    """
    try:
        _call(target, data)
    except ALLOWED[target]:
        # Controlled rejection of malformed input - the documented contract.
        return
    # Any other exception (incl. SERIOUS) propagates to the caller as a finding.


def classify_exception(exc):
    """Return a short, stable signature for ``exc``: ``ExcType@file.py:lineno``.

    The location is the deepest traceback frame *inside keylime* (so the
    signature points at the keylime line that failed to guard its input, not at
    a stdlib json/re frame). This is what the survey harness uses to group many
    crashing inputs into distinct findings, so each real bug is reported once.
    """
    loc = None
    tb = exc.__traceback__
    while tb is not None:
        filename = tb.tb_frame.f_code.co_filename
        if f"{os.sep}keylime{os.sep}" in filename or os.path.basename(os.path.dirname(filename)) == "keylime":
            loc = f"{os.path.basename(filename)}:{tb.tb_lineno}"
        tb = tb.tb_next
    if loc is None and exc.__traceback__ is not None:
        # Fall back to the deepest frame overall if nothing matched keylime.
        tb = exc.__traceback__
        while tb.tb_next is not None:
            tb = tb.tb_next
        loc = f"{os.path.basename(tb.tb_frame.f_code.co_filename)}:{tb.tb_lineno}"
    return f"{type(exc).__name__}@{loc or 'unknown'}"


# --------------------------------------------------------------------------
# Seed corpus generation
# --------------------------------------------------------------------------
def _valid_policy_json():
    """A minimal but schema-shaped runtime policy object (dict)."""
    return {
        "meta": {"version": 1},
        "release": 0,
        "digests": {},
        "excludes": [],
        "keyrings": {},
        "ima": {"ignored_keyrings": [], "log_hash_alg": "sha256"},
        "ima-buf": {},
        "verification-keys": "",
    }


def _self_signed_cert_pem():
    """Best-effort self-signed ECDSA cert (PEM bytes) for DSSE ``keyid`` seeds.

    Reaching load_pem_x509_certificate successfully lets a seed cover the
    verifier-construction happy path; dsse.Verify then rejects the (absent)
    signature via its own caught ValueError, so the call returns gracefully.
    Returns None if cryptography is unavailable.
    """
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import NameOID

        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "keylime-fuzz")])
        now = datetime.datetime.utcnow()
        cert = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now)
            .not_valid_after(now + datetime.timedelta(days=1))
            .sign(key, hashes.SHA256())
        )
        return cert.public_bytes(serialization.Encoding.PEM)
    except Exception:  # pragma: no cover - environment dependent
        return None


def _b64(data):
    return base64.b64encode(data).decode("ascii")


def _dsse_envelope(payload_obj, with_cert=True):
    """A structurally valid DSSE envelope wrapping ``payload_obj``."""
    env = {
        "payload": _b64(json.dumps(payload_obj).encode()),
        "payloadType": "application/vnd.in-toto+json",
        "signatures": [{"sig": _b64(b"not-a-real-signature")}],
    }
    if with_cert:
        cert = _self_signed_cert_pem()
        if cert is not None:
            env["signatures"][0]["keyid"] = _b64(cert)
    return json.dumps(env).encode()


# JSON scalars / wrong-shape top levels shared by all targets: these are the
# core issue #1139 shape-confusion inputs (dict assumed, scalar/list given).
_SHAPE_CONFUSION = [
    b"",  # empty input
    b"5",
    b"3.14",
    b'"a string"',
    b"[]",
    b"[1, 2, 3]",
    b"null",
    b"true",
    b"false",
    b"{}",  # valid empty object (graceful)
    b"not even json",
    b'{"unterminated": ',
]


def make_seeds():
    """Return {target: [seed_bytes, ...]}.

    Includes valid objects (to seed coverage of the happy path) and known
    adversarial inputs that target the issue #1139 findings: scalar/list
    shape-confusion, non-dict ``signatures`` / ``exclude``, non-str ``payload``,
    malformed base64, bogus X.509 material and pathological regexes. These
    double as a deterministic regression/documentation corpus for replay.py.
    """
    seeds = {t: [] for t in TARGETS}
    valid = _valid_policy_json()
    valid_bytes = json.dumps(valid).encode()
    dsse_env = _dsse_envelope(valid)

    # ---- runtime_policy --------------------------------------------------
    seeds["runtime_policy"].append(valid_bytes)  # happy path
    seeds["runtime_policy"].append(dsse_env)  # DSSE payload, verify_sig=False path
    seeds["runtime_policy"].extend(_SHAPE_CONFUSION)
    # payload present but not a string -> .encode()/b64dec shape confusion.
    seeds["runtime_policy"].append(b'{"payload": 123}')
    seeds["runtime_policy"].append(b'{"payload": ["x"]}')
    seeds["runtime_policy"].append(b'{"payload": "!!! not base64 !!!"}')
    # exclude list shape confusion -> "(" + ")|(".join(exclude) + ")".
    seeds["runtime_policy"].append(b'{"exclude": 5}')  # join on int
    seeds["runtime_policy"].append(b'{"exclude": [1, 2]}')  # join on non-str items
    seeds["runtime_policy"].append(b'{"exclude": {"a": 1}}')  # join on dict keys
    # invalid regex -> controlled ImaValidationError (graceful under policy).
    seeds["runtime_policy"].append(b'{"exclude": ["("]}')
    # ReDoS / resource probes in the compiled exclude regex.
    seeds["runtime_policy"].append(b'{"exclude": ["(a+)+$", "(.*a){50}"]}')
    seeds["runtime_policy"].append(b'{"exclude": ["a{2147483647}"]}')  # huge repeat

    # ---- deserialize_policy ----------------------------------------------
    seeds["deserialize_policy"].append(valid_bytes)  # happy path
    seeds["deserialize_policy"].append(dsse_env)  # DSSE payload extraction path
    seeds["deserialize_policy"].extend(_SHAPE_CONFUSION)
    seeds["deserialize_policy"].append(b'{"payload": 123}')  # non-str payload
    seeds["deserialize_policy"].append(b'{"payload": "!!!notb64!!!"}')  # bad b64
    seeds["deserialize_policy"].append(b'{"payload": "eyJhIjo="}')  # b64 of bad JSON

    # ---- dsse_envelope ---------------------------------------------------
    seeds["dsse_envelope"].append(dsse_env)  # structurally valid envelope
    seeds["dsse_envelope"].extend(_SHAPE_CONFUSION)
    seeds["dsse_envelope"].append(b'{"signatures": 5}')  # non-iterable signatures
    seeds["dsse_envelope"].append(b'{"signatures": "abc"}')  # str: iterates chars
    seeds["dsse_envelope"].append(b'{"signatures": [1, 2]}')  # non-dict signer
    seeds["dsse_envelope"].append(b'{"signatures": [{}]}')  # missing keyid
    seeds["dsse_envelope"].append(b'{"signatures": [{"keyid": 5}]}')  # non-str keyid
    seeds["dsse_envelope"].append(b'{"signatures": [{"keyid": "!!!"}]}')  # bad b64
    # keyid is valid base64 but not a PEM certificate -> x509 load failure.
    seeds["dsse_envelope"].append(
        json.dumps({"signatures": [{"keyid": _b64(b"not a certificate")}]}).encode()
    )
    seeds["dsse_envelope"].append(b'{"nosignatures": true}')  # missing signatures key

    return seeds
