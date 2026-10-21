/**
 * Smart Contract Integration Server
 * Connects Wrfcoin smart contracts with existing compute networks and data systems
 */

const express = require('express');
const cors = require('cors');
const { ethers } = require('ethers');

class ContractIntegrationServer {
  constructor(config) {
    this.app = express();
    this.config = config;
    this.contracts = {};
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);

    this.setupMiddleware();
    this.setupRoutes();
  }

  setupMiddleware() {
    this.app.use(cors());
    this.app.use(express.json());

    // Request logging
    this.app.use((req, res, next) => {
      console.log(`[${new Date().toISOString()}] ${req.method} ${req.path}`);
      next();
    });
  }

  setupRoutes() {
    // Health check
    this.app.get('/health', (req, res) => {
      res.json({
        status: 'healthy',
        service: 'contract-integration',
        contracts: Object.keys(this.contracts),
        timestamp: new Date().toISOString(),
      });
    });

    // Pollution Data Oracle Integration
    this.setupPollutionDataRoutes();

    // Peer Review Integration
    this.setupPeerReviewRoutes();

    // Carbon Credit Integration
    this.setupCarbonCreditRoutes();

    // Grant Distribution Integration
    this.setupGrantRoutes();

    // Model Training Integration
    this.setupModelTrainingRoutes();
  }

  setupPollutionDataRoutes() {
    // Submit sensor data from IoT networks
    this.app.post('/api/contracts/pollution/submit', async (req, res) => {
      try {
        const { sensorAddress, location, readings } = req.body;

        // Validate sensor data
        if (!this.validateSensorData(readings)) {
          return res.status(400).json({ error: 'Invalid sensor data' });
        }

        // Submit to smart contract
        const result = await this.submitPollutionData(
          sensorAddress,
          location,
          readings
        );

        res.json({
          success: true,
          transactionHash: result.hash,
          dataHash: result.dataHash,
          reward: result.reward,
        });
      } catch (error) {
        res.status(500).json({ error: error.message });
      }
    });

    // Get pollution data for location
    this.app.get(
      '/api/contracts/pollution/location/:location',
      async (req, res) => {
        try {
          const { location } = req.params;
          const { timeWindow = 86400 } = req.query; // Default 24 hours

          const data = await this.getPollutionData(location, timeWindow);

          res.json({
            success: true,
            location,
            data,
            aggregated: this.aggregatePollutionData(data),
          });
        } catch (error) {
          res.status(500).json({ error: error.message });
        }
      }
    );

    // Register IoT sensor device
    this.app.post(
      '/api/contracts/pollution/sensor/register',
      async (req, res) => {
        try {
          const { deviceId, manufacturer, model, location, calibrationDate } =
            req.body;

          const result = await this.registerSensor(
            deviceId,
            manufacturer,
            model,
            location,
            calibrationDate
          );

          res.json({
            success: true,
            sensorAddress: result.address,
            registrationHash: result.hash,
          });
        } catch (error) {
          res.status(500).json({ error: error.message });
        }
      }
    );
  }

  setupPeerReviewRoutes() {
    // Submit research for peer review
    this.app.post(
      '/api/contracts/peer-review/research/submit',
      async (req, res) => {
        try {
          const { title, abstractHash, datasetHash, category } = req.body;

          // Upload abstract and dataset to IPFS if needed
          const ipfsHashes = await this.uploadToIPFS({
            abstractHash,
            datasetHash,
          });

          const result = await this.submitResearch(
            title,
            ipfsHashes.abstractHash,
            ipfsHashes.datasetHash,
            category
          );

          res.json({
            success: true,
            submissionHash: result.submissionHash,
            transactionHash: result.hash,
            reviewDeadline: result.deadline,
          });
        } catch (error) {
          res.status(500).json({ error: error.message });
        }
      }
    );

    // Submit peer review
    this.app.post(
      '/api/contracts/peer-review/review/submit',
      async (req, res) => {
        try {
          const { submissionHash, decision, qualityScore, feedbackHash } =
            req.body;

          const result = await this.submitReview(
            submissionHash,
            decision,
            qualityScore,
            feedbackHash
          );

          res.json({
            success: true,
            reviewHash: result.hash,
            reward: result.reward,
          });
        } catch (error) {
          res.status(500).json({ error: error.message });
        }
      }
    );
  }

  setupCarbonCreditRoutes() {
    // Register environmental project
    this.app.post(
      '/api/contracts/carbon/project/register',
      async (req, res) => {
        try {
          const {
            projectId,
            name,
            description,
            location,
            projectType,
            expectedReduction,
            startDate,
            endDate,
          } = req.body;

          const result = await this.registerCarbonProject(
            projectId,
            name,
            description,
            location,
            projectType,
            expectedReduction,
            startDate,
            endDate
          );

          res.json({
            success: true,
            projectId,
            transactionHash: result.hash,
          });
        } catch (error) {
          res.status(500).json({ error: error.message });
        }
      }
    );

    // Purchase carbon credit
    this.app.post(
      '/api/contracts/carbon/credits/purchase/:creditId',
      async (req, res) => {
        try {
          const { creditId } = req.params;
          const { purpose } = req.body;

          const result = await this.purchaseCarbonCredit(creditId, purpose);

          res.json({
            success: true,
            creditId,
            transactionHash: result.hash,
            co2Offset: result.co2Offset,
          });
        } catch (error) {
          res.status(500).json({ error: error.message });
        }
      }
    );
  }

  setupGrantRoutes() {
    // Submit grant proposal
    this.app.post('/api/contracts/grants/proposal/submit', async (req, res) => {
      try {
        const { title, abstractHash, requestedAmount, category } = req.body;

        const result = await this.submitGrantProposal(
          title,
          abstractHash,
          requestedAmount,
          category
        );

        res.json({
          success: true,
          proposalId: result.proposalId,
          transactionHash: result.hash,
          votingDeadline: result.deadline,
        });
      } catch (error) {
        res.status(500).json({ error: error.message });
      }
    });

    // Submit milestone completion
    this.app.post(
      '/api/contracts/grants/milestone/submit',
      async (req, res) => {
        try {
          const { grantId, milestoneId, deliverableHash } = req.body;

          const result = await this.submitMilestone(
            grantId,
            milestoneId,
            deliverableHash
          );

          res.json({
            success: true,
            grantId,
            milestoneId,
            transactionHash: result.hash,
          });
        } catch (error) {
          res.status(500).json({ error: error.message });
        }
      }
    );
  }

  setupModelTrainingRoutes() {
    // Create training job
    this.app.post('/api/contracts/training/job/create', async (req, res) => {
      try {
        const {
          modelType,
          datasetHash,
          computeRequirement,
          deadline,
          maxParticipants,
          reward,
        } = req.body;

        const result = await this.createTrainingJob(
          modelType,
          datasetHash,
          computeRequirement,
          deadline,
          maxParticipants,
          reward
        );

        res.json({
          success: true,
          jobId: result.jobId,
          transactionHash: result.hash,
        });
      } catch (error) {
        res.status(500).json({ error: error.message });
      }
    });

    // Submit training contribution
    this.app.post(
      '/api/contracts/training/contribution/submit',
      async (req, res) => {
        try {
          const {
            jobId,
            computeProvided,
            trainingTime,
            resultHash,
            networkType,
          } = req.body;

          // Validate compute network integration
          const isValidNetwork = await this.validateComputeNetwork(networkType);
          if (!isValidNetwork) {
            return res
              .status(400)
              .json({ error: 'Invalid or unavailable compute network' });
          }

          const result = await this.submitTrainingContribution(
            jobId,
            computeProvided,
            trainingTime,
            resultHash,
            networkType
          );

          res.json({
            success: true,
            contributionId: result.contributionId,
            transactionHash: result.hash,
            estimatedReward: result.estimatedReward,
          });
        } catch (error) {
          res.status(500).json({ error: error.message });
        }
      }
    );

    // Get available compute networks
    this.app.get('/api/contracts/training/networks', async (req, res) => {
      try {
        const networks = await this.getAvailableComputeNetworks();

        res.json({
          success: true,
          networks,
        });
      } catch (error) {
        res.status(500).json({ error: error.message });
      }
    });
  }

  // Integration helper methods
  async validateSensorData(readings) {
    // Validate sensor readings format and ranges
    const requiredFields = [
      'co2Level',
      'pm25Level',
      'pm10Level',
      'temperature',
      'humidity',
    ];

    for (const field of requiredFields) {
      if (typeof readings[field] !== 'number' || readings[field] < 0) {
        return false;
      }
    }

    // Check realistic ranges
    if (
      readings.co2Level > 50000 ||
      readings.temperature < -10000 ||
      readings.temperature > 6000
    ) {
      return false;
    }

    return true;
  }

  async validateComputeNetwork(networkType) {
    // Check if compute network is available via your existing servers
    const networks = [
      'FLUX',
      'AKASH',
      'GOLEM',
      'RENDER',
      'IEXEC',
      'ICP',
      'AIOZ',
    ];
    return networks.includes(networkType.toUpperCase());
  }

  async getAvailableComputeNetworks() {
    // Integration with your existing compute networks server
    try {
      const response = await fetch(
        'http://localhost:5002/api/compute/networks'
      );
      const data = await response.json();

      return Object.keys(data.networks).map(key => ({
        name: key,
        type: data.networks[key].type,
        available: data.networks[key].status === 'active',
        computePower: data.networks[key].compute_power,
        costPerHour: data.networks[key].cost_per_hour,
      }));
    } catch (error) {
      console.error('Failed to fetch compute networks:', error);
      return [];
    }
  }

  async uploadToIPFS(data) {
    throw new Error('IPFS upload is not configured; no hash was created');
  }

  aggregatePollutionData(data) {
    if (!data || data.length === 0) return null;

    const aggregated = {
      averageCO2: 0,
      averagePM25: 0,
      averagePM10: 0,
      averageTemp: 0,
      dataPoints: data.length,
      timeRange: {
        start: Math.min(...data.map(d => d.timestamp)),
        end: Math.max(...data.map(d => d.timestamp)),
      },
    };

    data.forEach(reading => {
      aggregated.averageCO2 += reading.co2Level;
      aggregated.averagePM25 += reading.pm25Level;
      aggregated.averagePM10 += reading.pm10Level;
      aggregated.averageTemp += reading.temperature;
    });

    const count = data.length;
    aggregated.averageCO2 /= count;
    aggregated.averagePM25 /= count;
    aggregated.averagePM10 /= count;
    aggregated.averageTemp /= count;

    return aggregated;
  }

  // Smart contract interaction methods
  async submitPollutionData(sensorAddress, location, readings) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  async getPollutionData(location, timeWindow) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  async registerSensor(
    deviceId,
    manufacturer,
    model,
    location,
    calibrationDate
  ) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  async submitResearch(title, abstractHash, datasetHash, category) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  async submitReview(submissionHash, decision, qualityScore, feedbackHash) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  async registerCarbonProject(
    projectId,
    name,
    description,
    location,
    projectType,
    expectedReduction,
    startDate,
    endDate
  ) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  async purchaseCarbonCredit(creditId, purpose) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  async submitGrantProposal(title, abstractHash, requestedAmount, category) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  async submitMilestone(grantId, milestoneId, deliverableHash) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  async createTrainingJob(
    modelType,
    datasetHash,
    computeRequirement,
    deadline,
    maxParticipants,
    reward
  ) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  async submitTrainingContribution(
    jobId,
    computeProvided,
    trainingTime,
    resultHash,
    networkType
  ) {
    throw new Error('Contract integration is not configured; no transaction or result was created');
  }

  start(port = 5004) {
    this.app.listen(port, '0.0.0.0', () => {
      console.log(`🚀 Contract Integration Server running on port ${port}`);
      console.log(`✅ Health check: http://localhost:${port}/health`);
      console.log(`📡 Integration endpoints:`);
      console.log(
        `   • Pollution Data: http://localhost:${port}/api/contracts/pollution/`
      );
      console.log(
        `   • Peer Review: http://localhost:${port}/api/contracts/peer-review/`
      );
      console.log(
        `   • Carbon Credits: http://localhost:${port}/api/contracts/carbon/`
      );
      console.log(
        `   • Grants: http://localhost:${port}/api/contracts/grants/`
      );
      console.log(
        `   • Training: http://localhost:${port}/api/contracts/training/`
      );
    });
  }
}

// Configuration
const config = {
  rpcUrl: process.env.WRFCOIN_RPC_URL || 'http://localhost:8545',
  chainId: process.env.WRFCOIN_CHAIN_ID || 2024,
  contractAddresses: {
    PollutionDataOracle: process.env.POLLUTION_CONTRACT_ADDRESS,
    PeerReviewIncentives: process.env.PEER_REVIEW_CONTRACT_ADDRESS,
    CarbonCreditTrading: process.env.CARBON_CONTRACT_ADDRESS,
    GrantDistribution: process.env.GRANT_CONTRACT_ADDRESS,
    ModelTrainingRewards: process.env.TRAINING_CONTRACT_ADDRESS,
  },
};

// Start server if called directly
if (require.main === module) {
  const server = new ContractIntegrationServer(config);
  server.start(5004);
}

module.exports = { ContractIntegrationServer, config };
