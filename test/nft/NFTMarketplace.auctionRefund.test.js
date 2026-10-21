const { expect } = require('chai');
const { ethers } = require('hardhat');
const { time, loadFixture } = require('@nomicfoundation/hardhat-network-helpers');

// =============================================================================
// NFTMarketplace — ERC20 auction refunds & settlement ledger (#173)
//
// Bug: ERC20 auction refunds credited the NATIVE `pendingWithdrawals` ledger
// (withdrawn as ETH) instead of `tokenWithdrawals[user][token]`, and
// `_processPurchase` credited native + re-pulled `transferFrom` on the ERC20
// auction settlement path (winner already escrowed the bid → double charge /
// revert). These tests exercise the three refund sites plus settlement.
//
// The marketplace's constructor `_wrfToken` is used via `IERC20(address(wrfToken))`
// on the WRF payment path, so we pass a MockERC20 and list with PaymentToken.WRF.
// =============================================================================
describe('NFTMarketplace — ERC20 auction refunds (#173)', function () {
  const WRF = 1; // enum PaymentToken { Native, WRF, USDC, Custom }
  const ONE_HOUR = 60 * 60;

  async function fixture() {
    const [owner, seller, bidder1, bidder2] = await ethers.getSigners();

    const ERC20 = await ethers.getContractFactory('MockERC20');
    const pay = await ERC20.deploy('Pay', 'PAY', 18);
    await pay.waitForDeployment();

    const ERC721 = await ethers.getContractFactory('MockERC721');
    const nft = await ERC721.deploy('Art', 'ART');
    await nft.waitForDeployment();

    const MKT = await ethers.getContractFactory('NFTMarketplace');
    const mkt = await MKT.deploy(await pay.getAddress()); // wrfToken := PAY
    await mkt.waitForDeployment();

    await mkt.setAuthorizedNFTContract(await nft.getAddress(), true);

    // Seller owns token #1 and approves the marketplace.
    await nft['mint(address,uint256)'](seller.address, 1);
    await nft.connect(seller).setApprovalForAll(await mkt.getAddress(), true);

    return { owner, seller, bidder1, bidder2, pay, nft, mkt };
  }

  async function fundAndApprove(pay, mkt, who, amount) {
    await pay.mint(who.address, amount);
    await pay.connect(who).approve(await mkt.getAddress(), amount);
  }

  async function createWrfAuction(mkt, seller, nft, startPrice, reservePrice) {
    await mkt
      .connect(seller)
      .createAuction(
        await nft.getAddress(),
        1,
        startPrice,
        reservePrice,
        ONE_HOUR,
        WRF,
        ethers.ZeroAddress
      );
    return 1n; // first listing id
  }

  it('out-bid refund credits the ERC20 (token) ledger, not the native ETH ledger', async function () {
    const { seller, bidder1, bidder2, pay, nft, mkt } = await loadFixture(fixture);
    const payAddr = await pay.getAddress();
    const bid1 = ethers.parseEther('100');
    const bid2 = ethers.parseEther('200');

    await fundAndApprove(pay, mkt, bidder1, bid1);
    await fundAndApprove(pay, mkt, bidder2, bid2);

    const id = await createWrfAuction(mkt, seller, nft, bid1, 0);

    await mkt.connect(bidder1).placeBidWithToken(id, bid1);
    await mkt.connect(bidder2).placeBidWithToken(id, bid2); // out-bids bidder1

    // bidder1's 100 must be refunded to the TOKEN ledger.
    const [eth, tokens] = await mkt.getPendingWithdrawals(bidder1.address, [payAddr]);
    expect(eth).to.equal(0n);
    expect(tokens[0]).to.equal(bid1);

    // And it is actually recoverable as ERC20 (not ETH).
    await expect(mkt.connect(bidder1).withdraw()).to.be.revertedWith('Marketplace: No ETH funds to withdraw');
    const before = await pay.balanceOf(bidder1.address);
    await mkt.connect(bidder1).withdrawToken(payAddr);
    expect((await pay.balanceOf(bidder1.address)) - before).to.equal(bid1);
  });

  it('settlement does NOT double-charge the winner and credits the seller in the token ledger', async function () {
    const { owner, seller, bidder1, pay, nft, mkt } = await loadFixture(fixture);
    const payAddr = await pay.getAddress();
    const bid = ethers.parseEther('100');

    // Winner is funded with EXACTLY the bid — a second transferFrom would revert.
    await fundAndApprove(pay, mkt, bidder1, bid);

    const id = await createWrfAuction(mkt, seller, nft, bid, 0);
    await mkt.connect(bidder1).placeBidWithToken(id, bid);
    expect(await pay.balanceOf(bidder1.address)).to.equal(0n); // escrowed

    await time.increase(ONE_HOUR + 60);

    // Pre-fix this reverted (re-pull with no balance) or mis-credited native.
    await expect(mkt.finalizeAuction(id)).to.not.be.reverted;

    // NFT went to the winner; winner was charged exactly once.
    expect(await nft.ownerOf(1)).to.equal(bidder1.address);
    expect(await pay.balanceOf(bidder1.address)).to.equal(0n);

    // Seller + marketplace fee were credited to the TOKEN ledger (no ETH), and
    // conserve the full sale price (no royalties configured).
    const sellerTok = (await mkt.getPendingWithdrawals(seller.address, [payAddr]))[1][0];
    const ownerTok = (await mkt.getPendingWithdrawals(owner.address, [payAddr]))[1][0];
    const sellerEth = (await mkt.getPendingWithdrawals(seller.address, [payAddr]))[0];
    expect(sellerEth).to.equal(0n);
    expect(sellerTok + ownerTok).to.equal(bid);
    expect(sellerTok).to.be.gt(0n);
  });

  it('no-valid-bid (below reserve) refund credits the token ledger', async function () {
    const { seller, bidder1, pay, nft, mkt } = await loadFixture(fixture);
    const payAddr = await pay.getAddress();
    const bid = ethers.parseEther('100');

    await fundAndApprove(pay, mkt, bidder1, bid);

    // Reserve above the only bid → finalize hits the "no valid bid" branch.
    const id = await createWrfAuction(mkt, seller, nft, bid, ethers.parseEther('500'));
    await mkt.connect(bidder1).placeBidWithToken(id, bid);

    await time.increase(ONE_HOUR + 60);
    await mkt.finalizeAuction(id);

    // NFT returned to seller; bidder refunded to the token ledger.
    expect(await nft.ownerOf(1)).to.equal(seller.address);
    const [eth, tokens] = await mkt.getPendingWithdrawals(bidder1.address, [payAddr]);
    expect(eth).to.equal(0n);
    expect(tokens[0]).to.equal(bid);
  });

  it('cancelListing refund on an ERC20 auction credits the token ledger', async function () {
    const { seller, bidder1, pay, nft, mkt } = await loadFixture(fixture);
    const payAddr = await pay.getAddress();
    const bid = ethers.parseEther('100');

    await fundAndApprove(pay, mkt, bidder1, bid);

    const id = await createWrfAuction(mkt, seller, nft, bid, 0);
    await mkt.connect(bidder1).placeBidWithToken(id, bid);

    await mkt.connect(seller).cancelListing(id);

    expect(await nft.ownerOf(1)).to.equal(seller.address);
    const [eth, tokens] = await mkt.getPendingWithdrawals(bidder1.address, [payAddr]);
    expect(eth).to.equal(0n);
    expect(tokens[0]).to.equal(bid);
  });
});
