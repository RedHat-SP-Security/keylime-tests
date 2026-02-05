# Makefile for tpm_certify_simple
# TPM2_Certify utility using persistent handles

# Compiler and flags
CXX := g++
CXXFLAGS := -std=c++11 -Wall -Wextra -O2
LDFLAGS := -ltss2-esys -ltss2-mu -ltss2-tctildr

# Output binary
TARGET := tpm_certify_simple

# Source files
SOURCES := tpm_certify_simple.cpp

# Default target
all: $(TARGET)

# Build the binary
$(TARGET): $(SOURCES)
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)

# Clean build artifacts
clean:
	rm -f $(TARGET)

# Install (optional - copies to a system directory)
install: $(TARGET)
	install -m 755 $(TARGET) /usr/local/bin/

# Uninstall
uninstall:
	rm -f /usr/local/bin/$(TARGET)

# Debug build (with debug symbols, no optimization)
debug: CXXFLAGS := -std=c++11 -Wall -Wextra -g -O0
debug: clean $(TARGET)

# Run tests
test: $(TARGET)
	./test_tpm_certify.sh
	./test_tpm_helpers.sh

# Help target
help:
	@echo "Available targets:"
	@echo "  all        - Build tpm_certify_simple (default)"
	@echo "  clean      - Remove build artifacts"
	@echo "  debug      - Build with debug symbols"
	@echo "  install    - Install to /usr/local/bin"
	@echo "  uninstall  - Remove from /usr/local/bin"
	@echo "  test       - Run the test suite"
	@echo "  help       - Show this help message"

.PHONY: all clean install uninstall debug test help
