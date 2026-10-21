const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("PaperclipCircuitBreaker", function () {
  async function deploy() {
    const [dao, oracle, human, agent, outsider] = await ethers.getSigners();
    const Breaker = await ethers.getContractFactory("PaperclipCircuitBreaker");
    const breaker = await Breaker.deploy(dao.address, oracle.address, human.address);
    await breaker.configurePolicy(agent.address, 100, 50);
    return { breaker, dao, oracle, human, agent, outsider };
  }

  it("pauses key access when trusted oracle spend crosses the 24-hour cap", async function () {
    const { breaker, oracle, agent } = await deploy();
    await breaker.connect(oracle).reportUsage(agent.address, 60, 1);
    await breaker.connect(oracle).reportUsage(agent.address, 41, 1);
    expect(await breaker.paused(agent.address)).to.equal(true);
    expect(await breaker.keyAccessAllowed(agent.address)).to.equal(false);
  });

  it("pauses key access when trusted oracle reports workflow fan-out above the cap", async function () {
    const { breaker, oracle, agent } = await deploy();
    await breaker.connect(oracle).reportUsage(agent.address, 1, 51);
    expect(await breaker.paused(agent.address)).to.equal(true);
  });

  it("mutation: remove usage-oracle guard lets an outsider pause an agent and must revert", async function () {
    const { breaker, outsider, agent } = await deploy();
    await expect(breaker.connect(outsider).reportUsage(agent.address, 101, 1)).to.be.revertedWithCustomError(breaker, 'AccessControlUnauthorizedAccount').withArgs(outsider.address, await breaker.USAGE_ORACLE_ROLE());
  });

  it("mutation: omit manual-human approval guard lets an oracle resume a paused agent and must revert", async function () {
    const { breaker, oracle, agent } = await deploy();
    await breaker.connect(oracle).reportUsage(agent.address, 101, 1);
    await expect(breaker.connect(oracle).approveResumption(agent.address)).to.be.revertedWithCustomError(breaker, 'AccessControlUnauthorizedAccount').withArgs(oracle.address, await breaker.HUMAN_APPROVER_ROLE());
  });

  it("uses a rolling 24-hour spend window across boundary-overlap intervals", async function () {
    const { breaker, oracle, agent } = await deploy();
    const latest = await ethers.provider.getBlock("latest");
    const baseTimestamp = Number(latest.timestamp) + 100;

    await ethers.provider.send("evm_setNextBlockTimestamp", [baseTimestamp]);
    await ethers.provider.send("evm_mine");
    await breaker.connect(oracle).reportUsage(agent.address, 1, 1);

    await ethers.provider.send("evm_increaseTime", [86399]);
    await ethers.provider.send("evm_mine");
    await breaker.connect(oracle).reportUsage(agent.address, 99, 1);
    expect(await breaker.paused(agent.address)).to.equal(false);

    await ethers.provider.send("evm_increaseTime", [1]);
    await ethers.provider.send("evm_mine");
    await breaker.connect(oracle).reportUsage(agent.address, 100, 1);
    expect(await breaker.paused(agent.address)).to.equal(true);
  });

  it("keeps bucket state in sync when resuming a paused agent", async function () {
    const { breaker, oracle, human, agent } = await deploy();
    await breaker.connect(oracle).reportUsage(agent.address, 101, 1);
    expect(await breaker.paused(agent.address)).to.equal(true);

    await breaker.connect(human).approveResumption(agent.address);
    await ethers.provider.send("evm_increaseTime", [3600]);
    await ethers.provider.send("evm_mine");
    await breaker.connect(oracle).reportUsage(agent.address, 100, 1);

    await ethers.provider.send("evm_increaseTime", [82800]);
    await ethers.provider.send("evm_mine");
    await breaker.connect(oracle).reportUsage(agent.address, 1, 1);
    expect(await breaker.paused(agent.address)).to.equal(true);
  });

  it("requires explicit human approval before key access resumes", async function () {
    const { breaker, oracle, human, agent } = await deploy();
    await breaker.connect(oracle).reportUsage(agent.address, 101, 1);
    await breaker.connect(human).approveResumption(agent.address);
    expect(await breaker.keyAccessAllowed(agent.address)).to.equal(true);
  });
});
