#!/bin/bash

# WRFCoin Performance Benchmarking Setup Script
# Task 99.18: DoS Resilience Validation Infrastructure Setup

set -e

echo "🚀 Setting up WRFCoin Performance Benchmarking Infrastructure..."
echo "=================================================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/test"
REPORTS_DIR="$PROJECT_ROOT/test-reports"
PERFORMANCE_REPORTS_DIR="$REPORTS_DIR/performance-benchmarking"

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running from correct directory
if [ ! -d "$PROJECT_ROOT" ]; then
    print_error "Project root directory not found: $PROJECT_ROOT"
    print_error "Please run this script from the WRFCoin contracts directory"
    exit 1
fi

cd "$PROJECT_ROOT"

print_status "Validating project structure..."

# Verify required files exist
REQUIRED_FILES=(
    "hardhat.config.js"
    "package.json"
    "test/PerformanceBenchmarker.test.js"
    "test/run-performance-benchmarks.js"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        print_error "Required file missing: $file"
        exit 1
    fi
done

print_success "Project structure validated"

# Create report directories
print_status "Creating report directory structure..."

mkdir -p "$REPORTS_DIR"
mkdir -p "$PERFORMANCE_REPORTS_DIR"
mkdir -p "$PERFORMANCE_REPORTS_DIR/archive"

print_success "Report directories created"

# Check Node.js version
print_status "Checking Node.js version..."
NODE_VERSION=$(node --version | cut -d'v' -f2)
REQUIRED_NODE_VERSION="18.0.0"

if [ "$(printf '%s\n' "$REQUIRED_NODE_VERSION" "$NODE_VERSION" | sort -V | head -n1)" != "$REQUIRED_NODE_VERSION" ]; then
    print_warning "Node.js version $NODE_VERSION detected. Recommended: >= $REQUIRED_NODE_VERSION"
else
    print_success "Node.js version $NODE_VERSION is compatible"
fi

# Check npm and install dependencies
print_status "Checking dependencies..."

if [ ! -d "node_modules" ]; then
    print_status "Installing npm dependencies..."
    npm install
    print_success "Dependencies installed"
else
    print_status "Dependencies already installed, checking for updates..."
    npm update
    print_success "Dependencies updated"
fi

# Verify Hardhat installation
print_status "Verifying Hardhat installation..."
if ! npx hardhat --version > /dev/null 2>&1; then
    print_error "Hardhat not properly installed"
    exit 1
fi
print_success "Hardhat installation verified"

# Check for required contracts
print_status "Verifying smart contract availability..."

REQUIRED_CONTRACTS=(
    "WRFToken.sol"
    "NFTMarketplace.sol"  
    "GovernanceSecurityFramework.sol"
    "CarbonCreditAMM.sol"
    "ComputationalNFT.sol"
    "DOSTestHelper.sol"
    "GasConsumptionAnalyzer.sol"
)

MISSING_CONTRACTS=()

for contract in "${REQUIRED_CONTRACTS[@]}"; do
    if [ ! -f "$contract" ]; then
        # Check if it exists in subdirectories
        CONTRACT_FOUND=$(find . -name "$contract" -type f | head -1)
        if [ -z "$CONTRACT_FOUND" ]; then
            MISSING_CONTRACTS+=("$contract")
        fi
    fi
done

if [ ${#MISSING_CONTRACTS[@]} -gt 0 ]; then
    print_warning "Some contracts not found in root directory:"
    for contract in "${MISSING_CONTRACTS[@]}"; do
        echo "  - $contract"
    done
    print_warning "Performance benchmarking may fail if contracts cannot be deployed"
else
    print_success "All required contracts located"
fi

# Test compilation
print_status "Testing contract compilation..."
if npx hardhat compile > /dev/null 2>&1; then
    print_success "Contract compilation successful"
else
    print_error "Contract compilation failed"
    print_error "Please fix compilation errors before running performance benchmarks"
    exit 1
fi

# Create configuration file
print_status "Creating performance benchmarking configuration..."

cat > "$TEST_DIR/performance-benchmark.config.js" << 'EOF'
// WRFCoin Performance Benchmarking Configuration
// Task 99.18: DoS Resilience Validation

module.exports = {
    // Target protection level
    TARGET_TVL_USD: 30000000, // $30M USD

    // Test timeouts (milliseconds)
    TIMEOUTS: {
        INDIVIDUAL_TEST: 600000,     // 10 minutes per test
        SUITE_TIMEOUT: 1800000,      // 30 minutes per suite  
        TOTAL_TIMEOUT: 2700000       // 45 minutes total
    },

    // Performance thresholds
    GAS_LIMITS: {
        SIMPLE_OPERATION: 200000,
        COMPLEX_OPERATION: 1500000,
        BATCH_OPERATION: 8000000,
        CRITICAL_OPERATION: 15000000,
        BLOCK_LIMIT: 30000000
    },

    // DoS resilience requirements
    RESILIENCE_REQUIREMENTS: {
        MIN_THROUGHPUT_TPS: 1.0,
        MAX_LATENCY_MS: 30000,
        MIN_SUCCESS_RATE_PERCENT: 95,
        MAX_RECOVERY_TIME_MS: 60000
    },

    // Scaling test parameters
    SCALING_TESTS: {
        ROYALTY_RECIPIENTS: [1, 5, 10, 20, 30, 50, 75, 100],
        PROPOSAL_COUNTS: [10, 50, 100, 250, 500, 1000, 2000, 5000],
        STRESS_TEST_ITERATIONS: 500,
        CONCURRENT_USERS: 20
    },

    // Report configuration
    REPORTS: {
        GENERATE_JSON: true,
        GENERATE_HTML: true,
        GENERATE_EXECUTIVE_SUMMARY: true,
        ARCHIVE_PREVIOUS: true
    }
};
EOF

print_success "Configuration file created: $TEST_DIR/performance-benchmark.config.js"

# Create quick validation test
print_status "Creating quick validation test..."

cat > "$TEST_DIR/validate-performance-setup.js" << 'EOF'
// Quick validation test for performance benchmarking setup
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Performance Benchmarking Setup Validation", function () {
    it("Should deploy core contracts successfully", async function () {
        this.timeout(60000);
        
        console.log("🔍 Validating contract deployment capabilities...");
        
        // Test WRFToken deployment
        const WRFToken = await ethers.getContractFactory("WRFToken");
        const wrfToken = await WRFToken.deploy();
        expect(await wrfToken.name()).to.equal("WRF Coin");
        console.log("  ✅ WRFToken deployed successfully");
        
        // Test NFTMarketplace deployment  
        const NFTMarketplace = await ethers.getContractFactory("NFTMarketplace");
        const marketplace = await NFTMarketplace.deploy();
        expect(await marketplace.getAddress()).to.be.properAddress;
        console.log("  ✅ NFTMarketplace deployed successfully");
        
        // Test ComputationalNFT deployment
        const ComputationalNFT = await ethers.getContractFactory("ComputationalNFT");
        const nft = await ComputationalNFT.deploy("Test NFT", "TNFT", "https://test.com/");
        expect(await nft.name()).to.equal("Test NFT");
        console.log("  ✅ ComputationalNFT deployed successfully");
        
        console.log("🎉 All core contracts deploy successfully");
    });
    
    it("Should validate performance testing utilities", async function () {
        console.log("🔧 Validating performance testing infrastructure...");
        
        const fs = require('fs');
        const path = require('path');
        
        // Check report directories
        const reportsDir = path.join(__dirname, '../test-reports/performance-benchmarking');
        expect(fs.existsSync(reportsDir)).to.be.true;
        console.log("  ✅ Report directories exist");
        
        // Check configuration file
        const configPath = path.join(__dirname, 'performance-benchmark.config.js');
        expect(fs.existsSync(configPath)).to.be.true;
        console.log("  ✅ Configuration file exists");
        
        // Test configuration loading
        const config = require('./performance-benchmark.config.js');
        expect(config.TARGET_TVL_USD).to.equal(30000000);
        expect(config.GAS_LIMITS).to.be.an('object');
        console.log("  ✅ Configuration loads correctly");
        
        console.log("🎉 Performance testing infrastructure ready");
    });
});
EOF

print_success "Quick validation test created"

# Run quick validation
print_status "Running quick validation test..."
if npx hardhat test test/validate-performance-setup.js --timeout 120000; then
    print_success "Quick validation passed - setup is ready!"
else
    print_error "Quick validation failed - please check the errors above"
    exit 1
fi

# Create helpful scripts
print_status "Creating helper scripts..."

# Create run script
cat > "$PROJECT_ROOT/run-performance-benchmarks.sh" << 'EOF'
#!/bin/bash

echo "🚀 Running WRFCoin Performance Benchmarking Suite..."
echo "Target: $30M TVL DoS Resilience Validation"
echo ""

cd "$(dirname "$0")"

# Archive previous results
if [ -d "test-reports/performance-benchmarking" ]; then
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    mkdir -p "test-reports/performance-benchmarking/archive"
    if [ -f "test-reports/performance-benchmarking/comprehensive_performance_benchmark.json" ]; then
        mv test-reports/performance-benchmarking/*.json test-reports/performance-benchmarking/archive/
        mv test-reports/performance-benchmarking/*.html test-reports/performance-benchmarking/archive/
        mv test-reports/performance-benchmarking/*.md test-reports/performance-benchmarking/archive/
        echo "📁 Previous results archived with timestamp: $TIMESTAMP"
    fi
fi

# Run the comprehensive performance benchmarking suite
node test/run-performance-benchmarks.js

RESULT=$?

if [ $RESULT -eq 0 ]; then
    echo ""
    echo "🎉 Performance benchmarking completed successfully!"
    echo "📊 Check test-reports/performance-benchmarking/ for detailed results"
    echo "🌐 Open performance_benchmark_report.html for visual report"
else
    echo ""
    echo "❌ Performance benchmarking failed"
    echo "📋 Check the error logs above for details"
fi

exit $RESULT
EOF

chmod +x "$PROJECT_ROOT/run-performance-benchmarks.sh"
print_success "Run script created: run-performance-benchmarks.sh"

# Create quick test script
cat > "$PROJECT_ROOT/quick-performance-test.sh" << 'EOF'
#!/bin/bash

echo "⚡ Quick Performance Test for WRFCoin DoS Resilience"
echo "=================================================="

cd "$(dirname "$0")"

# Run just one critical test for quick validation
echo "🧪 Running NFTMarketplace royalty scaling test..."
npx hardhat test test/PerformanceBenchmarker.test.js --grep "royalty processing scaling patterns" --timeout 600000

RESULT=$?

if [ $RESULT -eq 0 ]; then
    echo "✅ Quick performance test passed!"
else
    echo "❌ Quick performance test failed"
fi

exit $RESULT
EOF

chmod +x "$PROJECT_ROOT/quick-performance-test.sh"
print_success "Quick test script created: quick-performance-test.sh"

# Create README for performance benchmarking
cat > "$PROJECT_ROOT/PERFORMANCE_BENCHMARKING_README.md" << 'EOF'
# WRFCoin Performance Benchmarking for DoS Resilience
## Task 99.18: Comprehensive Performance Validation

### Overview
This suite provides comprehensive performance benchmarking to validate WRFCoin's resistance to Denial of Service (DoS) attacks for protocols protecting up to **$30M USD** in Total Value Locked (TVL).

### Quick Start

```bash
# Full comprehensive benchmarking (30-45 minutes)
./run-performance-benchmarks.sh

# Quick validation test (5-10 minutes)  
./quick-performance-test.sh

# Manual test execution
npx hardhat test test/PerformanceBenchmarker.test.js
```

### Test Coverage

#### 1. NFTMarketplace Royalty Processing
- **Scaling Analysis**: 1-100+ royalty recipients
- **Gas Consumption**: Linear O(n) validation
- **Stress Testing**: Sustained load resistance
- **Attack Simulation**: Reentrancy and gas limit attacks

#### 2. Governance Framework Performance  
- **Proposal Enumeration**: 1-10,000+ proposals
- **Concurrent Operations**: Multi-user voting scenarios
- **Complexity Analysis**: Linear scaling validation
- **Load Testing**: High-throughput proposal processing

#### 3. Cross-Contract DoS Resilience
- **Economic Attacks**: Flash loan manipulation prevention
- **Throughput Maintenance**: >1 TPS under attack
- **Recovery Analysis**: Post-attack system recovery
- **Resource Exhaustion**: Memory and gas limit protection

#### 4. Comprehensive Reporting
- **JSON Reports**: Machine-readable performance data
- **HTML Dashboard**: Visual performance analysis
- **Executive Summary**: Business-ready assessment
- **Recommendations**: Actionable optimization guidance

### Performance Thresholds

| Metric | Target | Critical Limit |
|--------|--------|----------------|
| Gas per Operation | < 1M gas | < 15M gas |
| Response Latency | < 10s | < 30s |
| Transaction Throughput | > 1 TPS | > 0.5 TPS |
| Success Rate | > 95% | > 80% |
| Recovery Time | < 30s | < 60s |

### Report Locations

```
test-reports/performance-benchmarking/
├── comprehensive_performance_benchmark.json  # Complete data
├── performance_benchmark_report.html         # Visual dashboard
├── executive_summary.md                      # Business summary
└── archive/                                  # Previous results
```

### Configuration

Edit `test/performance-benchmark.config.js` to adjust:
- Target TVL protection level
- Performance thresholds
- Test parameters
- Report generation options

### Continuous Integration

Add to your CI/CD pipeline:

```yaml
- name: Performance Benchmarking
  run: |
    cd contracts
    ./setup-performance-benchmarks.sh
    ./run-performance-benchmarks.sh
  timeout-minutes: 60
```

### Interpreting Results

#### Grade System
- **A+/A**: Excellent DoS resilience, ready for production
- **B+/B**: Good resilience, minor optimizations recommended  
- **C**: Moderate resilience, improvements required
- **D**: Poor resilience, significant work needed

#### Critical Metrics
- **Overall Resilience Score**: Combined performance assessment
- **Gas Efficiency**: Operation cost optimization
- **Latency Resilience**: Response time under load
- **Throughput Stability**: Transaction processing consistency
- **Scaling Compliance**: Algorithm complexity validation

### Troubleshooting

#### Common Issues
1. **Contract Compilation Failures**: Run `npx hardhat compile`
2. **Test Timeouts**: Increase timeout in config file
3. **Memory Issues**: Reduce concurrent test parameters
4. **Gas Estimation Failures**: Check network configuration

#### Performance Optimization
1. **High Gas Usage**: Review algorithm complexity
2. **Long Latency**: Optimize critical path operations
3. **Low Throughput**: Implement batching or parallelization
4. **Poor Scaling**: Replace O(n²) algorithms with O(n)

### Support

For issues with performance benchmarking:
1. Check logs in test-reports/performance-benchmarking/
2. Verify contract compilation with `npx hardhat compile`
3. Run quick validation: `./quick-performance-test.sh`
4. Review configuration in `test/performance-benchmark.config.js`

---

**Generated by WRFCoin Performance Benchmarking Setup**
**Task 99.18 - DoS Resilience Validation Infrastructure**
EOF

print_success "Documentation created: PERFORMANCE_BENCHMARKING_README.md"

# Final summary
echo ""
echo "=================================================================="
print_success "WRFCoin Performance Benchmarking Setup Complete!"
echo "=================================================================="
echo ""
print_status "📁 Files Created:"
echo "  - test/PerformanceBenchmarker.test.js (comprehensive test suite)"
echo "  - test/run-performance-benchmarks.js (automated runner)"
echo "  - test/performance-benchmark.config.js (configuration)"
echo "  - test/validate-performance-setup.js (quick validation)"
echo "  - run-performance-benchmarks.sh (full suite runner)"
echo "  - quick-performance-test.sh (quick validation runner)"
echo "  - PERFORMANCE_BENCHMARKING_README.md (documentation)"
echo ""
print_status "📊 Report Directory Created:"
echo "  - test-reports/performance-benchmarking/"
echo ""
print_status "🚀 Ready to Run:"
echo "  Full benchmarking: ./run-performance-benchmarks.sh"
echo "  Quick test:        ./quick-performance-test.sh"
echo ""
print_success "Performance benchmarking infrastructure ready for Task 99.18!"
EOF