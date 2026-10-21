/**
 * WRFCoin Testnet Security Monitoring and Alerting Infrastructure
 * Task 99.18 - Real-time Security Event Detection and Response
 *
 * This module provides comprehensive security monitoring for the testnet environment,
 * specifically designed to detect and alert on:
 * - DoS attack attempts and patterns
 * - Economic attack simulations and outcomes
 * - Gas consumption anomalies and unbounded operations
 * - Circuit breaker activations and security events
 * - Performance degradation under adversarial conditions
 */

const { ethers, artifacts, network: hardhatNetwork } = require('hardhat');
const EventEmitter = require('events');
const fs = require('fs').promises;
const path = require('path');
const {
  loadAndValidateManifest,
  manifestPathFor,
} = require('./scripts/lib/deploymentManifest');

/**
 * Security Event Monitor
 * Monitors blockchain events and detects security anomalies in real-time
 */
class TestnetSecurityMonitor extends EventEmitter {
  constructor(config = {}) {
    super();

    this.config = {
      // Monitoring configuration
      pollingInterval: config.pollingInterval || 5000, // 5 seconds
      alertThresholds: config.alertThresholds || {},
      monitoringEnabled: config.monitoringEnabled !== false,

      // Security parameters from config
      maxGasPerOperation: config.maxGasPerOperation || 15000000,
      dosDetectionThreshold: config.dosDetectionThreshold || 0.8,
      economicAttackThreshold: config.economicAttackThreshold || 1000000,

      // Alert channels
      alertChannels: config.alertChannels || {
        console: true,
        file: true,
        webhook: false,
      },

      // Metrics collection
      metricsEnabled: config.metricsEnabled !== false,
      metricsRetention: config.metricsRetention || 86400000, // 24 hours

      ...config,
    };

    this.providers = new Map();
    this.contracts = new Map();
    this.eventFilters = new Map();
    this.metrics = new Map();
    this.alerts = [];
    this.isMonitoring = false;

    // Initialize metric collections
    this.initializeMetrics();
  }

  /**
   * Initialize monitoring infrastructure
   */
  async initialize(network = hardhatNetwork.name) {
    try {
      console.log(`🔒 Initializing Security Monitor for ${network}...`);

      // Connect to network
      const provider = ethers.provider;
      this.providers.set(network, provider);

      // Load contract instances for monitoring
      await this.loadContracts(network);

      // Setup event filters for critical security events
      await this.setupEventFilters();

      // Initialize metrics collection
      this.startMetricsCollection();

      // Setup alert handlers
      this.setupAlertHandlers();

      console.log(`✅ Security Monitor initialized successfully`);
      this.emit('monitor_initialized', { network, timestamp: Date.now() });
    } catch (error) {
      console.error(`❌ Failed to initialize Security Monitor:`, error);
      throw error;
    }
  }

  /**
   * Load contract instances for monitoring
   */
  async loadContracts(network) {
    const provider = this.providers.get(network);
    const deploymentPath = this.config.manifestPath || manifestPathFor(network);
    const manifest = await loadAndValidateManifest(deploymentPath, {
      provider,
      artifacts,
      networkName: network,
    });

    this.contracts.clear();
    for (const entry of manifest.contracts) {
      const artifact = await artifacts.readArtifact(entry.name);
      const contract = new ethers.Contract(
        entry.address,
        artifact.abi,
        provider
      );
      this.contracts.set(entry.name, contract);
      console.log(`📝 Loaded contract: ${entry.name} at ${entry.address}`);
    }
    return manifest;
  }

  /**
   * Setup event filters for critical security events
   */
  async setupEventFilters() {
    const criticalEvents = [
      // DoS attack detection events
      'UnboundedOperationDetected',
      'GasLimitExceeded',
      'CircuitBreakerTriggered',

      // Economic security events
      'LargeTokenTransfer',
      'SuspiciousVotingActivity',
      'FlashLoanDetected',
      'ProposalBondSlashed',

      // Performance degradation events
      'TransactionTimeout',
      'HighMemoryUsage',
      'ThroughputDegraded',

      // Governance security events
      'CoordinationAttackDetected',
      'VotingAnomalyDetected',
      'EmergencyPause',
    ];

    for (const [contractName, contract] of this.contracts.entries()) {
      try {
        // Setup filters for all events in contract
        const eventNames = contract.interface.fragments
          .filter(fragment => fragment.type === 'event')
          .map(fragment => fragment.name);

        for (const eventName of eventNames) {
          if (criticalEvents.includes(eventName)) {
            const filter = contract.filters[eventName]();
            this.eventFilters.set(`${contractName}.${eventName}`, {
              contract,
              filter,
              eventName,
              contractName,
            });
          }
        }
      } catch (error) {
        console.warn(
          `⚠️  Failed to setup filters for ${contractName}:`,
          error.message
        );
      }
    }

    console.log(
      `📡 Setup ${this.eventFilters.size} event filters for security monitoring`
    );
  }

  /**
   * Start real-time monitoring
   */
  async startMonitoring() {
    if (this.isMonitoring) {
      console.warn('⚠️  Security monitoring is already active');
      return;
    }

    this.isMonitoring = true;
    console.log('🚀 Starting real-time security monitoring...');

    // Start event monitoring
    this.startEventMonitoring();

    // Start gas consumption monitoring
    this.startGasMonitoring();

    // Start performance monitoring
    this.startPerformanceMonitoring();

    // Start economic security monitoring
    this.startEconomicMonitoring();

    this.emit('monitoring_started', { timestamp: Date.now() });
    console.log('✅ Security monitoring active');
  }

  /**
   * Start event monitoring for security events
   */
  startEventMonitoring() {
    for (const [filterKey, filterConfig] of this.eventFilters.entries()) {
      const { contract, filter, eventName, contractName } = filterConfig;

      contract.on(filter, (...args) => {
        const event = args[args.length - 1]; // Last argument is event object

        this.handleSecurityEvent({
          contractName,
          eventName,
          args: args.slice(0, -1),
          event,
          timestamp: Date.now(),
        });
      });
    }
  }

  /**
   * Start gas consumption monitoring
   */
  startGasMonitoring() {
    const provider = Array.from(this.providers.values())[0];

    // Monitor each new block for gas anomalies
    provider.on('block', async blockNumber => {
      try {
        const block = await provider.getBlock(blockNumber, true);

        if (block && block.transactions) {
          for (const txHash of block.transactions) {
            const tx = await provider.getTransaction(txHash);
            const receipt = await provider.getTransactionReceipt(txHash);

            if (receipt && receipt.gasUsed) {
              await this.analyzeGasConsumption(tx, receipt, block);
            }
          }
        }

        // Update block utilization metrics
        this.updateBlockUtilizationMetrics(block);
      } catch (error) {
        console.error('❌ Error in gas monitoring:', error);
      }
    });
  }

  /**
   * Analyze gas consumption for DoS patterns
   */
  async analyzeGasConsumption(transaction, receipt, block) {
    const gasUsed = receipt.gasUsed.toNumber();
    const gasLimit = transaction.gasLimit.toNumber();
    const gasUtilization = gasUsed / gasLimit;

    // Check for high gas consumption indicating potential DoS
    if (gasUsed > this.config.maxGasPerOperation) {
      await this.triggerAlert('HIGH_GAS_CONSUMPTION', {
        transaction: transaction.hash,
        gasUsed,
        gasLimit,
        gasUtilization,
        contract: receipt.to,
        severity: 'HIGH',
      });
    }

    // Check for gas limit approaching block limit
    const blockGasUtilization =
      receipt.cumulativeGasUsed.toNumber() / block.gasLimit.toNumber();
    if (blockGasUtilization > this.config.dosDetectionThreshold) {
      await this.triggerAlert('BLOCK_GAS_UTILIZATION_HIGH', {
        blockNumber: block.number,
        blockGasUtilization,
        cumulativeGasUsed: receipt.cumulativeGasUsed.toNumber(),
        blockGasLimit: block.gasLimit.toNumber(),
        severity: 'MEDIUM',
      });
    }

    // Update gas consumption metrics
    this.updateGasMetrics(transaction, receipt);
  }

  /**
   * Start performance monitoring
   */
  startPerformanceMonitoring() {
    setInterval(async () => {
      try {
        // Monitor transaction throughput
        await this.monitorTransactionThroughput();

        // Monitor response times
        await this.monitorResponseTimes();

        // Monitor memory usage (if available)
        await this.monitorResourceUsage();
      } catch (error) {
        console.error('❌ Error in performance monitoring:', error);
      }
    }, this.config.pollingInterval);
  }

  /**
   * Start economic security monitoring
   */
  startEconomicMonitoring() {
    // Monitor for large token transfers that could indicate attacks
    const wrfToken = this.contracts.get('WRFToken');
    if (wrfToken) {
      const transferFilter = wrfToken.filters.Transfer();

      wrfToken.on(transferFilter, async (from, to, amount, event) => {
        const amountNum = ethers.utils.formatEther(amount);

        if (parseFloat(amountNum) > this.config.economicAttackThreshold) {
          await this.triggerAlert('LARGE_TOKEN_TRANSFER', {
            from,
            to,
            amount: amountNum,
            transaction: event.transactionHash,
            severity: 'MEDIUM',
          });
        }

        this.updateEconomicMetrics(from, to, amount);
      });
    }
  }

  /**
   * Handle security events and determine severity
   */
  async handleSecurityEvent(eventData) {
    console.log(
      `🚨 Security Event Detected: ${eventData.contractName}.${eventData.eventName}`
    );

    // Determine event severity
    const severity = this.determineEventSeverity(eventData);

    // Create alert
    await this.triggerAlert('SECURITY_EVENT', {
      ...eventData,
      severity,
    });

    // Update security metrics
    this.updateSecurityMetrics(eventData);

    // Emit event for external handlers
    this.emit('security_event', eventData);
  }

  /**
   * Determine event severity based on type and context
   */
  determineEventSeverity(eventData) {
    const criticalEvents = [
      'CircuitBreakerTriggered',
      'EmergencyPause',
      'FlashLoanDetected',
      'CoordinationAttackDetected',
    ];

    const highEvents = [
      'UnboundedOperationDetected',
      'GasLimitExceeded',
      'ProposalBondSlashed',
      'SuspiciousVotingActivity',
    ];

    if (criticalEvents.includes(eventData.eventName)) {
      return 'CRITICAL';
    } else if (highEvents.includes(eventData.eventName)) {
      return 'HIGH';
    } else {
      return 'MEDIUM';
    }
  }

  /**
   * Trigger security alert
   */
  async triggerAlert(alertType, data) {
    const alert = {
      id: `alert_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      type: alertType,
      severity: data.severity || 'MEDIUM',
      timestamp: Date.now(),
      data,
    };

    this.alerts.push(alert);

    // Console output
    if (this.config.alertChannels.console) {
      console.log(`\n🚨 SECURITY ALERT [${alert.severity}] - ${alertType}`);
      console.log(`📅 Time: ${new Date(alert.timestamp).toISOString()}`);
      console.log(`📊 Data:`, JSON.stringify(data, null, 2));
      console.log(`🆔 Alert ID: ${alert.id}\n`);
    }

    // File output
    if (this.config.alertChannels.file) {
      await this.writeAlertToFile(alert);
    }

    // Webhook notification (if configured)
    if (this.config.alertChannels.webhook && this.config.webhookUrl) {
      await this.sendWebhookAlert(alert);
    }

    // Emit alert event
    this.emit('alert_triggered', alert);

    return alert;
  }

  /**
   * Write alert to file for persistence
   */
  async writeAlertToFile(alert) {
    try {
      const alertsDir = './test-reports/security-alerts';
      await fs.mkdir(alertsDir, { recursive: true });

      const filename = `alert_${new Date().toISOString().split('T')[0]}.json`;
      const filepath = path.join(alertsDir, filename);

      // Read existing alerts or create new array
      let alerts = [];
      try {
        const existing = await fs.readFile(filepath, 'utf8');
        alerts = JSON.parse(existing);
      } catch {
        // File doesn't exist, start with empty array
      }

      alerts.push(alert);

      await fs.writeFile(filepath, JSON.stringify(alerts, null, 2));
    } catch (error) {
      console.error('❌ Failed to write alert to file:', error);
    }
  }

  /**
   * Initialize metrics collections
   */
  initializeMetrics() {
    this.metrics.set('gasConsumption', []);
    this.metrics.set('transactionThroughput', []);
    this.metrics.set('blockUtilization', []);
    this.metrics.set('securityEvents', []);
    this.metrics.set('economicActivity', []);
    this.metrics.set('performanceMetrics', []);
  }

  /**
   * Update gas consumption metrics
   */
  updateGasMetrics(transaction, receipt) {
    const metric = {
      timestamp: Date.now(),
      transaction: transaction.hash,
      gasUsed: receipt.gasUsed.toNumber(),
      gasLimit: transaction.gasLimit.toNumber(),
      gasPrice: transaction.gasPrice.toNumber(),
      contract: receipt.to,
    };

    this.metrics.get('gasConsumption').push(metric);
    this.cleanupOldMetrics('gasConsumption');
  }

  /**
   * Update block utilization metrics
   */
  updateBlockUtilizationMetrics(block) {
    const metric = {
      timestamp: Date.now(),
      blockNumber: block.number,
      gasUsed: block.gasUsed.toNumber(),
      gasLimit: block.gasLimit.toNumber(),
      utilization: block.gasUsed.toNumber() / block.gasLimit.toNumber(),
      transactionCount: block.transactions.length,
    };

    this.metrics.get('blockUtilization').push(metric);
    this.cleanupOldMetrics('blockUtilization');
  }

  /**
   * Clean up old metrics to prevent memory leaks
   */
  cleanupOldMetrics(metricType) {
    const metrics = this.metrics.get(metricType);
    const cutoff = Date.now() - this.config.metricsRetention;

    const filtered = metrics.filter(metric => metric.timestamp > cutoff);
    this.metrics.set(metricType, filtered);
  }

  /**
   * Generate comprehensive security report
   */
  async generateSecurityReport() {
    const report = {
      generatedAt: new Date().toISOString(),
      monitoringDuration: this.isMonitoring ? Date.now() - this.startTime : 0,

      // Alert summary
      alerts: {
        total: this.alerts.length,
        bySeverity: this.getAlertsBySeverity(),
        recent: this.alerts.slice(-10), // Last 10 alerts
      },

      // Security metrics
      securityMetrics: this.calculateSecurityMetrics(),

      // Performance metrics
      performanceMetrics: this.calculatePerformanceMetrics(),

      // Gas analysis
      gasAnalysis: this.calculateGasAnalysis(),

      // Economic security analysis
      economicAnalysis: this.calculateEconomicAnalysis(),

      // Contract status
      contractStatus: await this.getContractStatus(),

      // Recommendations
      recommendations: this.generateRecommendations(),
    };

    // Save report to file
    const reportPath =
      './test-reports/security-monitoring/security-report.json';
    await fs.mkdir(path.dirname(reportPath), { recursive: true });
    await fs.writeFile(reportPath, JSON.stringify(report, null, 2));

    console.log(`📊 Security report generated: ${reportPath}`);
    return report;
  }

  /**
   * Calculate security metrics for reporting
   */
  calculateSecurityMetrics() {
    const securityEvents = this.metrics.get('securityEvents');
    const now = Date.now();
    const oneHour = 60 * 60 * 1000;

    const recentEvents = securityEvents.filter(
      event => now - event.timestamp < oneHour
    );

    return {
      totalEvents: securityEvents.length,
      recentEvents: recentEvents.length,
      eventsPerHour: recentEvents.length,

      // Event types breakdown
      eventTypes: this.groupBy(securityEvents, 'eventName'),

      // Severity distribution
      severityDistribution: this.groupBy(recentEvents, 'severity'),
    };
  }

  /**
   * Stop monitoring
   */
  async stopMonitoring() {
    this.isMonitoring = false;

    // Remove all listeners
    for (const [, filterConfig] of this.eventFilters.entries()) {
      filterConfig.contract.removeAllListeners();
    }

    // Generate final report
    const report = await this.generateSecurityReport();

    console.log('🛑 Security monitoring stopped');
    this.emit('monitoring_stopped', { timestamp: Date.now(), report });

    return report;
  }

  // Utility methods
  groupBy(array, key) {
    return array.reduce((groups, item) => {
      const value = item[key];
      groups[value] = (groups[value] || []).length + 1;
      return groups;
    }, {});
  }

  getAlertsBySeverity() {
    return this.groupBy(this.alerts, 'severity');
  }
}

function manifestContracts(manifest) {
  if (Array.isArray(manifest.contracts)) return manifest.contracts;
  if (manifest.contracts && typeof manifest.contracts === 'object') {
    return Object.entries(manifest.contracts).map(([name, address]) => ({
      name,
      address,
    }));
  }
  return [];
}

async function rpcCall(rpcUrl, method, params, id) {
  const response = await fetch(rpcUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id, method, params }),
  });
  if (!response.ok) throw new Error(`${method} HTTP ${response.status}`);
  const payload = await response.json();
  if (payload.error) {
    throw new Error(
      `${method} RPC error: ${payload.error.message || payload.error.code}`
    );
  }
  return payload.result;
}

async function writeReleaseMonitoringReport(reportPath, report) {
  await fs.mkdir(path.dirname(reportPath), { recursive: true });
  await fs.writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
}

async function runReleaseMonitoring(options = {}) {
  const manifestPath = path.resolve(
    options.manifestPath ||
      process.env.DEPLOYMENT_MANIFEST ||
      `deployments/${process.env.TESTNET_NETWORK || 'testnet'}/release-manifest.json`
  );
  const reportPath = path.resolve(
    options.reportPath ||
      process.env.MONITORING_REPORT_PATH ||
      'monitoring-reports/release-monitoring.json'
  );
  const rpcUrl = options.rpcUrl || process.env.TESTNET_RPC_URL;
  const report = {
    generatedAt: new Date().toISOString(),
    classification: 'RELEASE_EVIDENCE',
    command: ['web3_clientVersion', 'eth_chainId', 'eth_getCode'],
    tool: 'json-rpc',
    toolVersion: null,
    manifestPath,
    contractCount: 0,
    executedCheckCount: 0,
    exitStatus: 1,
    status: 'VOID',
    checks: [],
  };

  try {
    if (!rpcUrl)
      throw new Error(
        'TESTNET_RPC_URL is required; refusing an implicit local endpoint'
      );
    const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf8'));
    const contracts = manifestContracts(manifest);
    report.contractCount = contracts.length;
    if (contracts.length === 0)
      throw new Error('deployment manifest contains zero contracts');

    report.toolVersion = await rpcCall(rpcUrl, 'web3_clientVersion', [], 1);
    report.executedCheckCount += 1;
    if (!report.toolVersion)
      throw new Error('RPC returned an empty client version');
    const chainIdHex = await rpcCall(rpcUrl, 'eth_chainId', [], 2);
    report.executedCheckCount += 1;
    const observedChainId = Number.parseInt(chainIdHex, 16);
    report.checks.push({
      check: 'chainId',
      expected: manifest.chainId,
      observed: observedChainId,
    });
    if (observedChainId !== Number(manifest.chainId)) {
      throw new Error(
        `manifest chainId ${manifest.chainId} does not match RPC chainId ${observedChainId}`
      );
    }

    for (const [index, contract] of contracts.entries()) {
      if (!/^0x[0-9a-fA-F]{40}$/.test(contract.address || '')) {
        throw new Error(
          `${contract.name || `contract[${index}]`} has an invalid address`
        );
      }
      const code = await rpcCall(
        rpcUrl,
        'eth_getCode',
        [contract.address, 'latest'],
        index + 3
      );
      report.executedCheckCount += 1;
      const passed =
        typeof code === 'string' && code !== '0x' && code !== '0x0';
      report.checks.push({
        check: 'deployedCode',
        contract: contract.name,
        address: contract.address,
        passed,
      });
      if (!passed) throw new Error(`${contract.name} has zero deployed code`);
    }

    report.exitStatus = 0;
    report.status = 'PASS';
    await writeReleaseMonitoringReport(reportPath, report);
    return report;
  } catch (error) {
    report.error = error.message;
    if (report.executedCheckCount > 0) report.status = 'RED';
    await writeReleaseMonitoringReport(reportPath, report);
    throw Object.assign(new Error(error.message), { report });
  }
}

/**
 * Export monitoring functions for testnet deployment
 */
module.exports = {
  TestnetSecurityMonitor,

  /**
   * Initialize monitoring for testnet deployment
   */
  async initializeTestnetMonitoring(config = {}) {
    const monitor = new TestnetSecurityMonitor(config);
    await monitor.initialize();
    return monitor;
  },

  /**
   * Run security validation suite on deployed contracts
   */
  async runSecurityValidation(contracts = [], config = {}) {
    console.log('🔍 Running security validation suite...');

    if (contracts.length === 0) {
      throw new Error('security validation is VOID: zero contracts supplied');
    }

    const results = {
      timestamp: new Date().toISOString(),
      contracts: contracts.length,
      executedCheckCount: 0,
      validationResults: [],
      overallStatus: 'RED',
      criticalIssues: 0,
    };

    for (const contract of contracts) {
      try {
        const address = contract.target || contract.address;
        const runner = contract.runner || config.provider;
        if (!runner || typeof runner.getCode !== 'function') {
          throw new Error('contract runner does not expose getCode');
        }
        const code = await runner.getCode(address);
        results.executedCheckCount += 1;
        if (code === '0x' || code === '0x0')
          throw new Error('zero deployed code');

        const abiEntries = contract.interface?.fragments?.length || 0;
        results.executedCheckCount += 1;
        if (abiEntries === 0) throw new Error('empty contract ABI');

        const contractResult = {
          contractName: contract.contractName,
          address,
          validationTime: Date.now(),
          checks: {
            deployedCode: true,
            abiEntries,
          },
          status: 'PASS',
        };

        results.validationResults.push(contractResult);
      } catch (error) {
        console.error(
          `❌ Validation failed for ${contract.contractName}:`,
          error
        );
        results.validationResults.push({
          contractName: contract.contractName,
          address: contract.address,
          error: error.message,
          status: 'ERROR',
        });
        results.criticalIssues++;
      }
    }

    results.overallStatus = results.criticalIssues > 0 ? 'RED' : 'PASS';
    if (results.criticalIssues > 0) {
      throw Object.assign(
        new Error('one or more contract validation checks failed'),
        {
          results,
        }
      );
    }

    console.log(
      `✅ Security validation completed. Status: ${results.overallStatus}`
    );
    return results;
  },
  runReleaseMonitoring,
};

if (require.main === module) {
  runReleaseMonitoring()
    .then(report => {
      console.log(
        `Release monitoring PASS: ${report.contractCount} contracts, ${report.executedCheckCount} executed checks, ${report.toolVersion}`
      );
    })
    .catch(error => {
      console.error(
        `Release monitoring ${error.report?.status || 'RED'}: ${error.message}`
      );
      process.exitCode = error.report?.exitStatus || 1;
    });
}
