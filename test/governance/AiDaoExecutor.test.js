'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture, time } = require('@nomicfoundation/hardhat-network-helpers');

describe('AiDaoExecutor', function () {
  const DEFAULT_TIMELOCK = 48 * 60 * 60;

  async function deployFixture() {
    const [owner, guardian, oracle, user] = await ethers.getSigners();

    const Voting = await ethers.getContractFactory('MockSecureVotingSystem');
    const voting = await Voting.deploy();

    const EmissionController = await ethers.getContractFactory('MockEmissionController');
    const emissionController = await EmissionController.deploy();

    const Executor = await ethers.getContractFactory('AiDaoExecutor');
    const executor = await Executor.deploy(
      owner.address,
      guardian.address,
      await voting.getAddress(),
      await emissionController.getAddress(),
      DEFAULT_TIMELOCK
    );

    await executor.connect(owner).addAiOracle(oracle.address);

    return { owner, guardian, oracle, user, voting, emissionController, executor };
  }

  async function deployDefaultTimelockFixture() {
    const [owner, guardian] = await ethers.getSigners();
    const Voting = await ethers.getContractFactory('MockSecureVotingSystem');
    const voting = await Voting.deploy();
    const Executor = await ethers.getContractFactory('AiDaoExecutor');
    const executor = await Executor.deploy(
      owner.address,
      guardian.address,
      await voting.getAddress(),
      ethers.ZeroAddress,
      0
    );
    return { owner, guardian, voting, executor };
  }

  function buildParams(votingProposalId, payload = '0x1234') {
    return ethers.AbiCoder.defaultAbiCoder().encode(
      ['uint256', 'bytes'],
      [BigInt(votingProposalId), payload]
    );
  }

  async function submitProposal(executor, oracle, proposalType, params) {
    const tx = await executor.connect(oracle).submitProposal(proposalType, params);
    const receipt = await tx.wait();

    const submitted = receipt.logs
      .map((log) => {
        try {
          return executor.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((event) => event && event.name === 'ProposalSubmitted');

    return submitted.args.proposalId;
  }

  it('oracle can submit; non-oracle reverts', async function () {
    const { oracle, user, executor } = await loadFixture(deployFixture);

    const params = buildParams(1, '0x1122');

    await expect(executor.connect(oracle).submitProposal(0, params)).to.emit(
      executor,
      'ProposalSubmitted'
    );

    await expect(executor.connect(user).submitProposal(0, params)).to.be.revertedWithCustomError(
      executor,
      'AiDaoNotOracle'
    );
  });

  it('cannot execute during timelock', async function () {
    const { oracle, executor } = await loadFixture(deployFixture);

    const proposalId = await submitProposal(executor, oracle, 0, buildParams(1));

    await expect(executor.execute(proposalId)).to.be.revertedWithCustomError(
      executor,
      'AiDaoTimelockActive'
    );
  });

  it('can execute after timelock by anyone', async function () {
    const { oracle, user, emissionController, executor } = await loadFixture(deployFixture);

    const params = buildParams(1, '0xabcd');
    const proposalId = await submitProposal(executor, oracle, 1, params);

    await time.increase(DEFAULT_TIMELOCK + 1);

    await expect(executor.connect(user).execute(proposalId))
      .to.emit(emissionController, 'ProposalParamsApplied')
      .withArgs(1, params)
      .and.to.emit(executor, 'ProposalExecuted')
      .withArgs(proposalId, 1, params);

    expect(await emissionController.lastProposalType()).to.equal(1);
    expect(await emissionController.lastParams()).to.equal(params);
    expect(await emissionController.applyCount()).to.equal(1);
  });

  it('can execute after timelock without a configured emission controller', async function () {
    const { owner, oracle, user, executor } = await loadFixture(deployFixture);

    await expect(executor.connect(owner).setEmissionController(ethers.ZeroAddress))
      .to.emit(executor, 'EmissionControllerUpdated');

    const params = buildParams(1, '0xabcd');
    const proposalId = await submitProposal(executor, oracle, 1, params);

    await time.increase(DEFAULT_TIMELOCK + 1);

    await expect(executor.connect(user).execute(proposalId))
      .to.emit(executor, 'ProposalExecuted')
      .withArgs(proposalId, 1, params);
  });

  it('marks proposals executed when the emission controller rejects the params', async function () {
    const { oracle, emissionController, executor } = await loadFixture(deployFixture);

    const params = buildParams(1, '0xabcd');
    const proposalId = await submitProposal(executor, oracle, 1, params);
    await emissionController.setShouldRevert(true);

    await time.increase(DEFAULT_TIMELOCK + 1);

    await expect(executor.execute(proposalId))
      .to.emit(executor, 'EmissionControllerApplyFailed')
      .withArgs(proposalId, await emissionController.getAddress())
      .and.to.emit(executor, 'ProposalExecuted')
      .withArgs(proposalId, 1, params);

    const proposal = await executor.proposals(proposalId);
    expect(proposal.executed).to.equal(true);
    expect(await emissionController.applyCount()).to.equal(0);
  });

  it('veto during window blocks execution', async function () {
    const { oracle, voting, executor } = await loadFixture(deployFixture);

    const votingProposalId = 101;
    const proposalId = await submitProposal(executor, oracle, 2, buildParams(votingProposalId));

    await voting.setVotes(votingProposalId, 10, 25, 0);

    await expect(executor.veto(proposalId)).to.emit(executor, 'ProposalVetoed');

    await time.increase(DEFAULT_TIMELOCK + 1);

    await expect(executor.execute(proposalId)).to.be.revertedWithCustomError(executor, 'AiDaoVetoed');
  });

  it('cannot veto after window closes', async function () {
    const { oracle, voting, executor } = await loadFixture(deployFixture);

    const votingProposalId = 202;
    const proposalId = await submitProposal(executor, oracle, 0, buildParams(votingProposalId));

    await voting.setVotes(votingProposalId, 5, 15, 0);
    await time.increase(DEFAULT_TIMELOCK + 1);

    await expect(executor.veto(proposalId)).to.be.revertedWithCustomError(
      executor,
      'AiDaoVetoWindowClosed'
    );
  });

  it('emergency pause blocks execution', async function () {
    const { guardian, oracle, executor } = await loadFixture(deployFixture);

    const proposalId = await submitProposal(executor, oracle, 0, buildParams(303));

    await executor.connect(guardian).pause();
    await time.increase(DEFAULT_TIMELOCK + 1);

    await expect(executor.execute(proposalId)).to.be.revertedWithCustomError(executor, 'AiDaoPaused');
  });

  it('veto after timelock reverts with AiDaoVetoWindowClosed', async function () {
    const { oracle, voting, executor } = await loadFixture(deployFixture);

    const votingProposalId = 404;
    const proposalId = await submitProposal(executor, oracle, 1, buildParams(votingProposalId));

    await voting.setVotes(votingProposalId, 3, 9, 0);
    await time.increase(DEFAULT_TIMELOCK + 1);

    await expect(executor.veto(proposalId)).to.be.revertedWithCustomError(
      executor,
      'AiDaoVetoWindowClosed'
    );
  });

  it('uses default timelock when constructor timelock is zero', async function () {
    const { executor } = await loadFixture(deployDefaultTimelockFixture);
    expect(await executor.timelockSeconds()).to.equal(BigInt(DEFAULT_TIMELOCK));
  });

  it('constructor rejects zero addresses', async function () {
    const [owner, guardian] = await ethers.getSigners();
    const Voting = await ethers.getContractFactory('MockSecureVotingSystem');
    const voting = await Voting.deploy();
    const Executor = await ethers.getContractFactory('AiDaoExecutor');

    await expect(
      Executor.deploy(
        ethers.ZeroAddress,
        guardian.address,
        await voting.getAddress(),
        ethers.ZeroAddress,
        DEFAULT_TIMELOCK
      )
    ).to.be.revertedWithCustomError(Executor, 'OwnableInvalidOwner');

    await expect(
      Executor.deploy(
        owner.address,
        ethers.ZeroAddress,
        await voting.getAddress(),
        ethers.ZeroAddress,
        DEFAULT_TIMELOCK
      )
    ).to.be.revertedWithCustomError(Executor, 'AiDaoInvalidAddress');
  });

  it('cannot submit while paused and only guardian can pause/unpause', async function () {
    const { oracle, user, guardian, executor } = await loadFixture(deployFixture);

    await expect(executor.connect(user).pause()).to.be.revertedWithCustomError(
      executor,
      'AiDaoNotGuardian'
    );

    await executor.connect(guardian).pause();

    await expect(
      executor.connect(oracle).submitProposal(0, buildParams(909, '0x99'))
    ).to.be.revertedWithCustomError(executor, 'AiDaoPaused');

    await expect(executor.connect(user).unpause()).to.be.revertedWithCustomError(
      executor,
      'AiDaoNotGuardian'
    );

    await executor.connect(guardian).unpause();
  });

  it('rejects malformed proposal params and missing proposal ids', async function () {
    const { oracle, executor } = await loadFixture(deployFixture);

    await expect(
      executor.connect(oracle).submitProposal(0, '0x1234')
    ).to.be.revertedWithCustomError(executor, 'AiDaoInvalidParams');

    const fakeProposalId = ethers.keccak256(ethers.toUtf8Bytes('missing'));
    await expect(executor.execute(fakeProposalId)).to.be.revertedWithCustomError(
      executor,
      'AiDaoProposalNotFound'
    );
    await expect(executor.veto(fakeProposalId)).to.be.revertedWithCustomError(
      executor,
      'AiDaoProposalNotFound'
    );
  });

  it('rejects veto when majority is not reached', async function () {
    const { oracle, voting, executor } = await loadFixture(deployFixture);

    const votingProposalId = 505;
    const proposalId = await submitProposal(executor, oracle, 0, buildParams(votingProposalId));
    await voting.setVotes(votingProposalId, 50, 50, 0);

    await expect(executor.veto(proposalId)).to.be.revertedWithCustomError(
      executor,
      'AiDaoVetoMajorityNotReached'
    );
  });

  it('rejects execute/veto after execution', async function () {
    const { oracle, executor } = await loadFixture(deployFixture);

    const proposalId = await submitProposal(executor, oracle, 2, buildParams(606));
    await time.increase(DEFAULT_TIMELOCK + 1);
    await executor.execute(proposalId);

    await expect(executor.execute(proposalId)).to.be.revertedWithCustomError(
      executor,
      'AiDaoAlreadyExecuted'
    );
    await expect(executor.veto(proposalId)).to.be.revertedWithCustomError(
      executor,
      'AiDaoAlreadyExecuted'
    );
  });

  it('owner administrative setters update values and validate inputs', async function () {
    const { owner, guardian, oracle, user, voting, emissionController, executor } = await loadFixture(deployFixture);

    await expect(executor.connect(user).addAiOracle(user.address)).to.be.revertedWithCustomError(
      executor,
      'OwnableUnauthorizedAccount'
    );
    await expect(executor.connect(owner).addAiOracle(ethers.ZeroAddress)).to.be.revertedWithCustomError(
      executor,
      'AiDaoInvalidAddress'
    );
    await executor.connect(owner).addAiOracle(user.address);
    expect(await executor.aiOracles(user.address)).to.equal(true);
    await executor.connect(owner).removeAiOracle(user.address);
    expect(await executor.aiOracles(user.address)).to.equal(false);

    await expect(executor.connect(owner).setTimelock(0)).to.be.revertedWithCustomError(
      executor,
      'AiDaoInvalidTimelock'
    );
    await expect(executor.connect(owner).setTimelock(3600))
      .to.emit(executor, 'TimelockUpdated')
      .withArgs(DEFAULT_TIMELOCK, 3600);
    expect(await executor.timelockSeconds()).to.equal(3600n);

    await expect(executor.connect(owner).setGuardian(ethers.ZeroAddress)).to.be.revertedWithCustomError(
      executor,
      'AiDaoInvalidAddress'
    );
    await expect(executor.connect(owner).setGuardian(user.address))
      .to.emit(executor, 'GuardianUpdated')
      .withArgs(guardian.address, user.address);
    expect(await executor.guardian()).to.equal(user.address);

    await expect(
      executor.connect(owner).setSecureVotingSystem(ethers.ZeroAddress)
    ).to.be.revertedWithCustomError(executor, 'AiDaoInvalidAddress');
    await expect(executor.connect(owner).setSecureVotingSystem(await voting.getAddress()))
      .to.emit(executor, 'SecureVotingSystemUpdated')
      .withArgs(await voting.getAddress(), await voting.getAddress());

    await expect(executor.connect(owner).setEmissionController(user.address))
      .to.emit(executor, 'EmissionControllerUpdated')
      .withArgs(await emissionController.getAddress(), user.address);
    expect(await executor.emissionController()).to.equal(user.address);

    await expect(executor.connect(owner).transferOwnership(oracle.address)).to.emit(
      executor,
      'OwnershipTransferStarted'
    );
  });
});
