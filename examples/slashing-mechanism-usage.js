const { ethers } = require('hardhat');

/**
 * SlashingMechanism Usage Examples
 * Demonstrates key functionality of the fraud detection and penalty system
 */

async function slashingMechanismExamples() {
  console.log('🔒 SlashingMechanism Usage Examples');
  console.log('=====================================\n');

  // Get signers
  const [
    owner,
    validator1,
    validator2,
    validator3,
    participant1,
    participant2,
    committee1,
  ] = await ethers.getSigners();

  // Replace with actual deployed contract address
  const SLASHING_MECHANISM_ADDRESS =
    process.env.SLASHING_MECHANISM_ADDRESS || '0x...';

  if (SLASHING_MECHANISM_ADDRESS === '0x...') {
    console.log(
      '❌ Please set SLASHING_MECHANISM_ADDRESS environment variable'
    );
    return;
  }

  const slashingMechanism = await ethers.getContractAt(
    'SlashingMechanism',
    SLASHING_MECHANISM_ADDRESS
  );

  console.log('📋 Contract Info:');
  console.log(`Contract Address: ${SLASHING_MECHANISM_ADDRESS}`);
  console.log(`Next Slashing ID: ${await slashingMechanism.nextSlashingId()}`);
  console.log(
    `Min Validators Required: ${await slashingMechanism.minValidatorsRequired()}`
  );
  console.log(
    `Execution Delay: ${await slashingMechanism.executionDelay()} seconds`
  );
  console.log(
    `Appeal Window: ${await slashingMechanism.appealWindow()} seconds\n`
  );

  try {
    // ================================================================
    // Example 1: Evidence Submission
    // ================================================================
    console.log('📸 Example 1: Evidence Submission');
    console.log('----------------------------------');

    const evidenceData =
      'Participant submitted false temperature readings for Station ID 12345 on 2024-03-15. Weather data shows 25°C but actual temperature was 15°C based on neighboring stations.';
    const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes(evidenceData));
    const ipfsHash = 'QmX7KjQ2vW8RzPqM9N6tFpGhBsEg4CyJwLmV3nX8KjQ2vW8'; // Example IPFS hash

    console.log(`Evidence Hash: ${evidenceHash}`);
    console.log(`IPFS Hash: ${ipfsHash}`);

    // Submit evidence (requires VALIDATOR_ROLE)
    console.log('Submitting evidence...');
    const evidenceTx = await slashingMechanism
      .connect(validator1)
      .submitEvidence(evidenceHash, ipfsHash);
    await evidenceTx.wait();

    console.log('✅ Evidence submitted successfully');

    // Verify evidence was stored
    const isVerified = await slashingMechanism.verifyEvidence(evidenceHash);
    console.log(`Evidence verified: ${isVerified}\n`);

    // ================================================================
    // Example 2: Slashing Proposal
    // ================================================================
    console.log('⚖️ Example 2: Slashing Proposal');
    console.log('--------------------------------');

    const violationDescription =
      'Data manipulation detected: Participant consistently submitted weather data that deviates significantly from neighboring stations and satellite data. This pattern suggests systematic falsification of meteorological readings.';

    console.log(`Target Participant: ${participant1.address}`);
    console.log(`Violation: DATA_MANIPULATION (MAJOR severity)`);
    console.log(`Description: ${violationDescription.substring(0, 100)}...`);

    // Propose slashing
    const proposalTx = await slashingMechanism
      .connect(validator1)
      .proposeSlashing(
        participant1.address,
        0, // SlashingReason.DATA_MANIPULATION
        1, // ViolationSeverity.MAJOR (50% slash)
        evidenceHash,
        violationDescription
      );
    const proposalReceipt = await proposalTx.wait();

    // Get slashing ID from event
    const slashingProposedEvent = proposalReceipt.logs.find(
      log => log.fragment && log.fragment.name === 'SlashingProposed'
    );
    const slashingId = slashingProposedEvent.args[0];

    console.log(`✅ Slashing proposal created with ID: ${slashingId}`);

    // Get slashing details
    const slashingDetails =
      await slashingMechanism.getSlashingEvent(slashingId);
    console.log(
      `Proposed slash amount: ${ethers.formatEther(slashingDetails.slashedAmount)} ETH`
    );
    console.log(
      `Current status: ${['PENDING', 'CONFIRMED', 'APPEALED', 'OVERTURNED', 'EXECUTED', 'EXPIRED'][slashingDetails.status]}`
    );
    console.log(`Approval count: ${slashingDetails.approvalCount}/3\n`);

    // ================================================================
    // Example 3: Multi-Validator Approval
    // ================================================================
    console.log('👥 Example 3: Multi-Validator Approval');
    console.log('---------------------------------------');

    // Second validator validates
    console.log('Validator 2 approving...');
    const approval2Tx = await slashingMechanism
      .connect(validator2)
      .validateSlashing(slashingId);
    await approval2Tx.wait();

    // Third validator validates (should confirm)
    console.log('Validator 3 approving...');
    const approval3Tx = await slashingMechanism
      .connect(validator3)
      .validateSlashing(slashingId);
    await approval3Tx.wait();

    // Check updated status
    const updatedDetails = await slashingMechanism.getSlashingEvent(slashingId);
    console.log(
      `✅ Slashing confirmed with ${updatedDetails.approvalCount} approvals`
    );
    console.log(
      `New status: ${['PENDING', 'CONFIRMED', 'APPEALED', 'OVERTURNED', 'EXECUTED', 'EXPIRED'][updatedDetails.status]}`
    );
    console.log(
      `Execution scheduled for: ${new Date(Number(updatedDetails.executionTime) * 1000).toLocaleString()}\n`
    );

    // ================================================================
    // Example 4: Appeals Process
    // ================================================================
    console.log('📢 Example 4: Appeals Process');
    console.log('------------------------------');

    // Prepare defense evidence
    const defenseData =
      'Defense evidence: Weather station was undergoing calibration during reported period. Calibration log shows sensor readings were within acceptable range for maintenance mode.';
    const defenseHash = ethers.keccak256(ethers.toUtf8Bytes(defenseData));
    const defenseIpfsHash = 'QmDefense123...';

    // Submit defense evidence
    console.log('Submitting defense evidence...');
    await slashingMechanism
      .connect(validator2)
      .submitEvidence(defenseHash, defenseIpfsHash);

    // Participant appeals the slashing
    console.log('Participant submitting appeal...');
    const appealTx = await slashingMechanism
      .connect(participant1)
      .appealSlashing(
        slashingId,
        defenseHash,
        'I am appealing this slashing decision. The data discrepancies occurred during scheduled maintenance when my weather station was in calibration mode. The defense evidence shows this was a legitimate technical procedure, not data manipulation.'
      );
    const appealReceipt = await appealTx.wait();

    // Get appeal ID from event
    const appealEvent = appealReceipt.logs.find(
      log => log.fragment && log.fragment.name === 'AppealSubmitted'
    );
    const appealId = appealEvent.args[0];

    console.log(`✅ Appeal submitted with ID: ${appealId}`);

    // Check appeal details
    const appealDetails = await slashingMechanism.getAppealCase(appealId);
    console.log(
      `Appeal reason: ${appealDetails.appealReason.substring(0, 100)}...`
    );
    console.log(
      `Voting deadline: ${new Date(Number(appealDetails.votingDeadline) * 1000).toLocaleString()}\n`
    );

    // ================================================================
    // Example 5: Committee Voting on Appeal
    // ================================================================
    console.log('🗳️ Example 5: Committee Voting on Appeal');
    console.log('------------------------------------------');

    // Committee members vote on appeal
    console.log('Committee member voting to support appeal...');
    await slashingMechanism.connect(committee1).voteOnAppeal(appealId, true); // Support

    console.log('Owner voting against appeal...');
    await slashingMechanism.connect(owner).voteOnAppeal(appealId, false); // Oppose

    // Check current vote tally
    const voteStatus = await slashingMechanism.getAppealCase(appealId);
    console.log(
      `Current votes - Support: ${voteStatus.supportVotes}, Oppose: ${voteStatus.opposeVotes}`
    );

    // Note: In real scenario, would wait for voting period to end before resolving
    console.log(
      'Note: In production, wait for full voting period before resolving appeal\n'
    );

    // ================================================================
    // Example 6: Participant Record Tracking
    // ================================================================
    console.log('📊 Example 6: Participant Record Tracking');
    console.log('------------------------------------------');

    const participantRecord = await slashingMechanism.getParticipantRecord(
      participant1.address
    );
    console.log(`Participant: ${participant1.address}`);
    console.log(`Violation count: ${participantRecord.violationCount}`);
    console.log(
      `Total slashed: ${ethers.formatEther(participantRecord.totalSlashed)} ETH`
    );
    console.log(`Is banned: ${participantRecord.isBanned}`);
    console.log(`Requires refill: ${participantRecord.requiresRefill}`);
    console.log(`Layaway multiplier: ${participantRecord.layawayMultiplier}x`);

    if (participantRecord.graceDeadline > 0) {
      console.log(
        `Grace deadline: ${new Date(Number(participantRecord.graceDeadline) * 1000).toLocaleString()}`
      );
    }

    // Check eligibility
    const [eligible, reason] = await slashingMechanism.checkEligibility(
      participant1.address
    );
    console.log(
      `Current eligibility: ${eligible ? '✅ Eligible' : `❌ Not eligible - ${reason}`}\n`
    );

    // ================================================================
    // Example 7: Emergency Slashing
    // ================================================================
    console.log('🚨 Example 7: Emergency Slashing (Admin Only)');
    console.log('-----------------------------------------------');

    const emergencyAmount = ethers.parseEther('50'); // 50 ETH emergency slash
    const emergencyReason =
      'Critical security violation: Participant found to be running coordinated attack against network consensus mechanism.';

    console.log(
      `Emergency slashing ${ethers.formatEther(emergencyAmount)} ETH from ${participant2.address}`
    );
    console.log(`Reason: ${emergencyReason.substring(0, 100)}...`);

    try {
      const emergencyTx = await slashingMechanism
        .connect(owner)
        .emergencySlashing(
          participant2.address,
          emergencyAmount,
          emergencyReason
        );
      await emergencyTx.wait();

      console.log('✅ Emergency slashing executed');

      // Check participant record after emergency slashing
      const emergencyRecord = await slashingMechanism.getParticipantRecord(
        participant2.address
      );
      console.log(`Participant now banned: ${emergencyRecord.isBanned}`);
      console.log(
        `Ban expiry: ${new Date(Number(emergencyRecord.banExpiry) * 1000).toLocaleString()}`
      );
    } catch (error) {
      console.log(
        `❌ Emergency slashing failed (may need EMERGENCY_ROLE): ${error.message}`
      );
    }

    console.log();

    // ================================================================
    // Example 8: Monitoring Functions
    // ================================================================
    console.log('📈 Example 8: Monitoring Functions');
    console.log('-----------------------------------');

    // Get pending slashings for a validator
    const pendingSlashings = await slashingMechanism.getPendingSlashings(
      validator2.address
    );
    console.log(
      `Pending slashings for validator 2: ${pendingSlashings.length}`
    );

    if (pendingSlashings.length > 0) {
      console.log(`Pending slashing IDs: ${pendingSlashings.join(', ')}`);
    }

    // Monitor configuration
    console.log('\n🔧 Current Configuration:');
    console.log(
      `Min validators required: ${await slashingMechanism.minValidatorsRequired()}`
    );
    console.log(
      `Execution delay: ${await slashingMechanism.executionDelay()} seconds`
    );
    console.log(
      `Appeal window: ${await slashingMechanism.appealWindow()} seconds`
    );
    console.log(
      `Grace period: ${await slashingMechanism.gracePeriod()} seconds`
    );
    console.log(
      `Treasury allocation: ${await slashingMechanism.treasuryAllocationBPS()} basis points`
    );
    console.log(
      `Burn allocation: ${await slashingMechanism.burnAllocationBPS()} basis points`
    );

    console.log('\n✅ All examples completed successfully!');
  } catch (error) {
    console.error('❌ Error during example execution:', error.message);

    if (error.reason) {
      console.error('Reason:', error.reason);
    }

    // Common error handling
    if (error.message.includes('Not a validator')) {
      console.error('💡 Make sure the signer has VALIDATOR_ROLE');
    } else if (error.message.includes('Evidence not verified')) {
      console.error('💡 Submit evidence first before proposing slashing');
    } else if (error.message.includes('Already validated')) {
      console.error('💡 This validator already approved this slashing');
    }
  }

  console.log('\n🎓 Usage Tips:');
  console.log('- Always submit evidence before proposing slashing');
  console.log('- Require multiple validators for slashing confirmation');
  console.log('- Monitor appeal deadlines and voting periods');
  console.log('- Track participant records for violation patterns');
  console.log('- Use emergency slashing only for critical situations');
  console.log(
    '- Regularly monitor pending slashings and resolve them promptly'
  );
}

// Event monitoring example
async function monitorSlashingEvents(contractAddress) {
  console.log('\n📡 Event Monitoring Example');
  console.log('============================');

  const slashingMechanism = await ethers.getContractAt(
    'SlashingMechanism',
    contractAddress
  );

  console.log('Setting up event listeners...');

  // Listen for slashing proposals
  slashingMechanism.on(
    'SlashingProposed',
    (slashingId, participant, reason, severity, amount, evidenceHash) => {
      console.log(`\n🚨 SLASHING PROPOSED:`);
      console.log(`   ID: ${slashingId}`);
      console.log(`   Participant: ${participant}`);
      console.log(`   Reason: ${reason}`);
      console.log(`   Severity: ${severity}`);
      console.log(`   Amount: ${ethers.formatEther(amount)} ETH`);
      console.log(`   Evidence: ${evidenceHash}`);
    }
  );

  // Listen for appeals
  slashingMechanism.on(
    'AppealSubmitted',
    (appealId, slashingId, appellant, evidenceHash) => {
      console.log(`\n📢 APPEAL SUBMITTED:`);
      console.log(`   Appeal ID: ${appealId}`);
      console.log(`   Slashing ID: ${slashingId}`);
      console.log(`   Appellant: ${appellant}`);
      console.log(`   Defense Evidence: ${evidenceHash}`);
    }
  );

  // Listen for slashing executions
  slashingMechanism.on(
    'SlashingExecuted',
    (slashingId, participant, amount, treasuryAmount, burnAmount) => {
      console.log(`\n⚡ SLASHING EXECUTED:`);
      console.log(`   ID: ${slashingId}`);
      console.log(`   Participant: ${participant}`);
      console.log(`   Total Slashed: ${ethers.formatEther(amount)} ETH`);
      console.log(`   To Treasury: ${ethers.formatEther(treasuryAmount)} ETH`);
      console.log(`   Burned: ${ethers.formatEther(burnAmount)} ETH`);
    }
  );

  console.log('✅ Event listeners active. Monitoring for slashing events...');
  console.log('Press Ctrl+C to stop monitoring');
}

// Run examples if called directly
if (require.main === module) {
  slashingMechanismExamples()
    .then(() => {
      console.log('\n🏁 Examples completed!');

      // Optionally start event monitoring
      const contractAddress = process.env.SLASHING_MECHANISM_ADDRESS;
      if (contractAddress && contractAddress !== '0x...') {
        return monitorSlashingEvents(contractAddress);
      }
    })
    .catch(error => {
      console.error('❌ Fatal error:', error);
      process.exit(1);
    });
}

module.exports = {
  slashingMechanismExamples,
  monitorSlashingEvents,
};
