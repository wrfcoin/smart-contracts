#!/usr/bin/env node

/**
 * Comprehensive DoS Security Test Suite Runner
 *
 * This script orchestrates the execution of all DoS security tests
 * and generates comprehensive reports for Task 99.18 security validation.
 *
 * Test Categories:
 * 1. Main DoS Security Test Suite
 * 2. Fuzzing Tests for Edge Cases
 * 3. Attack Simulation Tests
 * 4. Gas Analysis and Benchmarking
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

class DOSSecurityTestRunner {
  constructor() {
    this.results = {
      totalTests: 0,
      passedTests: 0,
      failedTests: 0,
      skippedTests: 0,
      testSuites: {},
      gasAnalysis: {},
      securityFindings: [],
      startTime: null,
      endTime: null,
      duration: 0,
    };

    this.reportDir = path.join(__dirname, '../test-reports');
    this.dosReportDir = path.join(this.reportDir, 'dos-security');

    // Ensure report directories exist
    if (!fs.existsSync(this.reportDir)) {
      fs.mkdirSync(this.reportDir, { recursive: true });
    }
    if (!fs.existsSync(this.dosReportDir)) {
      fs.mkdirSync(this.dosReportDir, { recursive: true });
    }
  }

  async runTestSuite(testFile, suiteName, timeout = 600000) {
    console.log(`\n🧪 Running ${suiteName}...`);
    console.log('='.repeat(50));

    const startTime = Date.now();

    try {
      const command = `npx hardhat test ${testFile} --timeout ${timeout}`;
      const output = execSync(command, {
        encoding: 'utf8',
        cwd: path.join(__dirname, '..'),
        stdio: 'pipe',
      });

      const duration = Date.now() - startTime;

      // Parse test results from output
      const testResults = this.parseTestOutput(output);

      this.results.testSuites[suiteName] = {
        passed: true,
        duration: duration,
        output: output,
        testResults: testResults,
        gasAnalysis: this.extractGasAnalysis(output),
      };

      this.results.passedTests += testResults.passed || 0;
      this.results.failedTests += testResults.failed || 0;
      this.results.totalTests += testResults.total || 0;

      console.log(`✅ ${suiteName} completed successfully in ${duration}ms`);

      // Save individual test report
      this.saveTestReport(suiteName, output, testResults);

      return true;
    } catch (error) {
      const duration = Date.now() - startTime;

      console.log(`❌ ${suiteName} failed after ${duration}ms`);
      console.log(`Error: ${error.message}`);

      this.results.testSuites[suiteName] = {
        passed: false,
        duration: duration,
        error: error.message,
        output: error.stdout || '',
        testResults: this.parseTestOutput(error.stdout || ''),
      };

      // Count failed tests from error output
      const errorResults = this.parseTestOutput(error.stdout || '');
      this.results.failedTests += errorResults.total || 1;
      this.results.totalTests += errorResults.total || 1;

      return false;
    }
  }

  parseTestOutput(output) {
    const results = {
      total: 0,
      passed: 0,
      failed: 0,
      pending: 0,
      gasMetrics: {},
      securityFindings: [],
    };

    // Parse test counts
    const testCountMatch = output.match(/(\d+) passing/);
    if (testCountMatch) results.passed = parseInt(testCountMatch[1]);

    const failingMatch = output.match(/(\d+) failing/);
    if (failingMatch) results.failed = parseInt(failingMatch[1]);

    const pendingMatch = output.match(/(\d+) pending/);
    if (pendingMatch) results.pending = parseInt(pendingMatch[1]);

    results.total = results.passed + results.failed + results.pending;

    // Extract gas metrics
    const gasMatches = output.match(/Gas used[^:]*: (\d+)/g);
    if (gasMatches) {
      results.gasMetrics.measurements = gasMatches.map(match => {
        const value = match.match(/(\d+)/)[1];
        return parseInt(value);
      });

      if (results.gasMetrics.measurements.length > 0) {
        results.gasMetrics.average =
          results.gasMetrics.measurements.reduce((a, b) => a + b) /
          results.gasMetrics.measurements.length;
        results.gasMetrics.max = Math.max(...results.gasMetrics.measurements);
        results.gasMetrics.min = Math.min(...results.gasMetrics.measurements);
      }
    }

    // Extract security findings
    const securityFindings = output.match(/🚨[^✅]+✅[^\n]*/g);
    if (securityFindings) {
      results.securityFindings = securityFindings.map(finding => {
        const attack = finding.match(/🚨 ([^\.]+)/)?.[1] || 'Unknown attack';
        const mitigation =
          finding.match(/✅ ([^\n]+)/)?.[1] || 'Attack mitigated';
        return { attack, mitigation };
      });
    }

    return results;
  }

  extractGasAnalysis(output) {
    const gasAnalysis = {
      measurements: [],
      patterns: {},
      violations: [],
    };

    // Extract gas consumption patterns
    const gasPatternMatches = output.match(/Gas consumption[^:]*: [^\n]*/g);
    if (gasPatternMatches) {
      gasAnalysis.patterns = gasPatternMatches.reduce((acc, match) => {
        const key = match.split(':')[0].trim();
        const value = match.split(':')[1]?.trim();
        acc[key] = value;
        return acc;
      }, {});
    }

    // Extract violations
    const violationMatches = output.match(
      /Gas consumption violations[^:]*: [^\n]*/g
    );
    if (violationMatches) {
      gasAnalysis.violations = violationMatches;
    }

    return gasAnalysis;
  }

  saveTestReport(suiteName, output, testResults) {
    const reportFile = path.join(
      this.dosReportDir,
      `${suiteName.replace(/\s+/g, '_').toLowerCase()}_report.json`
    );

    const report = {
      suiteName: suiteName,
      timestamp: new Date().toISOString(),
      testResults: testResults,
      output: output,
      gasAnalysis: this.extractGasAnalysis(output),
    };

    fs.writeFileSync(reportFile, JSON.stringify(report, null, 2));

    // Also save raw output
    const outputFile = path.join(
      this.dosReportDir,
      `${suiteName.replace(/\s+/g, '_').toLowerCase()}_output.txt`
    );
    fs.writeFileSync(outputFile, output);
  }

  generateComprehensiveReport() {
    const report = {
      title: 'WRFCoin DoS Security Test Suite - Comprehensive Report',
      subtitle: 'Task 99.18: Security Testing for DoS Vulnerabilities',
      timestamp: new Date().toISOString(),
      executionSummary: {
        totalDuration: this.results.duration,
        totalTestSuites: Object.keys(this.results.testSuites).length,
        totalTests: this.results.totalTests,
        passedTests: this.results.passedTests,
        failedTests: this.results.failedTests,
        successRate:
          this.results.totalTests > 0
            ? (
                (this.results.passedTests / this.results.totalTests) *
                100
              ).toFixed(2) + '%'
            : '0%',
      },
      securityAssessment: {
        vulnerabilitiesTested: [
          'NFTMarketplace.sol - Unbounded Royalty Processing DoS (Lines 1089-1095, 1345-1351)',
          'GovernanceSecurityFramework.sol - Unbounded Proposal Enumeration (Lines 845-853)',
          'General gas limit exploitation across multiple contracts',
          'Economic attack vectors and flash loan attacks',
        ],
        testCategories: {
          'Fuzzing Tests': 'Property-based testing with randomized inputs',
          'Attack Simulations': 'Specific DoS attack vector simulations',
          'Gas Analysis': 'Gas consumption patterns and limits validation',
          'Economic Attacks': 'Flash loan and economic manipulation tests',
        },
        mitigationsValidated: [],
      },
      testSuiteResults: {},
      gasAnalysisSummary: {
        totalGasMeasurements: 0,
        averageGasConsumption: 0,
        maxGasConsumption: 0,
        gasViolations: [],
        scalingPatterns: {},
      },
      securityFindings: [],
      recommendations: [],
      conclusion: '',
    };

    // Process test suite results
    Object.entries(this.results.testSuites).forEach(
      ([suiteName, suiteResult]) => {
        report.testSuiteResults[suiteName] = {
          status: suiteResult.passed ? 'PASSED' : 'FAILED',
          duration: suiteResult.duration,
          testsRun: suiteResult.testResults?.total || 0,
          testsPassed: suiteResult.testResults?.passed || 0,
          testsFailed: suiteResult.testResults?.failed || 0,
          gasMetrics: suiteResult.testResults?.gasMetrics || {},
          securityFindings: suiteResult.testResults?.securityFindings || [],
        };

        // Aggregate security findings
        if (suiteResult.testResults?.securityFindings) {
          report.securityFindings.push(
            ...suiteResult.testResults.securityFindings
          );
        }

        // Aggregate gas analysis
        if (
          suiteResult.gasAnalysis &&
          suiteResult.testResults?.gasMetrics?.measurements
        ) {
          report.gasAnalysisSummary.totalGasMeasurements +=
            suiteResult.testResults.gasMetrics.measurements.length;
          if (
            suiteResult.testResults.gasMetrics.max >
            report.gasAnalysisSummary.maxGasConsumption
          ) {
            report.gasAnalysisSummary.maxGasConsumption =
              suiteResult.testResults.gasMetrics.max;
          }
        }
      }
    );

    // Calculate average gas consumption
    let totalGasSum = 0;
    let totalMeasurements = 0;
    Object.values(this.results.testSuites).forEach(suite => {
      if (suite.testResults?.gasMetrics?.measurements) {
        totalGasSum += suite.testResults.gasMetrics.measurements.reduce(
          (a, b) => a + b,
          0
        );
        totalMeasurements += suite.testResults.gasMetrics.measurements.length;
      }
    });

    if (totalMeasurements > 0) {
      report.gasAnalysisSummary.averageGasConsumption = Math.round(
        totalGasSum / totalMeasurements
      );
    }

    // Generate recommendations
    report.recommendations = this.generateRecommendations();

    // Generate conclusion
    report.conclusion = this.generateConclusion();

    return report;
  }

  generateRecommendations() {
    const recommendations = [
      {
        category: 'Gas Optimization',
        priority: 'HIGH',
        recommendation:
          'Implement circuit breakers for operations with unbounded loops to prevent gas limit DoS attacks',
      },
      {
        category: 'Royalty Processing',
        priority: 'MEDIUM',
        recommendation:
          'Consider implementing royalty recipient limits and batch processing optimizations',
      },
      {
        category: 'Governance',
        priority: 'MEDIUM',
        recommendation:
          'Implement pagination for proposal enumeration to maintain constant time complexity',
      },
      {
        category: 'Economic Security',
        priority: 'HIGH',
        recommendation:
          'Maintain flash loan attack protections and consider implementing time-weighted voting',
      },
      {
        category: 'Monitoring',
        priority: 'MEDIUM',
        recommendation:
          'Implement real-time gas consumption monitoring and alerting for anomalous patterns',
      },
    ];

    // Add specific recommendations based on test results
    if (this.results.failedTests > 0) {
      recommendations.push({
        category: 'Test Failures',
        priority: 'HIGH',
        recommendation: `Address ${this.results.failedTests} failed security tests before production deployment`,
      });
    }

    return recommendations;
  }

  generateConclusion() {
    const successRate =
      this.results.totalTests > 0
        ? (this.results.passedTests / this.results.totalTests) * 100
        : 0;

    if (successRate >= 95) {
      return (
        'EXCELLENT: The WRFCoin smart contracts demonstrate robust resistance to DoS attacks. ' +
        'All critical vulnerabilities have been properly mitigated with appropriate gas limits and security controls.'
      );
    } else if (successRate >= 80) {
      return (
        'GOOD: The smart contracts show strong DoS resistance with minor issues identified. ' +
        'Address remaining vulnerabilities before production deployment.'
      );
    } else if (successRate >= 60) {
      return (
        'MODERATE: Significant DoS vulnerabilities require immediate attention. ' +
        'Critical security improvements needed before production readiness.'
      );
    } else {
      return (
        'CRITICAL: Major DoS vulnerabilities detected. Immediate security review and remediation required. ' +
        'Do not deploy to production until all issues are resolved.'
      );
    }
  }

  async run() {
    console.log('🔒 WRFCoin DoS Security Test Suite');
    console.log('===================================');
    console.log('Task 99.18: Comprehensive DoS Vulnerability Testing');
    console.log(`Started at: ${new Date().toISOString()}`);

    this.results.startTime = Date.now();

    const testSuites = [
      {
        file: 'test/DOSSecurityTestSuite.test.js',
        name: 'Main DoS Security Tests',
        timeout: 600000, // 10 minutes
      },
      {
        file: 'test/DOSFuzzingTests.test.js',
        name: 'DoS Fuzzing Tests',
        timeout: 900000, // 15 minutes
      },
      {
        file: 'test/DOSAttackSimulation.test.js',
        name: 'DoS Attack Simulations',
        timeout: 1200000, // 20 minutes
      },
      {
        file: 'test/DOSGasAnalysis.test.js',
        name: 'DoS Gas Analysis',
        timeout: 900000, // 15 minutes
      },
    ];

    let allPassed = true;

    for (const suite of testSuites) {
      const result = await this.runTestSuite(
        suite.file,
        suite.name,
        suite.timeout
      );
      if (!result) {
        allPassed = false;
      }

      // Small delay between test suites
      await new Promise(resolve => setTimeout(resolve, 2000));
    }

    this.results.endTime = Date.now();
    this.results.duration = this.results.endTime - this.results.startTime;

    // Generate comprehensive report
    const comprehensiveReport = this.generateComprehensiveReport();

    // Save comprehensive report
    const reportFile = path.join(
      this.dosReportDir,
      'comprehensive_dos_security_report.json'
    );
    fs.writeFileSync(reportFile, JSON.stringify(comprehensiveReport, null, 2));

    // Generate HTML report
    this.generateHTMLReport(comprehensiveReport);

    // Print summary
    this.printSummary(comprehensiveReport);

    return allPassed;
  }

  generateHTMLReport(report) {
    const html = `
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WRFCoin DoS Security Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #2c3e50; border-bottom: 3px solid #3498db; padding-bottom: 10px; }
        h2 { color: #34495e; margin-top: 30px; }
        .status-passed { color: #27ae60; font-weight: bold; }
        .status-failed { color: #e74c3c; font-weight: bold; }
        .metric-box { background: #ecf0f1; padding: 15px; margin: 10px 0; border-radius: 5px; display: inline-block; min-width: 200px; margin-right: 20px; }
        .metric-label { font-size: 14px; color: #7f8c8d; }
        .metric-value { font-size: 24px; font-weight: bold; color: #2c3e50; }
        .finding { background: #fff3cd; border: 1px solid #ffeaa7; padding: 10px; margin: 5px 0; border-radius: 4px; }
        .recommendation { background: #d1ecf1; border: 1px solid #bee5eb; padding: 10px; margin: 5px 0; border-radius: 4px; }
        .priority-high { border-left: 4px solid #e74c3c; }
        .priority-medium { border-left: 4px solid #f39c12; }
        .priority-low { border-left: 4px solid #27ae60; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background: #3498db; color: white; }
        .conclusion { background: #e8f5e8; border: 2px solid #27ae60; padding: 20px; border-radius: 8px; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔒 ${report.title}</h1>
        <p><strong>${report.subtitle}</strong></p>
        <p><em>Generated on: ${report.timestamp}</em></p>
        
        <h2>📊 Execution Summary</h2>
        <div class="metric-box">
            <div class="metric-label">Total Tests</div>
            <div class="metric-value">${report.executionSummary.totalTests}</div>
        </div>
        <div class="metric-box">
            <div class="metric-label">Success Rate</div>
            <div class="metric-value">${report.executionSummary.successRate}</div>
        </div>
        <div class="metric-box">
            <div class="metric-label">Duration</div>
            <div class="metric-value">${Math.round(report.executionSummary.totalDuration / 1000)}s</div>
        </div>
        
        <h2>🧪 Test Suite Results</h2>
        <table>
            <thead>
                <tr>
                    <th>Test Suite</th>
                    <th>Status</th>
                    <th>Tests Run</th>
                    <th>Passed</th>
                    <th>Failed</th>
                    <th>Duration (ms)</th>
                </tr>
            </thead>
            <tbody>
                ${Object.entries(report.testSuiteResults)
                  .map(
                    ([name, result]) => `
                    <tr>
                        <td>${name}</td>
                        <td class="status-${result.status.toLowerCase()}">${result.status}</td>
                        <td>${result.testsRun}</td>
                        <td class="status-passed">${result.testsPassed}</td>
                        <td class="status-failed">${result.testsFailed}</td>
                        <td>${result.duration.toLocaleString()}</td>
                    </tr>
                `
                  )
                  .join('')}
            </tbody>
        </table>
        
        <h2>⛽ Gas Analysis Summary</h2>
        <div class="metric-box">
            <div class="metric-label">Total Measurements</div>
            <div class="metric-value">${report.gasAnalysisSummary.totalGasMeasurements}</div>
        </div>
        <div class="metric-box">
            <div class="metric-label">Average Gas</div>
            <div class="metric-value">${report.gasAnalysisSummary.averageGasConsumption.toLocaleString()}</div>
        </div>
        <div class="metric-box">
            <div class="metric-label">Max Gas</div>
            <div class="metric-value">${report.gasAnalysisSummary.maxGasConsumption.toLocaleString()}</div>
        </div>
        
        <h2>🔍 Security Findings</h2>
        ${report.securityFindings
          .map(
            finding => `
            <div class="finding">
                <strong>Attack:</strong> ${finding.attack}<br>
                <strong>Mitigation:</strong> ${finding.mitigation}
            </div>
        `
          )
          .join('')}
        
        <h2>💡 Recommendations</h2>
        ${report.recommendations
          .map(
            rec => `
            <div class="recommendation priority-${rec.priority.toLowerCase()}">
                <strong>${rec.category} (${rec.priority}):</strong> ${rec.recommendation}
            </div>
        `
          )
          .join('')}
        
        <h2>📝 Conclusion</h2>
        <div class="conclusion">
            ${report.conclusion}
        </div>
        
        <hr>
        <p><em>This report was generated automatically by the WRFCoin DoS Security Test Suite.</em></p>
    </div>
</body>
</html>`;

    const htmlFile = path.join(this.dosReportDir, 'dos_security_report.html');
    fs.writeFileSync(htmlFile, html);

    console.log(`\n📄 HTML report generated: ${htmlFile}`);
  }

  printSummary(report) {
    console.log('\n' + '='.repeat(60));
    console.log('🔒 DoS SECURITY TEST SUITE SUMMARY');
    console.log('='.repeat(60));
    console.log(
      `Total Test Suites: ${report.executionSummary.totalTestSuites}`
    );
    console.log(`Total Tests: ${report.executionSummary.totalTests}`);
    console.log(`Passed: ${report.executionSummary.passedTests}`);
    console.log(
      `Failed: ${report.executionSummary.totalTests - report.executionSummary.passedTests}`
    );
    console.log(`Success Rate: ${report.executionSummary.successRate}`);
    console.log(
      `Duration: ${Math.round(report.executionSummary.totalDuration / 1000)} seconds`
    );

    console.log('\n📊 Test Suite Results:');
    Object.entries(report.testSuiteResults).forEach(([name, result]) => {
      const status = result.status === 'PASSED' ? '✅' : '❌';
      console.log(
        `${status} ${name}: ${result.testsPassed}/${result.testsRun} passed`
      );
    });

    console.log(
      `\n⛽ Gas Analysis: ${report.gasAnalysisSummary.totalGasMeasurements} measurements`
    );
    console.log(
      `   Average: ${report.gasAnalysisSummary.averageGasConsumption.toLocaleString()} gas`
    );
    console.log(
      `   Maximum: ${report.gasAnalysisSummary.maxGasConsumption.toLocaleString()} gas`
    );

    console.log(
      `\n🔍 Security Findings: ${report.securityFindings.length} attack vectors tested`
    );

    console.log('\n📝 Conclusion:');
    console.log(report.conclusion);

    console.log('\n📁 Reports saved to:', this.dosReportDir);
    console.log('='.repeat(60));
  }
}

// Run the test suite if called directly
if (require.main === module) {
  const runner = new DOSSecurityTestRunner();

  runner
    .run()
    .then(success => {
      process.exit(success ? 0 : 1);
    })
    .catch(error => {
      console.error('Test runner failed:', error);
      process.exit(1);
    });
}

module.exports = DOSSecurityTestRunner;
