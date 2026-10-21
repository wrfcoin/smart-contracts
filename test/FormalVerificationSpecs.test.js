'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('FormalVerificationSpecs', function () {
  const OFFENSE_CODE = 'CONS-001';
  const EVIDENCE_PAYLOAD_HASH = ethers.keccak256(
    ethers.toUtf8Bytes('formal-verification-evidence-payload-v1')
  );
  const EVIDENCE_OBSERVED_AT = 1_710_000_100;
  const EVIDENCE_VALID_AFTER = 1_710_000_000;
  const EVIDENCE_EXPIRES_AT = 1_710_086_400;
  const STAKE_AMOUNT = ethers.parseEther('1000');
  const SLASH_AMOUNT = ethers.parseEther('100');
  const LOCK_DURATION = 2 * 24 * 60 * 60;
  const MAX_LOCK_DURATION = 3 * 24 * 60 * 60;
  const EVIDENCE_VERSION = 1;

  async function getLastEventArg(contract, eventName, argName) {
    const filter = contract.filters[eventName]();
    const events = await contract.queryFilter(filter);
    return events[events.length - 1].args[argName];
  }

  async function deployAllFixture() {
    const [owner, slashTarget, appealTarget] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const stakeToken = await MockERC20.deploy('Stake Token', 'STK', 18);

    const SlashingController = await ethers.getContractFactory('SlashingController');
    const slashCtrl = await SlashingController.deploy();

    const ParticipationLock = await ethers.getContractFactory('ParticipationLock');
    const lockCtrl = await ParticipationLock.deploy();

    const EqualLiabilityEnforcer = await ethers.getContractFactory('EqualLiabilityEnforcer');
    const enforcer = await EqualLiabilityEnforcer.deploy();

    const OffenseRegistry = await ethers.getContractFactory('OffenseRegistry');
    const offenseRegistry = await OffenseRegistry.deploy();

    const AppealReversalController = await ethers.getContractFactory(
      'AppealReversalController'
    );
    const appealCtrl = await AppealReversalController.deploy();

    const OffenseEvidenceRegistry = await ethers.getContractFactory(
      'OffenseEvidenceRegistry'
    );
    const evidenceReg = await OffenseEvidenceRegistry.deploy();

    const evidenceBasePacket = {
      evidenceHash: ethers.ZeroHash,
      offenseCode: OFFENSE_CODE,
      evidenceType: 1,
      reporter: owner.address,
      payloadHash: EVIDENCE_PAYLOAD_HASH,
      observedAt: EVIDENCE_OBSERVED_AT,
      validAfter: EVIDENCE_VALID_AFTER,
      expiresAt: EVIDENCE_EXPIRES_AT,
      timestamp: 0,
      reporterSignature: '0x',
      witnesses: [],
      version: EVIDENCE_VERSION,
    };
    const evidenceDigest = await evidenceReg.computeEvidenceHash(
      evidenceBasePacket
    );
    const evidencePacket = {
      ...evidenceBasePacket,
      evidenceHash: evidenceDigest,
      reporterSignature: await owner.signMessage(ethers.getBytes(evidenceDigest)),
      witnesses: [
        {
          witness: slashTarget.address,
          signature: await slashTarget.signMessage(
            ethers.getBytes(evidenceDigest)
          ),
        },
      ],
    };

    const MockERC20Factory = await ethers.getContractFactory('MockERC20');
    const ammTokenA = await MockERC20Factory.deploy('AMM Token A', 'AMMA', 18);
    const ammTokenB = await MockERC20Factory.deploy('AMM Token B', 'AMMB', 18);
    const routerUsdc = await MockERC20Factory.deploy('Router USDC', 'rUSDC', 18);

    const ammTokenAAddr = await ammTokenA.getAddress();
    const ammTokenBAddr = await ammTokenB.getAddress();
    const [ammToken0, ammToken1] =
      ammTokenAAddr.toLowerCase() < ammTokenBAddr.toLowerCase()
        ? [ammTokenA, ammTokenB]
        : [ammTokenB, ammTokenA];
    const ammToken0Addr = await ammToken0.getAddress();
    const ammToken1Addr = await ammToken1.getAddress();

    const CarbonCreditAMM = await ethers.getContractFactory('CarbonCreditAMM');
    const amm = await CarbonCreditAMM.connect(owner).deploy(owner.address);
    await amm.connect(owner).initialize(ammToken0Addr, ammToken1Addr, owner.address, 30);

    const ammLiquidity = ethers.parseEther('10000');
    await ammToken0.mint(owner.address, ammLiquidity);
    await ammToken1.mint(owner.address, ammLiquidity);
    await ammToken0.connect(owner).transfer(await amm.getAddress(), ammLiquidity);
    await ammToken1.connect(owner).transfer(await amm.getAddress(), ammLiquidity);
    await amm.connect(owner).mint(owner.address);

    const LiquidityPoolManager = await ethers.getContractFactory('LiquidityPoolManager');
    const poolManager = await LiquidityPoolManager.deploy(
      await routerUsdc.getAddress(),
      owner.address,
      owner.address
    );

    const CarbonCreditAMMFactory = await ethers.getContractFactory(
      'CarbonCreditAMMFactory'
    );
    const ammFactory = await CarbonCreditAMMFactory.deploy();

    const CarbonPoolRouter = await ethers.getContractFactory('CarbonPoolRouter');
    const router = await CarbonPoolRouter.deploy(
      await poolManager.getAddress(),
      await ammFactory.getAddress(),
      await routerUsdc.getAddress()
    );

    const FormalVerificationSpecs = await ethers.getContractFactory(
      'FormalVerificationSpecs'
    );
    const specs = await FormalVerificationSpecs.deploy();

    await stakeToken.mint(slashTarget.address, STAKE_AMOUNT);
    await stakeToken.mint(appealTarget.address, STAKE_AMOUNT);

    await offenseRegistry[
      'registerOffense(string,uint8,string,uint16,uint16,uint32,uint32)'
    ](
      OFFENSE_CODE,
      1,
      'Consensus double-sign',
      500,
      1500,
      24 * 60 * 60,
      MAX_LOCK_DURATION
    );

    await enforcer.registerSchedule(
      OFFENSE_CODE,
      1,
      SLASH_AMOUNT,
      LOCK_DURATION
    );

    await evidenceReg.submitEvidence({
      ...evidencePacket,
    });

    await slashCtrl.slash(
      slashTarget.address,
      OFFENSE_CODE,
      SLASH_AMOUNT,
      evidenceDigest
    );
    await lockCtrl.lock(slashTarget.address, 'formal verification lock', LOCK_DURATION);

    await slashCtrl.slash(
      appealTarget.address,
      OFFENSE_CODE,
      SLASH_AMOUNT,
      evidenceDigest
    );
    const appealSlashId = await getLastEventArg(slashCtrl, 'Slashed', 'slashId');

    await lockCtrl.lock(appealTarget.address, 'appeal verification lock', LOCK_DURATION);

    const SLASH_ADMIN_ROLE = await slashCtrl.SLASH_ADMIN_ROLE();
    const LOCK_ADMIN_ROLE = await lockCtrl.LOCK_ADMIN_ROLE();
    await slashCtrl.grantRole(SLASH_ADMIN_ROLE, await appealCtrl.getAddress());
    await lockCtrl.grantRole(LOCK_ADMIN_ROLE, await appealCtrl.getAddress());
    await appealCtrl.setAppealControllers(
      await slashCtrl.getAddress(),
      await lockCtrl.getAddress()
    );

    await appealCtrl.connect(appealTarget).fileAppeal(
      appealSlashId,
      'Approved appeal should restore pre-slash state'
    );
    const appealId = await getLastEventArg(appealCtrl, 'AppealFiled', 'appealId');
    await appealCtrl.decideAppeal(appealId, true, SLASH_AMOUNT);

    const context = {
      slashController: await slashCtrl.getAddress(),
      stakeBalanceSource: await stakeToken.getAddress(),
      slashTarget: slashTarget.address,
      appealController: await appealCtrl.getAddress(),
      appealId,
      appealTarget: appealTarget.address,
      lockController: await lockCtrl.getAddress(),
      lockTarget: slashTarget.address,
      maxLockDuration: MAX_LOCK_DURATION,
      enforcer: await enforcer.getAddress(),
      offenseRegistry: await offenseRegistry.getAddress(),
      offenseCode: OFFENSE_CODE,
      stakeAmount: STAKE_AMOUNT,
      evidenceRegistry: await evidenceReg.getAddress(),
      evidenceHash: evidenceDigest,
      expectedPreSlashTotal: 0,
      expectedLockedAfterAppeal: false,
      amm: await amm.getAddress(),
      ammSmallAmountIn: ethers.parseEther('1'),
      ammLargeAmountIn: ethers.parseEther('5'),
      router: await router.getAddress(),
      routerTokenIn: ammToken0Addr,
      routerTokenOut: ammToken1Addr,
      routerAmountIn: ethers.parseEther('1'),
    };

    return {
      specs,
      stakeToken,
      slashCtrl,
      lockCtrl,
      enforcer,
      offenseRegistry,
      appealCtrl,
      evidenceReg,
      owner,
      slashTarget,
      appealTarget,
      appealId,
      context,
      amm,
      router,
    };
  }

  describe('Core invariants', function () {
    it('confirms cumulative slashed amount never exceeds the tracked stake', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);

      const passed = await specs.verifySlashingInvariant_totalWithinStake(
        context.slashController,
        context.stakeBalanceSource,
        context.slashTarget
      );

      expect(passed).to.equal(true);
    });

    it('confirms approved appeals restore the expected slash and lock state', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);

      const passed = await specs.verifyAppealInvariant_reversalRestoresState(
        context.appealController,
        context.slashController,
        context.lockController,
        context.appealId,
        context.appealTarget,
        context.expectedPreSlashTotal,
        context.expectedLockedAfterAppeal
      );

      expect(passed).to.equal(true);
    });

    it('confirms equal-liability schedules sit inside the offense registry range', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);

      const passed = await specs.verifyParityInvariant_actorNeutral(
        context.enforcer,
        context.offenseRegistry,
        context.offenseCode,
        context.stakeAmount
      );

      expect(passed).to.equal(true);
    });

    it('confirms lock duration is bounded by the configured maximum', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);

      const passed = await specs.verifyLockInvariant_durationBound(
        context.lockController,
        context.lockTarget,
        context.maxLockDuration
      );

      expect(passed).to.equal(true);
    });

    it('confirms evidence records keep the retrieval hash immutable', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);

      const passed = await specs.verifyEvidenceInvariant_immutableHash(
        context.evidenceRegistry,
        context.evidenceHash
      );

      expect(passed).to.equal(true);
    });

    it('confirms larger AMM inputs never quote less output than smaller ones', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);

      const passed = await specs.verifyAmmInvariant_monotonicQuote(
        context.amm,
        context.ammSmallAmountIn,
        context.ammLargeAmountIn
      );

      expect(passed).to.equal(true);
    });

    it('confirms an empty router returns an empty route', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);

      const passed = await specs.verifyRouterInvariant_emptyRoute(
        context.router,
        context.routerTokenIn,
        context.routerTokenOut,
        context.routerAmountIn
      );

      expect(passed).to.equal(true);
    });
  });

  describe('Verification suite', function () {
    it('runs the full suite and stores one result per invariant', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);

      await expect(specs.runVerificationSuite(context))
        .to.emit(specs, 'VerificationSuiteCompleted')
        .withArgs(7, 7, 0);

      const results = await specs.getAllResults();
      expect(results.length).to.equal(7);
      expect(results.every((result) => result.passed)).to.equal(true);
    });

    it('returns the stored result for a named invariant', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);
      await specs.runVerificationSuite(context);

      const result = await specs.getVerificationResult('appeal_reversalRestoresState');
      expect(result.invariantName).to.equal('appeal_reversalRestoresState');
      expect(result.passed).to.equal(true);
      expect(result.verifiedAt).to.be.gt(0n);
    });
  });

  describe('Counterexamples', function () {
    it('fails the slashing invariant when stake is lower than cumulative slash', async function () {
      const { specs, stakeToken, context, slashTarget } = await loadFixture(deployAllFixture);

      await stakeToken.burn(slashTarget.address, STAKE_AMOUNT - ethers.parseEther('50'));

      const passed = await specs.verifySlashingInvariant_totalWithinStake(
        context.slashController,
        context.stakeBalanceSource,
        context.slashTarget
      );

      expect(passed).to.equal(false);
    });

    it('fails the parity invariant when the supplied stake makes the schedule exceed the registry range', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);

      const passed = await specs.verifyParityInvariant_actorNeutral(
        context.enforcer,
        context.offenseRegistry,
        context.offenseCode,
        ethers.parseEther('200')
      );

      expect(passed).to.equal(false);
    });

    it('fails the lock invariant when the caller supplies a bound smaller than the stored duration', async function () {
      const { specs, context } = await loadFixture(deployAllFixture);

      const passed = await specs.verifyLockInvariant_durationBound(
        context.lockController,
        context.lockTarget,
        24 * 60 * 60
      );

      expect(passed).to.equal(false);
    });
  });
});
