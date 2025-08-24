#!/bin/bash
# Test Coverage Report Generator
# This script runs tests with code coverage enabled and generates a readable report

set -e

echo "📊 Generating Test Coverage Report for Stower Package"
echo "======================================================="

# Change to package directory
cd "$(dirname "$0")/../StowerPackage"

# Clean previous builds
echo "🧹 Cleaning previous build artifacts..."
swift package clean

# Build with coverage instrumentation
echo "🔨 Building with coverage instrumentation..."
swift build --enable-test-discovery

# Run tests with coverage enabled
echo "🧪 Running tests with code coverage..."
swift test --enable-code-coverage --parallel

# Check if coverage data was generated
if [ ! -d ".build/debug/codecov" ]; then
    echo "⚠️  No coverage data found. Coverage may not be properly configured."
    exit 1
fi

echo "✅ Coverage data generated successfully!"

# Generate human-readable report using llvm-cov if available
if command -v llvm-cov >/dev/null 2>&1; then
    echo "📋 Generating detailed coverage report..."
    
    # Find the test executable
    TEST_EXECUTABLE=$(find .build/debug -name "*PackageTests" -type f | head -1)
    
    if [ -n "$TEST_EXECUTABLE" ]; then
        # Generate coverage report
        llvm-cov report "$TEST_EXECUTABLE" -instr-profile=.build/debug/codecov/default.profdata \
            --ignore-filename-regex='\.build|Tests' \
            --use-color > coverage-report.txt
        
        echo "📄 Coverage report saved to coverage-report.txt"
        
        # Show summary
        echo ""
        echo "📈 Coverage Summary:"
        echo "==================="
        llvm-cov report "$TEST_EXECUTABLE" -instr-profile=.build/debug/codecov/default.profdata \
            --ignore-filename-regex='\.build|Tests' \
            --use-color | tail -1
    else
        echo "⚠️  Could not find test executable for detailed reporting"
    fi
else
    echo "ℹ️  llvm-cov not found. Install Xcode Command Line Tools for detailed reports."
fi

echo ""
echo "✨ Coverage report generation complete!"
echo "📁 Coverage data location: .build/debug/codecov/"
echo "📄 Human-readable report: coverage-report.txt (if llvm-cov available)"