const { buildModule } = require('@nomicfoundation/hardhat-ignition/modules');

module.exports = buildModule('WRFTokenModule', m => {
  // Deploy WRF Token contract
  const wrfToken = m.contract('WRFToken');

  // Register initial weather stations after deployment
  const weatherStation1 = '0x742d35Cc6aB9C8F4c5a7B28EBC7F28E6D07d0b4d'; // Example address
  const weatherStation2 = '0x8ba1f109551bD432803012645Hac136c24F75D'; // Example address

  // Optional: Configure initial weather stations
  // Note: These would typically be called after deployment via scripts
  m.call(
    wrfToken,
    'registerWeatherStation',
    [weatherStation1, 'ACURITE_STATION_001'],
    { id: 'RegisterStation1' }
  );
  m.call(
    wrfToken,
    'registerWeatherStation',
    [weatherStation2, 'DAVIS_STATION_002'],
    { id: 'RegisterStation2' }
  );

  return { wrfToken };
});

// Alternative: More comprehensive deployment with all contracts
const WrfcoinEcosystemModule = buildModule('WrfcoinEcosystemModule', m => {
  // 1. Deploy WRF Token first
  const wrfToken = m.contract('WRFToken');

  // 2. Deploy Weather Data Validator
  const weatherValidator = m.contract('WeatherDataValidator');

  // 3. Deploy Carbon Credits (depends on WRF Token)
  const carbonCredits = m.contract('CarbonCredits', [wrfToken]);

  // 4. Deploy Computational NFT (depends on WRF Token)
  const computationalNFT = m.contract('ComputationalNFT', [wrfToken]);

  // Initial configuration calls

  // Authorize weather stations
  m.call(weatherValidator, 'authorizeStation', [
    'ACURITE_001',
    '0x742d35Cc6aB9C8F4c5a7B28EBC7F28E6D07d0b4d',
  ]);
  m.call(weatherValidator, 'authorizeStation', [
    'DAVIS_002',
    '0x8ba1f109551bD432803012645Hac136c24F7D',
  ]);

  // Register weather stations in token contract
  m.call(wrfToken, 'registerWeatherStation', [
    '0x742d35Cc6aB9C8F4c5a7B28EBC7F28E6D07d0b4d',
    'ACURITE_001',
  ]);
  m.call(wrfToken, 'registerWeatherStation', [
    '0x8ba1f109551bD432803012645Hac136c24F7D',
    'DAVIS_002',
  ]);

  // Authorize carbon credit issuers
  m.call(carbonCredits, 'authorizeIssuer', [
    '0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0',
  ]);

  // Add supported computational models
  m.call(computationalNFT, 'addSupportedModel', [
    'WRF-GFS-ENSEMBLE-V4',
    0, // WeatherForecast enum value
    '0x', // Empty validation rules for demo
  ]);

  m.call(computationalNFT, 'addSupportedModel', [
    'ICON-EU-NEST',
    0, // WeatherForecast enum value
    '0x', // Empty validation rules for demo
  ]);

  return {
    wrfToken,
    weatherValidator,
    carbonCredits,
    computationalNFT,
  };
});

module.exports.WrfcoinEcosystemModule = WrfcoinEcosystemModule;
