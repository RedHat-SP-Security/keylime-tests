/*
 * TPM2_Certify using persistent handle and qualifying data
 * Outputs raw binary attestation and signature to files
 * Base64 encoding is done by shell script using standard base64 command
 */
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <tss2/tss2_esys.h>
#include <tss2/tss2_mu.h>
#include <tss2/tss2_tctildr.h>
#include <vector>

std::vector<uint8_t> read_file(const char *filename)
{
    std::ifstream file(filename, std::ios::binary);
    if (!file.is_open()) {
        std::cerr << "ERROR: Cannot open file: " << filename << std::endl;
        exit(1);
    }
    std::vector<uint8_t> data((std::istreambuf_iterator<char>(file)),
                              std::istreambuf_iterator<char>());
    file.close();
    return data;
}

void write_file(const char *filename, const uint8_t *data, size_t len)
{
    std::ofstream file(filename, std::ios::binary);
    if (!file.is_open()) {
        std::cerr << "ERROR: Cannot write file: " << filename << std::endl;
        exit(1);
    }
    file.write(reinterpret_cast<const char *>(data), len);
    file.close();
}

struct TctiDeleter {
    void operator()(TSS2_TCTI_CONTEXT *ctx) const
    {
        if (ctx) {
            Tss2_TctiLdr_Finalize(&ctx);
        }
    }
};

struct EsysDeleter {
    void operator()(ESYS_CONTEXT *ctx) const
    {
        if (ctx) {
            Esys_Finalize(&ctx);
        }
    }
};

struct FreeDeleter {
    void operator()(void *ptr) const
    {
        free(ptr);
    }
};

using TctiContextPtr = std::unique_ptr<TSS2_TCTI_CONTEXT, TctiDeleter>;
using EsysContextPtr = std::unique_ptr<ESYS_CONTEXT, EsysDeleter>;
template <typename T> using TpmPtr = std::unique_ptr<T, FreeDeleter>;

int run_certify(unsigned long handle_value, const char *challenge_file,
                const char *attest_out, const char *sig_out)
{
    // Read challenge
    std::vector<uint8_t> challenge_bytes = read_file(challenge_file);
    std::cerr << "Read challenge: " << challenge_bytes.size() << " bytes"
              << std::endl;

    // Initialize TPM
    TSS2_TCTI_CONTEXT *tcti_ctx_raw = nullptr;
    ESYS_CONTEXT *esys_ctx_raw = nullptr;
    TSS2_RC rc;

    const char *tcti_conf = getenv("TPM2TOOLS_TCTI");
    if (tcti_conf == nullptr || strlen(tcti_conf) == 0) {
        tcti_conf = "device:/dev/tpm0";
    }

    rc = Tss2_TctiLdr_Initialize(tcti_conf, &tcti_ctx_raw);
    if (rc != TSS2_RC_SUCCESS) {
        std::cerr << "ERROR: TCTI init failed: 0x" << std::hex << rc << std::dec
                  << std::endl;
        return 1;
    }
    TctiContextPtr tcti_ctx(tcti_ctx_raw);

    rc = Esys_Initialize(&esys_ctx_raw, tcti_ctx.get(), nullptr);
    if (rc != TSS2_RC_SUCCESS) {
        std::cerr << "ERROR: ESAPI init failed: 0x" << std::hex << rc
                  << std::dec << std::endl;
        return 1;
    }
    EsysContextPtr esys_ctx(esys_ctx_raw);

    std::cerr << "Connected to TPM" << std::endl;

    // Load persistent handle
    ESYS_TR akHandle = ESYS_TR_NONE;
    rc = Esys_TR_FromTPMPublic(esys_ctx.get(), handle_value, ESYS_TR_NONE,
                               ESYS_TR_NONE, ESYS_TR_NONE, &akHandle);
    if (rc != TSS2_RC_SUCCESS) {
        std::cerr << "ERROR: Failed to load persistent handle: 0x" << std::hex
                  << rc << std::dec << std::endl;
        return 1;
    }

    std::cerr << "Loaded AK from persistent handle" << std::endl;

    // Prepare qualifying data
    TPM2B_DATA qualifying_data;
    memset(&qualifying_data, 0, sizeof(qualifying_data));
    qualifying_data.size = challenge_bytes.size();
    if (qualifying_data.size > sizeof(qualifying_data.buffer)) {
        std::cerr << "ERROR: Challenge too large" << std::endl;
        return 1;
    }
    memcpy(qualifying_data.buffer, challenge_bytes.data(),
           qualifying_data.size);

    // Call TPM2_Certify
    TPMT_SIG_SCHEME in_scheme;
    memset(&in_scheme, 0, sizeof(in_scheme));
    in_scheme.scheme = TPM2_ALG_NULL;

    TPM2B_ATTEST *certify_info_raw = nullptr;
    TPMT_SIGNATURE *signature_raw = nullptr;

    std::cerr << "Calling TPM2_Certify..." << std::endl;

    rc = Esys_Certify(esys_ctx.get(), akHandle, akHandle, ESYS_TR_PASSWORD,
                      ESYS_TR_PASSWORD, ESYS_TR_NONE, &qualifying_data,
                      &in_scheme, &certify_info_raw, &signature_raw);

    if (rc != TSS2_RC_SUCCESS) {
        std::cerr << "ERROR: TPM2_Certify failed: 0x" << std::hex << rc
                  << std::dec << std::endl;
        return 1;
    }

    TpmPtr<TPM2B_ATTEST> certify_info(certify_info_raw);
    TpmPtr<TPMT_SIGNATURE> signature(signature_raw);

    std::cerr << "TPM2_Certify successful!" << std::endl;

    // Write attestation data (without TPM2B wrapper) to file
    write_file(attest_out, certify_info->attestationData, certify_info->size);
    std::cerr << "Wrote attestation (" << certify_info->size << " bytes) to "
              << attest_out << std::endl;

    // Marshal and write signature to file
    uint8_t sig_buffer[4096];
    size_t sig_size = 0;
    rc = Tss2_MU_TPMT_SIGNATURE_Marshal(signature.get(), sig_buffer,
                                        sizeof(sig_buffer), &sig_size);
    if (rc != TSS2_RC_SUCCESS) {
        std::cerr << "ERROR: Marshal signature failed" << std::endl;
        return 1;
    }

    write_file(sig_out, sig_buffer, sig_size);
    std::cerr << "Wrote signature (" << sig_size << " bytes) to " << sig_out
              << std::endl;

    std::cerr << "Success!" << std::endl;
    return 0;
}

int main(int argc, char *argv[])
{
    if (argc != 5) {
        std::cerr
            << "Usage: " << argv[0]
            << " <persistent_handle> <challenge_file> <attest_out> <sig_out>"
            << std::endl;
        std::cerr
            << "Example: " << argv[0]
            << " 0x81010002 /tmp/challenge.bin /tmp/attest.bin /tmp/sig.bin"
            << std::endl;
        return 1;
    }

    unsigned long handle_value = strtoul(argv[1], NULL, 0);
    const char *challenge_file = argv[2];
    const char *attest_out = argv[3];
    const char *sig_out = argv[4];

    return run_certify(handle_value, challenge_file, attest_out, sig_out);
}
