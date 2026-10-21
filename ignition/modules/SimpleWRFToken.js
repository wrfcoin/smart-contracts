const { buildModule } = require('@nomicfoundation/hardhat-ignition/modules');

module.exports = buildModule('SimpleWRFTokenModule', m => {
  // Deploy WRF Token contract
  const wrfToken = m.contract('WRFToken');

  return { wrfToken };
});
