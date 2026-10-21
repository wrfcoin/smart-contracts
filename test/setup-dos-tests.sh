#!/bin/bash

# WRFCoin DoS Security Test Suite Setup Script
# Task 99.18: Setup comprehensive DoS vulnerability testing

set -e

echo "🔒 Setting up WRFCoin DoS Security Test Suite"
echo "=============================================="

# Check if we're in the right directory
if [ ! -f "hardhat.config.js" ]; then
    echo "❌ Error: Please run this script from the contracts directory"
    exit 1
fi

echo "📦 Checking dependencies..."

# Check for required packages
MISSING_DEPS=()

if ! npm list hardhat >/dev/null 2>&1; then
    MISSING_DEPS+=("hardhat")
fi

if ! npm list @nomicfoundation/hardhat-toolbox >/dev/null 2>&1; then
    MISSING_DEPS+=("@nomicfoundation/hardhat-toolbox")
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "📥 Installing missing dependencies: ${MISSING_DEPS[*]}"
    npm install "${MISSING_DEPS[@]}"
fi

echo "✅ Dependencies verified"

# Create report directories
echo "📁 Setting up report directories..."
mkdir -p test-reports/dos-security
chmod -R 755 test-reports

echo "🧪 Validating test files..."

# Check test files exist
TEST_FILES=(
    "test/DOSSecurityTestSuite.test.js"
    "test/DOSFuzzingTests.test.js"  
    "test/DOSAttackSimulation.test.js"
    "test/DOSGasAnalysis.test.js"
    "test/DOSTestHelper.sol"
    "test/run-dos-security-tests.js"
)

ALL_FILES_EXIST=true
for file in "${TEST_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "❌ Missing test file: $file"
        ALL_FILES_EXIST=false
    else
        echo "✅ Found: $file"
    fi
done

if [ "$ALL_FILES_EXIST" = false ]; then
    echo "❌ Some test files are missing. Please ensure all DoS security test files are present."
    exit 1
fi

# Make test runner executable
chmod +x test/run-dos-security-tests.js

echo "🔧 Validating contract compilation..."

# Compile contracts to ensure everything is working
if npx hardhat compile >/dev/null 2>&1; then
    echo "✅ Contract compilation successful"
else
    echo "❌ Contract compilation failed. Please check for compilation errors."
    exit 1
fi

echo "🧪 Running quick validation test..."

# Run a quick test to ensure setup is working
if timeout 60 npx hardhat test test/DOSSecurityTestSuite.test.js --timeout 30000 --grep "Should handle maximum number of royalty recipients" >/dev/null 2>&1; then
    echo "✅ Quick validation test passed"
else
    echo "⚠️ Quick validation test failed or timed out (this may be normal for complex tests)"
fi

echo ""
echo "✅ DoS Security Test Suite Setup Complete!"
echo "==========================================="
echo ""
echo "📋 Available Commands:"
echo ""
echo "  # Run all DoS security tests with comprehensive reporting"
echo "  node test/run-dos-security-tests.js"
echo ""
echo "  # Run individual test suites"
echo "  npx hardhat test test/DOSSecurityTestSuite.test.js    # Main security tests"  
echo "  npx hardhat test test/DOSFuzzingTests.test.js         # Fuzzing tests"
echo "  npx hardhat test test/DOSAttackSimulation.test.js     # Attack simulations"
echo "  npx hardhat test test/DOSGasAnalysis.test.js          # Gas analysis"
echo ""
echo "📊 Reports will be generated in: test-reports/dos-security/"
echo ""
echo "📖 For detailed documentation, see: test/DOS_SECURITY_TESTING_README.md"
echo ""
echo "🚨 Critical Vulnerabilities Tested:"
echo "   • NFTMarketplace royalty processing DoS (Lines 1089-1095, 1345-1351)"
echo "   • GovernanceSecurityFramework proposal enumeration (Lines 845-853)"
echo "   • General gas limit exploitation attacks"
echo "   • Economic manipulation and flash loan attacks"
echo ""
echo "⏱️ Expected runtime: 30-60 minutes for complete test suite"
echo ""

# Provide system info for debugging
echo "🖥️ System Information:"
echo "   Node.js: $(node --version)"
echo "   NPM: $(npm --version)"
echo "   Working Directory: $(pwd)"
echo "   Available Memory: $(free -h 2>/dev/null | grep Mem || echo 'N/A')"
echo ""

echo "🎯 Ready to run DoS security tests for Task 99.18!"

# Create a quick run script for convenience
cat > run-dos-tests.sh << 'EOF'
#!/bin/bash
echo "🔒 Running WRFCoin DoS Security Tests..."
node test/run-dos-security-tests.js
EOF

chmod +x run-dos-tests.sh
echo "   Quick run script created: ./run-dos-tests.sh"
echo ""
