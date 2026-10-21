/**
 * @title StakeDelegation Usage Examples
 * @dev Comprehensive examples showing how to use the StakeDelegation contract
 * for WRFCoin's fair launch advocate/recruiter system
 */

const { ethers } = require('hardhat');
const { expect } = require('chai');

/**
 * StakeDelegation Usage Examples
 * Demonstrates the complete workflow from advocate registration to recruit independence
 */
class StakeDelegationExamples {
  constructor() {
    this.stakeDelegation = null;
    this.multiAssetStaking = null;
    this.wrfToken = null;
    this.advocate = null;
    this.recruit = null;
  }

  async initialize() {
    // Get contract instances (assuming deployed)
    this.stakeDelegation = await ethers.getContractAt(
      'StakeDelegation',
      STAKE_DELEGATION_ADDRESS
    );
    this.multiAssetStaking = await ethers.getContractAt(
      'MultiAssetStaking',
      MULTI_ASSET_STAKING_ADDRESS
    );
    this.wrfToken = await ethers.getContractAt('WRFToken', WRF_TOKEN_ADDRESS);

    // Get signers
    const signers = await ethers.getSigners();
    this.advocate = signers[0];
    this.recruit = signers[1];

    console.log('StakeDelegation Examples Initialized');
    console.log('Advocate:', this.advocate.address);
    console.log('Recruit:', this.recruit.address);
  }

  /**
   * Example 1: Advocate Creates Referral Link
   * Shows how an experienced participant creates a referral link for recruiting
   */
  async example1_CreateReferralLink() {
    console.log('\n=== Example 1: Creating Referral Link ===');

    try {
      // Define referral parameters
      const referralCode = 'WRFCOIN1'; // 8-character code
      const stakeAmount = ethers.parseEther('1000'); // 1000 WRF tokens
      const stakeAsset = this.wrfToken.target; // WRF token address
      const maxUsage = 5; // Can be used 5 times

      // Ensure advocate has sufficient balance
      const advocateBalance = await this.wrfToken.balanceOf(
        this.advocate.address
      );
      console.log(
        `Advocate balance: ${ethers.formatEther(advocateBalance)} WRF`
      );

      if (advocateBalance < stakeAmount) {
        // Mint tokens for example (assuming minting capability)
        await this.wrfToken.mint(this.advocate.address, stakeAmount * 2n);
        console.log('Minted tokens for advocate');
      }

      // Approve tokens for staking
      await this.wrfToken
        .connect(this.advocate)
        .approve(this.stakeDelegation.target, stakeAmount);
      console.log('Approved tokens for stake delegation');

      // Create referral link
      const tx = await this.stakeDelegation
        .connect(this.advocate)
        .createReferralLink(referralCode, stakeAmount, stakeAsset, maxUsage);

      const receipt = await tx.wait();
      const event = receipt.logs.find(
        log => log.fragment && log.fragment.name === 'ReferralLinkCreated'
      );

      if (event) {
        console.log('✅ Referral Link Created:');
        console.log(`  Code: ${event.args.referralCode}`);
        console.log(
          `  Stake: ${ethers.formatEther(event.args.stakeAmount)} WRF`
        );
        console.log(
          `  Expires: ${new Date(Number(event.args.expiresAt) * 1000).toISOString()}`
        );
      }

      // Get referral link details
      const linkDetails =
        await this.stakeDelegation.getReferralLink(referralCode);
      console.log('📋 Link Details:');
      console.log(`  Advocate: ${linkDetails.advocate}`);
      console.log(`  Max Usage: ${linkDetails.maxUsage}`);
      console.log(`  Usage Count: ${linkDetails.usageCount}`);
      console.log(`  Active: ${linkDetails.isActive}`);

      return { referralCode, linkHash: linkDetails.linkHash };
    } catch (error) {
      console.error('❌ Failed to create referral link:', error.message);
      throw error;
    }
  }

  /**
   * Example 2: Recruit Uses Referral Link
   * Shows how a newcomer uses a referral link to join with delegated stake
   */
  async example2_UseReferralLink(referralCode) {
    console.log('\n=== Example 2: Using Referral Link ===');

    try {
      // Get referral link details
      const linkDetails =
        await this.stakeDelegation.getReferralLink(referralCode);
      console.log(`📋 Using referral code: ${referralCode}`);
      console.log(`  Advocate: ${linkDetails.advocate}`);
      console.log(
        `  Stake Amount: ${ethers.formatEther(linkDetails.stakeAmount)} WRF`
      );

      // Create EIP-712 signature from advocate
      const domain = {
        name: 'WRFCoin StakeDelegation',
        version: '1',
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: this.stakeDelegation.target,
      };

      const types = {
        ReferralLink: [
          { name: 'advocate', type: 'address' },
          { name: 'referralCode', type: 'string' },
          { name: 'nonce', type: 'uint256' },
          { name: 'deadline', type: 'uint256' },
          { name: 'stakeAmount', type: 'uint256' },
          { name: 'stakeAsset', type: 'address' },
        ],
      };

      const nonce = await this.stakeDelegation.nonces(linkDetails.advocate);
      const value = {
        advocate: linkDetails.advocate,
        referralCode: referralCode,
        nonce: nonce,
        deadline: linkDetails.expiresAt,
        stakeAmount: linkDetails.stakeAmount,
        stakeAsset: linkDetails.stakeAsset,
      };

      // Sign with advocate's private key
      const signature = await this.advocate.signTypedData(domain, types, value);
      console.log('✏️  EIP-712 signature created');

      // Use referral link as recruit
      const tx = await this.stakeDelegation
        .connect(this.recruit)
        .useReferralLink(referralCode, signature);

      const receipt = await tx.wait();
      const delegationEvent = receipt.logs.find(
        log => log.fragment && log.fragment.name === 'DelegationCreated'
      );

      if (delegationEvent) {
        console.log('✅ Delegation Created:');
        console.log(`  ID: ${delegationEvent.args.delegationId}`);
        console.log(`  Advocate: ${delegationEvent.args.advocate}`);
        console.log(`  Recruit: ${delegationEvent.args.recruit}`);
        console.log(
          `  Stake: ${ethers.formatEther(delegationEvent.args.stakeAmount)} WRF`
        );

        return delegationEvent.args.delegationId;
      }

      throw new Error('Delegation event not found');
    } catch (error) {
      console.error('❌ Failed to use referral link:', error.message);
      throw error;
    }
  }

  /**
   * Example 3: Process Recruit Earnings
   * Shows how recruit earnings are automatically allocated between parties
   */
  async example3_ProcessEarnings(delegationId) {
    console.log('\n=== Example 3: Processing Recruit Earnings ===');

    try {
      // Get delegation details
      const delegation = await this.stakeDelegation.getDelegation(delegationId);
      console.log('📋 Processing earnings for delegation:');
      console.log(`  ID: ${delegationId}`);
      console.log(`  Recruit: ${delegation.recruit}`);
      console.log(
        `  Stake Amount: ${ethers.formatEther(delegation.stakeAmount)} WRF`
      );
      console.log(
        `  Already Repaid: ${ethers.formatEther(delegation.stakeRepaid)} WRF`
      );

      // Simulate recruit earning 500 WRF tokens
      const recruitEarnings = ethers.parseEther('500');

      // Ensure earnings distributor role (usually set to earnings processing contract)
      const EARNINGS_DISTRIBUTOR_ROLE =
        await this.stakeDelegation.EARNINGS_DISTRIBUTOR_ROLE();
      const hasRole = await this.stakeDelegation.hasRole(
        EARNINGS_DISTRIBUTOR_ROLE,
        this.advocate.address
      );

      if (!hasRole) {
        await this.stakeDelegation.grantRole(
          EARNINGS_DISTRIBUTOR_ROLE,
          this.advocate.address
        );
        console.log('🔐 Granted EARNINGS_DISTRIBUTOR_ROLE for example');
      }

      // Mint earnings to the contract for distribution
      await this.wrfToken.mint(this.stakeDelegation.target, recruitEarnings);

      // Get balances before processing
      const recruitBalanceBefore = await this.wrfToken.balanceOf(
        delegation.recruit
      );
      const advocateBalanceBefore = await this.wrfToken.balanceOf(
        delegation.advocate
      );

      console.log('💰 Balances before earnings processing:');
      console.log(`  Recruit: ${ethers.formatEther(recruitBalanceBefore)} WRF`);
      console.log(
        `  Advocate: ${ethers.formatEther(advocateBalanceBefore)} WRF`
      );

      // Process earnings
      const tx = await this.stakeDelegation
        .connect(this.advocate)
        .processRecruitEarnings(delegation.recruit, recruitEarnings);

      const receipt = await tx.wait();
      const earningsEvent = receipt.logs.find(
        log => log.fragment && log.fragment.name === 'EarningsProcessed'
      );

      if (earningsEvent) {
        console.log('✅ Earnings Processed:');
        console.log(
          `  Total Earnings: ${ethers.formatEther(earningsEvent.args.totalEarnings)} WRF`
        );
        console.log(
          `  Stake Repayment: ${ethers.formatEther(earningsEvent.args.stakeRepaymentAmount)} WRF`
        );
        console.log(
          `  Advocate Bonus: ${ethers.formatEther(earningsEvent.args.advocateBonusAmount)} WRF`
        );
        console.log(
          `  Protocol Fee: ${ethers.formatEther(earningsEvent.args.protocolFeeAmount)} WRF`
        );
        console.log(
          `  Recruit Keeps: ${ethers.formatEther(earningsEvent.args.recruitKeepsAmount)} WRF`
        );
      }

      // Get balances after processing
      const recruitBalanceAfter = await this.wrfToken.balanceOf(
        delegation.recruit
      );
      const advocateBalanceAfter = await this.wrfToken.balanceOf(
        delegation.advocate
      );

      console.log('💰 Balances after earnings processing:');
      console.log(
        `  Recruit: ${ethers.formatEther(recruitBalanceAfter)} WRF (+${ethers.formatEther(recruitBalanceAfter - recruitBalanceBefore)})`
      );
      console.log(
        `  Advocate: ${ethers.formatEther(advocateBalanceAfter)} WRF (+${ethers.formatEther(advocateBalanceAfter - advocateBalanceBefore)})`
      );

      // Check if stake is fully repaid
      const updatedDelegation =
        await this.stakeDelegation.getDelegation(delegationId);
      console.log(
        `📊 Stake Progress: ${ethers.formatEther(updatedDelegation.stakeRepaid)}/${ethers.formatEther(updatedDelegation.stakeAmount)} WRF`
      );
    } catch (error) {
      console.error('❌ Failed to process earnings:', error.message);
      throw error;
    }
  }

  /**
   * Example 4: Achieve Independence
   * Shows what happens when a recruit fully repays their stake
   */
  async example4_AchieveIndependence(delegationId) {
    console.log('\n=== Example 4: Achieving Independence ===');

    try {
      let delegation = await this.stakeDelegation.getDelegation(delegationId);
      console.log('📋 Current delegation status:');
      console.log(`  Status: ${delegation.status}`);
      console.log(
        `  Repaid: ${ethers.formatEther(delegation.stakeRepaid)} WRF`
      );
      console.log(
        `  Required: ${ethers.formatEther(delegation.stakeAmount)} WRF`
      );

      // Process additional earnings to complete stake repayment
      const remainingStake = delegation.stakeAmount - delegation.stakeRepaid;
      const earningsNeeded = (remainingStake * 10000n) / 3000n; // Divide by 30% repayment rate

      console.log(
        `💡 Processing ${ethers.formatEther(earningsNeeded)} WRF in earnings to achieve independence`
      );

      // Mint earnings to the contract
      await this.wrfToken.mint(this.stakeDelegation.target, earningsNeeded);

      // Process earnings
      const tx = await this.stakeDelegation
        .connect(this.advocate)
        .processRecruitEarnings(delegation.recruit, earningsNeeded);

      const receipt = await tx.wait();

      // Look for independence event
      const independenceEvent = receipt.logs.find(
        log => log.fragment && log.fragment.name === 'IndependenceAchieved'
      );

      if (independenceEvent) {
        console.log('🎉 Independence Achieved!');
        console.log(`  Recruit: ${independenceEvent.args.recruit}`);
        console.log(
          `  Total Repaid: ${ethers.formatEther(independenceEvent.args.totalRepaid)} WRF`
        );
        console.log(
          `  Time to Independence: ${Math.floor(Number(independenceEvent.args.timeToIndependence) / 86400)} days`
        );
      }

      // Check updated delegation status
      delegation = await this.stakeDelegation.getDelegation(delegationId);
      console.log('📋 Final delegation status:');
      console.log(
        `  Status: ${delegation.status} (0=ACTIVE, 1=COMPLETED, 2=DEFAULTED, 3=TERMINATED)`
      );
      console.log(
        `  Independence Time: ${new Date(Number(delegation.independenceTime) * 1000).toISOString()}`
      );

      // Check advocate reputation update
      const advocateProfile = await this.stakeDelegation.getAdvocateProfile(
        delegation.advocate
      );
      console.log('👤 Updated advocate profile:');
      console.log(`  Active Delegations: ${advocateProfile.activeDelegations}`);
      console.log(
        `  Successful Delegations: ${advocateProfile.successfulDelegations}`
      );
      console.log(
        `  Reputation Score: ${advocateProfile.reputationScore}/10000`
      );
      console.log(
        `  Reputation Tier: ${advocateProfile.reputationTier} (0=NOVICE, 1=EXPERIENCED, 2=EXPERT, 3=MASTER)`
      );
    } catch (error) {
      console.error('❌ Failed to achieve independence:', error.message);
      throw error;
    }
  }

  /**
   * Example 5: Platform Statistics
   * Shows how to get comprehensive platform metrics
   */
  async example5_PlatformStatistics() {
    console.log('\n=== Example 5: Platform Statistics ===');

    try {
      const stats = await this.stakeDelegation.getPlatformStats();

      console.log('📊 WRFCoin StakeDelegation Platform Stats:');
      console.log(`  Total Delegations Created: ${stats.totalDelegations}`);
      console.log(`  Active Delegations: ${stats.activeDelegations}`);
      console.log(
        `  Total Stake Delegated: ${ethers.formatEther(stats.totalStaked)} WRF`
      );
      console.log(
        `  Total Advocate Rewards: ${ethers.formatEther(stats.totalAdvocateRewardsDistributed)} WRF`
      );
      console.log(
        `  Total Protocol Fees: ${ethers.formatEther(stats.totalProtocolFees)} WRF`
      );
      console.log(`  Active Advocates: ${stats.activeAdvocateCount}`);

      // Calculate platform efficiency metrics
      if (stats.totalDelegations > 0) {
        const successRate =
          ((stats.totalDelegations - stats.activeDelegations) /
            stats.totalDelegations) *
          100;
        console.log(`  Platform Success Rate: ${successRate.toFixed(2)}%`);
      }

      if (stats.totalStaked > 0) {
        const rewardEfficiency = Number(
          (stats.totalAdvocateRewardsDistributed * 100n) / stats.totalStaked
        );
        console.log(
          `  Reward Efficiency: ${rewardEfficiency.toFixed(2)}% of stake distributed as rewards`
        );
      }
    } catch (error) {
      console.error('❌ Failed to get platform statistics:', error.message);
      throw error;
    }
  }

  /**
   * Example 6: Advanced Advocate Management
   * Shows advocate profile management and reputation system
   */
  async example6_AdvocateManagement() {
    console.log('\n=== Example 6: Advocate Management ===');

    try {
      const advocateAddress = this.advocate.address;

      // Get detailed advocate profile
      const profile =
        await this.stakeDelegation.getAdvocateProfile(advocateAddress);
      console.log('👤 Detailed Advocate Profile:');
      console.log(`  Address: ${profile.advocate}`);
      console.log(
        `  Joined: ${new Date(Number(profile.joinedAt) * 1000).toISOString()}`
      );
      console.log(`  Total Delegations: ${profile.totalDelegations}`);
      console.log(`  Active: ${profile.activeDelegations}`);
      console.log(`  Successful: ${profile.successfulDelegations}`);
      console.log(`  Defaulted: ${profile.defaultedDelegations}`);
      console.log(
        `  Total Rewards Earned: ${ethers.formatEther(profile.totalRewardsEarned)} WRF`
      );
      console.log(
        `  Total Stake Provided: ${ethers.formatEther(profile.totalStakeProvided)} WRF`
      );
      console.log(
        `  Total Stake Recovered: ${ethers.formatEther(profile.totalStakeRecovered)} WRF`
      );
      console.log(`  Max Delegations Allowed: ${profile.maxDelegations}`);
      console.log(`  Current Reputation: ${profile.reputationScore}/10000`);
      console.log(
        `  Reputation Tier: ${['NOVICE', 'EXPERIENCED', 'EXPERT', 'MASTER'][profile.reputationTier]}`
      );

      // Get advocate's delegation IDs
      const delegationIds =
        await this.stakeDelegation.getAdvocateDelegationIds(advocateAddress);
      console.log(`📋 Advocate's Delegations (${delegationIds.length}):`);

      for (let i = 0; i < Math.min(delegationIds.length, 5); i++) {
        const delegation = await this.stakeDelegation.getDelegation(
          delegationIds[i]
        );
        const statusNames = ['ACTIVE', 'COMPLETED', 'DEFAULTED', 'TERMINATED'];
        console.log(
          `  ${i + 1}. ${delegationIds[i].slice(0, 10)}... - ${statusNames[delegation.status]} (${ethers.formatEther(delegation.stakeAmount)} WRF)`
        );
      }

      if (delegationIds.length > 5) {
        console.log(`  ... and ${delegationIds.length - 5} more`);
      }

      // Calculate performance metrics
      if (profile.totalDelegations > 0) {
        const successRate =
          (Number(profile.successfulDelegations) /
            Number(profile.totalDelegations)) *
          100;
        const defaultRate =
          (Number(profile.defaultedDelegations) /
            Number(profile.totalDelegations)) *
          100;

        console.log('📈 Performance Metrics:');
        console.log(`  Success Rate: ${successRate.toFixed(2)}%`);
        console.log(`  Default Rate: ${defaultRate.toFixed(2)}%`);

        if (profile.totalStakeProvided > 0) {
          const roi = Number(
            (profile.totalRewardsEarned * 100n) / profile.totalStakeProvided
          );
          console.log(`  ROI on Stakes: ${roi.toFixed(2)}%`);
        }
      }
    } catch (error) {
      console.error(
        '❌ Failed to get advocate management info:',
        error.message
      );
      throw error;
    }
  }

  /**
   * Run all examples in sequence
   */
  async runAllExamples() {
    console.log('🚀 Running WRFCoin StakeDelegation Examples');
    console.log('==========================================');

    try {
      await this.initialize();

      // Example 1: Create referral link
      const { referralCode } = await this.example1_CreateReferralLink();

      // Example 2: Use referral link
      const delegationId = await this.example2_UseReferralLink(referralCode);

      // Example 3: Process earnings
      await this.example3_ProcessEarnings(delegationId);

      // Example 4: Achieve independence
      await this.example4_AchieveIndependence(delegationId);

      // Example 5: Platform statistics
      await this.example5_PlatformStatistics();

      // Example 6: Advocate management
      await this.example6_AdvocateManagement();

      console.log('\n✅ All examples completed successfully!');
      console.log(
        '🎉 WRFCoin StakeDelegation system is ready for production use!'
      );
    } catch (error) {
      console.error('\n❌ Examples failed:', error.message);
      console.error('Stack trace:', error.stack);
    }
  }
}

// Configuration (replace with actual deployed contract addresses)
const STAKE_DELEGATION_ADDRESS = '0x1234567890123456789012345678901234567890';
const MULTI_ASSET_STAKING_ADDRESS =
  '0x1234567890123456789012345678901234567890';
const WRF_TOKEN_ADDRESS = '0x1234567890123456789012345678901234567890';

// Export for use in other scripts
module.exports = {
  StakeDelegationExamples,
  STAKE_DELEGATION_ADDRESS,
  MULTI_ASSET_STAKING_ADDRESS,
  WRF_TOKEN_ADDRESS,
};

// Run examples if called directly
if (require.main === module) {
  async function main() {
    const examples = new StakeDelegationExamples();
    await examples.runAllExamples();
  }

  main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
}
