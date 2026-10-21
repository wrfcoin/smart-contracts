'use strict';

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

describe('CarbonCreditRouter — focused coverage', function () {
  async function deployFixture() {
    const [admin, caller, outsider, treasury] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory('MockERC20');
    const tokenA = await MockERC20.deploy('Token A', 'TKA', 18);
    const tokenB = await MockERC20.deploy('Token B', 'TKB', 18);

    const tokenAAddr = await tokenA.getAddress();
    const tokenBAddr = await tokenB.getAddress();
    const [token0, token1] =
      tokenAAddr.toLowerCase() < tokenBAddr.toLowerCase()
        ? [tokenAAddr, tokenBAddr]
        : [tokenBAddr, tokenAAddr];

    const Factory = await ethers.getContractFactory('CarbonCreditAMMFactory');
    const factory = await Factory.deploy();

    const Router = await ethers.getContractFactory('CarbonCreditRouter');
    const router = await Router.deploy(await factory.getAddress(), ethers.ZeroAddress);

    return {
      admin,
      caller,
      outsider,
      treasury,
      token0,
      token1,
      factory,
      router,
      MockERC20,
    };
  }

  it('guards admin-only routing controls', async function () {
    const { router, admin, outsider } = await loadFixture(deployFixture);

    await expect(router.connect(admin).setRoutingFee(20)).to.not.be.reverted;
    // setRoutingFee is onlyRole(ROUTER_ADMIN_ROLE) — CarbonCreditRouter.sol:610.
    // The two calls below gate on DEFAULT_ADMIN_ROLE instead, so pinning the role
    // is what keeps these three assertions from being interchangeable.
    await expect(router.connect(outsider).setRoutingFee(20))
      .to.be.revertedWithCustomError(router, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await router.ROUTER_ADMIN_ROLE());

    await expect(router.connect(admin).setAuthorizedCaller(outsider.address, true)).to.not.be.reverted;
    // onlyRole(DEFAULT_ADMIN_ROLE) — CarbonCreditRouter.sol:618.
    await expect(router.connect(outsider).setAuthorizedCaller(outsider.address, true))
      .to.be.revertedWithCustomError(router, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await router.DEFAULT_ADMIN_ROLE());

    await expect(router.connect(admin).pause()).to.not.be.reverted;
    await expect(router.connect(admin).unpause()).to.not.be.reverted;

    // onlyRole(DEFAULT_ADMIN_ROLE) — CarbonCreditRouter.sol:632. The admin
    // pause/unpause pair above leaves the router UNPAUSED, so whenNotPaused cannot
    // be what rejects this call — the role gate is the only candidate.
    await expect(router.connect(outsider).pause())
      .to.be.revertedWithCustomError(router, 'AccessControlUnauthorizedAccount')
      .withArgs(outsider.address, await router.DEFAULT_ADMIN_ROLE());
    await expect(router.connect(outsider).withdrawFees(ethers.ZeroAddress, outsider.address, 1n))
      .to.be.revertedWithCustomError(router, 'AccessControlUnauthorizedAccount');
  });

  it('enforces routing fee bounds in admin setter', async function () {
    const { router, admin } = await loadFixture(deployFixture);
    await expect(router.connect(admin).setRoutingFee(101)).to.be.revertedWith(
      'CarbonCreditRouter: FEE_TOO_HIGH',
    );
  });

  it('validates swap deadlines before execution', async function () {
    const { router, caller, token0, token1 } = await loadFixture(deployFixture);
    const block = await ethers.provider.getBlock('latest');
    const tooFar = BigInt(block.timestamp) + 2n * 60n * 60n;
    const expired = BigInt(block.timestamp) - 1n;

    await expect(
      router.connect(caller).swapExactTokensForTokens({
        tokenIn: token0,
        tokenOut: token1,
        amountIn: 1n,
        amountOutMin: 1n,
        to: caller.address,
        deadline: expired,
        maxHops: 1n,
      }),
    ).to.be.revertedWith('CarbonCreditRouter: EXPIRED');

    await expect(
      router.connect(caller).swapExactTokensForTokens({
        tokenIn: token0,
        tokenOut: token1,
        amountIn: 1n,
        amountOutMin: 1n,
        to: caller.address,
        deadline: tooFar,
        maxHops: 1n,
      }),
    ).to.be.revertedWith('CarbonCreditRouter: DEADLINE_TOO_FAR');
  });

  it('validates quote path constraints and fee-lane alignment', async function () {
    const { router, token0, token1 } = await loadFixture(deployFixture);

    await expect(router.getAmountsOut(100n, [token0], [30n])).to.be.revertedWith(
      'CarbonCreditRouter: INVALID_PATH',
    );

    await expect(router.getAmountsOut(100n, [token0, token1], [])).to.be.revertedWith(
      'CarbonCreditRouter: INVALID_FEE_TIERS',
    );

    await expect(router.getAmountsIn(50n, [token0], [30n])).to.be.revertedWith(
      'CarbonCreditRouter: INVALID_PATH',
    );
  });

  it('guards liquidity operations against inactive or missing pools', async function () {
    const { admin, caller, token0, token1, factory, router, MockERC20 } = await loadFixture(deployFixture);

    const createTx = await factory.connect(admin).createPool(token0, token1, 30n);
    const pool = await factory.getPool(token0, token1, 30n);
    expect(pool).to.not.equal(ethers.ZeroAddress);

    await factory.connect(admin).setPoolStatus(pool, false);

    await expect(
      router.connect(admin).addLiquidity({
        tokenA: token0,
        tokenB: token1,
        feeTier: 30n,
        amountADesired: 1n,
        amountBDesired: 1n,
        amountAMin: 1n,
        amountBMin: 1n,
        to: caller.address,
        deadline: BigInt((await ethers.provider.getBlock('latest')).timestamp + 120),
      }),
    ).to.be.revertedWith('CarbonCreditRouter: POOL_NOT_ACTIVE');

    await expect(
      router.connect(caller).removeLiquidity(
        token0,
        token1,
        30n,
        1n,
        1n,
        1n,
        caller.address,
        BigInt((await ethers.provider.getBlock('latest')).timestamp + 120),
      ),
    ).to.be.revertedWith('CarbonCreditRouter: POOL_NOT_ACTIVE');

    const poolCreatorRole = await factory.POOL_CREATOR_ROLE();
    await factory.connect(admin).grantRole(poolCreatorRole, await router.getAddress());

    await expect(
      router.connect(caller).addLiquidity({
        tokenA: token0,
        tokenB: token1,
        feeTier: 3000n,
        amountADesired: 1n,
        amountBDesired: 1n,
        amountAMin: 1n,
        amountBMin: 1n,
        to: caller.address,
        deadline: BigInt((await ethers.provider.getBlock('latest')).timestamp + 120),
      }),
    ).to.be.revertedWith('CarbonCreditAMMFactory: INVALID_FEE_TIER');

    // A pair with no pool, at a fee tier that IS registered, so the router's own
    // POOL_NOT_EXISTS guard is reached. removeLiquidity has no auto-create path;
    // addLiquidity does (the router holds POOL_CREATOR_ROLE from above), which
    // is why this uses removeLiquidity.
    const tokenC = await MockERC20.deploy('Token C', 'TKC', 18);
    const tokenD = await MockERC20.deploy('Token D', 'TKD', 18);
    await expect(
      router.connect(caller).removeLiquidity(
        await tokenC.getAddress(),
        await tokenD.getAddress(),
        30n,
        1n,
        1n,
        1n,
        caller.address,
        BigInt((await ethers.provider.getBlock('latest')).timestamp + 120),
      ),
    ).to.be.revertedWith('CarbonCreditRouter: POOL_NOT_EXISTS');
  });
});
