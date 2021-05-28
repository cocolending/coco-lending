const Unitroller = artifacts.require("Unitroller");
const ComptrollerG6 = artifacts.require("ComptrollerG6");
const JumpRateModelV2 = artifacts.require("JumpRateModelV2");

const BigNumber = require('bignumber.js');
const bn = x=>(new BigNumber(x));

module.exports = async function (deployer) {

  const baseRatePerYear = bn("0.00e18");  // + 2% apy
  const multiplierPerYear = bn("0.25e18"); // %25 apy
  const jumpMultiplierPerYear = bn("1e18"); // max 100% apy
  const kink_ = bn("0.8e18");

	// get the owner address
	const accounts = await web3.eth.getAccounts();
	const owner = accounts[0];

  await deployer.deploy(Unitroller);
  await deployer.deploy(ComptrollerG6);
  await deployer.deploy(JumpRateModelV2,      
    baseRatePerYear, // 最低基础利率 2%
    multiplierPerYear,  // 目标利率 25%
    jumpMultiplierPerYear, // 最大利率 100%
    kink_, // 分段利率 80%
    owner
  );
};
