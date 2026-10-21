/**
 * Wrfcoin Smart Contract Usage Examples
 * Real-world examples showing how contracts integrate with your ecosystem
 */

const fetch = require('node-fetch');

class WrfcoinContractExamples {
  constructor(baseUrl = 'http://localhost:5004') {
    this.baseUrl = baseUrl;
  }

  /**
   * Example 1: Environmental Sensor Data Submission
   * Shows how IoT sensors submit pollution data and earn rewards
   */
  async exampleSensorDataSubmission() {
    console.log('🌍 Example 1: Environmental Sensor Data Submission');

    // Real sensor readings from environmental monitoring
    const sensorData = {
      sensorAddress: '0x742d35Cc6aF3...',
      location: 'Los Angeles, CA',
      readings: {
        co2Level: 415, // Current atmospheric CO2 (ppm)
        pm25Level: 35, // PM2.5 pollution level (µg/m³)
        pm10Level: 45, // PM10 pollution level (µg/m³)
        ozoneLevel: 120, // Ozone level (µg/m³)
        no2Level: 40, // NO2 level (µg/m³)
        so2Level: 15, // SO2 level (µg/m³)
        temperature: 2250, // 22.5°C * 100
        humidity: 6500, // 65% * 100
      },
    };

    try {
      const response = await fetch(
        `${this.baseUrl}/api/contracts/pollution/submit`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(sensorData),
        }
      );

      const result = await response.json();

      if (result.success) {
        console.log(`✅ Sensor data submitted successfully!`);
        console.log(`   Reward earned: ${result.reward} WRF tokens`);
        console.log(`   Transaction: ${result.transactionHash}`);
      }

      return result;
    } catch (error) {
      console.error('❌ Failed to submit sensor data:', error.message);
    }
  }

  /**
   * Example 2: Research Peer Review Process
   * Shows academic workflow for environmental research validation
   */
  async examplePeerReviewWorkflow() {
    console.log('\n🔬 Example 2: Research Peer Review Process');

    // Submit research for peer review
    const researchSubmission = {
      title: 'Urban Air Quality Impact on Climate Models',
      abstractHash: 'QmYjtig7VJQ6XsnUjqqJvj7QaMcCAwtrgNdahSiFofrE7o',
      datasetHash: 'QmNLei78zWmzUdbeRB3CiUfAizWUrbeeZh5K1rhAQKCh51',
      category: 'AIR_QUALITY',
    };

    try {
      // Submit research
      const submitResponse = await fetch(
        `${this.baseUrl}/api/contracts/peer-review/research/submit`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(researchSubmission),
        }
      );

      const submitResult = await submitResponse.json();
      console.log(`✅ Research submitted for peer review`);
      console.log(`   Submission ID: ${submitResult.submissionHash}`);

      // Simulate peer review submission
      const reviewData = {
        submissionHash: submitResult.submissionHash,
        decision: 'APPROVE',
        qualityScore: 85,
        feedbackHash: 'QmPK1s3pNYLi9ERiq3BDxKa4XosgWwFRQUydHUtz4YgpqB',
      };

      const reviewResponse = await fetch(
        `${this.baseUrl}/api/contracts/peer-review/review/submit`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(reviewData),
        }
      );

      const reviewResult = await reviewResponse.json();
      console.log(`✅ Peer review completed`);
      console.log(`   Reviewer reward: ${reviewResult.reward} WRF tokens`);

      return { submitResult, reviewResult };
    } catch (error) {
      console.error('❌ Failed in peer review process:', error.message);
    }
  }

  /**
   * Example 3: Carbon Credit Trading
   * Shows environmental project registration and carbon credit marketplace
   */
  async exampleCarbonCreditTrading() {
    console.log('\n🌱 Example 3: Carbon Credit Trading');

    // Register environmental project
    const projectData = {
      projectId: 'SOLAR-CA-2024-001',
      name: 'Renewable Solar Farm Initiative',
      description: 'Large-scale solar installation reducing grid dependence',
      location: 'Mojave Desert, California',
      projectType: 'SOLAR',
      expectedReduction: 50000, // 500 tons CO2 * 100
      startDate: Math.floor(Date.now() / 1000),
      endDate: Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60, // 1 year
    };

    try {
      const response = await fetch(
        `${this.baseUrl}/api/contracts/carbon/project/register`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(projectData),
        }
      );

      const result = await response.json();
      console.log(`✅ Environmental project registered`);
      console.log(`   Project ID: ${result.projectId}`);
      console.log(`   Expected CO2 reduction: 500 tons`);

      return result;
    } catch (error) {
      console.error('❌ Failed to register carbon project:', error.message);
    }
  }

  /**
   * Example 4: Grant Distribution Workflow
   * Shows funding allocation for environmental research
   */
  async exampleGrantDistribution() {
    console.log('\n💰 Example 4: Grant Distribution Workflow');

    const proposalData = {
      title: 'Machine Learning for Climate Prediction Enhancement',
      abstractHash: 'QmUNLLsPACCz1vLxQVkXqqLX5R1X9bFfTmiTN5dTq6eudT',
      requestedAmount: '25000000000000000000000', // 25,000 WRF tokens
      category: 'CLIMATE_RESEARCH',
    };

    try {
      const response = await fetch(
        `${this.baseUrl}/api/contracts/grants/proposal/submit`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(proposalData),
        }
      );

      const result = await response.json();
      console.log(`✅ Grant proposal submitted`);
      console.log(`   Proposal ID: ${result.proposalId}`);
      console.log(`   Requested amount: 25,000 WRF tokens`);
      console.log(
        `   Voting deadline: ${new Date(result.votingDeadline * 1000).toLocaleDateString()}`
      );

      return result;
    } catch (error) {
      console.error('❌ Failed to submit grant proposal:', error.message);
    }
  }

  /**
   * Example 5: AI Model Training Contribution
   * Shows compute network integration for weather model development
   */
  async exampleModelTrainingContribution() {
    console.log('\n🤖 Example 5: AI Model Training Contribution');

    // First, get available compute networks
    try {
      const networksResponse = await fetch(
        `${this.baseUrl}/api/contracts/training/networks`
      );
      const networksData = await networksResponse.json();

      console.log('Available compute networks:');
      networksData.networks.forEach(network => {
        console.log(
          `   • ${network.name}: ${network.computePower} (${network.costPerHour})`
        );
      });

      // Submit training contribution using Flux network
      const contributionData = {
        jobId: 1,
        computeProvided: 1250, // 12.5 TFLOPS * 100
        trainingTime: 7200, // 2 hours in seconds
        resultHash: 'QmWATWQ7fVPP2EFGu71UkfnqhYXDYH6FEt2QoFbTZCBL44',
        networkType: 'FLUX',
      };

      const response = await fetch(
        `${this.baseUrl}/api/contracts/training/contribution/submit`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(contributionData),
        }
      );

      const result = await response.json();
      console.log(`✅ Training contribution submitted`);
      console.log(`   Contribution ID: ${result.contributionId}`);
      console.log(`   Compute provided: 12.5 TFLOPS`);
      console.log(`   Estimated reward: ${result.estimatedReward} WRF tokens`);

      return result;
    } catch (error) {
      console.error(
        '❌ Failed to submit training contribution:',
        error.message
      );
    }
  }

  /**
   * Example 6: Integration with Your Existing Systems
   * Shows how contracts connect to your compute networks server
   */
  async exampleSystemIntegration() {
    console.log('\n🔗 Example 6: System Integration');

    try {
      // Check your existing compute networks
      const computeResponse = await fetch(
        'http://localhost:5002/api/compute/networks'
      );
      const computeData = await computeResponse.json();

      console.log('Integration with Wrfcoin Compute Networks:');
      Object.entries(computeData.networks).forEach(([key, network]) => {
        console.log(`   • ${network.name}: ${network.status}`);
        if (network.features) {
          network.features.forEach(feature => {
            console.log(`     - ${feature}`);
          });
        }
      });

      // Check contract integration health
      const healthResponse = await fetch(`${this.baseUrl}/health`);
      const healthData = await healthResponse.json();

      console.log('\nContract Integration Status:');
      console.log(`   Service: ${healthData.service}`);
      console.log(`   Status: ${healthData.status}`);
      console.log(`   Contracts loaded: ${healthData.contracts.length}`);

      return { computeData, healthData };
    } catch (error) {
      console.error('❌ System integration check failed:', error.message);
    }
  }

  /**
   * Run all examples
   */
  async runAllExamples() {
    console.log('🚀 Starting Wrfcoin Smart Contract Examples');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    await this.exampleSensorDataSubmission();
    await this.examplePeerReviewWorkflow();
    await this.exampleCarbonCreditTrading();
    await this.exampleGrantDistribution();
    await this.exampleModelTrainingContribution();
    await this.exampleSystemIntegration();

    console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('🎉 All examples completed!');
    console.log(
      '\nThese examples show how your smart contracts integrate with:'
    );
    console.log('• Environmental IoT sensor networks');
    console.log('• Scientific peer review systems');
    console.log('• Carbon offset marketplaces');
    console.log('• Research funding platforms');
    console.log('• Distributed AI training networks');
    console.log('• Your existing Wrfcoin compute infrastructure');
  }
}

// Run examples if called directly
if (require.main === module) {
  const examples = new WrfcoinContractExamples();
  examples.runAllExamples().catch(console.error);
}

module.exports = WrfcoinContractExamples;
